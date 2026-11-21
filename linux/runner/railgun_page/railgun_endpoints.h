#ifndef RUNNER_RAILGUN_PAGE_RAILGUN_ENDPOINTS_H_
#define RUNNER_RAILGUN_PAGE_RAILGUN_ENDPOINTS_H_

#include <string>

// What the page may reach besides its own files, on both networks. Rust's `deployment::RAILGUN_PAGE_HOSTS` (the
// bridge's allowlist), Kotlin's and Swift's `RailgunEndpoints.hosts` and the page's CSP (`index.html`) list the same
// hosts; a host missing from any of them is blocked silently. A `*.` entry stands for any subdomain, one label or more,
// never the domain itself (`railgun_page::ContentRules`). A Rust test (`railgun_bridge.rs`) reads the literals below,
// so keep them literal.
namespace railgun_page {

// Ethereum RPC (keyless publicnode, then the providers a user's own URL may name: Alchemy, Infura, QuickNode,
// Chainstack, Ankr, dRPC, BlockPI, Tenderly, NodeReal, GetBlock, OnFinality, Pocket Network and MEV Blocker), the
// screening node, the SDK's own quick sync, Anon's archive of the same history (which this host fetches for the page,
// railgun_archive.h) and, on Sepolia, our copy of its transaction list with the hash chain repaired, and where the
// proving artifacts come from: the SDK's own gateway, then our mirror when the gateway fails.
inline constexpr const char* kHosts[] = {
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
    "ppoi.fdi.network",
    "rail-squid.squids.live",
    "digest.anon.inc",
    "railgun-sepolia-list.pepeman931.workers.dev",
    "ipfs-lb.com",
    "railgun-artifacts.pepeman931.workers.dev",
};

// The page's own origin: WebKit can't intercept `https`, so the page gets an origin of its own on a custom scheme,
// registered secure and CORS-enabled, as on iOS and the Mac.
inline constexpr char kScheme[] = "veylor-railgun";
inline constexpr char kHost[] = "app";
inline constexpr char kPageUrl[] = "veylor-railgun://app/index.html";

// The page's CSP (`index.html`'s meta tag), also sent as a header, as iOS's `RailgunSchemeHandler` sends it.
std::string ContentSecurityPolicy();

// The page's allowlist as a WebKit content filter, in Safari's content-blocker JSON (iOS's `RailgunContentRules`):
// block everything, then let through the page's own scheme, `blob:`, `data:` and https to `kHosts`. WebKit has no
// per-request hook for network loads, so this stands in for Android's request filter. The bridge's allowlist stays the
// authority; this and the page's CSP are defence in depth.
std::string ContentRules();

}  // namespace railgun_page

#endif  // RUNNER_RAILGUN_PAGE_RAILGUN_ENDPOINTS_H_
