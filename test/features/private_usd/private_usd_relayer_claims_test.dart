import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_relayer_claims_provider.dart';

import 'support/fake_private_usd_backend.dart';

// The relayer-claims setting: on by default, kept in secure storage across
// launches, and one that can't be read fails a bridge rather than fall back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerWith(PrivateUsdRelayerClaimsStore store) {
    final container = ProviderContainer(
      overrides: [
        privateUsdRelayerClaimsStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('relayer claims are on until the user turns them off, and stay as '
      'set across launches', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = AppSecureStore.testing(
      storage: const FlutterSecureStorage(),
    );
    Future<bool> launch() => containerWith(
      PrivateUsdRelayerClaimsStore(storage),
    ).read(privateUsdRelayerClaimsProvider.future);

    final container = containerWith(PrivateUsdRelayerClaimsStore(storage));
    expect(
      await container.read(privateUsdRelayerClaimsProvider.future),
      isTrue,
    );
    await container.read(privateUsdRelayerClaimsProvider.notifier).set(false);
    expect(container.read(privateUsdRelayerClaimsProvider).value, isFalse);
    expect(await launch(), isFalse);

    await container.read(privateUsdRelayerClaimsProvider.notifier).set(true);
    expect(await launch(), isTrue);
  });

  test('a setting that cannot be read fails the bridge, and is read again '
      'next time', () async {
    final store = MemoryRelayerClaimsStore(false)..failing = true;
    final container = containerWith(store);
    final bridge = FutureProvider.autoDispose(privateUsdRelayerClaimsOf);
    final listening = container.listen(bridge.future, (_, _) {});
    addTearDown(listening.close);

    await expectLater(listening.read(), throwsStateError);

    store.failing = false;
    container.invalidate(bridge);
    expect(await container.read(bridge.future), isFalse);
  });
}
