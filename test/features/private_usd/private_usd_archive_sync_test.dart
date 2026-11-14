import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_archive_sync_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';

import 'support/fake_private_usd_backend.dart';

// The archive-sync setting: on by default and kept across launches, offered
// only where the page can read an archive (Ethereum's, fetched by Android's
// host), and off when it can't be read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerWith({
    required PrivateUsdArchiveSyncStore store,
    String railgunNetwork = 'mainnet',
  }) {
    final container = ProviderContainer(
      overrides: [
        privateUsdArchiveSyncStoreProvider.overrideWithValue(store),
        appBootstrapProvider.overrideWithValue(
          AppBootstrapState(
            initialLocation: '/home',
            initialAccountState: const AccountState(),
            initialSyncSnapshot: AppSyncSnapshot.empty,
            network: 'main',
            rpcEndpointConfig: defaultRpcEndpointConfig('main'),
            themeMode: ThemeMode.dark,
            privacyModeEnabled: false,
            isPasswordConfigured: true,
            isUnlocked: true,
            passwordRotationRecoveryFailed: false,
          ),
        ),
        privateUsdDeploymentProvider.overrideWith(
          (ref, network) => _deployment(railgunNetwork),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the archive is read until the user turns it off, and stays as set '
      'across launches', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = AppSecureStore.testing(
      storage: const FlutterSecureStorage(),
    );
    Future<bool> launch() => containerWith(
      store: PrivateUsdArchiveSyncStore(storage),
    ).read(privateUsdArchiveSyncProvider.future);

    final container = containerWith(store: PrivateUsdArchiveSyncStore(storage));
    expect(await container.read(privateUsdArchiveSyncProvider.future), isTrue);
    await container.read(privateUsdArchiveSyncProvider.notifier).set(false);
    expect(await launch(), isFalse);
    await container.read(privateUsdArchiveSyncProvider.notifier).set(true);
    expect(await launch(), isTrue);
  });

  test("a page starts on the archive only on Android's mainnet, and with the "
      'setting on', () async {
    final start = FutureProvider.autoDispose(privateUsdArchiveSyncOf);
    Future<bool> starts(ProviderContainer container) =>
        container.read(start.future);

    expect(
      await starts(containerWith(store: MemoryArchiveSyncStore())),
      isTrue,
    );
    expect(
      await starts(containerWith(store: MemoryArchiveSyncStore(false))),
      isFalse,
    );
    expect(
      await starts(
        containerWith(
          store: MemoryArchiveSyncStore(),
          railgunNetwork: 'sepolia',
        ),
      ),
      isFalse,
      reason: "Sepolia's archive stopped",
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(
      await starts(containerWith(store: MemoryArchiveSyncStore())),
      isFalse,
      reason: "the iOS host doesn't fetch it for the page",
    );
  });

  test(
    'a setting that cannot be read starts the page without the archive',
    () async {
      final store = MemoryArchiveSyncStore(true)..failing = true;
      final container = containerWith(store: store);
      final start = FutureProvider.autoDispose(privateUsdArchiveSyncOf);
      expect(await container.read(start.future), isFalse);
    },
  );

  test("the page's start says whether to read the archive", () {
    const params = RailgunStartParams(
      network: 'mainnet',
      rpcUrls: ['https://ethereum-rpc.publicnode.com'],
      poiNodeUrls: ['https://ppoi.fdi.network/'],
      archive: true,
    );
    expect(params.toJson(), contains('"archive":true'));
    expect(
      const RailgunStartParams(
        network: 'sepolia',
        rpcUrls: [],
        poiNodeUrls: [],
      ).toJson(),
      contains('"archive":false'),
    );
  });
}

ApiDeployment _deployment(String railgunNetwork) => ApiDeployment(
  network: railgunNetwork == 'mainnet' ? 'mainnet' : 'testnet',
  railgunNetwork: railgunNetwork,
  chainId: railgunNetwork == 'mainnet' ? 1 : 11155111,
  token: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
  tokenDecimals: 6,
  keylessRpcUrl: 'https://ethereum-rpc.publicnode.com',
  poiNodeUrl: 'https://ppoi.fdi.network/',
  railgunProxy: '0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9',
  relayAdapt: '0x4025ee6512dbbda97049bcf5aa5d38c54af6be8a',
  relayerRailgunAddress: '0zk1relayer',
  allowedHosts: const ['ethereum-rpc.publicnode.com'],
  rpcHosts: const ['ethereum-rpc.publicnode.com'],
  explorerTxPrefix: 'https://etherscan.io/tx/',
  railscanTxPrefix: 'https://railscan.io/tx/',
  zcashConfirmations: 2,
  escrowConfirmations: 2,
  screeningSeconds: 3600,
  maxRelayerFee: '2000000',
  usdTokens: const [],
  bridgeAvailable: false,
);
