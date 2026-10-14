import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/private_usd_lifecycle_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/src/rust/frb_generated.dart';

import '../features/private_usd/support/fake_private_usd_backend.dart';

// Account deletion and reset with Private USD conversions under way (plan
// §3.5, invariant 15; reference §8.4): warn and allow, never block a
// confirmed deletion; drain the engine first; remove the account's
// conversions only after the Rust account delete.
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
      container.read(accountProvider.notifier).removeAccount('account-2'),
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

    await container.read(accountProvider.notifier).removeAccount('account-2');

    expect(_rust.deletedAccounts, ['account-2']);
    expect(conversions.deleted, ['account-2']);
  });

  test('an unlocked reset with conversions under way is refused unless '
      'confirmed; a locked one only warns', () async {
    final unlocked = await containerFor();

    await expectLater(
      unlocked.read(accountProvider.notifier).resetWallet(),
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
      locked.read(accountProvider.notifier).resetWallet(),
      throwsA(isNot(isA<PrivateUsdUnfinishedConversionsException>())),
    );
  });

  test('a store that cannot be read never blocks a deletion', () async {
    conversions.unfinishedCounts.remove('account-2');
    final failing = _LoggingBackend(events)..failCount = true;
    lifecycle = PrivateUsdLifecycle(conversions: failing);
    final container = await containerFor();

    await container.read(accountProvider.notifier).removeAccount('account-2');

    expect(_rust.deletedAccounts, ['account-2']);
  });
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
  bool failDelete = false;

  void reset(List<String> events) {
    _events = events;
    deletedAccounts.clear();
    failDelete = false;
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
