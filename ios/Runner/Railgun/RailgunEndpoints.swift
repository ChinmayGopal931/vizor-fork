/// What the page may reach besides its own files, on both networks. Rust's `deployment::RAILGUN_PAGE_HOSTS` (the
/// bridge's allowlist), Kotlin's `RailgunEndpoints.hosts` and the page's CSP (`index.html`) list the same hosts; a
/// host missing from any of them is blocked silently. A Rust test (`railgun_bridge.rs`) reads the literals below, so
/// keep them literal.
enum RailgunEndpoints {
  static let poiNodeURL = "https://ppoi.fdi.network/"

  // Ethereum RPC (keyless publicnode, then the keyed providers), the screening node, and the SDK's own quick sync and
  // the gateway it downloads proving artifacts from.
  static let hosts: [String] = [
    "ethereum-rpc.publicnode.com",
    "ethereum-sepolia-rpc.publicnode.com",
    "eth-mainnet.g.alchemy.com",
    "eth-sepolia.g.alchemy.com",
    "mainnet.infura.io",
    "sepolia.infura.io",
    "ppoi.fdi.network",
    "rail-squid.squids.live",
    "ipfs-lb.com",
  ]
}
