//! What forward and reverse swaps share: the windows that decide when a
//! share may be revealed, the payout fee rules, the maker's and the
//! relayer's checks against the pins, the records in `swaps.db`, and the
//! seams of one driver call. Each direction keeps its own state machine.

use std::path::Path;

use zecswap_core::{JointAccount, SecretShare, SpendKey, SwapContext};

use super::deployment::{
    self, Deployment, SwapContract, READY_DEPTH_BLOCKS, REVEAL_MARGIN_SECONDS,
    SIGNATURE_TTL_SECONDS,
};
use super::engine::{self, MakerChecks, OpHandle};
use super::evm_rpc::SwapStage;
use super::joint::{SwapTxStatus, WalletZcash};
use super::keys::SwapKeyContext;
use super::maker_client::MakerClient;
use super::models::{
    Amount, Direction, ForwardRecord, RecordDeployment, RelayerTerms, ReverseRecord, StoredRecord,
    SwapAcceptance, SwapQuote, SwapZcashNetwork,
};
use super::relayer_client::RelayerClient;
use super::store::SwapStore;
use super::transport::{HttpTransport, Refusal, SwapErrorCode, SwapHttpError};
use super::{fail, terms, with_operations, ErrorCode, PrivateUsdError, Result};
use crate::wallet::network::WalletNetwork;
use crate::wallet::routed_http::RoutedHttp;

/// The maker API version this build speaks.
const MAKER_API_VERSION: u32 = 1;
/// A reveal is refused on a head this much older than the device's clock:
/// a node minutes behind shows windows that have moved on.
const MAX_HEAD_LAG_SECONDS: u64 = 3 * 60;
/// The only contract kind a relayer's terms may name.
const WINDOWS_CONTRACT_KIND: &str = "windows";

// ---- the windows ----

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

/// A swap as one consistent read shows it: its stage as of the newest block,
/// that block's time and number, and the device's clock.
///
/// A window has opened once the block's time is at or past its start: a
/// block at or past it exists, so every later one is past it too, where the
/// device's clock may run ahead. How much of a window is left counts from
/// the later of the two clocks: either can only make a reveal go earlier,
/// and the margin covers a device clock behind.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct WindowView {
    /// `None`: no swap at that block.
    pub stage: Option<SwapStage>,
    pub head: u64,
    pub head_number: u64,
    pub device_now: u64,
    pub t0: u64,
    pub t1: u64,
    /// The contract's `LATE_WINDOW`.
    pub late_window: u64,
}

impl WindowView {
    fn live(&self) -> bool {
        matches!(self.stage, Some(SwapStage::Open | SwapStage::Ready))
    }

    fn end_clock(&self) -> u64 {
        self.head.max(self.device_now)
    }
}

/// What a forward swap's windows let the user's claim do now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ClaimWindow {
    /// Reveal `z`: the window leaves the margin, or the late window is over
    /// and the claim is the user's for good.
    Open,
    /// Not before `t0` on a swap not ready, nor on a ready that is not
    /// `READY_DEPTH_BLOCKS` deep.
    NotYet,
    /// The swap unwinds: from `t1` the maker refunds for its late window,
    /// and under the margin before `t1` a claim could land after it. From
    /// `t1 + LATE` the claim opens again.
    Unwinding,
    /// Railgun is not taking the payout, which would sit in the contract.
    RailgunClosed,
    /// Claimed, refunded, or no swap.
    Shut,
}

/// The user's claim of a forward swap on `view`, the swap ready at block
/// `ready_block` where known.
pub(crate) fn claim_window(
    view: &WindowView,
    ready_block: Option<u64>,
    railgun_accepts: bool,
) -> ClaimWindow {
    if !view.live() {
        return ClaimWindow::Shut;
    }
    if !railgun_accepts {
        return ClaimWindow::RailgunClosed;
    }
    if view.head >= view.t1 {
        return if view.head >= view.t1.saturating_add(view.late_window) {
            ClaimWindow::Open
        } else {
            ClaimWindow::Unwinding
        };
    }
    if view.head < view.t0 {
        let deep = view.stage == Some(SwapStage::Ready)
            && ready_block.is_some_and(|block| {
                block <= view.head_number && view.head_number - block >= READY_DEPTH_BLOCKS
            });
        if !deep {
            return ClaimWindow::NotYet;
        }
    }
    if view.end_clock().saturating_add(REVEAL_MARGIN_SECONDS) >= view.t1 {
        return ClaimWindow::Unwinding;
    }
    ClaimWindow::Open
}

/// Whether the user may sign a reverse escrow's `ready` on `view`: open, no
/// refund of ours ever posted, the maker's ZEC confirmed in full, and the
/// signature's deadline, `SIGNATURE_TTL_SECONDS` from the block's time,
/// before `t0`, from when no ready lands.
pub(crate) fn may_sign_ready(
    view: &WindowView,
    refund_posted: bool,
    deposit_confirmed: bool,
) -> bool {
    view.stage == Some(SwapStage::Open)
        && !refund_posted
        && deposit_confirmed
        && view.head.saturating_add(SIGNATURE_TTL_SECONDS) < view.t0
}

/// Whether the user may reveal `z` to refund a reverse escrow on `view`: a
/// ready one from `t1`, for good; an open one once no ready it signed can
/// land, the chain being past each one's deadline or at `t0`. A ready
/// landing first would revert the refund with `z` public.
pub(crate) fn may_refund(view: &WindowView, ready_deadlines: &[u64]) -> bool {
    match view.stage {
        Some(SwapStage::Ready) => view.head >= view.t1,
        Some(SwapStage::Open) => !ready_deadlines
            .iter()
            .any(|deadline| view.head <= *deadline && view.head < view.t0),
        _ => false,
    }
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

/// The quote names the pinned chain, windows contract, token and maker.
pub(crate) fn serves(pins: &Deployment, quote: &SwapQuote) -> bool {
    quote.chain_id == pins.chain_id
        && pins.settles_on(&quote.contract.0)
        && quote.token.0 == pins.token
        && quote.maker.0 == pins.maker
}

/// A reverse record pinned to this build's deployment: the same chain,
/// windows contract, token, Railgun proxy, maker, relayer and Zcash network.
pub(crate) fn serves_reverse(pins: &Deployment, pinned: &RecordDeployment) -> bool {
    pinned.chain_id == pins.chain_id
        && pins.settles_on(&pinned.contract.0)
        && pinned.token.0 == pins.token
        && pinned.railgun_proxy.0 == pins.railgun_proxy
        && pinned.maker.0 == pins.maker
        && pinned.relayer.0 == pins.relayer
        && pinned.zcash_network == SwapZcashNetwork::from(pins.network)
}

/// A record this build drives: one pinned to another deployment, such as
/// the lock contract's, is never followed.
pub(crate) fn serves_record(pins: &Deployment, record: &StoredRecord) -> bool {
    match record {
        StoredRecord::Forward(record) => serves(pins, &record.quote),
        StoredRecord::Reverse(record) => serves_reverse(pins, &record.deployment),
    }
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

/// Whether the windows and contract kind a service names, where it names
/// them, are the pinned contract's.
fn names_pinned_windows(
    contract: &SwapContract,
    min_window: Option<u64>,
    late_window: Option<u64>,
    contract_kind: Option<&str>,
) -> bool {
    min_window.is_none_or(|window| window == contract.min_window)
        && late_window.is_none_or(|window| window == contract.late_window)
        && contract_kind.is_none_or(|kind| kind == WINDOWS_CONTRACT_KIND)
}

/// The maker's `/v1/info` against the pins, once per session and direction,
/// windows and contract kind included where it names them. A reverse
/// conversion also needs the maker to take them (`reverseEnabled`), else
/// `Unavailable`.
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
    let contract = pins.swap_contract()?;
    let info = maker.info().await?;
    let serves = info.api_version == MAKER_API_VERSION
        && info.maker.0 == pins.maker
        && info.chain_id == pins.chain_id
        && info.contract.0 == contract.address
        && info.token.0 == pins.token
        && info.zcash_network == SwapZcashNetwork::from(network)
        && names_pinned_windows(
            contract,
            info.min_window,
            info.late_window,
            info.contract_kind.as_deref(),
        );
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
/// and windows contract, and not the maker's. Windows the terms name must be
/// the pinned ones, which the chain answers, and a contract kind they name
/// must be the windows'.
pub(crate) async fn pinned_relayer_terms<T: HttpTransport>(
    relayer: &RelayerClient<'_, T>,
    pins: &Deployment,
) -> Result<RelayerTerms> {
    let contract = pins.swap_contract()?;
    let terms = relayer.terms().await?;
    let serves = terms.chain_id == pins.chain_id
        && terms.contract.0 == contract.address
        && terms.relayer.0 == pins.relayer
        && terms.relayer.0 != pins.maker
        && names_pinned_windows(
            contract,
            terms.min_window,
            terms.late_window,
            terms.contract_kind.as_deref(),
        );
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
        contract: pins.swap_contract()?.address,
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

/// One conversion at a time per account, in either direction. A reverse
/// draft is not under way, nor is a conversion of another deployment, which
/// this build never drives.
pub(crate) fn require_none_under_way(
    store: &SwapStore,
    account: &str,
    pins: &Deployment,
) -> Result<()> {
    let under_way = store
        .unfinished(account)?
        .iter()
        .any(|record| serves_record(pins, record));
    if under_way {
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
