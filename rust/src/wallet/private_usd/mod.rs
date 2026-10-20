//! Private USD: shielded ZEC to and from Railgun USDC by atomic swap
//! (`docs/private-usd-android-plan.md`).
//!
//! Rust owns every key, every swap rule and all swap networking. Keys are
//! re-derived from the seed for each use and never stored; swap records live
//! in `swaps.db` (`store`). Engine HTTP goes through `crate::wallet::routed_http`
//! only, so it follows the route policy and fails closed on Tor.
//!
//! Never log the mnemonic, the seed, a secret share, a relayer ticket, token
//! state or a keyed RPC URL.

// M1 and M2 build blocks the engine drives; the forward (M5), reverse (M6) and
// send (M7) halves use their share, and a few wait for M4's tokens. Remove
// this once the engine uses them all.
#![allow(dead_code)]

use std::fmt;
use std::sync::Mutex;

use zecswap_core::NetworkType;

use crate::wallet::network::WalletNetwork;

pub(crate) mod abi;
pub(crate) mod deployment;
pub(crate) mod deposits;
pub(crate) mod engine;
pub(crate) mod evm_rpc;
pub(crate) mod forward;
pub(crate) mod funding_calls;
pub(crate) mod indices;
pub(crate) mod joint;
pub(crate) mod keys;
pub(crate) mod maker_client;
pub(crate) mod models;
pub(crate) mod railgun_keys;
pub(crate) mod relayer_client;
pub(crate) mod reverse;
pub(crate) mod sends;
pub(crate) mod store;
pub(crate) mod terms;
pub(crate) mod transport;

#[cfg(test)]
mod tests;

/// One `swaps.db` or `joint.db` writer at a time. Never held across network
/// I/O.
pub(crate) static OPERATIONS: Mutex<()> = Mutex::new(());

/// The networks with a swap deployment. Regtest has none (D2), so the feature
/// is hidden there.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum PrivateUsdNetwork {
    Mainnet,
    Testnet,
}

impl PrivateUsdNetwork {
    pub(crate) fn from_wallet(network: WalletNetwork) -> Option<Self> {
        match network {
            WalletNetwork::Main => Some(Self::Mainnet),
            WalletNetwork::Test => Some(Self::Testnet),
            WalletNetwork::Regtest => None,
        }
    }

    /// The network the swap keys derive for: their coin type follows it.
    pub(crate) fn zcash(self) -> NetworkType {
        match self {
            Self::Mainnet => NetworkType::Main,
            Self::Testnet => NetworkType::Test,
        }
    }

    /// The deployment's name in records and file names.
    pub(crate) fn record_name(self) -> &'static str {
        match self {
            Self::Mainnet => "mainnet",
            Self::Testnet => "testnet",
        }
    }

    /// The Railgun page's `start.network`.
    pub(crate) fn railgun_name(self) -> &'static str {
        match self {
            Self::Mainnet => "mainnet",
            Self::Testnet => "sepolia",
        }
    }
}

/// Why a step failed. The first group maps one to one onto the FRB codes
/// (`api::private_usd::ApiPrivateUsdErrorCode`); the rest are internal reasons
/// that `api()` folds into them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ErrorCode {
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
    /// The call was cancelled (lock, background, drain): never a failure.
    Cancelled,
    /// A service or node serves another deployment than the pinned one.
    WrongDeployment,
    /// The Ethereum node's answer was too short or malformed to read.
    ChainUnreadable,
    /// Sixteen swap indices in a row are already in use on chain.
    IndicesInUse,
    /// More than a quote can name (`u32` token base units).
    AmountUnquotable,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct PrivateUsdError {
    pub code: ErrorCode,
    pub message: String,
}

impl PrivateUsdError {
    pub(crate) fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl fmt::Debug for PrivateUsdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)
    }
}

impl fmt::Display for PrivateUsdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

pub(crate) type Result<T> = std::result::Result<T, PrivateUsdError>;

/// `PrivateUsdError::new(code, message)` as an `Err`.
pub(crate) fn fail<T>(code: ErrorCode, message: impl Into<String>) -> Result<T> {
    Err(PrivateUsdError::new(code, message))
}
