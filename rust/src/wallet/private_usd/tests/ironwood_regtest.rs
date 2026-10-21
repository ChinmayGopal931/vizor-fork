//! A joint account's round trip on the Dockerized Ironwood regtest stack
//! (`scripts/ironwood-regtest`). The test resets the chain and starts the
//! stack itself. Run it only with the owner's go-ahead:
//!
//! ```text
//! cd rust && cargo test --lib private_usd::tests::ironwood_regtest -- --ignored --nocapture --test-threads=1
//! ```
//!
//! It checks on the real stack that the signer accepts the PCZT's lock-owner
//! field, the compact signatures are exactly the joint spend's, a joint DB
//! born above the tip syncs, resubmission runs on a joint DB, the primary
//! store path records an OVK-less sweep as sent, and PCZT creation works for
//! a spending account without derivation.
//!
//! In test builds the regtest NU6.3 height is per thread, so every wallet call
//! stays on this thread: async calls run on a current-thread runtime.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{atomic::AtomicBool, Arc};

use orchard::{
    keys::{OutgoingViewingKey, Scope},
    note_encryption::{IronwoodDomain, OrchardDomain},
};
use secrecy::{ExposeSecret, SecretVec};
use tempfile::TempDir;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_note_encryption::try_output_recovery_with_ovk;
use zcash_primitives::transaction::{Transaction, TxId};
use zcash_protocol::consensus::BranchId;
use zecswap_core::{derive_maker_share, derive_user_keys, JointAccount, NetworkType, SweepIntent};

use super::super::joint::{self, SwapTxStatus, SweepBroadcast};
use crate::api::{simple as simple_api, wallet as wallet_api};
use crate::wallet::{keys, network::WalletNetwork, sync, sync_engine};

const NETWORK: WalletNetwork = WalletNetwork::Regtest;
const FUNDER_MNEMONIC: &str = "winter shiver fetch refuse absurd mail pistol eight market lounge manual roast miracle ethics found child scare curve congress renew salute pig better used";
const DEPOSIT_ZATOSHI: u64 = 50_000_000;
const MAX_DEPOSIT_FEE_ZATOSHI: u64 = 100_000;
/// The sweep cap: 64 ZIP 317 marginal fees.
const MAX_SWEEP_FEE_ZATOSHI: u64 = 320_000;
const SWEEP_CONFIRMATIONS: u32 = 2;
const ORDINARY_UNTRUSTED_CONFIRMATIONS: u32 = 6;
/// A route nothing listens on: a broadcast through it cannot happen.
const DEAD_ROUTE: &str = "http://127.0.0.1:1";

struct Wallet {
    _dir: TempDir,
    db: String,
    account: String,
    address: String,
}

/// A deposit into a joint account lands in the Ironwood bundle; the joint
/// account, imported above the tip, scans it to two confirmations; and the
/// combined key sweeps it home without an OVK the maker could read.
#[test]
#[ignore = "requires the Dockerized Ironwood zcashd/lightwalletd regtest stack"]
fn a_joint_account_takes_an_ironwood_deposit_and_sweeps_it_home_without_its_ovk() {
    joint_account_round_trip(false);
}

/// An Orchard deposit made before NU6.3 remains discoverable and spendable
/// after activation, including the joint-key signature and Discard OVK path.
#[test]
#[ignore = "requires the Dockerized Ironwood zcashd/lightwalletd regtest stack"]
fn a_joint_account_takes_an_orchard_deposit_and_sweeps_it_after_ironwood_activation() {
    joint_account_round_trip(true);
}

fn joint_account_round_trip(deposit_before_activation: bool) {
    start_post_activation_chain();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime");
    let lwd = lightwalletd_url();

    // 1. The joint key, from the vector seed and maker root.
    let user = derive_user_keys(&[7; 64], NetworkType::Regtest, 0, 0).expect("user keys");
    let maker = derive_maker_share(&[9; 32], 0).expect("maker share");
    let joint = JointAccount::derive(&maker.public(), &user.share.public(), &user.viewing)
        .expect("joint account");
    let key = joint.spend_key(&maker, &user.share).expect("combined key");
    let joint_ua = joint.unified_address(NetworkType::Regtest);
    let joint_ovks = [
        joint.fvk().to_ovk(Scope::External),
        joint.fvk().to_ovk(Scope::Internal),
    ];

    // After activation the funder pays the deposit from one pre-activation
    // Orchard note. Its account is also where the sweep goes home.
    let funder = import("Funder", FUNDER_MNEMONIC, 1);
    if !deposit_before_activation {
        run_harness("fund-orchard.sh", &[&funder.address, "2.0", "10", "1", "1"]);
        run_harness("activate-ironwood.sh", &[]);
    }
    mine(ORDINARY_UNTRUSTED_CONFIRMATIONS);
    runtime.block_on(scan(&funder.db));

    // 2. Import at the exact birthday, above the tip: nothing to scan yet.
    let joint_dir = tempfile::tempdir().expect("joint tempdir");
    let joint_db = path_string(&joint_dir.path().join("joint.db"));
    let birthday = u32::try_from(latest_height() + 1).expect("height");
    let ufvk = joint.ufvk(NetworkType::Regtest);
    let joint_uuid =
        joint::register_joint_account(&joint_db, NETWORK, &ufvk, birthday).expect("import");
    assert_eq!(
        joint::register_joint_account(&joint_db, NETWORK, &ufvk, birthday).expect("again"),
        joint_uuid,
        "importing the same key again is idempotent"
    );
    runtime
        .block_on(sync_joint(&joint_db))
        .expect("a joint DB born above the tip syncs");

    // 3. The deposit. Before activation zcashd pays it, since the builder
    // makes no Orchard transaction before NU6.3. After it the wallet pays it
    // through the split: propose, create and store, find, send.
    let deposit_tx = if deposit_before_activation {
        let zec = format!(
            "{}.{:08}",
            DEPOSIT_ZATOSHI / 100_000_000,
            DEPOSIT_ZATOSHI % 100_000_000
        );
        run_harness("fund-orchard.sh", &[&joint_ua, &zec, "1", "1", "1"]);
        None
    } else {
        let deposit = sync::propose_swap_deposit(
            &funder.db,
            NETWORK,
            &funder.account,
            "deposit",
            &joint_ua,
            DEPOSIT_ZATOSHI,
            DEPOSIT_ZATOSHI + MAX_DEPOSIT_FEE_ZATOSHI,
        )
        .expect("propose the deposit");
        let created = runtime
            .block_on(sync::create_stored_proposal_transactions(
                &funder.db,
                &lwd,
                deposit.proposal_id,
                "deposit",
                seed(FUNDER_MNEMONIC),
                None,
                None,
            ))
            .expect("create and store the deposit");
        let [deposit_tx] = created.as_slice() else {
            panic!("a deposit is one transaction: {created:?}");
        };
        assert_eq!(
            joint::find_deposit(&funder.db, NETWORK, &funder.account, &joint_ua)
                .expect("find the deposit")
                .map(|found| found.txid),
            Some(deposit_tx.txid),
            "a stored, unsent deposit is found"
        );
        runtime
            .block_on(sync::broadcast_raw(&lwd, &deposit_tx.raw))
            .expect("send the deposit");
        runtime
            .block_on(sync::broadcast_raw(&lwd, &deposit_tx.raw))
            .expect("sending it again is harmless");
        // The joint UA receives in Ironwood, and the pool records the recipient
        // for `find_deposit`.
        let deposit_raw = Transaction::read(&deposit_tx.raw[..], BranchId::Nu6_3).expect("parse");
        assert!(deposit_raw.ironwood_bundle().is_some());
        assert_eq!(sent_output_pool(&funder.db, &deposit_tx.txid, &joint_ua), 4);
        let funder_ovk = funder_ovk();
        assert!(
            recovered_outputs(&deposit_tx.raw, &[funder_ovk]) >= 1,
            "control: the deposit keeps the sender OVK"
        );
        Some((deposit_tx.txid, deposit_tx.expiry_height))
    };

    // 4. Scan to two confirmations. zcashd's deposit is mined already.
    if !deposit_before_activation {
        mine(1);
    }
    runtime.block_on(sync_joint(&joint_db)).expect("joint sync");
    let receipts = joint::joint_receipts(&joint_db, NETWORK, &joint_uuid, SWEEP_CONFIRMATIONS)
        .expect("receipts");
    assert_eq!(receipts.received_zatoshi, DEPOSIT_ZATOSHI);
    assert_eq!(receipts.confirmed_zatoshi, 0, "one confirmation is not two");
    mine(SWEEP_CONFIRMATIONS - 1);
    runtime.block_on(sync_joint(&joint_db)).expect("joint sync");
    let receipts = joint::joint_receipts(&joint_db, NETWORK, &joint_uuid, SWEEP_CONFIRMATIONS)
        .expect("receipts");
    assert_eq!(
        (receipts.confirmed_zatoshi, receipts.confirmed_notes),
        (DEPOSIT_ZATOSHI, 1)
    );
    assert_eq!(
        (receipts.spendable_zatoshi, receipts.pending_zatoshi),
        (DEPOSIT_ZATOSHI, 0)
    );
    if let Some((deposit_txid, deposit_expiry)) = deposit_tx {
        runtime.block_on(scan(&funder.db));
        assert!(matches!(
            joint::swap_tx_status(&funder.db, NETWORK, &deposit_txid, deposit_expiry)
                .expect("deposit status"),
            SwapTxStatus::Mined { .. }
        ));
    }

    if deposit_before_activation {
        run_harness("activate-ironwood.sh", &[]);
        mine(ORDINARY_UNTRUSTED_CONFIRMATIONS);
        runtime
            .block_on(sync_joint(&joint_db))
            .expect("joint sync after activation");
        assert_eq!(
            joint::joint_receipts(&joint_db, NETWORK, &joint_uuid, SWEEP_CONFIRMATIONS)
                .expect("Orchard receipt after activation")
                .spendable_zatoshi,
            DEPOSIT_ZATOSHI,
            "activation must not strand the joint account's Orchard deposit"
        );
    }

    // 5. Broadcast before store: a sweep that cannot be sent stores nothing,
    // and its note stays spendable. Its PCZT carries the lock-owner field the
    // signer must accept for a spending account without derivation.
    let attempt = sync::propose_joint_sweep(
        &joint_db,
        NETWORK,
        &joint_uuid,
        "dead-route",
        &funder.address,
        MAX_SWEEP_FEE_ZATOSHI,
    )
    .expect("propose a sweep");
    let base = runtime
        .block_on(sync::create_pczt_from_proposal(
            &joint_db,
            &lwd,
            NETWORK,
            attempt.proposal_id,
            "dead-route",
        ))
        .expect("create the sweep PCZT");
    let attempt_txid = sync::txid_from_io_finalized_pczt(&base).expect("txid");
    let intent = SweepIntent::from_address(
        &funder.address,
        NetworkType::Regtest,
        attempt.amount_zatoshi,
        MAX_SWEEP_FEE_ZATOSHI,
    )
    .expect("intent");
    let signed = zecswap_core::sign_pczt_bytes(&base, std::slice::from_ref(&key), &intent)
        .expect("sign with the combined key");
    let signatures =
        sync::extract_required_compact_sigs_from_signed_pczt(&base, &signed).expect("signatures");
    assert_eq!(signatures.len(), 1, "exactly the joint spend's signature");
    let proofs = sync::add_proofs_to_pczt(&base, None, None).expect("prove");
    let refused = runtime
        .block_on(
            sync::store_and_broadcast_pczts_with_compact_signatures_for_proposal(
                &joint_db,
                DEAD_ROUTE,
                NETWORK,
                attempt.proposal_id,
                "dead-route",
                &[proofs],
                &[signatures],
                None,
                None,
            ),
        )
        .err()
        .expect("nothing can be sent through a dead route");
    sync::discard_proposal(attempt.proposal_id, "dead-route").expect("discard");
    assert_eq!(
        joint::swap_tx_status(&joint_db, NETWORK, &attempt_txid, 0).expect("status"),
        SwapTxStatus::Unknown,
        "an unsent sweep is not stored: {refused}"
    );
    assert_eq!(
        joint::joint_receipts(&joint_db, NETWORK, &joint_uuid, SWEEP_CONFIRMATIONS)
            .expect("receipts")
            .spendable_zatoshi,
        DEPOSIT_ZATOSHI,
        "the unsent sweep left its note spendable"
    );

    // 6. Sweep home with the combined key, discarding the OVK.
    let sweep = runtime
        .block_on(joint::sweep_joint(
            &joint_db,
            &lwd,
            NETWORK,
            &joint_uuid,
            "sweep",
            &funder.address,
            MAX_SWEEP_FEE_ZATOSHI,
            &key,
        ))
        .expect("sweep home");
    assert_eq!(
        sweep.broadcast,
        SweepBroadcast::Accepted,
        "{:?}",
        sweep.message
    );
    assert_eq!(sweep.amount_zatoshi + sweep.fee_zatoshi, DEPOSIT_ZATOSHI);
    // The primary store path records the sweep as sent without an OVK.
    assert_eq!(
        sent_output_pool(&joint_db, &sweep.transaction.txid, &funder.address),
        4
    );
    // 7. The maker's joint OVK cannot read where the sweep went.
    assert_eq!(recovered_outputs(&sweep.transaction.raw, &joint_ovks), 0);

    // The joint sync sends the pending sweep again, then sees it mined.
    runtime
        .block_on(sync_joint(&joint_db))
        .expect("joint sync resubmits the sweep");
    mine(1);
    runtime.block_on(sync_joint(&joint_db)).expect("joint sync");
    assert!(matches!(
        joint::swap_tx_status(
            &joint_db,
            NETWORK,
            &sweep.transaction.txid,
            sweep.transaction.expiry_height
        )
        .expect("sweep status"),
        SwapTxStatus::Mined { .. }
    ));
    runtime.block_on(scan(&funder.db));
    assert_eq!(
        received(&funder.db, &sweep.transaction.txid),
        sweep.amount_zatoshi,
        "the sweep came home"
    );

    joint::delete_joint_account(&joint_db, NETWORK, &joint_uuid).expect("forget the account");
    let accounts: i64 = rusqlite::Connection::open(&joint_db)
        .expect("joint db")
        .query_row("SELECT COUNT(*) FROM accounts", [], |row| row.get(0))
        .expect("count");
    assert_eq!(accounts, 0);
}

fn seed(mnemonic: &str) -> SecretVec<u8> {
    keys::mnemonic_to_seed(mnemonic).expect("seed")
}

fn funder_ovk() -> OutgoingViewingKey {
    UnifiedSpendingKey::from_seed(
        &NETWORK,
        seed(FUNDER_MNEMONIC).expose_secret(),
        zip32::AccountId::ZERO,
    )
    .expect("funder key")
    .to_unified_full_viewing_key()
    .orchard()
    .expect("Orchard key")
    .to_ovk(Scope::External)
}

/// How many of the transaction's outputs any of `ovks` recovers.
fn recovered_outputs(raw: &[u8], ovks: &[OutgoingViewingKey]) -> usize {
    let tx = Transaction::read(raw, BranchId::Nu6_3).expect("parse");
    let orchard = tx.orchard_bundle().map_or(0, |bundle| {
        bundle
            .actions()
            .iter()
            .filter(|action| {
                let domain = OrchardDomain::for_action(*action);
                ovks.iter().any(|ovk| {
                    try_output_recovery_with_ovk(
                        &domain,
                        ovk,
                        *action,
                        action.cv_net(),
                        &action.encrypted_note().out_ciphertext,
                    )
                    .is_some()
                })
            })
            .count()
    });
    let ironwood = tx.ironwood_bundle().map_or(0, |bundle| {
        bundle
            .actions()
            .iter()
            .filter(|action| {
                let domain = IronwoodDomain::for_action(*action);
                ovks.iter().any(|ovk| {
                    try_output_recovery_with_ovk(
                        &domain,
                        ovk,
                        *action,
                        action.cv_net(),
                        &action.encrypted_note().out_ciphertext,
                    )
                    .is_some()
                })
            })
            .count()
    });
    orchard + ironwood
}

/// The pool code `db` recorded for its sent output of `txid` to `to`.
fn sent_output_pool(db: &str, txid: &TxId, to: &str) -> i64 {
    rusqlite::Connection::open(db)
        .expect("wallet db")
        .query_row(
            "SELECT sn.output_pool FROM sent_notes sn
             JOIN transactions t ON t.id_tx = sn.transaction_id
             WHERE t.txid = ?1 AND sn.to_address = ?2",
            rusqlite::params![txid.as_ref(), to],
            |row| row.get(0),
        )
        .expect("the sent output is recorded with its recipient")
}

/// What `db` received in `txid`.
fn received(db: &str, txid: &TxId) -> u64 {
    rusqlite::Connection::open(db)
        .expect("wallet db")
        .query_row(
            "SELECT COALESCE(SUM(ro.value), 0) FROM v_received_outputs ro
             JOIN transactions t ON t.id_tx = ro.transaction_id
             WHERE t.txid = ?1",
            [txid.as_ref()],
            |row| row.get(0),
        )
        .expect("received outputs")
}

async fn scan(db: &str) {
    keys::ensure_db_migrated_once(db, NETWORK).expect("migrate");
    sync_engine::run_payment_link_claim_sync(
        db,
        &lightwalletd_url(),
        NETWORK,
        Arc::new(AtomicBool::new(false)),
        false,
    )
    .await
    .expect("scan");
}

async fn sync_joint(joint_db: &str) -> super::super::Result<()> {
    joint::sync_joint_db(
        joint_db,
        &lightwalletd_url(),
        NETWORK,
        Arc::new(AtomicBool::new(false)),
    )
    .await
}

fn start_post_activation_chain() {
    simple_api::configure_regtest_ironwood_activation_height(activation_height())
        .expect("configure wallet NU6.3 activation");
    run_harness("reset.sh", &[]);
    run_harness("up.sh", &[]);
}

fn import(name: &str, mnemonic: &str, birthday: u64) -> Wallet {
    let dir = tempfile::tempdir().expect("wallet tempdir");
    let db = path_string(&dir.path().join("zcash_wallet.db"));
    let wallet = wallet_api::import_wallet(
        mnemonic.to_string(),
        String::new(),
        Some(birthday),
        "regtest".into(),
        db.clone(),
        Some(name.to_string()),
    )
    .unwrap_or_else(|error| panic!("import {name}: {error}"));
    Wallet {
        _dir: dir,
        db,
        account: wallet.account_uuid,
        address: wallet.unified_address,
    }
}

fn mine(blocks: u32) {
    run_harness("mine.sh", &[&blocks.to_string()]);
}

fn latest_height() -> u64 {
    wallet_api::get_latest_block_height(lightwalletd_url(), "regtest".into())
        .expect("read Ironwood regtest tip")
}

fn activation_height() -> u32 {
    std::env::var("IRONWOOD_ACTIVATION_HEIGHT")
        .unwrap_or_else(|_| "500".to_string())
        .parse()
        .expect("IRONWOOD_ACTIVATION_HEIGHT must be a u32")
}

fn lightwalletd_url() -> String {
    let port = std::env::var("IRONWOOD_LIGHTWALLETD_PORT").unwrap_or_else(|_| "19067".to_string());
    format!("http://127.0.0.1:{port}")
}

fn run_harness(script: &str, args: &[&str]) -> String {
    let path = repo_root()
        .join("scripts")
        .join("ironwood-regtest")
        .join(script);
    let output = Command::new(path)
        .args(args)
        .current_dir(repo_root())
        .env(
            "IRONWOOD_ACTIVATION_HEIGHT",
            activation_height().to_string(),
        )
        .output()
        .unwrap_or_else(|error| panic!("run {script}: {error}"));
    assert!(
        output.status.success(),
        "{script} failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust crate must be inside the repository")
        .to_path_buf()
}

fn path_string(path: &Path) -> String {
    path.to_str().expect("UTF-8 path").to_string()
}
