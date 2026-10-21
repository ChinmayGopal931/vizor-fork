import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_balance_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/railgun_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_cache.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_host_channel.dart';
import 'package:zcash_wallet/src/providers/app_security_provider.dart';

// A send's change stays processing until Railgun's screening nodes take its
// proofs. The page reports when its screening last failed, and the balance
// says so instead of "a send is being confirmed" for days.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Page page;

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
        appSecurityProvider.overrideWith(_Security.new),
        railgunEngineProvider.overrideWithValue(engine),
        privateUsdBalanceCacheProvider.overrideWithValue(_Cache(cached)),
        privateUsdCurrentDeploymentProvider.overrideWithValue(null),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await engine.dispose();
    });
    container.listen(privateUsdBalanceProvider(_account), (_, _) {});
    return container;
  }

  Future<void> sync(ProviderContainer container, String screening) async {
    // The cache read the notifier starts with.
    await pumpEventQueue();
    container.read(privateUsdBalanceProvider(_account).notifier).refresh();
    await pumpEventQueue();
    page.refreshing!.complete(
      '{"balances":$_balancesJson,"screening":"$screening"}',
    );
    await pumpEventQueue();
  }

  bool screeningFailed(ProviderContainer container) =>
      container.read(privateUsdBalanceProvider(_account)).screeningFailed;

  test('a sync whose screening failed marks the balance until one goes '
      'through', () async {
    final container = containerWith();

    await sync(container, 'failed');
    expect(screeningFailed(container), isTrue);

    await sync(container, 'ok');
    expect(screeningFailed(container), isFalse);
  });

  test('a cached balance shows without it', () async {
    final container = containerWith(
      cached: CachedPrivateUsdBalances(
        address: '0zk1account',
        updatedAt: DateTime(2026, 10, 19),
        balances: RailgunBalances.parse(jsonDecode(_balancesJson)),
      ),
    );
    await pumpEventQueue();

    final state = container.read(privateUsdBalanceProvider(_account));
    expect(state.balances, isNotNull);
    expect(state.screeningFailed, isFalse);
  });
}

const _account = 'account';

const _balancesJson =
    '{"MissingInternalPOI":[{"token":'
    '"0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c","amount":"5"}]}';

class _Security extends AppSecurityNotifier {
  @override
  AppSecurityState build() =>
      const AppSecurityState(isPasswordConfigured: true, isUnlocked: true);
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
