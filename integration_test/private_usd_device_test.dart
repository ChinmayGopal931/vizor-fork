@Tags(['mobile', 'private-usd-device'])
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/network_config.dart';
import 'package:zcash_wallet/src/core/config/private_usd_feature_config.dart';
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_balances.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_balance_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/railgun_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_host_channel.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/app_security_provider.dart';
import 'package:zcash_wallet/src/providers/network_privacy_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart' as rust_private_usd;

import 'support/mobile_regtest_flow.dart';

// The Private USD device round (plan §10): the M3 device checks on a physical
// Android phone, against Zcash testnet and Ethereum Sepolia, with no funds.
//
// Run it only through `scripts/private-usd/run_device_round.sh`. The runner
// refuses a phone whose app is not a debuggable build, keeps the screen on,
// wipes the page storage for a true first sync, serves the host checkpoints
// this test calls over `adb reverse` (WebView renderer process, the app UID's
// loopback listeners and sockets, memory, screenshots), samples the phone in
// parallel, and then checks the R8 release build from the host.
//
// It resets this build's testnet wallet and creates a fresh one, whose
// mnemonic is never printed. The `private-usd-device` tag keeps it out of
// `fvm flutter test integration_test/`.
//
// What it checks, in order (later rounds extend it):
//   1. Before first use the home strip shows "—" and no renderer runs.
//   2. `/private-usd` shows the first-sync percentage, then the balance ($0),
//      and the receive address equals the page's wallet and Rust's.
//   3. Tor on: the route change closes the page and stops its bridge; a first
//      sync (page storage wiped) and a refresh through Tor make no direct
//      socket. Tor off: a refresh works direct again.
//   4. Lock closes the page and leaves no loopback listener.
//   5. Unlock: the strip shows the known balance and does not reopen the page.

const _driverUrl = String.fromEnvironment('VIZOR_PUSD_DEVICE_DRIVER_URL');
const _allowReset = bool.fromEnvironment('VIZOR_PUSD_DEVICE_RESET');
const _freshPage = bool.fromEnvironment('VIZOR_PUSD_DEVICE_FRESH_PAGE');
const _torFirstSync = bool.fromEnvironment(
  'VIZOR_PUSD_DEVICE_TOR_FIRST_SYNC',
  defaultValue: true,
);

const _homeBalanceKey = ValueKey('mobile_home_shielded_balance');
const _stripKey = ValueKey('mobile_home_private_usd_strip');
const _stripAmountKey = ValueKey('mobile_home_private_usd_amount');
const _totalKey = ValueKey('mobile_private_usd_total');
const _headlineKey = ValueKey('mobile_private_usd_headline');
const _statusKey = ValueKey('mobile_private_usd_status');
const _errorKey = ValueKey('mobile_private_usd_error');
const _emptyKey = ValueKey('mobile_private_usd_empty');
const _addressKey = ValueKey('mobile_private_usd_address');
const _refreshKey = ValueKey('mobile_private_usd_refresh');

const _firstSyncTimeout = Duration(minutes: 10);
const _refreshTimeout = Duration(minutes: 5);
final _percent = RegExp(r'Loading your private balance: (\d+)%');

void _log(String message) => debugPrint('[pusd-device] $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // A round that died part-way may have left Tor on; this one starts direct.
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(kTorEnabledPreferenceKey, false);
    await initializeZcashWalletRuntime();
  });

  testWidgets('M3: the Private USD balance, Tor and lock on a device', (
    tester,
  ) async {
    tolerateRenderOverflows();
    _requireRoundSetup();
    await _Round(tester).run();
  }, timeout: const Timeout(Duration(minutes: 50)));
}

void _requireRoundSetup() {
  if (!Platform.isAndroid) fail('The Railgun host is Android only.');
  if (kZcashDefaultNetworkName != ZcashNetwork.testnet.name) {
    fail('Run on testnet: --dart-define=ZCASH_DEFAULT_NETWORK=test.');
  }
  if (!kVizorPrivateUsdEnabled) {
    fail('Build with --dart-define=VIZOR_PRIVATE_USD_ENABLED=true.');
  }
  if (kAppFormFactor != AppFormFactor.mobile) {
    fail('Build with --dart-define=VIZOR_FORM_FACTOR=mobile.');
  }
  if (_driverUrl.isEmpty || !_allowReset) {
    fail(
      'Run through scripts/private-usd/run_device_round.sh: it serves the '
      'host checkpoints and allows the testnet wallet reset.',
    );
  }
}

/// A host checkpoint's result (`scripts/private-usd/device_round.py`).
class _Checkpoint {
  _Checkpoint(this.name, this.raw);

  final String name;
  final Map<String, Object?> raw;

  Map<String, Object?> _section(String key) =>
      (raw[key] as Map?)?.cast<String, Object?>() ?? const {};

  bool get rendererRunning => _section('renderer')['running'] == true;

  List<int> get rendererPids => [
    for (final pid in (_section('renderer')['pids'] as List?) ?? const [])
      (pid as num).toInt(),
  ];

  /// Loopback listeners of the app UID other than the Dart VM service.
  Set<int> get otherListenPorts => {
    for (final port in (_section('listen')['other_ports'] as List?) ?? const [])
      (port as num).toInt(),
  };

  Map<String, int>? get socketCounts {
    final counts = _section('sockets')['counts'];
    if (counts is! Map) return null;
    return {
      for (final entry in counts.entries)
        '${entry.key}': (entry.value as num).toInt(),
    };
  }

  int sockets(String kind) => socketCounts?[kind] ?? 0;

  List<String> get socketLines => [
    for (final line in (_section('sockets')['lines'] as List?) ?? const [])
      '$line',
  ];

  @override
  String toString() => '$name: $raw';
}

class _Round {
  _Round(this.tester);

  final WidgetTester tester;
  final _host = const RailgunHostChannel();
  final _results = <String, Object?>{};
  late final ProviderContainer _container;
  late final String _uuid;
  int? _vmServicePort;

  Future<void> run() async {
    _vmServicePort = (await developer.Service.getInfo()).serverUri?.port;
    _log('Dart VM service port on the device: $_vmServicePort');
    await _event('round-start', {
      'vmServicePort': _vmServicePort,
      'freshPage': _freshPage,
      'torFirstSync': _torFirstSync,
    });

    await _resetTestnetWallet();
    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await _createWallet();
    _container = ProviderScope.containerOf(
      tester.element(find.byKey(_homeBalanceKey)),
    );
    _uuid = _container.read(accountProvider).value!.activeAccountUuid!;
    expect(
      _container.read(privateUsdAvailableProvider),
      isTrue,
      reason: 'Private USD must be available for a software testnet account.',
    );

    await _beforeFirstUse();
    await _firstSyncDirect();
    await _torOnThenOff();
    await _lock();
    await _unlock();

    _log('results: $_results');
    await _event('round-end', _results);
  }

  // ── Setup ──────────────────────────────────────────────────────────

  /// Deletes this build's testnet wallet: its secure-storage file, its
  /// wallet DB and the files beside it. Testnet-scoped, so a mainnet wallet
  /// in the same install is never touched. The page storage is the
  /// runner's to wipe (before the app starts, so no WebView loads here).
  Future<void> _resetTestnetWallet() async {
    if (kZcashDefaultNetworkName != ZcashNetwork.testnet.name || !_allowReset) {
      throw StateError('Refusing to reset wallet state outside a round.');
    }
    _log('resetting the testnet wallet state');
    await stopRustWorkForCleanup();
    final storage = AppSecureStore.instance;
    final dbName = await storage.readPlain(kWalletDbNameKey);
    await storage.deleteAll();
    final support = await getWalletSupportDirectory();
    String inSupport(String name) =>
        '${support.path}${Platform.pathSeparator}$name';
    if (dbName != null && dbName.isNotEmpty) {
      for (final suffix in [
        '',
        '-shm',
        '-wal',
        '.voting',
        '.voting-journal',
        '.voting-shm',
        '.voting-wal',
      ]) {
        final file = File(inSupport('$dbName$suffix'));
        if (file.existsSync()) file.deleteSync();
      }
      for (final name in [
        '$dbName.voting-cache',
        '$dbName.tpir',
        'private_usd_${dbName}_${ZcashNetwork.testnet.name}',
      ]) {
        final directory = Directory(inSupport(name));
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    }
    final tokens = File(
      inSupport('private_usd_tokens_${ZcashNetwork.testnet.name}.json'),
    );
    if (tokens.existsSync()) tokens.deleteSync();
  }

  /// Welcome → create → passcode → (biometrics offer) → home. The mnemonic
  /// screens are never captured.
  Future<void> _createWallet() async {
    _log('creating a fresh testnet wallet');
    await tapWidget(tester, const ValueKey('mobile_welcome_get_started'));
    await tapAppButton(tester, const ValueKey('mobile_intro_continue'));
    await tapAppButton(tester, const ValueKey('mobile_address_types_continue'));
    await tapAppButton(
      tester,
      const ValueKey('mobile_things_to_know_continue'),
    );
    await tapAppButton(
      tester,
      const ValueKey('mobile_secret_passphrase_primary'),
    );
    await tapAppButton(
      tester,
      const ValueKey('mobile_secret_passphrase_primary'),
    );
    await tapAppButton(
      tester,
      const ValueKey('mobile_customise_account_continue'),
      timeout: const Duration(minutes: 2),
    );
    await enterPasscode(tester, mobileE2ePasscode);
    await enterPasscode(tester, mobileE2ePasscode);
    final notNow = find.byKey(const ValueKey('mobile_biometrics_not_now'));
    await _waitUntil(
      'the biometrics offer or home',
      () => tester.any(notNow) || tester.any(find.byKey(_homeBalanceKey)),
      timeout: const Duration(minutes: 2),
    );
    if (tester.any(notNow)) {
      await tapWidget(tester, const ValueKey('mobile_biometrics_not_now'));
    }
    await waitForHome(tester);
    _log('wallet created');
  }

  // ── 1. Before first use ────────────────────────────────────────────

  Future<void> _beforeFirstUse() async {
    _log('check 1: before first use');
    await _waitUntil(
      'the Private USD strip',
      () => tester.any(find.byKey(_stripKey)),
      timeout: const Duration(minutes: 1),
    );
    // Long enough for any polling to have started the page.
    final holdUntil = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(holdUntil)) {
      expect(textForKey(tester, _stripAmountKey), PrivateUsdCopy.unknown);
      await _pumpFor(const Duration(milliseconds: 500));
    }
    expect(
      _container.read(railgunEngineStateProvider).phase,
      RailgunEnginePhase.idle,
    );
    expect(await _host.isOpen(), isFalse);
    await _screenshot('m3-01-home-before-first-use');
    final checkpoint = await _checkpoint('before-first-use');
    expect(
      checkpoint.rendererRunning,
      isFalse,
      reason: 'a WebView renderer runs before first use: $checkpoint',
    );
    expect(
      checkpoint.otherListenPorts,
      isEmpty,
      reason: 'a loopback listener before first use: $checkpoint',
    );
    _results['check1_strip'] = PrivateUsdCopy.unknown;
    _results['check1_renderer'] = 'none';
  }

  // ── 2. /private-usd, first sync with Tor off ───────────────────────

  Future<void> _firstSyncDirect() async {
    _log('check 2: /private-usd first sync (Tor off)');
    expect(_container.read(networkPrivacyProvider).torEnabled, isFalse);
    final opened = DateTime.now();
    await tapUntilVisible(
      tester,
      trigger: find.byKey(_stripKey),
      outcome: find.byKey(_totalKey),
      description: '/private-usd',
    );
    final percents = <int>[];
    var sawFirstLoad = false;
    String? status;
    DateTime? erroringSince;
    final zero = formatPrivateUsd(BigInt.zero);
    await _waitUntil(
      'the first balance',
      () {
        final next = textForKey(tester, _statusKey);
        if (next != status) {
          status = next;
          _log('status: $next');
        }
        if (next == PrivateUsdCopy.firstLoad) sawFirstLoad = true;
        final percent = _percent.firstMatch(next ?? '');
        if (percent != null) {
          final value = int.parse(percent.group(1)!);
          if (percents.isEmpty || percents.last != value) percents.add(value);
        }
        if (tester.any(find.byKey(_errorKey))) {
          erroringSince ??= DateTime.now();
          if (DateTime.now().difference(erroringSince!) >
              const Duration(minutes: 2)) {
            fail(
              'the first load kept failing: '
              '${textForKey(tester, _errorKey)} '
              '(engine: ${_container.read(railgunEngineStateProvider).failure})',
            );
          }
        } else {
          erroringSince = null;
        }
        return textForKey(tester, _headlineKey) == zero;
      },
      timeout: _firstSyncTimeout,
      every: const Duration(seconds: 30),
      onTick: (elapsed) async {
        await _checkpoint(
          'first-sync-direct-${elapsed.inSeconds}s',
          checks: const ['renderer', 'listen', 'mem'],
        );
      },
    );
    // The engine stamps a sync when its result arrives; host samples taken
    // while waiting never stretch the figure.
    final synced = _container.read(railgunEngineStateProvider).lastSync;
    final seconds = _seconds((synced?.at ?? DateTime.now()).difference(opened));
    _log('first balance after $seconds s; percentages seen: $percents');
    _results['check2_time_to_first_balance_s'] = seconds;
    _results['check2_first_sync_percents'] = percents;
    _results['check2_first_load_without_percent_seen'] = sawFirstLoad;
    await _event('first-balance-direct', {
      'seconds': seconds,
      'percents': percents,
    });
    if (_freshPage) {
      expect(
        percents,
        isNotEmpty,
        reason: 'a first sync must show its percentage',
      );
    }
    expect(textForKey(tester, _headlineKey), zero);
    expect(tester.any(find.byKey(_emptyKey)), isTrue);

    await _checkAddress();
    await _screenshot('m3-02-private-usd-first-balance');
    final open = await _checkpoint('page-open-direct');
    expect(open.rendererRunning, isTrue, reason: '$open');
    expect(
      open.otherListenPorts,
      hasLength(1),
      reason: 'the open page has exactly one bridge listener: $open',
    );
    _results['check2_bridge_port_direct'] = open.otherListenPorts.single;
  }

  /// The address shown is Rust's derivation for the account, and the page
  /// opened the same wallet (the engine refuses a mismatch, too).
  Future<void> _checkAddress() async {
    await _waitUntil(
      'the receive address',
      () => textForKey(tester, _addressKey) != null,
    );
    final shown = textForKey(tester, _addressKey)!;
    final engine = _container.read(railgunEngineStateProvider);
    final derived = await _rustAddress();
    expect(derived, startsWith('0zk'));
    expect(shown, derived, reason: 'the shown address is not Rust\'s');
    expect(engine.address, derived, reason: 'the page opened another wallet');
    expect(engine.lastSync?.address, derived);
    _log('address: shown == page == Rust (${_short(derived)})');
    _results['check2_address_matches'] = true;
  }

  Future<String> _rustAddress() async {
    final network = _container.read(appBootstrapProvider).network;
    final dbPath = await getWalletDbPath();
    final bytes = await _container
        .read(accountProvider.notifier)
        .getMnemonicBytesForAccount(_uuid);
    if (bytes == null || bytes.isEmpty) fail('the seed is not readable');
    final Future<String> address;
    try {
      // The call copies the bytes as it starts.
      address = rust_private_usd.privateUsdRailgunAddress(
        dbPath: dbPath,
        network: network,
        accountUuid: _uuid,
        mnemonicBytes: bytes,
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
    return address;
  }

  // ── 3. Tor on, then off ────────────────────────────────────────────

  Future<void> _torOnThenOff() async {
    _log('check 3: Tor on');
    final privacy = _container.read(networkPrivacyProvider.notifier);
    final started = DateTime.now();
    unawaited(privacy.setTorEnabled(true));
    await _waitUntil(
      'the route change to close the page',
      () async => !(await _host.isOpen()),
    );
    await _waitUntil('Tor to connect', () {
      final state = _container.read(networkPrivacyProvider);
      if (state.status == NetworkPrivacyConnectionStatus.failed) {
        fail('Tor failed: ${state.error}');
      }
      return state.torEnabled &&
          state.status == NetworkPrivacyConnectionStatus.connected;
    }, timeout: const Duration(minutes: 4));
    final bootstrap = _seconds(DateTime.now().difference(started));
    _log('Tor connected after $bootstrap s');
    _results['check3_tor_bootstrap_s'] = bootstrap;
    await _event('tor-connected', {'seconds': bootstrap});

    // Right after the switch, sockets the direct route opened may still be
    // closing; this sample counts for Railgun hosts only.
    final closed = await _checkpoint('tor-connected-page-closed');
    expect(
      closed.otherListenPorts,
      isEmpty,
      reason: 'the route change must stop the bridge: $closed',
    );
    expect(closed.sockets('railgun-host'), 0, reason: '$closed');
    _results['check3_tor_connected_sample'] = closed.socketCounts;

    final torSamples = <_Checkpoint>[];
    if (_torFirstSync) {
      _log('wiping the page storage for a first sync through Tor');
      await _container.read(railgunEngineProvider).wipe();
      // WebStorage deletes asynchronously; let it finish before the reload.
      await _pumpFor(const Duration(seconds: 10));
      final seconds = await _syncOnce(
        'tor-first-sync',
        timeout: _firstSyncTimeout,
        samples: torSamples,
      );
      _results['check3_tor_first_sync_s'] = seconds;
    }
    final refresh = await _syncOnce(
      'tor-refresh',
      timeout: _refreshTimeout,
      samples: torSamples,
    );
    _results['check3_tor_refresh_s'] = refresh;
    final after = await _checkpoint('tor-after-refresh');
    torSamples.add(after);
    expect(after.rendererRunning, isTrue, reason: '$after');
    expect(after.otherListenPorts, hasLength(1), reason: '$after');
    await _screenshot('m3-03-private-usd-tor');

    // With Tor on, the page's traffic leaves the phone only through Tor.
    final railgunHost = torSamples.fold(
      0,
      (n, s) => n + s.sockets('railgun-host'),
    );
    final unexplained = [
      for (final sample in torSamples)
        if (sample.sockets('unexplained') > 0) sample,
    ];
    final relays = torSamples.fold(0, (n, s) => n + s.sockets('tor-relay'));
    _results['check3_tor_socket_samples'] = torSamples.length;
    _results['check3_tor_railgun_host_total'] = railgunHost;
    _results['check3_tor_unexplained_samples'] = unexplained.length;
    _results['check3_tor_relay_total'] = relays;
    expect(railgunHost, 0, reason: 'a direct Railgun socket with Tor on');
    expect(
      unexplained,
      isEmpty,
      reason:
          'a socket that is neither loopback nor a Tor relay with Tor on: '
          '${[for (final s in unexplained) '${s.name} ${s.socketLines}']}',
    );

    _log('check 3: Tor off');
    final offStarted = DateTime.now();
    unawaited(privacy.setTorEnabled(false));
    await _waitUntil(
      'the route change to close the page',
      () async => !(await _host.isOpen()),
    );
    await _waitUntil('Tor to turn off', () {
      final state = _container.read(networkPrivacyProvider);
      return !state.torEnabled &&
          state.status == NetworkPrivacyConnectionStatus.off;
    }, timeout: const Duration(minutes: 2));
    _results['check3_tor_off_s'] = _seconds(
      DateTime.now().difference(offStarted),
    );
    final directClosed = await _checkpoint(
      'tor-off-page-closed',
      checks: const ['renderer', 'listen', 'mem'],
    );
    expect(directClosed.otherListenPorts, isEmpty, reason: '$directClosed');
    _results['check3_direct_refresh_s'] = await _syncOnce(
      'direct-refresh',
      timeout: _refreshTimeout,
    );
    final direct = await _checkpoint('direct-after-refresh');
    expect(direct.otherListenPorts, hasLength(1), reason: '$direct');
  }

  /// Taps refresh and waits for the engine's next sync of this account,
  /// sampling the host every 30 s into [samples]. A failed sync is retried
  /// twice, each recorded. Returns the seconds the successful one took.
  Future<double> _syncOnce(
    String label, {
    required Duration timeout,
    List<_Checkpoint>? samples,
  }) async {
    for (var attempt = 1; attempt <= 3; attempt++) {
      await _waitUntil(
        'the refresh button to be ready',
        () => !_container.read(privateUsdBalanceProvider(_uuid)).isRefreshing,
        timeout: _refreshTimeout,
      );
      final before = _container.read(railgunEngineStateProvider).lastSync;
      final started = DateTime.now();
      await tester.tap(find.byKey(_refreshKey));
      await tester.pump();
      _log('$label: refresh tapped (attempt $attempt)');
      await _waitUntil(
        '$label to start',
        () =>
            _container.read(privateUsdBalanceProvider(_uuid)).isRefreshing ||
            _container.read(railgunEngineStateProvider).lastSync != before,
        timeout: const Duration(seconds: 10),
      );
      var failed = false;
      DateTime? finished;
      await _waitUntil(
        '$label to finish',
        () {
          final engine = _container.read(railgunEngineStateProvider);
          final sync = engine.lastSync;
          if (sync != null &&
              sync.accountUuid == _uuid &&
              !identical(sync, before) &&
              sync.at.isAfter(started)) {
            finished = sync.at;
            return true;
          }
          if (engine.phase == RailgunEnginePhase.failed &&
              DateTime.now().difference(started) > const Duration(seconds: 3)) {
            failed = true;
            return true;
          }
          return false;
        },
        timeout: timeout,
        every: const Duration(seconds: 30),
        onTick: (elapsed) async {
          final sample = await _checkpoint('$label-${elapsed.inSeconds}s');
          samples?.add(sample);
        },
      );
      final seconds = _seconds(
        (finished ?? DateTime.now()).difference(started),
      );
      if (!failed) {
        _log('$label: synced in $seconds s');
        await _event(label, {'seconds': seconds, 'attempt': attempt});
        return seconds;
      }
      final code = _container.read(railgunEngineStateProvider).failure;
      _log('$label: failed after $seconds s (${code?.name}); retrying');
      await _event('$label-failed', {
        'seconds': seconds,
        'attempt': attempt,
        'code': code?.name,
      });
      _results['${label}_failures'] = attempt;
      await _pumpFor(const Duration(seconds: 5));
    }
    fail('$label failed three times');
  }

  // ── 4. Lock ────────────────────────────────────────────────────────

  Future<void> _lock() async {
    _log('check 4: lock');
    expect(await _host.isOpen(), isTrue, reason: 'the page should be open');
    final before = await _checkpoint(
      'before-lock',
      checks: const ['renderer', 'listen', 'mem'],
    );
    final bridge = before.otherListenPorts;
    expect(bridge, hasLength(1), reason: '$before');

    // The mobile lock sequence (BackgroundAutoLockHost).
    final router = GoRouter.of(tester.element(find.byKey(_totalKey)));
    final locked = DateTime.now();
    _container.read(appSecurityProvider.notifier).lock();
    _container.read(accountProvider.notifier).clearSensitiveStateForLock();
    router.go('/unlock');
    unawaited(
      _container.read(syncProvider.notifier).clearSensitiveStateForLock(),
    );
    await _waitUntil(
      'the page to close on lock',
      () async => !(await _host.isOpen()),
    );
    final closedMs = DateTime.now().difference(locked).inMilliseconds;
    _results['check4_page_closed_after_lock_ms'] = closedMs;
    await _waitUntil(
      'the unlock keypad',
      () => tester.any(find.bySemanticsLabel('Digit 1')),
    );
    // The bridge stops right after the page.
    await _pumpFor(const Duration(seconds: 3));
    final after = await _checkpoint(
      'after-lock',
      checks: const ['renderer', 'listen', 'mem'],
    );
    await _screenshot('m3-04-after-lock');
    expect(
      after.otherListenPorts,
      isEmpty,
      reason: 'a loopback listener survived the lock: $after',
    );
    _results['check4_bridge_port_before_lock'] = bridge.single;
    _results['check4_listeners_after_lock'] = after.otherListenPorts.toList();
    _results['check4_renderer_after_lock'] = after.rendererRunning
        ? 'running ${after.rendererPids}'
        : 'gone';
    await _pumpFor(const Duration(seconds: 20));
    final later = await _checkpoint(
      'after-lock-20s',
      checks: const ['renderer', 'listen', 'mem'],
    );
    expect(later.otherListenPorts, isEmpty, reason: '$later');
    _results['check4_renderer_after_lock_20s'] = later.rendererRunning
        ? 'running ${later.rendererPids}'
        : 'gone';
  }

  // ── 5. Unlock ──────────────────────────────────────────────────────

  Future<void> _unlock() async {
    _log('unlocking');
    await enterPasscode(tester, mobileE2ePasscode);
    await waitForHome(tester);
    await _waitUntil(
      'the strip to show the known balance',
      () =>
          textForKey(tester, _stripAmountKey) == formatPrivateUsd(BigInt.zero),
      timeout: const Duration(minutes: 1),
    );
    // A zero balance is not "in use": the strip must not reopen the page.
    await _pumpFor(const Duration(seconds: 15));
    expect(await _host.isOpen(), isFalse);
    await _screenshot('m3-05-home-after-unlock');
    final home = await _checkpoint(
      'home-after-unlock',
      checks: const ['renderer', 'listen', 'mem'],
    );
    expect(home.otherListenPorts, isEmpty, reason: '$home');
    _results['unlock_strip'] = textForKey(tester, _stripAmountKey);
  }

  // ── Helpers ────────────────────────────────────────────────────────

  Future<_Checkpoint> _checkpoint(
    String name, {
    List<String> checks = const ['renderer', 'listen', 'mem', 'sockets'],
  }) async {
    final raw = await postDriver(
      '/checkpoint',
      {'name': name, 'checks': checks, 'vmServicePort': _vmServicePort},
      baseUrl: _driverUrl,
      timeout: const Duration(minutes: 5),
    );
    final checkpoint = _Checkpoint(name, raw);
    _log(
      'checkpoint $name: renderer=${checkpoint.rendererPids} '
      'listeners=${checkpoint.otherListenPorts} '
      'sockets=${checkpoint.socketCounts}',
    );
    return checkpoint;
  }

  Future<void> _event(String name, Map<String, Object?> data) =>
      postDriver('/event', {'name': name, ...data}, baseUrl: _driverUrl);

  Future<void> _screenshot(String name) async {
    await tester.pump();
    await postDriver('/screenshot', {'name': name}, baseUrl: _driverUrl);
  }

  Future<void> _pumpFor(Duration duration) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Polls [ready] while pumping; every [every] it awaits [onTick] (host
  /// samples). Logs progress every 15 s.
  Future<void> _waitUntil(
    String description,
    FutureOr<bool> Function() ready, {
    Duration timeout = const Duration(seconds: 30),
    Duration? every,
    Future<void> Function(Duration elapsed)? onTick,
  }) async {
    final start = DateTime.now();
    var lastLog = start;
    var lastTick = start;
    while (!await ready()) {
      final now = DateTime.now();
      final elapsed = now.difference(start);
      if (elapsed > timeout) {
        fail(
          'Timed out after ${timeout.inSeconds} s waiting for $description.',
        );
      }
      if (now.difference(lastLog) >= const Duration(seconds: 15)) {
        lastLog = now;
        _log('waiting for $description (${elapsed.inSeconds} s)');
      }
      if (every != null &&
          onTick != null &&
          now.difference(lastTick) >= every) {
        lastTick = now;
        await onTick(elapsed);
      }
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  static double _seconds(Duration duration) =>
      (duration.inMilliseconds / 100).round() / 10;

  static String _short(String address) =>
      '${address.substring(0, 8)}…${address.substring(address.length - 6)}';
}
