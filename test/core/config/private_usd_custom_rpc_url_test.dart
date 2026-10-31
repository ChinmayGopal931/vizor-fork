import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/private_usd_feature_config.dart';

void main() {
  // Some of mainnet's providers (Rust's `Deployment::rpc_hosts`).
  const rpcHosts = [
    'ethereum-rpc.publicnode.com',
    'eth-mainnet.g.alchemy.com',
    'mainnet.infura.io',
    '*.quiknode.pro',
    'rpc.ankr.com',
    'lb.drpc.live',
  ];

  test("a user's own RPC URL is https, on one of the network's providers", () {
    String? custom(String url) =>
        privateUsdCustomRpcUrl(url, rpcHosts: rpcHosts);

    for (final url in [
      'https://eth-mainnet.g.alchemy.com/v2/key',
      'https://mainnet.infura.io:443/v3/key',
      'https://ethereum-rpc.publicnode.com',
      'https://rpc.ankr.com/eth/key',
      'https://lb.drpc.live/ethereum?dkey=key',
      // A `*.` entry: an endpoint of the user's own name, one label or more.
      'https://my-endpoint.quiknode.pro/key/',
      'https://my-endpoint.ethereum-mainnet.quiknode.pro/key/',
      'https://MY-ENDPOINT.QuikNode.pro/key/',
      'https://xn--abc.quiknode.pro/key/',
    ]) {
      expect(custom(' $url '), url, reason: url);
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
      // The wildcard's domain itself, and lookalikes.
      'https://quiknode.pro/key',
      'https://my-endpoint.quiknode.pro.evil.example/key',
      'https://evilquiknode.pro/key',
      // Labels the iOS content rules would not match.
      'https://a_b.quiknode.pro/key',
      'https://a..quiknode.pro/key',
      'https://-a.quiknode.pro/key',
      'https://user:secret@mainnet.infura.io/v3/key',
      'https://mainnet.infura.io/v3/key#fragment',
    ]) {
      expect(custom(url), isNull, reason: url);
    }
  });

  test('a host matches a provider exactly, or a wildcard by subdomain', () {
    expect(privateUsdHostAllowed(rpcHosts, 'RPC.ANKR.COM'), isTrue);
    expect(privateUsdHostAllowed(rpcHosts, 'a.quiknode.pro'), isTrue);
    expect(privateUsdHostAllowed(rpcHosts, 'a-b.c-d.quiknode.pro'), isTrue);
    expect(privateUsdHostAllowed(rpcHosts, 'a_b.quiknode.pro'), isFalse);
    expect(privateUsdHostAllowed(rpcHosts, 'a-.quiknode.pro'), isFalse);
    expect(privateUsdHostAllowed(rpcHosts, 'quiknode.pro'), isFalse);
    expect(privateUsdHostAllowed(rpcHosts, '.quiknode.pro'), isFalse);
    expect(privateUsdHostAllowed(rpcHosts, 'a.rpc.ankr.com'), isFalse);
    expect(privateUsdHostAllowed(rpcHosts, ''), isFalse);
  });
}
