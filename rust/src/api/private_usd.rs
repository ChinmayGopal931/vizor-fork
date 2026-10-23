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
    abi::hex0x,
    deployment, deposits,
    engine::{self, Activity, Clock, OpHandle, SystemClock},
    evm_rpc::EvmRpc,
    forward::{self, AcceptOutcome, AdvanceReport, ForwardWait, Quoted},
    joint::{self as joint_ops, SwapTxStatus},
    keys::{account_derivation, SwapKeyContext},
    models::{
        Address, Amount, ClaimHold, Direction, ForwardOutcome, ForwardPhase, ForwardRecord,
        NothingSentCause, RefundCause, ReversePhase, ReverseRecord, ZcashTxId,
    },
    railgun_keys,
    relayer_client::{RailgunBroadcast, RelayerClient},
    reverse::{self, FundingPrice, FundingRequest, ProvedFunding, ReverseAccept, ReverseReport},
    sends::{self, ProvedSend, SendRecord, Sends},
    store::SwapStore,
    swap::{self, SwapCall},
    ErrorCode, PrivateUsdError, PrivateUsdNetwork,
};
use crate::wallet::routed_http::RoutedHttp;

/// Why a Private USD call failed. Copy follows the code, never the message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiPrivateUsdErrorCode {
    RelayerUnreachable,
    RelayerRefused,
    RelayerFee,
    EthereumUnreachable,
    RailgunClosed,
    ZcashWallet,
    DepositUnpayable,
    ZcashRejected,
    Mismatch,
    TokensRefused,
    TokensNeeded,
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
    /// A service or the node belongs to another deployment than this build
    /// pins: a contract that is not the pinned windows contract, or terms
    /// that are not the pin's. Never followed.
    WrongDeployment,
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
        ErrorCode::ZcashWallet => Api::ZcashWallet,
        ErrorCode::DepositUnpayable => Api::DepositUnpayable,
        ErrorCode::ZcashRejected => Api::ZcashRejected,
        ErrorCode::Mismatch => Api::Mismatch,
        ErrorCode::TokensRefused => Api::TokensRefused,
        ErrorCode::TokensNeeded => Api::TokensNeeded,
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
        ErrorCode::WrongDeployment => Api::WrongDeployment,
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

/// A network's pinned deployment, as Dart reads it.
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
    /// Where public USDC is shielded into the private balance; `None` where
    /// no Deposits contract is pinned, which hides deposits.
    pub deposits: Option<ApiDepositsPin>,
    /// Whether a windows contract is pinned, so bridging runs. Off, quotes
    /// and conversions are refused (`Unavailable`): hide Bridge. Balance,
    /// deposits, sends and withdrawals work either way.
    pub bridge_available: bool,
}

/// A network's pinned Deposits deployment.
pub struct ApiDepositsPin {
    /// The Deposits contract, `0x` lowercase.
    pub contract: String,
    /// The token deposits take (the swap token), `0x` lowercase.
    pub token: String,
    /// `USDC`, or `tUSD` on testnet.
    pub token_symbol: String,
    /// The network a sender picks: `Ethereum`, or `Sepolia` on testnet.
    pub chain_name: String,
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
        token: hex0x(&pins.token),
        token_decimals: deployment::TOKEN_DECIMALS,
        keyless_rpc_url: pins.keyless_rpc_url.into(),
        poi_node_url: pins.poi_node_url.into(),
        railgun_proxy: hex0x(&pins.railgun_proxy),
        relay_adapt: hex0x(&pins.relay_adapt),
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
                address: hex0x(&token.address),
                symbol: token.symbol.to_owned(),
            })
            .collect(),
        deposits: pins.deposits.map(|pin| ApiDepositsPin {
            contract: hex0x(&pin.contract),
            token: hex0x(&pin.token),
            token_symbol: pins
                .usd_tokens
                .iter()
                .find(|token| token.address == pin.token)
                .map_or("USDC", |token| token.symbol)
                .to_owned(),
            chain_name: match network {
                PrivateUsdNetwork::Mainnet => "Ethereum",
                PrivateUsdNetwork::Testnet => "Sepolia",
            }
            .to_owned(),
        }),
        bridge_available: pins.swaps.is_some(),
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

// ---- conversions ----

/// What a call is doing now, for the progress screen.
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
    /// Revealing or paying out a reverse refund.
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

/// What call `op_id` is doing now, while it runs; poll it about every 500 ms
/// during an advance.
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
/// checked again.
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
/// of them while the app is open and unlocked.
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
    /// The maker wants a Privacy Pass token, which this build cannot get.
    /// Nothing opened; abandon the conversion.
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
    /// The deposit is out; waiting for the maker to mark the swap ready (and
    /// the ready to be 2 blocks deep), or for `t0`. A claim the relayer
    /// holds is left to it for the window's first minute.
    Confirming,
    /// The maker called the swap off while the deposit was unmined.
    DepositUnsettled,
    /// The refunded deposit is on its way home.
    Refunding,
    /// The Zcash wallet is syncing: never a problem.
    ZcashSyncing,
    /// Too late to claim before `t1`, and from `t1` the swap is the maker's
    /// to refund: the swap unwinds, and the ZEC comes back after the maker's
    /// refund. If the maker never refunds, the claim goes out from
    /// `late_claim_at`.
    Unwinding,
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
    /// `t1` and the contract's late window: from here a swap the maker never
    /// refunded is claimed after all. `None` before the maker answered.
    pub late_claim_at: Option<i64>,
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
    /// The relayer holds the claim and sends it once the claim's window
    /// opens: the claim no longer needs Veylor open.
    pub claim_held: bool,
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
    /// minute in a row.
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
        let quoted = drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            &lightwalletd_url,
            &eth_rpc_url,
            None,
            async |call, op| {
                call.forward(op, async |forward, store| forward.quote(store, units).await)
                    .await
            },
        )?;
        Ok(api_quote(&quoted))
    }))
}

/// Accepts the quote of swap `index`: saves the record, then posts the
/// accept. A missing offer is `QuoteExpired`. Called again for the same
/// index, it posts the saved quote once more (never a new index). An error
/// after the save means "maybe opened": read the records and show the
/// conversion's progress if it is under way. With `relayer_claims` (the
/// setting, kept on the record), the claim goes to the relayer once the
/// deposit is out, for it to send when the claim's window opens.
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
    relayer_claims: bool,
) -> Result<ApiAcceptResult, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let outcome = drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            &lightwalletd_url,
            &eth_rpc_url,
            None,
            async |call, op| {
                call.forward(op, async |forward, store| {
                    forward
                        .accept(store, index, max_total_zat, relayer_claims)
                        .await
                })
                .await
            },
        )?;
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
        drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            &lightwalletd_url,
            &eth_rpc_url,
            Some(op_id),
            async |call, op| {
                let report = call
                    .forward(op, async |forward, store| {
                        forward.advance_report(store, index).await
                    })
                    .await?;
                Ok(api_advance(&report, call.main_db, call.network))
            },
        )
    }))
}

/// Drops swap `index` before it reached the chain: an unanswered accept ends
/// `MakerUnavailable` (a turn-away at the token gate included), an answered
/// one `NeverOpened`. `TooLate` once a deposit started or the chain shows
/// the swap. No key is needed.
pub fn private_usd_forward_abandon(
    network: String,
    account_uuid: String,
    store_dir: String,
    eth_rpc_url: String,
    index: u32,
) -> Result<ApiForwardRecord, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
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
        Ok(swap::records::<ForwardRecord>(&store, &account_uuid)?
            .iter()
            .map(|record| api_record(record, deposit_confirmations(&db_path, network, record)))
            .collect())
    })
}

// ---- reverse conversions ----

/// Where a reverse conversion stands.
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
    /// minute in a row.
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
        drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            &lightwalletd_url,
            &eth_rpc_url,
            None,
            async |call, op| {
                call.reverse(op, async |reverse, store| {
                    let quoted = reverse.quote(store, units).await?;
                    Ok(ApiReverseQuote {
                        record: api_reverse_record(store, &account_uuid, &quoted.record),
                        cost_request: api_cost_request(&quoted.price),
                    })
                })
                .await
            },
        )
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
/// maker wants a token, which this build cannot get; nothing opened, so
/// cancel the conversion. `NothingSent`: the maker's last word
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
        let outcome = drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            &lightwalletd_url,
            &eth_rpc_url,
            None,
            async |call, op| {
                call.reverse(op, async |reverse, store| {
                    reverse.accept(store, index).await
                })
                .await
            },
        )?;
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
        let request = drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            "",
            &eth_rpc_url,
            None,
            async |call, op| {
                call.reverse(op, async |reverse, store| {
                    reverse
                        .funding_request(store, index, &railgun_address)
                        .await
                })
                .await
            },
        )?;
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
        drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            &lightwalletd_url,
            &eth_rpc_url,
            Some(op_id),
            async |call, op| {
                call.reverse(op, async |reverse, store| {
                    let report = reverse.advance_report(store, index).await?;
                    Ok(api_reverse_advance(store, &account_uuid, &report))
                })
                .await
            },
        )
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
        drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            &lightwalletd_url,
            &eth_rpc_url,
            None,
            async |call, op| {
                call.reverse(op, async |reverse, store| {
                    let record = reverse.authorize_ready(store, index).await?;
                    Ok(api_reverse_record(store, &account_uuid, &record))
                })
                .await
            },
        )
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
        drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            &lightwalletd_url,
            &eth_rpc_url,
            None,
            async |call, op| {
                call.reverse(op, async |reverse, store| {
                    let record = reverse.cancel(store, index).await?;
                    Ok(api_reverse_record(store, &account_uuid, &record))
                })
                .await
            },
        )
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
        drive(
            &db_path,
            &network,
            &account_uuid,
            &store_dir,
            &secret,
            "",
            &eth_rpc_url,
            None,
            async |call, op| {
                call.reverse(op, async |reverse, store| {
                    let record = reverse.rescue(store, index).await?;
                    Ok(api_reverse_record(store, &account_uuid, &record))
                })
                .await
            },
        )
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
        Ok(swap::records::<ReverseRecord>(&store, &account_uuid)?
            .iter()
            .map(|record| api_reverse_record(&store, &account_uuid, record))
            .collect())
    })
}

// ---- private sends and withdrawals ----

/// The relayer's terms for private sends and withdrawals, already held to
/// the deployment's pins. The page's broadcaster is `{chainId, railgunProxy,
/// railgunAddress, token, minFee: fee_floor, feePerUnitGas?, maxGasPrice:
/// max_gas_price_wei}`. Amounts are decimal base units of `token`.
pub struct ApiRailgunSendsTerms {
    pub chain_id: i64,
    /// The relayer's `0zk`, which the fee note pays.
    pub railgun_address: String,
    pub railgun_proxy: String,
    /// The fee token (`0x` lowercase), the deployment's swap token.
    pub token: String,
    /// The least fee a send pays; never above `max_relayer_fee`.
    pub fee_floor: String,
    /// Fee-token base units per 10^18 wei of gas, where the relayer prices
    /// gas; then `fee_expires_at` is set too.
    pub fee_per_unit_gas: Option<String>,
    /// Unix seconds until which a fee worked out at that rate is held.
    pub fee_expires_at: Option<i64>,
    pub max_gas_limit: String,
    pub max_gas_price_wei: String,
    pub max_calldata_bytes: u32,
}

/// A proved send or withdrawal, as Dart hands it to Rust to keep before it is
/// posted.
pub struct ApiProvedSend {
    /// A new UUID per send.
    pub send_id: String,
    /// The token sent (`0x`), one of the deployment's `usd_tokens`.
    pub token: String,
    /// Base units sent, the relayer's fee aside.
    pub amount: String,
    /// The `broadcasterFee` the proof pays the relayer, in base units of the
    /// deployment's token; at most `max_relayer_fee`.
    pub fee: String,
    /// The `0zk` (lowercase) or `0x` destination.
    pub to: String,
    /// The page's `transfer` or `unshield` result, unchanged.
    pub proof_json: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiSendState {
    /// Proved and kept; not seen in a block yet. Blocks the account's next
    /// payment.
    Unconfirmed,
    Confirmed,
}

/// One send or withdrawal of the log.
pub struct ApiSendRecord {
    pub send_id: String,
    pub token: String,
    pub amount: String,
    pub fee: String,
    pub to: String,
    pub withdraw: bool,
    /// Unix seconds when it was kept.
    pub sent_at: i64,
    pub state: ApiSendState,
    /// The relayer's transaction, once it named one (`0x`).
    pub tx_hash: Option<String>,
    /// While unconfirmed: the last post, the last "already spent" answer,
    /// and the time the relayer asked to wait for.
    pub posted_at: Option<i64>,
    pub spent_at: Option<i64>,
    pub retry_at: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiTransactKind {
    /// Submitted in `transactions[0]`, not mined yet.
    Sent,
    /// Its notes are spent (by `transactions`, where named): the chain
    /// settles it.
    Spent,
    /// Refused: nothing went, and the send is dropped from the log.
    Refused,
    /// No answer that settles anything: the same bytes go again, no sooner
    /// than `retry_after_secs` where set.
    Retry,
}

pub struct ApiTransactResult {
    pub kind: ApiTransactKind,
    pub transactions: Vec<String>,
    /// At most an hour.
    pub retry_after_secs: Option<u32>,
}

/// `GET /v1/terms`' `railgunSends`, held to the pins. `Unavailable` when the
/// relayer sends none now, or none the pins allow; `RelayerFee` when its
/// least fee is above the 2 USDC cap.
pub fn private_usd_railgun_sends_terms(
    network: String,
) -> Result<ApiRailgunSendsTerms, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let pins = deployment::deployment(network);
        let transport = RoutedHttp::new();
        let relayer = RelayerClient::new(&transport, pins.relayer_url);
        let terms = block_on(relayer.railgun_sends(pins))?.ok_or_else(|| {
            PrivateUsdError::new(
                ErrorCode::Unavailable,
                "the relayer sends no private payments now",
            )
        })?;
        Ok(ApiRailgunSendsTerms {
            chain_id: terms.chain_id as i64,
            railgun_address: terms.railgun_address.to_owned(),
            railgun_proxy: hex0x(&terms.railgun_proxy),
            token: hex0x(&terms.fee_token),
            fee_floor: terms.min_fee.0.to_string(),
            fee_per_unit_gas: terms.fee_per_unit_gas,
            fee_expires_at: terms.fee_expires_at.map(seconds),
            max_gas_limit: terms.max_gas_limit.to_string(),
            max_gas_price_wei: terms.max_gas_price_wei,
            max_calldata_bytes: terms.max_calldata_bytes,
        })
    })
}

/// Keeps a proved send before it is posted. Call it only while still
/// unlocked and in the foreground, then post it with
/// `private_usd_relayer_transact`. On any error nothing was kept and
/// nothing goes out: `Mismatch` (the proof is not this deployment's or not
/// this send's, or another proof is kept under the id), `RelayerFee` (a fee
/// above the cap), `Busy` (another payment of the account is unsettled, or
/// a conversion is under way). Keeping the same send again returns it.
pub fn private_usd_send_log_put(
    store_dir: String,
    network: String,
    account_uuid: String,
    send: ApiProvedSend,
) -> Result<ApiSendRecord, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let token = Address::parse(&send.token).ok_or_else(|| {
            PrivateUsdError::new(ErrorCode::Mismatch, "the token is not an address")
        })?;
        let proved = ProvedSend {
            id: &send.send_id,
            token,
            amount: parse_amount(&send.amount)?,
            fee: parse_amount(&send.fee)?,
            to: &send.to,
            proof_json: &send.proof_json,
        };
        let mut store = SwapStore::open(Path::new(&store_dir))?;
        let record = sends::keep(
            &mut store,
            deployment::deployment(network),
            &account_uuid,
            &proved,
            SystemClock.now(),
        )?;
        Ok(api_send_record(&record))
    })
}

/// The account's sends and withdrawals, newest first; empty when the wallet
/// never kept one. `StoreUnreadable` must keep spending blocked.
pub fn private_usd_send_log_list(
    store_dir: String,
    account_uuid: String,
) -> Result<Vec<ApiSendRecord>, ApiPrivateUsdError> {
    catch(|| {
        let Some(store) = SwapStore::open_existing(Path::new(&store_dir))? else {
            return Ok(Vec::new());
        };
        Ok(sends::records(&store, &account_uuid)?
            .iter()
            .map(api_send_record)
            .collect())
    })
}

/// Posts the kept request of `send_id` to the relayer (`POST
/// /v1/railgun/transact`), never bytes from Dart, and notes the answer in
/// the log. `Other` when no such send is kept: nothing went out.
pub fn private_usd_relayer_transact(
    store_dir: String,
    network: String,
    account_uuid: String,
    send_id: String,
) -> Result<ApiTransactResult, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let pins = deployment::deployment(network);
        let Some(mut store) = SwapStore::open_existing(Path::new(&store_dir))? else {
            return Err(PrivateUsdError::new(ErrorCode::Other, "no such send").into());
        };
        let transport = RoutedHttp::new();
        let clock = SystemClock;
        let relay = Sends::new(&transport, pins.relayer_url, &clock, &account_uuid);
        let answer = block_on(relay.transact(&mut store, &send_id))?;
        Ok(api_transact(&answer))
    })
}

/// One settlement pass over the account's unconfirmed sends: each is marked
/// confirmed from its receipt (1 confirmation) or its nullifiers, dropped
/// once it reverted or another proof took part of its notes, or posted again
/// as the same bytes. A pass asked for while one runs returns at once.
/// Returns the sends after it.
pub fn private_usd_send_settle_all(
    store_dir: String,
    network: String,
    eth_rpc_url: String,
    account_uuid: String,
) -> Result<Vec<ApiSendRecord>, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let Some(mut store) = SwapStore::open_existing(Path::new(&store_dir))? else {
            return Ok(Vec::new());
        };
        let pins = deployment::deployment(network);
        let transport = RoutedHttp::new();
        let chain = EvmRpc::new(&transport, pins, &eth_rpc_url);
        let clock = SystemClock;
        let relay = Sends::new(&transport, pins.relayer_url, &clock, &account_uuid);
        Ok(block_on(relay.settle_all(&mut store, &chain))?
            .iter()
            .map(api_send_record)
            .collect())
    })
}

fn api_send_record(send: &SendRecord) -> ApiSendRecord {
    let relay = send.relay.as_ref();
    ApiSendRecord {
        send_id: send.id.clone(),
        token: hex0x(&send.token.0),
        amount: send.amount.0.to_string(),
        fee: send.fee.0.to_string(),
        to: send.to.clone(),
        withdraw: send.withdraw(),
        sent_at: seconds(send.sent_at),
        state: if send.confirmed() {
            ApiSendState::Confirmed
        } else {
            ApiSendState::Unconfirmed
        },
        tx_hash: send.tx_hash.map(|transaction| transaction.to_hex()),
        posted_at: relay.and_then(|relay| relay.posted_at).map(seconds),
        spent_at: relay.and_then(|relay| relay.spent_at).map(seconds),
        retry_at: relay.and_then(|relay| relay.retry_at).map(seconds),
    }
}

fn api_transact(answer: &RailgunBroadcast) -> ApiTransactResult {
    let to_hex = |transaction: &[u8; 32]| hex0x(transaction);
    let (kind, transactions, retry_after_secs) = match answer {
        RailgunBroadcast::Sent(transaction) => {
            (ApiTransactKind::Sent, vec![to_hex(transaction)], None)
        }
        RailgunBroadcast::Refused { .. } => (ApiTransactKind::Refused, Vec::new(), None),
        RailgunBroadcast::Spent(transactions) => (
            ApiTransactKind::Spent,
            transactions.iter().map(to_hex).collect(),
            None,
        ),
        RailgunBroadcast::Retry { retry_after_secs } => (
            ApiTransactKind::Retry,
            Vec::new(),
            retry_after_secs.map(|seconds| u32::try_from(seconds).unwrap_or(u32::MAX)),
        ),
    };
    ApiTransactResult {
        kind,
        transactions,
        retry_after_secs,
    }
}

// ---- deposits ----

/// The relayer's deposit terms, held to the pin, for the Receive USDC sheet
/// (amounts in token base units).
pub struct ApiDepositTerms {
    /// The relayer's fee before its percentage; a rescue pays it alone.
    pub fee: String,
    /// The relayer's percentage of a deposit, in basis points.
    pub fee_bps: u32,
    /// Until when an authorization signed with `fee` is taken (Unix
    /// seconds), where gas prices the fee.
    pub fee_expires_at: Option<i64>,
    /// The least a deposit moves.
    pub min_value: String,
    /// Railgun's shield fee, in basis points.
    pub railgun_fee_bps: u32,
}

/// What a deposit of an amount costs and brings.
pub struct ApiDepositQuote {
    /// The relayer's fee.
    pub fee: String,
    /// What reaches the private balance after both fees.
    pub arrives: String,
}

/// The deposit address to show and its index.
pub struct ApiDepositAddress {
    pub index: u32,
    /// EIP-55, as exchanges' withdrawal forms take it.
    pub address: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiDepositKind {
    /// An address's balance shielded on its authorization.
    Shield,
    /// What Railgun sent back to an address's vault, shielded again.
    Rescue,
}

/// Where a deposit stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiDepositState {
    /// Kept, not yet answered with a transaction: "Received $X" (or, with
    /// `waiting`, "Waiting for the network").
    Signed,
    /// Posted, until it mines: "Shielding…".
    Sent,
    /// Mined and believed: "Shielded, available in …".
    Landed,
    /// Refused: the address shows as received but not shielding.
    Refused,
    /// Its transaction reverted: nothing moved; signed again after an hour.
    Reverted,
    /// Signed again in its place: not shown.
    Replaced,
    /// Its validity ran out first: not shown.
    Expired,
}

/// One kept deposit or rescue, for the screen and the activity rows.
pub struct ApiDepositRecord {
    pub id: String,
    pub kind: ApiDepositKind,
    /// The deposit address's index, and the address (EIP-55).
    pub index: u32,
    pub address: String,
    pub state: ApiDepositState,
    /// What it moves (a rescue: its vault's balance when signed).
    pub value: String,
    /// The relayer's fee.
    pub fee: String,
    /// What reaches the private balance: the contract's own figure once it
    /// landed, else what the request should bring.
    pub arrives: String,
    /// Unix seconds when it was signed, and when it ended.
    pub created_at: i64,
    pub ended_at: Option<i64>,
    /// The transaction that landed it, or the last the relayer named.
    pub tx_hash: Option<String>,
    /// The relayer asked to wait over 30 s, or could not be reached.
    pub waiting: bool,
}

/// A used deposit address: it holds tokens or has deposited.
pub struct ApiDepositAddressUse {
    pub index: u32,
    pub address: String,
    pub balance: String,
    pub deposited: bool,
}

/// A vault holding more than a rescue's fee: "Recover" is offered.
pub struct ApiDepositRescuable {
    pub index: u32,
    pub address: String,
    pub held: String,
    pub fee: String,
}

/// One deposit pass: the address to show, the used ones, the account's
/// deposits, the terms and when to pass again.
pub struct ApiDepositPass {
    pub index: u32,
    pub address: String,
    pub used: Vec<ApiDepositAddressUse>,
    pub records: Vec<ApiDepositRecord>,
    /// The terms, or why they did not read: `Unavailable` or
    /// `WrongDeployment` means deposits are unavailable (show no address);
    /// anything else only that the fees could not load.
    pub terms: Option<ApiDepositTerms>,
    pub terms_error: Option<ApiPrivateUsdErrorCode>,
    pub rescuable: Vec<ApiDepositRescuable>,
    /// Whether this pass read the addresses from the chain, and when they
    /// were last read.
    pub scanned: bool,
    pub scanned_at: Option<i64>,
    /// When to pass again; none while nothing is posted or due.
    pub next_poll_ms: Option<u32>,
    /// The first step that failed (a scan, a signing, a post).
    pub problem: Option<ApiPrivateUsdErrorCode>,
}

/// The relayer's deposit terms (`GET /v1/terms`' `deposits`), held to the
/// pin. `Unavailable` where nothing is pinned or the relayer takes none,
/// `WrongDeployment` for another deployment's: say deposits are
/// unavailable. Anything else (Tor starting, the relayer down): show the
/// address and say the fees could not load.
pub fn private_usd_deposit_terms(network: String) -> Result<ApiDepositTerms, ApiPrivateUsdError> {
    catch(|| {
        let network = swap_network(&network)?;
        let pins = deployment::deployment(network);
        let transport = RoutedHttp::new();
        let relayer = RelayerClient::new(&transport, pins.relayer_url);
        let terms = block_on(async {
            let terms = relayer.terms().await?;
            deposits::pinned_terms(&terms, pins)
        })?;
        Ok(api_deposit_terms(&terms))
    })
}

/// What a deposit of `value` costs and brings under the relayer's `fee`
/// and `fee_bps`; `None` when its fee is above the cap or not under the
/// value, so nothing would be signed.
#[frb(sync)]
pub fn private_usd_deposit_quote(
    fee: String,
    fee_bps: u32,
    value: String,
) -> Option<ApiDepositQuote> {
    let (fee, value) = (fee.parse::<u128>().ok()?, value.parse::<u128>().ok()?);
    let fee = deposits::capped_fee(fee, fee_bps, value).ok()?;
    Some(ApiDepositQuote {
        fee: fee.to_string(),
        arrives: deposits::arrives(value, fee).to_string(),
    })
}

/// The deposit address to show now, from the last scan kept (index 0 before
/// any): no network, so it shows while Tor starts. Checks the seed against
/// the account first.
pub fn private_usd_deposit_address(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
) -> Result<ApiDepositAddress, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let keys = open_context(&db_path, &network, &account_uuid, &secret)?;
        if deployment::deployment(keys.network()).deposits.is_none() {
            return Err(PrivateUsdError::new(
                ErrorCode::Unavailable,
                "no Deposits contract is pinned here",
            )
            .into());
        }
        let index = match SwapStore::open_existing(Path::new(&store_dir))? {
            Some(store) => {
                deposits::last_scan(&store, &account_uuid)?.map_or(0, |(_, scan)| scan.showing)
            }
            None => 0,
        };
        let address = keys.deposit_keys(index)?.key.address();
        Ok(ApiDepositAddress {
            index,
            address: deposits::eip55(&address),
        })
    }))
}

/// One deposit pass for the account (the active one): scans its deposit
/// addresses (Multicall3, twenty a call, until a window holds none used),
/// posts again what was kept, follows what the relayer named, and with
/// `sign_new` signs, keeps and posts a deposit for each address holding at
/// least the minimum. A deposit already under way is followed and posted
/// whatever `sign_new` says (the kill switch never stops one). With
/// `check_vaults` it also reads which vaults can be rescued. With
/// `only_if_used` (the passes nothing asked for: unlock, the foreground, an
/// account switch) an account that never scanned or kept a deposit gets the
/// address to show and nothing else: no network, and no store created.
/// `Busy` while another pass or a rescue of the account runs; stops with
/// `Cancelled` once `private_usd_cancel(op_id)` is called. Run it only while
/// unlocked and in the foreground.
pub fn private_usd_deposit_pass(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    eth_rpc_url: String,
    op_id: u32,
    sign_new: bool,
    check_vaults: bool,
    only_if_used: bool,
) -> Result<ApiDepositPass, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let op = OpHandle::begin(op_id)?;
        let keys = open_context(&db_path, &network, &account_uuid, &secret)?;
        let _guard = deposits::lock_account(&account_uuid)?;
        if op.cancelled() {
            return Err(engine::cancelled().into());
        }
        if only_if_used {
            let used = match SwapStore::open_existing(Path::new(&store_dir))? {
                Some(store) => {
                    deposits::last_scan(&store, &account_uuid)?.is_some()
                        || !store.deposits(&account_uuid)?.is_empty()
                }
                None => false,
            };
            if !used {
                let address = keys.deposit_keys(0)?.key.address();
                return Ok(api_deposit_pass(&deposits::PassReport::unused(address)));
            }
        }
        let report = block_on(deposits::run(
            Path::new(&store_dir),
            &keys,
            &account_uuid,
            &eth_rpc_url,
            Some(&op),
            async |deposits, store| deposits.pass(store, sign_new, check_vaults).await,
        ))?;
        Ok(api_deposit_pass(&report))
    }))
}

/// The account's deposits and rescues, newest first; empty when none was
/// ever kept. No network and no key.
pub fn private_usd_deposit_records(
    account_uuid: String,
    store_dir: String,
) -> Result<Vec<ApiDepositRecord>, ApiPrivateUsdError> {
    catch(|| {
        let Some(store) = SwapStore::open_existing(Path::new(&store_dir))? else {
            return Ok(Vec::new());
        };
        Ok(deposits::records(&store, &account_uuid)?
            .iter()
            .map(api_deposit_record)
            .collect())
    })
}

/// "Recover" a deposit whose note Railgun's screening refused and sent back
/// to the address's vault (the user's action, behind a confirmation): signs
/// a rescue with the vault's next nonce, keeps it and posts it. It pays the
/// relayer's `fee` alone, at most 2 USDC. `Unavailable` when
/// the vault holds no more than the fee, `Busy` while a rescue of the
/// address or a pass runs.
pub fn private_usd_deposit_rescue(
    db_path: String,
    network: String,
    account_uuid: String,
    store_dir: String,
    mnemonic_bytes: Vec<u8>,
    eth_rpc_url: String,
    index: u32,
) -> Result<ApiDepositRecord, ApiPrivateUsdError> {
    let secret = Zeroizing::new(mnemonic_bytes);
    catch(panic::AssertUnwindSafe(|| {
        let keys = open_context(&db_path, &network, &account_uuid, &secret)?;
        let _guard = deposits::lock_account(&account_uuid)?;
        let record = block_on(deposits::run(
            Path::new(&store_dir),
            &keys,
            &account_uuid,
            &eth_rpc_url,
            None,
            async |deposits, store| deposits.rescue(store, index).await,
        ))?;
        Ok(api_deposit_record(&record))
    }))
}

fn api_deposit_terms(terms: &deposits::DepositTerms) -> ApiDepositTerms {
    ApiDepositTerms {
        fee: terms.fee.to_string(),
        fee_bps: terms.fee_bps,
        fee_expires_at: terms.fee_expires_at.map(seconds),
        min_value: terms.min_value.to_string(),
        railgun_fee_bps: deployment::RAILGUN_FEE_BPS as u32,
    }
}

fn api_deposit_record(record: &deposits::DepositRecord) -> ApiDepositRecord {
    ApiDepositRecord {
        id: record.id.clone(),
        kind: match record.kind {
            deposits::DepositKind::Shield => ApiDepositKind::Shield,
            deposits::DepositKind::Rescue => ApiDepositKind::Rescue,
        },
        index: record.index,
        address: deposits::eip55(&record.from()),
        state: match record.state {
            deposits::DepositState::Signed => ApiDepositState::Signed,
            deposits::DepositState::Sent => ApiDepositState::Sent,
            deposits::DepositState::Landed => ApiDepositState::Landed,
            deposits::DepositState::Refused => ApiDepositState::Refused,
            deposits::DepositState::Reverted => ApiDepositState::Reverted,
            deposits::DepositState::Replaced => ApiDepositState::Replaced,
            deposits::DepositState::Expired => ApiDepositState::Expired,
        },
        value: record.value.0.to_string(),
        fee: record.fee().to_string(),
        arrives: record.arrives().to_string(),
        created_at: seconds(record.created_at),
        ended_at: record.ended_at.map(seconds),
        tx_hash: record
            .landing
            .and_then(|landing| landing.tx)
            .or_else(|| record.transactions.last().copied())
            .map(|tx| tx.to_hex()),
        waiting: record.waiting,
    }
}

fn api_deposit_pass(report: &deposits::PassReport) -> ApiDepositPass {
    ApiDepositPass {
        index: report.showing,
        address: deposits::eip55(&report.showing_address),
        used: report
            .used
            .iter()
            .map(|address| ApiDepositAddressUse {
                index: address.index,
                address: deposits::eip55(&address.address),
                balance: address.balance.to_string(),
                deposited: address.deposited,
            })
            .collect(),
        records: report.records.iter().map(api_deposit_record).collect(),
        terms: report
            .terms
            .as_ref()
            .and_then(|terms| terms.as_ref().ok())
            .map(api_deposit_terms),
        terms_error: report
            .terms
            .as_ref()
            .and_then(|terms| terms.as_ref().err())
            .map(|code| api_code(*code)),
        rescuable: report
            .rescuable
            .iter()
            .map(|rescuable| ApiDepositRescuable {
                index: rescuable.index,
                address: report
                    .used
                    .iter()
                    .find(|address| address.index == rescuable.index)
                    .map(|address| deposits::eip55(&address.address))
                    .unwrap_or_default(),
                held: rescuable.held.to_string(),
                fee: rescuable.fee.to_string(),
            })
            .collect(),
        scanned: report.scanned,
        scanned_at: report.scanned_at.map(seconds),
        next_poll_ms: report
            .next_poll
            .map(|nap| u32::try_from(nap.as_millis()).unwrap_or(u32::MAX)),
        problem: report.problem.map(api_code),
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
        railgun_proxy: hex0x(&price.railgun_proxy),
        fee: price.fee.0.to_string(),
        fee_expires_at: price.fee_expires_at.map(seconds),
    }
}

fn api_funding_request(request: &FundingRequest) -> ApiFundingRequest {
    ApiFundingRequest {
        amount: request.amount.0.to_string(),
        railgun_proxy: hex0x(&request.railgun_proxy),
        token: hex0x(&request.token),
        calls_to: request.calls.iter().map(|call| hex0x(&call.to)).collect(),
        calls_data: request.calls.iter().map(|call| hex0x(&call.data)).collect(),
        relay_adapt: hex0x(&request.relay_adapt),
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

/// A key-using conversion call: registers `op_id` when given, checks the
/// seed against the account, takes the account's driver lock (`Busy` if
/// taken), and runs `step` over the account's paths and endpoints.
fn drive<T>(
    db_path: &str,
    network: &str,
    account_uuid: &str,
    store_dir: &str,
    secret: &[u8],
    lightwalletd_url: &str,
    eth_rpc_url: &str,
    op_id: Option<u32>,
    step: impl AsyncFnOnce(&SwapCall<'_>, Option<&OpHandle>) -> Result<T, PrivateUsdError>,
) -> Result<T, ApiPrivateUsdError> {
    let op = op_id.map(OpHandle::begin).transpose()?;
    let network = parse_network_and_migrate(db_path, network)?;
    let keys = SwapKeyContext::open(db_path, network, account_uuid, secret)?;
    let _driver = engine::lock_account(account_uuid)?;
    if op.as_ref().is_some_and(OpHandle::cancelled) {
        return Err(engine::cancelled().into());
    }
    let call = SwapCall {
        main_db: db_path,
        network,
        account: account_uuid,
        store_dir: Path::new(store_dir),
        lightwalletd_url,
        eth_rpc_url,
        keys: &keys,
    };
    block_on(step(&call, op.as_ref()))
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
        deposit_fee_zat: offer.deposit_fee_zatoshi,
        max_total_zat: offer.max_total_zatoshi(),
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
            ForwardWait::Unwinding => ApiForwardWait::Unwinding,
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
    let phase = match record.phase() {
        ForwardPhase::Opening => ApiForwardPhase::Opening,
        ForwardPhase::Depositing => ApiForwardPhase::Depositing,
        ForwardPhase::Confirming => ApiForwardPhase::Confirming,
        ForwardPhase::Claiming => ApiForwardPhase::Claiming,
        ForwardPhase::Refunding => ApiForwardPhase::Refunding,
        ForwardPhase::Paid => ApiForwardPhase::Paid,
        ForwardPhase::Refunded => ApiForwardPhase::Refunded,
        ForwardPhase::NothingSent => ApiForwardPhase::NothingSent,
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
        late_claim_at: late_claim_at(record),
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
        claim_held: record.claim_hold == Some(ClaimHold::Held),
        outcome,
        refund_cause,
        nothing_sent_cause,
        ended_at: record.finished_at.map(seconds),
    }
}

/// When a forward swap the maker never refunded is claimed after all, `t1`
/// and the contract's late window; `None` before `t1` is known.
fn late_claim_at(record: &ForwardRecord) -> Option<i64> {
    let swaps = deployment::for_chain_id(record.quote.chain_id)?.swaps?;
    Some(seconds(record.t1?.saturating_add(swaps.late_window)))
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
    let txid = joint_ops::internal_txid(&deposit.tx_id).ok()?;
    let expiry = u32::try_from(deposit.expiry_height).unwrap_or(u32::MAX);
    match joint_ops::swap_tx_status(db_path, network, &txid, expiry).ok()? {
        SwapTxStatus::Mined { confirmations, .. } => Some(confirmations),
        _ => Some(0),
    }
}

/// A record's transaction id in the wallet DB's byte order, as history rows
/// carry it.
fn internal_hex(tx_id: &ZcashTxId) -> Option<String> {
    joint_ops::internal_txid(tx_id)
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
