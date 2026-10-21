//! The reverse conversion's fund-safety rules on fakes, one test per rule,
//! and the `openReverse` calldata byte for byte.

use std::sync::Arc;

use tokio::sync::Notify;
use zecswap_core::{Domain, PublicShare, RescueAuthorization, ReverseOpen};

use super::super::abi::address_word;
use super::super::engine;
use super::super::evm_rpc::{SwapStage, TransactionStatus};
use super::super::funding_calls;
use super::super::joint::SwapTxStatus;
use super::super::models::{
    Direction, Hex, NothingSentCause, ReverseFundingTransaction, ReversePhase,
    ReverseReceiveEstimate, ReverseRecord, StoredRecord,
};
use super::super::reverse::ReverseAccept;
use super::super::terms;
use super::super::ErrorCode;
use super::fakes::*;
use super::{bytes, text, vectors};

fn hex0x(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

fn uint_word(value: u128) -> [u8; 32] {
    let mut word = [0u8; 32];
    word[16..].copy_from_slice(&value.to_be_bytes());
    word
}

/// Argument word `index` of a call's data.
fn argument(data: &[u8], index: usize) -> [u8; 32] {
    data[4 + 32 * index..4 + 32 * (index + 1)]
        .try_into()
        .unwrap()
}

/// Funded, with the escrow open on chain and no `ready` signed.
async fn escrowed() -> Harness {
    let h = Harness::new();
    h.prepared().await;
    h.fund().await.unwrap();
    h.funded();
    h
}

/// Escrowed, the maker's ZEC in, and `ready` authorized and handed out; the
/// escrow is still open.
async fn authorized() -> Harness {
    let h = escrowed().await;
    h.world.set().paid_in = REVERSE_DEPOSIT_ZAT;
    h.advance_reverse().await.unwrap();
    h.reverse()
        .authorize_ready(&mut h.store(), 0)
        .await
        .unwrap();
    h
}

impl Harness {
    /// Replaces the kept reverse record, as an earlier run left it.
    fn keep_reverse(&self, record: ReverseRecord) {
        self.store()
            .update(&self.account, &StoredRecord::Reverse(Box::new(record)))
            .unwrap();
    }
}

/// A funding whose answer was lost is never proved again: the kept bytes go
/// again only while the node does not know them, before the funding deadline
/// and while the user has not called the conversion off, and the hash a
/// resend gets back is kept.
#[tokio::test]
async fn a_lost_funding_answer_is_sent_again_only_while_the_node_does_not_know_it() {
    let h = Harness::new();
    h.prepared().await;
    // The answer is lost; the funding was kept before it went out.
    h.world.set().unreachable = Some("/v1/reverse/fund");
    assert!(h.fund().await.is_err());
    let kept = h.reverse_record(0).funding.unwrap();
    assert_eq!(kept.tx_id, None);
    assert_eq!(h.reverse_record(0).phase, ReversePhase::SendingUsdc);

    // Paying again, after a restart, proves nothing: the kept bytes go again,
    // and the hash they come back with is kept.
    h.world.set().unreachable = None;
    let resent = h.fund().await.unwrap();
    assert_eq!(h.world.get().proofs, 1);
    assert_eq!(resent.phase, ReversePhase::ConfirmingEscrow);
    assert_eq!(
        resent.funding,
        Some(ReverseFundingTransaction {
            tx_id: Some(Hex(word(8))),
            ..kept
        })
    );
    {
        let state = h.world.get();
        assert_eq!(state.fundings.len(), 2);
        assert_eq!(state.fundings[0], state.fundings[1], "the same bytes");
    }

    // Known to the node: followed, never sent again.
    for status in [TransactionStatus::Pending, TransactionStatus::Confirmed] {
        h.world.set().funding_status = status;
        let followed = h.advance_reverse().await.unwrap();
        assert_eq!(followed.phase, ReversePhase::ConfirmingEscrow);
    }
    assert_eq!(h.world.get().fundings.len(), 2);
    // Unknown to it: sent again before the deadline, never at or after it.
    h.world.set().funding_status = TransactionStatus::Unknown;
    h.advance_reverse().await.unwrap();
    assert_eq!(h.world.get().fundings.len(), 3);
    let to_deadline = FUNDING - h.world.get().chain_now;
    h.world.set().pass(to_deadline);
    h.advance_reverse().await.unwrap();
    assert_eq!(h.world.get().fundings.len(), 3);
    // Long past it, no escrow is coming: called off, and the joint account
    // goes.
    h.world.set().pass(10 * 60 + 1);
    let ended = h.advance_reverse().await.unwrap();
    assert_eq!(ended.phase, ReversePhase::Cancelled);
    assert_eq!(h.world.get().forgotten, 1);
    assert_eq!(h.world.get().fundings.len(), 3);

    // Called off by the user: never sent again.
    let h = Harness::new();
    h.prepared().await;
    h.fund().await.unwrap();
    h.advance_reverse().await.unwrap();
    assert_eq!(h.world.get().fundings.len(), 2);
    let cancelled = h.reverse().cancel(&mut h.store(), 0).await.unwrap();
    assert_eq!(cancelled.phase, ReversePhase::RefundWait);
    h.advance_reverse().await.unwrap();
    assert_eq!(h.world.get().fundings.len(), 2);
    assert_eq!(h.reverse_record(0).phase, ReversePhase::RefundWait);
}

/// A funding's answer that comes back after the user called the conversion
/// off keeps the cancel and the funding's hash. The driver lock spans the
/// post, so a cancel waits for it; and a cancel while the page proves means
/// the proof is never sent.
#[tokio::test]
async fn a_late_funding_answer_keeps_the_users_cancel() {
    let h = Harness::new();
    h.prepared().await;
    let release = Arc::new(Notify::new());
    h.world.set().hold_fund = Some(release.clone());
    let funding = async {
        let _driver = engine::lock_account(&h.account).unwrap();
        h.fund().await
    };
    let cancel = async {
        while h.world.get().fundings.is_empty() {
            tokio::task::yield_now().await;
        }
        // The funding is kept and out; a cancel waits for its answer...
        let busy = engine::lock_account(&h.account)
            .err()
            .map(|error| error.code);
        // ...and one kept meanwhile stays when the answer comes back.
        let mut record = h.reverse_record(0);
        assert!(record.funding.is_some());
        record.cancel_requested = true;
        record.phase = ReversePhase::RefundWait;
        h.store()
            .update(&h.account, &StoredRecord::Reverse(Box::new(record)))
            .unwrap();
        release.notify_one();
        busy
    };
    let (funded, busy) = tokio::join!(funding, cancel);
    assert_eq!(busy, Some(ErrorCode::Busy));
    funded.unwrap();
    let record = h.reverse_record(0);
    assert!(record.cancel_requested);
    assert_eq!(record.phase, ReversePhase::RefundWait);
    assert_eq!(record.funding.unwrap().tx_id, Some(Hex(word(8))));
    assert_eq!(record.ready, None);

    // Called off while the page proves: the proof is never sent.
    let h = Harness::new();
    h.prepared().await;
    let request = h
        .reverse()
        .funding_request(&mut h.store(), 0, &h.keys.railgun_address().unwrap())
        .await
        .unwrap();
    let cancelled = h.reverse().cancel(&mut h.store(), 0).await.unwrap();
    assert_eq!(cancelled.phase, ReversePhase::Cancelled);
    let proved = h.prove(&request);
    let refused = h
        .reverse()
        .view()
        .submit_funding(&mut h.store(), 0, proved)
        .await
        .unwrap_err();
    assert_eq!(refused.code, ErrorCode::Cancelled);
    assert_eq!(h.reverse_record(0).funding, None);
    assert!(h.world.get().fundings.is_empty());
}

/// `ready` is the user's second approval: the engine never signs it, a kept
/// one is only sent again while it holds, and never signed again.
#[tokio::test]
async fn ready_is_signed_only_by_the_user_and_never_again_after_a_restart() {
    let h = Harness::new();
    h.prepared().await;
    h.fund().await.unwrap();
    h.funded();
    h.world.set().paid_in = REVERSE_DEPOSIT_ZAT;
    // Restarted and advanced again and again: the app never signs it.
    for _ in 0..3 {
        let waiting = h.advance_reverse().await.unwrap();
        assert_eq!(waiting.phase, ReversePhase::AwaitingReady);
    }
    assert_eq!(h.reverse_record(0).ready, None);
    assert_eq!(h.posts("/v1/reverse/ready"), 0);

    // The user authorizes it: signed by the swap's key, kept, then sent.
    let settling = h
        .reverse()
        .authorize_ready(&mut h.store(), 0)
        .await
        .unwrap();
    assert_eq!(settling.phase, ReversePhase::Settling);
    let ready = settling.ready.clone().unwrap();
    assert_eq!(ready.deadline, h.world.get().chain_now + 120);
    let digest = pins()
        .domain()
        .unwrap()
        .ready(&settling.swap_id.0, ready.deadline);
    assert_eq!(
        zecswap_core::signer(&digest, &ready.signature.0),
        Some(h.keys.auth_address(0).unwrap())
    );
    assert_eq!(h.posts("/v1/reverse/ready"), 1);

    // Authorized again, as after a restart: sent again as kept.
    h.reverse()
        .authorize_ready(&mut h.store(), 0)
        .await
        .unwrap();
    assert_eq!(h.reverse_record(0).ready, Some(ready.clone()));
    assert_eq!(h.posts("/v1/reverse/ready"), 2);
    assert_eq!(
        h.world.get().bodies["/v1/reverse/ready"]["signature"],
        ready.signature.to_hex()
    );

    // Lapsed: neither sent nor signed again; called off, the refund goes on
    // without it, the chain being past its deadline.
    h.world.set().pass(121);
    let lapsed = h.advance_reverse().await.unwrap();
    assert_eq!(lapsed.phase, ReversePhase::RefundWait);
    h.reverse().cancel(&mut h.store(), 0).await.unwrap();
    assert_eq!(h.posts("/v1/reverse/refund"), 1);
    // Posted again, the same, until it lands; the ready never again.
    h.advance_reverse().await.unwrap();
    assert_eq!(h.posts("/v1/reverse/refund"), 2);
    assert_eq!(h.posts("/v1/reverse/ready"), 2);
    assert_eq!(h.reverse_record(0).ready, Some(ready));
}

/// Once a refund was posted no `ready` is signed, nor a kept one sent again:
/// landing first, it would revert the refund with `z` public.
#[tokio::test]
async fn no_ready_is_signed_or_sent_after_a_refund_was_posted() {
    let h = escrowed().await;
    h.world.set().paid_in = REVERSE_DEPOSIT_ZAT;
    assert_eq!(
        h.advance_reverse().await.unwrap().phase,
        ReversePhase::AwaitingReady
    );
    let mut record = h.reverse_record(0);
    record.refund_posted = true;
    h.keep_reverse(record);
    let refused = h
        .reverse()
        .authorize_ready(&mut h.store(), 0)
        .await
        .unwrap_err();
    assert_eq!(refused.code, ErrorCode::TooLate);
    assert_eq!(h.reverse_record(0).ready, None);
    assert_eq!(h.posts("/v1/reverse/ready"), 0);

    let h = authorized().await;
    assert_eq!(h.posts("/v1/reverse/ready"), 1);
    let mut record = h.reverse_record(0);
    record.refund_posted = true;
    h.keep_reverse(record);
    h.advance_reverse().await.unwrap();
    assert_eq!(h.posts("/v1/reverse/ready"), 1);
}

/// `ready` is offered only while its signature's deadline falls before t0,
/// by the chain's clock, from when no ready lands.
#[tokio::test]
async fn ready_is_signed_only_with_its_deadline_before_t0() {
    let h = escrowed().await;
    h.world.set().paid_in = REVERSE_DEPOSIT_ZAT;
    h.advance_reverse().await.unwrap();
    let to_cutoff = READY - 120 - h.world.get().chain_now;
    h.world.set().pass(to_cutoff);
    let refused = h
        .reverse()
        .authorize_ready(&mut h.store(), 0)
        .await
        .unwrap_err();
    assert_eq!(refused.code, ErrorCode::TooLate);
    assert_eq!(h.posts("/v1/reverse/ready"), 0);

    let h = escrowed().await;
    h.world.set().paid_in = REVERSE_DEPOSIT_ZAT;
    h.advance_reverse().await.unwrap();
    let to_cutoff = READY - 121 - h.world.get().chain_now;
    h.world.set().pass(to_cutoff);
    let settling = h
        .reverse()
        .authorize_ready(&mut h.store(), 0)
        .await
        .unwrap();
    assert_eq!(settling.ready.unwrap().deadline, READY - 1);
}

/// The sweep home pays at most the fee the user reviewed with `ready`,
/// however the estimate moved since; it is kept before it is first sent,
/// sent again unchanged, and built anew only once proven expired.
#[tokio::test]
async fn the_sweep_home_pays_no_more_than_the_reviewed_fee() {
    let h = Harness::new();
    h.prepared().await;
    h.fund().await.unwrap();
    h.funded();
    {
        let mut state = h.world.set();
        state.paid_in = REVERSE_DEPOSIT_ZAT;
        state.sweep_fee = 15_000;
    }
    h.advance_reverse().await.unwrap();
    h.reverse()
        .authorize_ready(&mut h.store(), 0)
        .await
        .unwrap();
    let reviewed = ReverseReceiveEstimate {
        available_zat: REVERSE_DEPOSIT_ZAT,
        fee_zat: 15_000,
    };
    assert_eq!(h.reverse_record(0).receive_estimate, Some(reviewed));

    // Fees rose since: a sweep would pay more, so none is built or sent.
    {
        let mut state = h.world.set();
        state.sweep_fee = 30_000;
        state.sweep_pays = 20_000;
    }
    h.claimed();
    assert!(h.advance_reverse().await.is_err());
    let settled = h.reverse_record(0);
    assert_eq!(settled.phase, ReversePhase::Receiving);
    assert_eq!(settled.receive, None);
    assert!(h.world.get().submitted.is_empty());

    // Within it: built, kept, then sent; sent again unchanged; built anew
    // only once proven expired.
    h.world.set().sweep_pays = 15_000;
    h.advance_reverse().await.unwrap();
    let receive = h.reverse_record(0).receive.unwrap();
    assert_eq!(receive.fee_zat, 15_000);
    assert_eq!(receive.received_zat, REVERSE_DEPOSIT_ZAT - 15_000);
    h.advance_reverse().await.unwrap();
    assert_eq!(h.reverse_record(0).receive, Some(receive.clone()));
    assert_eq!(
        h.world.get().submitted,
        vec![receive.tx_id.clone(), receive.tx_id.clone()]
    );
    h.world
        .set()
        .statuses
        .insert(receive.tx_id.clone(), SwapTxStatus::Expired);
    h.advance_reverse().await.unwrap();
    let rebuilt = h.reverse_record(0).receive.unwrap();
    assert_ne!(rebuilt.tx_id, receive.tx_id);
    assert_eq!(h.world.get().receive_caps, vec![Some(15_000); 3]);

    // At its confirmations: complete, and the joint account goes.
    h.world
        .set()
        .statuses
        .insert(rebuilt.tx_id.clone(), mined(2));
    let complete = h.advance_reverse().await.unwrap();
    assert_eq!(complete.phase, ReversePhase::Complete);
    assert_eq!(complete.receive_confirmations, 2);
    assert_eq!(h.world.get().forgotten, 1);
}

/// `z` is revealed to refund an open escrow only once no `ready` of ours can
/// land, the chain past its deadline; a ready one only from t1. Judged on one
/// consistent read, again immediately before the reveal, and never through a
/// node minutes behind; the refund is kept as posted before it goes.
#[tokio::test]
async fn the_refund_secret_is_revealed_only_once_no_ready_of_ours_can_land() {
    // Open, no ready signed: called off, the refund goes at once.
    let h = escrowed().await;
    let cancelled = h.reverse().cancel(&mut h.store(), 0).await.unwrap();
    assert_eq!(cancelled.phase, ReversePhase::Refunding);
    assert!(cancelled.refund_posted);
    assert_eq!(h.posts("/v1/reverse/refund"), 1);
    let payout = cancelled.payout.unwrap();
    let z = h.keys.user_keys(0).unwrap().share.to_be_bytes();
    {
        let state = h.world.get();
        let posted = &state.bodies["/v1/reverse/refund"];
        assert_eq!(posted["secret"], hex0x(&z));
        assert_eq!(posted["payout"]["signature"], payout.signature.to_hex());
    }

    // A ready handed out: the refund waits until the chain is past its
    // deadline.
    let h = authorized().await;
    let deadline = h.reverse_record(0).ready.unwrap().deadline;
    let waiting = h.reverse().cancel(&mut h.store(), 0).await.unwrap();
    assert_eq!(waiting.phase, ReversePhase::RefundWait);
    let to_deadline = deadline - h.world.get().chain_now;
    h.world.set().pass(to_deadline);
    h.advance_reverse().await.unwrap();
    assert_eq!(h.posts("/v1/reverse/refund"), 0);
    let held = h.reverse_record(0);
    assert!(!held.refund_posted);
    assert_eq!(held.payout, None, "nothing signed while it waits");
    h.world.set().pass(1);
    h.advance_reverse().await.unwrap();
    assert_eq!(h.posts("/v1/reverse/refund"), 1);

    // Ready: the maker's to claim until t1, then the user's to refund.
    let h = authorized().await;
    h.world.set().stage = SwapStage::Ready;
    h.reverse().cancel(&mut h.store(), 0).await.unwrap();
    assert_eq!(h.reverse_record(0).phase, ReversePhase::RefundWait);
    let to_t1 = REFUND - 1 - h.world.get().chain_now;
    h.world.set().pass(to_t1);
    h.advance_reverse().await.unwrap();
    assert_eq!(h.posts("/v1/reverse/refund"), 0);
    h.world.set().pass(1);
    h.advance_reverse().await.unwrap();
    assert_eq!(h.posts("/v1/reverse/refund"), 1);

    // Claimed or readied while the reveal is prepared: nothing revealed.
    type Change = fn(&mut State);
    let changes: [Change; 2] = [
        |state| {
            state.stage = SwapStage::Claimed;
            state.secret = maker_secret().to_be_bytes();
        },
        |state| state.stage = SwapStage::Ready,
    ];
    for change in changes {
        let h = escrowed().await;
        {
            let mut state = h.world.set();
            state.reads = 0;
            state.on_read = Some(Box::new(move |state: &mut State, read| {
                if read == 2 {
                    change(state);
                }
            }));
        }
        h.reverse().cancel(&mut h.store(), 0).await.unwrap();
        assert_eq!(h.posts("/v1/reverse/refund"), 0);
        assert!(!h.reverse_record(0).refund_posted);
    }

    // A node minutes behind this device's clock is not trusted with it.
    let h = escrowed().await;
    let now = h.world.get().chain_now;
    h.world.set().clock = now + 4 * 60;
    let lagging = h.reverse().cancel(&mut h.store(), 0).await.unwrap_err();
    assert_eq!(lagging.code, ErrorCode::ChainLagging);
    assert_eq!(h.posts("/v1/reverse/refund"), 0);
    h.world.set().clock = now + 90;
    h.advance_reverse().await.unwrap();
    assert_eq!(h.posts("/v1/reverse/refund"), 1);
}

/// A quote whose deadlines leave less than the contract's least window from
/// funding to t0, or from t0 to t1, would never open: refused at quote.
#[tokio::test]
async fn a_reverse_quote_leaving_less_than_the_contracts_window_is_refused() {
    for (ready, refund, quoted) in [
        (FUNDING + 30 * 60 - 1, FUNDING + 60 * 60, false),
        (FUNDING + 30 * 60, FUNDING + 60 * 60 - 1, false),
        (FUNDING + 30 * 60, FUNDING + 60 * 60, true),
    ] {
        let h = Harness::new();
        h.world.set().reverse_deadlines = (FUNDING, ready, refund);
        let quote = h.reverse_quote().await;
        if quoted {
            assert!(quote.is_ok());
        } else {
            assert_eq!(quote.unwrap_err().code, ErrorCode::Mismatch);
        }
    }

    // A maker naming another late window as it accepts serves another
    // contract: nothing is funded.
    let h = Harness::new();
    h.world.set().accepted_late_window = Some(24 * 60 * 60);
    let quoted = h.reverse_quote().await.unwrap();
    let (debit, railgun_fee) = h.page_cost(quoted.price.fee.0);
    let reverse = h.reverse();
    reverse
        .view()
        .set_cost(&mut h.store(), 0, debit, railgun_fee)
        .await
        .unwrap();
    reverse.view().go_ahead(&mut h.store(), 0).await.unwrap();
    assert_eq!(
        reverse.accept(&mut h.store(), 0).await.unwrap(),
        ReverseAccept::Ended(Some(NothingSentCause::Mismatch))
    );
    let ended = h.reverse_record(0);
    assert_eq!(ended.phase, ReversePhase::Cancelled);
    assert_eq!(ended.account, None);
}

/// A refund is rescued only once it was paid out and its vault holds more
/// than the relayer's fee; a rescue keeps the contract's nonce and its
/// deadline exactly, is never sent again in the background, and leaves a
/// newer conversion active.
#[tokio::test]
async fn a_refund_is_rescued_only_from_a_vault_holding_more_than_the_fee() {
    let h = Harness::new();
    h.prepared().await;
    h.fund().await.unwrap();
    h.funded();
    // Refunded, not paid out: the payout is kept, then sent.
    h.world.set().stage = SwapStage::Refunded;
    let paying = h.advance_reverse().await.unwrap();
    assert_eq!(paying.phase, ReversePhase::RefundPayout);
    assert_eq!(h.posts("/v1/reverse/refund-payout"), 1);
    h.world.set().paid_out = true;
    let refunded = h.advance_reverse().await.unwrap();
    assert_eq!(refunded.phase, ReversePhase::Refunded);
    assert_eq!(h.world.get().forgotten, 1);
    // A newer draft is active meanwhile.
    assert_eq!(h.reverse_quote().await.unwrap().record.index, 1);

    // A vault holding no more than the fee: nothing to rescue, nothing
    // signed or sent.
    for vault in [0, RELAYER_FEE] {
        h.world.set().vault = vault;
        let reverse = h.reverse();
        assert!(!reverse.view().can_rescue(&h.store(), 0).await.unwrap());
        reverse.rescue(&mut h.store(), 0).await.unwrap();
        assert_eq!(h.reverse_record(0).rescue, None);
    }
    assert_eq!(h.posts("/v1/reverse/rescue"), 0);

    // More: rescued under the contract's nonce, kept exactly before it is
    // sent.
    {
        let mut state = h.world.set();
        state.vault = 900_000;
        state.rescue_nonce = 7;
    }
    let reverse = h.reverse();
    assert!(reverse.view().can_rescue(&h.store(), 0).await.unwrap());
    let rescued = reverse.rescue(&mut h.store(), 0).await.unwrap();
    let rescue = rescued.rescue.clone().unwrap();
    assert_eq!(rescue.nonce, 7);
    assert_eq!(rescue.deadline, h.world.get().chain_now + 120);
    let digest = pins().domain().unwrap().rescue(
        &rescued.swap_id.0,
        &h.keys.note(0).unwrap().commitment(),
        &pins().relayer,
        RELAYER_FEE,
        RescueAuthorization {
            nonce: 7,
            deadline: rescue.deadline,
        },
    );
    assert_eq!(
        zecswap_core::signer(&digest, &rescue.signature.0),
        Some(h.keys.auth_address(0).unwrap())
    );
    assert_eq!(h.world.get().bodies["/v1/reverse/rescue"]["nonce"], 7);
    assert_eq!(rescued.phase, ReversePhase::Refunded);
    assert!(
        !rescued.under_way(),
        "a rescue never holds up another conversion"
    );
    match h.store().active(&h.account, Direction::Reverse).unwrap() {
        Some(StoredRecord::Reverse(active)) => assert_eq!(active.index, 1),
        other => panic!("{other:?}"),
    }

    // Never sent again in the background; the next takes the next nonce.
    h.advance_reverse().await.unwrap();
    assert_eq!(h.posts("/v1/reverse/rescue"), 1);
    h.world.set().rescue_nonce = 8;
    let again = h.reverse().rescue(&mut h.store(), 0).await.unwrap();
    assert_eq!(again.rescue.unwrap().nonce, 8);
    assert_eq!(h.posts("/v1/reverse/rescue"), 2);
}

/// The funding's calls byte for byte as ethers encodes them with the
/// contract's ABI (a vector whose `OpenReverse` signature recovers under
/// zecswap-core's digest), and the roles of a real funding request: exactly
/// the escrow approved to the contract, the escrow opened for the right
/// parties into our own refund note under our signature, and the relayer
/// paid its fee.
#[tokio::test]
async fn open_reverse_calldata_matches_the_independent_encoding_and_zapps_roles() {
    let vector = &vectors()["reverseFunding"];
    let number = |name: &str| vector[name].as_u64().unwrap();
    let open = ReverseOpen {
        maker: bytes(&vector["maker"]),
        user: bytes(&vector["user"]),
        token: bytes(&vector["token"]),
        amount: u128::from(number("amount")),
        maker_share: PublicShare::from_affine_bytes(&bytes(&vector["makerShare"])).unwrap(),
        user_share: PublicShare::from_affine_bytes(&bytes(&vector["userShare"])).unwrap(),
        t0: number("t0"),
        t1: number("t1"),
        refund_note: bytes(&vector["refundNote"]),
        deadline: number("deadline"),
    };
    let contract: [u8; 20] = bytes(&vector["contract"]);
    let signature: [u8; 65] = bytes(&vector["signature"]);
    let calls = funding_calls::encode(
        contract,
        bytes(&vector["relayer"]),
        &open,
        &signature,
        u128::from(number("fee")),
    );
    assert_eq!(
        calls.iter().map(|call| call.to).collect::<Vec<_>>(),
        vec![open.token, contract, open.token]
    );
    for (call, name) in calls.iter().zip(["approve", "openReverse", "transfer"]) {
        assert_eq!(hex0x(&call.data), text(&vector[name]), "{name}");
    }
    assert_eq!(
        hex0x(&terms::reverse_swap_id(&open.user, &open.maker_share)),
        text(&vector["swapId"])
    );
    let domain = Domain {
        chain_id: number("chainId"),
        contract,
    };
    let digest = domain.open_reverse(&open);
    assert_eq!(zecswap_core::signer(&digest, &signature), Some(open.user));

    let h = Harness::new();
    h.prepared().await;
    let request = h
        .reverse()
        .funding_request(&mut h.store(), 0, &h.keys.railgun_address().unwrap())
        .await
        .unwrap();
    let pins = pins();
    let calls = &request.calls;
    assert_eq!(
        calls.iter().map(|call| call.to).collect::<Vec<_>>(),
        vec![pins.token, super::fakes::contract(), pins.token]
    );
    assert_eq!(
        argument(&calls[0].data, 0),
        address_word(&super::fakes::contract())
    );
    assert_eq!(argument(&calls[0].data, 1), uint_word(AMOUNT));
    let opened = &calls[1].data;
    let user = h.keys.auth_address(0).unwrap();
    let note = h.keys.note(0).unwrap().commitment();
    assert_eq!(argument(opened, 0), address_word(&pins.maker));
    assert_eq!(argument(opened, 1), address_word(&user));
    assert_eq!(argument(opened, 2), address_word(&pins.token));
    assert_eq!(argument(opened, 3), uint_word(AMOUNT));
    assert_eq!(argument(opened, 10), note);
    let signed: [u8; 65] = opened[4 + 14 * 32..4 + 14 * 32 + 65].try_into().unwrap();
    let digest = pins.domain().unwrap().open_reverse(&ReverseOpen {
        maker: pins.maker,
        user,
        token: pins.token,
        amount: AMOUNT,
        maker_share: maker_share(),
        user_share: h.keys.user_share(0).unwrap(),
        t0: READY,
        t1: REFUND,
        refund_note: note,
        deadline: FUNDING,
    });
    assert_eq!(zecswap_core::signer(&digest, &signed), Some(user));
    assert_eq!(argument(&calls[2].data, 0), address_word(&pins.relayer));
    assert_eq!(argument(&calls[2].data, 1), uint_word(FUNDING_FEE));
}
