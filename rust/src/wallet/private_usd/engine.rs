//! The swap engine's process-wide state: one driver step per account at a
//! time, the forward offers quoted but not accepted yet, the reverse fundings
//! handed to the Railgun page to prove, and the FRB calls in flight with their
//! cancel flags and current activity. None of it is persisted.
//!
//! - A driver step holds its account's guard for its whole run, network I/O
//!   included; a second caller gets `Busy`.
//! - An offer lives until its quote expires or the wallet locks
//!   ([`clear_sessions`]). The forward quote is never persisted and never
//!   crosses to Dart: a missing offer at accept is `QuoteExpired`.
//! - A reverse funding lives from its request until its proof is submitted,
//!   the wallet locks or the account is deleted: a proof that finishes after
//!   a lock is never submitted.
//! - A call registered with [`OpHandle::begin`] can be cancelled by its id and
//!   reports what it is doing until it returns.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

use super::joint::{self, joint_db_path};
use super::models::{Amount, ReverseRecord, SwapQuote};
use super::store::SwapStore;
use super::{lock, with_operations, ErrorCode, PrivateUsdError, PrivateUsdNetwork, Result};
use crate::wallet::network::WalletNetwork;

// ---- per-account locks ----

/// One async lock per account.
pub(crate) struct AccountLocks(LazyLock<Mutex<HashMap<String, Arc<AsyncMutex<()>>>>>);

impl AccountLocks {
    pub(crate) const fn new() -> Self {
        Self(LazyLock::new(Default::default))
    }

    /// `account`'s lock, to wait for or try.
    pub(crate) fn of(&self, account: &str) -> Arc<AsyncMutex<()>> {
        lock(&self.0).entry(account.to_owned()).or_default().clone()
    }

    /// Takes `account`'s lock, or `Busy` with `busy` while another holds it.
    pub(crate) fn try_lock(&self, account: &str, busy: &str) -> Result<AccountGuard> {
        self.of(account)
            .try_lock_owned()
            .map(|guard| AccountGuard { _guard: guard })
            .map_err(|_| PrivateUsdError::new(ErrorCode::Busy, busy))
    }
}

/// An account's lock, released when dropped.
pub(crate) struct AccountGuard {
    _guard: OwnedMutexGuard<()>,
}

/// Driver steps: without the lock, an accept and the engine loop would
/// overwrite each other's `t0` and ticket.
static DRIVER_LOCKS: AccountLocks = AccountLocks::new();

/// Takes `account`'s driver lock, or `Busy` while another step holds it.
pub(crate) fn lock_account(account: &str) -> Result<AccountGuard> {
    DRIVER_LOCKS.try_lock(
        account,
        "another step of this account's conversion is running",
    )
}

/// Removes everything Private USD keeps for `account`: its joint accounts in
/// `joint.db` first, then its rows in `swaps.db` (its deposits included), so
/// a failure leaves the rows to retry with. `Busy` while one of its driver
/// steps or deposit passes runs: a step that saved after the delete would
/// bring a record back. The caller warned the user and drained the engine
/// first.
pub(crate) fn delete_account(
    store_dir: &Path,
    network: WalletNetwork,
    account: &str,
) -> Result<()> {
    let _driver = lock_account(account)?;
    let _deposits = super::deposits::lock_account(account)?;
    remove_account_offers(account);
    remove_account_fundings(account);
    let Some(mut store) = SwapStore::open_existing(store_dir)? else {
        return Ok(());
    };
    let joint_db = joint_db_path(store_dir);
    for row in store
        .joint_accounts()?
        .into_iter()
        .filter(|row| row.account_uuid == account)
    {
        joint::forget_joint_account(&joint_db, network, &row.joint_uuid)?;
    }
    with_operations(|| store.delete_account(account))
}

// ---- forward offers ----

/// A forward quote for one swap index, not accepted yet.
#[derive(Clone, Debug)]
pub(crate) struct Offer {
    pub network: PrivateUsdNetwork,
    pub quote: SwapQuote,
    /// The relayer's fee when quoted, which the payout pays until
    /// `fee_expires_at`.
    pub relayer_fee: Amount,
    pub fee_expires_at: Option<u64>,
    /// What reaches Railgun after the relayer's and Railgun's fees.
    pub receives: Amount,
    /// The deposit's network fee from this wallet now; `None` when one
    /// transaction cannot pay it, which makes the offer unpayable.
    pub deposit_fee_zatoshi: Option<u64>,
}

impl Offer {
    /// What the deposit may cost in all: the amount and its fee.
    pub(crate) fn max_total_zatoshi(&self) -> Option<u64> {
        self.deposit_fee_zatoshi
            .and_then(|fee| self.quote.deposit_zat.checked_add(fee))
    }

    fn expired(&self, now: u64) -> bool {
        now >= self.quote.expires_at
    }
}

static OFFERS: LazyLock<Mutex<HashMap<(String, u32), Offer>>> = LazyLock::new(Default::default);
/// Bumped by every [`clear_sessions`], under the `OFFERS` lock.
static SESSION: AtomicU64 = AtomicU64::new(0);

/// The current session: a quote takes it before it starts.
pub(crate) fn session() -> u64 {
    SESSION.load(Ordering::Acquire)
}

/// Holds `offer` for `account`'s swap `index` until its quote expires,
/// dropping the account's expired ones. An offer quoted in an earlier
/// `session` (the wallet locked meanwhile) is never held.
pub(crate) fn put_offer(account: &str, index: u32, offer: Offer, now: u64, session: u64) {
    let mut offers = lock(&OFFERS);
    if SESSION.load(Ordering::Acquire) != session {
        return;
    }
    offers.retain(|(held_account, _), held| held_account != account || !held.expired(now));
    offers.insert((account.to_owned(), index), offer);
}

/// The offer held for `account`'s swap `index` on `network`, unless it
/// expired.
pub(crate) fn offer(
    account: &str,
    index: u32,
    network: PrivateUsdNetwork,
    now: u64,
) -> Option<Offer> {
    let mut offers = lock(&OFFERS);
    let key = (account.to_owned(), index);
    if offers.get(&key).is_some_and(|held| held.expired(now)) {
        offers.remove(&key);
    }
    offers
        .get(&key)
        .filter(|held| held.network == network)
        .cloned()
}

pub(crate) fn remove_offer(account: &str, index: u32) {
    lock(&OFFERS).remove(&(account.to_owned(), index));
}

/// Drops every offer of `account`, as its deletion does.
pub(crate) fn remove_account_offers(account: &str) {
    lock(&OFFERS).retain(|(held, _), _| held != account);
}

/// Which makers' `/v1/info` already matched the pins this session, for which
/// direction (a reverse conversion also needs `reverseEnabled`). Cleared with
/// the offers.
#[derive(Default)]
pub(crate) struct MakerChecks(Mutex<HashSet<(PrivateUsdNetwork, bool)>>);

impl MakerChecks {
    pub(crate) fn checked(&self, network: PrivateUsdNetwork, reverse: bool) -> bool {
        lock(&self.0).contains(&(network, reverse))
    }

    pub(crate) fn mark(&self, network: PrivateUsdNetwork, reverse: bool) {
        lock(&self.0).insert((network, reverse));
    }

    fn clear(&self) {
        lock(&self.0).clear();
    }
}

pub(crate) static MAKER_CHECKS: LazyLock<MakerChecks> = LazyLock::new(Default::default);

/// Forgets every offer, reverse funding and maker check: the wallet locked.
/// A quote made before the lock is never accepted after it, and a funding
/// proved across it is never submitted.
pub(crate) fn clear_sessions() {
    let mut offers = lock(&OFFERS);
    SESSION.fetch_add(1, Ordering::AcqRel);
    offers.clear();
    drop(offers);
    lock(&FUNDINGS).clear();
    MAKER_CHECKS.clear();
}

// ---- reverse fundings ----

/// A reverse swap's funding as Rust handed it to the Railgun page to prove:
/// kept in memory only, until the proof comes back.
#[derive(Clone, Debug)]
pub(crate) struct FundingSession {
    pub network: PrivateUsdNetwork,
    /// The record when its `OpenReverse` was signed: a proof is submitted
    /// only while the record is unchanged.
    pub record: ReverseRecord,
    /// The relayer fee the calls pay, and until when the relayer takes it.
    pub fee: Amount,
    pub fee_expires_at: Option<u64>,
    /// The relayer's pinned Relay Adapt and calldata limit when signed.
    pub relay_adapt: [u8; 20],
    pub max_calldata_bytes: u32,
}

static FUNDINGS: LazyLock<Mutex<HashMap<(String, u32), FundingSession>>> =
    LazyLock::new(Default::default);

/// Holds `funding` for `account`'s swap `index` until its proof comes back;
/// one made in an earlier `session` (the wallet locked meanwhile) is never
/// held.
pub(crate) fn put_funding(account: &str, index: u32, funding: FundingSession, session: u64) {
    let mut fundings = lock(&FUNDINGS);
    if SESSION.load(Ordering::Acquire) != session {
        return;
    }
    fundings.insert((account.to_owned(), index), funding);
}

/// Takes the funding held for `account`'s swap `index` on `network`: one
/// proof is submitted once.
pub(crate) fn take_funding(
    account: &str,
    index: u32,
    network: PrivateUsdNetwork,
) -> Option<FundingSession> {
    lock(&FUNDINGS)
        .remove(&(account.to_owned(), index))
        .filter(|held| held.network == network)
}

/// Drops every funding of `account`, as its deletion does.
pub(crate) fn remove_account_fundings(account: &str) {
    lock(&FUNDINGS).retain(|(held, _), _| held != account);
}

// ---- calls in flight ----

/// What a call is doing now, for the progress screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Activity {
    Depositing,
    Claiming,
    PayingOut,
    Sweeping,
    /// Sending a kept reverse funding (again).
    Funding,
    /// Sending the saved `ready` again.
    Readying,
    /// Locking, revealing or paying out a reverse refund.
    Refunding,
}

struct OpState {
    cancel: Arc<AtomicBool>,
    activity: Mutex<Option<Activity>>,
}

#[derive(Default)]
struct OpRegistry {
    running: HashMap<u32, Arc<OpState>>,
    /// Ids cancelled before their call registered: Dart cancels the call it
    /// started, which may still be queued for a worker thread.
    cancelled_early: VecDeque<u32>,
}

/// How many early cancels are remembered.
const CANCELLED_EARLY_KEPT: usize = 64;

static OPS: LazyLock<Mutex<OpRegistry>> = LazyLock::new(Default::default);

/// One FRB call that can be cancelled by its id, registered until dropped.
pub(crate) struct OpHandle {
    id: u32,
    state: Arc<OpState>,
}

impl OpHandle {
    /// Registers call `id`. `Busy` if a call with that id is running.
    pub(crate) fn begin(id: u32) -> Result<Self> {
        let mut ops = lock(&OPS);
        if ops.running.contains_key(&id) {
            return Err(PrivateUsdError::new(
                ErrorCode::Busy,
                "a call with this id is running",
            ));
        }
        let cancelled = match ops.cancelled_early.iter().position(|early| *early == id) {
            Some(position) => {
                ops.cancelled_early.remove(position);
                true
            }
            None => false,
        };
        let state = Arc::new(OpState {
            cancel: Arc::new(AtomicBool::new(cancelled)),
            activity: Mutex::new(None),
        });
        ops.running.insert(id, state.clone());
        Ok(Self { id, state })
    }

    pub(crate) fn cancelled(&self) -> bool {
        self.state.cancel.load(Ordering::Acquire)
    }

    /// The flag the call's network requests and scans stop on.
    pub(crate) fn cancel_flag(&self) -> Arc<AtomicBool> {
        self.state.cancel.clone()
    }

    fn set_activity(&self, activity: Activity) {
        *lock(&self.state.activity) = Some(activity);
    }
}

impl Drop for OpHandle {
    fn drop(&mut self) {
        let mut ops = lock(&OPS);
        if ops
            .running
            .get(&self.id)
            .is_some_and(|running| Arc::ptr_eq(running, &self.state))
        {
            ops.running.remove(&self.id);
        }
    }
}

/// Cancels call `id`: it stops at its next safe point. Never between saving
/// a deposit as started and keeping its transaction.
pub(crate) fn cancel_op(id: u32) {
    let mut ops = lock(&OPS);
    if let Some(running) = ops.running.get(&id) {
        running.cancel.store(true, Ordering::Release);
        return;
    }
    if !ops.cancelled_early.contains(&id) {
        if ops.cancelled_early.len() == CANCELLED_EARLY_KEPT {
            ops.cancelled_early.pop_front();
        }
        ops.cancelled_early.push_back(id);
    }
}

/// What call `id` is doing now, while it runs.
pub(crate) fn op_activity(id: u32) -> Option<Activity> {
    let state = lock(&OPS).running.get(&id).cloned()?;
    let activity = *lock(&state.activity);
    activity
}

/// Shows `activity` as what the call `op` does now.
pub(crate) fn set_activity(op: Option<&OpHandle>, activity: Activity) {
    if let Some(op) = op {
        op.set_activity(activity);
    }
}

/// Stops at a safe point once the call `op` is cancelled.
pub(crate) fn check_cancelled(op: Option<&OpHandle>) -> Result<()> {
    if op.is_some_and(OpHandle::cancelled) {
        return Err(cancelled());
    }
    Ok(())
}

/// A call that stopped because it was cancelled: never a failure, so never a
/// problem shown to the user.
pub(crate) fn cancelled() -> PrivateUsdError {
    PrivateUsdError::new(ErrorCode::Cancelled, "cancelled")
}

// ---- the clock ----

/// The device's clock, and waiting. Engine tests fake both.
pub(crate) trait Clock {
    /// Unix seconds on this device.
    fn now(&self) -> u64;
    async fn sleep(&self, duration: Duration);
}

pub(crate) struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs())
            .unwrap_or_default()
    }

    async fn sleep(&self, duration: Duration) {
        tokio::time::sleep(duration).await;
    }
}

// ---- problems ----

/// A failed step is tried again after this.
pub(crate) const RETRY_DELAY: Duration = Duration::from_secs(15);

/// The problem a failed step shows, after a minute of failures: the codes
/// the progress screens have copy for, and `Other` for the unexpected.
pub(crate) fn problem(code: ErrorCode) -> ErrorCode {
    use ErrorCode::*;
    match code {
        RelayerUnreachable | RelayerRefused | RelayerFee | EthereumUnreachable | RailgunClosed
        | ClaimTurn | ZcashWallet | DepositUnpayable | ZcashRejected | Mismatch | RouteBlocked => {
            code
        }
        ChainLagging | ChainUnreadable => EthereumUnreachable,
        // A service serving another deployment reads as the relayer being
        // unreachable.
        WrongDeployment => RelayerUnreachable,
        _ => Other,
    }
}
