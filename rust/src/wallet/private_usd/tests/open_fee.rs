//! The open fee on fakes (zecSwap's `docs/open-fee.md`, the owner's
//! "Done when"): a fee over the cap or payable outside Orchard is refused
//! with nothing paid; an accept the maker answers `feeRequired` is posted
//! again as it asks and the swap completes; one whose fee the maker never
//! sees stops at the quote's end; a payment kept but not sent is sent, never
//! built again; and a quote without a fee is accepted as before.

use super::super::engine;
use super::super::evm_rpc::SwapStage;
use super::super::forward::{AcceptOutcome, ForwardStep, ForwardWait, Funds};
use super::super::models::{ForwardOutcome, NothingSentCause, OpenFeeProgress};
use super::super::{ErrorCode, Result};
use super::fakes::*;

const FEE: u64 = 20_000;

fn accept_path() -> String {
    format!("/v1/quote/0x{}/accept", "22".repeat(32))
}

/// An Orchard-only unified address on the deployment's Zcash network, as a
/// maker's fee address is: another seed's joint account.
fn fee_address() -> String {
    super::super::keys::SwapKeyContext::for_tests(&[3; 64], NETWORK, 0)
        .joint(0, &maker_share())
        .unwrap()
        .unified_address(NETWORK.zcash())
}

/// A harness whose maker asks `zat` to `address` before it opens a swap.
fn asking(zat: u64, address: String) -> Harness {
    let h = Harness::new();
    h.world.set().open_fee = Some((zat, address));
    h
}

fn waiting(wait: ForwardWait) -> ForwardStep {
    ForwardStep::Waiting {
        wait,
        t0: None,
        t1: None,
    }
}

fn nothing_sent(cause: NothingSentCause) -> ForwardStep {
    ForwardStep::Finished(ForwardOutcome::NothingSent { cause })
}

/// Accepts swap `index`'s offer, approving its deposit and that deposit's fee.
async fn accept(h: &Harness, index: u32) -> Result<AcceptOutcome> {
    h.forward()
        .accept(&mut h.store(), index, DEPOSIT_ZAT + DEPOSIT_FEE_ZAT, false)
        .await
}

fn accepts(h: &Harness) -> usize {
    h.posts(&accept_path())
}

fn mine(h: &Harness, name: &str) {
    h.world.set().statuses.insert(tx_id(name), mined(1));
}

/// Done when 1: a fee above the cap, of nothing, to an address of another
/// network or beside a transparent receiver is refused at the quote with
/// nothing paid, though the index is spent. A wallet that could not also
/// deposit, or a quote too near its end, pays nothing either.
#[tokio::test]
async fn a_fee_over_the_cap_or_payable_outside_orchard_is_refused_with_nothing_paid() {
    let address = fee_address();
    let mainnet = super::super::keys::SwapKeyContext::for_tests(
        &[3; 64],
        super::super::PrivateUsdNetwork::Mainnet,
        0,
    )
    .joint(0, &maker_share())
    .unwrap()
    .unified_address(super::super::PrivateUsdNetwork::Mainnet.zcash());
    let cap = pins().max_open_fee_zat;
    for (zat, to) in [
        (cap + 1, address.clone()),
        (0, address.clone()),
        (FEE, mainnet),
        (FEE, "tmEZhbWHTpdKMw5it8YDspUXSMGQyFwovpU".to_owned()),
    ] {
        let h = asking(zat, to);
        let refused = h.quote().await.unwrap_err();
        assert_eq!(refused.code, ErrorCode::OpenFeeRefused, "{refused:?}");
        assert_eq!(accepts(&h), 0);
        assert!(h.world.get().fee_payments.is_empty());
        // The index is spent: the next quote takes the one after.
        h.world.set().open_fee = Some((FEE, address.clone()));
        assert_eq!(h.quote().await.unwrap().index, 1);
    }

    // The cap itself is paid.
    let h = asking(cap, address.clone());
    let quoted = h.quote().await.unwrap();
    assert_eq!(
        accept(&h, quoted.index).await.unwrap(),
        AcceptOutcome::Accepted
    );
    assert_eq!(h.world.get().fee_payments, [(address.clone(), cap)]);

    // A wallet that could not deposit after the fee pays none: nothing saved.
    let h = asking(FEE, address.clone());
    let quoted = h.quote().await.unwrap();
    h.world.set().funds = Funds {
        spendable: FEE + DEPOSIT_FEE_ZAT + DEPOSIT_ZAT + DEPOSIT_FEE_ZAT - 1,
        pending: 0,
    };
    let short = accept(&h, quoted.index).await.unwrap_err();
    assert_eq!(short.code, ErrorCode::DepositUnpayable);
    assert!(h.world.get().fee_payments.is_empty());
    assert_eq!(h.store().unfinished_count(&h.account).unwrap(), 0);

    // Nor one under a minute from the quote's end.
    let h = asking(FEE, address);
    let quoted = h.quote().await.unwrap();
    h.world.set().clock = NOW + 300 - 59;
    let late = accept(&h, quoted.index).await.unwrap_err();
    assert_eq!(late.code, ErrorCode::QuoteExpired);
    assert!(h.world.get().fee_payments.is_empty());
    assert_eq!(accepts(&h), 0);
}

/// Done when 2: the fee is paid at accept and the accept waits for a block
/// to have it; answered `feeRequired` twice, the accept is posted again as
/// the maker asks, the second wait paced to 12 s, and the swap then
/// completes. A deposit waits for the fee's change rather than fail.
#[tokio::test]
async fn an_accept_answered_fee_required_twice_then_accepted_completes_the_swap() {
    let address = fee_address();
    let h = asking(FEE, address.clone());
    {
        let mut state = h.world.set();
        state.fee_unseen_accepts = 2;
        state.fee_retry_after = Some(3);
    }
    let quoted = h.quote().await.unwrap();
    assert_eq!(
        accept(&h, quoted.index).await.unwrap(),
        AcceptOutcome::Accepted
    );
    // Paid once, exactly, kept and sent; nothing accepted before a block
    // has it.
    assert_eq!(h.world.get().fee_payments, [(address, FEE)]);
    assert_eq!(h.world.get().submitted, [tx_id("openfee1")]);
    assert!(matches!(
        h.record().open_fee_progress(),
        OpenFeeProgress::Kept(payment) if payment.tx_id == tx_id("openfee1")
    ));
    assert_eq!(accepts(&h), 0);
    assert_eq!(
        h.advance().await.unwrap(),
        waiting(ForwardWait::FeeConfirming)
    );
    assert_eq!(accepts(&h), 0);

    mine(&h, "openfee1");
    let report = async || h.forward().advance_report(&mut h.store(), 0).await.unwrap();
    let unseen = report().await;
    assert_eq!(unseen.wait, Some(ForwardWait::FeeAccepting));
    assert_eq!(unseen.next_poll, std::time::Duration::from_secs(3));
    assert_eq!(accepts(&h), 1);
    // Not before the maker asked.
    assert_eq!(report().await.wait, Some(ForwardWait::FeeAccepting));
    assert_eq!(accepts(&h), 1);
    h.world.set().pass(3);
    let paced = report().await;
    assert_eq!(
        (paced.wait, accepts(&h)),
        (Some(ForwardWait::FeeAccepting), 2)
    );
    assert_eq!(paced.next_poll, std::time::Duration::from_secs(12));
    h.world.set().pass(3);
    assert_eq!(report().await.wait, Some(ForwardWait::FeeAccepting));
    assert_eq!(accepts(&h), 2);
    h.world.set().pass(9);
    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Opening));
    assert_eq!(accepts(&h), 3);
    assert!(h.record().t0.is_some());

    // The fee spent the only note: the deposit waits for its change.
    {
        let mut state = h.world.set();
        state.unpayable = true;
        state.funds.pending = 180_000;
    }
    assert_eq!(
        h.advance().await.unwrap(),
        ForwardStep::Waiting {
            wait: ForwardWait::FundsPending,
            t0: None,
            t1: None,
        }
    );
    assert_eq!(h.world.get().deposits.len(), 0);
    h.world.set().unpayable = false;
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.world.get().deposits.len(), 1);

    h.world.set().stage = SwapStage::Ready;
    assert_eq!(
        h.advance().await.unwrap(),
        ForwardStep::Finished(ForwardOutcome::Paid)
    );
    assert_eq!(h.world.get().fee_payments.len(), 1, "never paid twice");
    assert_eq!(accepts(&h), 3);
}

/// Done when 3: with the fee never seen, the accept is posted until the
/// quote's end and never after, and the swap ends with the fee the maker's.
/// A fee no block has by then is given up the same way, with no accept.
#[tokio::test]
async fn with_the_fee_never_seen_the_accept_stops_at_the_quotes_end() {
    let h = asking(FEE, fee_address());
    h.world.set().fee_unseen_accepts = u32::MAX;
    let quoted = h.quote().await.unwrap();
    accept(&h, quoted.index).await.unwrap();
    mine(&h, "openfee1");
    let expires_at = NOW + 300;
    while h.world.get().clock < expires_at {
        assert_eq!(
            h.advance().await.unwrap(),
            waiting(ForwardWait::FeeAccepting)
        );
        h.world.set().pass(7);
    }
    let posted = accepts(&h);
    assert!(posted >= 10, "posted again while the quote lived: {posted}");
    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::FeeNotHonoured)
    );
    h.world.set().pass(60);
    h.advance().await.unwrap();
    assert_eq!(accepts(&h), posted, "and never after");

    let h = asking(FEE, fee_address());
    let quoted = h.quote().await.unwrap();
    accept(&h, quoted.index).await.unwrap();
    h.world.set().clock = expires_at;
    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::FeeNotHonoured)
    );
    assert_eq!(accepts(&h), 0);
}

/// Done when 4: a payment kept but never sent, as a restart between the two
/// leaves it, is sent once, not built again, and sent again only after half
/// a minute. One created but not kept is found in the wallet and sent.
#[tokio::test]
async fn a_restart_between_keeping_the_payment_and_sending_it_sends_that_payment_once() {
    let h = asking(FEE, fee_address());
    h.world.set().broadcast_fails = true;
    let quoted = h.quote().await.unwrap();
    assert_eq!(
        accept(&h, quoted.index).await.unwrap_err().code,
        ErrorCode::ZcashRejected
    );
    assert!(matches!(
        h.record().open_fee_progress(),
        OpenFeeProgress::Kept(_)
    ));
    assert!(h.world.get().submitted.is_empty());

    // The app comes back with nothing in memory, and the node takes it.
    engine::remove_fee_pace(&h.account, 0);
    h.world.set().broadcast_fails = false;
    assert_eq!(
        h.advance().await.unwrap(),
        waiting(ForwardWait::FeeConfirming)
    );
    assert_eq!(h.world.get().submitted, [tx_id("openfee1")]);
    assert_eq!(
        h.advance().await.unwrap(),
        waiting(ForwardWait::FeeConfirming)
    );
    assert_eq!(h.world.get().submitted.len(), 1, "not again within 30 s");
    h.world.set().pass(30);
    h.advance().await.unwrap();
    assert_eq!(
        h.world.get().submitted,
        [tx_id("openfee1"), tx_id("openfee1")]
    );
    assert_eq!(h.world.get().fee_payments.len(), 1, "built once");

    // Created, but the record never kept it: found again, never rebuilt.
    let h = asking(FEE, fee_address());
    h.world.set().fee_crash = Some(Crash::AfterCreate);
    let quoted = h.quote().await.unwrap();
    assert_eq!(
        accept(&h, quoted.index).await.unwrap_err().code,
        ErrorCode::StoreUnreadable
    );
    assert_eq!(h.record().open_fee_progress(), OpenFeeProgress::Started);
    engine::remove_fee_pace(&h.account, 0);
    assert_eq!(
        h.advance().await.unwrap(),
        waiting(ForwardWait::FeeConfirming)
    );
    assert!(matches!(
        h.record().open_fee_progress(),
        OpenFeeProgress::Kept(_)
    ));
    assert_eq!(h.world.get().submitted, [tx_id("openfee1")]);
    assert_eq!(h.world.get().fee_payments.len(), 1);
}

/// Done when 5: a quote without an open fee is accepted at once, with
/// nothing paid ahead and no fee kept on its record.
#[tokio::test]
async fn a_quote_without_an_open_fee_is_accepted_as_before() {
    let h = Harness::new();
    let quoted = h.quote().await.unwrap();
    assert_eq!(quoted.offer.open_fee_network_zatoshi, None);
    assert_eq!(
        accept(&h, quoted.index).await.unwrap(),
        AcceptOutcome::Accepted
    );
    assert_eq!(accepts(&h), 1);
    assert!(h.world.get().fee_payments.is_empty());
    let record = h.record();
    assert_eq!(record.open_fee_progress(), OpenFeeProgress::NotStarted);
    assert_eq!(record.open_fee_max_total_zat, None);
    assert!(record.t0.is_some());
    assert!(
        !super::super::models::StoredRecord::Forward(Box::new(record))
            .to_json()
            .unwrap()
            .contains("openFee")
    );
}

/// Finding 1: the fee's payment is created to expire with its quote, not
/// 40 or 120 blocks on, and a bridge that ended sends it no more.
#[tokio::test]
async fn the_fee_expires_with_its_quote_and_an_ended_bridge_sends_it_no_more() {
    let h = asking(FEE, fee_address());
    h.world.set().fee_unseen_accepts = u32::MAX;
    let quoted = h.quote().await.unwrap();
    accept(&h, quoted.index).await.unwrap();
    assert_eq!(h.world.get().fee_deadlines, [NOW + 300]);
    assert_eq!(h.world.get().submitted.len(), 1);

    h.world.set().clock = NOW + 300;
    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::FeeNotHonoured)
    );
    h.world.set().pass(60);
    h.advance().await.unwrap();
    assert_eq!(h.world.get().submitted.len(), 1, "never sent again");
}

/// Findings 2 and 5: a fee quote with less than the least life its fee
/// needs, or one that lives past the deployment's most, is refused at the
/// quote with nothing paid; and one whose life ran below the least by the
/// bridge pays nothing either.
#[tokio::test]
async fn a_fee_quote_too_short_or_too_long_lived_pays_nothing() {
    let least = pins().open_fee_min_quote_life_seconds;
    let most = pins().open_fee_max_quote_life_seconds;
    assert_eq!((least, most), (180, 1_800));
    for life in [least - 1, most + 1] {
        let h = asking(FEE, fee_address());
        h.world.set().quote_expires_at = NOW + life;
        let refused = h.quote().await.unwrap_err();
        assert_eq!(
            refused.code,
            ErrorCode::OpenFeeRefused,
            "{life}: {refused:?}"
        );
        assert!(h.world.get().fee_payments.is_empty());
    }
    for life in [least, most] {
        let h = asking(FEE, fee_address());
        h.world.set().quote_expires_at = NOW + life;
        let quoted = h.quote().await.unwrap();
        assert_eq!(
            accept(&h, quoted.index).await.unwrap(),
            AcceptOutcome::Accepted,
            "{life}"
        );
    }

    // Tapped a second too late: nothing saved, nothing paid.
    let h = asking(FEE, fee_address());
    let quoted = h.quote().await.unwrap();
    h.world.set().clock = NOW + 300 - least + 1;
    let late = accept(&h, quoted.index).await.unwrap_err();
    assert_eq!(late.code, ErrorCode::QuoteExpired);
    assert!(h.world.get().fee_payments.is_empty());
    assert_eq!(h.store().unfinished_count(&h.account).unwrap(), 0);

    // A quote without a fee keeps its old margin.
    let h = Harness::new();
    let quoted = h.quote().await.unwrap();
    h.world.set().clock = NOW + 300 - least + 1;
    assert_eq!(
        accept(&h, quoted.index).await.unwrap(),
        AcceptOutcome::Accepted
    );
}

/// Finding 3: an accept whose answer was lost, for a swap the maker opened,
/// goes on to its deposit once the quote is over, with the deadlines its
/// confirmed `Opened` names and nothing posted after the quote; a swap
/// whose event no confirmed block shows is waited for, then given up. A
/// quote without a fee is followed the same way.
#[tokio::test]
async fn a_swap_whose_accept_answer_was_lost_goes_on_from_the_chains_opened() {
    let h = asking(FEE, fee_address());
    h.world.set().accept_answer_lost = true;
    let quoted = h.quote().await.unwrap();
    accept(&h, quoted.index).await.unwrap();
    mine(&h, "openfee1");
    assert_eq!(
        h.advance().await.unwrap(),
        waiting(ForwardWait::FeeAccepting)
    );
    assert!(h.world.get().opened, "the maker opened it");
    assert_eq!(h.record().t0, None, "but its answer never came");
    let posted = accepts(&h);

    h.world.set().pass(300);
    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Opening));
    assert_eq!(accepts(&h), posted, "nothing posted after the quote");
    let (t0, t1) = (h.world.get().t0, h.world.get().t1());
    assert_eq!((h.record().t0, h.record().t1), (Some(t0), Some(t1)));
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.world.get().deposits.len(), 1);
    assert_eq!(accepts(&h), posted);

    // No confirmed block shows its event yet: waited for, then given up.
    let h = asking(FEE, fee_address());
    {
        let mut state = h.world.set();
        state.accept_answer_lost = true;
        state.opened_event_visible = false;
    }
    let quoted = h.quote().await.unwrap();
    accept(&h, quoted.index).await.unwrap();
    mine(&h, "openfee1");
    h.advance().await.unwrap();
    h.world.set().pass(300 + 300 + 300);
    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Opening));
    assert_eq!(h.record().t0, None);
    h.world.set().pass(1);
    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::MakerUnavailable)
    );
    assert!(h.world.get().deposits.is_empty());

    // Without a fee: the accept itself loses its answer.
    let h = Harness::new();
    h.world.set().accept_answer_lost = true;
    let quoted = h.quote().await.unwrap();
    assert!(accept(&h, quoted.index).await.is_err(), "maybe opened");
    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Opening));
    assert_eq!(
        h.world.get().opened_event_reads,
        0,
        "not before the quote ends"
    );
    h.world.set().pass(300);
    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Opening));
    assert!(h.record().t0.is_some());
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.world.get().deposits.len(), 1);
}

