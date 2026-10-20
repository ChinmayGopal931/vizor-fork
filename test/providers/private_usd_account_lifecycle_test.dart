import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/railgun_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_host_channel.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/private_usd_lifecycle_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/src/rust/frb_generated.dart';

import '../features/private_usd/support/fake_private_usd_backend.dart';

// Account deletion and reset with Private USD conversions under way: warn
// and allow, never block a confirmed deletion; drain the engine first;
// remove the account's conversions only after the Rust account delete.
final _rust = _RemovalRustApiFake();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => RustLib.initMock(api: _rust));
  tearDownAll(RustLib.dispose);

  late List<String> events;
  late FakePrivateUsdBackend conversions;
  late PrivateUsdLifecycle lifecycle;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mockRemovalPlatform();
    events = [];
    _rust.reset(events);
    conversions = _LoggingBackend(events)
      ..unfinishedCounts['account-1'] = 1
      ..unfinishedCounts['account-2'] = 2;
    lifecycle = PrivateUsdLifecycle(conversions: conversions);
    lifecycle.register(
      owner: Object(),
      quiesceAndDrain: () async => events.add('drain'),
      resume: () => events.add('resume'),
    );
  });

  Future<ProviderContainer> containerFor({bool unlocked = true}) async {
    final container = ProviderContainer(
      overrides: [
        appBootstrapProvider.overrideWithValue(
          _bootstrap(isUnlocked: unlocked),
        ),
        privateUsdLifecycleProvider.overrideWithValue(lifecycle),
      ],
    );
    addTearDown(container.dispose);
    await container.read(accountProvider.future);
    return container;
  }

  test('deleting an account with unconfirmed conversions under way is refused '
      'after the drain, and deletes nothing', () async {
    final container = await containerFor();

    await expectLater(
      container
          .read(accountProvider.notifier)
          .removeAccount('account-2', confirmedPrivateUsdUnfinishedCount: 0),
      throwsA(
        isA<PrivateUsdUnfinishedConversionsException>().having(
          (e) => e.count,
          'count',
          2,
        ),
      ),
    );

    expect(events, ['drain', 'resume']);
    expect(_rust.deletedAccounts, isEmpty);
    expect(conversions.deleted, isEmpty);
    expect(container.read(accountProvider).value!.accounts.map((a) => a.uuid), [
      'account-1',
      'account-2',
    ]);
  });

  test('more conversions than the user confirmed asks again', () async {
    final container = await containerFor();

    await expectLater(
      container
          .read(accountProvider.notifier)
          .removeAccount('account-2', confirmedPrivateUsdUnfinishedCount: 1),
      throwsA(isA<PrivateUsdUnfinishedConversionsException>()),
    );
    expect(_rust.deletedAccounts, isEmpty);
  });

  test('a confirmed deletion drains the engine first and removes the '
      "account's conversions only after the Rust delete", () async {
    final container = await containerFor();

    await container
        .read(accountProvider.notifier)
        .removeAccount('account-2', confirmedPrivateUsdUnfinishedCount: 2);

    expect(events, [
      'drain',
      'rust-delete account-2',
      'conversions-delete account-2',
      'resume',
    ]);
    expect(container.read(accountProvider).value!.accounts.map((a) => a.uuid), [
      'account-1',
    ]);
  });

  test('a failed Rust delete keeps the conversions', () async {
    _rust.failDelete = true;
    final container = await containerFor();

    await expectLater(
      container
          .read(accountProvider.notifier)
          .removeAccount('account-2', confirmedPrivateUsdUnfinishedCount: 2),
      throwsA(isA<StateError>()),
    );

    expect(conversions.deleted, isEmpty);
    expect(events, ['drain', 'resume']);
  });

  test('an account without conversions is deleted without asking', () async {
    conversions.unfinishedCounts['account-2'] = 0;
    final container = await containerFor();

    await container
        .read(accountProvider.notifier)
        .removeAccount('account-2', confirmedPrivateUsdUnfinishedCount: 0);

    expect(_rust.deletedAccounts, ['account-2']);
    expect(conversions.deleted, ['account-2']);
  });

  test('an unlocked reset with conversions under way is refused unless '
      'confirmed; a locked one only warns', () async {
    final unlocked = await containerFor();

    await expectLater(
      unlocked
          .read(accountProvider.notifier)
          .resetWallet(confirmedPrivateUsdUnfinishedCount: 0),
      throwsA(
        isA<PrivateUsdUnfinishedConversionsException>().having(
          (e) => e.count,
          'count',
          3,
        ),
      ),
    );
    expect(events, ['drain', 'resume']);

    // Locked, the reset goes on past the count (and here fails later, at
    // the wallet path this test does not provide).
    events.clear();
    _failPathProvider();
    final locked = await containerFor(unlocked: false);
    await expectLater(
      locked
          .read(accountProvider.notifier)
          .resetWallet(confirmedPrivateUsdUnfinishedCount: 0),
      throwsA(isNot(isA<PrivateUsdUnfinishedConversionsException>())),
    );
  });

  test('a store that cannot be read asks again without a count, and a '
      'deletion confirmed without one goes ahead', () async {
    conversions.unfinishedCounts.remove('account-2');
    final failing = _LoggingBackend(events)..failCount = true;
    lifecycle = PrivateUsdLifecycle(conversions: failing);
    final container = await containerFor();
    final accounts = container.read(accountProvider.notifier);

    await expectLater(
      accounts.removeAccount(
        'account-2',
        confirmedPrivateUsdUnfinishedCount: 0,
      ),
      throwsA(
        isA<PrivateUsdUnfinishedConversionsException>().having(
          (e) => e.count,
          'count',
          isNull,
        ),
      ),
    );
    expect(_rust.deletedAccounts, isEmpty);

    await accounts.removeAccount('account-2');

    expect(_rust.deletedAccounts, ['account-2']);
  });

  // The account's Railgun wallet leaves the page's storage too. Its mnemonic
  // is derived before the Rust delete (Rust checks the seed against the
  // account), and the page deletes the wallet after it, behind a bridge that
  // reaches nothing. Best effort throughout.
  group("the account's Railgun wallet", () {
    late _PageHost page;
    late _SeedAccounts accounts;

    setUp(() {
      conversions.unfinishedCounts['account-2'] = 0;
      page = _PageHost(events);
    });

    Future<ProviderContainer> walletContainer({bool usedPrivateUsd = true}) {
      FlutterSecureStorage.setMockInitialValues({
        if (usedPrivateUsd) _engineKey: 'stored',
      });
      final container = ProviderContainer(
        overrides: [
          appBootstrapProvider.overrideWithValue(_bootstrap(isUnlocked: true)),
          accountProvider.overrideWith(() => accounts = _SeedAccounts()),
          privateUsdLifecycleProvider.overrideWith((ref) {
            final wallets = PrivateUsdLifecycle(
              host: page,
              conversions: conversions,
              railgunWallets: RailgunEngineWallets(ref.container),
            );
            wallets.register(
              owner: Object(),
              quiesceAndDrain: () async => events.add('drain'),
              resume: () => events.add('resume'),
            );
            return wallets;
          }),
          privateUsdDeploymentProvider.overrideWith((ref, network) => _sepolia),
          railgunHostProvider.overrideWithValue(page),
          railgunBridgeProvider.overrideWithValue(
            RailgunBridge(
              start: () async {
                events.add('bridge start');
                return 4242;
              },
              startOffline: () async {
                events.add('bridge start offline');
                return 4343;
              },
              stop: () async => events.add('bridge stop'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container.read(accountProvider.future).then((_) => container);
    }

    test('is derived before the Rust delete and deleted from the page '
        'after it', () async {
      final container = await walletContainer();

      await container.read(accountProvider.notifier).removeAccount('account-2');

      int at(String event) {
        expect(events, contains(event));
        return events.indexOf(event);
      }

      expect(events.first, 'drain');
      expect(at('derive account-2'), lessThan(at('rust-delete account-2')));
      expect(at('rust-delete account-2'), lessThan(at('bridge start offline')));
      expect(at('bridge start offline'), lessThan(at('page load 4343')));
      expect(at('page load 4343'), lessThan(at('page deleteWallet')));
      expect(events.sublist(at('page deleteWallet') + 1), [
        'page close',
        'bridge stop',
        'resume',
      ]);
      // Nothing routed: the page reaches nothing, and no Tor wait.
      expect(events, isNot(contains('bridge start')));
      expect(jsonDecode(page.deleteParams.single), {
        'network': 'sepolia',
        'mnemonic': 'railgun words of account-2',
      });
      // Rust got the seed; the copy Dart read is zeroed.
      expect(_rust.derivedFrom, [utf8.encode('seed of account-2')]);
      expect(accounts.seedReads.single.every((byte) => byte == 0), isTrue);
      expect(
        await AppSecureStore.instance.readString(_engineKey),
        isNull,
        reason: 'the engine key goes too',
      );
      expect(
        container.read(accountProvider).value!.accounts.map((a) => a.uuid),
        ['account-1'],
      );
    });

    test('an account that never used Private USD derives nothing and loads '
        'no page', () async {
      final container = await walletContainer(usedPrivateUsd: false);

      await container.read(accountProvider.notifier).removeAccount('account-2');

      expect(events, [
        'drain',
        'rust-delete account-2',
        'conversions-delete account-2',
        'resume',
      ]);
      expect(accounts.seedReads, isEmpty);
      expect(_rust.derivedFrom, isEmpty);
    });

    test(
      'a page that fails to delete never fails the account deletion',
      () async {
        page.failDelete = true;
        final container = await walletContainer();

        await container
            .read(accountProvider.notifier)
            .removeAccount('account-2');

        expect(_rust.deletedAccounts, ['account-2']);
        expect(
          container.read(accountProvider).value!.accounts.map((a) => a.uuid),
          ['account-1'],
        );
        expect(events, contains('page deleteWallet'));
        expect(events.sublist(events.length - 3), [
          'page close',
          'bridge stop',
          'resume',
        ]);
      },
    );

    test('a derivation that fails never blocks the deletion', () async {
      _rust.failDerive = true;
      final container = await walletContainer();

      await container.read(accountProvider.notifier).removeAccount('account-2');

      expect(_rust.deletedAccounts, ['account-2']);
      expect(events, isNot(contains('bridge start offline')));
      expect(page.deleteParams, isEmpty);
    });

    test('a failed Rust delete keeps the wallet and loads no page', () async {
      _rust.failDelete = true;
      final container = await walletContainer();

      await expectLater(
        container.read(accountProvider.notifier).removeAccount('account-2'),
        throwsA(isA<StateError>()),
      );

      expect(events, contains('derive account-2'));
      expect(events, isNot(contains('bridge start offline')));
      expect(page.deleteParams, isEmpty);
    });
  });
}

final _engineKey = AppSecureStore.railgunEncryptionKeyStorageKey('account-2');

const _sepolia = ApiDeployment(
  network: 'testnet',
  railgunNetwork: 'sepolia',
  chainId: 11155111,
  token: '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238',
  tokenDecimals: 6,
  keylessRpcUrl: 'https://ethereum-sepolia-rpc.publicnode.com',
  poiNodeUrl: 'https://ppoi.fdi.network/',
  railgunProxy: '0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea',
  relayAdapt: '0x7e3d929EbD5bDC84d02Bd3205c777578f33A214D',
  relayerRailgunAddress: '0zk1relayer',
  allowedHosts: ['ethereum-sepolia-rpc.publicnode.com'],
  explorerTxPrefix: 'https://sepolia.etherscan.io/tx/',
  railscanTxPrefix: 'https://railscan.io/tx/',
  zcashConfirmations: 2,
  escrowConfirmations: 2,
  screeningSeconds: 3600,
  maxRelayerFee: '2000000',
  usdTokens: [],
);

/// The account notifier as built, with each account's seed readable.
class _SeedAccounts extends AccountNotifier {
  final seedReads = <Uint8List>[];

  @override
  Future<Uint8List?> getMnemonicBytesForAccount(String uuid) async {
    final bytes = Uint8List.fromList(utf8.encode('seed of $uuid'));
    seedReads.add(bytes);
    return bytes;
  }
}

/// The page's host: loads, `deleteWallet` and closes, in [log].
class _PageHost implements RailgunHost {
  _PageHost(this.log);

  final List<String> log;
  final deleteParams = <String>[];
  bool failDelete = false;

  @override
  Future<void> load({required int proxyPort, required bool debug}) async =>
      log.add('page load $proxyPort');

  @override
  Future<String> call(String method, String paramsJson) async {
    log.add('page $method');
    if (method != 'deleteWallet') {
      throw RailgunHostException(RailgunHostErrorCode.badArgs);
    }
    deleteParams.add(paramsJson);
    if (failDelete) throw RailgunHostException(RailgunHostErrorCode.failed);
    return 'null';
  }

  @override
  Future<void> close() async => log.add('page close');

  @override
  Future<void> wipe() async => log.add('page wipe');

  @override
  Future<bool> isOpen() async => false;

  @override
  Stream<String> get events => const Stream.empty();
}

class _LoggingBackend extends FakePrivateUsdBackend {
  _LoggingBackend(this.events) : super(records: {});

  final List<String> events;
  bool failCount = false;

  @override
  Future<int> unfinishedCount(String accountUuid) async {
    if (failCount) {
      throw const ApiPrivateUsdError(
        code: ApiPrivateUsdErrorCode.storeUnreadable,
        message: 'unreadable',
      );
    }
    return super.unfinishedCount(accountUuid);
  }

  @override
  Future<void> deleteAccount(String accountUuid) async {
    events.add('conversions-delete $accountUuid');
    await super.deleteAccount(accountUuid);
  }
}

AppBootstrapState _bootstrap({required bool isUnlocked}) {
  final network = kZcashDefaultNetworkName;
  return AppBootstrapState(
    initialLocation: '/home',
    initialAccountState: const AccountState(
      accounts: [
        AccountInfo(uuid: 'account-1', name: 'Primary', order: 0),
        AccountInfo(uuid: 'account-2', name: 'Savings', order: 1),
      ],
      activeAccountUuid: 'account-1',
    ),
    initialSyncSnapshot: AppSyncSnapshot.emptyForAccount('account-1'),
    network: network,
    rpcEndpointConfig: defaultRpcEndpointConfig(network),
    themeMode: ThemeMode.system,
    privacyModeEnabled: false,
    isPasswordConfigured: true,
    isUnlocked: isUnlocked,
    passwordRotationRecoveryFailed: false,
    enhancePirEnabled: false,
  );
}

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void _mockRemovalPlatform() {
  FlutterSecureStorage.setMockInitialValues({});
  final support = Directory.systemTemp.createTempSync('vizor-pusd-removal');
  addTearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProvider, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return support.path;
        }
        throw MissingPluginException('Unexpected path provider call.');
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null),
  );
}

void _failPathProvider() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProvider, (call) async {
        throw PlatformException(code: 'db-path-unavailable');
      });
}

class _RemovalRustApiFake implements RustLibApi {
  List<String> _events = [];
  final deletedAccounts = <String>[];
  final derivedFrom = <List<int>>[];
  bool failDelete = false;
  bool failDerive = false;

  void reset(List<String> events) {
    _events = events;
    deletedAccounts.clear();
    derivedFrom.clear();
    failDelete = false;
    failDerive = false;
  }

  @override
  Future<String> crateApiPrivateUsdPrivateUsdRailgunMnemonic({
    required String dbPath,
    required String network,
    required String accountUuid,
    required List<int> mnemonicBytes,
  }) async {
    // As FRB does, the bytes are copied as the call starts.
    derivedFrom.add(List.of(mnemonicBytes));
    _events.add('derive $accountUuid');
    if (failDerive) throw StateError('the wallet DB is busy');
    return 'railgun words of $accountUuid';
  }

  @override
  Future<String> crateApiWalletGetUnifiedAddress({
    required String dbPath,
    required String network,
    String? accountUuid,
  }) async => 'u1$accountUuid-address';

  @override
  Future<void> crateApiWalletDeleteAccount({
    required String dbPath,
    required String network,
    required String accountUuid,
  }) async {
    if (failDelete) throw StateError('the wallet DB is busy');
    deletedAccounts.add(accountUuid);
    _events.add('rust-delete $accountUuid');
  }

  @override
  Future<void> crateApiSyncDiscardAllKeystoneMigrationRequests() async {}

  @override
  Future<void> crateApiVotingResetVotingSessionState({
    required String dbPath,
    required String accountUuid,
    String? roundId,
  }) async {}

  @override
  Future<int> crateApiVotingDeleteVotingAccountState({
    required String dbPath,
    required String accountUuid,
  }) async => 1;

  @override
  void crateApiSyncSetEnhancePirEnabled({required bool enabled}) {}

  @override
  void crateApiSyncSetEnhancePirPreferenceConfirmed({
    required bool confirmed,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
