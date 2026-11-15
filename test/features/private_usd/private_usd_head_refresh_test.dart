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

  group('PrivateUsdRailgunHeads', () {
    const fresh = Duration(seconds: 10);
    const older = Duration(minutes: 2);
    PrivateUsdRailgunHeads heads() =>
        PrivateUsdRailgunHeads(read: () async => 'h', now: DateTime.now);

    test('with nothing shown yet, a balance refreshes', () {
      expect(heads().shouldRefresh('a', 'h1', age: null), isTrue);
      expect(heads().shouldRefresh('a', null, age: null), isTrue);
    });

    test('a head moved past the last refresh refreshes; one that stood still '
        'does not', () {
      final shared = heads()..refreshed('a', 'h1');
      expect(shared.shouldRefresh('a', 'h1', age: older), isFalse);
      expect(shared.shouldRefresh('a', 'h2', age: older), isTrue);
      expect(shared.shouldRefresh('a', 'h2', age: fresh), isTrue);
      shared.refreshed('a', 'h2');
      expect(shared.shouldRefresh('a', 'h2', age: fresh), isFalse);
      expect(
        shared.shouldRefresh('b', 'h2', age: older),
        isTrue,
        reason: 'another account refreshed with no head yet',
      );
    });

    test('a head that could not be read refreshes nothing before the '
        'backstop', () {
      final shared = heads()..refreshed('a', 'h1');
      expect(shared.shouldRefresh('a', null, age: older), isFalse);
      shared.refreshed('a', null);
      expect(shared.shouldRefresh('a', 'h1', age: older), isFalse);
      expect(
        shared.shouldRefresh('a', null, age: PrivateUsdBalanceTiming.backstop),
        isTrue,
      );
    });

    test("before an account's first refresh, a head is its balance's when "
        'that is younger than a poll', () {
      final shared = heads();
      expect(shared.shouldRefresh('a', 'h1', age: fresh), isFalse);
      expect(shared.shouldRefresh('a', 'h1', age: older), isFalse);
      expect(shared.shouldRefresh('a', 'h2', age: fresh), isTrue);
      expect(heads().shouldRefresh('a', 'h1', age: older), isTrue);
    });

    test('balances that ask together share one request', () async {
      var clock = DateTime(2026, 11, 15, 9);
      var reads = 0;
      final shared = PrivateUsdRailgunHeads(
        read: () async => 'h${++reads}',
        now: () => clock,
      );
      expect(await Future.wait([shared.read(), shared.read()]), ['h1', 'h1']);
      expect(await shared.read(), 'h1');
      clock = clock.add(PrivateUsdBalanceTiming.headPoll);
      expect(await shared.read(), 'h2');
      expect(shared.latest, 'h2');
      expect(reads, 2);
    });
  });

  group('a watched balance', () {
    late _Page page;
    late DateTime clock;
    late PrivateUsdRailgunHeads heads;
    String? head;
    var headReads = 0;

    ProviderContainer containerWith({
      String? balances,
      CachedPrivateUsdBalances? cached,
    }) {
      page = _Page(balances ?? _dollarsJson);
      clock = DateTime(2026, 11, 15, 9);
      head = 'h1';
      headReads = 0;
      heads = PrivateUsdRailgunHeads(
        read: () async {
          headReads++;
          return head;
        },
        now: () => clock,
      );
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
          privateUsdCurrentDeploymentProvider.overrideWithValue(_sepolia),
          privateUsdBalanceClockProvider.overrideWithValue(() => clock),
          privateUsdRailgunHeadsProvider.overrideWithValue(heads),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await engine.dispose();
      });
      return container;
    }

    /// [account]'s notifier, watched until the test ends or `close()`.
    ({PrivateUsdBalanceNotifier notifier, void Function() close}) watch(
      ProviderContainer container, [
      String account = _account,
    ]) {
      final subscription = container.listen(
        privateUsdBalanceProvider(account),
        (_, _) {},
      );
      final notifier = container.read(
        privateUsdBalanceProvider(account).notifier,
      );
      final cancel = notifier.watch(ifUsed: false);
      var closed = false;
      void close() {
        if (closed) return;
        closed = true;
        cancel();
        subscription.close();
      }

      addTearDown(close);
      return (notifier: notifier, close: close);
    }

    PrivateUsdBalanceNotifier watched({String? balances}) =>
        watch(containerWith(balances: balances)).notifier;

    Future<void> answer() async {
      await pumpEventQueue();
      page.refreshing!.complete(page.body);
      page.refreshing = null;
      await pumpEventQueue();
    }

    Future<void> fail() async {
      await pumpEventQueue();
      page.refreshing!.completeError(
        RailgunHostException(RailgunHostErrorCode.failed),
      );
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
      final notifier = watched();
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
      final notifier = watched();
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
      final container = containerWith(balances: _arrivingJson);
      final notifier = watch(container).notifier;
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
      final notifier = watched();
      await answer();
      head = null;
      for (var i = 0; i < 5; i++) {
        await poll(notifier);
      }
      expect(page.refreshes, 1);
    });

    test('a refresh that failed tries the same head again, once failures '
        'let it, and asks for no head meanwhile', () async {
      final notifier = watched();
      await answer();
      head = 'h2';
      await poll(notifier);
      expect(page.refreshes, 2);
      await fail();
      final reads = headReads;
      await notifier.pollNow();
      await pumpEventQueue();
      expect(page.refreshes, 2, reason: 'backing off');
      expect(headReads, reads, reason: 'no head asked while backing off');
      await poll(notifier);
      expect(page.refreshes, 3, reason: 'the head the failure began at');
      await answer();
    });

    test("a refresh the user asked for counts for the head it began at, so "
        'the poll after it adds none', () async {
      final notifier = watched();
      await answer();
      head = 'h2';
      await poll(notifier);
      expect(page.refreshes, 2);
      await answer();
      head = 'h3';
      clock = clock.add(PrivateUsdBalanceTiming.headPoll);
      await heads.read();
      notifier.refresh(showProgress: true);
      await answer();
      expect(page.refreshes, 3);
      await poll(notifier);
      expect(page.refreshes, 3, reason: 'the head the user refreshed at');
    });

    test('balances watched together ask for one head, and a rebuilt balance '
        "keeps what its head was", () async {
      final container = containerWith(
        cached: CachedPrivateUsdBalances(
          address: '0zk1account',
          updatedAt: DateTime(2026, 11, 15, 9),
          balances: const RailgunBalances({}),
        ),
      );
      final one = watch(container);
      final other = watch(container, 'other');
      await pumpEventQueue();
      final reads = headReads;
      clock = clock.add(PrivateUsdBalanceTiming.headPoll);
      await Future.wait([one.notifier.pollNow(), other.notifier.pollNow()]);
      await pumpEventQueue();
      expect(headReads, reads + 1);
      expect(page.refreshes, 0, reason: 'the cached balances are fresh');
      // The screen left and opened again: a new notifier, the same head.
      one.close();
      await pumpEventQueue();
      final again = watch(container).notifier;
      await pumpEventQueue();
      await poll(again);
      expect(page.refreshes, 0);
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
