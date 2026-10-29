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
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_host_channel.dart';
import 'package:zcash_wallet/src/providers/app_security_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';

// A send's change stays processing until Railgun's screening nodes take its
// proofs. The page reports when its screening last failed, and the balance
// says so instead of "a send is being confirmed" for days.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Page page;
  var clock = DateTime(2026, 10, 21, 9);

  ProviderContainer containerWith({
    CachedPrivateUsdBalances? cached,
    ApiDeployment? deployment,
  }) {
    page = _Page();
    final engine = RailgunEngine(
      host: page,
      wallets: _Wallets(),
      startBridge: () async => 4242,
      stopBridge: () async {},
      now: () => clock,
    );
    final container = ProviderContainer(
      overrides: [
        appSecurityProvider.overrideWith(_Security.new),
        railgunEngineProvider.overrideWithValue(engine),
        privateUsdBalanceCacheProvider.overrideWithValue(_Cache(cached)),
        privateUsdCurrentDeploymentProvider.overrideWithValue(deployment),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await engine.dispose();
    });
    container.listen(privateUsdBalanceProvider(_account), (_, _) {});
    return container;
  }

  Future<void> syncAnswering(ProviderContainer container, String body) async {
    // The cache read the notifier starts with.
    await pumpEventQueue();
    container.read(privateUsdBalanceProvider(_account).notifier).refresh();
    await pumpEventQueue();
    page.refreshing!.complete(body);
    await pumpEventQueue();
  }

  Future<void> sync(ProviderContainer container, String screening) =>
      syncAnswering(
        container,
        '{"balances":$_balancesJson,"screening":"$screening"}',
      );

  bool screeningFailed(ProviderContainer container) =>
      container.read(privateUsdBalanceProvider(_account)).screeningFailed;

  test('a sync that failed on the RPC says so until one succeeds or the RPC '
      'changes', () async {
    final container = containerWith();
    PrivateUsdBalanceState state() =>
        container.read(privateUsdBalanceProvider(_account));
    Future<void> syncFailing(RailgunHostErrorCode code) async {
      await pumpEventQueue();
      container.read(privateUsdBalanceProvider(_account).notifier).refresh();
      await pumpEventQueue();
      page.refreshing!.completeError(RailgunHostException(code));
      await pumpEventQueue();
    }

    await syncFailing(RailgunHostErrorCode.failed);
    expect(state().refreshFailed, isTrue);
    expect(state().rpcFailed, isFalse);

    await syncFailing(RailgunHostErrorCode.rpcFailed);
    expect(state().rpcFailed, isTrue);
    // A retry failing before the page asked the RPC keeps the verdict.
    await syncFailing(RailgunHostErrorCode.failed);
    expect(state().rpcFailed, isTrue);

    container
        .read(privateUsdBalanceProvider(_account).notifier)
        .clearRpcFailed();
    expect(state().rpcFailed, isFalse);
    expect(state().refreshFailed, isTrue);

    await syncFailing(RailgunHostErrorCode.rpcFailed);
    expect(state().rpcFailed, isTrue);
    await sync(container, 'ok');
    expect(state().rpcFailed, isFalse);
    expect(state().refreshFailed, isFalse);
  });

  test('a sync whose screening failed marks the balance until one goes '
      'through', () async {
    final container = containerWith();

    await sync(container, 'failed');
    expect(screeningFailed(container), isTrue);

    await sync(container, 'ok');
    expect(screeningFailed(container), isFalse);
  });

  // The private sends received come with each sync: the deployment's dollar
  // tokens only, never cached, and kept through a sync that could not read
  // them.
  test('a sync lists the dollar sends received; one with no block time keeps '
      'the time it was first listed', () async {
    final container = containerWith(deployment: _sepolia);
    final txid = '0x${'ab' * 32}';
    final received =
        '[{"txid":"$txid","timestamp":1790000000,"token":"$_dollars",'
        '"amount":"5","bucket":"Spendable","sender":null},'
        '{"txid":"$txid","timestamp":null,"token":"$_dollars","amount":"6",'
        '"bucket":"MissingExternalPOI","sender":null},'
        '{"txid":"$txid","timestamp":1790000000,'
        '"token":"0x1111111111111111111111111111111111111111","amount":"7",'
        '"bucket":"Spendable","sender":null}]';
    List<RailgunReceipt> receipts() =>
        container.read(privateUsdBalanceProvider(_account)).received;

    await syncAnswering(
      container,
      '{"balances":{},"screening":"ok","received":$received}',
    );
    expect(receipts().map((receipt) => receipt.amount), [
      BigInt.from(5),
      BigInt.from(6),
    ]);
    expect(
      receipts().first.at,
      DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000),
    );
    final firstListed = clock;
    expect(receipts().last.at, firstListed);

    clock = clock.add(const Duration(minutes: 5));
    await syncAnswering(
      container,
      '{"balances":{},"screening":"ok","received":$received}',
    );
    expect(receipts().last.at, firstListed);

    await syncAnswering(
      container,
      '{"balances":{},"screening":"ok","received":null}',
    );
    expect(receipts(), hasLength(2));
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

const _dollars = '0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c';

const _sepolia = ApiDeployment(
  network: 'testnet',
  railgunNetwork: 'sepolia',
  chainId: 11155111,
  token: _dollars,
  tokenDecimals: 6,
  keylessRpcUrl: 'https://ethereum-sepolia-rpc.publicnode.com',
  poiNodeUrl: 'https://ppoi.fdi.network/',
  railgunProxy: '0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea',
  relayAdapt: '0x7e3d929EbD5bDC84d02Bd3205c777578f33A214D',
  relayerRailgunAddress: '0zk1relayer',
  allowedHosts: ['ethereum-sepolia-rpc.publicnode.com'],
  rpcHosts: ['ethereum-sepolia-rpc.publicnode.com'],
  swapContract: '0x459b0a69e0f736666b66a3ffe0fc17c11f05980d',
  explorerTxPrefix: 'https://sepolia.etherscan.io/tx/',
  railscanTxPrefix: 'https://railscan.io/tx/',
  zcashConfirmations: 2,
  escrowConfirmations: 2,
  screeningSeconds: 3600,
  maxRelayerFee: '2000000',
  usdTokens: [ApiUsdToken(address: _dollars, symbol: 'tUSD')],
  bridgeAvailable: true,
);

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
