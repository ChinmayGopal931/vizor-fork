//! Private USD (shielded ZEC ↔ Railgun USDC): the thin FRB surface.
//! Logic lives in `crate::wallet::private_usd`; these wrappers parse
//! arguments, guard panics and map errors to stable codes. Dart never branches
//! on an error's message.
//!
//! Key-using calls take the account's stored secret as `mnemonic_bytes`,
//! zeroized on return, and derive keys only after checking the seed against
//! the account. Never log their arguments or results.

use std::panic;

use flutter_rust_bridge::frb;
use zeroize::Zeroizing;

use crate::wallet::keys;
use crate::wallet::network::WalletNetwork;
use crate::wallet::private_usd::{
    deployment::{self, hex_address},
    keys::{account_derivation, SwapKeyContext},
    railgun_keys, ErrorCode, PrivateUsdError, PrivateUsdNetwork,
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
        use ApiPrivateUsdErrorCode as Api;
        let code = match error.code {
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
            // zapp holds a wrong deployment as the relayer being unreachable.
            ErrorCode::WrongDeployment => Api::RelayerUnreachable,
            ErrorCode::ChainUnreadable => Api::EthereumUnreachable,
            ErrorCode::IndicesInUse => Api::Other,
            ErrorCode::AmountUnquotable => Api::AmountRefused,
        };
        Self {
            code,
            message: error.message,
        }
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
