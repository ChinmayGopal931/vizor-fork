//! A swap's joint account in `joint.db`, and the swap transactions the wallet
//! follows (`docs/private-usd-reference.md` §8.1).
//!
//! The joint account is the Orchard-only account whose spend authorizing key
//! is split: the maker holds `e`, the user holds `z`. The wallet imports it by
//! its viewing key, scans it, and sweeps it home with the combined key
//! `±(e+z)` once it knows both halves. `joint.db` is a librustzcash wallet of
//! its own, so joint accounts never appear in the main wallet's account list,
//! sync status, voting or migration.
//!
//! The deposit into a joint account comes from the main wallet
//! (`crate::wallet::sync::propose_swap_deposit`); [`find_deposit`] and
//! [`swap_tx_status`] follow it there.
//!
//! `OPERATIONS` is held around the short local writes here (import, delete),
//! never across network I/O. librustzcash writes also take the process-wide
//! wallet write lock. One scan of a `joint.db` runs at a time.

use std::collections::HashSet;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, LazyLock, Mutex};

use rusqlite::OptionalExtension;
use zcash_client_backend::data_api::{Account as _, AccountPurpose, WalletRead, WalletWrite};
use zcash_keys::keys::UnifiedFullViewingKey;
use zcash_primitives::transaction::TxId;
use zcash_protocol::consensus::Parameters;
use zecswap_core::{SpendKey, SweepIntent};

use super::{fail, ErrorCode, PrivateUsdError, Result, OPERATIONS};
use crate::wallet::db::{
    open_readonly_conn_with_timeout, open_wallet_db_with_timeout, wallet_db_on,
    with_wallet_db_write_lock, ACCOUNT_MUTATION_DB_BUSY_TIMEOUT, READ_DB_BUSY_TIMEOUT,
};
use crate::wallet::failure::WalletFailure;
use crate::wallet::network::WalletNetwork;
use crate::wallet::sync::{self, CreatedTransaction, StoreAndBroadcastPcztsResult, SwapProposal};
use crate::wallet::{keys, sync_engine};

/// The name and key source a joint account is imported under.
const JOINT_ACCOUNT_NAME: &str = "Private USD joint";
const JOINT_KEY_SOURCE: &str = "vizor-private-usd-joint";

fn wallet_error(message: impl Into<String>) -> PrivateUsdError {
    PrivateUsdError::new(ErrorCode::ZcashWallet, message)
}

fn sql_error(error: rusqlite::Error) -> PrivateUsdError {
    wallet_error(error.to_string())
}

/// Imports a swap's joint account into `joint_db` by its UFVK, at exactly
/// `birthday_height`: rounding it down would rescan up to 10,000 blocks
/// inside a swap's deadlines (§3.5 item 12). It is a spending account with no
/// derivation, never view-only, so the wallet tracks the notes a sweep
/// spends. Registering the same key again returns the same account.
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

    let _guard = OPERATIONS.lock().unwrap_or_else(|error| error.into_inner());
    keys::ensure_db_migrated_once(joint_db, network).map_err(wallet_error)?;
    let registered: std::result::Result<Result<String>, String> =
        with_wallet_db_write_lock("private_usd.register_joint_account", || {
            let mut db =
                open_wallet_db_with_timeout(joint_db, network, ACCOUNT_MUTATION_DB_BUSY_TIMEOUT)?;
            if let Some(account) = db.get_account_for_ufvk(&ufvk).map_err(|e| e.to_string())? {
                return Ok(match account.purpose() {
                    AccountPurpose::Spending { .. } => Ok(account.id().expose_uuid().to_string()),
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
}

/// Forgets a joint account, once its sweep is confirmed or its swap no longer
/// needs it.
pub(crate) fn delete_joint_account(
    joint_db: &str,
    network: WalletNetwork,
    joint_uuid: &str,
) -> Result<()> {
    let _guard = OPERATIONS.lock().unwrap_or_else(|error| error.into_inner());
    keys::delete_account(joint_db, network, joint_uuid).map_err(wallet_error)
}

/// The `joint.db` paths a scan is running on.
static SCANNING: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(Default::default);

/// One running scan of a `joint.db`, released when dropped.
struct ScanClaim(String);

impl ScanClaim {
    fn take(joint_db: &str) -> Result<Self> {
        let mut scanning = SCANNING.lock().unwrap_or_else(|error| error.into_inner());
        if !scanning.insert(joint_db.to_string()) {
            return fail(ErrorCode::Busy, "the joint wallet is already scanning");
        }
        Ok(Self(joint_db.to_string()))
    }
}

impl Drop for ScanClaim {
    fn drop(&mut self) {
        SCANNING
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .remove(&self.0);
    }
}

/// Scans `joint_db` to the chain tip with the isolated claim scan, which also
/// sends its unmined sweep again. `cancel` stops it between batches.
///
/// A `joint.db` whose accounts are all born above the tip has nothing to scan
/// yet, and the claim scan's completion checks would fail on it: no block is
/// stored at the tip. This returns at once until the chain reaches the
/// birthday (U6; zecSwap's `born_above`).
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
    let tip = sync_engine::latest_block_for_transaction(lightwalletd_url, network)
        .await
        .map_err(|error| wallet_error(format!("read the chain tip: {error}")))?;
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
    pub broadcast: SweepBroadcast,
    pub message: Option<String>,
}

/// Sweeps everything in a joint account to `home_ua` with the combined key
/// `key` (`±(e+z)`): propose, create the PCZT, sign the unredacted base
/// against a `SweepIntent`, extract the compact signatures, prove, then
/// broadcast and store through the hardware completion path (§8.1).
///
/// - The sweep discards its OVK (D12), pays `home_ua` the whole balance less
///   the fee, and pays at most `max_fee_zatoshi`.
/// - Broadcast comes before storage, so a rejected sweep leaves the joint
///   notes unspent (§3.5 item 9).
/// - PCZT creation consumes the proposal; every other exit discards it, which
///   never releases a reservation a broadcast has started (item 10).
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
        log::warn!("private_usd: releasing a joint sweep proposal failed: {error}");
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
    let code = if failure.message.starts_with("Broadcast rejected:") {
        ErrorCode::ZcashRejected
    } else {
        ErrorCode::ZcashWallet
    };
    PrivateUsdError::new(code, failure.message)
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

/// Where a swap's Zcash transaction stands, in the wallet DB that sent it
/// (zapp `SwapZcashTransactions.status`).
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
    // it is expired only once the block after that is scanned too (zecSwap's
    // `is_expired`).
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

/// The account's sent transaction to `joint_ua` that may still land, if any:
/// mined, or unmined and not provably expired. A deposit marked started but
/// never kept is looked up here before anything new is built, so it is never
/// paid twice (§3.5 item 3, zapp `findDeposit`).
pub(crate) fn find_deposit(
    main_db: &str,
    network: WalletNetwork,
    account_uuid: &str,
    joint_ua: &str,
) -> Result<Option<CreatedTransaction>> {
    let account = keys::parse_account_uuid(account_uuid)
        .map_err(|error| PrivateUsdError::new(ErrorCode::Other, error))?;
    let conn = open_readonly_conn_with_timeout(main_db, Some(READ_DB_BUSY_TIMEOUT))
        .map_err(wallet_error)?;
    let snapshot = conn.unchecked_transaction().map_err(sql_error)?;
    let fully_scanned = fully_scanned_height(&wallet_db_on(&snapshot, main_db, network))?;
    let mut query = snapshot
        .prepare(
            "SELECT t.txid, t.raw, t.expiry_height, t.mined_height
             FROM transactions t
             WHERE t.id_tx IN (
                 SELECT sn.transaction_id
                 FROM sent_notes sn
                 JOIN accounts a ON a.id = sn.from_account_id
                 WHERE a.uuid = ?1 AND sn.to_address = ?2)
             ORDER BY t.id_tx DESC",
        )
        .map_err(sql_error)?;
    let sent = query
        .query_map(
            rusqlite::params![account.expose_uuid().as_bytes().as_slice(), joint_ua],
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
