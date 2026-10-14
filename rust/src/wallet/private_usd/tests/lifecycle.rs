//! The Rust side of the account lifecycle guards (plan M5 "Done when",
//! reference §8.4, §3.5 item 15), through the FRB calls Dart makes: the
//! count the deletion and reset warnings show, the accounts the engine loop
//! advances and drains, the refusal while a step runs, and the cleanup once
//! the user confirmed.

use std::sync::Arc;

use tokio::sync::Notify;
use zcash_client_backend::data_api::WalletRead;
use zecswap_core::NetworkType;

use super::super::engine::{self, OpHandle};
use super::super::evm_rpc::SwapStage;
use super::super::forward::joint_db_path;
use super::super::joint;
use super::super::models::{Direction, ForwardOutcome};
use super::super::store::JointAccountRow;
use super::super::ErrorCode;
use super::fakes::*;
use crate::api::private_usd::{
    private_usd_accounts_with_unfinished, private_usd_cancel, private_usd_delete_account,
    private_usd_unfinished_count, ApiPrivateUsdErrorCode,
};
use crate::wallet::{keys, network::WalletNetwork, sync};

const BIRTHDAY: u32 = 4_200_000;

fn store_dir(h: &Harness) -> String {
    h.dir.path().to_str().unwrap().to_owned()
}

/// Imports swap 0's joint account for `h`, as a refund sweep does.
fn import_joint(h: &Harness) -> String {
    let ufvk = h
        .keys
        .joint(0, &maker_share())
        .unwrap()
        .ufvk(NetworkType::Test);
    let joint_uuid = joint::register_joint_account(
        &joint_db_path(h.dir.path()),
        WalletNetwork::Test,
        &ufvk,
        BIRTHDAY,
    )
    .unwrap();
    h.store()
        .put_joint_account(&JointAccountRow {
            account_uuid: h.account.clone(),
            direction: Direction::Forward,
            swap_index: 0,
            joint_uuid: joint_uuid.clone(),
            ufvk,
            birthday: u64::from(BIRTHDAY),
        })
        .unwrap();
    joint_uuid
}

fn joint_db_holds(h: &Harness, joint_uuid: &str) -> bool {
    sync::open_wallet_db_for_read(&joint_db_path(h.dir.path()), WalletNetwork::Test)
        .unwrap()
        .get_account(keys::parse_account_uuid(joint_uuid).unwrap())
        .unwrap()
        .is_some()
}

#[tokio::test]
async fn the_warning_counts_conversions_under_way_and_the_loop_finds_their_accounts() {
    // A wallet that never converted: nothing to warn about, and asking
    // creates nothing.
    let empty = tempfile::tempdir().unwrap();
    let never = empty.path().join("private_usd_wallet_test");
    let never_dir = never.to_str().unwrap().to_owned();
    assert_eq!(
        private_usd_unfinished_count(never_dir.clone(), "account".into()).unwrap(),
        0
    );
    assert!(private_usd_accounts_with_unfinished(never_dir)
        .unwrap()
        .is_empty());
    assert!(!never.exists());

    let alice = Harness::new();
    let bob = Harness::beside(&alice);
    alice.deposited().await;
    let dir = store_dir(&alice);
    assert_eq!(
        private_usd_unfinished_count(dir.clone(), alice.account.clone()).unwrap(),
        1
    );
    assert_eq!(
        private_usd_unfinished_count(dir.clone(), bob.account.clone()).unwrap(),
        0
    );
    assert_eq!(
        private_usd_accounts_with_unfinished(dir.clone()).unwrap(),
        vec![alice.account.clone()]
    );

    // Paid: no longer under way, and kept as history.
    alice.world.set().stage = SwapStage::Ready;
    alice.advance().await.unwrap();
    assert_eq!(alice.record().outcome, Some(ForwardOutcome::Paid));
    assert_eq!(
        private_usd_unfinished_count(dir.clone(), alice.account.clone()).unwrap(),
        0
    );
    assert!(private_usd_accounts_with_unfinished(dir)
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn deleting_an_account_removes_its_conversions_and_joint_accounts_only() {
    let alice = Harness::new();
    let bob = Harness::beside(&alice);
    alice.deposited().await;
    bob.deposited().await;
    let alice_joint = import_joint(&alice);
    let bob_joint = import_joint(&bob);
    let dir = store_dir(&alice);

    private_usd_delete_account(dir.clone(), "test".into(), alice.account.clone()).unwrap();

    let store = alice.store();
    assert_eq!(
        store.find(&alice.account, Direction::Forward, 0).unwrap(),
        None
    );
    assert_eq!(store.unfinished_count(&alice.account).unwrap(), 0);
    assert!(!joint_db_holds(&alice, &alice_joint));
    // The other account keeps its conversion and joint account.
    assert_eq!(store.unfinished_count(&bob.account).unwrap(), 1);
    assert!(joint_db_holds(&bob, &bob_joint));
    let rows = store.joint_accounts().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].account_uuid, bob.account);
    drop(store);

    // Nothing is left to delete: deleting again is a no-op.
    private_usd_delete_account(dir, "test".into(), alice.account.clone()).unwrap();
    assert!(joint_db_holds(&bob, &bob_joint));
}

#[tokio::test]
async fn a_drain_cancels_the_step_in_flight_and_the_delete_waits_for_it() {
    let h = Harness::new();
    h.deposited().await;
    let release = Arc::new(Notify::new());
    {
        let mut state = h.world.set();
        state.stage = SwapStage::Ready;
        state.hold_lock = Some(release.clone());
    }
    let op_id = rand::random::<u32>();
    let op = OpHandle::begin(op_id).unwrap();
    let dir = store_dir(&h);

    let step = async {
        let _driver = engine::lock_account(&h.account).unwrap();
        h.forward_with(Some(&op))
            .advance_report(&mut h.store(), 0)
            .await
    };
    let drain = async {
        while h.paths().iter().all(|path| path != "/v1/lock-claim") {
            tokio::task::yield_now().await;
        }
        // The user confirmed the warning; the delete waits for the step.
        let refused = private_usd_delete_account(dir.clone(), "test".into(), h.account.clone())
            .unwrap_err()
            .code;
        // Draining cancels the step in flight.
        private_usd_cancel(op_id);
        release.notify_one();
        refused
    };
    let (report, refused) = tokio::join!(step, drain);

    assert_eq!(refused, ApiPrivateUsdErrorCode::Busy);
    // Cancelled before the reveal: an error, never a problem to show.
    assert_eq!(report.unwrap_err().code, ErrorCode::Cancelled);
    assert!(h.paths().iter().all(|path| path != "/v1/claim"));
    assert_eq!(h.record().outcome, None);
    drop(op);

    // Drained: the delete goes through.
    private_usd_delete_account(dir.clone(), "test".into(), h.account.clone()).unwrap();
    assert_eq!(
        private_usd_unfinished_count(dir, h.account.clone()).unwrap(),
        0
    );

    // A cancel that reaches Rust before its call registered still stops it.
    let early = rand::random::<u32>();
    private_usd_cancel(early);
    assert!(OpHandle::begin(early).unwrap().cancelled());
}
