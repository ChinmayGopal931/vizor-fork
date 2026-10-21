/// What the page may reach besides its own files, on both networks. Rust's `deployment::RAILGUN_PAGE_HOSTS` (the
/// bridge's allowlist), Kotlin's `RailgunEndpoints.hosts` and the page's CSP (`index.html`) list the same hosts; a
/// host missing from any of them is blocked silently. A Rust test (`railgun_bridge.rs`) reads the literals below, so
/// keep them literal.
enum RailgunEndpoints {
  // Ethereum RPC (keyless publicnode, then the keyed providers), the screening node, the SDK's own quick sync and, on
  // Sepolia, our copy of its transaction list with the hash chain repaired, and where the proving artifacts come from:
  // the SDK's own gateway, then our mirror when the gateway fails.
  static let hosts: [String] = [
    "ethereum-rpc.publicnode.com",
    "ethereum-sepolia-rpc.publicnode.com",
    "eth-mainnet.g.alchemy.com",
    "eth-sepolia.g.alchemy.com",
    "mainnet.infura.io",
    "sepolia.infura.io",
    "ppoi.fdi.network",
    "rail-squid.squids.live",
    "railgun-sepolia-list.pepeman931.workers.dev",
    "ipfs-lb.com",
    "railgun-artifacts.pepeman931.workers.dev",
  ]
}
