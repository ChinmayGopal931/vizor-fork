/// The anonymizing networks Shielded USD's Ethereum requests can go through,
/// each an anon-rpc worker (<https://ethereum.github.io/anon-rpc/>) pinned by
/// a specifier contract: the contract names the worker's keccak hash, the
/// page checks the bundle against it before a byte of it runs. `off` is the
/// direct connection as before (over Tor when Tor is on).
enum AnonRpcNetwork {
  /// Arti, the Tor Project's Rust client, compiled to WebAssembly: circuits
  /// are built on the phone and reach the Tor network through a KPS gateway
  /// (browsers cannot open the raw TCP Tor uses).
  tor(
    label: 'Tor',
    description:
        'Tor circuits built on your phone. The provider sees a Tor exit, '
        'never your IP address.',
    specifier: '0x700dA3193D35fA54Cd3fBf29B66f2a2A0385659e',
    specifierChainId: 1,
  ),

  /// A Sphinx mixnet with entry, mix and exit nodes, dialled over KPS; TLS to
  /// the RPC runs inside the worker. Its specifier lives on Sepolia and its
  /// nodes are a testnet deployment.
  nox(
    label: 'Nox',
    description:
        'A Sphinx mixnet on testnet nodes. Slower: each hop adds delay.',
    specifier: '0x35133267A8F7EC35046a83DCA0f4Ca8A6e1b7A9A',
    specifierChainId: 11155111,
  ),

  /// The Nym mixnet client compiled to WebAssembly. Not yet verified in the
  /// app's WebView behind its proxy, so debug builds only until it is.
  nym(
    label: 'Nym',
    description: 'The Nym mixnet, about 18 MB to download the first time.',
    specifier: '0x3aCD9742C68F6d993066Ae25533e09b9e1f60eD0',
    specifierChainId: 1,
  ),

  /// The reference worker: a plain fetch inside the sandbox. It proves the
  /// hash check and the sandbox, not privacy; debug builds only.
  passthrough(
    label: 'Passthrough (no privacy)',
    description:
        'The reference worker: a plain fetch. For testing the sandbox only.',
    specifier: '0x4fd77be300f31c5fe6ab266d35d27750a3478d27',
    specifierChainId: 1,
  ),

  /// Direct connections, as before: over Tor when Tor is on.
  off(
    label: 'Direct',
    description:
        'Straight to the provider, which sees your IP address unless Tor '
        'is on.',
  );

  const AnonRpcNetwork({
    required this.label,
    required this.description,
    this.specifier,
    this.specifierChainId,
  });

  final String label;
  final String description;

  /// The specifier contract, `0x` hex; null for [off].
  final String? specifier;

  /// The chain the specifier contract lives on, so the chain the bootstrap
  /// read must ask: not the chain the anonymized fetch reaches.
  final int? specifierChainId;

  /// What a fresh install uses.
  static const defaultNetwork = tor;

  static AnonRpcNetwork? fromName(String? name) {
    for (final network in values) {
      if (network.name == name) return network;
    }
    return null;
  }

  bool get anonymizes => this != off;

  /// Whether the picker offers this network: Nox's nodes are a testnet
  /// deployment, Nym is unverified in the WebView and passthrough protects
  /// nothing, so the last two are for debug builds.
  bool availableFor({required String walletNetwork, required bool debug}) =>
      switch (this) {
        tor || off => true,
        nox => walletNetwork == 'test',
        nym || passthrough => debug,
      };

  /// Where the page reads the specifier: publicnode on the specifier's
  /// chain. Both hosts are on the anon page's allowlist (Rust
  /// `ANON_RPC_PAGE_HOSTS`); the read carries nothing about the user.
  String? get bootstrapRpcUrl => switch (specifierChainId) {
    1 => 'https://ethereum-rpc.publicnode.com',
    11155111 => 'https://ethereum-sepolia-rpc.publicnode.com',
    _ => null,
  };

  /// The worker's `config`, a plain JSON value opaque to the harness: tor-js
  /// takes its gateways and a log level; the others take none.
  Object? get config => switch (this) {
    tor => {'gateways': kAnonRpcTorGateways, 'logLevel': 'info'},
    off => null,
    _ => const <String, Object?>{},
  };
}

/// The KPS gateways (`ip:port:certhash`) tor-js reaches the Tor network
/// through, from `VIZOR_ANON_RPC_TOR_GATEWAYS` (comma-separated) when the
/// build names its own, else the EF's demonstration gateway: limited
/// capacity, and it may disappear at any time.
const kVizorAnonRpcTorGateways = String.fromEnvironment(
  'VIZOR_ANON_RPC_TOR_GATEWAYS',
);

const _kDemoTorGateway =
    '152.236.3.22:12298:uEiCH0VdbhryzJcMtCfB0vLA4sOvHdQ4hq5w7CopcwU59bQ';

final List<String> kAnonRpcTorGateways = kVizorAnonRpcTorGateways.isEmpty
    ? const [_kDemoTorGateway]
    : kVizorAnonRpcTorGateways
          .split(',')
          .map((gateway) => gateway.trim())
          .where((gateway) => gateway.isNotEmpty)
          .toList(growable: false);
