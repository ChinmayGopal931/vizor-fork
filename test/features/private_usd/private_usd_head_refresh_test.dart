import 'dart:async';

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

// A watched balance refreshes when Railgun's head moves, the same head every
// wallet reads at the same rate, and at a backstop; never faster because
// funds are on their way, which would tell Railgun's indexer, the RPC and the
// screening nodes when a wallet expects them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrivateUsdHeadWatch', () {
    const fresh = Duration(seconds: 10);
    const older = Duration(minutes: 2);

    test('with nothing shown yet, it refreshes', () {
      expect(PrivateUsdHeadWatch().shouldRefresh('h1', age: null), isTrue);
      expect(PrivateUsdHeadWatch().shouldRefresh(null, age: null), isTrue);
    });

    test('a head that moved past the last refresh refreshes; one that stood '
        'still does not', () {
      final heads = PrivateUsdHeadWatch()..refreshing('h1');
      expect(heads.shouldRefresh('h1', age: older), isFalse);
      expect(heads.shouldRefresh('h2', age: older), isTrue);
      expect(
        heads.shouldRefresh('h2', age: fresh),
        isTrue,
        reason: 'however fresh',
      );
      heads.refreshing('h2');
      expect(heads.shouldRefresh('h2', age: fresh), isFalse);
    });

    test('a head that could not be read refreshes nothing before the '
        'backstop, and keeps the last one', () {
      final heads = PrivateUsdHeadWatch()..refreshing('h1');
      expect(heads.shouldRefresh(null, age: older), isFalse);
      heads.refreshing(null);
      expect(heads.shouldRefresh('h1', age: older), isFalse);
      expect(
        heads.shouldRefresh(null, age: PrivateUsdBalanceTiming.backstop),
        isTrue,
      );
    });

    test('the backstop refreshes a head that stood still', () {
      final heads = PrivateUsdHeadWatch()..refreshing('h1');
      expect(
        heads.shouldRefresh('h1', age: PrivateUsdBalanceTiming.backstop),
        isTrue,
      );
    });

    test('before its first refresh, a head is the balance\'s when that is '
        'younger than a poll', () {
      final heads = PrivateUsdHeadWatch();
      expect(heads.shouldRefresh('h1', age: fresh), isFalse);
      expect(heads.shouldRefresh('h1', age: older), isFalse, reason: 'taken');
      expect(heads.shouldRefresh('h2', age: fresh), isTrue);
      expect(PrivateUsdHeadWatch().shouldRefresh('h1', age: older), isTrue);
    });
  });

  group('a watched balance', () {
    late _Page page;
    late DateTime clock;
    String? head;
    var headReads = 0;

    ({ProviderContainer container, PrivateUsdBalanceNotifier notifier})
    watched({String? balances}) {
      page = _Page(balances ?? _dollarsJson);
      clock = DateTime(2026, 11, 15, 9);
      head = 'h1';
      headReads = 0;
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
          privateUsdBalanceCacheProvider.overrideWithValue(_Cache()),
          privateUsdCurrentDeploymentProvider.overrideWithValue(_sepolia),
          privateUsdBalanceClockProvider.overrideWithValue(() => clock),
          privateUsdRailgunHeadProvider.overrideWithValue(() async {
            headReads++;
            return head;
          }),
        ],
      );
      container.listen(privateUsdBalanceProvider(_account), (_, _) {});
      final notifier = container.read(
        privateUsdBalanceProvider(_account).notifier,
      );
      final cancel = notifier.watch(ifUsed: false);
      addTearDown(() async {
        cancel();
        container.dispose();
        await engine.dispose();
      });
      return (container: container, notifier: notifier);
    }

    Future<void> answer() async {
      await pumpEventQueue();
      page.refreshing!.complete(page.body);
      page.refreshing = null;
      await pumpEventQueue();
    }

    /// The timer's next poll, [PrivateUsdBalanceTiming.headPoll] on.
    Future<void> poll(PrivateUsdBalanceNotifier notifier) async {
      clock = clock.add(PrivateUsdBalanceTiming.headPoll);
      await notifier.pollNow();
      await pumpEventQueue();
    }

    test('refreshes when the head moves, and only then', () async {
      final notifier = watched().notifier;
      await answer();
      expect(page.refreshes, 1, reason: 'nothing shown yet');
      for (var i = 0; i < 5; i++) {
        await poll(notifier);
      }
      expect(page.refreshes, 1, reason: 'the head stood still');
      expect(headReads, greaterThanOrEqualTo(5));
      head = 'h2';
      await poll(notifier);
      expect(page.refreshes, 2);
      await answer();
      await poll(notifier);
      expect(page.refreshes, 2);
    });

    test('refreshes at the backstop though the head stands still', () async {
      final notifier = watched().notifier;
      await answer();
      final polls =
          PrivateUsdBalanceTiming.backstop.inSeconds ~/
          PrivateUsdBalanceTiming.headPoll.inSeconds;
      for (var i = 0; i < polls - 1; i++) {
        await poll(notifier);
      }
      expect(page.refreshes, 1);
      await poll(notifier);
      expect(page.refreshes, 2);
      await answer();
    });

    test('never refreshes faster while funds arrive', () async {
      final (:container, :notifier) = watched(balances: _arrivingJson);
      await answer();
      expect(
        container.read(privateUsdBalanceProvider(_account)).balances?.arriving,
        BigInt.from(5),
      );
      for (var i = 0; i < 10; i++) {
        await poll(notifier);
      }
      expect(page.refreshes, 1, reason: 'the head stood still');
    });

    test('a head that cannot be read waits for the backstop', () async {
      final notifier = watched().notifier;
      await answer();
      head = null;
      for (var i = 0; i < 5; i++) {
        await poll(notifier);
      }
      expect(page.refreshes, 1);
    });
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

const _dollarsJson =
    '{"balances":{"Spendable":[{"token":'
    '"0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c","amount":"5"}]},'
    '"screening":"ok"}';

const _arrivingJson =
    '{"balances":{"ShieldPending":[{"token":'
    '"0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c","amount":"5"}]},'
    '"screening":"ok"}';

class _Security extends AppSecurityNotifier {
  @override
  AppSecurityState build() =>
      const AppSecurityState(isPasswordConfigured: true, isUnlocked: true);
}

class _Cache extends PrivateUsdBalanceCache {
  _Cache() : super(AppSecureStore.instance);

  @override
  Future<CachedPrivateUsdBalances?> read(String accountUuid) async => null;

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

/// A page whose `refresh` waits for the test, answering [body], and counts
/// them.
class _Page implements RailgunHost {
  _Page(this.body);

  final String body;
  Completer<String>? refreshing;
  var refreshes = 0;
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
      'refresh' => () {
        refreshes++;
        return (refreshing = Completer<String>()).future;
      }(),
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
