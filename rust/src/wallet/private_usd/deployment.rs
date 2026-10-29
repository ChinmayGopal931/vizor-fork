//! The pinned swap deployments and the driver's constants. A service that
//! disagrees with a pin is refused, never followed.

use std::time::Duration;

use super::{fail, ErrorCode, PrivateUsdError, PrivateUsdNetwork, Result};

/// The highest relayer fee any signature pays: 2 USDC in 6-decimal base
/// units. It caps the forward payout, the refund payout, the reverse funding
/// fee, the rescue fee and Railgun send fees.
pub(crate) const MAX_RELAYER_FEE: u128 = 2_000_000;
/// The swap token's decimals on both networks.
pub(crate) const TOKEN_DECIMALS: u32 = 6;
/// How long a signed `ready` or rescue holds.
pub(crate) const SIGNATURE_TTL_SECONDS: u64 = 120;
/// A claim is revealed only with more than this left in its window (the
/// claim margin): one landing after the window closes reverts with `z`
/// public.
pub(crate) const REVEAL_MARGIN_SECONDS: u64 = 300;
/// Before `t0` a claim goes out on a ready only once it is this many blocks
/// deep: one a reorg dropped would leave the claim reverted, `z` public and
/// the swap the maker's to cancel.
pub(crate) const READY_DEPTH_BLOCKS: u64 = 2;
/// A claim handed to the relayer is left to it for this long after its
/// window opens; then the app posts it itself. Before `t0` the window opens
/// at the ready's depth, so there the wait counts Ethereum's 12 s slots.
pub(crate) const RELAYER_CLAIM_WAIT_SECONDS: u64 = 60;
pub(crate) const RELAYER_CLAIM_WAIT_BLOCKS: u64 = 5;
/// The latest `t1` a forward swap may have after its `t0`: until the maker
/// refunds, the deposit waits on it.
pub(crate) const MAX_T0_TO_T1_SECONDS: u64 = 2 * 60 * 60;
/// An accept is not sent this close to the quote's expiry.
pub(crate) const ACCEPT_MARGIN_SECONDS: u64 = 15;
/// Railgun's shield fee, in basis points.
pub(crate) const RAILGUN_FEE_BPS: u128 = 25;
/// Basis points in one.
pub(crate) const BPS_MAX: u128 = 10_000;
/// Reads (`/v1/info`, `/v1/terms`, swap status) and quotes.
pub(crate) const QUICK_TIMEOUT: Duration = Duration::from_secs(20);
/// Accepts and relayer posts: they may be sending a transaction.
pub(crate) const CLIENT_TIMEOUT: Duration = Duration::from_secs(180);
/// The header every relayer request for a swap carries its ticket in.
pub(crate) const TICKET_HEADER: &str = "ZecSwap-Ticket";
/// The soonest `t0` a forward swap may have by default, and the latest.
pub(crate) const DEFAULT_MIN_SECONDS_TO_T0: u64 = 25 * 60;
pub(crate) const MAX_SECONDS_TO_T0: u64 = 2 * 60 * 60;
/// The longest a reverse escrow may run from funding to refund.
pub(crate) const MAX_READY_WAIT_SECONDS: u64 = 24 * 60 * 60;
/// Maker and relayer answers are small; `eth_getLogs` pages are larger.
pub(crate) const MAX_SERVICE_BODY: usize = 1 << 20;
pub(crate) const MAX_LOGS_BODY: usize = 8 << 20;

/// What the Railgun page may reach besides its own assets, on both networks.
/// Kotlin's and Swift's `RailgunEndpoints.hosts` and the bundle's CSP list the
/// same hosts, and an RPC URL, the build's keyed one or the user's own, must
/// use one of this network's among them (`Deployment::rpc_hosts`). A `*.`
/// entry stands for any subdomain, one label or more, never the domain itself
/// (`host_allowed`): QuickNode names each endpoint, Chainstack each dedicated
/// node.
pub(crate) const RAILGUN_PAGE_HOSTS: [&str; 38] = [
    // Ethereum RPC: publicnode (the keyless default), Alchemy, Infura,
    // QuickNode, Chainstack, Ankr, dRPC, BlockPI, Tenderly, NodeReal,
    // GetBlock, OnFinality, Pocket Network, MEV Blocker, Flashbots Protect,
    // 0xRPC and Stakely. Each keyless one answered `eth_getLogs` over the
    // engine's 5,000-block window on 2026-10-29; a keyed one's plans vary, so
    // Settings asks the same window before it saves a URL.
    "ethereum-rpc.publicnode.com",
    "ethereum-sepolia-rpc.publicnode.com",
    "eth-mainnet.g.alchemy.com",
    "eth-sepolia.g.alchemy.com",
    "mainnet.infura.io",
    "sepolia.infura.io",
    "*.quiknode.pro",
    "ethereum-mainnet.core.chainstack.com",
    "ethereum-sepolia.core.chainstack.com",
    "*.p2pify.com",
    "rpc.ankr.com",
    "lb.drpc.live",
    "lb.drpc.org",
    "eth.drpc.org",
    "sepolia.drpc.org",
    "ethereum.blockpi.network",
    "ethereum-sepolia.blockpi.network",
    "ethereum.public.blockpi.network",
    "mainnet.gateway.tenderly.co",
    "sepolia.gateway.tenderly.co",
    "gateway.tenderly.co",
    "eth-mainnet.nodereal.io",
    "eth-sepolia.nodereal.io",
    "go.getblock.io",
    "go.getblock.us",
    "go.getblock.asia",
    "eth.api.onfinality.io",
    "eth-sepolia.api.onfinality.io",
    "eth.api.pocket.network",
    "rpc.mevblocker.io",
    "rpc.flashbots.net",
    "0xrpc.io",
    "ethereum-json-rpc.stakely.io",
    // The screening node and the SDK's own quick sync.
    "ppoi.fdi.network",
    "rail-squid.squids.live",
    // On Sepolia, our copy of its transaction list with the hash chain repaired.
    "railgun-sepolia-list.pepeman931.workers.dev",
    // The proving artifacts: the SDK's own gateway, then our mirror when the
    // gateway fails.
    "ipfs-lb.com",
    "railgun-artifacts.pepeman931.workers.dev",
];

pub(crate) const POI_NODE_URL: &str = "https://ppoi.fdi.network/";

/// Whether `host` is one of `allowed`, where a `*.` entry stands for any
/// subdomain: one label or more, never the domain itself. Case does not
/// count; a host that is not ASCII (none is on the wire) matches nothing.
pub(crate) fn host_allowed(allowed: &[&str], host: &str) -> bool {
    allowed.iter().any(|pattern| host_matches(pattern, host))
}

fn host_matches(pattern: &str, host: &str) -> bool {
    if !host.is_ascii() {
        return false;
    }
    match pattern.strip_prefix("*.") {
        Some(domain) => {
            let Some(at) = host.len().checked_sub(domain.len() + 1) else {
                return false;
            };
            let (prefix, suffix) = host.split_at(at);
            !prefix.is_empty()
                && suffix.as_bytes()[0] == b'.'
                && suffix[1..].eq_ignore_ascii_case(domain)
        }
        None => host.eq_ignore_ascii_case(pattern),
    }
}

/// One network's pins. Addresses are bytes; the hex in this file keeps the
/// EIP-55 case the sources use, and the wire always gets lowercase.
#[derive(Debug)]
pub(crate) struct Deployment {
    pub network: PrivateUsdNetwork,
    pub maker_url: &'static str,
    pub relayer_url: &'static str,
    pub issuer_url: &'static str,
    pub issuer_name: &'static str,
    /// RFC 9578 token key, base64url SPKI (RSA-PSS SHA-384).
    pub issuer_token_key: &'static str,
    /// The key the maker hands tokens back under, base64url SPKI.
    pub maker_token_return_key: &'static str,
    pub chain_id: u64,
    /// The windows contract swaps settle on; `None` where bridging is off,
    /// and quotes and swaps are refused.
    pub swaps: Option<SwapContract>,
    /// Lock contracts swaps of this network settled on before, by rules this
    /// build does not follow. An index used there is never used again: its
    /// share may be public.
    pub retired_contracts: &'static [[u8; 20]],
    pub token: [u8; 20],
    /// The dollar tokens the private USD balance counts, the swap token
    /// first (Sepolia adds Circle's test USDC, which Railgun accepts). Their
    /// decimals are [`TOKEN_DECIMALS`].
    pub usd_tokens: &'static [UsdToken],
    /// The only maker whose quotes are taken.
    pub maker: [u8; 20],
    /// The only relayer payouts are signed for.
    pub relayer: [u8; 20],
    /// The relayer's own `0zk` address, which a private send's fee note pays.
    pub relayer_railgun_address: &'static str,
    pub railgun_proxy: [u8; 20],
    pub relay_adapt: [u8; 20],
    /// Confirmations the maker waits for before it counts a deposit.
    pub zcash_confirmations: u32,
    /// Ethereum confirmations, its own block included, for opens, escrows
    /// and payouts.
    pub escrow_confirmations: u32,
    /// The soonest `t0` a forward deposit may be paid for.
    pub min_seconds_to_t0: u64,
    /// The screening time shown to the user.
    pub screening_seconds: u32,
    pub explorer_tx_prefix: &'static str,
    pub railscan_tx_prefix: &'static str,
    /// publicnode, which needs no key: the RPC of a build without a keyed
    /// URL.
    pub keyless_rpc_url: &'static str,
    /// The RPC providers the engine may be pointed at, by the build's keyed
    /// URL or the user's own: this network's among `RAILGUN_PAGE_HOSTS`.
    pub rpc_hosts: &'static [&'static str],
    pub poi_node_url: &'static str,
    /// Where public USDC is shielded into the private balance; `None` where no
    /// Deposits contract is pinned, and deposits are hidden.
    pub deposits: Option<DepositsPin>,
}

/// A windows contract as a deployment pins it. At every moment one side at
/// most may reveal: the maker may cancel a forward swap until `t0` unless it
/// made it ready, the user may claim once it is ready or from `t0` until
/// `t1`, the maker may refund from `t1` for `late_window`, and the user may
/// claim again after that; a reverse escrow is the maker's to claim once
/// ready until `t1`, and the user's to refund while not ready and from `t1`.
/// The chain must answer both windows as pinned before any swap read is
/// trusted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SwapContract {
    pub address: [u8; 20],
    /// `MIN_WINDOW()`: the least an open leaves before `t0`, and from `t0`
    /// to `t1`.
    pub min_window: u64,
    /// `LATE_WINDOW()`: how long from `t1` only the maker may refund a
    /// forward swap.
    pub late_window: u64,
}

/// What a wallet pins of a Deposits deployment, never what a relayer says:
/// the relayer's terms must name the same contract, account and token on the
/// pinned chain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct DepositsPin {
    /// The Deposits contract: every authorization's `to`.
    pub contract: [u8; 20],
    /// The account the relayer sends deposits from. A deposit's nonce
    /// commits to it, so a tampered answer cannot take even the fee. It is
    /// not the top-level `relayer`, which payouts are signed for.
    pub relayer: [u8; 20],
    /// The token deposits are in: the deployment's swap token.
    pub token: [u8; 20],
    /// Multicall3, which reads twenty deposit addresses in one call.
    pub multicall: [u8; 20],
}

/// A token the private USD balance counts as dollars.
#[derive(Debug, Clone, Copy)]
pub(crate) struct UsdToken {
    pub address: [u8; 20],
    /// `USDC`, or `tUSD` for the testnet maker's token (which has no
    /// `symbol()` of its own).
    pub symbol: &'static str,
}

const MAINNET_USDC: [u8; 20] = address("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
/// The testnet maker's swap token, standing in for USDC: `ZecSwap Test USD`,
/// version `2`, 6 decimals, with EIP-3009 for deposits.
const SEPOLIA_TEST_USD: [u8; 20] = address("0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c");
/// Multicall3, at its canonical address on every chain.
pub(crate) const MULTICALL3: [u8; 20] = address("0xcA11bde05977b3631167028862bE2a173976CA11");
/// Circle's test USDC, the one Railgun accepts on Sepolia.
const SEPOLIA_USDC: [u8; 20] = address("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238");

const MAINNET: Deployment = Deployment {
    network: PrivateUsdNetwork::Mainnet,
    maker_url: "https://zecswap-mainnet.pepeman931.workers.dev/maker",
    relayer_url: "https://zecswap-mainnet.pepeman931.workers.dev/relayer",
    issuer_url: "https://zecswap-mainnet.pepeman931.workers.dev/issuer",
    issuer_name: "zecswap-mainnet-issuer",
    issuer_token_key: "MIIBUjA9BgkqhkiG9w0BAQowMKANMAsGCWCGSAFlAwQCAqEaMBgGCSqGSIb3DQEBCDALBglghkgBZQMEAgKiAwIBMAOCAQ8AMIIBCgKCAQEAuA8Rq3Fo644QG48Kmxsyg1UFAKd-kfsS9t7BgPVwJqXHIEmlH4gS1UaxDBdu7awf0n9lv7yYozNTE5PysBh01LBhGbcIMWyTSNXkF2l1Mi0AOVVhVJZr-KTyr0u6ZFI2EGRVxT1BF2B4QgzQgJ64xqj-tzX_ctpwYQiE1Gf74zG4Yd0mdEbDjTYhgzoaR0lV5uHHSnVN2fmnlskAkZl6mfrJKfcfivp-UQ8qgBEs-7ke67lMhMyC3BxoDG7qoY0B4eIQRQ_-fu3eYT1RifuO5LgvMYkzRe58X63emOvYls19En0Vbkeq2Y73kMRA2AOYMp5gD3DyF4t5LM535p4-GQIDAQAB",
    maker_token_return_key: "MIIBUjA9BgkqhkiG9w0BAQowMKANMAsGCWCGSAFlAwQCAqEaMBgGCSqGSIb3DQEBCDALBglghkgBZQMEAgKiAwIBMAOCAQ8AMIIBCgKCAQEArte6ewR0iOfbhxrByZ1vj_MMkKiQLQ-2R3OdCyHeKr_G4FrsCHvLhJ0uuu5r-papDogiMb_btM5-nPaOWzC1olxbmEUypJWgz-yCXD3K4wp_jgeqlP7EnlJE3IT5iTwv_S1hK5yV4Fka5mRoyhvZlhvDW3eCWoMix15Fp-TD3AGm7GttqzW4QyLXV_mQcnqlWPwuCacmTYch93eMZ7CaTHHRMmsfqR7_kZdskZh_JM55_lw_puDvvdRtu4vYItvo5wMI5mkwmSEwi6UahZDx_OI8IAF2JpeqRIKwbhT6FVGwahDeu6PRTww71C0i13EOwC3GQ85pxDRIAzF01W14wQIDAQAB",
    chain_id: 1,
    // Deployed at block 26250774, in place of the lock contract.
    swaps: Some(SwapContract {
        address: address("0xeB3A00bcB6c9fF626fE57a5dBbDCf01730e7898f"),
        min_window: 60 * 60,
        late_window: 24 * 60 * 60,
    }),
    retired_contracts: &[address("0x4708D7d36992b7e33Ad97a1ab0A31c3ac6C4fe6D")],
    token: MAINNET_USDC,
    usd_tokens: &[UsdToken {
        address: MAINNET_USDC,
        symbol: "USDC",
    }],
    maker: address("0x4370eEaa6bEcf1dAeF21Deeb0379Eb7f6CaEf7eF"),
    relayer: address("0xcBcb5f57C79C88a0E4BB450289dE2088958A017F"),
    relayer_railgun_address: "0zk1qy860uut20m8gd6fnhzvr0zqeyhs0ya5247x7h2eyedxsazx43w5nrv7j6fe3z53l78hn78kmslky2206lm75mclrv7dawd756m2suy7l4zud2m4yhg6kcsn7ed",
    railgun_proxy: address("0xFA7093CDD9EE6932B4eb2c9e1cde7CE00B1FA4b9"),
    relay_adapt: address("0xAc9f360Ae85469B27aEDdEaFC579Ef2d052aD405"),
    zcash_confirmations: 2,
    escrow_confirmations: 3,
    min_seconds_to_t0: 15 * 60,
    screening_seconds: 60 * 60,
    explorer_tx_prefix: "https://etherscan.io/tx/",
    railscan_tx_prefix: "https://railscan.io/ethereum/tx/",
    keyless_rpc_url: "https://ethereum-rpc.publicnode.com",
    rpc_hosts: &[
        "ethereum-rpc.publicnode.com",
        "eth-mainnet.g.alchemy.com",
        "mainnet.infura.io",
        "*.quiknode.pro",
        "ethereum-mainnet.core.chainstack.com",
        "*.p2pify.com",
        "rpc.ankr.com",
        "lb.drpc.live",
        "lb.drpc.org",
        "eth.drpc.org",
        "ethereum.blockpi.network",
        "ethereum.public.blockpi.network",
        "mainnet.gateway.tenderly.co",
        "gateway.tenderly.co",
        "eth-mainnet.nodereal.io",
        "go.getblock.io",
        "go.getblock.us",
        "go.getblock.asia",
        "eth.api.onfinality.io",
        "eth.api.pocket.network",
        "rpc.mevblocker.io",
        "rpc.flashbots.net",
        "0xrpc.io",
        "ethereum-json-rpc.stakely.io",
    ],
    poi_node_url: POI_NODE_URL,
    deposits: Some(DepositsPin {
        contract: address("0xebc7508e20bd4467491ee7e7589d5c7d4c5e8cb6"),
        relayer: address("0x6ae40b34c32d3feaa0eef53d7e4724160b7a2135"),
        token: MAINNET_USDC,
        multicall: MULTICALL3,
    }),
};

const TESTNET: Deployment = Deployment {
    network: PrivateUsdNetwork::Testnet,
    maker_url: "https://zecswap-testnet.pepeman931.workers.dev/maker",
    relayer_url: "https://zecswap-testnet.pepeman931.workers.dev/relayer",
    issuer_url: "https://zecswap-testnet.pepeman931.workers.dev/issuer",
    issuer_name: "zecswap-testnet-issuer",
    issuer_token_key: "MIIBUjA9BgkqhkiG9w0BAQowMKANMAsGCWCGSAFlAwQCAqEaMBgGCSqGSIb3DQEBCDALBglghkgBZQMEAgKiAwIBMAOCAQ8AMIIBCgKCAQEAqAp6ClskrSdfUjiFvS2H9eTxKKNxrtVPM-n0n8WCgCj508sXiyQj21W9Dpjki-JYLbYS7xkHaTCuplU7-Kg6EFK_xwFB-BmQZcW9qk1GTYcZAqJ5YmfttMFHMDsdroUq5v6RnQxLRINIh5UIiFgn_516Wp2CcizaU-lwuwP4f8hp-0cLvynQ119pUTIfwgaYhrRaxngHFu0JnQF6l4AK4rhtIt6g7AG_bSSV06cYowKuOVEncE45CaUDOUJbP18MfRSP42HPnWZ0-h6n3_uBYvxHYsKp7KQ5_Hr-QpOafUoXhFANv4mfpk3MUQxo2m7vZZAMaFa9ELsIIiaLkACGhQIDAQAB",
    maker_token_return_key: "MIIBUjA9BgkqhkiG9w0BAQowMKANMAsGCWCGSAFlAwQCAqEaMBgGCSqGSIb3DQEBCDALBglghkgBZQMEAgKiAwIBMAOCAQ8AMIIBCgKCAQEA5boFzxSM2UDd-NfwWUnT_lVo23Td6wOH5twYjLo2wLDEWmGKSNBgdZy3t3JC2JkzD8j9rVRdehpll_i3GRKmUq0wr6xkHHuHxswr3TehMUqUrztg-nxDS4U2f0V0yYno3I5YPo2SByOz_-jHNWM6Mlx-TZsWzALQTb3NmRXdynqecz3-8hqd_OPhUJtH7M3pK9ikkUbSzV1ofXkyM6FnaNAGkHZ1kAMEF2pGe69tOJJqGq6wpTuZMtzaaxu9t1C4xoR7R7pbdkjPM_Wxd15LoXa1N26V-PToIeD06VmwX51VjrO_2VHWFat4Rtu7eLPeiEX-5kKsyvCY7EhpkNK1DQIDAQAB",
    chain_id: 11_155_111,
    // Deployed at block 11958709, in place of the lock contract.
    swaps: Some(SwapContract {
        address: address("0x459b0a69e0f736666b66a3ffe0fc17c11f05980d"),
        min_window: 30 * 60,
        late_window: 60 * 60,
    }),
    retired_contracts: &[address("0xD75Efc6a157CC0A95f66962DA86DDf35d9F2617c")],
    token: SEPOLIA_TEST_USD,
    usd_tokens: &[
        UsdToken {
            address: SEPOLIA_TEST_USD,
            symbol: "tUSD",
        },
        UsdToken {
            address: SEPOLIA_USDC,
            symbol: "USDC",
        },
    ],
    maker: address("0x2bac02b5032e9092493814c705f156b49e288922"),
    relayer: address("0xd9633572041886fa7584a2e12f36c8c7f1126412"),
    relayer_railgun_address: "0zk1qy25r4x4qjhtlfe0k9z22jy9psfm83j4k4fgvqs3pmv4he4ytefm8rv7j6fe3z53lltumh8amd66g2axaej92dmjk6mvnuveqtmmwccdm593pft827p4xpwljug",
    railgun_proxy: address("0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea"),
    relay_adapt: address("0x7e3d929EbD5bDC84d02Bd3205c777578f33A214D"),
    zcash_confirmations: 2,
    escrow_confirmations: 2,
    min_seconds_to_t0: 9 * 60,
    screening_seconds: 60,
    explorer_tx_prefix: "https://sepolia.etherscan.io/tx/",
    railscan_tx_prefix: "https://railscan.io/sepolia/tx/",
    keyless_rpc_url: "https://ethereum-sepolia-rpc.publicnode.com",
    rpc_hosts: &[
        "ethereum-sepolia-rpc.publicnode.com",
        "eth-sepolia.g.alchemy.com",
        "sepolia.infura.io",
        "*.quiknode.pro",
        "ethereum-sepolia.core.chainstack.com",
        "*.p2pify.com",
        "rpc.ankr.com",
        "lb.drpc.live",
        "lb.drpc.org",
        "sepolia.drpc.org",
        "ethereum-sepolia.blockpi.network",
        "sepolia.gateway.tenderly.co",
        "gateway.tenderly.co",
        "eth-sepolia.nodereal.io",
        "go.getblock.io",
        "go.getblock.us",
        "go.getblock.asia",
        "eth-sepolia.api.onfinality.io",
        "0xrpc.io",
    ],
    poi_node_url: POI_NODE_URL,
    deposits: Some(DepositsPin {
        contract: address("0x58324e9a866c9690aca08169d3c67630e84c9019"),
        relayer: address("0xedc4c88a3f6ae8130a2c18babbabd8100cc1a446"),
        token: SEPOLIA_TEST_USD,
        multicall: MULTICALL3,
    }),
};

pub(crate) fn deployment(network: PrivateUsdNetwork) -> &'static Deployment {
    match network {
        PrivateUsdNetwork::Mainnet => &MAINNET,
        PrivateUsdNetwork::Testnet => &TESTNET,
    }
}

/// The deployment on Ethereum chain `chain_id`, if one is pinned there.
pub(crate) fn for_chain_id(chain_id: u64) -> Option<&'static Deployment> {
    [&MAINNET, &TESTNET]
        .into_iter()
        .find(|deployment| deployment.chain_id == chain_id)
}

impl Deployment {
    /// Where the engine reads the chain: the keyed URL when the build has one,
    /// else publicnode. A keyed URL, the build's or the user's own, is taken
    /// only as https, on the default port and without credentials, on one of
    /// this network's `rpc_hosts` (`host_allowed`); the Dart side keeps only
    /// such a URL, and this holds the engine to it whatever reaches it. Any
    /// other is `WrongDeployment`: nothing falls back from a keyed URL, and it
    /// is never stored or logged.
    pub(crate) fn rpc_url<'a>(&'a self, keyed: &'a str) -> Result<&'a str> {
        let keyed = keyed.trim();
        if keyed.is_empty() {
            return Ok(self.keyless_rpc_url);
        }
        let on_host = url::Url::parse(keyed).is_ok_and(|url| {
            url.scheme() == "https"
                && url.port().is_none_or(|port| port == 443)
                && url.username().is_empty()
                && url.password().is_none()
                && url
                    .host_str()
                    .is_some_and(|host| host_allowed(self.rpc_hosts, host))
        });
        if !on_host {
            return fail(
                ErrorCode::WrongDeployment,
                "the Ethereum RPC URL is not on one of this network's providers",
            );
        }
        Ok(keyed)
    }

    /// The windows contract, or `Unavailable` where bridging is off.
    pub(crate) fn swap_contract(&self) -> Result<&SwapContract> {
        self.swaps.as_ref().ok_or_else(|| {
            PrivateUsdError::new(ErrorCode::Unavailable, "bridging is off on this network")
        })
    }

    /// Whether `contract` is this deployment's windows contract.
    pub(crate) fn settles_on(&self, contract: &[u8; 20]) -> bool {
        self.swaps.is_some_and(|swaps| swaps.address == *contract)
    }

    pub(crate) fn domain(&self) -> Result<zecswap_core::Domain> {
        Ok(zecswap_core::Domain {
            chain_id: self.chain_id,
            contract: self.swap_contract()?.address,
        })
    }
}

/// Refuses a relayer fee above [`MAX_RELAYER_FEE`]: no signature pays one.
pub(crate) fn require_within_fee_cap(fee: u128) -> Result<()> {
    if fee > MAX_RELAYER_FEE {
        return fail(
            ErrorCode::RelayerFee,
            "the relayer's fee is above the 2 USDC cap",
        );
    }
    Ok(())
}

/// What Railgun shields of `amount`: its shield fee comes off, rounded down.
pub(crate) fn after_railgun_fee(amount: u128) -> u128 {
    amount - amount.saturating_mul(RAILGUN_FEE_BPS) / BPS_MAX
}

/// A 20-byte address from `0x` hex of either case, at compile time.
const fn address(hex: &str) -> [u8; 20] {
    let bytes = hex.as_bytes();
    assert!(bytes.len() == 42 && bytes[0] == b'0' && bytes[1] == b'x');
    let mut out = [0u8; 20];
    let mut i = 0;
    while i < 20 {
        out[i] = (nibble(bytes[2 + 2 * i]) << 4) | nibble(bytes[3 + 2 * i]);
        i += 1;
    }
    out
}

const fn nibble(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        b'A'..=b'F' => c - b'A' + 10,
        _ => panic!("not hex"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The engine reads the chain only at this network's RPC providers, which
    /// the page may reach: https, the default port, no credentials. An empty
    /// URL is publicnode; another network's provider, a page host that is no
    /// RPC, or any other host is refused, never replaced.
    #[test]
    fn an_rpc_url_is_taken_only_on_the_networks_providers() {
        let refused = |pins: &Deployment, url: &str| pins.rpc_url(url).unwrap_err().code;
        for pins in [&MAINNET, &TESTNET] {
            assert_eq!(pins.rpc_url("").unwrap(), pins.keyless_rpc_url);
            assert_eq!(pins.rpc_url(" ").unwrap(), pins.keyless_rpc_url);
            let keyless = url::Url::parse(pins.keyless_rpc_url).unwrap();
            assert!(pins.rpc_hosts.contains(&keyless.host_str().unwrap()));
            for host in pins.rpc_hosts {
                assert!(RAILGUN_PAGE_HOSTS.contains(host), "{host}");
                // A `*.` entry: an endpoint of the user's own name.
                let host = host.replace("*.", "my-endpoint.");
                let keyed = format!("https://{host}/v2/key");
                assert_eq!(pins.rpc_url(&keyed).unwrap(), keyed);
                assert_eq!(pins.rpc_url(&format!(" {keyed} ")).unwrap(), keyed);
                let on_443 = format!("https://{host}:443/v2/key");
                assert_eq!(pins.rpc_url(&on_443).unwrap(), on_443);
                for off in [
                    format!("http://{host}/v2/key"),
                    format!("https://{host}:8545/v2/key"),
                    format!("https://user:key@{host}/"),
                    format!("https://{host}.evil.example/v2/key"),
                ] {
                    assert_eq!(refused(pins, &off), ErrorCode::WrongDeployment, "{off}");
                }
            }
        }
        for off in [
            "https://eth-sepolia.g.alchemy.com/v2/key",
            "https://ppoi.fdi.network/",
            "https://rpc.invalid/",
            "not a url",
        ] {
            assert_eq!(refused(&MAINNET, off), ErrorCode::WrongDeployment, "{off}");
        }
        assert_eq!(
            refused(&TESTNET, "https://eth-mainnet.g.alchemy.com/v2/key"),
            ErrorCode::WrongDeployment
        );
    }

    /// A `*.` entry takes any subdomain, one label or more, in any case:
    /// never the domain itself, a lookalike, or a host that is not ASCII.
    #[test]
    fn a_wildcard_host_takes_subdomains_only() {
        let allowed = ["*.quiknode.pro", "rpc.ankr.com"];
        for host in [
            "a.quiknode.pro",
            "my-endpoint.ethereum-sepolia.quiknode.pro",
            "A.QuikNode.PRO",
            "rpc.ankr.com",
            "RPC.ANKR.COM",
        ] {
            assert!(host_allowed(&allowed, host), "{host}");
        }
        for host in [
            "quiknode.pro",
            ".quiknode.pro",
            "aquiknode.pro",
            "a.quiknode.pro.evil.example",
            "quiknode.pro.evil.example",
            "a.quiknode.pr",
            "ankr.com",
            "a.rpc.ankr.com",
            "ä.quiknode.pro",
            "",
        ] {
            assert!(!host_allowed(&allowed, host), "{host}");
        }
        for pins in [&MAINNET, &TESTNET] {
            let keyed = "https://my-endpoint.quiknode.pro/key";
            assert_eq!(pins.rpc_url(keyed).unwrap(), keyed);
            assert_eq!(
                pins.rpc_url("https://quiknode.pro/key").unwrap_err().code,
                ErrorCode::WrongDeployment
            );
        }
    }
}
