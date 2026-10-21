//! The wallet's Zcash side of a swap: a swap's joint account in `joint.db`,
//! the deposit from the main wallet, and the swap transactions the wallet
//! follows.
//!
//! The joint account is the Orchard-only account whose spend authorizing key
//! is split: the maker holds `e`, the user holds `z`. The wallet imports it by
//! its viewing key, scans it, and sweeps it home with the combined key
//! `±(e+z)` once it knows both halves. `joint.db` is a librustzcash wallet of
//! its own, so joint accounts never appear in the main wallet's account list,
//! sync status, voting or migration.
//!
//! The local writes here (import, delete) run under `with_operations`, never
//! across network I/O; librustzcash writes also take the process-wide wallet
//! write lock. One scan of a `joint.db` runs at a time.

use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use rusqlite::OptionalExtension;
use zcash_client_backend::data_api::{Account as _, AccountPurpose, WalletRead, WalletWrite};
use zcash_keys::keys::UnifiedFullViewingKey;
use zcash_primitives::transaction::{fees::zip317, TxId};
use zcash_protocol::consensus::Parameters;
use zecswap_core::{JointAccount, SpendKey, SweepIntent};

use super::forward::ForwardZcash;
use super::keys::SwapKeyContext;
use super::models::{
    Direction, JointAccountId, ReverseReceiveEstimate, ReverseReceiveTransaction, ZcashTransaction,
    ZcashTxId,
};
use super::reverse::ReverseZcash;
use super::store::{JointAccountRow, SwapStore};
use super::{fail, lock, with_operations, ErrorCode, PrivateUsdError, Result};
use crate::wallet::db::{
    open_readonly_conn_with_timeout, open_wallet_db_with_timeout, wallet_db_on,
    with_wallet_db_write_lock, ACCOUNT_MUTATION_DB_BUSY_TIMEOUT, READ_DB_BUSY_TIMEOUT,
};
use crate::wallet::failure::WalletFailure;
use crate::wallet::network::WalletNetwork;
use crate::wallet::sync::{
    self, CreatedTransaction, StoreAndBroadcastPcztsResult, SwapDepositError, SwapProposal,
};
use crate::wallet::{keys, sync_engine};

/// The joint accounts of one wallet's conversions, beside `swaps.db`.
const JOINT_DB_FILE: &str = "joint.db";
/// The name and key source a joint account is imported under.
const JOINT_ACCOUNT_NAME: &str = "Private USD joint";
const JOINT_KEY_SOURCE: &str = "vizor-private-usd-joint";
/// A forward refund's sweep pays at most this fee: 64 ZIP 317 marginal fees.
const MAX_SWEEP_FEE_ZATOSHI: u64 = 320_000;

fn wallet_error(message: impl Into<String>) -> PrivateUsdError {
    PrivateUsdError::new(ErrorCode::ZcashWallet, message)
}

fn sql_error(error: rusqlite::Error) -> PrivateUsdError {
    wallet_error(error.to_string())
}

/// Imports a swap's joint account into `joint_db` by its UFVK, at exactly
/// `birthday_height`: rounding it down would rescan up to 10,000 blocks
/// inside a swap's deadlines. It is a spending account with no derivation,
/// never view-only, so the wallet tracks the notes a sweep spends.
/// Registering the same key again returns the same account.
pub(crate) fn register_joint_account(
    joint_db: &str,
    network: WalletNetwork,
    ufvk: &str,
    birthday_height: u32,
) -> Result<String> {
    if birthday_height == 0 {
        return fail(ErrorCode::Other, "a joint account needs a birthday height");
    }
    let ufvk = UnifiedFullViewingKey::decode(&network, ufvk).map_err(|error| {
        PrivateUsdError::new(ErrorCode::Mismatch, format!("joint viewing key: {error}"))
    })?;
    if ufvk.orchard().is_none() || ufvk.sapling().is_some() || ufvk.transparent().is_some() {
        return fail(
            ErrorCode::Mismatch,
            "a joint viewing key holds an Orchard key and nothing else",
        );
    }
    let birthday = keys::make_birthday(network, Some(u64::from(birthday_height)));

    with_operations(|| {
        keys::ensure_db_migrated_once(joint_db, network).map_err(wallet_error)?;
        let registered: std::result::Result<Result<String>, String> =
            with_wallet_db_write_lock("private_usd.register_joint_account", || {
                let mut db = open_wallet_db_with_timeout(
                    joint_db,
                    network,
                    ACCOUNT_MUTATION_DB_BUSY_TIMEOUT,
                )?;
                if let Some(account) = db.get_account_for_ufvk(&ufvk).map_err(|e| e.to_string())? {
                    return Ok(match account.purpose() {
                        AccountPurpose::Spending { .. } => {
                            Ok(account.id().expose_uuid().to_string())
                        }
                        AccountPurpose::ViewOnly => Err(PrivateUsdError::new(
                            ErrorCode::Mismatch,
                            "the joint account is imported view-only",
                        )),
                    });
                }
                let account = db
                    .import_account_ufvk(
                        JOINT_ACCOUNT_NAME,
                        &ufvk,
                        &birthday,
                        AccountPurpose::Spending { derivation: None },
                        Some(JOINT_KEY_SOURCE),
                    )
                    .map_err(|e| e.to_string())?;
                Ok(Ok(account.id().expose_uuid().to_string()))
            });
        registered.map_err(wallet_error)?
    })
}

/// Forgets a joint account, once its sweep is confirmed or its swap no longer
/// needs it.
pub(crate) fn delete_joint_account(
    joint_db: &str,
    network: WalletNetwork,
    joint_uuid: &str,
) -> Result<()> {
    with_operations(|| keys::delete_account(joint_db, network, joint_uuid).map_err(wallet_error))
}

/// Forgets a joint account if `joint_db` still holds it: a cleanup that ran
/// before, or a `joint.db` that is gone, leaves nothing to do.
pub(crate) fn forget_joint_account(
    joint_db: &str,
    network: WalletNetwork,
    joint_uuid: &str,
) -> Result<()> {
    if !std::path::Path::new(joint_db).exists() {
        return Ok(());
    }
    let account = keys::parse_account_uuid(joint_uuid)
        .map_err(|error| PrivateUsdError::new(ErrorCode::Other, error))?;
    let held = sync::open_wallet_db_for_read(joint_db, network)
        .map_err(wallet_error)?
        .get_account(account)
        .map_err(|error| wallet_error(error.to_string()))?
        .is_some();
    if !held {
        return Ok(());
    }
    delete_joint_account(joint_db, network, joint_uuid)
}

/// The `joint.db` paths a scan is running on.
static SCANNING: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(Default::default);

/// One running scan of a `joint.db`, released when dropped.
struct ScanClaim(String);

impl ScanClaim {
    fn take(joint_db: &str) -> Result<Self> {
        if !lock(&SCANNING).insert(joint_db.to_string()) {
            return fail(ErrorCode::Busy, "the joint wallet is already scanning");
        }
        Ok(Self(joint_db.to_string()))
    }
}

impl Drop for ScanClaim {
    fn drop(&mut self) {
        lock(&SCANNING).remove(&self.0);
    }
}

/// Scans `joint_db` to the chain tip with the isolated claim scan, which also
/// sends its unmined sweep again. `cancel` stops it between batches.
///
/// A `joint.db` whose accounts are all born above the tip has nothing to scan
/// yet, and the claim scan's completion checks would fail on it: no block is
/// stored at the tip. This returns at once until the chain reaches the
/// birthday.
pub(crate) async fn sync_joint_db(
    joint_db: &str,
    lightwalletd_url: &str,
    network: WalletNetwork,
    cancel: Arc<AtomicBool>,
) -> Result<()> {
    let _scan = ScanClaim::take(joint_db)?;
    keys::ensure_db_migrated_once(joint_db, network).map_err(wallet_error)?;
    let birthday = sync::open_wallet_db_for_read(joint_db, network)
        .map_err(wallet_error)?
        .get_wallet_birthday()
        .map_err(|error| wallet_error(error.to_string()))?;
    let Some(birthday) = birthday else {
        return Ok(());
    };
    // A fresh tip, never the transaction tip cache: a tip cached up to 15 s
    // earlier would skip the scan of the very block that reaches the birthday.
    let mut client = sync_engine::open_lwd_channel_with_cancel(lightwalletd_url, || {
        cancel.load(Ordering::Relaxed)
    })
    .await
    .map_err(|error| wallet_error(format!("read the chain tip: {error}")))?;
    let tip = sync_engine::get_latest_block_recorded(&mut client, lightwalletd_url, network)
        .await
        .map_err(|error| wallet_error(format!("read the chain tip: {error}")))?;
    drop(client);
    if u64::from(u32::from(birthday)) > tip.height {
        return Ok(());
    }
    sync_engine::run_payment_link_claim_sync(joint_db, lightwalletd_url, network, cancel, true)
        .await
        .map_err(wallet_error)
}

/// What a joint account has received, and what a sweep could spend now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct JointReceipts {
    /// Received in transactions at least `confirmations` deep, counted from
    /// the fully scanned height, never from an unscanned tip.
    pub confirmed_zatoshi: u64,
    /// The notes those transactions carry. A sweep pays for an action per
    /// note, and one for its output.
    pub confirmed_notes: u32,
    /// Everything received, at any depth.
    pub received_zatoshi: u64,
    /// Spendable now under the sweep's two-confirmation policy.
    pub spendable_zatoshi: u64,
    /// Received but not yet spendable under that policy. A sweep waits until
    /// this is zero, so it leaves no note behind.
    pub pending_zatoshi: u64,
    /// The height through which every block is scanned; `None` before the
    /// first.
    pub fully_scanned_height: Option<u32>,
}

/// The joint account's receipts, read from one snapshot of `joint_db`.
pub(crate) fn joint_receipts(
    joint_db: &str,
    network: WalletNetwork,
    joint_uuid: &str,
    confirmations: u32,
) -> Result<JointReceipts> {
    let account = keys::parse_account_uuid(joint_uuid)
        .map_err(|error| PrivateUsdError::new(ErrorCode::Other, error))?;
    let conn = open_readonly_conn_with_timeout(joint_db, Some(READ_DB_BUSY_TIMEOUT))
        .map_err(wallet_error)?;
    let snapshot = conn.unchecked_transaction().map_err(sql_error)?;
    let wallet = wallet_db_on(&snapshot, joint_db, network);
    let fully_scanned_height = fully_scanned_height(&wallet)?;

    let mut receipts = JointReceipts {
        confirmed_zatoshi: 0,
        confirmed_notes: 0,
        received_zatoshi: 0,
        spendable_zatoshi: 0,
        pending_zatoshi: 0,
        fully_scanned_height,
    };
    let mut query = snapshot
        .prepare(
            "SELECT ro.value, t.mined_height
             FROM v_received_outputs ro
             JOIN transactions t ON t.id_tx = ro.transaction_id
             JOIN accounts a ON a.id = ro.account_id
             WHERE a.uuid = ?1 AND ro.pool IN (3, 4) AND ro.value > 0 AND ro.is_change = 0",
        )
        .map_err(sql_error)?;
    let received = query
        .query_map([account.expose_uuid().as_bytes().as_slice()], |row| {
            Ok((row.get::<_, u64>(0)?, row.get::<_, Option<u32>>(1)?))
        })
        .map_err(sql_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(sql_error)?;
    for (value, mined_height) in received {
        receipts.received_zatoshi = receipts.received_zatoshi.saturating_add(value);
        let deep_enough = mined_height
            .zip(fully_scanned_height)
            .is_some_and(|(mined, scanned)| {
                scanned >= mined && scanned - mined + 1 >= confirmations
            });
        if deep_enough {
            receipts.confirmed_zatoshi = receipts.confirmed_zatoshi.saturating_add(value);
            receipts.confirmed_notes += 1;
        }
    }

    let summary = wallet
        .get_wallet_summary(crate::wallet::joint_sweep_confirmations_policy())
        .map_err(|error| wallet_error(error.to_string()))?;
    if let Some(balance) = summary
        .as_ref()
        .and_then(|summary| summary.account_balances().get(&account))
    {
        for pool in [balance.orchard_balance(), balance.ironwood_balance()] {
            receipts.spendable_zatoshi = receipts
                .spendable_zatoshi
                .saturating_add(u64::from(pool.spendable_value()));
            receipts.pending_zatoshi = receipts
                .pending_zatoshi
                .saturating_add(u64::from(pool.value_pending_spendability()))
                .saturating_add(u64::from(pool.change_pending_confirmation()));
        }
    }
    Ok(receipts)
}

/// How a sweep's broadcast ended. In each case the sweep may be on the
/// network, so the caller keeps its bytes and sends them again until it is
/// mined.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SweepBroadcast {
    /// lightwalletd accepted it, and `joint.db` stores it as sent.
    Accepted,
    /// The answer was lost. `joint.db` stores it unless storage failed too.
    Unknown,
    /// lightwalletd accepted it but storing it failed. Its notes stay locked
    /// until it expires, and the joint scan finds it once it is mined.
    StorageFailed,
}

/// The sweep that sent a joint account's balance home.
pub(crate) struct JointSweep {
    pub transaction: CreatedTransaction,
    pub amount_zatoshi: u64,
    pub fee_zatoshi: u64,
    #[cfg_attr(not(test), allow(dead_code))]
    pub broadcast: SweepBroadcast,
    #[cfg_attr(not(test), allow(dead_code))]
    pub message: Option<String>,
}

/// Sweeps everything in a joint account to `home_ua` with the combined key
/// `key` (`±(e+z)`): propose, create the PCZT, sign the unredacted base
/// against a `SweepIntent`, extract the compact signatures, prove, then
/// broadcast and store through the hardware completion path.
///
/// - The sweep discards its OVK, pays `home_ua` the whole balance less the
///   fee, and pays at most `max_fee_zatoshi`.
/// - Broadcast comes before storage, so a rejected sweep leaves the joint
///   notes unspent.
/// - PCZT creation consumes the proposal; every other exit discards it, which
///   never releases a reservation a broadcast has started.
pub(crate) async fn sweep_joint(
    joint_db: &str,
    lightwalletd_url: &str,
    network: WalletNetwork,
    joint_uuid: &str,
    send_flow_id: &str,
    home_ua: &str,
    max_fee_zatoshi: u64,
    key: &SpendKey,
) -> Result<JointSweep> {
    // The signer pays only a unified address's Orchard receiver on this
    // network: refuse anything else before proposing.
    SweepIntent::recipient(home_ua, network.network_type())
        .map_err(|error| PrivateUsdError::new(ErrorCode::Mismatch, error.to_string()))?;
    let proposal = sync::propose_joint_sweep(
        joint_db,
        network,
        joint_uuid,
        send_flow_id,
        home_ua,
        max_fee_zatoshi,
    )
    .map_err(wallet_error)?;
    let swept = sweep_proposal(
        joint_db,
        lightwalletd_url,
        network,
        send_flow_id,
        home_ua,
        max_fee_zatoshi,
        key,
        &proposal,
    )
    .await;
    if let Err(error) = sync::discard_proposal(proposal.proposal_id, send_flow_id) {
        log::warn!("private usd: releasing a joint sweep proposal failed: {error}");
    }
    swept
}

async fn sweep_proposal(
    joint_db: &str,
    lightwalletd_url: &str,
    network: WalletNetwork,
    send_flow_id: &str,
    home_ua: &str,
    max_fee_zatoshi: u64,
    key: &SpendKey,
    proposal: &SwapProposal,
) -> Result<JointSweep> {
    let base = sync::create_pczt_from_proposal(
        joint_db,
        lightwalletd_url,
        network,
        proposal.proposal_id,
        send_flow_id,
    )
    .await
    .map_err(wallet_error)?;
    let txid = sync::txid_from_io_finalized_pczt(&base).map_err(wallet_error)?;
    let expiry_height = sync::expiry_height_from_io_finalized_pczt(&base).map_err(wallet_error)?;

    // The signer checks the intent against the base's note values and
    // randomness, which the redacted signer view leaves out.
    let intent = SweepIntent::from_address(
        home_ua,
        network.network_type(),
        proposal.amount_zatoshi,
        max_fee_zatoshi,
    )
    .map_err(|error| PrivateUsdError::new(ErrorCode::Mismatch, error.to_string()))?;
    let signed = zecswap_core::sign_pczt_bytes(&base, std::slice::from_ref(key), &intent)
        .map_err(|error| PrivateUsdError::new(ErrorCode::Mismatch, error.to_string()))?;
    let signatures = sync::extract_required_compact_sigs_from_signed_pczt(&base, &signed)
        .map_err(wallet_error)?;
    let proofs = tokio::task::spawn_blocking(move || sync::add_proofs_to_pczt(&base, None, None))
        .await
        .map_err(|error| wallet_error(format!("proving the sweep stopped: {error}")))?
        .map_err(wallet_error)?;

    let result = sync::store_and_broadcast_pczts_with_compact_signatures_for_proposal(
        joint_db,
        lightwalletd_url,
        network,
        proposal.proposal_id,
        send_flow_id,
        std::slice::from_ref(&proofs),
        std::slice::from_ref(&signatures),
        None,
        None,
    )
    .await
    .map_err(broadcast_error)?;
    let broadcast = match result.status.as_str() {
        StoreAndBroadcastPcztsResult::BROADCASTED => SweepBroadcast::Accepted,
        StoreAndBroadcastPcztsResult::BROADCASTED_STORAGE_FAILED => SweepBroadcast::StorageFailed,
        StoreAndBroadcastPcztsResult::EXPIRED => {
            return fail(
                ErrorCode::ZcashWallet,
                "the sweep expired before it could be sent",
            );
        }
        _ => SweepBroadcast::Unknown,
    };

    // The sweep may be on the network now, so its bytes must come back.
    // `joint.db` keeps the ones it stored. Without them, extract the same
    // transaction again: its binding signature differs, its txid does not.
    let raw = match stored_raw(joint_db, &txid) {
        Ok(Some(raw)) => raw,
        Ok(None) | Err(_) => {
            let extracted = sync::apply_sigs_and_extract(&proofs, &signatures, None, None)
                .map_err(|error| {
                    wallet_error(format!(
                        "the sweep {txid} may be on the network, but its bytes are lost: {error}"
                    ))
                })?;
            if extracted.txid != txid {
                return fail(
                    ErrorCode::ZcashWallet,
                    "the extracted sweep changed its txid",
                );
            }
            extracted.raw_tx
        }
    };
    Ok(JointSweep {
        transaction: CreatedTransaction {
            txid,
            raw,
            expiry_height,
        },
        amount_zatoshi: proposal.amount_zatoshi,
        fee_zatoshi: proposal.fee_zatoshi,
        broadcast,
        message: result.message,
    })
}

fn broadcast_error(failure: WalletFailure) -> PrivateUsdError {
    broadcast_failure(failure.message)
}

/// A broadcast's failure: the node refused the transaction, or the wallet
/// could not send it.
fn broadcast_failure(message: String) -> PrivateUsdError {
    let code = if sync::broadcast_rejected(&message) {
        ErrorCode::ZcashRejected
    } else {
        ErrorCode::ZcashWallet
    };
    PrivateUsdError::new(code, message)
}

fn stored_raw(db: &str, txid: &TxId) -> Result<Option<Vec<u8>>> {
    let conn =
        open_readonly_conn_with_timeout(db, Some(READ_DB_BUSY_TIMEOUT)).map_err(wallet_error)?;
    let raw: Option<Option<Vec<u8>>> = conn
        .query_row(
            "SELECT raw FROM transactions WHERE txid = ?1",
            [txid.as_ref()],
            |row| row.get(0),
        )
        .optional()
        .map_err(sql_error)?;
    Ok(raw.flatten())
}

/// Where a swap's Zcash transaction stands, in the wallet DB that sent it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SwapTxStatus {
    /// Mined at `height`, `confirmations` deep below the fully scanned height
    /// (at least 1).
    Mined { height: u32, confirmations: u32 },
    /// The wallet holds it unmined, and it may still be mined.
    Unmined,
    /// Not mined, and every block past its expiry height is scanned, so it
    /// never will be. Only now may a deposit be built again.
    Expired,
    /// Not in the wallet, and not provably expired.
    Unknown,
}

/// The status of `txid` (internal byte order) in `db`, a main or joint
/// wallet DB, given the expiry height the caller kept with it. An expiry
/// height of 0 means none, so that transaction never expires.
pub(crate) fn swap_tx_status(
    db: &str,
    network: WalletNetwork,
    txid: &TxId,
    expiry_height: u32,
) -> Result<SwapTxStatus> {
    let conn =
        open_readonly_conn_with_timeout(db, Some(READ_DB_BUSY_TIMEOUT)).map_err(wallet_error)?;
    let snapshot = conn.unchecked_transaction().map_err(sql_error)?;
    let fully_scanned = fully_scanned_height(&wallet_db_on(&snapshot, db, network))?;
    let stored: Option<Option<u32>> = snapshot
        .query_row(
            "SELECT mined_height FROM transactions WHERE txid = ?1",
            [txid.as_ref()],
            |row| row.get(0),
        )
        .optional()
        .map_err(sql_error)?;
    Ok(classify(stored, fully_scanned, expiry_height))
}

/// `stored` is `None` for a transaction the wallet does not hold, else its
/// mined height.
fn classify(
    stored: Option<Option<u32>>,
    fully_scanned: Option<u32>,
    expiry_height: u32,
) -> SwapTxStatus {
    if let Some(Some(height)) = stored {
        let confirmations = fully_scanned
            .filter(|scanned| *scanned >= height)
            .map_or(1, |scanned| scanned - height + 1);
        return SwapTxStatus::Mined {
            height,
            confirmations,
        };
    }
    // A transaction can still be mined in the block at its expiry height, so
    // it is expired only once the block after that is scanned too.
    let expired =
        expiry_height != 0 && fully_scanned.is_some_and(|scanned| scanned > expiry_height);
    match (expired, stored.is_some()) {
        (true, _) => SwapTxStatus::Expired,
        (false, true) => SwapTxStatus::Unmined,
        (false, false) => SwapTxStatus::Unknown,
    }
}

fn fully_scanned_height<W>(wallet: &W) -> Result<Option<u32>>
where
    W: WalletRead,
    W::Error: std::fmt::Display,
{
    Ok(wallet
        .block_fully_scanned()
        .map_err(|error| wallet_error(error.to_string()))?
        .map(|block| u32::from(block.block_height())))
}

/// The height through which `db` has scanned every block; `None` before its
/// first scan.
pub(crate) fn scanned_height(db: &str, network: WalletNetwork) -> Result<Option<u32>> {
    let conn =
        open_readonly_conn_with_timeout(db, Some(READ_DB_BUSY_TIMEOUT)).map_err(wallet_error)?;
    fully_scanned_height(&wallet_db_on(&conn, db, network))
}

/// The account's sent transaction to `joint_ua` that may still land, if any:
/// mined, or unmined and not provably expired. A deposit marked started but
/// never kept is looked up here before anything new is built, so it is never
/// paid twice.
pub(crate) fn find_deposit(
    main_db: &str,
    network: WalletNetwork,
    account_uuid: &str,
    joint_ua: &str,
) -> Result<Option<CreatedTransaction>> {
    find_sent(main_db, network, account_uuid, Some(joint_ua))
}

/// The account's newest sent transaction that may still land, to `to` or to
/// anyone: mined, or unmined and not provably expired. A joint account's
/// earlier sweep is found here whatever home address it paid.
pub(crate) fn find_sent(
    db: &str,
    network: WalletNetwork,
    account_uuid: &str,
    to: Option<&str>,
) -> Result<Option<CreatedTransaction>> {
    let account = keys::parse_account_uuid(account_uuid)
        .map_err(|error| PrivateUsdError::new(ErrorCode::Other, error))?;
    let conn =
        open_readonly_conn_with_timeout(db, Some(READ_DB_BUSY_TIMEOUT)).map_err(wallet_error)?;
    let snapshot = conn.unchecked_transaction().map_err(sql_error)?;
    let fully_scanned = fully_scanned_height(&wallet_db_on(&snapshot, db, network))?;
    let mut query = snapshot
        .prepare(
            "SELECT t.txid, t.raw, t.expiry_height, t.mined_height
             FROM transactions t
             WHERE t.id_tx IN (
                 SELECT sn.transaction_id
                 FROM sent_notes sn
                 JOIN accounts a ON a.id = sn.from_account_id
                 WHERE a.uuid = ?1 AND (?2 IS NULL OR sn.to_address = ?2))
             ORDER BY t.id_tx DESC",
        )
        .map_err(sql_error)?;
    let sent = query
        .query_map(
            rusqlite::params![account.expose_uuid().as_bytes().as_slice(), to],
            |row| {
                Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, Option<Vec<u8>>>(1)?,
                    row.get::<_, Option<u32>>(2)?,
                    row.get::<_, Option<u32>>(3)?,
                ))
            },
        )
        .map_err(sql_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(sql_error)?;
    for (txid, raw, expiry_height, mined_height) in sent {
        let txid = TxId::from_bytes(
            txid.try_into()
                .map_err(|_| wallet_error("a stored txid is not 32 bytes"))?,
        );
        // An unknown expiry is treated as none: never expired, never rebuilt.
        let expiry_height = expiry_height.unwrap_or(0);
        if classify(Some(mined_height), fully_scanned, expiry_height) == SwapTxStatus::Expired {
            continue;
        }
        // Fail closed: a deposit the wallet cannot resend is still a deposit.
        let raw = raw.ok_or_else(|| {
            wallet_error(format!(
                "the deposit {txid} is in the wallet but its bytes are not stored yet"
            ))
        })?;
        return Ok(Some(CreatedTransaction {
            txid,
            raw,
            expiry_height,
        }));
    }
    Ok(None)
}

/// What `txid` (internal byte order) sent, as `db` recorded it: the value of
/// its sent outputs, and its fee when the wallet knows it. A sweep found
/// again after an interruption reports its amounts from here.
pub(crate) fn sent_value_and_fee(db: &str, txid: &TxId) -> Result<(u64, Option<u64>)> {
    let conn =
        open_readonly_conn_with_timeout(db, Some(READ_DB_BUSY_TIMEOUT)).map_err(wallet_error)?;
    let snapshot = conn.unchecked_transaction().map_err(sql_error)?;
    let value: Option<i64> = snapshot
        .query_row(
            "SELECT SUM(sn.value) FROM sent_notes sn
             JOIN transactions t ON t.id_tx = sn.transaction_id
             WHERE t.txid = ?1",
            [txid.as_ref()],
            |row| row.get(0),
        )
        .map_err(sql_error)?;
    let fee: Option<Option<i64>> = snapshot
        .query_row(
            "SELECT fee FROM transactions WHERE txid = ?1",
            [txid.as_ref()],
            |row| row.get(0),
        )
        .optional()
        .map_err(sql_error)?;
    let value = u64::try_from(value.unwrap_or_default())
        .map_err(|_| wallet_error("a sent value is negative"))?;
    let fee = fee
        .flatten()
        .map(u64::try_from)
        .transpose()
        .map_err(|_| wallet_error("a stored fee is negative"))?;
    Ok((value, fee))
}

// ---- the wallet's side of a swap ----

/// The Zcash side of a swap over the main wallet DB and `joint.db`.
pub(crate) struct WalletZcash<'a> {
    pub main_db: &'a str,
    pub lightwalletd_url: &'a str,
    pub network: WalletNetwork,
    pub account_uuid: &'a str,
    pub store_dir: &'a Path,
    pub keys: &'a SwapKeyContext,
    /// The call's cancel flag: a joint scan stops on it between batches.
    pub cancel: Arc<AtomicBool>,
}

/// A deposit proposal in `PROPOSAL_STORE`, under its send flow.
pub(crate) struct DepositProposal {
    proposal_id: u64,
    send_flow_id: String,
}

/// A joint account's balance swept home.
pub(crate) struct SweptHome {
    pub transaction: CreatedTransaction,
    /// What reached the home address, and the fee, as far as the wallet
    /// knows them (an earlier sweep found again may not record its fee).
    pub amount_zatoshi: u64,
    pub fee_zatoshi: Option<u64>,
}

impl WalletZcash<'_> {
    fn joint_db(&self) -> String {
        joint_db_path(self.store_dir)
    }

    async fn tip(&self) -> Result<u64> {
        sync_engine::latest_block_for_transaction(self.lightwalletd_url, self.network)
            .await
            .map(|tip| tip.height)
            .map_err(|error| wallet_error(format!("read the Zcash chain tip: {error}")))
    }

    /// Imports `direction`'s swap `index`'s joint account at its exact
    /// birthday, idempotently, and indexes it in `swaps.db`. It takes the
    /// process-wide wallet write lock, so it may wait on a batch of the main
    /// sync.
    fn import_joint(
        &self,
        direction: Direction,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
    ) -> Result<String> {
        let ufvk = joint.ufvk(self.network.network_type());
        let birthday = u32::try_from(birthday).map_err(|_| {
            PrivateUsdError::new(ErrorCode::Other, "the joint account's birthday is too high")
        })?;
        let joint_uuid = register_joint_account(&self.joint_db(), self.network, &ufvk, birthday)?;
        let mut store = SwapStore::open(self.store_dir)?;
        with_operations(|| {
            store.put_joint_account(&JointAccountRow {
                account_uuid: self.account_uuid.to_owned(),
                direction,
                swap_index: index,
                joint_uuid: joint_uuid.clone(),
                ufvk,
                birthday: u64::from(birthday),
            })
        })?;
        Ok(joint_uuid)
    }

    /// The joint account imported (idempotently, so a lost `joint.db` heals
    /// by rescanning from the exact birthday) and `joint.db` scanned to the
    /// tip. The scan's writes take the process-wide wallet write lock.
    async fn synced_joint(
        &self,
        direction: Direction,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
    ) -> Result<String> {
        let joint_uuid = self.import_joint(direction, index, joint, birthday)?;
        sync_joint_db(
            &self.joint_db(),
            self.lightwalletd_url,
            self.network,
            self.cancel.clone(),
        )
        .await?;
        Ok(joint_uuid)
    }

    /// Where `transaction`, sent from the joint account, stands in
    /// `joint.db`, once synced.
    async fn joint_tx_status(
        &self,
        direction: Direction,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
        transaction: &ZcashTransaction,
    ) -> Result<SwapTxStatus> {
        self.synced_joint(direction, index, joint, birthday).await?;
        swap_tx_status(
            &self.joint_db(),
            self.network,
            &internal_txid(&transaction.tx_id)?,
            expiry(transaction),
        )
    }

    /// The joint account's whole balance swept home with the combined `key`
    /// and Discard OVK: an earlier sweep that may still land is returned
    /// again, never built twice; `None` until every note is spendable. The
    /// sweep pays at most `max_fee_zatoshi` (a forward refund's default when
    /// `None`), and at least ZIP 317's least fee.
    async fn sweep_home(
        &self,
        direction: Direction,
        index: u32,
        joint: &JointAccount,
        key: &SpendKey,
        birthday: u64,
        max_fee_zatoshi: Option<u64>,
        send_flow_id: &str,
    ) -> Result<Option<SweptHome>> {
        let joint_uuid = self.synced_joint(direction, index, joint, birthday).await?;
        let joint_db = self.joint_db();
        if let Some(earlier) = find_sent(&joint_db, self.network, &joint_uuid, None)? {
            let (amount_zatoshi, fee_zatoshi) = sent_value_and_fee(&joint_db, &earlier.txid)?;
            return Ok(Some(SweptHome {
                transaction: earlier,
                amount_zatoshi,
                fee_zatoshi,
            }));
        }
        let receipts = joint_receipts(
            &joint_db,
            self.network,
            &joint_uuid,
            crate::wallet::JOINT_SWEEP_CONFIRMATIONS,
        )?;
        // The whole balance at once, so no note is left behind.
        if receipts.spendable_zatoshi == 0 || receipts.pending_zatoshi > 0 {
            return Ok(None);
        }
        let fee_limit = max_fee_zatoshi
            .unwrap_or(MAX_SWEEP_FEE_ZATOSHI)
            .min(receipts.spendable_zatoshi - 1);
        if fee_limit < u64::from(zip317::MINIMUM_FEE) {
            return fail(
                ErrorCode::ZcashWallet,
                "the joint account does not cover a sweep's fee",
            );
        }
        let home = keys::get_address_from_db(self.main_db, self.network, Some(self.account_uuid))
            .map_err(wallet_error)?;
        let swept = sweep_joint(
            &joint_db,
            self.lightwalletd_url,
            self.network,
            &joint_uuid,
            send_flow_id,
            &home,
            fee_limit,
            key,
        )
        .await?;
        Ok(Some(SweptHome {
            transaction: swept.transaction,
            amount_zatoshi: swept.amount_zatoshi,
            fee_zatoshi: Some(swept.fee_zatoshi),
        }))
    }

    /// Sends a kept transaction once more.
    async fn broadcast_kept(&self, transaction: &ZcashTransaction) -> Result<()> {
        let raw = hex::decode(&transaction.raw).map_err(|_| {
            PrivateUsdError::new(ErrorCode::StoreUnreadable, "a kept transaction is not hex")
        })?;
        sync::broadcast_raw(self.lightwalletd_url, &raw)
            .await
            .map_err(broadcast_failure)
    }

    /// Forgets `direction`'s swap `index`'s joint account once nothing more
    /// can come from it.
    fn forget_joint(&self, direction: Direction, index: u32) -> Result<()> {
        let rows: Vec<JointAccountRow> = SwapStore::open(self.store_dir)?
            .joint_accounts()?
            .into_iter()
            .filter(|row| {
                row.account_uuid == self.account_uuid
                    && row.direction == direction
                    && row.swap_index == index
            })
            .collect();
        for row in rows {
            forget_joint_account(&self.joint_db(), self.network, &row.joint_uuid)?;
            let mut store = SwapStore::open(self.store_dir)?;
            with_operations(|| store.remove_joint_account(self.account_uuid, direction, index))?;
        }
        Ok(())
    }
}

impl ForwardZcash for WalletZcash<'_> {
    type Proposal = DepositProposal;

    async fn chain_height(&self) -> Result<u64> {
        self.tip().await
    }

    async fn synced(&self) -> Result<bool> {
        let scanned = scanned_height(self.main_db, self.network)?;
        let tip = self.tip().await?;
        Ok(scanned.is_some_and(|scanned| u64::from(scanned) >= tip))
    }

    async fn deposit_fee(&self, address: &str, zatoshi: u64) -> Result<Option<u64>> {
        sync::estimate_swap_deposit_fee(
            self.main_db,
            self.network,
            self.account_uuid,
            address,
            zatoshi,
        )
        .map_err(wallet_error)
    }

    async fn propose_deposit(
        &self,
        index: u32,
        address: &str,
        zatoshi: u64,
        max_total_zatoshi: u64,
    ) -> Result<DepositProposal> {
        let send_flow_id = format!("private-usd-deposit:{}:{index}", self.account_uuid);
        let proposal = sync::propose_swap_deposit(
            self.main_db,
            self.network,
            self.account_uuid,
            &send_flow_id,
            address,
            zatoshi,
            max_total_zatoshi,
        )
        .map_err(|error| match error {
            SwapDepositError::Unpayable(message) => {
                PrivateUsdError::new(ErrorCode::DepositUnpayable, message)
            }
            SwapDepositError::Wallet(message) => wallet_error(message),
        })?;
        let needs_sapling_params = proposal.needs_sapling_params;
        let proposal = DepositProposal {
            proposal_id: proposal.proposal_id,
            send_flow_id,
        };
        // Spending Sapling notes needs the Sapling proving parameters, which
        // Private USD does not download.
        if needs_sapling_params {
            self.discard_deposit(proposal);
            return fail(
                ErrorCode::DepositUnpayable,
                "the deposit would spend Sapling funds, which Private USD cannot prove yet",
            );
        }
        Ok(proposal)
    }

    async fn create_deposit(&self, proposal: DepositProposal) -> Result<ZcashTransaction> {
        let created = sync::create_stored_proposal_transactions(
            self.main_db,
            self.lightwalletd_url,
            proposal.proposal_id,
            &proposal.send_flow_id,
            self.keys.seed(),
            None,
            None,
        )
        .await
        .map_err(wallet_error)?;
        match created.as_slice() {
            [deposit] => kept_transaction(deposit),
            _ => fail(
                ErrorCode::ZcashWallet,
                "the deposit was not one transaction",
            ),
        }
    }

    fn discard_deposit(&self, proposal: DepositProposal) {
        if sync::discard_proposal(proposal.proposal_id, &proposal.send_flow_id).is_err() {
            log::warn!("private usd: releasing a deposit proposal failed");
        }
    }

    async fn find_deposit(&self, address: &str) -> Result<Option<ZcashTransaction>> {
        find_deposit(self.main_db, self.network, self.account_uuid, address)?
            .as_ref()
            .map(kept_transaction)
            .transpose()
    }

    async fn deposit_status(&self, deposit: &ZcashTransaction) -> Result<SwapTxStatus> {
        swap_tx_status(
            self.main_db,
            self.network,
            &internal_txid(&deposit.tx_id)?,
            expiry(deposit),
        )
    }

    async fn broadcast(&self, transaction: &ZcashTransaction) -> Result<()> {
        self.broadcast_kept(transaction).await
    }

    async fn prepare_sweep(
        &self,
        index: u32,
        joint: &JointAccount,
        key: &SpendKey,
        birthday: u64,
    ) -> Result<Option<ZcashTransaction>> {
        let send_flow_id = format!("private-usd-sweep:{}:{index}", self.account_uuid);
        self.sweep_home(
            Direction::Forward,
            index,
            joint,
            key,
            birthday,
            None,
            &send_flow_id,
        )
        .await?
        .map(|swept| kept_transaction(&swept.transaction))
        .transpose()
    }

    async fn sweep_status(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
        sweep: &ZcashTransaction,
    ) -> Result<SwapTxStatus> {
        self.joint_tx_status(Direction::Forward, index, joint, birthday, sweep)
            .await
    }

    async fn forget_joint_account(&self, index: u32) -> Result<()> {
        self.forget_joint(Direction::Forward, index)
    }
}

impl ReverseZcash for WalletZcash<'_> {
    async fn chain_height(&self) -> Result<u64> {
        self.tip().await
    }

    async fn import_account(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
    ) -> Result<JointAccountId> {
        let joint_uuid = self.import_joint(Direction::Reverse, index, joint, birthday)?;
        let uuid = uuid::Uuid::parse_str(&joint_uuid)
            .map_err(|_| wallet_error("a joint account id is not a UUID"))?;
        Ok(JointAccountId(uuid.into_bytes()))
    }

    async fn estimate_receive(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
        confirmations: u32,
    ) -> Result<ReverseReceiveEstimate> {
        let joint_uuid = self
            .synced_joint(Direction::Reverse, index, joint, birthday)
            .await?;
        let receipts = joint_receipts(&self.joint_db(), self.network, &joint_uuid, confirmations)?;
        Ok(ReverseReceiveEstimate {
            available_zat: receipts.confirmed_zatoshi,
            fee_zat: sweep_fee_estimate(receipts.confirmed_notes),
        })
    }

    async fn prepare_receive(
        &self,
        index: u32,
        joint: &JointAccount,
        key: &SpendKey,
        birthday: u64,
        max_fee_zatoshi: Option<u64>,
    ) -> Result<Option<ReverseReceiveTransaction>> {
        let send_flow_id = format!("private-usd-receive:{}:{index}", self.account_uuid);
        let Some(swept) = self
            .sweep_home(
                Direction::Reverse,
                index,
                joint,
                key,
                birthday,
                max_fee_zatoshi,
                &send_flow_id,
            )
            .await?
        else {
            return Ok(None);
        };
        let kept = kept_transaction(&swept.transaction)?;
        Ok(Some(ReverseReceiveTransaction {
            tx_id: kept.tx_id,
            raw: kept.raw,
            expiry_height: kept.expiry_height,
            received_zat: swept.amount_zatoshi,
            fee_zat: swept.fee_zatoshi.unwrap_or_default(),
        }))
    }

    async fn receive_status(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
        receive: &ZcashTransaction,
    ) -> Result<SwapTxStatus> {
        self.joint_tx_status(Direction::Reverse, index, joint, birthday, receive)
            .await
    }

    async fn broadcast(&self, transaction: &ZcashTransaction) -> Result<()> {
        self.broadcast_kept(transaction).await
    }

    async fn forget(&self, index: u32) -> Result<()> {
        self.forget_joint(Direction::Reverse, index)
    }
}

/// ZIP 317's fee for sweeping `notes` notes home in one transaction, the
/// least charge included: an action a note, and one for the output.
fn sweep_fee_estimate(notes: u32) -> u64 {
    let actions = u64::from(notes) + 1;
    u64::from(zip317::MARGINAL_FEE) * actions.max(zip317::GRACE_ACTIONS as u64)
}

/// `joint.db` in a wallet's Private USD directory.
pub(crate) fn joint_db_path(store_dir: &Path) -> String {
    store_dir.join(JOINT_DB_FILE).to_string_lossy().into_owned()
}

/// A created transaction as a record keeps it: its id in display order, its
/// bytes in hex.
pub(crate) fn kept_transaction(created: &CreatedTransaction) -> Result<ZcashTransaction> {
    let tx_id = ZcashTxId::parse(&created.txid.to_string())
        .ok_or_else(|| wallet_error("a created transaction has no id"))?;
    Ok(ZcashTransaction {
        tx_id,
        raw: hex::encode(&created.raw),
        expiry_height: u64::from(created.expiry_height),
    })
}

/// A kept transaction's expiry height, as the wallet DB compares it.
pub(crate) fn expiry(transaction: &ZcashTransaction) -> u32 {
    u32::try_from(transaction.expiry_height).unwrap_or(u32::MAX)
}

/// A record's transaction id (display order) as the wallet DB stores it:
/// internal byte order.
pub(crate) fn internal_txid(tx_id: &ZcashTxId) -> Result<TxId> {
    let mut bytes = [0u8; 32];
    hex::decode_to_slice(tx_id.as_str(), &mut bytes).map_err(|_| {
        PrivateUsdError::new(
            ErrorCode::StoreUnreadable,
            "a kept transaction id is not hex",
        )
    })?;
    bytes.reverse();
    Ok(TxId::from_bytes(bytes))
}
