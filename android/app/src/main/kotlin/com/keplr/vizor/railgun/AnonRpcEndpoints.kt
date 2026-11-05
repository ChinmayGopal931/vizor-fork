package com.keplr.vizor.railgun

/**
 * What the anon-rpc page may reach besides its own assets: publicnode on both networks, for the one bootstrap read of
 * a worker's specifier (its hash and resolvers), and the resolvers the specifiers name for the worker bundles. The
 * bundle is checked against its on-chain hash before a byte of it runs, so the resolver is trusted with nothing.
 * Rust's `deployment::ANON_RPC_PAGE_HOSTS` (in the bridge's allowlist) and the page's CSP (`anon-rpc-web/src/index.html`)
 * list the same hosts; a Rust test (`railgun_bridge.rs`) reads the literals below, so keep them literal.
 */
internal object AnonRpcEndpoints {
    val hosts =
        setOf(
            "ethereum-rpc.publicnode.com",
            "ethereum-sepolia-rpc.publicnode.com",
            "cdn.jsdelivr.net",
            "unpkg.com",
            "raw.githubusercontent.com",
        )

    /** Whether [host] is one of [hosts] ([HostPatterns.allows]). */
    fun allows(host: String): Boolean = HostPatterns.allows(hosts, host)
}
