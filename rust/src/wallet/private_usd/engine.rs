//! The swap engine's process-wide state (plan §5.10, reference §5.10 "vizor
//! engine"): one driver step per account at a time, the forward offers quoted
//! but not accepted yet, the reverse fundings handed to the Railgun page to
//! prove, and the FRB calls in flight with their cancel flags and current
//! activity. None of it is persisted.
//!
//! - A driver step holds its account's [`DriverGuard`] for its whole run,
//!   network I/O included; a second caller gets `Busy`. `OPERATIONS` is never
//!   held across I/O.
//! - An offer lives until its quote expires or the wallet locks
//!   ([`clear_sessions`]). The forward quote is never persisted and never
//!   crosses to Dart: a missing offer at accept is `QuoteExpired`.
//! - A reverse funding lives from its request until its proof is submitted,
//!   the wallet locks or the account is deleted: a proof that finishes after
//!   a lock is never submitted.
//! - A call registered with [`OpHandle::begin`] can be cancelled by its id and
//!   reports what it is doing (zapp `onActivity`) until it returns.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

use super::forward::joint_db_path;
use super::joint;
use super::models::{Amount, ReverseRecord, SwapQuote};
use super::store::SwapStore;
use super::{ErrorCode, PrivateUsdError, PrivateUsdNetwork, Result, OPERATIONS};
use crate::wallet::network::WalletNetwork;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

// ---- driver locks ----

static DRIVER_LOCKS: LazyLock<Mutex<HashMap<String, Arc<AsyncMutex<()>>>>> =
    LazyLock::new(Default::default);

/// An account's driver step, released when dropped. Without it, an accept and
/// the engine loop would overwrite each other's `t0` and ticket.
pub(crate) struct DriverGuard {
    _guard: OwnedMutexGuard<()>,
}

/// Takes `account`'s driver lock, or `Busy` while another step holds it.
pub(crate) fn lock_account(account: &str) -> Result<DriverGuard> {
    let mutex = lock(&DRIVER_LOCKS)
        .entry(account.to_owned())
        .or_default()
        .clone();
    mutex
        .try_lock_owned()
        .map(|guard| DriverGuard { _guard: guard })
        .map_err(|_| {
            PrivateUsdError::new(
                ErrorCode::Busy,
                "another step of this account's conversion is running",
            )
        })
}

/// Removes everything Private USD keeps for `account` (reference §8.4): its
/// joint accounts in `joint.db` first, then its rows in `swaps.db`, so a
/// failure leaves the rows to retry with. `Busy` while one of its driver
/// steps runs: a step that saved after the delete would bring a record back.
/// The caller warned the user and drained the engine first (§3.5 item 15).
pub(crate) fn delete_account(
    store_dir: &Path,
    network: WalletNetwork,
    account: &str,
) -> Result<()> {
    let _driver = lock_account(account)?;
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
    let _guard = OPERATIONS.lock().unwrap_or_else(|error| error.into_inner());
    store.delete_account(account)
}

// ---- forward offers ----

/// A forward quote for one swap index, not accepted yet (zapp
/// `AtomicSwapOffer`).
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
    pub deposit_fee_zat: Option<u64>,
}

impl Offer {
    /// What the deposit may cost in all: the amount and its fee.
    pub(crate) fn max_total_zat(&self) -> Option<u64> {
        self.deposit_fee_zat
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
/// direction (zapp checks once per driver; reverse also needs
/// `reverseEnabled`). Cleared with the offers.
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

/// Forgets every offer, reverse funding and maker check: the wallet locked
/// (D9). A quote made before the lock is never accepted after it, and a
/// funding proved across it is never submitted.
pub(crate) fn clear_sessions() {
    let mut offers = lock(&OFFERS);
    SESSION.fetch_add(1, Ordering::AcqRel);
    offers.clear();
    drop(offers);
    lock(&FUNDINGS).clear();
    MAKER_CHECKS.clear();
}

// ---- reverse fundings ----

/// A reverse swap's funding as Rust handed it to the Railgun page to prove
/// (reference §5.7 step 4): kept in memory only, until the proof comes back.
#[derive(Clone, Debug)]
pub(crate) struct FundingSession {
    pub network: PrivateUsdNetwork,
    /// The record when its `OpenReverse` was signed: a proof is submitted
    /// only while the record is unchanged (zapp `fund`'s check).
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

/// What a call is doing now, for the progress screen (zapp
/// `AtomicSwapActivity`, plus the reverse steps).
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

    pub(crate) fn set_activity(&self, activity: Activity) {
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

/// A call that stopped because it was cancelled: never a failure, so never a
/// problem shown to the user.
pub(crate) fn cancelled() -> PrivateUsdError {
    PrivateUsdError::new(ErrorCode::Cancelled, "cancelled")
}

// ---- seams ----

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

/// Privacy Pass tokens for a maker's accept (reference §5.9). M4 implements
/// it; until then [`NoTokens`] holds none, so a maker that asks for one turns
/// the accept away as `TokensNeeded` and the engine never retries by itself.
pub(crate) trait TokenSource {
    /// The `Authorization` an accept carries, from a token already held for
    /// this maker; `None` sends it unpaid.
    fn accept_authorization(&self) -> Option<String>;
    /// The maker answered an accept `tokenRequired` with this challenge.
    fn token_required(&self, challenge: Option<&str>);
}

/// No tokens client yet (M4 waits for N1): nothing is ever held or awaited.
pub(crate) struct NoTokens;

impl TokenSource for NoTokens {
    fn accept_authorization(&self) -> Option<String> {
        None
    }

    fn token_required(&self, _challenge: Option<&str>) {}
}

// ---- problems ----

/// A failed step is tried again after this (zapp `RETRY_DELAY`).
pub(crate) const RETRY_DELAY: Duration = Duration::from_secs(15);

/// The problem a failed step shows, after a minute of failures (reference
/// §5.8; zapp `ua/SwapLoop.kt` block → hold): the codes the progress screens
/// have copy for, and `Other` for the unexpected.
pub(crate) fn problem(code: ErrorCode) -> ErrorCode {
    use ErrorCode::*;
    match code {
        RelayerUnreachable | RelayerRefused | RelayerFee | EthereumUnreachable | RailgunClosed
        | ClaimTurn | ZcashWallet | DepositUnpayable | ZcashRejected | Mismatch
        | TokensUnreachable | RouteBlocked => code,
        ChainLagging | ChainUnreadable => EthereumUnreachable,
        // zapp holds a service serving another deployment as the relayer
        // being unreachable.
        WrongDeployment => RelayerUnreachable,
        _ => Other,
    }
}
