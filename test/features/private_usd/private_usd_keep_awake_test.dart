import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_record_key.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_balance_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_keep_awake_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_unfinished_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/railgun_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_cache.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_host_channel.dart';
import 'package:zcash_wallet/src/providers/app_security_provider.dart';

// iOS progress VI-14 and VI-18: the screen stays on through a Railgun first
// sync while the wallet is unlocked; `SyncKeepAwakeNativeHost` lets go in the
// background (its own test).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Page page;
  late _Security security;

  ProviderContainer containerWith({CachedPrivateUsdBalances? cached}) {
    page = _Page();
    final engine = RailgunEngine(
      host: page,
      wallets: _Wallets(),
      startBridge: () async => 4242,
      stopBridge: () async {},
    );
    final container = ProviderContainer(
      overrides: [
        appSecurityProvider.overrideWith(() => security = _Security()),
        railgunEngineProvider.overrideWithValue(engine),
        privateUsdBalanceCacheProvider.overrideWithValue(_Cache(cached)),
        privateUsdCurrentDeploymentProvider.overrideWithValue(null),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await engine.dispose();
    });
    // The native host watches it for the whole app's life.
    container.listen(privateUsdKeepAwakeProvider, (_, _) {});
    container.listen(privateUsdBalanceProvider(_account), (_, _) {});
    return container;
  }

  bool keepAwake(ProviderContainer container) =>
      container.read(privateUsdKeepAwakeProvider);

  Future<void> startRefresh(ProviderContainer container) async {
    // The cache read the notifier starts with.
    await pumpEventQueue();
    container.read(privateUsdBalanceProvider(_account).notifier).refresh();
    await pumpEventQueue();
    expect(page.refreshing, isNotNull, reason: 'the page is syncing');
  }

  test('a first sync keeps the screen on until it completes', () async {
    final container = containerWith();
    expect(keepAwake(container), isFalse);

    await startRefresh(container);
    expect(keepAwake(container), isTrue);

    page.refreshing!.complete(_refreshJson);
    await pumpEventQueue();
    expect(
      container.read(privateUsdBalanceProvider(_account)).balances,
      isNotNull,
    );
    expect(keepAwake(container), isFalse);
  });

  test('a first sync that fails lets go', () async {
    final container = containerWith();
    await startRefresh(container);
    expect(keepAwake(container), isTrue);

    page.refreshing!.completeError(
      RailgunHostException(RailgunHostErrorCode.failed),
    );
    await pumpEventQueue();
    expect(
      container.read(privateUsdBalanceProvider(_account)).refreshFailed,
      isTrue,
    );
    expect(keepAwake(container), isFalse);
  });

  test('a lock lets go at once', () async {
    final container = containerWith();
    await startRefresh(container);
    expect(keepAwake(container), isTrue);

    security.lockNow();
    expect(keepAwake(container), isFalse);
  });

  test('a refresh of a wallet that synced before keeps nothing on', () async {
    final container = containerWith(
      cached: CachedPrivateUsdBalances(
        address: '0zk1account',
        updatedAt: DateTime(2026, 10, 17),
        balances: RailgunBalances.parse(jsonDecode(_balancesJson)),
      ),
    );

    await startRefresh(container);
    expect(
      container.read(privateUsdBalanceProvider(_account)).isRefreshing,
      isTrue,
    );
    expect(keepAwake(container), isFalse);
    page.refreshing!.complete(_refreshJson);
  });

  test("a conversion's progress still keeps the screen on", () {
    final container = containerWith();
    const key = PrivateUsdRecordKey(
      accountUuid: _account,
      direction: PrivateUsdDirection.forward,
      index: 1,
    );

    container.read(privateUsdProgressVisibleProvider.notifier).show(key);
    expect(keepAwake(container), isFalse, reason: 'no key step to come');
    container.read(privateUsdUnfinishedProvider.notifier).publish({key});
    expect(keepAwake(container), isTrue);
  });
}

const _account = 'account';

const _balancesJson =
    '{"Spendable":[{"token":"0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c",'
    '"amount":"5"}]}';
const _refreshJson = '{"balances":$_balancesJson,"screening":"ok"}';

class _Security extends AppSecurityNotifier {
  @override
  AppSecurityState build() =>
      const AppSecurityState(isPasswordConfigured: true, isUnlocked: true);

  void lockNow() => state = state.copyWith(isUnlocked: false);
}

class _Cache extends PrivateUsdBalanceCache {
  _Cache(this.cached) : super(AppSecureStore.instance);

  final CachedPrivateUsdBalances? cached;

  @override
  Future<CachedPrivateUsdBalances?> read(String accountUuid) async => cached;

  @override
  Future<void> write(
    String accountUuid, {
    required String address,
    required DateTime updatedAt,
    required RailgunBalances balances,
  }) async {}
}

class _Wallets implements RailgunWalletSource {
  @override
  Future<RailgunWalletOpening> prepare(String accountUuid) async =>
      const RailgunWalletOpening(
        start: RailgunStartParams(
          network: 'sepolia',
          rpcUrls: ['https://ethereum-sepolia-rpc.publicnode.com'],
          poiNodeUrls: ['https://ppoi.fdi.network/'],
        ),
        wallet: RailgunOpenWalletParams(
          encryptionKey: 'key',
          mnemonic: 'words',
        ),
        expectedAddress: '0zk1account',
      );

  @override
  Future<RailgunWalletDeletion?> prepareDeletion(String accountUuid) async =>
      null;
}

/// A page whose `refresh` waits for the test.
class _Page implements RailgunHost {
  Completer<String>? refreshing;
  var _open = false;

  @override
  Future<void> load({required int proxyPort, required bool debug}) async =>
      _open = true;

  @override
  Future<String> call(String method, String paramsJson) {
    if (!_open) throw RailgunHostException(RailgunHostErrorCode.closed);
    return switch (method) {
      'start' => Future.value('{"fees":{"unshield":25,"shield":25}}'),
      'openWallet' => Future.value('{"address":"0zk1account"}'),
      'refresh' => (refreshing = Completer<String>()).future,
      _ => throw RailgunHostException(RailgunHostErrorCode.badArgs),
    };
  }

  @override
  Future<void> close() async => _open = false;

  @override
  Future<void> wipe() async => _open = false;

  @override
  Future<bool> isOpen() async => _open;

  @override
  Stream<String> get events => const Stream.empty();
}
