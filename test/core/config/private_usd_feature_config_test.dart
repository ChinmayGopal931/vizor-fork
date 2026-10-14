
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/private_usd_feature_config.dart';
import 'package:zcash_wallet/src/providers/network_privacy_provider.dart';

// The kill switch (D16): only an explicit `false` hides the feature; a
// missing flag, an unreadable document or a failed fetch keeps the last
// known answer, which defaults to available.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only an explicit bool is an answer', () {
    expect(parsePrivateUsdAvailability('{"private_usd_available":true}'), true);
    expect(
      parsePrivateUsdAvailability('{"private_usd_available":false}'),
      false,
    );
    expect(
      parsePrivateUsdAvailability('{"private_usd_available":"false"}'),
      isNull,
    );
    expect(parsePrivateUsdAvailability('{"other":false}'), isNull);
    expect(parsePrivateUsdAvailability('[false]'), isNull);
    expect(parsePrivateUsdAvailability('not json'), isNull);
  });

  test('without an answer the last known one stands, else available', () {
    expect(resolvePrivateUsdAvailability(), true);
    expect(resolvePrivateUsdAvailability(lastKnown: false), false);
    expect(
      resolvePrivateUsdAvailability(fetched: true, lastKnown: false),
      true,
    );
    expect(
      resolvePrivateUsdAvailability(fetched: false, lastKnown: true),
      false,
    );
  });

  group('privateUsdKillSwitchProvider', () {
    test('no URL: available, and nothing is fetched', () async {
      final source = _FakeSource(answer: false);
      final container = _container(url: '', source: source);

      expect(container.read(privateUsdKillSwitchProvider), true);
      await _settle();
      expect(container.read(privateUsdKillSwitchProvider), true);
      expect(source.fetches, 0);
    });

    test('an explicit false hides it and is remembered', () async {
      final store = _FakeStore();
      final container = _container(
        source: _FakeSource(answer: false),
        store: store,
      );

      container.read(privateUsdKillSwitchProvider);
      await _settle();

      expect(container.read(privateUsdKillSwitchProvider), false);
      expect(store.value, false);
    });

    test('a failed fetch keeps the last known false', () async {
      final container = _container(
        source: _FakeSource(fails: true),
        store: _FakeStore(false),
      );

      container.read(privateUsdKillSwitchProvider);
      await _settle();

      expect(container.read(privateUsdKillSwitchProvider), false);
    });

    test('a document without the flag keeps the last known false', () async {
      final store = _FakeStore(false);
      final container = _container(source: _FakeSource(), store: store);

      container.read(privateUsdKillSwitchProvider);
      await _settle();

      expect(container.read(privateUsdKillSwitchProvider), false);
      expect(store.value, false);
    });

    test('a failed fetch with nothing known stays available', () async {
      final container = _container(source: _FakeSource(fails: true));

      container.read(privateUsdKillSwitchProvider);
      await _settle();

      expect(container.read(privateUsdKillSwitchProvider), true);
    });

    test('a later true brings it back', () async {
      final store = _FakeStore(false);
      final container = _container(
        source: _FakeSource(answer: true),
        store: store,
      );

      container.read(privateUsdKillSwitchProvider);
      await _settle();

      expect(container.read(privateUsdKillSwitchProvider), true);
      expect(store.value, true);
    });
  });

  test('a keyed RPC URL is used only on a host the page may reach', () {
    const hosts = ['eth-sepolia.g.alchemy.com', 'sepolia.infura.io'];
    expect(
      privateUsdKeyedRpcUrl(
        'sepolia',
        allowedHosts: hosts,
        sepolia: 'https://eth-sepolia.g.alchemy.com/v2/key',
      ),
      'https://eth-sepolia.g.alchemy.com/v2/key',
    );
    for (final url in [
      '',
      'https://rpc.example.com/key',
      'http://eth-sepolia.g.alchemy.com/v2/key',
      'https://eth-sepolia.g.alchemy.com:8443/v2/key',
    ]) {
      expect(
        privateUsdKeyedRpcUrl('sepolia', allowedHosts: hosts, sepolia: url),
        isNull,
        reason: url,
      );
    }
  });
}

ProviderContainer _container({
  String url = 'https://example.com/private-usd.json',
  required _FakeSource source,
  _FakeStore? store,
}) {
  final container = ProviderContainer(
    overrides: [
      privateUsdFlagUrlProvider.overrideWithValue(url),
      privateUsdAvailabilitySourceProvider.overrideWithValue(source),
      privateUsdAvailabilityStoreProvider.overrideWithValue(
        store ?? _FakeStore(),
      ),
      privateUsdKillSwitchWorkPolicyProvider.overrideWithValue(
        ({required bool isInForeground}) => false,
      ),
      networkPrivacyProvider.overrideWith(_FakeNetworkPrivacyNotifier.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeSource implements PrivateUsdAvailabilitySource {
  _FakeSource({this.answer, this.fails = false});

  final bool? answer;
  final bool fails;
  var fetches = 0;

  @override
  Future<bool?> fetch() async {
    fetches++;
    if (fails) throw StateError('unreachable');
    return answer;
  }
}

class _FakeStore implements PrivateUsdAvailabilityStore {
  _FakeStore([this.value]);

  bool? value;

  @override
  Future<bool?> read() async => value;

  @override
  Future<void> write(bool available) async => value = available;
}

class _FakeNetworkPrivacyNotifier extends NetworkPrivacyNotifier {
  @override
  NetworkPrivacyState build() => const NetworkPrivacyState.off();
}
