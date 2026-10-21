import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/private_usd_feature_config.dart';

void main() {
  test("a user's own RPC URL is https, on its network's RPC hosts", () {
    // The deployment's page hosts (Rust's RAILGUN_PAGE_HOSTS).
    const pageHosts = [
      'ethereum-rpc.publicnode.com',
      'ethereum-sepolia-rpc.publicnode.com',
      'eth-mainnet.g.alchemy.com',
      'eth-sepolia.g.alchemy.com',
      'mainnet.infura.io',
      'sepolia.infura.io',
      'ppoi.fdi.network',
      'rail-squid.squids.live',
      'railgun-sepolia-list.pepeman931.workers.dev',
      'ipfs-lb.com',
      'railgun-artifacts.pepeman931.workers.dev',
    ];
    String? custom(String url, {String network = 'mainnet'}) =>
        privateUsdCustomRpcUrl(url, network, allowedHosts: pageHosts);

    for (final (url, network) in [
      ('https://eth-mainnet.g.alchemy.com/v2/key', 'mainnet'),
      ('https://mainnet.infura.io:443/v3/key', 'mainnet'),
      ('https://ethereum-rpc.publicnode.com', 'mainnet'),
      ('https://eth-sepolia.g.alchemy.com/v2/key', 'sepolia'),
      ('https://sepolia.infura.io/v3/key', 'sepolia'),
      ('https://ethereum-sepolia-rpc.publicnode.com', 'sepolia'),
    ]) {
      expect(custom(' $url ', network: network), url, reason: url);
    }
    for (final url in [
      '',
      'eth-mainnet.g.alchemy.com/v2/key',
      'http://eth-mainnet.g.alchemy.com/v2/key',
      'https://eth-mainnet.g.alchemy.com:8443/v2/key',
      'https://rpc.example.com/key',
      // A host the page reaches that serves no RPC.
      'https://ppoi.fdi.network/',
      // The other network's provider.
      'https://eth-sepolia.g.alchemy.com/v2/key',
      'https://user:secret@mainnet.infura.io/v3/key',
      'https://mainnet.infura.io/v3/key#fragment',
    ]) {
      expect(custom(url), isNull, reason: url);
    }
    // Only an RPC host the page may reach counts.
    expect(
      privateUsdCustomRpcUrl(
        'https://mainnet.infura.io/v3/key',
        'mainnet',
        allowedHosts: const ['eth-mainnet.g.alchemy.com'],
      ),
      isNull,
    );
  });
}
