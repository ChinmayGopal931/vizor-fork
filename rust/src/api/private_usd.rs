//! Private USD (shielded ZEC ↔ Railgun USDC): the thin FRB surface.
//! Logic lives in `crate::wallet::private_usd`; these wrappers parse
//! arguments, guard panics and map errors to stable codes. Dart never branches
//! on an error's message.
//!
//! Key-using calls take the account's stored secret as `mnemonic_bytes`,
//! zeroized on return, and derive keys only after checking the seed against
//! the account. Never log their arguments or results.

use std::panic;
use std::path::Path;

use flutter_rust_bridge::frb;
use zeroize::Zeroizing;

use crate::wallet::keys;
use crate::wallet::network::WalletNetwork;
use crate::wallet::private_usd::{
    deployment::{self, hex_address},
    engine::{self, Activity, OpHandle},
    forward::{self, AcceptOutcome, AdvanceReport, ForwardWait, Quoted},
    joint::{self as joint_ops, SwapTxStatus},
    keys::{account_derivation, SwapKeyContext},
    models::{
        Amount, Direction, ForwardOutcome, ForwardRecord, NothingSentCause, RefundCause,
        ReversePhase, ReverseRecord, ZcashTxId,
    },
    railgun_keys,
    reverse::{self, FundingPrice, FundingRequest, ProvedFunding, ReverseAccept, ReverseReport},
    store::SwapStore,
    ErrorCode, PrivateUsdError, PrivateUsdNetwork,
};

/// Why a Private USD call failed. Copy follows the code, never the message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiPrivateUsdErrorCode {
    RelayerUnreachable,
    RelayerRefused,
    RelayerFee,
    EthereumUnreachable,
    RailgunClosed,
    ClaimTurn,
    ZcashWallet,
    DepositUnpayable,
    ZcashRejected,
    Mismatch,
    TokensUnreachable,
    TokensRefused,
    TokensDeviceRefused,
    NoTokensToday,
    TokensNeeded,
    Keystore,
    ChainLagging,
    QuoteExpired,
    MakerUnavailable,
    MakerBusy,
    AmountRefused,
    FundingCostChanged,
    DepositUnconfirmed,
    TooLate,
    Busy,
    StoreUnreadable,
    Unavailable,
    RouteBlocked,
    Other,
    /// The call was cancelled (`private_usd_cancel`): never a failure.
    Cancelled,
}

/// A Private USD failure. Its Dart `toString()` is the message.
#[frb(dart_code = "
  @override
  String toString() => message;
")]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiPrivateUsdError {
    pub code: ApiPrivateUsdErrorCode,
    pub message: String,
}

impl From<PrivateUsdError> for ApiPrivateUsdError {
    fn from(error: PrivateUsdError) -> Self {
        Self {
            code: api_code(error.code),
            message: error.message,
        }
    }
}

/// The FRB code of an engine code; the internal reasons fold into the
/// nearest one.
fn api_code(code: ErrorCode) -> ApiPrivateUsdErrorCode {
    use ApiPrivateUsdErrorCode as Api;
    match code {
        ErrorCode::RelayerUnreachable => Api::RelayerUnreachable,
        ErrorCode::RelayerRefused => Api::RelayerRefused,
        ErrorCode::RelayerFee => Api::RelayerFee,
        ErrorCode::EthereumUnreachable => Api::EthereumUnreachable,
        ErrorCode::RailgunClosed => Api::RailgunClosed,
        ErrorCode::ClaimTurn => Api::ClaimTurn,
        ErrorCode::ZcashWallet => Api::ZcashWallet,
        ErrorCode::DepositUnpayable => Api::DepositUnpayable,
        ErrorCode::ZcashRejected => Api::ZcashRejected,
        ErrorCode::Mismatch => Api::Mismatch,
        ErrorCode::TokensUnreachable => Api::TokensUnreachable,
        ErrorCode::TokensRefused => Api::TokensRefused,
        ErrorCode::TokensDeviceRefused => Api::TokensDeviceRefused,
        ErrorCode::NoTokensToday => Api::NoTokensToday,
        ErrorCode::TokensNeeded => Api::TokensNeeded,
        ErrorCode::Keystore => Api::Keystore,
        ErrorCode::ChainLagging => Api::ChainLagging,
        ErrorCode::QuoteExpired => Api::QuoteExpired,
        ErrorCode::MakerUnavailable => Api::MakerUnavailable,
        ErrorCode::MakerBusy => Api::MakerBusy,
        ErrorCode::AmountRefused => Api::AmountRefused,
        ErrorCode::FundingCostChanged => Api::FundingCostChanged,
        ErrorCode::DepositUnconfirmed => Api::DepositUnconfirmed,
        ErrorCode::TooLate => Api::TooLate,
        ErrorCode::Busy => Api::Busy,
        ErrorCode::StoreUnreadable => Api::StoreUnreadable,
        ErrorCode::Unavailable => Api::Unavailable,
        ErrorCode::RouteBlocked => Api::RouteBlocked,
        ErrorCode::Other => Api::Other,
        ErrorCode::Cancelled => Api::Cancelled,
        // zapp holds a wrong deployment as the relayer being unreachable.
        ErrorCode::WrongDeployment => Api::RelayerUnreachable,
        ErrorCode::ChainUnreadable => Api::EthereumUnreachable,
        ErrorCode::IndicesInUse => Api::Other,
        ErrorCode::AmountUnquotable => Api::AmountRefused,
    }
}

impl From<String> for ApiPrivateUsdError {
    fn from(message: String) -> Self {
        Self {
            code: ApiPrivateUsdErrorCode::Other,
            message,
        }
    }
}

/// A network's pinned deployment: everything Dart and Kotlin need, so they
/// never duplicate config.
pub struct ApiDeployment {
    /// `"mainnet"` or `"testnet"`.
    pub network: String,
    /// The Railgun page's `start.network`: `"mainnet"` or `"sepolia"`.
    pub railgun_network: String,
    pub chain_id: i64,
    /// `0x`, lowercase.
    pub token: String,
    pub token_decimals: u32,
    pub keyless_rpc_url: String,
    pub poi_node_url: String,
    pub railgun_proxy: String,
    pub relay_adapt: String,
    pub relayer_railgun_address: String,
    /// The hosts the Railgun page may reach (both networks); a keyed RPC URL
    /// must use one of them.
    pub allowed_hosts: Vec<String>,
    pub explorer_tx_prefix: String,
    pub railscan_tx_prefix: String,
    pub zcash_confirmations: u32,
    pub escrow_confirmations: u32,
    pub screening_seconds: u32,
    /// The relayer fee cap in token base units, `"2000000"`.
    pub max_relayer_fee: String,
    /// The tokens the private USD balance counts as dollars, the swap token
    /// first. Each has `token_decimals`.
    pub usd_tokens: Vec<ApiUsdToken>,
}

/// A token the private USD balance counts as dollars.
pub struct ApiUsdToken {
    /// `0x`, lowercase.
    pub address: String,
    /// `USDC`, or `tUSD` for the testnet maker's token.
    pub symbol: String,
}

/// The deployment for the wallet network `"main"` or `"test"`; `None` on
/// regtest or an unknown network, where Private USD is hidden.
#[frb(sync)]
pub fn private_usd_deployment(network: String) -> Option<ApiDeployment> {
    let network = PrivateUsdNetwork::from_wallet(WalletNetwork::from_str(&network)?)?;
    let pins = deployment::deployment(network);
    Some(ApiDeployment {
        network: network.record_name().into(),
        railgun_network: network.railgun_name().into(),
        chain_id: pins.chain_id as i64,
        token: hex_address(&pins.token),
        token_decimals: deployment::TOKEN_DECIMALS,
        keyless_rpc_url: pins.keyless_rpc_url.into(),
        poi_node_url: pins.poi_node_url.into(),
        railgun_proxy: hex_address(&pins.railgun_proxy),
        relay_adapt: hex_address(&pins.relay_adapt),
        relayer_railgun_address: pins.relayer_railgun_address.into(),
        allowed_hosts: deployment::RAILGUN_PAGE_HOSTS
            .iter()
            .map(|host| (*host).to_owned())
            .collect(),
        explorer_tx_prefix: pins.explorer_tx_prefix.into(),
        railscan_tx_prefix: pins.railscan_tx_prefix.into(),
        zcash_confirmations: pins.zcash_confirmations,
        escrow_confirmations: pins.escrow_confirmations,
        screening_seconds: pins.screening_seconds,
        max_relayer_fee: deployment::MAX_RELAYER_FEE.to_string(),
        usd_tokens: pins
            .usd_tokens
            .iter()
            .map(|token| ApiUsdToken {
                address: hex_address(&token.address),
                symbol: token.symbol.to_owned(),
            })
            .collect(),
    })
}

/// Whether `address` is a Railgun `0zk` address (bech32m, hrp `0zk`, 73
/// bytes, version 1). Lowercase it first if it came in capitals.
#[frb(sync)]
pub fn private_usd_is_valid_railgun_address(address: String) -> bool {
    railgun_keys::is_valid_railgun_address(&address)
}

/// Whether Private USD can run for the account: a software account with
/// ZIP-32 derivation metadata on a network with a deployment. No secret
/// needed.
pub fn private_usd_account_eligible(
    db_path: String,
    network: String,
    account_uuid: String,
) -> Result<bool, ApiPrivateUsdError> {
    catch(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        if PrivateUsdNetwork::from_wallet(network).is_none() {
            return Ok(false);
        }
        Ok(account_derivation(&db_path, network, &account_uuid)?.is_some())
    })
}

/// The account's Railgun mnemonic, for the Railgun page's `openWallet`.
/// Checks the seed against the account first: `Mismatch` for another seed,
/// `Unavailable` without derivation. The words cross to Dart as a `String`,
/// which cannot be zeroized: drop it after `openWallet`.
pub fn private_usd_railgun_mnemonic(
    db_path: String,
    network: String,
    account_uuid: String,
    mnemonic_bytes: Vec<u8>,
) -> Result<String, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let context = open_context(&db_path, &network, &account_uuid, &secret)?;
        Ok(context.railgun_mnemonic()?.to_string())
    }))
}

/// The account's `0zk` address, to check the Railgun page's against.
pub fn private_usd_railgun_address(
    db_path: String,
    network: String,
    account_uuid: String,
    mnemonic_bytes: Vec<u8>,
) -> Result<String, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let context = open_context(&db_path, &network, &account_uuid, &secret)?;
        Ok(context.railgun_address()?)
    }))
}

// ---- conversions (M5) ----

/// What a call is doing now, for the progress screen (zapp
/// `AtomicSwapActivity`, and the reverse steps).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiActivity {
    Depositing,
    Claiming,
    PayingOut,
    /// A sweep home: a forward refund's, or a reverse conversion's ZEC.
    Sweeping,
    /// Sending a kept reverse funding again.
    Funding,
    /// Sending the kept `ready` again.
    Readying,
    /// Locking, revealing or paying out a reverse refund.
    Refunding,
}

/// Cancels the call registered as `op_id` (an advance): it stops at its next
/// safe point with `Cancelled`, and never between saving a deposit as
/// started and keeping its transaction. A cancel that reaches Rust before its
/// call registered still stops it.
#[frb(sync)]
pub fn private_usd_cancel(op_id: u32) {
    engine::cancel_op(op_id);
}

/// What call `op_id` is doing now, while it runs (zapp `onActivity`); poll it
/// about every 500 ms during an advance.
#[frb(sync)]
pub fn private_usd_activity(op_id: u32) -> Option<ApiActivity> {
    engine::op_activity(op_id).map(|activity| match activity {
        Activity::Depositing => ApiActivity::Depositing,
        Activity::Claiming => ApiActivity::Claiming,
        Activity::PayingOut => ApiActivity::PayingOut,
        Activity::Sweeping => ApiActivity::Sweeping,
        Activity::Funding => ApiActivity::Funding,
        Activity::Readying => ApiActivity::Readying,
        Activity::Refunding => ApiActivity::Refunding,
    })
}

/// Forgets every in-memory session: call it on lock. A forward quote made
/// before the lock is never accepted after it, a reverse funding proved
/// across the lock is never submitted, and each maker's `/v1/info` is
/// checked again. (M4 adds its token issuance sessions here.)
#[frb(sync)]
pub fn private_usd_clear_sessions() {
    engine::clear_sessions();
}

/// The account's conversions under way, in either direction: a forward one
/// not ended, a reverse one past its quote. The account deletion and reset
/// warnings show it. 0 when the wallet never made one.
pub fn private_usd_unfinished_count(
    store_dir: String,
    account_uuid: String,
) -> Result<u32, ApiPrivateUsdError> {
    catch(|| {
        Ok(match SwapStore::open_existing(Path::new(&store_dir))? {
            Some(store) => store.unfinished_count(&account_uuid)?,
            None => 0,
        })
    })
}

/// Every account with a conversion under way: the engine loop advances each
/// of them while the app is open and unlocked (D14).
pub fn private_usd_accounts_with_unfinished(
    store_dir: String,
) -> Result<Vec<String>, ApiPrivateUsdError> {
    catch(|| {
        Ok(match SwapStore::open_existing(Path::new(&store_dir))? {
            Some(store) => store.accounts_with_unfinished()?,
            None => Vec::new(),
        })
    })
}

/// Removes the account's conversions from `swaps.db` and its joint accounts
/// from `joint.db`, after the user confirmed and the engine drained. `Busy`
/// while one of its steps runs: drain, then call again.
pub fn private_usd_delete_account(
    store_dir: String,
    network: String,
    account_uuid: String,
) -> Result<(), ApiPrivateUsdError> {
    catch(|| {
        let network = keys::parse_network(&network)?;
        Ok(engine::delete_account(
            Path::new(&store_dir),
            network,
            &account_uuid,
        )?)
    })
}

/// A forward quote, held in Rust until accepted or expired.
pub struct ApiForwardQuote {
    /// The swap index the quote spent.
    pub index: u32,
    /// Unix seconds. Stop offering the quote 20 s before.
    pub expires_at: i64,
    /// Token base units, decimal.
    pub amount: String,
    pub network_cost: Option<String>,
    pub relayer_fee: String,
    /// What reaches the private balance after the relayer's and Railgun's
    /// fees.
    pub receives: String,
    pub deposit_zat: u64,
    /// The deposit's network fee from this wallet now; `None`: one
    /// transaction cannot pay it, so the quote is unpayable.
    pub deposit_fee_zat: Option<u64>,
    /// `deposit_zat + deposit_fee_zat`: what the user approves, and what
    /// accept takes.
    pub max_total_zat: Option<u64>,
    pub fee_expires_at: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiAcceptKind {
    /// The maker opened the swap, or is opening it: show its progress.
    Accepted,
    /// The maker wants a Privacy Pass token and none is held (no tokens
    /// client before M4). Nothing opened; abandon the conversion.
    TokensNeeded,
    /// Over before anything was sent; `cause` says why.
    NothingSent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiNothingSentCause {
    QuoteExpired,
    MakerRefused,
    MakerUnavailable,
    NeverOpened,
    Mismatch,
    DepositWindowMissed,
    MakerCancelled,
}

pub struct ApiAcceptResult {
    pub kind: ApiAcceptKind,
    pub cause: Option<ApiNothingSentCause>,
    pub index: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiForwardWait {
    /// The maker has not opened the swap on chain yet.
    Opening,
    /// The deposit is out; waiting for the maker to mark the swap ready, or
    /// for `t0`.
    Confirming,
    /// The maker called the swap off while the deposit was unmined.
    DepositUnsettled,
    /// The refunded deposit is on its way home.
    Refunding,
    /// The Zcash wallet is syncing: never a problem.
    ZcashSyncing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiForwardOutcome {
    Paid,
    Refunded,
    NothingSent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiRefundCause {
    MakerCancelled,
    NotClaimedInTime,
}

/// Where a forward record stands by what it keeps (the store's phase).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiForwardPhase {
    Opening,
    Depositing,
    Confirming,
    Claiming,
    Refunding,
    Paid,
    Refunded,
    NothingSent,
}

/// A flat view of a forward record; the record itself stays in Rust.
pub struct ApiForwardRecord {
    pub index: u32,
    /// `0x`, 32 bytes.
    pub swap_id: String,
    pub phase: ApiForwardPhase,
    pub accepted_at: i64,
    pub quote_expires_at: i64,
    pub deposit_zat: u64,
    pub max_total_zat: Option<u64>,
    pub amount: String,
    pub receives: String,
    pub relayer_fee: String,
    pub t0: Option<i64>,
    pub t1: Option<i64>,
    /// Internal byte order hex, as wallet history rows carry it; show it with
    /// `zcashDisplayTxidHex`.
    pub deposit_txid: Option<String>,
    /// While under way with a deposit kept: its depth in the main wallet
    /// (0 until mined). `None` otherwise.
    pub deposit_confirmations: Option<u32>,
    /// Internal byte order hex.
    pub sweep_txid: Option<String>,
    /// The Ethereum transaction that shielded the payout, `0x` hex.
    pub payout_tx: Option<String>,
    pub outcome: Option<ApiForwardOutcome>,
    pub refund_cause: Option<ApiRefundCause>,
    pub nothing_sent_cause: Option<ApiNothingSentCause>,
    pub ended_at: Option<i64>,
}

pub struct ApiForwardAdvance {
    pub record: ApiForwardRecord,
    pub wait: Option<ApiForwardWait>,
    /// How long to nap before the next advance; 0 once the record ended.
    pub next_poll_ms: u32,
    /// The step failed: the problem to show once steps have failed for a
    /// minute in a row (reference §5.8).
    pub problem: Option<ApiPrivateUsdErrorCode>,
}

/// Quotes `units` (token base units) for a fresh swap index, which counts as
/// spent from here on. The offer stays in Rust until it expires or the
/// wallet locks. `Busy` while a conversion is under way.
pub fn private_usd_forward_quote(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    lightwalletd_url: String,
    eth_rpc_url: String,
    units: u32,
) -> Result<ApiForwardQuote, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let call = forward_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            &lightwalletd_url,
            &eth_rpc_url,
            &keys,
        );
        let quoted = block_on(call.run(None, async |forward, store| {
            forward.quote(store, units).await
        }))?;
        Ok(api_quote(&quoted))
    }))
}

/// Accepts the quote of swap `index`: saves the record, then posts the
/// accept. A missing offer is `QuoteExpired`. Called again for the same
/// index, it posts the saved quote once more (never a new index). An error
/// after the save means "maybe opened": read the records and show the
/// conversion's progress if it is under way.
pub fn private_usd_forward_accept(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    lightwalletd_url: String,
    eth_rpc_url: String,
    index: u32,
    max_total_zat: u64,
) -> Result<ApiAcceptResult, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let call = forward_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            &lightwalletd_url,
            &eth_rpc_url,
            &keys,
        );
        let outcome = block_on(call.run(None, async |forward, store| {
            forward.accept(store, index, max_total_zat).await
        }))?;
        let (kind, cause) = match outcome {
            AcceptOutcome::Accepted => (ApiAcceptKind::Accepted, None),
            AcceptOutcome::TokensNeeded => (ApiAcceptKind::TokensNeeded, None),
            AcceptOutcome::NothingSent(cause) => {
                (ApiAcceptKind::NothingSent, Some(api_cause(cause)))
            }
        };
        Ok(ApiAcceptResult { kind, cause, index })
    }))
}

/// One look at the chain for swap `index`, then at most one key-using step
/// (deposit, claim, payout or sweep). Reloads the record from `swaps.db`.
/// Holds the account's driver lock throughout (`Busy` if taken), and stops
/// with `Cancelled` once `private_usd_cancel(op_id)` is called. A failed step
/// returns the record with `problem` set; nap `next_poll_ms`, then advance
/// again.
pub fn private_usd_forward_advance(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    lightwalletd_url: String,
    eth_rpc_url: String,
    op_id: u32,
    index: u32,
) -> Result<ApiForwardAdvance, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let op = OpHandle::begin(op_id)?;
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        if op.cancelled() {
            return Err(engine::cancelled().into());
        }
        let call = forward_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            &lightwalletd_url,
            &eth_rpc_url,
            &keys,
        );
        let report = block_on(call.run(Some(&op), async |forward, store| {
            forward.advance_report(store, index).await
        }))?;
        Ok(api_advance(&report, &db_path, network))
    }))
}

/// Drops swap `index` before it reached the chain (§5.6 step 12): an
/// unanswered accept ends `MakerUnavailable` (a turn-away at the token gate
/// included), an answered one `NeverOpened`. `TooLate` once a deposit
/// started or the chain shows the swap. No key is needed.
pub fn private_usd_forward_abandon(
    network: String,
    account_uuid: String,
    store_dir: String,
    eth_rpc_url: String,
    index: u32,
) -> Result<ApiForwardRecord, ApiPrivateUsdError> {
    catch(|| {
        let network = keys::parse_network(&network)?;
        let Some(network) = PrivateUsdNetwork::from_wallet(network) else {
            return Err(PrivateUsdError::new(
                ErrorCode::Unavailable,
                "no Private USD deployment on this network",
            )
            .into());
        };
        let _driver = engine::lock_account(&account_uuid)?;
        let record = block_on(forward::abandon_with(
            Path::new(&store_dir),
            network,
            &eth_rpc_url,
            &account_uuid,
            index,
        ))?;
        Ok(api_record(&record, None))
    })
}

/// The account's forward conversions: the active one first, then the rest,
/// newest first.
pub fn private_usd_forward_records(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
) -> Result<Vec<ApiForwardRecord>, ApiPrivateUsdError> {
    catch(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        let Some(store) = SwapStore::open_existing(Path::new(&store_dir))? else {
            return Ok(Vec::new());
        };
        Ok(forward::records(&store, &account_uuid)?
            .iter()
            .map(|record| api_record(record, deposit_confirmations(&db_path, network, record)))
            .collect())
    })
}

// ---- reverse conversions (M6) ----

/// Where a reverse conversion stands (zapp `ReversePhase`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiReversePhase {
    /// A reviewed draft: nothing accepted or paid, not under way.
    Quoted,
    Accepting,
    /// The user's first approval: "Pay {debit}".
    AwaitingFunding,
    SendingUsdc,
    ConfirmingEscrow,
    ReceivingZec,
    /// The user's second approval: "Authorize settlement".
    AwaitingReady,
    Settling,
    Receiving,
    Complete,
    RefundWait,
    Refunding,
    RefundPayout,
    Refunded,
    Cancelled,
}

/// What funding takes from the private balance, in token base units: the
/// escrow, Railgun's unshield fee and the relayer's fee for the gas.
pub struct ApiReverseCost {
    pub debit: String,
    pub railgun_fee: String,
    pub broadcaster_fee: String,
    /// Unix seconds until which the relayer takes `broadcaster_fee`.
    pub fee_expires_at: Option<i64>,
}

/// A flat view of a reverse record; the record itself stays in Rust.
pub struct ApiReverseRecord {
    pub index: u32,
    /// `0x`, 32 bytes: the escrow's id.
    pub swap_id: String,
    pub phase: ApiReversePhase,
    /// The escrow amount, token base units.
    pub amount: String,
    /// The maker's own network cost the quote charges, if it names one.
    pub network_cost: Option<String>,
    /// What the maker deposits into the joint account.
    pub deposit_zat: u64,
    pub quote_expires_at: i64,
    pub funding_deadline: i64,
    /// "Authorize settlement" is offered until `ready_deadline − 120`.
    pub ready_deadline: i64,
    /// A refund after `ready` can only proceed from here.
    pub refund_after: i64,
    /// The reviewed cost; `None` until priced (or after the relayer's fee
    /// rose): price it before "Pay".
    pub cost: Option<ApiReverseCost>,
    /// A funding is kept (posted, or to be posted again).
    pub funded: bool,
    /// The funding's Ethereum transaction, `0x` hex, once the relayer named
    /// one.
    pub funding_tx: Option<String>,
    pub cancel_requested: bool,
    /// The maker claimed: the ZEC is on its way home; no refund follows.
    pub settled: bool,
    /// Whether "Cancel conversion" / "Request private refund" shows.
    pub cancellable: bool,
    /// Waiting on the user's funding payment or settlement approval.
    pub awaiting_user: bool,
    /// The sweep home's estimate the user reviewed with `ready`: what
    /// arrives after its fee, and the fee, the most the sweep pays.
    pub receive_estimate_zat: Option<u64>,
    pub receive_fee_zat: Option<u64>,
    /// The sweep home, internal byte order hex, as wallet history rows carry
    /// it; show it with `zcashDisplayTxidHex`.
    pub receive_txid: Option<String>,
    pub received_zat: Option<u64>,
    pub receive_confirmations: u32,
    /// When the user went ahead; `None` for a draft.
    pub accepted_at: Option<i64>,
    /// When the record last changed (device clock).
    pub updated_at: i64,
}

/// What the Railgun page's `reverseCost` takes: `{amount, railgun:
/// railgun_proxy, fee}`. Its `{debit, railgunFee}` answer goes to
/// `private_usd_reverse_set_cost`.
pub struct ApiReverseCostRequest {
    pub index: u32,
    pub amount: String,
    pub railgun_proxy: String,
    /// The relayer's funding fee now (at most 2 USDC).
    pub fee: String,
    pub fee_expires_at: Option<i64>,
}

/// A reverse quote kept as a `QUOTED` draft, and what to price it at.
pub struct ApiReverseQuote {
    pub record: ApiReverseRecord,
    pub cost_request: ApiReverseCostRequest,
}

/// The page's `prepareReverse` params, ready to JSON-encode: `{amount,
/// railgun: railgun_proxy, token, calls: [{to, data}] × 3, relayAdapt, fee}`.
pub struct ApiFundingRequest {
    pub amount: String,
    pub railgun_proxy: String,
    pub token: String,
    /// The three calls, in order: approve, openReverse, transfer.
    pub calls_to: Vec<String>,
    pub calls_data: Vec<String>,
    pub relay_adapt: String,
    pub fee: String,
    /// A funding is kept already: skip the page and advance instead.
    pub already_funded: bool,
}

pub struct ApiReverseAdvance {
    pub record: ApiReverseRecord,
    /// How long to nap before the next advance; 0 once it ended.
    pub next_poll_ms: u32,
    /// The step failed: the problem to show once steps have failed for a
    /// minute in a row (reference §5.8).
    pub problem: Option<ApiPrivateUsdErrorCode>,
    /// The user's approval is needed: "Pay {debit}" in `AwaitingFunding`,
    /// "Authorize settlement" in `AwaitingReady`.
    pub needs_you: bool,
}

/// Quotes `units` of private dollars (token base units, whole cents) for a
/// fresh swap index, which counts as spent from here on, and keeps the
/// verified quote as a `QUOTED` draft, replacing any earlier draft. Price it
/// next: the page's `reverseCost` with `cost_request`, then
/// `private_usd_reverse_set_cost`. `Busy` while a conversion is under way.
pub fn private_usd_reverse_quote(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    lightwalletd_url: String,
    eth_rpc_url: String,
    units: u32,
) -> Result<ApiReverseQuote, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let call = reverse_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            &lightwalletd_url,
            &eth_rpc_url,
            &keys,
        );
        Ok(block_on(call.run(None, async |reverse, store| {
            let quoted = reverse.quote(store, units).await?;
            Ok(ApiReverseQuote {
                record: api_reverse_record(store, &account_uuid, &quoted.record),
                cost_request: api_cost_request(&quoted.price),
            })
        }))?)
    }))
}

/// What to price swap `index`'s funding at now (for a draft whose pricing
/// was cut short, or after `FundingCostChanged`). No key is needed.
pub fn private_usd_reverse_cost_request(
    network: String,
    account_uuid: String,
    store_dir: String,
    index: u32,
) -> Result<ApiReverseCostRequest, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let price = block_on(reverse::run_view(
            Path::new(&store_dir),
            network,
            "",
            &account_uuid,
            async |view, store| view.price(store, index).await,
        ))?;
        Ok(api_cost_request(&no_such_conversion(price)?))
    })
}

/// Keeps the page's `reverseCost` answer as the reviewed cost (`debit =
/// amount + fee + railgun_fee`, strings of base units). Only a draft, or a
/// conversion waiting to be paid, is priced; `FundingCostChanged` when the
/// relayer's fee moved meanwhile: ask for a cost request again.
pub fn private_usd_reverse_set_cost(
    network: String,
    account_uuid: String,
    store_dir: String,
    index: u32,
    debit: String,
    railgun_fee: String,
) -> Result<ApiReverseRecord, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let debit = parse_amount(&debit)?;
        let railgun_fee = parse_amount(&railgun_fee)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let record = block_on(reverse::run_view(
            Path::new(&store_dir),
            network,
            "",
            &account_uuid,
            async |view, store| {
                let record = view.set_cost(store, index, debit, railgun_fee).await?;
                Ok(api_reverse_record(store, &account_uuid, &record))
            },
        ))?;
        no_such_conversion(record)
    })
}

/// The user went ahead with the reviewed draft (the first tap of "Convert"):
/// `Accepting` with `accepted_at`, nothing paid yet. Needs a priced draft
/// (`FundingCostChanged` otherwise); `QuoteExpired` once the quote ran out;
/// `Busy` while another conversion is under way. No key is needed.
pub fn private_usd_reverse_go_ahead(
    network: String,
    account_uuid: String,
    store_dir: String,
    eth_rpc_url: String,
    index: u32,
) -> Result<ApiReverseRecord, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let record = block_on(reverse::run_view(
            Path::new(&store_dir),
            network,
            &eth_rpc_url,
            &account_uuid,
            async |view, store| {
                let record = view.go_ahead(store, index).await?;
                Ok(api_reverse_record(store, &account_uuid, &record))
            },
        ))?;
        no_such_conversion(record)
    })
}

/// The maker's acceptance of swap `index`, posted once, and its joint account
/// imported (idempotent: call it again after an error). `TokensNeeded`: the
/// maker wants a token and no tokens client exists before M4; nothing
/// opened, so cancel the conversion. `NothingSent`: the maker's last word
/// ended it (`CANCELLED`), with the cause when known.
pub fn private_usd_reverse_accept(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    lightwalletd_url: String,
    eth_rpc_url: String,
    index: u32,
) -> Result<ApiAcceptResult, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let call = reverse_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            &lightwalletd_url,
            &eth_rpc_url,
            &keys,
        );
        let outcome = block_on(call.run(None, async |reverse, store| {
            reverse.accept(store, index).await
        }))?;
        let (kind, cause) = match outcome {
            ReverseAccept::Accepted => (ApiAcceptKind::Accepted, None),
            ReverseAccept::TokensNeeded => (ApiAcceptKind::TokensNeeded, None),
            ReverseAccept::Ended(cause) => (ApiAcceptKind::NothingSent, cause.map(api_cause)),
        };
        Ok(ApiAcceptResult { kind, cause, index })
    }))
}

/// The calls the Railgun page proves for swap `index`'s funding, with the
/// user's `OpenReverse` signed. `railgun_address` is the page's open wallet
/// (`openWallet`'s address): another than this account's is `Mismatch`.
/// Needs the conversion accepted and priced. Nothing is kept: after the
/// page's `prepareReverse`, pass its result to
/// `private_usd_reverse_submit_funding` while still unlocked, in the
/// foreground and in the same session; a lock drops it. `already_funded`:
/// skip the page and advance.
pub fn private_usd_reverse_funding_request(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    eth_rpc_url: String,
    index: u32,
    railgun_address: String,
) -> Result<ApiFundingRequest, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let call = reverse_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            "",
            &eth_rpc_url,
            &keys,
        );
        let request = block_on(call.run(None, async |reverse, store| {
            reverse
                .funding_request(store, index, &railgun_address)
                .await
        }))?;
        Ok(api_funding_request(&request))
    }))
}

/// Checks the page's `prepareReverse` result (`{to, data, value, cost:
/// {debit, railgunFee}}`), keeps it (`SendingUsdc`) and posts it. Nothing is
/// kept or sent when the conversion was called off or the wallet locked
/// since the request (`Cancelled`: drop the proof), when the record changed
/// (`TooLate`), or when the proved cost differs from the reviewed one
/// (`FundingCostChanged`: the new cost is kept for review, pay again). An
/// error after the keep means the funding is kept and the engine loop sends
/// the same bytes again: read the record. No key is needed.
pub fn private_usd_reverse_submit_funding(
    network: String,
    account_uuid: String,
    store_dir: String,
    eth_rpc_url: String,
    index: u32,
    to: String,
    data: String,
    value: String,
    debit: String,
    railgun_fee: String,
) -> Result<ApiReverseRecord, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let proved = ProvedFunding {
            to,
            data,
            value,
            debit: parse_amount(&debit)?,
            railgun_fee: parse_amount(&railgun_fee)?,
        };
        let _driver = engine::lock_account(&account_uuid)?;
        let record = block_on(reverse::run_view(
            Path::new(&store_dir),
            network,
            &eth_rpc_url,
            &account_uuid,
            async |view, store| {
                let record = view.submit_funding(store, index, proved).await?;
                Ok(api_reverse_record(store, &account_uuid, &record))
            },
        ))?;
        no_such_conversion(record)
    })
}

/// One look at the chain for swap `index`, then what is due: the funding
/// followed to its escrow (sent again only while the node does not know
/// it), the maker's deposit, a kept `ready` sent again, the sweep home, or
/// the refund. Never signs `ready`. Holds the account's driver lock
/// throughout (`Busy` if taken) and stops with `Cancelled` once
/// `private_usd_cancel(op_id)` is called. A failed step returns the record
/// with `problem` set; nap `next_poll_ms`, then advance again.
pub fn private_usd_reverse_advance(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    lightwalletd_url: String,
    eth_rpc_url: String,
    op_id: u32,
    index: u32,
) -> Result<ApiReverseAdvance, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let op = OpHandle::begin(op_id)?;
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        if op.cancelled() {
            return Err(engine::cancelled().into());
        }
        let call = reverse_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            &lightwalletd_url,
            &eth_rpc_url,
            &keys,
        );
        Ok(block_on(call.run(Some(&op), async |reverse, store| {
            let report = reverse.advance_report(store, index).await?;
            Ok(api_reverse_advance(store, &account_uuid, &report))
        }))?)
    }))
}

/// "Authorize settlement": once the maker's whole deposit has its
/// confirmations, signs `ready`, keeps it with the sweep's reviewed fee and
/// posts it. Offer it in `AwaitingReady` until `ready_deadline − 120`.
/// `DepositUnconfirmed` before the deposit or the escrow is confirmed,
/// `TooLate` past the deadline. A kept `ready` is only sent again; an error
/// after the keep leaves it kept, and the loop sends it until its deadline.
pub fn private_usd_reverse_authorize_ready(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    lightwalletd_url: String,
    eth_rpc_url: String,
    index: u32,
) -> Result<ApiReverseRecord, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let call = reverse_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            &lightwalletd_url,
            &eth_rpc_url,
            &keys,
        );
        Ok(block_on(call.run(None, async |reverse, store| {
            let record = reverse.authorize_ready(store, index).await?;
            Ok(api_reverse_record(store, &account_uuid, &record))
        }))?)
    }))
}

/// Calls swap `index` off: the request is kept first, then an advance runs
/// at once. With no escrow and no funding kept it ends `Cancelled`; with an
/// escrow, its refund starts (`RefundWait`, then `Refunding`). `TooLate`
/// once settled ("already settled, can no longer be refunded"), also when it
/// settled during this call. An error after the keep leaves the request
/// kept: read the record.
pub fn private_usd_reverse_cancel(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    lightwalletd_url: String,
    eth_rpc_url: String,
    index: u32,
) -> Result<ApiReverseRecord, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let call = reverse_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            &lightwalletd_url,
            &eth_rpc_url,
            &keys,
        );
        Ok(block_on(call.run(None, async |reverse, store| {
            let record = reverse.cancel(store, index).await?;
            Ok(api_reverse_record(store, &account_uuid, &record))
        }))?)
    }))
}

/// Whether swap `index`'s refund (a `Refunded` record) can be rescued now:
/// Railgun sent it back to its vault, which holds more than the relayer's
/// fee. A chain read only; no key and no lock.
pub fn private_usd_reverse_can_rescue(
    network: String,
    account_uuid: String,
    store_dir: String,
    eth_rpc_url: String,
    index: u32,
) -> Result<bool, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let rescuable = block_on(reverse::run_view(
            Path::new(&store_dir),
            network,
            &eth_rpc_url,
            &account_uuid,
            async |view, store| view.can_rescue(store, index).await,
        ))?;
        no_such_conversion(rescuable)
    })
}

/// "Recover refund": signs a rescue with a fresh nonce and deadline, keeps
/// it, and asks the relayer to shield the refund again into this account's
/// note. The record stays `Refunded`. Nothing happens when nothing is
/// rescuable now (check `private_usd_reverse_can_rescue` again).
pub fn private_usd_reverse_rescue(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    eth_rpc_url: String,
    index: u32,
) -> Result<ApiReverseRecord, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let network = parse_network_and_migrate(&db_path, &network)?;
        let keys = SwapKeyContext::open(&db_path, network, &account_uuid, &secret)?;
        let _driver = engine::lock_account(&account_uuid)?;
        let call = reverse_call(
            &db_path,
            network,
            &account_uuid,
            &store_dir,
            "",
            &eth_rpc_url,
            &keys,
        );
        Ok(block_on(call.run(None, async |reverse, store| {
            let record = reverse.rescue(store, index).await?;
            Ok(api_reverse_record(store, &account_uuid, &record))
        }))?)
    }))
}

/// The account's reverse conversions: the active one first (a draft too),
/// then the rest, newest first. Empty when the wallet never converted.
pub fn private_usd_reverse_records(
    account_uuid: String,
    store_dir: String,
) -> Result<Vec<ApiReverseRecord>, ApiPrivateUsdError> {
    catch(|| {
        let Some(store) = SwapStore::open_existing(Path::new(&store_dir))? else {
            return Ok(Vec::new());
        };
        Ok(reverse::records(&store, &account_uuid)?
            .iter()
            .map(|record| api_reverse_record(&store, &account_uuid, record))
            .collect())
    })
}

fn reverse_call<'s>(
    db_path: &'s str,
    network: WalletNetwork,
    account_uuid: &'s str,
    store_dir: &'s str,
    lightwalletd_url: &'s str,
    eth_rpc_url: &'s str,
    keys: &'s SwapKeyContext,
) -> reverse::ReverseCall<'s> {
    reverse::ReverseCall {
        main_db: db_path,
        network,
        account: account_uuid,
        store_dir: Path::new(store_dir),
        lightwalletd_url,
        eth_rpc_url,
        keys,
    }
}

/// The deployment of the wallet network `"main"` or `"test"`.
fn swap_network(network: &str) -> Result<PrivateUsdNetwork, ApiPrivateUsdError> {
    PrivateUsdNetwork::from_wallet(keys::parse_network(network)?).ok_or_else(|| {
        PrivateUsdError::new(
            ErrorCode::Unavailable,
            "no Private USD deployment on this network",
        )
        .into()
    })
}

/// A keyless step's result, or "no such conversion" for a wallet that never
/// converted.
fn no_such_conversion<T>(result: Option<T>) -> Result<T, ApiPrivateUsdError> {
    result.ok_or_else(|| PrivateUsdError::new(ErrorCode::Other, "no such conversion").into())
}

/// Token base units as a decimal string, as the page and Dart pass them.
fn parse_amount(text: &str) -> Result<Amount, ApiPrivateUsdError> {
    let valid = !text.is_empty() && text.len() <= 39 && text.bytes().all(|b| b.is_ascii_digit());
    valid
        .then(|| text.parse().ok())
        .flatten()
        .map(Amount)
        .ok_or_else(|| {
            PrivateUsdError::new(ErrorCode::Mismatch, "an amount is not decimal base units").into()
        })
}

fn api_cost_request(price: &FundingPrice) -> ApiReverseCostRequest {
    ApiReverseCostRequest {
        index: price.index,
        amount: price.amount.0.to_string(),
        railgun_proxy: hex_address(&price.railgun_proxy),
        fee: price.fee.0.to_string(),
        fee_expires_at: price.fee_expires_at.map(seconds),
    }
}

fn api_funding_request(request: &FundingRequest) -> ApiFundingRequest {
    ApiFundingRequest {
        amount: request.amount.0.to_string(),
        railgun_proxy: hex_address(&request.railgun_proxy),
        token: hex_address(&request.token),
        calls_to: request
            .calls
            .iter()
            .map(|call| hex_address(&call.to))
            .collect(),
        calls_data: request
            .calls
            .iter()
            .map(|call| format!("0x{}", hex::encode(&call.data)))
            .collect(),
        relay_adapt: hex_address(&request.relay_adapt),
        fee: request.fee.0.to_string(),
        already_funded: request.already_funded,
    }
}

fn api_reverse_advance(
    store: &SwapStore,
    account: &str,
    report: &ReverseReport,
) -> ApiReverseAdvance {
    ApiReverseAdvance {
        record: api_reverse_record(store, account, &report.record),
        next_poll_ms: u32::try_from(report.next_poll.as_millis()).unwrap_or(u32::MAX),
        problem: report.problem.map(api_code),
        needs_you: report.record.awaiting_user(),
    }
}

fn api_reverse_record(
    store: &SwapStore,
    account: &str,
    record: &ReverseRecord,
) -> ApiReverseRecord {
    let quote = &record.quote;
    let updated_at = store
        .updated_at(account, Direction::Reverse, record.index)
        .ok()
        .flatten()
        .unwrap_or_default();
    ApiReverseRecord {
        index: record.index,
        swap_id: record.swap_id.to_hex(),
        phase: api_reverse_phase(record.phase),
        amount: quote.terms.amount.0.to_string(),
        network_cost: quote.terms.network_cost.map(|cost| cost.0.to_string()),
        deposit_zat: quote.terms.deposit_zat,
        quote_expires_at: seconds(quote.terms.expires_at),
        funding_deadline: seconds(quote.funding_deadline),
        ready_deadline: seconds(quote.ready_deadline),
        refund_after: seconds(quote.refund_after),
        cost: record.cost.as_ref().map(|cost| ApiReverseCost {
            debit: cost.debit.0.to_string(),
            railgun_fee: cost.railgun_fee.0.to_string(),
            broadcaster_fee: cost.broadcaster_fee.0.to_string(),
            fee_expires_at: cost.fee_expires_at.map(seconds),
        }),
        funded: record.funding.is_some(),
        funding_tx: record
            .funding
            .as_ref()
            .and_then(|funding| funding.tx_id)
            .map(|transaction| transaction.to_hex()),
        cancel_requested: record.cancel_requested,
        settled: record.is_settled(),
        cancellable: record.cancellable(),
        awaiting_user: record.awaiting_user(),
        receive_estimate_zat: record
            .receive_estimate
            .as_ref()
            .map(|estimate| estimate.received_zat()),
        receive_fee_zat: record
            .receive_estimate
            .as_ref()
            .map(|estimate| estimate.fee_zat),
        receive_txid: record
            .receive
            .as_ref()
            .and_then(|receive| internal_hex(&receive.tx_id)),
        received_zat: record.receive.as_ref().map(|receive| receive.received_zat),
        receive_confirmations: u32::try_from(record.receive_confirmations).unwrap_or(u32::MAX),
        accepted_at: record.accepted_at.map(seconds),
        updated_at: seconds(updated_at),
    }
}

fn api_reverse_phase(phase: ReversePhase) -> ApiReversePhase {
    match phase {
        ReversePhase::Quoted => ApiReversePhase::Quoted,
        ReversePhase::Accepting => ApiReversePhase::Accepting,
        ReversePhase::AwaitingFunding => ApiReversePhase::AwaitingFunding,
        ReversePhase::SendingUsdc => ApiReversePhase::SendingUsdc,
        ReversePhase::ConfirmingEscrow => ApiReversePhase::ConfirmingEscrow,
        ReversePhase::ReceivingZec => ApiReversePhase::ReceivingZec,
        ReversePhase::AwaitingReady => ApiReversePhase::AwaitingReady,
        ReversePhase::Settling => ApiReversePhase::Settling,
        ReversePhase::Receiving => ApiReversePhase::Receiving,
        ReversePhase::Complete => ApiReversePhase::Complete,
        ReversePhase::RefundWait => ApiReversePhase::RefundWait,
        ReversePhase::Refunding => ApiReversePhase::Refunding,
        ReversePhase::RefundPayout => ApiReversePhase::RefundPayout,
        ReversePhase::Refunded => ApiReversePhase::Refunded,
        ReversePhase::Cancelled => ApiReversePhase::Cancelled,
    }
}

fn forward_call<'s>(
    db_path: &'s str,
    network: WalletNetwork,
    account_uuid: &'s str,
    store_dir: &'s str,
    lightwalletd_url: &'s str,
    eth_rpc_url: &'s str,
    keys: &'s SwapKeyContext,
) -> forward::ForwardCall<'s> {
    forward::ForwardCall {
        main_db: db_path,
        network,
        account: account_uuid,
        store_dir: Path::new(store_dir),
        lightwalletd_url,
        eth_rpc_url,
        keys,
    }
}

/// Runs an engine future on a runtime of its own. Never call it from async
/// code.
fn block_on<T>(
    future: impl std::future::Future<Output = Result<T, PrivateUsdError>>,
) -> Result<T, ApiPrivateUsdError> {
    let runtime = tokio::runtime::Runtime::new().map_err(|error| format!("tokio: {error}"))?;
    Ok(runtime.block_on(future)?)
}

fn api_quote(quoted: &Quoted) -> ApiForwardQuote {
    let offer = &quoted.offer;
    ApiForwardQuote {
        index: quoted.index,
        expires_at: seconds(offer.quote.expires_at),
        amount: offer.quote.amount.0.to_string(),
        network_cost: offer.quote.network_cost.map(|cost| cost.0.to_string()),
        relayer_fee: offer.relayer_fee.0.to_string(),
        receives: offer.receives.0.to_string(),
        deposit_zat: offer.quote.deposit_zat,
        deposit_fee_zat: offer.deposit_fee_zat,
        max_total_zat: offer.max_total_zat(),
        fee_expires_at: offer.fee_expires_at.map(seconds),
    }
}

fn api_advance(report: &AdvanceReport, db_path: &str, network: WalletNetwork) -> ApiForwardAdvance {
    ApiForwardAdvance {
        record: api_record(
            &report.record,
            deposit_confirmations(db_path, network, &report.record),
        ),
        wait: report.wait.map(|wait| match wait {
            ForwardWait::Opening => ApiForwardWait::Opening,
            ForwardWait::Confirming => ApiForwardWait::Confirming,
            ForwardWait::DepositUnsettled => ApiForwardWait::DepositUnsettled,
            ForwardWait::Refunding => ApiForwardWait::Refunding,
            ForwardWait::ZcashSyncing => ApiForwardWait::ZcashSyncing,
        }),
        next_poll_ms: u32::try_from(report.next_poll.as_millis()).unwrap_or(u32::MAX),
        problem: report.problem.map(api_code),
    }
}

fn api_record(record: &ForwardRecord, deposit_confirmations: Option<u32>) -> ApiForwardRecord {
    let (outcome, refund_cause, nothing_sent_cause) = match &record.outcome {
        None => (None, None, None),
        Some(ForwardOutcome::Paid) => (Some(ApiForwardOutcome::Paid), None, None),
        Some(ForwardOutcome::Refunded { cause, .. }) => (
            Some(ApiForwardOutcome::Refunded),
            Some(match cause {
                RefundCause::MakerCancelled => ApiRefundCause::MakerCancelled,
                RefundCause::NotClaimedInTime => ApiRefundCause::NotClaimedInTime,
            }),
            None,
        ),
        Some(ForwardOutcome::NothingSent { cause }) => (
            Some(ApiForwardOutcome::NothingSent),
            None,
            Some(api_cause(*cause)),
        ),
    };
    let phase = match record.phase_name() {
        "PAID" => ApiForwardPhase::Paid,
        "REFUNDED" => ApiForwardPhase::Refunded,
        "NOTHING_SENT" => ApiForwardPhase::NothingSent,
        "REFUNDING" => ApiForwardPhase::Refunding,
        "CLAIMING" => ApiForwardPhase::Claiming,
        "CONFIRMING" => ApiForwardPhase::Confirming,
        "DEPOSITING" => ApiForwardPhase::Depositing,
        _ => ApiForwardPhase::Opening,
    };
    ApiForwardRecord {
        index: record.index,
        swap_id: record.swap_id.to_hex(),
        phase,
        accepted_at: seconds(record.accepted_at),
        quote_expires_at: seconds(record.quote.expires_at),
        deposit_zat: record.quote.deposit_zat,
        max_total_zat: record.max_total_zat,
        amount: record.quote.amount.0.to_string(),
        receives: record.receives.0.to_string(),
        relayer_fee: record.relayer_fee.0.to_string(),
        t0: record.t0.map(seconds),
        t1: record.t1.map(seconds),
        deposit_txid: record
            .deposit
            .as_ref()
            .and_then(|deposit| internal_hex(&deposit.tx_id)),
        deposit_confirmations,
        sweep_txid: record
            .sweep
            .as_ref()
            .and_then(|sweep| internal_hex(&sweep.tx_id)),
        payout_tx: record.payout_tx.map(|transaction| transaction.to_hex()),
        outcome,
        refund_cause,
        nothing_sent_cause,
        ended_at: record.finished_at.map(seconds),
    }
}

/// The kept deposit's depth in the main wallet while the conversion is under
/// way; best effort, `None` when unknown.
fn deposit_confirmations(
    db_path: &str,
    network: WalletNetwork,
    record: &ForwardRecord,
) -> Option<u32> {
    if record.finished() {
        return None;
    }
    let deposit = record.deposit.as_ref()?;
    let txid = forward::internal_txid(&deposit.tx_id).ok()?;
    let expiry = u32::try_from(deposit.expiry_height).unwrap_or(u32::MAX);
    match joint_ops::swap_tx_status(db_path, network, &txid, expiry).ok()? {
        SwapTxStatus::Mined { confirmations, .. } => Some(confirmations),
        _ => Some(0),
    }
}

/// A record's transaction id in the wallet DB's byte order, as history rows
/// carry it.
fn internal_hex(tx_id: &ZcashTxId) -> Option<String> {
    forward::internal_txid(tx_id)
        .ok()
        .map(|txid| hex::encode(txid.as_ref()))
}

fn api_cause(cause: NothingSentCause) -> ApiNothingSentCause {
    match cause {
        NothingSentCause::QuoteExpired => ApiNothingSentCause::QuoteExpired,
        NothingSentCause::MakerRefused => ApiNothingSentCause::MakerRefused,
        NothingSentCause::MakerUnavailable => ApiNothingSentCause::MakerUnavailable,
        NothingSentCause::NeverOpened => ApiNothingSentCause::NeverOpened,
        NothingSentCause::Mismatch => ApiNothingSentCause::Mismatch,
        NothingSentCause::DepositWindowMissed => ApiNothingSentCause::DepositWindowMissed,
        NothingSentCause::MakerCancelled => ApiNothingSentCause::MakerCancelled,
    }
}

fn seconds(unix: u64) -> i64 {
    i64::try_from(unix).unwrap_or(i64::MAX)
}

fn open_context(
    db_path: &str,
    network: &str,
    account_uuid: &str,
    secret: &[u8],
) -> Result<SwapKeyContext, ApiPrivateUsdError> {
    let network = parse_network_and_migrate(db_path, network)?;
    Ok(SwapKeyContext::open(
        db_path,
        network,
        account_uuid,
        secret,
    )?)
}

fn parse_network_and_migrate(
    db_path: &str,
    network: &str,
) -> Result<WalletNetwork, ApiPrivateUsdError> {
    let network = keys::parse_network(network)?;
    keys::ensure_db_migrated_once(db_path, network).map_err(|message| ApiPrivateUsdError {
        code: ApiPrivateUsdErrorCode::ZcashWallet,
        message,
    })?;
    Ok(network)
}

fn catch<T>(
    f: impl FnOnce() -> Result<T, ApiPrivateUsdError> + panic::UnwindSafe,
) -> Result<T, ApiPrivateUsdError> {
    match panic::catch_unwind(f) {
        Ok(result) => result,
        Err(panic) => {
            let message = if let Some(text) = panic.downcast_ref::<&str>() {
                (*text).to_string()
            } else if let Some(text) = panic.downcast_ref::<String>() {
                text.clone()
            } else {
                "Unknown panic".to_string()
            };
            Err(format!("Rust panic: {message}").into())
        }
    }
}
