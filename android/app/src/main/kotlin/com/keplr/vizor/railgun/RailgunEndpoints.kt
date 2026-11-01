package com.keplr.vizor.railgun

/**
 * What the page may reach besides its own assets, on both networks. Rust's `deployment::RAILGUN_PAGE_HOSTS`
 * (the bridge's allowlist), Swift's `RailgunEndpoints.hosts` and the page's CSP (`index.html`) list the same
 * hosts; a host missing from any of them is blocked silently. A `*.` entry stands for any subdomain, one label or
 * more, never the domain itself ([allows]). A Rust test (`railgun_bridge.rs`) reads the literals below, so keep
 * them literal.
 */
internal object RailgunEndpoints {
    // Ethereum RPC (keyless publicnode, then the providers a user's own URL may name: Alchemy, Infura, QuickNode,
    // Chainstack, Ankr, dRPC, BlockPI, Tenderly, NodeReal, GetBlock, OnFinality, Pocket Network and MEV Blocker),
    // the screening node, the SDK's own quick sync and, on Sepolia, our copy of its transaction list with the hash
    // chain repaired, and where the proving artifacts come from: the SDK's own gateway, then our mirror when the
    // gateway fails.
    val hosts =
        setOf(
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
            "railgun-sepolia-list.pepeman931.workers.dev",
            "ipfs-lb.com",
            "railgun-artifacts.pepeman931.workers.dev",
        )

    /**
     * Whether [host] is one of [hosts], a `*.` entry taking any subdomain: one label or more of letters, digits and
     * inner hyphens, never the domain. The iOS content rules match a regex (`RailgunContentRules.pattern`), so this
     * keeps to its grammar and a URL one platform accepts is reachable on the other.
     */
    fun allows(host: String): Boolean =
        hosts.any { pattern ->
            if (pattern.startsWith("*.")) {
                val suffix = pattern.substring(1)
                host.length > suffix.length &&
                    host.endsWith(suffix, ignoreCase = true) &&
                    host.dropLast(suffix.length).split('.').all(LABEL::matches)
            } else {
                host.equals(pattern, ignoreCase = true)
            }
        }

    /** A hostname label as the iOS content rules match one: letters, digits and inner hyphens. */
    private val LABEL = Regex("[a-z0-9]+(-+[a-z0-9]+)*", RegexOption.IGNORE_CASE)
}
