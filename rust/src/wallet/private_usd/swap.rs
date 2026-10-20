//! What forward and reverse swaps share: the lock and reveal rules, the
//! payout fee rules, the maker's and the relayer's checks against the pins,
//! the records in `swaps.db`, and the seams of one driver call. Each
//! direction keeps its own state machine.

use std::path::Path;

use zecswap_core::{JointAccount, SecretShare, SpendKey, SwapContext};

use super::deployment::{self, Deployment, REVEAL_MARGIN_SECONDS, SIGNATURE_TTL_SECONDS};
use super::engine::{self, MakerChecks, OpHandle};
use super::joint::{SwapTxStatus, WalletZcash};
use super::keys::SwapKeyContext;
use super::maker_client::MakerClient;
use super::models::{
    Amount, Direction, ForwardRecord, RelayerTerms, ReverseRecord, StoredRecord, SwapAcceptance,
    SwapQuote, SwapZcashNetwork,
};
use super::relayer_client::RelayerClient;
use super::store::SwapStore;
use super::transport::{HttpTransport, Refusal, SwapErrorCode, SwapHttpError};
use super::{fail, terms, with_operations, ErrorCode, PrivateUsdError, Result};
use crate::wallet::network::WalletNetwork;
use crate::wallet::routed_http::RoutedHttp;

/// The maker API version this build speaks.
const MAKER_API_VERSION: u32 = 1;
/// Lock reasoning is refused on a head this much older than the device's
/// clock: a lapsed lock would look held.
const MAX_HEAD_LAG_SECONDS: u64 = 3 * 60;

// ---- locks and reveals ----

/// `head`, the latest block's time, unless it trails this device's clock by
/// minutes.
pub(crate) fn fresh_head(head: u64, device_now: u64) -> Result<u64> {
    let lag = device_now.saturating_sub(head);
    if lag > MAX_HEAD_LAG_SECONDS {
        return fail(
            ErrorCode::ChainLagging,
            format!("the chain's head is {lag}s old"),
        );
    }
    Ok(head)
}

/// Whether a lock held until `lock_until` leaves more than the reveal margin:
/// a share revealed under it lands before the other side's turn. The margin
/// counts from the later of the fresh `head` and this device's clock, since
/// the head may trail real time by up to `MAX_HEAD_LAG_SECONDS`.
pub(crate) fn reveal_margin_holds(lock_until: u64, head: u64, device_now: u64) -> bool {
    let from = head.max(device_now);
    lock_until > from && lock_until - from > REVEAL_MARGIN_SECONDS
}

/// Whether the contract gives us a lock at `now`: none is held, nor is it
/// the other side's turn after ours lapsed (`ZecSwap.sol`'s `_locked` and
/// `_turnAfterLapse`).
pub(crate) fn may_take_lock(own: u64, other: u64, now: u64, lock_duration: u64) -> bool {
    let held = now < own || now < other;
    let their_turn = own > other && (now < own || now - own < lock_duration);
    lock_duration > 0 && !held && !their_turn
}

/// The deadline of a lock signed at `now`, or `None` while the contract would
/// not give us the lock.
pub(crate) fn lock_deadline(
    own: u64,
    other: u64,
    now: u64,
    lock_duration: u64,
) -> Result<Option<u64>> {
    if !may_take_lock(own, other, now, lock_duration) {
        return Ok(None);
    }
    if SIGNATURE_TTL_SECONDS >= lock_duration {
        return fail(
            ErrorCode::WrongDeployment,
            "the contract's locks are too short to sign for",
        );
    }
    Ok(Some(now + SIGNATURE_TTL_SECONDS))
}

/// The key that spends swap `index`'s joint account, `±(e+z)`, from the
/// maker's share `revealed` on chain.
pub(crate) fn joint_spend_key(
    keys: &SwapKeyContext,
    index: u32,
    joint: &JointAccount,
    revealed: &[u8; 32],
) -> Result<SpendKey> {
    let maker = SecretShare::from_be_bytes(revealed).map_err(|_| {
        PrivateUsdError::new(ErrorCode::Mismatch, "the revealed share is not valid")
    })?;
    let user = keys.user_keys(index)?;
    joint.spend_key(&maker, &user.share).map_err(|_| {
        PrivateUsdError::new(
            ErrorCode::Mismatch,
            "the revealed share does not open the joint account",
        )
    })
}

/// A kept swap transaction and its status, unless it provably expired: only
/// then may a new one be built, once `expire` has dropped it from `record`
/// and the record is kept.
pub(crate) async fn unexpired<R: SwapRecord, T>(
    store: &mut SwapStore,
    account: &str,
    record: &mut R,
    kept: Option<T>,
    status: impl AsyncFnOnce(&T) -> Result<SwapTxStatus>,
    expire: impl FnOnce(&mut R),
) -> Result<Option<(T, SwapTxStatus)>> {
    let Some(kept) = kept else {
        return Ok(None);
    };
    let status = status(&kept).await?;
    if status != SwapTxStatus::Expired {
        return Ok(Some((kept, status)));
    }
    expire(record);
    update(store, account, record)?;
    Ok(None)
}

// ---- payouts ----

/// What reaches Railgun of `amount`: the relayer's fee comes off first, then
/// Railgun's shield fee.
pub(crate) fn payout_after_fees(amount: Amount, relayer_fee: Amount) -> Amount {
    if relayer_fee >= amount {
        return Amount(0);
    }
    Amount(deployment::after_railgun_fee(amount.0 - relayer_fee.0))
}

/// The relayer refuses a payout `fee` would take all of, so nothing that
/// needs one starts.
pub(crate) fn require_pays_out(amount: Amount, fee: Amount) -> Result<()> {
    if fee >= amount {
        return fail(
            ErrorCode::RelayerFee,
            format!("a relayer fee of {} leaves nothing", fee.0),
        );
    }
    Ok(())
}

/// A fee a payout may be signed for: it leaves something of `amount`, and it
/// is within the cap.
pub(crate) fn require_payout_fee(amount: Amount, fee: Amount) -> Result<()> {
    require_pays_out(amount, fee)?;
    deployment::require_within_fee_cap(fee.0)
}

/// A relayer post that failed: turned down, so nothing was sent, or
/// otherwise.
pub(crate) enum PostError {
    Refused(Refusal),
    Failed(PrivateUsdError),
}

impl From<PostError> for PrivateUsdError {
    fn from(error: PostError) -> Self {
        match error {
            PostError::Refused(refusal) => SwapHttpError::Refused(refusal).into(),
            PostError::Failed(error) => error,
        }
    }
}

// ---- the maker and the relayer ----

/// The quote names the pinned chain, contract, token and maker.
pub(crate) fn serves(pins: &Deployment, quote: &SwapQuote) -> bool {
    quote.chain_id == pins.chain_id
        && quote.contract.0 == pins.contract
        && quote.token.0 == pins.token
        && quote.maker.0 == pins.maker
}

/// A quote's error: the maker turning the amount down is `AmountRefused`.
pub(crate) fn quote_error(error: SwapHttpError) -> PrivateUsdError {
    match error.code() {
        Some(SwapErrorCode::Rejected | SwapErrorCode::InvalidRequest) => {
            PrivateUsdError::new(ErrorCode::AmountRefused, error.to_string())
        }
        _ => error.into(),
    }
}

/// The maker's `/v1/info` against the pins, once per session and direction.
/// A reverse conversion also needs the maker to take them
/// (`reverseEnabled`), else `Unavailable`.
pub(crate) async fn check_maker<T: HttpTransport>(
    maker: &MakerClient<'_, T>,
    pins: &Deployment,
    makers: &MakerChecks,
    reverse: bool,
) -> Result<()> {
    let network = pins.network;
    if makers.checked(network, reverse) {
        return Ok(());
    }
    let info = maker.info().await?;
    let serves = info.api_version == MAKER_API_VERSION
        && info.maker.0 == pins.maker
        && info.chain_id == pins.chain_id
        && info.contract.0 == pins.contract
        && info.token.0 == pins.token
        && info.zcash_network == SwapZcashNetwork::from(network);
    if !serves {
        return fail(
            ErrorCode::WrongDeployment,
            "the maker serves another deployment",
        );
    }
    if reverse && !info.reverse_enabled {
        return fail(
            ErrorCode::Unavailable,
            "the maker takes no conversions to ZEC now",
        );
    }
    // A return key shown to only some devices would mark the tokens they
    // get back.
    if info
        .token_return_key
        .as_deref()
        .is_some_and(|key| key != pins.maker_token_return_key)
    {
        return fail(
            ErrorCode::TokensRefused,
            "the maker returns tokens under another key",
        );
    }
    makers.mark(network, reverse);
    Ok(())
}

/// `GET /v1/terms`, once they are the pinned relayer's on the pinned chain
/// and contract, and not the maker's.
pub(crate) async fn pinned_relayer_terms<T: HttpTransport>(
    relayer: &RelayerClient<'_, T>,
    pins: &Deployment,
) -> Result<RelayerTerms> {
    let terms = relayer.terms().await?;
    let serves = terms.chain_id == pins.chain_id
        && terms.contract.0 == pins.contract
        && terms.relayer.0 == pins.relayer
        && terms.relayer.0 != pins.maker;
    if !serves {
        return fail(ErrorCode::WrongDeployment, "another deployment's relayer");
    }
    Ok(terms)
}

/// Accepts `quote` for swap `index`: the maker's proof of its share checked,
/// our share proved. `Mismatch` when the maker's proof does not verify.
pub(crate) fn acceptance(
    keys: &SwapKeyContext,
    pins: &Deployment,
    index: u32,
    quote: &SwapQuote,
) -> Result<SwapAcceptance> {
    let (Some(quote_id), Some(proof)) = (quote.quote_id_bytes(), quote.maker_proof_bytes()) else {
        return fail(ErrorCode::Mismatch, "the quote's id or proof is malformed");
    };
    let context = SwapContext {
        chain_id: quote.chain_id,
        contract: pins.contract,
        quote_id,
    };
    keys.acceptance(index, context, &terms::quote_maker_share(quote)?, &proof)
}

// ---- records ----

/// A swap's record as `swaps.db` keeps it, in one direction.
pub(crate) trait SwapRecord: Sized {
    const DIRECTION: Direction;

    fn index(&self) -> u32;
    fn stored(&self) -> StoredRecord;
    fn from_stored(stored: StoredRecord) -> Option<Self>;
}

impl SwapRecord for ForwardRecord {
    const DIRECTION: Direction = Direction::Forward;

    fn index(&self) -> u32 {
        self.index
    }

    fn stored(&self) -> StoredRecord {
        StoredRecord::Forward(Box::new(self.clone()))
    }

    fn from_stored(stored: StoredRecord) -> Option<Self> {
        match stored {
            StoredRecord::Forward(record) => Some(*record),
            StoredRecord::Reverse(_) => None,
        }
    }
}

impl SwapRecord for ReverseRecord {
    const DIRECTION: Direction = Direction::Reverse;

    fn index(&self) -> u32 {
        self.index
    }

    fn stored(&self) -> StoredRecord {
        StoredRecord::Reverse(Box::new(self.clone()))
    }

    fn from_stored(stored: StoredRecord) -> Option<Self> {
        match stored {
            StoredRecord::Reverse(record) => Some(*record),
            StoredRecord::Forward(_) => None,
        }
    }
}

fn filed<R: SwapRecord>(stored: StoredRecord) -> Result<R> {
    R::from_stored(stored).ok_or_else(|| {
        PrivateUsdError::new(
            ErrorCode::StoreUnreadable,
            "a record is filed under the other direction",
        )
    })
}

pub(crate) fn find<R: SwapRecord>(
    store: &SwapStore,
    account: &str,
    index: u32,
) -> Result<Option<R>> {
    store
        .find(account, R::DIRECTION, index)?
        .map(filed)
        .transpose()
}

pub(crate) fn load<R: SwapRecord>(store: &SwapStore, account: &str, index: u32) -> Result<R> {
    find(store, account, index)?
        .ok_or_else(|| PrivateUsdError::new(ErrorCode::Other, "no such conversion"))
}

/// The account's records: the active one first, then the rest of the
/// history, newest first.
pub(crate) fn records<R: SwapRecord>(store: &SwapStore, account: &str) -> Result<Vec<R>> {
    let active: Option<R> = store
        .active(account, R::DIRECTION)?
        .map(filed)
        .transpose()?;
    let active_index = active.as_ref().map(R::index);
    let mut records: Vec<R> = active.into_iter().collect();
    for stored in store.history(account, R::DIRECTION)? {
        if let Some(record) = R::from_stored(stored) {
            if Some(record.index()) != active_index {
                records.push(record);
            }
        }
    }
    Ok(records)
}

/// Keeps `record` as its direction's active record, replacing a reverse
/// draft.
pub(crate) fn save<R: SwapRecord>(store: &mut SwapStore, account: &str, record: &R) -> Result<()> {
    let stored = record.stored();
    with_operations(|| store.save(account, &stored))?;
    Ok(())
}

/// Changes the kept `record` in place, leaving which one is active alone.
pub(crate) fn update<R: SwapRecord>(
    store: &mut SwapStore,
    account: &str,
    record: &R,
) -> Result<()> {
    let stored = record.stored();
    with_operations(|| store.update(account, &stored))?;
    Ok(())
}

/// One conversion at a time per account, in either direction; a reverse
/// draft is not under way.
pub(crate) fn require_none_under_way(store: &SwapStore, account: &str) -> Result<()> {
    if store.unfinished_count(account)? > 0 {
        return fail(ErrorCode::Busy, "a conversion is already under way");
    }
    Ok(())
}

// ---- one driver call ----

/// A step's result as the engine loop takes it. A cancelled call stops the
/// loop (`Err`); any other failure is a problem to show once steps have
/// failed for a minute (`Ok(Err)`).
pub(crate) fn loop_outcome<T>(
    op: Option<&OpHandle>,
    direction: Direction,
    index: u32,
    step: Result<T>,
) -> Result<std::result::Result<T, ErrorCode>> {
    engine::check_cancelled(op)?;
    match step {
        Ok(value) => Ok(Ok(value)),
        Err(error) if error.code == ErrorCode::Cancelled => Err(error),
        Err(error) => {
            log::warn!(
                "private usd: {} swap {index}: a step failed ({:?})",
                direction.as_str(),
                error.code
            );
            Ok(Err(engine::problem(error.code)))
        }
    }
}

/// One call's transport: with `op`, its cancel flag stops the requests.
pub(crate) fn transport(op: Option<&OpHandle>) -> RoutedHttp {
    match op {
        Some(op) => RoutedHttp::cancellable(op.cancel_flag()),
        None => RoutedHttp::new(),
    }
}

/// One FRB call's account, paths and endpoints, which it drives its swaps
/// over. The caller holds the account's driver lock.
pub(crate) struct SwapCall<'s> {
    pub main_db: &'s str,
    pub network: WalletNetwork,
    pub account: &'s str,
    pub store_dir: &'s Path,
    pub lightwalletd_url: &'s str,
    /// The keyed Ethereum RPC URL, or empty for publicnode. Never stored.
    pub eth_rpc_url: &'s str,
    pub keys: &'s SwapKeyContext,
}

impl<'s> SwapCall<'s> {
    pub(crate) fn pins(&self) -> &'static Deployment {
        deployment::deployment(self.keys.network())
    }

    /// The wallet's Zcash side; with `op`, its cancel flag stops joint scans.
    pub(crate) fn zcash(&self, op: Option<&OpHandle>) -> WalletZcash<'s> {
        WalletZcash {
            main_db: self.main_db,
            lightwalletd_url: self.lightwalletd_url,
            network: self.network,
            account_uuid: self.account,
            store_dir: self.store_dir,
            keys: self.keys,
            cancel: op.map(OpHandle::cancel_flag).unwrap_or_default(),
        }
    }
}
