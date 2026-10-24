//! The forward conversion's fund-safety rules on fakes: the driver, the
//! claim's windows and settlement, the deposit's crash points and sync gate,
//! the 2 USDC cap, the token gate without a tokens client, claims handed to
//! the relayer, the rescue of a payout Railgun sent back, records of another
//! contract, and one driver step per account.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use tokio::sync::Notify;

use super::super::deployment::{
    READY_DEPTH_BLOCKS, RELAYER_CLAIM_WAIT_BLOCKS, RELAYER_CLAIM_WAIT_SECONDS,
};
use super::super::engine;
use super::super::evm_rpc::SwapStage;
use super::super::forward::{AcceptOutcome, ForwardStep, ForwardWait, ReturnedPayout};
use super::super::joint::SwapTxStatus;
use super::super::models::{
    Amount, ClaimHold, DepositProgress, Direction, ForwardOutcome, ForwardPhase, ForwardRecord,
    Hex, NothingSentCause, RefundCause, StoredRecord,
};
use super::super::store::SwapStore;
use super::super::terms::swap_id;
use super::super::{ErrorCode, Result};
use super::fakes::*;

fn nothing_sent(cause: NothingSentCause) -> ForwardStep {
    ForwardStep::Finished(ForwardOutcome::NothingSent { cause })
}

fn paid() -> ForwardStep {
    ForwardStep::Finished(ForwardOutcome::Paid)
}

fn refunded(sweep: &str, cause: RefundCause) -> ForwardStep {
    ForwardStep::Finished(ForwardOutcome::Refunded {
        sweep_tx_id: tx_id(sweep),
        cause,
    })
}

fn waiting(wait: ForwardWait) -> ForwardStep {
    ForwardStep::Waiting {
        wait,
        t0: None,
        t1: None,
    }
}

fn code<T: std::fmt::Debug>(result: Result<T>) -> ErrorCode {
    result.unwrap_err().code
}

fn accept_path() -> String {
    format!("/v1/quote/0x{}/accept", "22".repeat(32))
}

impl Harness {
    fn posted(&self, path: &str) -> usize {
        self.paths().iter().filter(|posted| *posted == path).count()
    }

    fn deposits(&self) -> usize {
        self.world.get().deposits.len()
    }

    fn submitted(&self) -> Vec<super::super::models::ZcashTxId> {
        self.world.get().submitted.clone()
    }

    async fn accept(&self, index: u32) -> Result<AcceptOutcome> {
        let relayer_claims = self.world.get().relayer_claims;
        self.forward()
            .accept(
                &mut self.store(),
                index,
                DEPOSIT_ZAT + DEPOSIT_FEE_ZAT,
                relayer_claims,
            )
            .await
    }

    /// The record as an interruption after `Started` left it.
    fn started(&self) {
        let mut record = self.record();
        record.deposit_attempted = true;
        record.deposit = None;
        self.keep(&record);
    }
}

// ---- quote and accept (AtomicSwapDriverTest) ----

#[tokio::test]
async fn the_happy_path_claims_into_railgun() {
    let h = Harness::new();
    let record = h.accepted().await;

    assert_eq!(h.advance().await.unwrap(), h.confirming());
    let address = h
        .keys
        .joint(0, &maker_share())
        .unwrap()
        .unified_address(NETWORK.zcash());
    assert_eq!(h.world.get().deposits, vec![(address, DEPOSIT_ZAT)]);
    assert_eq!(
        h.record().deposit.map(|deposit| deposit.tx_id),
        Some(tx_id("deposit1"))
    );
    assert_eq!(h.submitted(), vec![tx_id("deposit1")]);

    h.world.set().stage = SwapStage::Ready;
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(
        h.paths(),
        [
            "/v1/info",
            // Asked beside the index, before the maker's quote.
            "/v1/terms",
            "/v1/quote",
            &accept_path(),
            "/v1/terms",
            "/v1/claim",
        ]
    );
    // The claim reveals z with the swap's ticket, on a ready read at the
    // block READY_DEPTH_BLOCKS below the head.
    let z = h.keys.user_keys(0).unwrap().share.to_be_bytes();
    let state = h.world.get();
    assert_eq!(
        state.bodies["/v1/claim"]["secret"],
        format!("0x{}", hex::encode(z))
    );
    let ticket = state.headers["/v1/claim"]
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("zecswap-ticket"))
        .map(|(_, value)| value.clone());
    assert_eq!(
        ticket,
        record.ticket.as_ref().map(|ticket| ticket.0.clone())
    );
    assert_eq!(
        state.depth_reads,
        vec![state.head_number - READY_DEPTH_BLOCKS; 2]
    );
    drop(state);
    let ended = h.record();
    assert!(ended.claim_posted, "kept as posted before it went");
    assert_eq!(ended.outcome, Some(ForwardOutcome::Paid));
    assert_eq!(ended.finished_at, Some(NOW));
    assert_eq!(
        ended.payout_tx,
        Some(Hex(word(1))),
        "the claim's second transaction is the payout"
    );
    // The payout is the swap's own key's, for the pinned relayer.
    let payout = ended.payout.unwrap();
    let digest = pins()
        .domain()
        .unwrap()
        .payout(&record.swap_id.0, &pins().relayer, payout.fee.0);
    assert_eq!(
        zecswap_core::signer(&digest, &payout.signature.0),
        Some(h.keys.auth_address(0).unwrap())
    );
}

#[tokio::test]
async fn an_offer_says_what_arrives_after_the_relayer_and_railgun_take_their_fees() {
    let h = Harness::new();
    let quoted = h.quote().await.unwrap();

    assert_eq!(quoted.index, 0);
    assert_eq!(quoted.offer.relayer_fee, Amount(20_000));
    assert_eq!(quoted.offer.receives, Amount(977_550));
    assert_eq!(
        quoted.offer.max_total_zatoshi(),
        Some(DEPOSIT_ZAT + DEPOSIT_FEE_ZAT)
    );
    // The maker quotes for the swap's own key and note.
    let state = h.world.get();
    let request = &state.quote_requests[0];
    assert_eq!(request["units"], 1);
    assert_eq!(
        request["payout"],
        format!("0x{}", hex::encode(h.keys.auth_address(0).unwrap()))
    );
    assert_eq!(
        request["payoutNote"],
        format!("0x{}", hex::encode(h.keys.note(0).unwrap().commitment()))
    );
}

/// Claiming reveals `z`, so another swap on the same index would be the
/// maker's to take.
#[tokio::test]
async fn swap_indices_are_never_reused() {
    let h = Harness::new();
    assert_eq!(h.quote().await.unwrap().index, 0);
    // A quote spends its index, accepted or not.
    assert_eq!(h.quote().await.unwrap().index, 1);
    assert_eq!(h.accept(1).await.unwrap(), AcceptOutcome::Accepted);
    // One conversion at a time: no index is taken while one is under way.
    assert_eq!(code(h.quote().await), ErrorCode::Busy);
    assert_eq!(h.world.get().quote_requests.len(), 2);

    // A reinstall loses the counter; the chain still shows indices 0 and 1
    // in use (the same seed in another wallet, say), and they are skipped.
    let reinstalled = Harness::new();
    for index in [0, 1] {
        let share = reinstalled.keys.user_share(index).unwrap();
        reinstalled
            .world
            .set()
            .used_ids
            .push(swap_id(&pins().maker, &share));
    }
    assert_eq!(reinstalled.quote().await.unwrap().index, 2);
    {
        let state = reinstalled.world.get();
        assert_eq!(
            state.quote_requests.len(),
            1,
            "the maker never hears of a used index"
        );
        assert_eq!(
            state.quote_requests[0]["payout"],
            format!(
                "0x{}",
                hex::encode(reinstalled.keys.auth_address(2).unwrap())
            )
        );
    }

    // Indices the retired lock contract shows in use are skipped as well.
    let reinstalled = Harness::new();
    for index in [0, 1] {
        let share = reinstalled.keys.user_share(index).unwrap();
        reinstalled
            .world
            .set()
            .used_before
            .push(swap_id(&pins().maker, &share));
    }
    assert_eq!(reinstalled.quote().await.unwrap().index, 2);
}

#[tokio::test]
async fn a_quote_about_to_run_out_is_not_accepted() {
    let h = Harness::new();
    let quoted = h.quote().await.unwrap();
    h.world.set().clock = NOW + 290;

    assert_eq!(code(h.accept(quoted.index).await), ErrorCode::QuoteExpired);
    assert!(h.paths().iter().all(|path| !path.ends_with("/accept")));
    assert_eq!(
        h.store().find(&h.account, Direction::Forward, 0).unwrap(),
        None
    );

    // An offer is held only in memory: gone with a lock, or expired, it is
    // never accepted.
    h.world.set().clock = NOW;
    engine::remove_account_offers(&h.account);
    assert_eq!(code(h.accept(quoted.index).await), ErrorCode::QuoteExpired);
    let quoted = h.quote().await.unwrap();
    h.world.set().clock = NOW + 300;
    assert_eq!(code(h.accept(quoted.index).await), ErrorCode::QuoteExpired);
    assert!(h.paths().iter().all(|path| !path.ends_with("/accept")));
}

#[tokio::test]
async fn an_accept_that_may_have_opened_waits_for_the_swap_then_gives_up() {
    let h = Harness::new();
    {
        let mut state = h.world.set();
        state.accept_status = 500;
        state.accept_code = Some("internal");
    }
    let quoted = h.quote().await.unwrap();

    assert!(h.accept(quoted.index).await.is_err());
    let record = h.record();
    assert_eq!(
        record.outcome, None,
        "saved before the share left: maybe opened"
    );
    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Opening));

    h.world.set().clock = NOW + 300 + 301;
    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::NeverOpened)
    );
}

#[tokio::test]
async fn an_accept_refusal_ends_only_when_nothing_can_have_opened() {
    // A refusal with a known code ends as the code says.
    let h = Harness::new();
    {
        let mut state = h.world.set();
        state.accept_status = 400;
        state.accept_code = Some("unknownQuote");
    }
    let quoted = h.quote().await.unwrap();
    assert_eq!(
        h.accept(quoted.index).await.unwrap(),
        AcceptOutcome::NothingSent(NothingSentCause::QuoteExpired)
    );
    assert_eq!(
        h.record().outcome,
        Some(ForwardOutcome::NothingSent {
            cause: NothingSentCause::QuoteExpired
        })
    );

    // One that may follow an open is not taken for nothing sent.
    let h = Harness::new();
    {
        let mut state = h.world.set();
        state.accept_status = 400;
        state.accept_code = Some("internal");
    }
    let quoted = h.quote().await.unwrap();
    assert!(h.accept(quoted.index).await.is_err());
    assert_eq!(h.record().outcome, None);
}

/// Without a tokens client, a maker asking for a token gets `TokensNeeded`,
/// never a retry, and the conversion can be dropped.
#[tokio::test]
async fn a_maker_asking_for_a_token_turns_the_accept_away_without_a_retry() {
    let h = Harness::new();
    {
        let mut state = h.world.set();
        state.accept_status = 401;
        state.accept_code = Some("tokenRequired");
    }
    let quoted = h.quote().await.unwrap();

    assert_eq!(
        h.accept(quoted.index).await.unwrap(),
        AcceptOutcome::TokensNeeded
    );
    assert_eq!(h.posted(&accept_path()), 1);
    let unauthorized = h.world.get().headers[&accept_path()]
        .iter()
        .all(|(name, _)| !name.eq_ignore_ascii_case("authorization"));
    assert!(unauthorized, "no token is held, so none is sent");
    let record = h.record();
    assert_eq!((record.outcome.clone(), record.t0), (None, None));

    // Accepting again posts the saved quote once more, for the same index.
    assert_eq!(
        h.accept(quoted.index).await.unwrap(),
        AcceptOutcome::TokensNeeded
    );
    assert_eq!(h.posted(&accept_path()), 2);
    assert_eq!(h.world.get().quote_requests.len(), 1);

    // Nothing opened: it can be abandoned.
    let abandoned = super::super::forward::abandon(
        &mut h.store(),
        h.chain(),
        &FakeClock(h.world.clone()),
        &h.account,
        quoted.index,
    )
    .await
    .unwrap();
    assert_eq!(
        abandoned.outcome,
        Some(ForwardOutcome::NothingSent {
            cause: NothingSentCause::MakerUnavailable
        })
    );
}

// ---- the deposit is never paid twice (AtomicSwapDriverTest) ----

#[tokio::test]
async fn an_interrupted_deposit_that_went_out_is_recorded_not_paid_again() {
    let h = Harness::new();
    h.accepted().await;
    h.started();
    h.world.set().created = Some(transaction("earlier"));

    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.deposits(), 0);
    assert_eq!(
        h.record().deposit.map(|deposit| deposit.tx_id),
        Some(tx_id("earlier"))
    );
    assert_eq!(
        h.submitted(),
        vec![tx_id("earlier")],
        "a deposit found again is sent again"
    );
}

#[tokio::test]
async fn an_interrupted_deposit_that_never_went_out_is_paid_once() {
    let h = Harness::new();
    h.accepted().await;
    h.started();

    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.deposits(), 1);
    assert_eq!(
        h.record().deposit.map(|deposit| deposit.tx_id),
        Some(tx_id("deposit1"))
    );
}

#[tokio::test]
async fn a_deposit_the_wallet_cannot_pay_leaves_nothing_attempted() {
    let h = Harness::new();
    h.accepted().await;
    h.world.set().unpayable = true;

    assert_eq!(code(h.advance().await), ErrorCode::DepositUnpayable);
    assert_eq!(h.record().deposit_progress(), DepositProgress::NotStarted);

    h.world.set().unpayable = false;
    {
        let mut state = h.world.set();
        state.chain_now = state.t0 - 60;
    }
    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::DepositWindowMissed)
    );
    assert_eq!(h.deposits(), 0);
}

#[tokio::test]
async fn a_deposit_is_sent_again_until_it_is_mined() {
    let h = Harness::new();
    h.deposited().await;
    h.advance().await.unwrap();
    assert_eq!(h.submitted(), vec![tx_id("deposit1"), tx_id("deposit1")]);

    h.world.set().statuses.insert(tx_id("deposit1"), mined(1));
    h.advance().await.unwrap();
    assert_eq!(h.submitted().len(), 2);
    assert_eq!(h.deposits(), 1);
}

#[tokio::test]
async fn an_expired_deposit_is_paid_again_only_while_payable() {
    let h = Harness::new();
    h.deposited().await;
    h.world
        .set()
        .statuses
        .insert(tx_id("deposit1"), SwapTxStatus::Expired);

    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.deposits(), 2);
    assert_eq!(
        h.record().deposit.map(|deposit| deposit.tx_id),
        Some(tx_id("deposit2"))
    );

    // Too close to t0: never paid again.
    {
        let mut state = h.world.set();
        state
            .statuses
            .insert(tx_id("deposit2"), SwapTxStatus::Expired);
        state.chain_now = state.t0 - 60;
    }
    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::DepositWindowMissed)
    );
    assert_eq!(h.deposits(), 2);
}

/// `t1` must leave the claim from `t0` the contract's least window, and no
/// more than two hours: the deposit waits on it until the maker refunds.
#[tokio::test]
async fn nothing_is_deposited_into_a_swap_whose_t1_is_too_close_or_too_far() {
    for (t1_after, payable) in [
        (30 * 60 - 1, false),
        (30 * 60, true),
        (2 * 60 * 60, true),
        (2 * 60 * 60 + 1, false),
    ] {
        let h = Harness::new();
        h.world.set().t1_after = t1_after;
        h.accepted().await;
        let step = h.advance().await.unwrap();
        if payable {
            assert_eq!(step, h.confirming(), "{t1_after}");
            assert_eq!(h.deposits(), 1);
        } else {
            assert_eq!(step, nothing_sent(NothingSentCause::Mismatch), "{t1_after}");
            assert_eq!(h.deposits(), 0);
        }
    }
}

/// The deposit's split: propose, keep `Started`, create, keep the bytes. A
/// crash at either save never leads to a second deposit.
#[tokio::test]
async fn a_crash_around_the_deposit_never_pays_it_twice() {
    // Before `Started` commits: the proposal is released, nothing created.
    let h = Harness::new();
    h.accepted().await;
    h.world.set().crash = Some(Crash::AfterPropose);
    assert_eq!(code(h.advance().await), ErrorCode::StoreUnreadable);
    assert_eq!(h.world.get().discarded, 1);
    assert_eq!(h.deposits(), 0);
    assert_eq!(h.record().deposit_progress(), DepositProgress::NotStarted);
    h.world.set().crash = None;
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.deposits(), 1);

    // Created, but its bytes never kept: found in the wallet and sent, never
    // built again.
    let h = Harness::new();
    h.accepted().await;
    h.world.set().crash = Some(Crash::AfterCreate);
    assert_eq!(code(h.advance().await), ErrorCode::StoreUnreadable);
    assert_eq!(h.record().deposit_progress(), DepositProgress::Started);
    assert!(h.submitted().is_empty());
    h.world.set().crash = None;
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.deposits(), 1);
    assert_eq!(h.world.get().discarded, 0);
    assert_eq!(
        h.record().deposit.map(|deposit| deposit.tx_id),
        Some(tx_id("deposit1"))
    );
    assert_eq!(h.submitted(), vec![tx_id("deposit1")]);
}

#[tokio::test]
async fn no_deposit_is_built_until_the_wallet_has_scanned_to_the_tip() {
    let h = Harness::new();
    h.accepted().await;
    h.world.set().synced = false;

    assert_eq!(
        h.advance().await.unwrap(),
        waiting(ForwardWait::ZcashSyncing)
    );
    assert_eq!(h.deposits(), 0);
    assert_eq!(h.record().deposit_progress(), DepositProgress::NotStarted);

    h.world.set().synced = true;
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.deposits(), 1);
}

#[tokio::test]
async fn nothing_is_deposited_into_a_swap_whose_terms_are_off_by_one_in_any_word() {
    for word in 0..11 {
        let h = Harness::new();
        h.accepted().await;
        h.world.set().tamper = Some(Box::new(move |words: &mut [[u8; 32]; 11]| {
            words[word][31] = words[word][31].wrapping_add(1);
        }));

        assert_eq!(
            h.advance().await.unwrap(),
            nothing_sent(NothingSentCause::Mismatch),
            "word {word}"
        );
        assert_eq!(h.deposits(), 0);
    }
}

#[tokio::test]
async fn a_silent_maker_is_claimed_from_once_t0_passes() {
    let h = Harness::new();
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.chain_now = state.t0;
        state.clock = state.t0;
    }

    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/claim"), 1);
}

// ---- the forward refund (AtomicSwapClaimTest) ----

#[tokio::test]
async fn a_refund_after_a_deposit_that_never_went_out_sweeps_nothing() {
    let h = Harness::new();
    h.accepted().await;
    h.started();
    h.refund();

    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::MakerCancelled)
    );
    assert!(h.world.get().sweeps.is_empty());
}

#[tokio::test]
async fn a_refund_after_an_expired_deposit_sweeps_nothing() {
    let h = Harness::new();
    h.deposited().await;
    h.world
        .set()
        .statuses
        .insert(tx_id("deposit1"), SwapTxStatus::Expired);
    h.refund();

    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::MakerCancelled)
    );
    assert!(h.world.get().sweeps.is_empty());
}

#[tokio::test]
async fn a_refund_waits_for_a_deposit_that_may_still_be_mined_without_sending_it() {
    let h = Harness::new();
    h.deposited().await;
    h.refund();

    assert_eq!(
        h.advance().await.unwrap(),
        waiting(ForwardWait::DepositUnsettled)
    );
    assert_eq!(h.submitted().len(), 1);
    assert!(h.world.get().sweeps.is_empty());
}

#[tokio::test]
async fn a_refund_after_an_interrupted_deposit_that_went_out_sweeps_it() {
    let h = Harness::new();
    h.accepted().await;
    h.started();
    {
        let mut state = h.world.set();
        state.created = Some(transaction("earlier"));
        state.statuses.insert(tx_id("earlier"), mined(5));
    }
    h.refund();

    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Refunding));
    h.world.set().statuses.insert(tx_id("sweep1"), mined(2));
    assert_eq!(
        h.advance().await.unwrap(),
        refunded("sweep1", RefundCause::MakerCancelled)
    );
    assert_eq!(h.world.get().sweeps.len(), 1);
}

#[tokio::test]
async fn a_refund_sweep_is_kept_before_it_is_sent_and_ends_only_with_its_confirmations() {
    let h = Harness::new();
    let record = h.mined_deposit().await;
    h.refund();

    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Refunding));
    assert_eq!(h.world.get().sweeps, vec![(record.index, ZCASH_HEIGHT)]);
    assert_eq!(
        h.record().sweep.map(|sweep| sweep.tx_id),
        Some(tx_id("sweep1"))
    );
    assert_eq!(h.submitted().last(), Some(&tx_id("sweep1")));

    h.world.set().statuses.insert(tx_id("sweep1"), mined(1));
    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Refunding));
    assert_eq!(h.world.get().forgotten, 0);

    h.world.set().statuses.insert(tx_id("sweep1"), mined(2));
    assert_eq!(
        h.advance().await.unwrap(),
        refunded("sweep1", RefundCause::MakerCancelled)
    );
    let state = h.world.get();
    assert_eq!(state.sweeps.len(), 1);
    assert_eq!(
        state.forgotten, 1,
        "the joint account goes once its sweep is final"
    );
}

#[tokio::test]
async fn an_expired_sweep_is_built_again() {
    let h = Harness::new();
    h.mined_deposit().await;
    h.refund();
    h.advance().await.unwrap();
    h.world
        .set()
        .statuses
        .insert(tx_id("sweep1"), SwapTxStatus::Expired);

    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Refunding));
    assert_eq!(
        h.record().sweep.map(|sweep| sweep.tx_id),
        Some(tx_id("sweep2"))
    );
    assert_eq!(h.world.get().forgotten, 0);
}

#[tokio::test]
async fn a_sweep_waits_until_the_refunded_deposit_is_spendable() {
    let h = Harness::new();
    h.mined_deposit().await;
    h.refund();
    h.world.set().spendable = false;

    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Refunding));
    assert_eq!(h.record().sweep, None);
}

/// A refund mined before t0 is the maker calling the swap off, one from t1
/// waited out the claim; without its event, the chain's time decides.
#[tokio::test]
async fn a_refund_from_t1_is_a_swap_nobody_claimed_in_time() {
    for (refunded_at, chain_now, cause) in [
        (
            Some(NOW + 60),
            NOW + 2 * 60 * 60,
            RefundCause::MakerCancelled,
        ),
        (
            Some(NOW + 35 * 60 + 60 * 60),
            NOW + 2 * 60 * 60,
            RefundCause::NotClaimedInTime,
        ),
        (None, NOW + 2 * 60 * 60, RefundCause::NotClaimedInTime),
        (None, NOW + 60, RefundCause::MakerCancelled),
    ] {
        let h = Harness::new();
        h.mined_deposit().await;
        h.refund();
        h.advance().await.unwrap();
        {
            let mut state = h.world.set();
            state.statuses.insert(tx_id("sweep1"), mined(2));
            state.refunded_at = refunded_at;
            state.chain_now = chain_now;
            state.clock = chain_now;
        }
        assert_eq!(
            h.advance().await.unwrap(),
            refunded("sweep1", cause),
            "{refunded_at:?}"
        );
    }
}

#[tokio::test]
async fn a_swap_left_under_the_same_id_by_an_earlier_use_of_the_index_is_never_paid() {
    let h = Harness::new();
    h.accepted().await;
    let other = zecswap_core::derive_maker_share(&[0x0b; 32], 0)
        .unwrap()
        .public()
        .to_affine_bytes();
    {
        let mut state = h.world.set();
        state.tamper = Some(Box::new(move |words: &mut [[u8; 32]; 11]| {
            words[3].copy_from_slice(&other[..32]);
            words[4].copy_from_slice(&other[32..]);
        }));
        state.stage = SwapStage::Claimed;
        state.paid_out = true;
    }

    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::Mismatch)
    );
    assert_eq!(h.record().payout_tx, None);
}

// ---- the claim's windows ----

fn unwinding(h: &Harness) -> ForwardStep {
    let state = h.world.get();
    ForwardStep::Waiting {
        wait: ForwardWait::Unwinding,
        t0: Some(state.t0),
        t1: Some(state.t1()),
    }
}

/// Both clocks move to `at`.
fn at(h: &Harness, at: u64) {
    let mut state = h.world.set();
    state.chain_now = at;
    state.clock = at;
}

#[tokio::test]
async fn the_share_stays_secret_when_railgun_is_not_taking_payouts() {
    let h = Harness::new();
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.railgun_accepts = false;
    }

    assert_eq!(code(h.advance().await), ErrorCode::RailgunClosed);
    assert_eq!(h.posted("/v1/claim"), 0);

    // A payout after a claim waits as well.
    let h = Harness::new();
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Claimed;
        state.railgun_accepts = false;
    }
    assert_eq!(code(h.advance().await), ErrorCode::RailgunClosed);
    assert_eq!(h.posted("/v1/payout"), 0);
}

/// Before t0 a ready counts once it is `READY_DEPTH_BLOCKS` deep: one a
/// reorg drops would leave the claim reverted with `z` public. From t0 an
/// open swap is claimed without one.
#[tokio::test]
async fn a_ready_is_claimed_on_before_t0_only_once_it_is_deep_enough() {
    let h = Harness::new();
    h.deposited().await;
    let head = h.world.get().head_number;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.ready_block = Some(head - READY_DEPTH_BLOCKS + 1);
    }
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.posted("/v1/claim"), 0);
    assert_eq!(h.record().payout, None, "nothing signed while it waits");

    h.world.set().ready_block = Some(head - READY_DEPTH_BLOCKS);
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/claim"), 1);

    // The same shallow ready from t0: no depth needed.
    let h = Harness::new();
    h.deposited().await;
    let t0 = h.world.get().t0;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.ready_block = Some(state.head_number);
    }
    at(&h, t0);
    assert_eq!(h.advance().await.unwrap(), paid());
}

/// Under the margin before t1 nothing is revealed, by the later of the
/// chain's and the device's clocks; between t1 and t1 + LATE the swap is the
/// maker's to refund; from t1 + LATE it is claimed after all.
#[tokio::test]
async fn the_claim_waits_out_the_margin_and_the_late_window_then_goes_for_good() {
    // Just inside the margin, it goes.
    let h = Harness::new();
    h.deposited().await;
    h.world.set().stage = SwapStage::Ready;
    let t1 = h.world.get().t1();
    at(&h, t1 - 301);
    assert_eq!(h.advance().await.unwrap(), paid());

    let h = Harness::new();
    h.deposited().await;
    h.world.set().stage = SwapStage::Ready;
    let ahead = Harness::new();
    ahead.deposited().await;
    ahead.world.set().stage = SwapStage::Ready;
    {
        // The chain at the margin's edge, the device a second past it.
        let mut state = ahead.world.set();
        state.chain_now = t1 - 400;
        state.clock = t1 - 300;
    }
    assert_eq!(ahead.advance().await.unwrap(), unwinding(&ahead));
    assert_eq!(ahead.posted("/v1/claim"), 0);

    at(&h, t1 - 300);
    assert_eq!(h.advance().await.unwrap(), unwinding(&h));
    for now in [t1, t1 + late_window() - 1] {
        at(&h, now);
        assert_eq!(h.advance().await.unwrap(), unwinding(&h), "{now}");
    }
    assert_eq!(h.posted("/v1/claim"), 0);
    assert!(!h.record().claim_posted);
    assert_eq!(h.record().payout, None);

    at(&h, t1 + late_window());
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/claim"), 1);

    // An open swap too: the late claim is the user's whether or not the
    // maker readied it.
    let h = Harness::new();
    h.deposited().await;
    let t1 = h.world.get().t1();
    at(&h, t1 + 10);
    assert_eq!(h.advance().await.unwrap(), unwinding(&h));
    at(&h, t1 + late_window());
    assert_eq!(h.advance().await.unwrap(), paid());
}

/// Once the maker refunds in the late window, the deposit comes home.
#[tokio::test]
async fn an_unwound_swap_brings_the_deposit_home_after_the_makers_refund() {
    let h = Harness::new();
    h.mined_deposit().await;
    let t1 = h.world.get().t1();
    at(&h, t1 + 60);
    assert_eq!(h.advance().await.unwrap(), unwinding(&h));

    h.refund();
    h.world.set().refunded_at = Some(t1 + 120);
    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Refunding));
    h.world.set().statuses.insert(tx_id("sweep1"), mined(2));
    assert_eq!(
        h.advance().await.unwrap(),
        refunded("sweep1", RefundCause::NotClaimedInTime)
    );
    assert_eq!(h.posted("/v1/claim"), 0);
}

#[tokio::test]
async fn the_share_stays_secret_through_a_node_minutes_behind() {
    let h = Harness::new();
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.clock = NOW + 4 * 60;
    }

    assert_eq!(code(h.advance().await), ErrorCode::ChainLagging);
    assert_eq!(h.posted("/v1/claim"), 0);

    // A device clock a minute and a half off still claims.
    let h = Harness::new();
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.clock = NOW + 90;
    }
    assert_eq!(h.advance().await.unwrap(), paid());
}

/// The window is read again, in one read, immediately before the claim is
/// posted: a window that shut, terms that changed, Railgun closing or a head
/// that fell behind meanwhile reveal nothing.
#[tokio::test]
async fn the_window_and_terms_are_read_again_immediately_before_the_reveal() {
    type Change = fn(&mut State);
    let changes: [(Change, std::result::Result<ForwardWait, ErrorCode>); 5] = [
        // The margin before t1 ran out.
        (
            |state| {
                state.chain_now = state.t1() - 300;
                state.clock = state.chain_now;
            },
            Ok(ForwardWait::Unwinding),
        ),
        // The maker refunded: the swap is shut.
        (
            |state| {
                state.stage = SwapStage::Refunded;
                state.secret = maker_secret().to_be_bytes();
            },
            Ok(ForwardWait::Confirming),
        ),
        // A payout commitment changed.
        (
            |state| {
                state.tamper = Some(Box::new(|words: &mut [[u8; 32]; 11]| {
                    words[10] = [6; 32];
                }))
            },
            Err(ErrorCode::Mismatch),
        ),
        (
            |state| state.railgun_accepts = false,
            Err(ErrorCode::RailgunClosed),
        ),
        (|state| state.clock += 4 * 60, Err(ErrorCode::ChainLagging)),
    ];
    for (change, expected) in changes {
        let h = Harness::new();
        h.deposited().await;
        {
            let mut state = h.world.set();
            state.stage = SwapStage::Ready;
            state.reads = 0;
            state.on_read = Some(Box::new(move |state: &mut State, read| {
                if read == 2 {
                    change(state);
                }
            }));
        }

        let step = h.advance().await;
        match expected {
            Ok(wait) => match step.unwrap() {
                ForwardStep::Waiting { wait: got, .. } => assert_eq!(got, wait),
                other => panic!("{other:?}"),
            },
            Err(error) => assert_eq!(code(step), error),
        }
        assert_eq!(h.posted("/v1/claim"), 0, "{expected:?}");
        assert!(!h.record().claim_posted);
    }
}

#[tokio::test]
async fn an_unconfirmed_open_is_neither_funded_nor_abandoned_after_the_quote_expires() {
    let h = Harness::new();
    let record = h.accepted().await;
    {
        let mut state = h.world.set();
        state.confirmed = Some(Box::new(|_| None));
        state.clock = record.quote.expires_at + 600;
    }

    assert_eq!(h.advance().await.unwrap(), waiting(ForwardWait::Opening));
    assert_eq!(h.deposits(), 0);
    assert_eq!(h.record().outcome, None);
}

/// A relayer that holds a claim back (`503`, its own send may still land)
/// gets the same claim again on the next step; nothing is signed anew.
#[tokio::test]
async fn a_held_back_claim_is_posted_again_unchanged() {
    let h = Harness::new();
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.claim_refusal = Some((503, "unavailable"));
    }
    assert_eq!(code(h.advance().await), ErrorCode::RelayerRefused);
    let held = h.record();
    assert!(held.claim_posted);
    let first = h.world.get().bodies["/v1/claim"].clone();

    h.world.set().claim_refusal = None;
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/claim"), 2);
    assert_eq!(h.world.get().bodies["/v1/claim"], first);
    assert_eq!(h.record().payout, held.payout);
}

// ---- the payout and its fee (AtomicSwapClaimTest, AtomicSwapSettlementTest) ----

/// Within its window the offer's fee is signed, though the relayer asks more
/// now; past it, the relayer's fee now.
#[tokio::test]
async fn a_claim_signs_the_offers_fee_within_its_window_and_the_relayers_after() {
    let h = Harness::new();
    h.world.set().fee_expires_at = Some(NOW + 3_600);
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.relayer_fee = 30_000;
        state.stage = SwapStage::Ready;
    }

    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.world.get().posted_fees, vec![20_000]);
    assert_eq!(h.record().receives, Amount(977_550));

    let h = Harness::new();
    h.world.set().fee_expires_at = Some(NOW + 3_600);
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.relayer_fee = 30_000;
        state.stage = SwapStage::Ready;
        state.clock = NOW + 3_600;
        state.chain_now = NOW + 3_600;
    }

    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.world.get().posted_fees, vec![30_000]);
    // What it kept: 1,000,000 less 30,000, less Railgun's 0.25 %.
    assert_eq!(h.record().receives, Amount(967_575));
}

/// A refused payout is signed again only when the relayer's fee rose, and is
/// kept before it is posted.
#[tokio::test]
async fn a_refused_payout_is_signed_again_only_at_a_higher_fee() {
    let h = Harness::new();
    h.world.set().fee_expires_at = Some(NOW + 3_600);
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.relayer_fee = 30_000;
        state.least_fee = 30_000;
        state.stage = SwapStage::Ready;
    }

    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.world.get().posted_fees, vec![20_000, 30_000]);
    assert_eq!(h.posted("/v1/claim"), 2);
    assert_eq!(
        h.record().payout.map(|payout| payout.fee),
        Some(Amount(30_000))
    );

    // Refused at the fee it asks now: not signed again.
    let h = Harness::new();
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.least_fee = 30_000;
        state.stage = SwapStage::Ready;
    }
    assert_eq!(code(h.advance().await), ErrorCode::RelayerRefused);
    assert_eq!(h.world.get().posted_fees, vec![20_000]);
    assert_eq!(
        h.record().payout.map(|payout| payout.fee),
        Some(Amount(20_000))
    );
    assert_eq!(h.record().outcome, None);
}

/// No payout is signed for more than 2 USDC, nor for a fee that leaves
/// nothing.
#[tokio::test]
async fn a_payout_is_never_signed_above_the_cap() {
    const CAP: u128 = 2_000_000;
    const AMOUNT_ABOVE_CAP: u128 = 5_000_000;

    // Quoted above the cap: refused before anything is accepted.
    let h = Harness::new();
    {
        let mut state = h.world.set();
        state.amount = AMOUNT_ABOVE_CAP;
        state.relayer_fee = CAP + 1;
    }
    assert_eq!(code(h.quote().await), ErrorCode::RelayerFee);

    // Asked above the cap at the claim: nothing signed or sent; it waits.
    let h = Harness::new();
    h.world.set().amount = AMOUNT_ABOVE_CAP;
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.relayer_fee = CAP + 1;
        state.stage = SwapStage::Ready;
    }
    assert_eq!(code(h.advance().await), ErrorCode::RelayerFee);
    assert_eq!(h.posted("/v1/claim"), 0);
    assert_eq!(h.record().payout, None);
    // At the cap, it is paid.
    h.world.set().relayer_fee = CAP;
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.world.get().posted_fees, vec![CAP]);

    // A refusal whose new fee is above the cap is not signed again.
    let h = Harness::new();
    h.world.set().amount = AMOUNT_ABOVE_CAP;
    h.deposited().await;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.least_fee = CAP + 1;
        state.reads = 0;
        // The relayer raises its fee as it turns the claim down.
        state.on_read = Some(Box::new(|state: &mut State, read| {
            if read == 2 {
                state.relayer_fee = CAP + 1;
            }
        }));
    }
    assert_eq!(code(h.advance().await), ErrorCode::RelayerFee);
    assert_eq!(h.world.get().posted_fees, vec![RELAYER_FEE]);
    assert_eq!(
        h.record().payout.map(|payout| payout.fee),
        Some(Amount(RELAYER_FEE))
    );

    // A fee that takes the whole amount: the swap is never started.
    let h = Harness::new();
    h.world.set().relayer_fee = AMOUNT;
    let quoted = h.quote().await.unwrap();
    assert_eq!(quoted.offer.receives, Amount(0));
    assert_eq!(code(h.accept(quoted.index).await), ErrorCode::RelayerFee);
    assert!(h.paths().iter().all(|path| !path.ends_with("/accept")));
}

#[tokio::test]
async fn a_claim_revealed_before_an_interruption_only_needs_its_payout() {
    let h = Harness::new();
    h.deposited().await;
    h.world.set().stage = SwapStage::Claimed;

    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.paths().last().map(String::as_str), Some("/v1/payout"));
    assert_eq!(h.posted("/v1/claim"), 0);
    assert_eq!(h.record().payout_tx, Some(Hex(word(0))));
}

#[tokio::test]
async fn an_orphaned_payout_is_retried_until_it_has_its_confirmations() {
    let h = Harness::new();
    let record = h.deposited().await;
    h.world.set().stage = SwapStage::Claimed;
    let without_payout = h.world.snapshot();
    h.world.set().confirmed = Some(Box::new(move |_| without_payout.clone()));

    assert_eq!(code(h.advance().await), ErrorCode::ChainLagging);
    assert!(
        h.world.get().paid_out,
        "the payout is at the tip, but not confirmed"
    );
    assert_eq!(h.record().outcome, None);

    // A reorg drops the first payout; it is sent again.
    {
        let mut state = h.world.set();
        state.paid_out = false;
        state.confirmed = None;
    }
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/payout"), 2);
    assert_eq!(h.record().deposit, record.deposit);
}

// ---- relayer claims ----

/// Accepted with relayer claims, its deposit out and its claim held.
async fn handed_over() -> Harness {
    let h = Harness::new();
    h.world.set().relayer_claims = true;
    h.deposited().await;
    assert_eq!(h.record().claim_hold, Some(ClaimHold::Held));
    h
}

fn holds(h: &Harness) -> Vec<serde_json::Value> {
    h.world.get().holds.clone()
}

/// Right after the deposit goes out, in the same step, the claim goes to the
/// relayer: `z` with the payout kept for it, under the swap's ticket. Once:
/// later steps, a ready swap included, never hand it over again, and the
/// app claims nothing of its own yet.
#[tokio::test]
async fn the_claim_is_handed_to_the_relayer_once_right_after_the_deposit() {
    let h = Harness::new();
    h.world.set().relayer_claims = true;
    let accepted = h.accepted().await;
    assert!(accepted.relayer_claims);
    assert_eq!(h.posted("/v1/claim/hold"), 0);

    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.submitted(), vec![tx_id("deposit1")]);
    assert_eq!(h.paths().last().map(String::as_str), Some("/v1/claim/hold"));
    let record = h.record();
    assert_eq!(record.claim_hold, Some(ClaimHold::Held));
    assert_eq!(record.phase(), ForwardPhase::Confirming);
    assert!(!record.claim_posted);
    let payout = record.payout.clone().unwrap();
    assert_eq!(payout.fee, Amount(RELAYER_FEE));
    {
        let state = h.world.get();
        let held = state.held.as_ref().unwrap();
        let z = h.keys.user_keys(0).unwrap().share.to_be_bytes();
        assert_eq!(held["secret"], format!("0x{}", hex::encode(z)));
        assert_eq!(held["swapId"], record.swap_id.to_hex());
        assert_eq!(held["payout"]["fee"], payout.fee.0.to_string());
        assert_eq!(held["payout"]["signature"], payout.signature.to_hex());
        let ticket = state.headers["/v1/claim/hold"]
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("zecswap-ticket"))
            .map(|(_, value)| value.clone());
        assert_eq!(
            ticket,
            record.ticket.as_ref().map(|ticket| ticket.0.clone())
        );
    }

    h.advance().await.unwrap();
    let head = h.world.get().head_number;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.ready_block = Some(head);
    }
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.posted("/v1/claim/hold"), 1);
    assert_eq!(h.posted("/v1/claim"), 0);
}

/// The payout and the hand-over are both kept before the claim is posted.
#[tokio::test]
async fn the_hand_over_is_kept_before_it_is_posted() {
    let h = Harness::new();
    h.world.set().relayer_claims = true;
    h.accepted().await;
    let kept: Rc<RefCell<Option<ForwardRecord>>> = Rc::default();
    {
        let dir = h.dir.path().to_owned();
        let account = h.account.clone();
        let kept = kept.clone();
        h.world.set().on_hold = Some(Box::new(move |_| {
            let found = SwapStore::open(&dir)
                .unwrap()
                .find(&account, Direction::Forward, 0)
                .unwrap();
            let Some(StoredRecord::Forward(record)) = found else {
                panic!("no record as the claim is posted");
            };
            *kept.borrow_mut() = Some(*record);
        }));
    }

    h.advance().await.unwrap();
    let kept = kept.borrow().clone().expect("the claim was handed over");
    assert_eq!(kept.claim_hold, Some(ClaimHold::Posted));
    let payout = kept.payout.expect("the payout was kept first");
    let posted = holds(&h)[0]["payout"].clone();
    assert_eq!(posted["fee"], payout.fee.0.to_string());
    assert_eq!(posted["signature"], payout.signature.to_hex());
}

/// No claim goes to the relayer before the deposit is out (a wallet still
/// scanning, a broadcast turned down), and none in manual mode, where the
/// claim goes as the window opens.
#[tokio::test]
async fn nothing_is_handed_over_before_the_deposit_is_out_nor_in_manual_mode() {
    let h = Harness::new();
    h.world.set().relayer_claims = true;
    h.accepted().await;
    h.world.set().synced = false;
    assert_eq!(
        h.advance().await.unwrap(),
        waiting(ForwardWait::ZcashSyncing)
    );
    {
        let mut state = h.world.set();
        state.synced = true;
        state.broadcast_fails = true;
    }
    assert_eq!(code(h.advance().await), ErrorCode::ZcashRejected);
    assert_eq!(h.deposits(), 1, "kept, not out");
    assert_eq!(h.posted("/v1/claim/hold"), 0);
    let record = h.record();
    assert_eq!((record.claim_hold, record.payout), (None, None));

    h.world.set().broadcast_fails = false;
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.posted("/v1/claim/hold"), 1);
    assert_eq!(h.record().claim_hold, Some(ClaimHold::Held));

    let h = Harness::new();
    h.deposited().await;
    let record = h.record();
    assert!(!record.relayer_claims);
    assert_eq!((record.claim_hold, record.payout), (None, None));
    let head = h.world.get().head_number;
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.ready_block = Some(head - READY_DEPTH_BLOCKS);
    }
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/claim/hold"), 0);
    assert_eq!(h.posted("/v1/claim"), 1);
}

/// A relayer without the endpoint, or one that turns the claim down, holds
/// nothing: the hand-over is declined, never posted again, and the app
/// claims as the window opens.
#[tokio::test]
async fn a_hand_over_turned_down_leaves_the_claim_to_the_app() {
    for (holds_claims, refusal) in [
        (false, None),
        (true, Some((400, "rejected"))),
        (true, Some((409, "conflict"))),
    ] {
        let h = Harness::new();
        {
            let mut state = h.world.set();
            state.relayer_claims = true;
            state.holds_claims = holds_claims;
            state.hold_refusal = refusal;
        }
        h.deposited().await;
        assert_eq!(
            h.record().claim_hold,
            Some(ClaimHold::Declined),
            "{refusal:?}"
        );
        h.advance().await.unwrap();
        assert_eq!(h.posted("/v1/claim/hold"), 1, "{refusal:?}");

        let head = h.world.get().head_number;
        {
            let mut state = h.world.set();
            state.stage = SwapStage::Ready;
            state.ready_block = Some(head - READY_DEPTH_BLOCKS);
        }
        assert_eq!(h.advance().await.unwrap(), paid(), "{refusal:?}");
        assert_eq!(h.posted("/v1/claim"), 1);
    }
}

/// A hand-over that got no answer goes again on the next step with the same
/// bytes, though the relayer asks more now; once held, never again.
#[tokio::test]
async fn a_hand_over_without_an_answer_goes_again_with_the_same_bytes() {
    let h = Harness::new();
    {
        let mut state = h.world.set();
        state.relayer_claims = true;
        state.fee_expires_at = Some(NOW + 60);
        state.unreachable = Some("/v1/claim/hold");
    }
    h.deposited().await;
    let first = h.record();
    assert_eq!(first.claim_hold, Some(ClaimHold::Posted));
    let sent = h.world.get().bodies["/v1/claim/hold"].clone();

    {
        let mut state = h.world.set();
        state.unreachable = None;
        state.relayer_fee = 30_000;
        state.pass(120);
    }
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.posted("/v1/claim/hold"), 2);
    assert_eq!(holds(&h), vec![sent]);
    let record = h.record();
    assert_eq!(record.claim_hold, Some(ClaimHold::Held));
    assert_eq!(record.payout, first.payout);

    h.advance().await.unwrap();
    assert_eq!(h.posted("/v1/claim/hold"), 2);
}

/// A hand-over turned down for its fee is signed again, once, at the higher
/// fee the relayer asks now, and kept before it goes; turned down at the fee
/// it asks, or asking above the cap, it is declined with nothing signed
/// again.
#[tokio::test]
async fn a_hand_over_refused_for_its_fee_is_signed_again_once_at_the_higher_fee() {
    let h = Harness::new();
    {
        let mut state = h.world.set();
        state.relayer_claims = true;
        state.fee_expires_at = Some(NOW + 3_600);
    }
    h.accepted().await;
    {
        let mut state = h.world.set();
        state.relayer_fee = 30_000;
        state.least_fee = 30_000;
    }
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    let fees: Vec<serde_json::Value> = holds(&h)
        .iter()
        .map(|hold| hold["payout"]["fee"].clone())
        .collect();
    assert_eq!(fees, ["20000", "30000"]);
    let record = h.record();
    assert_eq!(record.claim_hold, Some(ClaimHold::Held));
    assert_eq!(record.payout.map(|payout| payout.fee), Some(Amount(30_000)));

    const CAP: u128 = 2_000_000;
    for (amount, asked) in [(AMOUNT, RELAYER_FEE), (5_000_000, CAP + 1)] {
        let h = Harness::new();
        {
            let mut state = h.world.set();
            state.relayer_claims = true;
            state.amount = amount;
            state.fee_expires_at = Some(NOW + 3_600);
        }
        h.accepted().await;
        {
            let mut state = h.world.set();
            state.least_fee = RELAYER_FEE + 1;
            state.relayer_fee = asked;
        }
        assert_eq!(h.advance().await.unwrap(), h.confirming(), "{asked}");
        assert_eq!(holds(&h).len(), 1, "{asked}");
        let record = h.record();
        assert_eq!(record.claim_hold, Some(ClaimHold::Declined));
        assert_eq!(
            record.payout.map(|payout| payout.fee),
            Some(Amount(RELAYER_FEE))
        );
    }
}

/// The app leaves the relayer the window's first minute: a ready before t0
/// five blocks past its depth, an open swap a minute after t0, a late claim
/// a minute after t1 + LATE. Then it claims itself, with the payout it
/// handed over.
#[tokio::test]
async fn the_app_claims_a_minute_into_a_window_the_relayer_left_open() {
    let h = handed_over().await;
    let handed = h.record().payout;
    let head = h.world.get().head_number;
    for depth in [
        READY_DEPTH_BLOCKS,
        READY_DEPTH_BLOCKS + RELAYER_CLAIM_WAIT_BLOCKS - 1,
    ] {
        {
            let mut state = h.world.set();
            state.stage = SwapStage::Ready;
            state.ready_block = Some(head - depth);
        }
        assert_eq!(h.advance().await.unwrap(), h.confirming(), "{depth}");
    }
    assert_eq!(h.posted("/v1/claim"), 0);
    h.world.set().ready_block = Some(head - READY_DEPTH_BLOCKS - RELAYER_CLAIM_WAIT_BLOCKS);
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/claim"), 1);
    let ended = h.record();
    assert!(ended.claim_posted);
    assert_eq!(ended.payout, handed);

    let h = handed_over().await;
    let t0 = h.world.get().t0;
    for now in [t0, t0 + RELAYER_CLAIM_WAIT_SECONDS - 1] {
        at(&h, now);
        assert_eq!(h.advance().await.unwrap(), h.confirming(), "{now}");
    }
    assert_eq!(h.posted("/v1/claim"), 0);
    at(&h, t0 + RELAYER_CLAIM_WAIT_SECONDS);
    assert_eq!(h.advance().await.unwrap(), paid());

    let h = handed_over().await;
    let late = h.world.get().t1() + late_window();
    for now in [late, late + RELAYER_CLAIM_WAIT_SECONDS - 1] {
        at(&h, now);
        assert_eq!(h.advance().await.unwrap(), unwinding(&h), "{now}");
    }
    assert_eq!(h.posted("/v1/claim"), 0);
    at(&h, late + RELAYER_CLAIM_WAIT_SECONDS);
    assert_eq!(h.advance().await.unwrap(), paid());
}

/// A hand-over that got no answer may still be held: the app leaves the
/// relayer its minute all the same.
#[tokio::test]
async fn a_hand_over_without_an_answer_still_leaves_the_relayer_its_minute() {
    let h = Harness::new();
    {
        let mut state = h.world.set();
        state.relayer_claims = true;
        state.unreachable = Some("/v1/claim/hold");
    }
    h.deposited().await;
    let t0 = h.world.get().t0;
    at(&h, t0);
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    assert_eq!(h.posted("/v1/claim"), 0);
    at(&h, t0 + RELAYER_CLAIM_WAIT_SECONDS);
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/claim"), 1);
}

/// A claim the relayer landed, with its payout, finishes the bridge on the
/// payout's event, the app posting nothing; one landed without its payout
/// gets the payout the app handed over.
#[tokio::test]
async fn a_claim_the_relayer_landed_finishes_the_bridge() {
    let h = handed_over().await;
    h.relayer_sends_held_claim();
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/claim"), 0);
    assert_eq!(h.posted("/v1/payout"), 0);
    let ended = h.record();
    assert_eq!(ended.outcome, Some(ForwardOutcome::Paid));
    assert_eq!(ended.payout_tx, Some(Hex(word(2))));
    assert_eq!(ended.receives, Amount(977_550));
    assert!(!ended.claim_posted);

    let h = handed_over().await;
    let handed = h.record().payout.unwrap();
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Claimed;
    }
    assert_eq!(h.advance().await.unwrap(), paid());
    assert_eq!(h.posted("/v1/claim"), 0);
    assert_eq!(h.posted("/v1/payout"), 1);
    assert_eq!(
        h.world.get().bodies["/v1/payout"]["signature"],
        handed.signature.to_hex()
    );
}

// ---- the deployment ----

/// A maker or relayer that names other windows, or another kind of
/// contract, serves another deployment: nothing is paid into its swaps.
/// A paid swap's payout Railgun sent back to its vault is listed, and
/// rescued, only once the vault holds more than the relayer's fee; a rescue
/// keeps the contract's nonce and its deadline exactly, is kept before it is
/// sent, leaves the swap paid, and the next takes the next nonce. A swap the
/// chain does not show paid out is never rescued.
#[tokio::test]
async fn a_returned_payout_is_rescued_only_from_a_vault_holding_more_than_the_fee() {
    let h = Harness::new();
    h.accepted().await;
    assert_eq!(h.advance().await.unwrap(), h.confirming());
    h.world.set().stage = SwapStage::Ready;
    assert_eq!(h.advance().await.unwrap(), paid());
    let record = h.record();

    // A vault holding no more than the fee: nothing listed, nothing signed
    // or sent.
    for vault in [0, RELAYER_FEE] {
        h.world.set().vault = vault;
        assert_eq!(
            h.forward_view().returned_payouts(&h.store()).await.unwrap(),
            vec![]
        );
        h.forward().rescue(&mut h.store(), 0).await.unwrap();
        assert_eq!(h.record().rescue, None);
    }
    assert_eq!(h.posts("/v1/rescue"), 0);

    // More: listed with what it holds, then rescued under the contract's
    // nonce, kept exactly before it is sent.
    {
        let mut state = h.world.set();
        state.vault = 900_000;
        state.rescue_nonce = 7;
    }
    assert_eq!(
        h.forward_view().returned_payouts(&h.store()).await.unwrap(),
        vec![ReturnedPayout {
            index: 0,
            held: 900_000,
            fee: Amount(RELAYER_FEE),
        }]
    );
    let rescued = h.forward().rescue(&mut h.store(), 0).await.unwrap();
    let rescue = rescued.rescue.clone().unwrap();
    assert_eq!(rescue.nonce, 7);
    assert_eq!(rescue.fee, Amount(RELAYER_FEE));
    assert_eq!(rescue.deadline, h.world.get().chain_now + 120);
    let digest = pins().domain().unwrap().rescue(
        &record.swap_id.0,
        &h.keys.note(0).unwrap().commitment(),
        &pins().relayer,
        RELAYER_FEE,
        zecswap_core::RescueAuthorization {
            nonce: 7,
            deadline: rescue.deadline,
        },
    );
    assert_eq!(
        zecswap_core::signer(&digest, &rescue.signature.0),
        Some(h.keys.auth_address(0).unwrap())
    );
    let state = h.world.get();
    assert_eq!(state.bodies["/v1/rescue"]["nonce"], 7);
    assert_eq!(
        state.bodies["/v1/rescue"]["swapId"],
        record.swap_id.to_hex()
    );
    drop(state);
    assert_eq!(rescued.outcome, Some(ForwardOutcome::Paid));
    assert_eq!(h.posts("/v1/rescue"), 1);
    assert_eq!(h.store().unfinished_count(&h.account).unwrap(), 0);

    // The next takes the next nonce.
    h.world.set().rescue_nonce = 8;
    let again = h.forward().rescue(&mut h.store(), 0).await.unwrap();
    assert_eq!(again.rescue.unwrap().nonce, 8);
    assert_eq!(h.posts("/v1/rescue"), 2);

    // A chain that does not show the payout: nothing is signed.
    h.world.set().paid_out = false;
    assert_eq!(
        code(h.forward().rescue(&mut h.store(), 0).await),
        ErrorCode::Mismatch
    );
    assert_eq!(h.posts("/v1/rescue"), 2);
}

#[tokio::test]
async fn services_naming_other_windows_are_refused() {
    let h = Harness::new();
    h.world.set().accepted_late_window = Some(24 * 60 * 60);
    assert_eq!(
        h.accept(h.quote().await.unwrap().index).await.unwrap(),
        AcceptOutcome::NothingSent(NothingSentCause::Mismatch)
    );
    assert_eq!(
        h.advance().await.unwrap(),
        nothing_sent(NothingSentCause::Mismatch)
    );
    assert_eq!(h.deposits(), 0);

    for windows in [
        serde_json::json!({ "minWindow": 3_600 }),
        serde_json::json!({ "lateWindow": 24 * 60 * 60 }),
        serde_json::json!({ "contractKind": "locks" }),
    ] {
        let h = Harness::new();
        h.world.set().terms_windows = Some(windows.clone());
        assert_eq!(
            code(h.quote().await),
            ErrorCode::WrongDeployment,
            "terms {windows}"
        );
        let h = Harness::new();
        h.world.set().info_windows = Some(windows.clone());
        assert_eq!(
            code(h.quote().await),
            ErrorCode::WrongDeployment,
            "info {windows}"
        );
        assert_eq!(h.posted("/v1/quote"), 0, "info {windows}");
    }
    let pinned = serde_json::json!({
        "minWindow": 30 * 60,
        "lateWindow": late_window(),
        "contractKind": "windows",
    });
    let h = Harness::new();
    h.world.set().terms_windows = Some(pinned.clone());
    h.world.set().info_windows = Some(pinned);
    assert!(h.quote().await.is_ok());
}

// ---- one driver step per account ----

/// An advance while an accept is in flight gets `Busy`; the accept's `t0`
/// and ticket are never overwritten.
#[tokio::test]
async fn a_concurrent_advance_and_accept_on_one_account_gives_busy_and_leaves_the_record_intact() {
    let h = Harness::new();
    let quoted = h.quote().await.unwrap();
    let release = Arc::new(Notify::new());
    h.world.set().hold_accept = Some(release.clone());

    let accept = async {
        let _driver = engine::lock_account(&h.account).unwrap();
        h.accept(quoted.index).await
    };
    let advance = async {
        while h.posted(&accept_path()) == 0 {
            tokio::task::yield_now().await;
        }
        let busy = engine::lock_account(&h.account)
            .err()
            .map(|error| error.code);
        let during = h.record();
        release.notify_one();
        (busy, during)
    };
    let (accepted, (busy, during)) = tokio::join!(accept, advance);

    assert_eq!(busy, Some(ErrorCode::Busy));
    assert_eq!(during.t0, None, "saved before the share left the device");
    assert_eq!(accepted.unwrap(), AcceptOutcome::Accepted);
    let record = h.record();
    assert_eq!(record.t0, Some(h.world.get().t0));
    assert!(record.ticket.is_some());
    // Released with the accept: the next step runs.
    let _driver = engine::lock_account(&h.account).unwrap();
    assert_eq!(h.advance().await.unwrap(), h.confirming());
}
