//! The pinned swap deployments (plan reference §7.1) and the driver constants
//! (§7.2). Copied from zapp's `AtomicSwapMainnet.kt` / `AtomicSwapTestnet.kt`
//! and cross-checked with zecSwap's deployment records. A service that
//! disagrees with a pin is refused, never followed.

use std::time::Duration;

use super::PrivateUsdNetwork;

/// The highest relayer fee any signature pays: 2 USDC in 6-decimal base units
/// (D11, X6). Applies to the forward payout, the refund payout, the reverse
/// funding fee, the rescue fee and Railgun send fees. zapp has no cap.
pub(crate) const MAX_RELAYER_FEE: u128 = 2_000_000;
/// The swap token's decimals on both networks.
pub(crate) const TOKEN_DECIMALS: u32 = 6;
/// How long a signed lock or `ready` holds; below every `LOCK_DURATION`.
pub(crate) const SIGNATURE_TTL_SECONDS: u64 = 120;
/// A share is revealed only under a lock with more than this left (the claim
/// margin).
pub(crate) const REVEAL_MARGIN_SECONDS: u64 = 300;
/// An accept is not sent this close to the quote's expiry.
pub(crate) const ACCEPT_MARGIN_SECONDS: u64 = 15;
/// Railgun's shield fee, in basis points.
pub(crate) const RAILGUN_FEE_BPS: u128 = 25;
/// Reads (`/v1/info`, `/v1/terms`, swap status) and quotes.
pub(crate) const QUICK_TIMEOUT: Duration = Duration::from_secs(20);
/// Accepts and relayer posts: they may be sending a transaction.
pub(crate) const CLIENT_TIMEOUT: Duration = Duration::from_secs(180);
/// The header every relayer request for a swap carries its ticket in.
pub(crate) const TICKET_HEADER: &str = "ZecSwap-Ticket";
/// The clock skew allowed against the token issuer.
pub(crate) const ISSUER_CLOCK_SKEW_SECONDS: u64 = 600;
/// The soonest `t0` a forward swap may have by default, and the latest.
pub(crate) const DEFAULT_MIN_SECONDS_TO_T0: u64 = 25 * 60;
pub(crate) const MAX_SECONDS_TO_T0: u64 = 2 * 60 * 60;
/// The longest a reverse escrow may run from funding to refund.
pub(crate) const MAX_READY_WAIT_SECONDS: u64 = 24 * 60 * 60;
/// Maker and relayer answers are small; `eth_getLogs` pages are larger.
pub(crate) const MAX_SERVICE_BODY: usize = 1 << 20;
pub(crate) const MAX_LOGS_BODY: usize = 8 << 20;

/// What the Railgun page may reach besides its own assets, on both networks.
/// Kotlin's `RailgunEndpoints.hosts` and the bundle's CSP list the same hosts
/// (reference §6.4), and a keyed RPC URL must use one of them.
pub(crate) const RAILGUN_PAGE_HOSTS: [&str; 9] = [
    "ethereum-rpc.publicnode.com",
    "ethereum-sepolia-rpc.publicnode.com",
    "eth-mainnet.g.alchemy.com",
    "eth-sepolia.g.alchemy.com",
    "mainnet.infura.io",
    "sepolia.infura.io",
    "ppoi.fdi.network",
    "rail-squid.squids.live",
    "ipfs-lb.com",
];

pub(crate) const POI_NODE_URL: &str = "https://ppoi.fdi.network/";

/// One network's pins. Addresses are bytes; the hex in this file keeps the
/// EIP-55 case the sources use, and the wire always gets lowercase.
#[derive(Debug)]
pub(crate) struct Deployment {
    pub network: PrivateUsdNetwork,
    pub maker_url: &'static str,
    pub relayer_url: &'static str,
    pub issuer_url: &'static str,
    pub issuer_name: &'static str,
    /// RFC 9578 token key, base64url SPKI (RSA-PSS SHA-384). Parsed once the
    /// token client lands (plan §2 N1).
    pub issuer_token_key: &'static str,
    /// The key the maker hands tokens back under, base64url SPKI.
    pub maker_token_return_key: &'static str,
    pub chain_id: u64,
    pub contract: [u8; 20],
    /// The contract's deployment block, informational.
    pub contract_block: u64,
    /// `LOCK_DURATION` at deployment, informational: the driver reads it on
    /// chain.
    pub lock_duration_seconds: u64,
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
    /// Ethereum confirmations, its own block included, for escrow, locks and
    /// payouts.
    pub escrow_confirmations: u32,
    /// The soonest `t0` a forward deposit may be paid for.
    pub min_seconds_to_t0: u64,
    /// The screening time shown to the user.
    pub screening_seconds: u32,
    pub explorer_tx_prefix: &'static str,
    pub railscan_tx_prefix: &'static str,
    /// publicnode, which needs no key. A keyed URL (a build secret) is tried
    /// first and never stored.
    pub keyless_rpc_url: &'static str,
    pub poi_node_url: &'static str,
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
/// The testnet maker's swap token; it stands in for USDC.
const SEPOLIA_TEST_USD: [u8; 20] = address("0x5764D0044bef5AA839E0dDafE2073421101B9Ed8");
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
    contract: address("0x4708D7d36992b7e33Ad97a1ab0A31c3ac6C4fe6D"),
    contract_block: 26_178_667,
    lock_duration_seconds: 1800,
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
    poi_node_url: POI_NODE_URL,
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
    contract: address("0xD75Efc6a157CC0A95f66962DA86DDf35d9F2617c"),
    contract_block: 11_860_526,
    lock_duration_seconds: 600,
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
    poi_node_url: POI_NODE_URL,
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
    /// else publicnode. Never falls back from a keyed URL (zapp does not
    /// either), and never stored.
    pub(crate) fn rpc_url<'a>(&'a self, keyed: &'a str) -> &'a str {
        if keyed.trim().is_empty() {
            self.keyless_rpc_url
        } else {
            keyed
        }
    }

    pub(crate) fn domain(&self) -> zecswap_core::Domain {
        zecswap_core::Domain {
            chain_id: self.chain_id,
            contract: self.contract,
        }
    }
}

/// `0x`-prefixed lowercase hex, as the wire and records write addresses.
pub(crate) fn hex_address(address: &[u8; 20]) -> String {
    format!("0x{}", hex::encode(address))
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
