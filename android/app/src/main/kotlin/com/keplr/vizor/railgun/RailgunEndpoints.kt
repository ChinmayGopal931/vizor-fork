package com.keplr.vizor.railgun

/**
 * What the page may reach besides its own assets, on both networks. Rust's `deployment::RAILGUN_PAGE_HOSTS`
 * (the bridge's allowlist) and the page's CSP (`index.html`) list the same hosts; a host missing from any of
 * the three is blocked silently. A Rust test (`railgun_bridge.rs`) reads the literals below, so keep them
 * literal.
 */
internal object RailgunEndpoints {
    const val POI_NODE_URL = "https://ppoi.fdi.network/"

    // Ethereum RPC (keyless publicnode, then the keyed providers), the screening node, the SDK's own quick sync,
    // and where the proving artifacts come from: the SDK's own gateway, then our mirror when the gateway fails.
    val hosts =
        setOf(
            "ethereum-rpc.publicnode.com",
            "ethereum-sepolia-rpc.publicnode.com",
            "eth-mainnet.g.alchemy.com",
            "eth-sepolia.g.alchemy.com",
            "mainnet.infura.io",
            "sepolia.infura.io",
            "ppoi.fdi.network",
            "rail-squid.squids.live",
            "ipfs-lb.com",
            "railgun-artifacts.pepeman931.workers.dev",
        )
}
