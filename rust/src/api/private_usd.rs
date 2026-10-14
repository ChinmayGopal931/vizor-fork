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
    models::{ForwardOutcome, ForwardRecord, NothingSentCause, RefundCause, ZcashTxId},
    railgun_keys,
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
/// `AtomicSwapActivity`). The reverse steps arrive with M6.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiActivity {
    Depositing,
    Claiming,
    PayingOut,
    Sweeping,
    Funding,
    Readying,
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
    })
}

/// Forgets every in-memory session: call it on lock. A forward quote made
/// before the lock is never accepted after it, and each maker's `/v1/info` is
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
