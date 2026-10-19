@Tags(['mobile', 'private-usd-device'])
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zcash_wallet/app.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/network_config.dart';
import 'package:zcash_wallet/src/core/config/private_usd_feature_config.dart';
import 'package:zcash_wallet/src/core/formatting/zec_amount.dart';
import 'package:zcash_wallet/src/core/layout/app_form_factor.dart';
import 'package:zcash_wallet/src/core/storage/app_secure_store.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';
import 'package:zcash_wallet/src/features/address_book/models/address_format_validator.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_balances.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_send.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_receive_address_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_send_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_sender.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_balance_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_convert_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_record_key.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_reverse_amount.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_reverse_funding.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_deposits_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_unfinished_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_spend_status_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/railgun_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_host_channel.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/providers/app_security_provider.dart';
import 'package:zcash_wallet/src/providers/private_usd_lifecycle_provider.dart';
import 'package:zcash_wallet/src/providers/network_privacy_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart' as rust_private_usd;
import 'package:zcash_wallet/src/rust/api/private_usd.dart'
    show
        ApiDepositPass,
        ApiDepositState,
        ApiForwardOutcome,
        ApiForwardPhase,
        ApiProvedSend,
        ApiRailgunSendsTerms,
        ApiReversePhase,
        ApiSendRecord,
        ApiSendState,
        ApiTransactResult;

import 'support/mobile_regtest_flow.dart';

// The Private USD device round (plan §10): the M3 device checks on a physical
// Android phone, against Zcash testnet and Ethereum Sepolia, with no funds.
// On iOS (iOS plan MI3) the same round runs on an iPhone or the simulator
// through `scripts/private-usd/ios/run_device_round.sh`, whose driver
// (`device_round_ios.py`) answers the same checkpoints. A Mac cannot sample
// an iPhone's listeners, per-process sockets or WebKit processes: those come
// back unmeasured, the round then checks the page and its bridge from the app,
// and the runner's packet capture (rvictl) judges the iPhone's sockets.
//
// On Android, run it only through `scripts/private-usd/run_device_round.sh`.
// The runner refuses a phone whose app is not a debuggable build, keeps the
// screen on, wipes the page storage for a true first sync, serves the host
// checkpoints this test calls over `adb reverse` (WebView renderer process,
// the app UID's loopback listeners and sockets, memory, screenshots), samples
// the phone in parallel, and then checks the R8 release build from the host.
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
//
// The M5 round (forward conversion) is opt-in: the runner's `--m5` passes
// VIZOR_PUSD_DEVICE_M5=start, kills the app, then runs it again with
// VIZOR_PUSD_DEVICE_M5=resume. It never resets the wallet: it converts from
// the testnet wallet already on the phone (an earlier round's, unlocked with
// that round's passcode), which needs testnet ZEC (E8).
//   start:  unlock, wait for the wallet to sync, convert
//           VIZOR_PUSD_DEVICE_M5_ZEC through the screens, and stop once the
//           deposit is kept (the runner then force-stops the app mid-
//           confirmation).
//   resume: unlock; the conversion resumes after the kill; a lock uses no
//           key until unlock resumes it; with another account active it
//           keeps advancing; the delete warning shows the count; it reaches
//           Paid.
//
// The M6 round (reverse conversion) is opt-in too: the runner's `--m6`
// passes VIZOR_PUSD_DEVICE_M6=run. It runs after an M5 round left private
// USD in the same wallet, never resets it, and converts
// VIZOR_PUSD_DEVICE_M6_USD dollars back to ZEC through the screens:
//   1. a lock while the page proves the payment pays nothing;
//   2. that unpaid conversion, cancelled, ends CANCELLED;
//   3. a new one is paid, settlement is authorized, and it reaches COMPLETE;
//   4. only with VIZOR_PUSD_DEVICE_M6_REFUND (`--m6-refund`, long refund
//      deadlines): a paid one, cancelled, ends REFUNDED and shows on Refunds.
//
// The M7 round (private send and withdraw) is opt-in as well: the runner's
// `--m7 --m7-to 0x…` passes VIZOR_PUSD_DEVICE_M7=start, kills the app, then
// runs it again with VIZOR_PUSD_DEVICE_M7=resume. It runs after an M5 round
// left private USD in the wallet, never resets it, and moves
// VIZOR_PUSD_DEVICE_M7_USD dollars each time through the screens:
//   start:  1. a send to a second account's 0zk address arrives there, and
//              on Sepolia its output stays Processing (MissingExternalPOI);
//           2. a withdrawal reaches VIZOR_PUSD_DEVICE_M7_TO (a public ERC-20
//              balance the host reads);
//           3. a third send is proved and kept, and its first post is held,
//              so the runner's force-stop kills it between proving and the
//              post.
//   resume: before unlock the log holds that send, kept and never posted;
//           after unlock settlement posts the same kept bytes and it lands,
//           while nothing is proved again.
//
// The M8 route round (plan M8.1) is opt-in too: the runner's `--m8-route`
// passes VIZOR_PUSD_DEVICE_M8_ROUTE, a comma list of its phases (default
// forward,reverse,send). It runs on the wallet earlier rounds funded, never
// resets it, starts with Tor off, reuses the M5, M6 and M7 rounds' screen
// steps and their amounts, and turns Tor on in the middle of each phase:
//   forward: a conversion of VIZOR_PUSD_DEVICE_M5_ZEC, once its claim starts;
//   reverse: a conversion of VIZOR_PUSD_DEVICE_M6_USD back, while the page
//            proves the payment;
//   send:    a send of VIZOR_PUSD_DEVICE_M7_USD to a second account's 0zk
//            address, while the page proves it.
// Each must fail closed: from the flip on, no host sample shows a direct
// socket to a Railgun host, and once Tor has connected none shows a socket
// that is neither loopback nor a Tor relay; a proof the flip cut off pays
// and keeps nothing. Each must then resume and finish over Tor (Paid,
// COMPLETE, the send landed), and Tor goes off again before the next phase.

const _driverUrl = String.fromEnvironment('VIZOR_PUSD_DEVICE_DRIVER_URL');
const _allowReset = bool.fromEnvironment('VIZOR_PUSD_DEVICE_RESET');
const _freshPage = bool.fromEnvironment('VIZOR_PUSD_DEVICE_FRESH_PAGE');
const _torFirstSync = bool.fromEnvironment(
  'VIZOR_PUSD_DEVICE_TOR_FIRST_SYNC',
  defaultValue: true,
);
// '' (the M3 round), 'start' or 'resume'.
const _m5Phase = String.fromEnvironment('VIZOR_PUSD_DEVICE_M5');

/// Opt-in: send this much testnet ZEC from the first account to the second
/// through the real Send screens, then leave the second account active, so a
/// conversion can start there while the first account's is still closing
/// (one conversion per account). It is also a plain testnet send under the
/// wallet's consensus parameters (B-11).
const _fundZec = String.fromEnvironment('VIZOR_PUSD_DEVICE_FUND');
const _m5Zec = String.fromEnvironment(
  'VIZOR_PUSD_DEVICE_M5_ZEC',
  defaultValue: '0.01',
);
// '' or 'run': the M6 round (reverse conversion).
const _m6Phase = String.fromEnvironment('VIZOR_PUSD_DEVICE_M6');
const _m6CompleteOnly = bool.fromEnvironment(
  'VIZOR_PUSD_DEVICE_M6_COMPLETE_ONLY',
);
const _m6FeeMargin = String.fromEnvironment(
  'VIZOR_PUSD_DEVICE_M6_FEE_MARGIN',
  defaultValue: '2.5',
);
const _m6Usd = String.fromEnvironment(
  'VIZOR_PUSD_DEVICE_M6_USD',
  defaultValue: '2',
);
const _m6Refund = bool.fromEnvironment('VIZOR_PUSD_DEVICE_M6_REFUND');
// '', 'start' or 'resume': the M7 round (private send and withdraw).
const _m7Phase = String.fromEnvironment('VIZOR_PUSD_DEVICE_M7');
const _m7Usd = String.fromEnvironment(
  'VIZOR_PUSD_DEVICE_M7_USD',
  defaultValue: '1',
);
const _m7To = String.fromEnvironment('VIZOR_PUSD_DEVICE_M7_TO');

/// Skip the first send and its arrival check (a rerun after it passed spends
/// no further private note on it).
const _m7SkipSend = bool.fromEnvironment('VIZOR_PUSD_DEVICE_M7_SKIP_SEND');

/// Skip the withdrawal and its landing check (a rerun after it passed).
const _m7SkipWithdraw = bool.fromEnvironment(
  'VIZOR_PUSD_DEVICE_M7_SKIP_WITHDRAW',
);
// '' or a comma list of forward, reverse and send: the M8 route round.
/// The deposits round (M9): `run`, the private tUSD each deposit withdraws
/// to the account's own deposit address, and whether a second one follows
/// at the next address.
const _depositsPhase = String.fromEnvironment('VIZOR_PUSD_DEVICE_DEPOSITS');
const _depositsUsd = String.fromEnvironment(
  'VIZOR_PUSD_DEVICE_DEPOSITS_USD',
  defaultValue: '3',
);
const _depositsTwice = bool.fromEnvironment(
  'VIZOR_PUSD_DEVICE_DEPOSITS_TWICE',
);
const _m8Route = String.fromEnvironment('VIZOR_PUSD_DEVICE_M8_ROUTE');
const _m8AllPhases = ['forward', 'reverse', 'send'];
final _m8Phases = [
  for (final phase in _m8Route.split(','))
    if (phase.trim().isNotEmpty) phase.trim(),
];

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
// The sync line's front layer, whose readout carries a first sync's
// percentage (iOS progress VI-19).
const _syncLineKey = ValueKey('mobile_private_usd_sync_front');

const _firstSyncTimeout = Duration(minutes: 10);
const _refreshTimeout = Duration(minutes: 5);
final _percent = RegExp(r'^RAILGUN SYNC (\d+)%$');

/// The text at the sync line's head, as drawn.
String? _syncReadout(WidgetTester tester) {
  final texts = find.descendant(
    of: find.byKey(_syncLineKey),
    matching: find.byType(Text),
  );
  if (!tester.any(texts)) return null;
  return tester.widget<Text>(texts.first).data;
}

void _log(String message) => debugPrint('[pusd-device] $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // A round that died part-way may have left Tor on; this one starts direct.
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(kTorEnabledPreferenceKey, false);
    await initializeZcashWalletRuntime();
  });

  // `--run-skipped` (which the tag needs) lifts `skip:`, so each test picks
  // its round itself.
  testWidgets('M3: the Private USD balance, Tor and lock on a device', (
    tester,
  ) async {
    if (_m5Phase.isNotEmpty ||
        _m6Phase.isNotEmpty ||
        _m7Phase.isNotEmpty ||
        _depositsPhase.isNotEmpty ||
        _m8Route.isNotEmpty) {
      return _log('a conversion, send, deposits or route round: M3 not run');
    }
    tolerateRenderOverflows();
    await _requireRoundSetup();
    await _Round(tester).run();
  }, timeout: const Timeout(Duration(minutes: 50)));

  testWidgets('Fund: send testnet ZEC from the first account to the second', (
    tester,
  ) async {
    if (_fundZec.isEmpty) return _log('not the fund round');
    tolerateRenderOverflows();
    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await pumpUntil(
      tester,
      () => tester.any(find.bySemanticsLabel('Digit 1')),
      description: 'the unlock keypad',
      timeout: const Duration(minutes: 2),
    );
    await enterPasscode(tester, mobileE2ePasscode);
    await waitForHome(tester);
    final firstUuid = await accountUuidAtOrder(0);
    final secondUuid = await accountUuidAtOrder(1);
    await switchAccountTo(tester, secondUuid);
    final secondAddress = await copyShieldedAddress(tester);
    await switchAccountTo(tester, firstUuid);
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(_homeBalanceKey)),
    );
    final spend = parseZecAmount(_fundZec)!;
    await pumpUntil(
      tester,
      () {
        final sync = container.read(syncProvider).value;
        return sync != null &&
            sync.isSyncComplete &&
            sync.spendableBalance >= spend;
      },
      description: 'the first account to sync with $_fundZec ZEC spendable',
      timeout: const Duration(minutes: 10),
    );
    await sendViaWizard(tester, address: secondAddress, amountDigits: _fundZec);
    _log('sent $_fundZec ZEC from the first account to the second');
    await switchAccountTo(tester, secondUuid);
    _log('the second account is active for the next conversion');
  }, timeout: const Timeout(Duration(minutes: 20)));

  testWidgets('M5 (start): a conversion until its deposit is kept', (
    tester,
  ) async {
    if (_m5Phase != 'start') return _log('not the M5 start round');
    tolerateRenderOverflows();
    await _requireM5Setup();
    await _M5Round(tester).start();
  }, timeout: const Timeout(Duration(minutes: 40)));

  testWidgets('M5 (resume): kill, lock, account switch, delete warning, Paid', (
    tester,
  ) async {
    if (_m5Phase != 'resume') return _log('not the M5 resume round');
    tolerateRenderOverflows();
    await _requireM5Setup();
    await _M5Round(tester).resume();
  }, timeout: const Timeout(Duration(minutes: 70)));

  testWidgets('M6: reverse conversion, lock mid-proof, cancel, complete', (
    tester,
  ) async {
    if (_m6Phase != 'run') return _log('not the M6 round');
    tolerateRenderOverflows();
    await _requireM6Setup();
    await _M6Round(tester).convertBack();
  }, timeout: Timeout(Duration(minutes: _m6Refund ? 330 : 150)));

  testWidgets('M7 (start): a send arrives, a withdrawal lands, a kept send '
      'is held before its post', (tester) async {
    if (_m7Phase != 'start') return _log('not the M7 start round');
    tolerateRenderOverflows();
    await _requireM7Setup();
    await _M7Round(tester).start();
  }, timeout: const Timeout(Duration(minutes: 120)));

  testWidgets('M7 (resume): the kept send goes out as it was, never proved '
      'again', (tester) async {
    if (_m7Phase != 'resume') return _log('not the M7 resume round');
    tolerateRenderOverflows();
    await _requireM7Setup();
    await _M7Round(tester).resume();
  }, timeout: const Timeout(Duration(minutes: 40)));

  testWidgets('Deposits: private tUSD withdrawn to the account\'s own '
      'deposit address shields back on its own, and the shown address '
      'moves on', (tester) async {
    if (_depositsPhase != 'run') return _log('not the deposits round');
    tolerateRenderOverflows();
    await _requireDepositsSetup();
    await _DepositsRound(tester).run();
  }, timeout: const Timeout(Duration(minutes: 90)));

  testWidgets('M8 (route): a Tor flip mid-claim, mid-funding and mid-send '
      'fails closed and resumes', (tester) async {
    if (_m8Route.isEmpty) return _log('not the M8 route round');
    tolerateRenderOverflows();
    await _requireM8Setup();
    await _M8RouteRound(tester).flip();
  }, timeout: const Timeout(Duration(minutes: 480)));
}

Future<void> _requireM8Setup() async {
  await _requireRailgunHost();
  if (kZcashDefaultNetworkName != ZcashNetwork.testnet.name) {
    fail('Run on testnet: --dart-define=ZCASH_DEFAULT_NETWORK=test.');
  }
  if (!kVizorPrivateUsdEnabled || kAppFormFactor != AppFormFactor.mobile) {
    fail('Build with VIZOR_PRIVATE_USD_ENABLED and VIZOR_FORM_FACTOR=mobile.');
  }
  if (_driverUrl.isEmpty) {
    fail('Run through scripts/private-usd/run_device_round.sh --m8-route.');
  }
  // It converts and sends what earlier rounds left: never the reset round.
  if (_allowReset) fail('An M8 round never resets the wallet.');
  if (_m8Phases.isEmpty || _m8Phases.any((p) => !_m8AllPhases.contains(p))) {
    fail('Bad VIZOR_PUSD_DEVICE_M8_ROUTE: a comma list of $_m8AllPhases.');
  }
  if (_m8Phases.contains('forward') && parseZecAmount(_m5Zec) == null) {
    fail('Bad VIZOR_PUSD_DEVICE_M5_ZEC.');
  }
  if (_m8Phases.contains('reverse') && privateUsdDollarUnits(_m6Usd) == null) {
    fail('Bad VIZOR_PUSD_DEVICE_M6_USD: whole cents, more than zero.');
  }
  if (_m8Phases.contains('send')) {
    final units = privateUsdTokenUnits(_m7Usd, 6);
    if (units == null || units <= BigInt.zero) {
      fail('Bad VIZOR_PUSD_DEVICE_M7_USD: dollars, more than zero.');
    }
  }
}

Future<void> _requireM7Setup() async {
  await _requireRailgunHost();
  if (kZcashDefaultNetworkName != ZcashNetwork.testnet.name) {
    fail('Run on testnet: --dart-define=ZCASH_DEFAULT_NETWORK=test.');
  }
  if (!kVizorPrivateUsdEnabled || kAppFormFactor != AppFormFactor.mobile) {
    fail('Build with VIZOR_PRIVATE_USD_ENABLED and VIZOR_FORM_FACTOR=mobile.');
  }
  if (_driverUrl.isEmpty) {
    fail('Run through scripts/private-usd/run_device_round.sh --m7.');
  }
  // It sends the private USD an M5 round left: never the reset round.
  if (_allowReset) fail('An M7 round never resets the wallet.');
  if (privateUsdTokenUnits(_m7Usd, 6) case final units?
      when units > BigInt.zero) {
    // Fine.
  } else {
    fail('Bad VIZOR_PUSD_DEVICE_M7_USD: dollars, more than zero.');
  }
  if (_m7Phase == 'start' && !isValidEvmAddress(_m7To)) {
    fail('Bad VIZOR_PUSD_DEVICE_M7_TO: a 0x address to withdraw to.');
  }
}

Future<void> _requireDepositsSetup() async {
  await _requireRailgunHost();
  if (kZcashDefaultNetworkName != ZcashNetwork.testnet.name) {
    fail('Run on testnet: --dart-define=ZCASH_DEFAULT_NETWORK=test.');
  }
  if (!kVizorPrivateUsdEnabled || kAppFormFactor != AppFormFactor.mobile) {
    fail('Build with VIZOR_PRIVATE_USD_ENABLED and VIZOR_FORM_FACTOR=mobile.');
  }
  if (_driverUrl.isEmpty) {
    fail('Run through scripts/private-usd/run_device_round.sh --deposits.');
  }
  // It withdraws the private tUSD an M5 round left: never the reset round.
  if (_allowReset) fail('A deposits round never resets the wallet.');
  // The relayer's minimum is 2 tUSD, and the withdrawal pays Railgun 0.25%.
  if (privateUsdTokenUnits(_depositsUsd, 6) case final units?
      when units >= BigInt.from(2100000)) {
    // Fine.
  } else {
    fail('Bad VIZOR_PUSD_DEVICE_DEPOSITS_USD: dollars, at least 2.10.');
  }
}

Future<void> _requireM6Setup() async {
  await _requireRailgunHost();
  if (kZcashDefaultNetworkName != ZcashNetwork.testnet.name) {
    fail('Run on testnet: --dart-define=ZCASH_DEFAULT_NETWORK=test.');
  }
  if (!kVizorPrivateUsdEnabled || kAppFormFactor != AppFormFactor.mobile) {
    fail('Build with VIZOR_PRIVATE_USD_ENABLED and VIZOR_FORM_FACTOR=mobile.');
  }
  if (_driverUrl.isEmpty) {
    fail('Run through scripts/private-usd/run_device_round.sh --m6.');
  }
  // It converts the private USD an M5 round left: never the reset round.
  if (_allowReset) fail('An M6 round never resets the wallet.');
  if (privateUsdDollarUnits(_m6Usd) == null) {
    fail('Bad VIZOR_PUSD_DEVICE_M6_USD: whole cents, more than zero.');
  }
}

Future<void> _requireM5Setup() async {
  await _requireRailgunHost();
  if (kZcashDefaultNetworkName != ZcashNetwork.testnet.name) {
    fail('Run on testnet: --dart-define=ZCASH_DEFAULT_NETWORK=test.');
  }
  if (!kVizorPrivateUsdEnabled || kAppFormFactor != AppFormFactor.mobile) {
    fail('Build with VIZOR_PRIVATE_USD_ENABLED and VIZOR_FORM_FACTOR=mobile.');
  }
  if (_driverUrl.isEmpty) {
    fail('Run through scripts/private-usd/run_device_round.sh --m5.');
  }
  // The M5 round converts real (testnet) funds from the wallet on the phone:
  // it must never be the round that resets that wallet.
  if (_allowReset) fail('An M5 round never resets the wallet.');
  if (parseZecAmount(_m5Zec) == null) fail('Bad VIZOR_PUSD_DEVICE_M5_ZEC.');
}

Future<void> _requireRoundSetup() async {
  await _requireRailgunHost();
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

/// The page needs a host that runs it here: every Android build, or iOS 17
/// and later (iOS plan XI9). The swap engine follows the same rule.
Future<void> _requireRailgunHost() async {
  if (await queryRailgunHostSupported() != true) {
    fail(
      'This device cannot host the Railgun page: it needs Android, or iOS 17 '
      'and later ($defaultTargetPlatform).',
    );
  }
}

/// A host checkpoint's result (`scripts/private-usd/device_round.py`, or
/// `scripts/private-usd/ios/device_round_ios.py` on iOS).
/// Loopback listeners present right after the wallet is created, before any
/// Private USD use (set once by the round): never the Railgun bridge.
Set<int> _baselineListenPorts = <int>{};

/// Opens `/private-usd` from home. A tap while home is still animating in
/// does nothing, so tap until the screen shows.
Future<void> _openPrivateUsdScreen(WidgetTester tester) async {
  // A screen still animating out (after a go-home) would count as shown and
  // then vanish; let any transition finish before looking.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tapUntilVisible(
    tester,
    trigger: find.byKey(const ValueKey('mobile_home_private_usd_strip')),
    outcome: find.byKey(const ValueKey('mobile_private_usd_convert')),
    description: 'the Private USD screen',
    timeout: const Duration(minutes: 2),
  );
}

class _Checkpoint {
  _Checkpoint(this.name, this.raw);

  final String name;
  final Map<String, Object?> raw;

  Map<String, Object?> _section(String key) =>
      (raw[key] as Map?)?.cast<String, Object?>() ?? const {};

  /// Whether the host sampled [key]. A Mac cannot see an iPhone's listeners,
  /// per-process sockets or WebKit processes: the iOS driver marks those
  /// unmeasured, the round checks the page and its bridge from the app
  /// instead, and the round's packet capture judges the iPhone's sockets.
  bool measured(String key) => _section(key)['measured'] != false;

  bool get rendererRunning => _section('renderer')['running'] == true;

  List<int> get rendererPids => [
    for (final pid in (_section('renderer')['pids'] as List?) ?? const [])
      (pid as num).toInt(),
  ];

  /// Loopback listeners of the app UID other than the Dart VM service and
  /// the baseline the round took before any Private USD use.
  Set<int> get otherListenPorts => {
    for (final port in (_section('listen')['other_ports'] as List?) ?? const [])
      if (!_baselineListenPorts.contains((port as num).toInt())) port.toInt(),
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
    final activeAccount = _container.read(accountProvider).value?.activeAccount;
    expect(
      _container.read(privateUsdAvailableProvider),
      isTrue,
      reason:
          'Private USD must be available for a software testnet account '
          '(enabled: $kVizorPrivateUsdEnabled, form factor: $kAppFormFactor, '
          'platform: $defaultTargetPlatform, bootstrap network: '
          '${_container.read(appBootstrapProvider).network}, deployment: '
          '${_container.read(privateUsdCurrentDeploymentProvider) != null}, '
          'kill switch: ${_container.read(privateUsdKillSwitchProvider)}, '
          'account: ${activeAccount != null}, hardware: '
          '${activeAccount?.isHardware}, zip32 index: '
          '${activeAccount?.zip32AccountIndex}).',
    );

    // A debug build holds loopback listeners of its own (Dart's VM service
    // and tooling) before any Private USD use; the release round has none.
    // Every later check counts only listeners that appear after this.
    _baselineListenPorts = (await _checkpoint(
      'baseline',
      checks: const ['listen'],
    )).otherListenPorts;
    _results['baseline_listeners'] = _baselineListenPorts.toList();

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
    // On iOS the page's data store is the app's to remove (a Mac can't reach
    // an iPhone's), and removing it creates no web view. Android's runner
    // wipes app_webview before the app starts.
    if (_freshPage && defaultTargetPlatform == TargetPlatform.iOS) {
      await _host.wipe();
    }
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
      await _pageRunning(checkpoint),
      isFalse,
      reason: 'a WebView renderer runs before first use: $checkpoint',
    );
    expect(
      await _bridgeListeners(checkpoint),
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
        // Before the engine's first report the line reads 0% on a stub.
        final reported =
            _container
                .read(privateUsdBalanceProvider(_uuid))
                .firstSyncPercent !=
            null;
        if (next == PrivateUsdCopy.firstLoad && !reported) sawFirstLoad = true;
        final percent = reported
            ? _percent.firstMatch(_syncReadout(tester) ?? '')
            : null;
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
    expect(await _pageRunning(open), isTrue, reason: '$open');
    final openBridge = await _bridgeListeners(open);
    expect(
      openBridge,
      hasLength(1),
      reason: 'the open page has exactly one bridge listener: $open',
    );
    _results['check2_bridge_port_direct'] = openBridge.single;
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
      await _bridgeListeners(closed),
      isEmpty,
      reason: 'the route change must stop the bridge: $closed',
    );
    expect(closed.sockets('railgun-host'), 0, reason: '$closed');
    _results['check3_tor_connected_sample'] = closed.socketCounts;
    _noteUnsampledSockets('check3_tor_connected_sample', [closed]);

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
    expect(await _pageRunning(after), isTrue, reason: '$after');
    expect(await _bridgeListeners(after), hasLength(1), reason: '$after');
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
    _noteUnsampledSockets('check3_tor_socket_samples', torSamples);
    expect(railgunHost, 0, reason: 'a direct Railgun socket with Tor on');
    expect(
      unexplained,
      isEmpty,
      reason:
          'a socket that is neither loopback nor a Tor relay with Tor on: '
          '${[for (final s in unexplained) '${s.name} ${s.socketLines}']}',
    );

    _log('check 3: Tor off');
    // An iPhone's capture judges sockets between the Tor events.
    await _event('tor-off', const {});
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
    expect(
      await _bridgeListeners(directClosed),
      isEmpty,
      reason: '$directClosed',
    );
    _results['check3_direct_refresh_s'] = await _syncOnce(
      'direct-refresh',
      timeout: _refreshTimeout,
    );
    final direct = await _checkpoint('direct-after-refresh');
    expect(await _bridgeListeners(direct), hasLength(1), reason: '$direct');
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
        // Over Tor a refresh can queue behind the engine's previous use (one
        // use at a time) for well over 10 s.
        timeout: const Duration(seconds: 60),
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
    final bridge = await _bridgeListeners(before);
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
    final afterBridge = await _bridgeListeners(after);
    expect(
      afterBridge,
      isEmpty,
      reason: 'a loopback listener survived the lock: $after',
    );
    _results['check4_bridge_port_before_lock'] = bridge.single;
    _results['check4_listeners_after_lock'] = afterBridge.toList();
    _results['check4_renderer_after_lock'] = await _pageRunning(after)
        ? 'running ${after.rendererPids}'
        : 'gone';
    await _pumpFor(const Duration(seconds: 20));
    final later = await _checkpoint(
      'after-lock-20s',
      checks: const ['renderer', 'listen', 'mem'],
    );
    expect(await _bridgeListeners(later), isEmpty, reason: '$later');
    _results['check4_renderer_after_lock_20s'] = await _pageRunning(later)
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
    expect(await _bridgeListeners(home), isEmpty, reason: '$home');
    _results['unlock_strip'] = textForKey(tester, _stripAmountKey);
  }

  // ── Helpers ────────────────────────────────────────────────────────

  // Every bridge port this round has seen, for the app's own probe.
  final _bridgePorts = <int>{};

  /// Whether the page runs: the host's renderer sample where it can take
  /// one, else the page host's own answer.
  Future<bool> _pageRunning(_Checkpoint checkpoint) async =>
      checkpoint.measured('renderer')
      ? checkpoint.rendererRunning
      : await _host.isOpen();

  /// The loopback listeners the page's bridge adds: the host's sample where
  /// it can take one, else every bridge port this round has seen that still
  /// accepts a connection, probed from the app.
  Future<Set<int>> _bridgeListeners(_Checkpoint checkpoint) async {
    if (checkpoint.measured('listen')) return checkpoint.otherListenPorts;
    final port = _container.read(railgunEngineProvider).bridgePort;
    if (port != null) _bridgePorts.add(port);
    return {
      for (final port in _bridgePorts)
        if (await loopbackAccepts(port)) port,
    };
  }

  /// Notes in the results when the host took no socket sample: the round's
  /// packet capture judges those sockets instead (iPhone).
  void _noteUnsampledSockets(String key, Iterable<_Checkpoint> samples) {
    final unsampled = samples.where((s) => !s.measured('sockets')).length;
    if (unsampled > 0) _results['${key}_unsampled'] = unsampled;
  }

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

/// The M5 device round (forward conversion), in two runs around a kill.
/// Never prints the mnemonic, a txid with an amount, or any secret: the
/// events carry the swap index, phases and timings.
class _M5Round extends _Round {
  _M5Round(super.tester);

  static const _amountKey = ValueKey('mobile_private_usd_convert_amount');
  static const _reviewKey = ValueKey('mobile_private_usd_convert_review');
  static const _convertKey = ValueKey('mobile_private_usd_review_convert');
  static const _screenConvertKey = ValueKey('mobile_private_usd_convert');
  static const _progressKey = ValueKey('mobile_private_usd_progress_list');
  static const _bannerKey = ValueKey('private_usd_conversion_banner');

  late PrivateUsdRecordKey _key;

  PrivateUsdConversionStatus? get _status =>
      _container.read(privateUsdConversionsProvider)[_key];

  /// Unlocks the wallet already on the phone and waits for home.
  Future<void> _openWallet(String phase) async {
    _vmServicePort = (await developer.Service.getInfo()).serverUri?.port;
    await _event('m5-$phase-start', {'zec': _m5Zec});
    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await _waitUntil(
      'the unlock keypad',
      () => tester.any(find.bySemanticsLabel('Digit 1')),
      timeout: const Duration(minutes: 2),
    );
    await enterPasscode(tester, mobileE2ePasscode);
    await waitForHome(tester);
    // The conversion rounds use the second account; an earlier round's
    // account-switch check can leave the first one active.
    final holder = await accountUuidAtOrder(1);
    final active = ProviderScope.containerOf(
      tester.element(find.byKey(_homeBalanceKey)),
    ).read(accountProvider).value?.activeAccountUuid;
    if (active != holder) await switchAccountTo(tester, holder);
    _container = ProviderScope.containerOf(
      tester.element(find.byKey(_homeBalanceKey)),
    );
    _uuid = _container.read(accountProvider).value!.activeAccountUuid!;
    expect(_container.read(privateUsdAvailableProvider), isTrue);
  }

  Future<void> start() async {
    await _openWallet('start');
    final spend = parseZecAmount(_m5Zec)!;
    await _waitUntil('the wallet to sync with $_m5Zec ZEC spendable', () {
      final sync = _container.read(syncProvider).value;
      return sync != null &&
          sync.isSyncComplete &&
          sync.spendableBalance >= spend;
    }, timeout: const Duration(minutes: 20));
    // A conversion a died round left under way is used, not a new one.
    final underWay = privateUsdUnderWayFor(
      _container.read(privateUsdUnfinishedProvider),
      _uuid,
    );
    if (underWay != null) {
      _key = underWay;
      _log('a conversion is already under way: index ${_key.index}');
    } else {
      await _convertThroughTheScreens();
    }
    await _event('m5-accepted', {'index': _key.index});
    final accepted = DateTime.now();
    await _waitUntil(
      'the deposit to be kept',
      () => _status?.record.depositTxid != null || _status?.isUnderWay == false,
      timeout: const Duration(minutes: 15),
      every: const Duration(seconds: 30),
      onTick: (elapsed) async => _log('phase ${_status?.record.phase.name}'),
    );
    await _screenshot('m5-01-deposit-kept');
    await _event('m5-start-end', {
      'index': _key.index,
      'phase': _status?.record.phase.name,
      'depositKeptAfterS': DateTime.now().difference(accepted).inSeconds,
    });
    // The runner force-stops the app now: killed mid-confirmation.
  }

  Future<void> _convertThroughTheScreens() async {
    // One conversion per account: an earlier round's conversion may still be
    // closing (a deposit that never landed ends once its window shuts). The
    // engine advances it in the foreground; wait for it to end first.
    final engine = _container.read(privateUsdEngineProvider);
    final settleBy = DateTime.now().add(const Duration(minutes: 10));
    while ((await engine.loadRecords(_uuid)).any((r) => r.outcome == null)) {
      if (DateTime.now().isAfter(settleBy)) {
        fail('an earlier conversion is still under way after 10 minutes');
      }
      _log('waiting for an earlier conversion to end');
      await _pumpFor(const Duration(seconds: 15));
    }
    // The Convert button waits for the payment guard's first read of the send
    // log, which can take a while after the app starts; a strip tap that
    // lands while home is still animating in does nothing.
    await tapUntilVisible(
      tester,
      trigger: find.byKey(_stripKey),
      outcome: find.byKey(_screenConvertKey),
      description: 'the Private USD screen',
      timeout: const Duration(minutes: 1),
    );
    await tapAppButton(
      tester,
      _screenConvertKey,
      timeout: const Duration(minutes: 3),
    );
    await _waitUntil(
      'the convert screen',
      () => tester.any(find.byKey(_amountKey)),
    );
    await tester.enterText(find.byKey(_amountKey), _m5Zec);
    await tester.pump(const Duration(milliseconds: 100));
    // 700 ms after typing stops, then a price probe and a quote. Without one
    // in time, say why: the screen's convert state names it.
    final quoteDeadline = DateTime.now().add(const Duration(minutes: 2));
    while (!_container.read(privateUsdConvertProvider).canReview) {
      if (DateTime.now().isAfter(quoteDeadline)) {
        final convert = _container.read(privateUsdConvertProvider);
        await _screenshot('m5-00-no-quote');
        fail(
          'no quote to review: quoting=${convert.quoting} '
          'quote=${convert.quote != null} error=${convert.quoteError} '
          'short=${convert.isShort} invalid=${convert.isAmountInvalid} '
          'engineCanRun=${_container.read(privateUsdEngineProvider).canRun} '
          'lifecycle=${WidgetsBinding.instance.lifecycleState} '
          'locked=${_container.read(appSecurityProvider).requiresUnlock} '
          'quiesced=${_container.read(privateUsdLifecycleProvider).isQuiesced}',
        );
      }
      await _pumpFor(const Duration(seconds: 1));
    }
    await tapAppButton(tester, _reviewKey, timeout: const Duration(minutes: 2));
    await _screenshot('m5-00-review');
    await tapAppButton(
      tester,
      _convertKey,
      timeout: const Duration(minutes: 1),
    );
    await _waitUntil(
      'the progress screen',
      () => tester.any(find.byKey(_progressKey)),
      timeout: const Duration(minutes: 3),
    );
    final key = privateUsdUnderWayFor(
      _container.read(privateUsdUnfinishedProvider),
      _uuid,
    );
    expect(key, isNotNull, reason: 'accepted, but nothing is under way');
    _key = key!;
  }

  Future<void> resume() async {
    await _openWallet('resume');
    final engine = _container.read(privateUsdEngineProvider);
    await _waitUntil(
      'the conversion under way to be known',
      () =>
          privateUsdUnderWayFor(
            _container.read(privateUsdUnfinishedProvider),
            _uuid,
          ) !=
          null,
      timeout: const Duration(minutes: 2),
    );
    _key = privateUsdUnderWayFor(
      _container.read(privateUsdUnfinishedProvider),
      _uuid,
    )!;
    // 1. Killed mid-confirmation, it resumes: an advance after the restart.
    await _waitUntil(
      'an advance after the restart',
      () => _status?.checkedAt != null || _status?.isUnderWay == false,
      timeout: const Duration(minutes: 3),
    );
    _results['m5_resumed_phase'] = _status?.record.phase.name;
    // The two short checks first: a swap takes only a few minutes, and the
    // 90 s lock check would otherwise outlast it.
    await _otherAccountKeepsAdvancing();
    await _deleteWarningShowsTheCount();
    await _lockUsesNoKey(engine);
    await _reachesPaid();
    _log('results: $_results');
    await _event('m5-resume-end', _results);
  }

  /// 2. Locked mid-swap, no key is used (no advance runs: each needs the
  /// seed), and unlock resumes it.
  Future<void> _lockUsesNoKey(PrivateUsdEngine engine) async {
    if (_status?.isUnderWay != true) {
      _results['m5_lock'] = 'skipped: ended before the check';
      return;
    }
    final router = GoRouter.of(tester.element(find.byKey(_homeBalanceKey)));
    final before = _status?.checkedAt;
    _container.read(appSecurityProvider.notifier).lock();
    _container.read(accountProvider.notifier).clearSensitiveStateForLock();
    router.go('/unlock');
    unawaited(
      _container.read(syncProvider.notifier).clearSensitiveStateForLock(),
    );
    await _pumpFor(const Duration(seconds: 90));
    expect(engine.canRun, isFalse);
    expect(
      _status?.checkedAt,
      before,
      reason: 'an advance (which reads the seed) ran while locked',
    );
    await enterPasscode(tester, mobileE2ePasscode);
    await waitForHome(tester);
    await _waitUntil(
      'an advance after unlock',
      () =>
          _status?.isUnderWay == false ||
          (_status?.checkedAt?.isAfter(before ?? DateTime(0)) ?? false),
      timeout: const Duration(minutes: 3),
    );
    _results['m5_lock'] = 'no advance while locked; resumed after unlock';
  }

  /// 3. With another account active, the conversion keeps advancing (D14).
  Future<void> _otherAccountKeepsAdvancing() async {
    if (_status?.isUnderWay != true) {
      _results['m5_switch'] = 'skipped: ended before the check';
      return;
    }
    final notifier = _container.read(accountProvider.notifier);
    var other = _container
        .read(accountProvider)
        .value!
        .accounts
        .where((a) => a.uuid != _uuid && !a.isHardware)
        .map((a) => a.uuid)
        .firstOrNull;
    if (other == null) {
      _log('adding a second account for the switch check');
      other = await notifier.createAccount(name: 'Round second');
    }
    await notifier.switchAccount(other);
    await waitForHome(tester);
    final before = _status?.checkedAt;
    await _waitUntil(
      'an advance with the other account active',
      () =>
          _status?.isUnderWay == false ||
          (_status?.checkedAt?.isAfter(before ?? DateTime(0)) ?? false),
      timeout: const Duration(minutes: 3),
    );
    await _screenshot('m5-02-other-account');
    await notifier.switchAccount(_uuid);
    await waitForHome(tester);
    _results['m5_switch'] = 'advanced while another account was active';
  }

  /// 4. Removing the account warns with the number under way, and Cancel
  /// deletes nothing.
  Future<void> _deleteWarningShowsTheCount() async {
    if (_status?.isUnderWay != true) {
      _results['m5_delete_warning'] = 'skipped: ended before the check';
      return;
    }
    final router = GoRouter.of(tester.element(find.byKey(_homeBalanceKey)));
    unawaited(router.push('/accounts'));
    await tapWidget(tester, ValueKey('mobile_accounts_menu_$_uuid'));
    await tapWidget(tester, const ValueKey('mobile_account_menu_remove'));
    await _waitUntil(
      'the removal warning',
      () => tester.any(
        find.byKey(const ValueKey('mobile_account_remove_private_usd')),
      ),
    );
    final count = await _container.read(
      privateUsdUnfinishedCountProvider(_uuid).future,
    );
    expect(count, greaterThanOrEqualTo(1));
    expect(
      find.text(PrivateUsdCopy.deleteUnfinishedBody(count)),
      findsOneWidget,
    );
    await _screenshot('m5-03-delete-warning');
    await tester.tap(find.text('Cancel'));
    await _pumpFor(const Duration(seconds: 2));
    expect(
      _container.read(accountProvider).value!.accounts.map((a) => a.uuid),
      contains(_uuid),
    );
    router.go('/home');
    await waitForHome(tester);
    _results['m5_delete_warning'] = 'showed $count, nothing deleted';
  }

  /// 5. It reaches Paid, watched from its progress screen.
  Future<void> _reachesPaid() async {
    if (_status?.isUnderWay == true) {
      await tapWidget(tester, _bannerKey);
      await _waitUntil(
        'the progress screen',
        () => tester.any(find.byKey(_progressKey)),
      );
    }
    final started = DateTime.now();
    String? phase;
    await _waitUntil(
      'the conversion to end',
      () => _status?.isUnderWay == false,
      timeout: const Duration(minutes: 45),
      every: const Duration(seconds: 30),
      onTick: (elapsed) async {
        final now = _status?.record.phase.name;
        if (now != phase) {
          phase = now;
          await _event('m5-phase', {'phase': now, 'afterS': elapsed.inSeconds});
        }
      },
    );
    await _screenshot('m5-04-ended');
    expect(_status?.record.outcome, ApiForwardOutcome.paid);
    _results['m5_outcome'] = _status?.record.outcome?.name;
    _results['m5_paid_after_resume_s'] = DateTime.now()
        .difference(started)
        .inSeconds;
  }
}

/// The M6 device round (reverse conversion, opt-in), after an M5 round left
/// private USD in the phone's testnet wallet. Never prints the mnemonic, an
/// address, a txid or any secret: the events carry the swap index, phases
/// and timings.
class _M6Round extends _Round {
  _M6Round(super.tester);

  static const _screenConvertKey = ValueKey('mobile_private_usd_convert');
  static const _directionKey = ValueKey('mobile_private_usd_convert_direction');
  static const _amountKey = ValueKey('mobile_private_usd_convert_amount');
  static const _reviewKey = ValueKey('mobile_private_usd_convert_review');
  static const _convertKey = ValueKey('mobile_private_usd_review_convert');
  static const _progressKey = ValueKey('mobile_private_usd_progress_list');
  static const _actionKey = ValueKey('mobile_private_usd_progress_action');
  static const _callOffKey = ValueKey('mobile_private_usd_progress_call_off');
  static const _confirmKey = ValueKey('private_usd_confirm_sheet_confirm');
  static const _bannerKey = ValueKey('private_usd_conversion_banner');
  static const _refundsKey = ValueKey('mobile_private_usd_progress_refunds');

  late PrivateUsdRecordKey _key;

  PrivateUsdReverseStatus? get _status =>
      _container.read(privateUsdReverseConversionsProvider)[_key];

  PrivateUsdFundingState? get _funding =>
      _container.read(privateUsdFundingStatesProvider)[_key];

  ApiReversePhase? get _phase => _status?.record.phase;

  bool get _funded => _status?.record.funded ?? false;

  Future<void> convertBack() async {
    _vmServicePort = (await developer.Service.getInfo()).serverUri?.port;
    await _event('m6-start', {'usd': _m6Usd, 'refund': _m6Refund});
    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await _waitUntil(
      'the unlock keypad',
      () => tester.any(find.bySemanticsLabel('Digit 1')),
      timeout: const Duration(minutes: 2),
    );
    await enterPasscode(tester, mobileE2ePasscode);
    await waitForHome(tester);
    _container = ProviderScope.containerOf(
      tester.element(find.byKey(_homeBalanceKey)),
    );
    _uuid = _container.read(accountProvider).value!.activeAccountUuid!;
    _router = GoRouter.of(tester.element(find.byKey(_homeBalanceKey)));
    expect(_container.read(privateUsdAvailableProvider), isTrue);

    // A paid reverse conversion a died round left under way is followed to
    // the end; there is nothing to wait for in the balance then.
    await _container.read(privateUsdEngineProvider).loadReverseRecords(_uuid);
    await _pumpFor(const Duration(seconds: 2));
    final earlier = privateUsdUnderWayFor(
      _container.read(privateUsdUnfinishedProvider),
      _uuid,
    );
    if (earlier != null && earlier.direction == PrivateUsdDirection.reverse) {
      _key = earlier;
      await _waitUntil(
        'the earlier conversion to load',
        () => _status != null,
        timeout: const Duration(minutes: 1),
      );
      if (_funded || _status?.record.fundingTx != null) {
        _log('following a paid conversion left under way: ${_key.index}');
        _results['m6_lock'] = 'skipped: a paid conversion was under way';
        _results['m6_cancel_before_funding'] =
            'skipped: a paid conversion was under way';
        await _reachesComplete();
        _results['m6_refund'] = 'skipped: a paid conversion was under way';
        _log('results: $_results');
        await _event('m6-end', _results);
        return;
      }
    }
    await _waitForDollars();
    // A died round can leave an unpaid reverse conversion under way, and an
    // account has one conversion at a time: cancel it through its sheet first.
    final leftover = privateUsdUnderWayFor(
      _container.read(privateUsdUnfinishedProvider),
      _uuid,
    );
    if (leftover != null && leftover.direction == PrivateUsdDirection.reverse) {
      _key = leftover;
      await _waitUntil(
        'the leftover conversion to load',
        () => _status != null,
        timeout: const Duration(minutes: 1),
      );
      if (!_funded) {
        _log('cancelling an unpaid conversion left under way: ${_key.index}');
        await _cancelBeforeFunding();
      }
    }
    if (_m6CompleteOnly) {
      _results['m6_lock'] = 'skipped: --m6-complete-only';
      _results['m6_cancel_before_funding'] = 'skipped: --m6-complete-only';
    } else {
      await _lockDuringTheProofPaysNothing();
      await _cancelBeforeFunding();
    }
    await _reachesComplete();
    if (_m6Refund) {
      await _cancelAfterFundingRefunds();
    } else {
      _results['m6_refund'] = 'skipped: not asked for (--m6-refund)';
    }
    _log('results: $_results');
    await _event('m6-end', _results);
  }

  /// The swap token's spendable private balance covers the amount and its
  /// fees (the relayer's at most 2 USDC, Railgun's 0.25 %). From
  /// `/private-usd`, which keeps the balance fresh.
  Future<void> _waitForDollars() async {
    final needed =
        privateUsdDollarUnits(_m6Usd)! + privateUsdDollarUnits(_m6FeeMargin)!;
    await _openPrivateUsdScreen(tester);
    await _waitUntil('$_m6Usd private USD and its fees to be available', () {
      final token = _container
          .read(privateUsdCurrentDeploymentProvider)
          ?.token
          .toLowerCase();
      final assets = _container
          .read(privateUsdBalanceProvider(_uuid))
          .balances
          ?.assets;
      final asset = assets?.where((a) => a.token.address == token);
      return asset != null &&
          asset.isNotEmpty &&
          asset.first.available >= needed;
    }, timeout: const Duration(minutes: 30));
    _goHome();
    await waitForHome(tester);
  }

  // Taken on home: the app's one router, whichever screen shows later.
  late final GoRouter _router;

  void _goHome() => _router.go('/home');

  /// Home → strip → Convert → the direction toggle → the dollars → Review →
  /// Convert, which accepts and starts paying; its progress shows.
  Future<void> _convertThroughTheScreens(String check) async {
    // Called from home: a Private USD screen still animating out (after a go
    // home) would count as shown, so let it close first.
    await _waitUntil(
      'the previous Private USD screen to close',
      () => !tester.any(find.byKey(_screenConvertKey)),
      timeout: const Duration(seconds: 30),
    );
    // Tap until the Private USD screen shows: a tap that lands while home is
    // still animating in does nothing.
    await tapUntilVisible(
      tester,
      trigger: find.byKey(_stripKey),
      outcome: find.byKey(_screenConvertKey),
      description: 'the Private USD screen',
      timeout: const Duration(minutes: 1),
    );
    // Convert waits for the payment guard's first read of the send log (one
    // payment at a time), which can take a while after the app starts.
    try {
      await tapAppButton(
        tester,
        _screenConvertKey,
        timeout: const Duration(minutes: 3),
      );
    } on TestFailure {
      final status = _container.read(privateUsdSpendStatusProvider(_uuid));
      await _screenshot('m6-$check-guard');
      fail('Convert never enabled; the payment guard shows ${status.name}');
    }
    await tapWidget(tester, _directionKey);
    await _waitUntil(
      'the reverse convert screen',
      () => tester.any(
        find.byKey(const ValueKey('mobile_private_usd_convert_usd')),
      ),
    );
    await tester.enterText(find.byKey(_amountKey), _m6Usd);
    await tester.pump(const Duration(milliseconds: 100));
    // 700 ms after typing stops: a quote, then the page prices it.
    await tapAppButton(tester, _reviewKey, timeout: const Duration(minutes: 3));
    await _screenshot('m6-$check-review');
    final started = DateTime.now();
    await tapAppButton(
      tester,
      _convertKey,
      timeout: const Duration(minutes: 1),
    );
    await _waitUntil(
      'the reverse progress screen',
      () => tester.any(find.byKey(_progressKey)),
      timeout: const Duration(minutes: 3),
    );
    final key = privateUsdUnderWayFor(
      _container.read(privateUsdUnfinishedProvider),
      _uuid,
    );
    expect(key, isNotNull, reason: 'accepted, but nothing is under way');
    expect(key!.direction, PrivateUsdDirection.reverse);
    _key = key;
    await _event('m6-accepted', {
      'check': check,
      'index': _key.index,
      'afterS': DateTime.now().difference(started).inSeconds,
    });
  }

  /// 1. Locked while the page proves the payment: the proof is dropped and
  /// nothing is paid, then or after unlock.
  Future<void> _lockDuringTheProofPaysNothing() async {
    await _convertThroughTheScreens('lock');
    // Lock the moment the proof starts: on a fast phone it takes seconds.
    final proofBy = DateTime.now().add(const Duration(minutes: 5));
    while (_funding?.stage != PrivateUsdFundingStage.proving &&
        !_funded &&
        _status?.record.fundingTx == null) {
      if (DateTime.now().isAfter(proofBy)) {
        fail('Timed out after 5 minutes waiting for the payment proof.');
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (_funded ||
        _status?.record.fundingTx != null ||
        _funding?.stage != PrivateUsdFundingStage.proving) {
      _results['m6_lock'] = 'skipped: the proof finished before the lock';
      return;
    }
    await _screenshot('m6-01-proving');
    _container.read(appSecurityProvider.notifier).lock();
    _container.read(accountProvider.notifier).clearSensitiveStateForLock();
    _router.go('/unlock');
    unawaited(
      _container.read(syncProvider.notifier).clearSensitiveStateForLock(),
    );
    // Longer than a proof takes: one that finished would be submitted now.
    await _pumpFor(const Duration(minutes: 3));
    expect(_funded, isFalse, reason: 'a payment was submitted while locked');
    await enterPasscode(tester, mobileE2ePasscode);
    await waitForHome(tester);
    await _pumpFor(const Duration(seconds: 30));
    await _container.read(privateUsdEngineProvider).loadReverseRecords(_uuid);
    expect(_funded, isFalse, reason: 'the dropped proof was paid after unlock');
    expect(_status?.record.fundingTx, isNull);
    expect(_funding?.running ?? false, isFalse);
    _results['m6_lock'] =
        'no payment after a lock mid-proof (phase ${_phase?.name})';
  }

  /// 2. The unpaid conversion, cancelled behind its sheet: CANCELLED.
  Future<void> _cancelBeforeFunding() async {
    // `funded` follows the chain; a payment already kept and posted shows
    // first as the record's funding transaction. Cancelling that one asks
    // for a refund instead (the opt-in refund check covers it).
    if (_funded ||
        _status?.record.fundingTx != null ||
        _status?.isUnderWay != true) {
      _results['m6_cancel_before_funding'] = 'skipped: ${_phase?.name}';
      return;
    }
    // Straight to this conversion's page: home can show more than one
    // conversion banner (a forward one still arriving, say).
    _router.go('/private-usd/conversion/reverse/${_key.index}');
    await _waitUntil(
      'the reverse progress screen',
      () => tester.any(find.byKey(_progressKey)),
    );
    expect(find.text(PrivateUsdCopy.reverseCancel), findsOneWidget);
    await tapAppButton(tester, _callOffKey);
    await tapAppButton(tester, _confirmKey);
    await _waitUntil(
      'the conversion to be cancelled',
      () => _phase == ApiReversePhase.cancelled,
      timeout: const Duration(minutes: 5),
    );
    await _screenshot('m6-02-cancelled');
    expect(_funded, isFalse);
    _results['m6_cancel_before_funding'] = _phase?.name;
    _goHome();
    await waitForHome(tester);
  }

  /// 3. Paid, settlement authorized, COMPLETE. A conversion the lock check
  /// left paid is followed instead of a new one.
  Future<void> _reachesComplete() async {
    final underWay = privateUsdUnderWayFor(
      _container.read(privateUsdUnfinishedProvider),
      _uuid,
    );
    if (underWay != null && underWay.direction == PrivateUsdDirection.reverse) {
      _key = underWay;
      if (!tester.any(find.byKey(_progressKey))) {
        _goHome();
        await waitForHome(tester);
        await tapWidget(tester, _bannerKey);
      }
    } else {
      await _convertThroughTheScreens('complete');
    }
    final started = DateTime.now();
    await _waitUntil(
      'the payment to be kept',
      () => _funded || _status?.isUnderWay == false,
      timeout: const Duration(minutes: 15),
    );
    expect(_funded, isTrue, reason: 'ended ${_phase?.name} before paying');
    await _screenshot('m6-03-paid');
    await _event('m6-paid', {
      'index': _key.index,
      'afterS': DateTime.now().difference(started).inSeconds,
    });
    await _followUntil(
      'settlement to be asked for',
      () =>
          _phase == ApiReversePhase.awaitingReady ||
          _status?.isUnderWay == false,
      timeout: const Duration(minutes: 60),
    );
    // A conversion an earlier run already authorized (or finished) has gone
    // past the ask; only a conversion still asking is authorized here.
    if (_phase == ApiReversePhase.awaitingReady) {
      await _screenshot('m6-04-authorize');
      await tapAppButton(tester, _actionKey);
    } else {
      _log('settlement was authorized earlier: ${_phase?.name}');
    }
    await _followUntil(
      'the conversion to complete',
      () => _status?.isUnderWay == false,
      timeout: const Duration(minutes: 45),
    );
    await _screenshot('m6-05-complete');
    expect(_phase, ApiReversePhase.complete);
    _results['m6_outcome'] = _phase?.name;
    _results['m6_complete_after_s'] = DateTime.now()
        .difference(started)
        .inSeconds;
    _goHome();
    await waitForHome(tester);
  }

  /// 4. Opt-in: a paid conversion, cancelled behind its sheet ("Request
  /// refund"), ends REFUNDED and shows on Refunds.
  Future<void> _cancelAfterFundingRefunds() async {
    await _waitForDollars();
    await _convertThroughTheScreens('refund');
    await _waitUntil(
      'the payment to be kept',
      () => _funded || _status?.isUnderWay == false,
      timeout: const Duration(minutes: 15),
    );
    expect(_funded, isTrue, reason: 'ended ${_phase?.name} before paying');
    expect(find.text(PrivateUsdCopy.reverseRequestRefund), findsOneWidget);
    await tapAppButton(tester, _callOffKey);
    await tapAppButton(tester, _confirmKey);
    final started = DateTime.now();
    await _followUntil(
      'the refund',
      () => _status?.isUnderWay == false,
      timeout: const Duration(hours: 3),
    );
    await _screenshot('m6-06-refunded');
    expect(_phase, ApiReversePhase.refunded);
    _results['m6_refund'] = _phase?.name;
    _results['m6_refunded_after_s'] = DateTime.now()
        .difference(started)
        .inSeconds;
    await tapAppButton(tester, _refundsKey);
    await _waitUntil(
      'the refund on Refunds',
      () => tester.any(find.text(PrivateUsdCopy.refundsOriginalAmount)),
    );
    await _screenshot('m6-07-refunds');
  }

  /// Waits for [done], recording each phase change as an event.
  Future<void> _followUntil(
    String description,
    bool Function() done, {
    required Duration timeout,
  }) async {
    String? phase;
    await _waitUntil(
      description,
      done,
      timeout: timeout,
      every: const Duration(seconds: 30),
      onTick: (elapsed) async {
        final now = _phase?.name;
        if (now != phase) {
          phase = now;
          await _event('m6-phase', {
            'index': _key.index,
            'phase': now,
            'afterS': elapsed.inSeconds,
          });
        }
      },
    );
  }
}

/// The M7 start phase's sends: Rust's, except that once [hold] is set a
/// send's first post never returns and no settlement pass runs, so the
/// runner can kill the app between proving and the post.
class _HoldPostBackend implements PrivateUsdSendBackend {
  _HoldPostBackend(this._inner);

  final PrivateUsdSendBackend _inner;
  var hold = false;
  final held = Completer<String>();

  @override
  Future<ApiRailgunSendsTerms> terms() => _inner.terms();

  @override
  Future<ApiSendRecord> put(
    String accountUuid,
    ApiProvedSend send, {
    required bool Function() stillCurrent,
  }) => _inner.put(accountUuid, send, stillCurrent: stillCurrent);

  @override
  Future<List<ApiSendRecord>> list(String accountUuid) =>
      _inner.list(accountUuid);

  @override
  Future<ApiTransactResult> transact(String accountUuid, String sendId) {
    if (!hold) return _inner.transact(accountUuid, sendId);
    if (!held.isCompleted) held.complete(sendId);
    return Completer<ApiTransactResult>().future;
  }

  @override
  Future<List<ApiSendRecord>> settleAll(String accountUuid) =>
      hold ? _inner.list(accountUuid) : _inner.settleAll(accountUuid);
}

/// Rust's send calls, once the app's provider has made them.
class _LateBackend implements PrivateUsdSendBackend {
  late PrivateUsdSendBackend inner;

  @override
  Future<ApiRailgunSendsTerms> terms() => inner.terms();

  @override
  Future<ApiSendRecord> put(
    String accountUuid,
    ApiProvedSend send, {
    required bool Function() stillCurrent,
  }) => inner.put(accountUuid, send, stillCurrent: stillCurrent);

  @override
  Future<List<ApiSendRecord>> list(String accountUuid) =>
      inner.list(accountUuid);

  @override
  Future<ApiTransactResult> transact(String accountUuid, String sendId) =>
      inner.transact(accountUuid, sendId);

  @override
  Future<List<ApiSendRecord>> settleAll(String accountUuid) =>
      inner.settleAll(accountUuid);
}

/// The M7 resume phase's page: the app's, counting proofs.
class _CountingSendPage implements PrivateUsdSendPage {
  _CountingSendPage(this._inner);

  final PrivateUsdSendPage _inner;

  /// Across rebuilds of the provider.
  static var proofs = 0;

  @override
  Future<RailgunFees> fees(String accountUuid) => _inner.fees(accountUuid);

  @override
  Future<BigInt> broadcasterFee(
    String accountUuid,
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
  ) => _inner.broadcasterFee(accountUuid, transfer, broadcaster);

  @override
  Future<RailgunRelayedProof> prove(
    String accountUuid,
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
    BigInt fee,
  ) {
    proofs++;
    return _inner.prove(accountUuid, transfer, broadcaster, fee);
  }

  @override
  Future<void> sync(String accountUuid) => _inner.sync(accountUuid);
}

/// The M7 device round (private send and withdraw, opt-in), in two runs
/// around a kill, after an M5 round left private USD in the phone's testnet
/// wallet. Never prints the mnemonic, an address, a transaction or any
/// secret: the events carry outcomes, buckets and timings.
class _M7Round extends _Round {
  _M7Round(super.tester, {this.usd = _m7Usd});

  /// Dollars per send and withdrawal (the deposits round withdraws its own).
  final String usd;

  static const _sendKey = ValueKey('mobile_private_usd_send');
  static const _withdrawKey = ValueKey('mobile_private_usd_withdraw');
  static const _amountKey = ValueKey('mobile_private_usd_send_amount');
  static const _recipientKey = ValueKey('mobile_private_usd_send_recipient');
  static const _reviewKey = ValueKey('mobile_private_usd_send_review');
  static const _confirmKey = ValueKey('mobile_private_usd_send_confirm');
  static const _doneKey = ValueKey('mobile_private_usd_send_status_done');
  static const _statusKey = ValueKey('mobile_private_usd_send_status_title');

  late final GoRouter _router;
  late final BigInt _units = privateUsdTokenUnits(usd, 6)!;

  /// What a send needs: its amount and the relayer's fee, at most 2 USDC.
  // The amount plus a fee allowance: real relayer fees are cents, so this is
  // generous without needing the 2 USDC cap (spends leave their change
  // Processing on Sepolia, so spendable dollars run short quickly).
  BigInt get _needed => _units + BigInt.from(750000);

  void _goHome() => _router.go('/home');

  Future<void> _unlockToHome(List<Override> overrides) async {
    _vmServicePort = (await developer.Service.getInfo()).serverUri?.port;
    await tester.pumpWidget(
      await buildBootstrappedZcashWalletApp(overrides: overrides),
    );
    await _waitUntil(
      'the unlock keypad',
      () => tester.any(find.bySemanticsLabel('Digit 1')),
      timeout: const Duration(minutes: 2),
    );
  }

  Future<void> _home() async {
    await enterPasscode(tester, mobileE2ePasscode);
    await waitForHome(tester);
    // The conversion rounds hold their private USD in the second account, and
    // an earlier round's account-switch check can leave the first one active.
    final holder = await accountUuidAtOrder(1);
    if (_activeUuidOf(tester) != holder) {
      await switchAccountTo(tester, holder);
    }
    _container = ProviderScope.containerOf(
      tester.element(find.byKey(_homeBalanceKey)),
    );
    _uuid = _container.read(accountProvider).value!.activeAccountUuid!;
    _router = GoRouter.of(tester.element(find.byKey(_homeBalanceKey)));
    expect(_container.read(privateUsdAvailableProvider), isTrue);
  }

  String? _activeUuidOf(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byKey(_homeBalanceKey)),
  ).read(accountProvider).value?.activeAccountUuid;

  PrivateUsdBalances? _balancesOf(String uuid) =>
      _container.read(privateUsdBalanceProvider(uuid)).balances;

  /// [uuid]'s private USD, freshly synced from `/private-usd`.
  Future<PrivateUsdBalances> _syncedBalances(String uuid) async {
    final before = _container.read(privateUsdBalanceProvider(uuid)).updatedAt;
    // The strip renders a moment after home does, and a tap while home is
    // still animating in does nothing: tap until the screen opens.
    await tapUntilVisible(
      tester,
      trigger: find.byKey(_stripKey),
      outcome: find.byKey(const ValueKey('mobile_private_usd_convert')),
      description: 'the Private USD screen',
      timeout: const Duration(minutes: 2),
    );
    _container.read(privateUsdBalanceProvider(uuid).notifier).refresh();
    await _waitUntil('a fresh private balance', () {
      final state = _container.read(privateUsdBalanceProvider(uuid));
      final at = state.updatedAt;
      return state.balances != null &&
          !state.isRefreshing &&
          at != null &&
          (before == null || at.isAfter(before));
    }, timeout: _firstSyncTimeout);
    return _balancesOf(uuid)!;
  }

  Future<void> _waitForDollars() async {
    final token = _container
        .read(privateUsdCurrentDeploymentProvider)!
        .token
        .toLowerCase();
    await _openPrivateUsdScreen(tester);
    await _waitUntil(
      '${formatPrivateUsdExact(_needed, 6)} to be available',
      () {
        final asset = _balancesOf(
          _uuid,
        )?.assets.where((a) => a.token.address == token).firstOrNull;
        return asset != null && asset.available >= _needed;
      },
      // Spends leave their change Processing on Sepolia; dollars that are not
      // available soon will not be (top up with a conversion).
      timeout: const Duration(minutes: 8),
    );
    _goHome();
    await waitForHome(tester);
  }

  /// Home → strip → Send or Withdraw → amount → recipient → Review →
  /// confirm; returns once the status shows.
  Future<void> _sendThroughTheScreens(
    PrivateUsdSendMode mode,
    String to,
    String check,
  ) async {
    await _openPrivateUsdScreen(tester);
    try {
      await tapAppButton(
        tester,
        mode == PrivateUsdSendMode.private ? _sendKey : _withdrawKey,
        timeout: const Duration(minutes: 2),
      );
    } on TestFailure {
      final balance = _container.read(privateUsdBalanceProvider(_uuid));
      final guard = _container.read(privateUsdSpendStatusProvider(_uuid));
      await _screenshot('m7-$check-no-button');
      fail(
        'the ${mode.name} button never enabled: guard=${guard.name} '
        'balances=${balance.balances != null} '
        'total=${balance.balances?.total} refreshing=${balance.isRefreshing} '
        'active=${_activeUuidOf(tester) == _uuid}',
      );
    }
    await tester.enterText(find.byKey(_amountKey), usd);
    await tester.enterText(find.byKey(_recipientKey), to);
    await tester.pump(const Duration(milliseconds: 300));
    await tapAppButton(tester, _reviewKey, timeout: const Duration(minutes: 1));
    try {
      await _waitUntil(
        'the review',
        () => tester.any(find.byKey(_confirmKey)),
        timeout: const Duration(minutes: 3),
      );
    } on TestFailure {
      final form = _container.read(privateUsdSendProvider(mode));
      await _screenshot('m7-$check-no-review');
      fail('no $check review: phase=${form.phase.name} error=${form.error}');
    }
    await _screenshot('m7-$check-review');
    await tapAppButton(
      tester,
      _confirmKey,
      timeout: const Duration(minutes: 1),
    );
    await _waitUntil(
      'the send status',
      () => tester.any(find.byKey(_statusKey)),
    );
  }

  /// Waits for the outcome on the status screen, then "Done".
  Future<PrivateUsdSendOutcome> _outcome(
    PrivateUsdSendMode mode,
    String check,
  ) async {
    final started = DateTime.now();
    await _waitUntil(
      'the $check outcome',
      () =>
          _container.read(privateUsdSendProvider(mode)).phase !=
          PrivateUsdSendPhase.sending,
      timeout: const Duration(minutes: 15),
    );
    final form = _container.read(privateUsdSendProvider(mode));
    await _screenshot('m7-$check-outcome');
    final outcome = form.outcome;
    await _event('m7-$check', {
      'phase': form.phase.name,
      'outcome': outcome.runtimeType.toString(),
      'afterS': DateTime.now().difference(started).inSeconds,
    });
    expect(
      form.phase,
      PrivateUsdSendPhase.done,
      reason: '$check: nothing was sent (${form.error})',
    );
    await tapAppButton(tester, _doneKey);
    _goHome();
    await waitForHome(tester);
    return outcome!;
  }

  Future<String> _secondAccount() async {
    final notifier = _container.read(accountProvider.notifier);
    final other = _container
        .read(accountProvider)
        .value!
        .accounts
        .where((a) => a.uuid != _uuid && !a.isHardware)
        .map((a) => a.uuid)
        .firstOrNull;
    if (other != null) return other;
    _log('adding a second account to send to');
    return notifier.createAccount(name: 'Round second');
  }

  Future<void> _switchTo(String uuid) async {
    await _container.read(accountProvider.notifier).switchAccount(uuid);
    await waitForHome(tester);
  }

  Future<void> start() async {
    // The app's own send calls, with the hold in front of them.
    final holding = _HoldPostBackend(_LateBackend());
    await _unlockToHome([
      privateUsdSendBackendProvider.overrideWith((ref) {
        (holding._inner as _LateBackend).inner = RustPrivateUsdSendBackend(
          () => privateUsdSwapContextOf(ref),
        );
        return holding;
      }),
    ]);
    await _event('m7-start', {'usd': _m7Usd});
    await _home();
    _container.read(privateUsdSendBackendProvider);

    // 1. A private send to a second account arrives there.
    final other = await _secondAccount();
    final otherAddress = await _container.read(
      privateUsdReceiveAddressProvider(other).future,
    );
    if (_m7SkipSend) {
      _results['m7_send'] = 'skipped: --m7-skip-send';
      _results['m7_arrived'] = 'skipped: --m7-skip-send';
    } else {
      await _switchTo(other);
      final otherBefore = await _syncedBalances(other);
      _goHome();
      await waitForHome(tester);
      await _switchTo(_uuid);
      await _waitForDollars();
      await _sendThroughTheScreens(
        PrivateUsdSendMode.private,
        otherAddress,
        'send',
      );
      final sent = await _outcome(PrivateUsdSendMode.private, 'send');
      _results['m7_send'] = sent.runtimeType.toString();
      await _switchTo(other);
      final arrivedStart = DateTime.now();
      var otherAfter = otherBefore;
      await _waitUntil(
        'the send to arrive at the second account',
        () => otherAfter.total - otherBefore.total >= _units,
        timeout: const Duration(minutes: 30),
        every: const Duration(seconds: 30),
        onTick: (_) async {
          otherAfter = await _syncedBalances(other);
          _goHome();
          await waitForHome(tester);
        },
      );
      // On Sepolia a relayed send's output stays Processing
      // (MissingExternalPOI, reference §6.7 "Screening caveat").
      final processing = otherAfter.processing - otherBefore.processing;
      await _event('m7-arrived', {
        'processing': processing >= _units,
        'afterS': DateTime.now().difference(arrivedStart).inSeconds,
      });
      expect(
        processing >= _units,
        isTrue,
        reason: 'on Sepolia the output should stay Processing',
      );
      _results['m7_arrived'] = 'processing';
      await _switchTo(_uuid);
    }

    // 2. A withdrawal reaches the given address.
    final deployment = _container.read(privateUsdCurrentDeploymentProvider)!;
    Future<BigInt> publicBalance() async {
      final answer = await postDriver('/erc20-balance', {
        'rpc': deployment.keylessRpcUrl,
        'token': deployment.token,
        'address': _m7To,
      }, baseUrl: _driverUrl);
      final balance = answer['balance'];
      if (balance is! String) fail('No balance from the host: $answer');
      return BigInt.parse(balance);
    }

    if (_m7SkipWithdraw) {
      _results['m7_withdraw'] = 'skipped: --m7-skip-withdraw';
      _results['m7_withdraw_landed'] = 'skipped: --m7-skip-withdraw';
    } else {
      final publicBefore = await publicBalance();
      await _waitForDollars();
      await _sendThroughTheScreens(
        PrivateUsdSendMode.withdraw,
        _m7To,
        'withdraw',
      );
      final withdrawn = await _outcome(PrivateUsdSendMode.withdraw, 'withdraw');
      _results['m7_withdraw'] = withdrawn.runtimeType.toString();
      // Railgun keeps 25 bps of what is withdrawn.
      final expected = _units - _units * BigInt.from(25) ~/ BigInt.from(10000);
      final landedStart = DateTime.now();
      var landed = false;
      await _waitUntil(
        'the withdrawal to reach the address',
        () => landed,
        timeout: const Duration(minutes: 20),
        every: const Duration(seconds: 20),
        onTick: (_) async {
          landed = await publicBalance() - publicBefore >= expected;
        },
      );
      await _event('m7-withdraw-landed', {
        'afterS': DateTime.now().difference(landedStart).inSeconds,
      });
      _results['m7_withdraw_landed'] = true;
    }

    // 3. A send proved and kept, whose first post never returns: the
    // runner kills the app here.
    await _waitForDollars();
    holding.hold = true;
    final keptBefore = (await holding.list(_uuid)).length;
    await _sendThroughTheScreens(
      PrivateUsdSendMode.private,
      otherAddress,
      'held',
    );
    final heldId = await holding.held.future.timeout(
      const Duration(minutes: 15),
    );
    final rows = await holding.list(_uuid);
    final kept = rows.where((row) => row.sendId == heldId).single;
    expect(rows.length, keptBefore + 1);
    expect(kept.state, ApiSendState.unconfirmed);
    expect(kept.postedAt, isNull, reason: 'the held send was posted');
    await _screenshot('m7-held');
    await _event('m7-held', {'kept': true});
    _log('results: $_results');
    await _event('m7-start-end', _results);
  }

  Future<void> resume() async {
    await _unlockToHome([
      privateUsdSendPageProvider.overrideWith(
        (ref) => _CountingSendPage(
          RailgunSendPage(ref.watch(railgunEngineProvider)),
        ),
      ),
    ]);
    await _event('m7-resume', {});
    // Before unlock: the send the start phase kept and never posted.
    final container = ProviderScope.containerOf(
      tester.element(find.bySemanticsLabel('Digit 1').first),
    );
    final uuid = container.read(accountProvider).value!.activeAccountUuid!;
    final backend = container.read(privateUsdSendBackendProvider);
    final before = await backend.list(uuid);
    final held = before
        .where(
          (row) =>
              row.state == ApiSendState.unconfirmed && row.postedAt == null,
        )
        .toList();
    expect(held, hasLength(1), reason: 'no kept, unposted send to resume');
    final heldId = held.single.sendId;

    await _home();
    final started = DateTime.now();
    // Unlock settles the log: the kept bytes go out, then land.
    await _waitUntil(
      'the kept send to land',
      () async {
        final rows = await backend.list(_uuid);
        final row = rows.where((r) => r.sendId == heldId).firstOrNull;
        return row?.state == ApiSendState.confirmed;
      },
      timeout: const Duration(minutes: 30),
      every: const Duration(seconds: 30),
      onTick: (_) async {
        await _container.read(privateUsdSenderProvider).settle(_uuid);
      },
    );
    final after = await backend.list(_uuid);
    expect(after.length, before.length, reason: 'another send was kept');
    expect(_CountingSendPage.proofs, 0, reason: 'a kept send was proved again');
    await _event('m7-resumed', {
      'landed': true,
      'afterS': DateTime.now().difference(started).inSeconds,
    });
    _results['m7_kill_resend'] = 'landed from the kept bytes; no new proof';
    _log('results: $_results');
    await _event('m7-end', _results);
  }
}

/// The M8 route round (opt-in, plan M8.1): the Tor route flips in the middle
/// of a forward claim, a reverse funding and a private send, on the wallet
/// earlier rounds funded (never reset). Each phase must fail closed (the
/// host's `check_sockets.py --onionoo`: no direct socket to a Railgun host
/// from the flip on, and nothing but loopback and Tor relays once Tor has
/// connected) and then resume and finish over Tor. It drives the M5, M6 and
/// M7 rounds' screen steps on its own app. Events carry the swap index,
/// phases, steps, outcomes and timings only: never an address, a txid, a URL
/// or a secret.
/// The deposits round (plan M9): private tUSD from the device wallet is
/// withdrawn, through the Withdraw screens, to the account's own shown
/// deposit address; the engine shields it back on its own (signed, kept,
/// posted, mined, believed), and the shown address moves to the next index.
/// With `--deposits-twice`, a second deposit to that next address shields to
/// a note of its own. Events carry indices, states and timings; the
/// transaction hash and the fee are public on Sepolia.
class _DepositsRound extends _M7Round {
  _DepositsRound(super.tester) : super(usd: _depositsUsd);

  /// The active account's last deposit pass that read the chain.
  ApiDepositPass? get _pass {
    final status = _container.read(privateUsdDepositsProvider);
    if (status?.accountUuid != _uuid) return null;
    final pass = status?.pass;
    return pass != null && pass.scanned ? pass : null;
  }

  /// Asks for a pass now and waits for one newer than [after].
  Future<ApiDepositPass> _freshPass(String why, {DateTime? after}) async {
    final since = after ?? DateTime.now();
    _container.read(privateUsdDepositActionsProvider).refresh();
    await _waitUntil(
      why,
      () {
        final status = _container.read(privateUsdDepositsProvider);
        final checked = status?.checkedAt;
        return _pass != null && checked != null && !checked.isBefore(since);
      },
      timeout: const Duration(minutes: 3),
      every: const Duration(seconds: 20),
      onTick: (_) async =>
          _container.read(privateUsdDepositActionsProvider).refresh(),
    );
    return _pass!;
  }

  @override
  Future<void> run() async {
    await _unlockToHome(const []);
    await _event('deposits-start', {
      'usd': _depositsUsd,
      'twice': _depositsTwice,
    });
    await _home();
    expect(
      _container.read(privateUsdDepositsAvailableProvider),
      isTrue,
      reason: 'deposits need the testnet pin and Private USD available',
    );
    final first = await _deposit('first');
    _results['deposit_first'] = first;
    if (_depositsTwice) {
      _results['deposit_second'] = await _deposit('second');
    }
    _log('results: $_results');
    await _event('deposits-end', _results);
  }

  /// One deposit: the shown address read, private tUSD withdrawn to it, the
  /// deposit followed until it landed, and the shown index moved on.
  Future<Map<String, Object?>> _deposit(String which) async {
    await _openPrivateUsdScreen(tester);
    final before = await _freshPass('the $which deposit address');
    final index = before.index;
    final address = before.address;
    expect(isValidEvmAddress(address), isTrue, reason: 'an EIP-55 address');
    expect(
      before.terms,
      isNotNull,
      reason: 'the relayer\'s deposit terms (${before.termsError})',
    );
    await _screenshot('deposits-$which-shown');
    await _event('deposits-$which-shown', {'index': index});
    _goHome();
    await waitForHome(tester);

    // Withdraw to it, as a sender from any wallet would pay it.
    await _waitForDollars();
    await _sendThroughTheScreens(
      PrivateUsdSendMode.withdraw,
      address,
      'deposit-$which',
    );
    await _outcome(PrivateUsdSendMode.withdraw, 'deposit-$which');
    final withdrawn = DateTime.now();

    // The screen's cadence and the engine's follow-ups shield it.
    await _openPrivateUsdScreen(tester);
    var sawSent = false;
    await _waitUntil(
      'the $which deposit to land',
      () {
        final pass = _pass;
        if (pass == null) return false;
        final records = pass.records.where((r) => r.index == index);
        sawSent |= records.any((r) => r.state == ApiDepositState.sent);
        return records.any((r) => r.state == ApiDepositState.landed);
      },
      timeout: const Duration(minutes: 30),
      every: const Duration(seconds: 20),
      onTick: (_) async =>
          _container.read(privateUsdDepositActionsProvider).refresh(),
    );
    final landed = _pass!.records.firstWhere(
      (r) => r.index == index && r.state == ApiDepositState.landed,
    );
    final afterS = DateTime.now().difference(withdrawn).inSeconds;
    await _screenshot('deposits-$which-landed');
    await _event('deposits-$which-landed', {
      'index': index,
      'tx': landed.txHash,
      'fee': landed.fee,
      'arrives': landed.arrives,
      'sawMakingPrivate': sawSent,
      'afterS': afterS,
    });

    // Once its vault is there, the next address is shown.
    final moved = DateTime.now();
    await _waitUntil(
      'the shown deposit address to move past $index',
      () => (_pass?.index ?? index) > index,
      timeout: const Duration(minutes: 5),
      every: const Duration(seconds: 20),
      onTick: (_) async =>
          _container.read(privateUsdDepositActionsProvider).refresh(),
    );
    final after = _pass!;
    expect(after.index, index + 1, reason: 'the next index is shown');
    expect(after.address, isNot(address));
    await _event('deposits-$which-moved', {
      'from': index,
      'to': after.index,
      'afterS': DateTime.now().difference(moved).inSeconds,
    });
    _goHome();
    await waitForHome(tester);
    return {
      'index': index,
      'tx': landed.txHash,
      'fee': landed.fee,
      'arrives': landed.arrives,
      'afterS': afterS,
      'next_index': after.index,
    };
  }
}

class _M8RouteRound extends _Round {
  _M8RouteRound(super.tester);

  late final _M5Round _forward = _M5Round(tester);
  late final _M6Round _reverse = _M6Round(tester);
  late final _M7Round _send = _M7Round(tester);
  late final GoRouter _router;

  // Host samples with Tor on; memory is sample_device.sh's.
  static const _sampleChecks = ['renderer', 'listen', 'sockets'];

  Future<void> flip() async {
    _vmServicePort = (await developer.Service.getInfo()).serverUri?.port;
    await _event('m8-route-start', {
      'phases': _m8Phases,
      'zec': _m5Zec,
      'usd': _m6Usd,
      'sendUsd': _m7Usd,
    });
    await tester.pumpWidget(await buildBootstrappedZcashWalletApp());
    await _waitUntil(
      'the unlock keypad',
      () => tester.any(find.bySemanticsLabel('Digit 1')),
      timeout: const Duration(minutes: 2),
    );
    await enterPasscode(tester, mobileE2ePasscode);
    await waitForHome(tester);
    // M5 funds the second account; its switch check can leave the first
    // active. Use the same funded account as M7 before sharing the context.
    final holder = await accountUuidAtOrder(1);
    final active = ProviderScope.containerOf(
      tester.element(find.byKey(_homeBalanceKey)),
    ).read(accountProvider).value?.activeAccountUuid;
    if (active != holder) await switchAccountTo(tester, holder);
    _container = ProviderScope.containerOf(
      tester.element(find.byKey(_homeBalanceKey)),
    );
    _uuid = _container.read(accountProvider).value!.activeAccountUuid!;
    _router = GoRouter.of(tester.element(find.byKey(_homeBalanceKey)));
    expect(_container.read(privateUsdAvailableProvider), isTrue);
    expect(
      _container.read(networkPrivacyProvider).torEnabled,
      isFalse,
      reason: 'the round starts direct',
    );
    // The M5, M6 and M7 rounds' steps, on this round's app.
    for (final round in <_Round>[_forward, _reverse, _send]) {
      round
        .._container = _container
        .._uuid = _uuid
        .._vmServicePort = _vmServicePort;
    }
    _reverse._router = _router;
    _send._router = _router;

    if (_m8Phases.contains('forward')) await _flipDuringTheClaim();
    if (_m8Phases.contains('reverse')) await _flipDuringTheFunding();
    if (_m8Phases.contains('send')) await _flipDuringTheSend();
    _log('results: $_results');
    await _event('m8-route-end', _results);
  }

  // ── Forward: Tor turns on as the claim starts ──────────────────────

  Future<void> _flipDuringTheClaim() async {
    final m5 = _forward;
    final spend = parseZecAmount(_m5Zec)!;
    PrivateUsdRecordKey? underWay() => privateUsdUnderWayFor(
      _container.read(privateUsdUnfinishedProvider),
      _uuid,
    );
    await _waitUntil('the wallet to sync with $_m5Zec ZEC spendable', () {
      final sync = _container.read(syncProvider).value;
      return sync != null &&
          sync.isSyncComplete &&
          (sync.spendableBalance >= spend || underWay() != null);
    }, timeout: const Duration(minutes: 20));
    // A forward conversion a died round left is followed, not a new one.
    final existing = underWay();
    if (existing == null) {
      await m5._convertThroughTheScreens();
    } else if (existing.direction == PrivateUsdDirection.forward) {
      m5._key = existing;
      _log('forward: index ${existing.index} is already under way');
      await tapWidget(tester, _M5Round._bannerKey);
    } else {
      _requireNothingUnderWay('forward');
    }
    await _event('m8-forward-accepted', {'index': m5._key.index});
    await _waitUntil(
      'the claim to start',
      () =>
          m5._status?.record.phase == ApiForwardPhase.claiming ||
          m5._status?.isUnderWay == false,
      timeout: const Duration(minutes: 60),
      every: const Duration(minutes: 1),
      onTick: (_) async =>
          _log('forward: phase ${m5._status?.record.phase.name}'),
    );
    if (m5._status?.isUnderWay != true) {
      _results['m8_forward'] =
          'skipped: it ended ${m5._status?.record.phase.name} before its '
          'claim was seen';
      await _event('m8-forward-skipped', {'index': m5._key.index});
      await _goHomeAndWait();
      return;
    }
    await _screenshot('m8-forward-1-claiming');
    await _event('m8-forward-flip', {'index': m5._key.index});
    // The step codes seen after the flip: a request the route change cut
    // off fails its step, which the loop retries over Tor.
    final problems = <String>{};
    void noteProblem() {
      final problem = m5._status?.problem;
      if (problem != null) problems.add(problem.name);
    }

    final connected = await _torOn('forward', observe: noteProblem);
    final samples = <_Checkpoint>[];
    await _followOverTor(
      'forward',
      'the conversion to end over Tor',
      () {
        noteProblem();
        return m5._status?.isUnderWay == false;
      },
      phaseName: () => m5._status?.record.phase.name,
      samples: samples,
      timeout: const Duration(minutes: 60),
    );
    await _screenshot('m8-forward-2-ended');
    await _checkTorOnly('forward', connected, samples);
    expect(
      m5._status?.record.outcome,
      ApiForwardOutcome.paid,
      reason: 'the claim did not finish over Tor',
    );
    _results['m8_forward'] = 'paid over Tor after a flip as its claim began';
    _results['m8_forward_problems_after_flip'] = problems.toList();
    await _torOff('forward');
    await _goHomeAndWait();
  }

  // ── Reverse: Tor turns on while the page proves the payment ────────

  Future<void> _flipDuringTheFunding() async {
    final m6 = _reverse;
    await m6._waitForDollars();
    _requireNothingUnderWay('reverse');
    await m6._convertThroughTheScreens('m8');
    // "Convert" goes ahead, accepts and starts paying. The page's proof is
    // the payment's longest step, so the flip lands in it.
    await _waitUntil(
      'the payment proof to start',
      () =>
          m6._funded ||
          m6._funding?.stage == PrivateUsdFundingStage.proving ||
          m6._funding?.error != null,
      timeout: const Duration(minutes: 5),
    );
    final stage = m6._funded
        ? 'paid'
        : (m6._funding?.stage?.name ?? 'not running');
    await _screenshot('m8-reverse-1-flip');
    await _event('m8-reverse-flip', {'index': m6._key.index, 'stage': stage});
    final connected = await _torOn('reverse');
    await _waitUntil(
      'the payment the flip met to stop',
      () => m6._funded || m6._funding?.running != true,
      timeout: const Duration(minutes: 10),
    );
    // A proof the route change cut off is dropped: there is nothing to pay
    // with. One that finished as the route changed is submitted, and from
    // the flip on only through Tor (the samples).
    await _container.read(privateUsdEngineProvider).loadReverseRecords(_uuid);
    _results['m8_reverse_flip'] = m6._funded
        ? '$stage: paid as the route changed'
        : '$stage: cut off, nothing paid';
    // Resumes: "Pay" proves again, on a page reopened over Tor.
    final samples = <_Checkpoint>[];
    var pays = 0;
    Future<void> payAgain() async {
      if (m6._funded ||
          m6._funding?.running == true ||
          m6._phase != ApiReversePhase.awaitingFunding ||
          pays >= 3) {
        return;
      }
      pays++;
      await _event('m8-reverse-pay', {'index': m6._key.index, 'try': pays});
      await _onReverseProgress();
      await tapAppButton(
        tester,
        _M6Round._actionKey,
        timeout: const Duration(minutes: 2),
      );
    }

    await payAgain();
    await _waitUntil(
      'the payment over Tor',
      () => m6._funded || m6._status?.isUnderWay == false,
      timeout: const Duration(minutes: 30),
      every: const Duration(seconds: 30),
      onTick: (elapsed) async {
        samples.add(
          await _checkpoint(
            'm8-reverse-tor-pay-${elapsed.inSeconds}s',
            checks: _sampleChecks,
          ),
        );
        await payAgain();
      },
    );
    expect(
      m6._funded,
      isTrue,
      reason: 'nothing was paid over Tor (${m6._phase?.name})',
    );
    await _screenshot('m8-reverse-2-paid');
    await _event('m8-reverse-paid', {'index': m6._key.index, 'pays': pays});
    await _followOverTor(
      'reverse',
      'settlement to be asked for',
      () =>
          m6._phase == ApiReversePhase.awaitingReady ||
          m6._status?.isUnderWay == false,
      phaseName: () => m6._phase?.name,
      samples: samples,
      timeout: const Duration(minutes: 60),
    );
    expect(m6._phase, ApiReversePhase.awaitingReady);
    await _onReverseProgress();
    await tapAppButton(tester, _M6Round._actionKey);
    await _followOverTor(
      'reverse',
      'the conversion to complete',
      () => m6._status?.isUnderWay == false,
      phaseName: () => m6._phase?.name,
      samples: samples,
      timeout: const Duration(minutes: 45),
    );
    await _screenshot('m8-reverse-3-ended');
    await _checkTorOnly('reverse', connected, samples);
    expect(m6._phase, ApiReversePhase.complete);
    _results['m8_reverse'] = 'complete over Tor after a flip mid-funding';
    _results['m8_reverse_pays'] = pays;
    await _torOff('reverse');
    await _goHomeAndWait();
  }

  /// The reverse conversion's progress screen, through its banner if needed.
  Future<void> _onReverseProgress() async {
    if (tester.any(find.byKey(_M6Round._progressKey))) return;
    await _goHomeAndWait();
    await tapWidget(tester, _M6Round._bannerKey);
    await _waitUntil(
      'the reverse progress screen',
      () => tester.any(find.byKey(_M6Round._progressKey)),
    );
  }

  // ── Send: Tor turns on while the page proves a send ────────────────

  Future<void> _flipDuringTheSend() async {
    final m7 = _send;
    const mode = PrivateUsdSendMode.private;
    PrivateUsdSendForm form() => _container.read(privateUsdSendProvider(mode));
    _requireNothingUnderWay('send');
    final other = await m7._secondAccount();
    final otherAddress = await _container.read(
      privateUsdReceiveAddressProvider(other).future,
    );
    await m7._switchTo(_uuid);
    await m7._waitForDollars();
    final backend = _container.read(privateUsdSendBackendProvider);
    final before = {for (final row in await backend.list(_uuid)) row.sendId};
    await m7._sendThroughTheScreens(mode, otherAddress, 'm8');
    await _waitUntil(
      'the send to prove',
      () =>
          form().step == PrivateUsdSendStep.proving ||
          form().phase != PrivateUsdSendPhase.sending,
      timeout: const Duration(minutes: 5),
    );
    final step = form().phase == PrivateUsdSendPhase.sending
        ? (form().step?.name ?? 'sending')
        : form().phase.name;
    await _event('m8-send-flip', {'step': step});
    final connected = await _torOn('send');
    final samples = <_Checkpoint>[];
    await _waitUntil(
      'the send the flip met to end',
      () => form().phase != PrivateUsdSendPhase.sending,
      timeout: const Duration(minutes: 15),
    );
    await _screenshot('m8-send-1-after-flip');
    if (form().phase == PrivateUsdSendPhase.done) {
      // Kept before the flip: its post or settlement goes over Tor.
      _results['m8_send_flip'] = '$step: kept (${form().outcome.runtimeType})';
    } else {
      // Failed closed: cut off before it was kept, nothing was kept.
      expect(
        form().phase,
        PrivateUsdSendPhase.review,
        reason: 'the cut-off send left its review',
      );
      final kept = {for (final row in await backend.list(_uuid)) row.sendId};
      expect(
        kept.difference(before),
        isEmpty,
        reason: 'a send the route change cut off was kept',
      );
      _results['m8_send_flip'] = '$step: cut off, nothing kept';
      // Resumes: the same review sends it again, over Tor.
      await tapAppButton(
        tester,
        _M7Round._confirmKey,
        timeout: const Duration(minutes: 2),
      );
      await _waitUntil(
        'the send status',
        () => tester.any(find.byKey(_M7Round._statusKey)),
      );
      await _waitUntil(
        'the send over Tor',
        () => form().phase != PrivateUsdSendPhase.sending,
        timeout: const Duration(minutes: 20),
        every: const Duration(seconds: 30),
        onTick: (elapsed) async => samples.add(
          await _checkpoint(
            'm8-send-tor-${elapsed.inSeconds}s',
            checks: _sampleChecks,
          ),
        ),
      );
    }
    final outcome = await m7._outcome(mode, 'm8');
    _results['m8_send_outcome'] = outcome.runtimeType.toString();
    // One payment, one kept proof, and it lands over Tor.
    await _waitUntil(
      'the send to land over Tor',
      () async {
        final rows = await backend.list(_uuid);
        return rows.every((row) => row.state == ApiSendState.confirmed);
      },
      timeout: const Duration(minutes: 30),
      every: const Duration(seconds: 30),
      onTick: (elapsed) async {
        samples.add(
          await _checkpoint(
            'm8-send-tor-landing-${elapsed.inSeconds}s',
            checks: _sampleChecks,
          ),
        );
        await _container.read(privateUsdSenderProvider).settle(_uuid);
      },
    );
    final after = {for (final row in await backend.list(_uuid)) row.sendId};
    expect(
      after.difference(before),
      hasLength(1),
      reason: 'one send must keep exactly one proof',
    );
    await _checkTorOnly('send', connected, samples);
    _results['m8_send'] = 'landed over Tor after a flip mid-proof';
    await _torOff('send');
  }

  // ── Helpers ────────────────────────────────────────────────────────

  Future<void> _goHomeAndWait() async {
    _router.go('/home');
    await waitForHome(tester);
  }

  /// One conversion at a time per account, and the spend guard holds sends
  /// while one is under way; these phases start their own.
  void _requireNothingUnderWay(String phase) {
    final underWay = privateUsdUnderWayFor(
      _container.read(privateUsdUnfinishedProvider),
      _uuid,
    );
    if (underWay != null) {
      fail(
        '$phase: a ${underWay.direction.name} conversion is under way '
        '(index ${underWay.index}); let it finish first (its banner, or the '
        '--m5 or --m6 round).',
      );
    }
  }

  /// Turns Tor on mid-phase. The route change closes the page and stops its
  /// bridge at once; from then on no sample may show a direct socket to a
  /// Railgun host, while Tor connects (sampled every 15 s) or after. Returns
  /// the sample taken as Tor connected.
  Future<_Checkpoint> _torOn(String phase, {void Function()? observe}) async {
    _log('$phase: Tor on');
    final privacy = _container.read(networkPrivacyProvider.notifier);
    final started = DateTime.now();
    unawaited(privacy.setTorEnabled(true));
    await _waitUntil(
      'the route change to close the page',
      () async => !(await _host.isOpen()),
    );
    final connecting = <_Checkpoint>[];
    await _waitUntil(
      'Tor to connect',
      () {
        observe?.call();
        final state = _container.read(networkPrivacyProvider);
        if (state.status == NetworkPrivacyConnectionStatus.failed) {
          fail('Tor failed: ${state.error}');
        }
        return state.torEnabled &&
            state.status == NetworkPrivacyConnectionStatus.connected;
      },
      timeout: const Duration(minutes: 4),
      every: const Duration(seconds: 15),
      onTick: (elapsed) async => connecting.add(
        await _checkpoint(
          'm8-$phase-connecting-${elapsed.inSeconds}s',
          checks: _sampleChecks,
        ),
      ),
    );
    final seconds = _Round._seconds(DateTime.now().difference(started));
    _results['m8_${phase}_tor_connect_s'] = seconds;
    await _event('m8-$phase-tor-connected', {'seconds': seconds});
    final connected = await _checkpoint(
      'm8-$phase-tor-connected',
      checks: _sampleChecks,
    );
    _results['m8_${phase}_connecting_samples'] = connecting.length;
    _noteUnsampledSockets('m8_${phase}_connecting_samples', [
      ...connecting,
      connected,
    ]);
    for (final sample in [...connecting, connected]) {
      expect(
        sample.sockets('railgun-host'),
        0,
        reason: '$phase: a direct Railgun socket after the flip: $sample',
      );
    }
    return connected;
  }

  Future<void> _torOff(String phase) async {
    _log('$phase: Tor off');
    await _event('m8-$phase-tor-off', const {});
    final privacy = _container.read(networkPrivacyProvider.notifier);
    unawaited(privacy.setTorEnabled(false));
    await _waitUntil('Tor to turn off', () {
      final state = _container.read(networkPrivacyProvider);
      return !state.torEnabled &&
          state.status == NetworkPrivacyConnectionStatus.off;
    }, timeout: const Duration(minutes: 2));
  }

  /// Waits for [done] with Tor on, sampling the host every minute into
  /// [samples] and recording each phase change as an event.
  Future<void> _followOverTor(
    String phase,
    String description,
    bool Function() done, {
    required String? Function() phaseName,
    required List<_Checkpoint> samples,
    required Duration timeout,
  }) async {
    String? last;
    await _waitUntil(
      description,
      done,
      timeout: timeout,
      every: const Duration(minutes: 1),
      onTick: (elapsed) async {
        samples.add(
          await _checkpoint(
            'm8-$phase-tor-${elapsed.inSeconds}s',
            checks: _sampleChecks,
          ),
        );
        final now = phaseName();
        if (now != last) {
          last = now;
          await _event('m8-$phase-phase', {
            'phase': now,
            'afterS': elapsed.inSeconds,
          });
        }
      },
    );
  }

  /// With Tor on, the app's traffic leaves the phone only through Tor. The
  /// sample taken as Tor connected counted for Railgun hosts only (sockets
  /// the direct route opened before the flip may still be closing, as in
  /// M3); every later one, and a last one now, must show nothing but
  /// loopback and Tor relays.
  Future<void> _checkTorOnly(
    String phase,
    _Checkpoint connected,
    List<_Checkpoint> samples,
  ) async {
    samples.add(await _checkpoint('m8-$phase-tor-end', checks: _sampleChecks));
    final railgunHost = samples.fold<int>(
      0,
      (n, s) => n + s.sockets('railgun-host'),
    );
    final unexplained = [
      for (final sample in samples)
        if (sample.sockets('unexplained') > 0) sample,
    ];
    _results['m8_${phase}_connected_sample'] = connected.socketCounts;
    _results['m8_${phase}_tor_samples'] = samples.length;
    _results['m8_${phase}_railgun_host_total'] = railgunHost;
    _results['m8_${phase}_unexplained_samples'] = unexplained.length;
    _results['m8_${phase}_tor_relay_total'] = samples.fold<int>(
      0,
      (n, s) => n + s.sockets('tor-relay'),
    );
    _noteUnsampledSockets('m8_${phase}_tor_samples', samples);
    expect(railgunHost, 0, reason: '$phase: a direct Railgun socket, Tor on');
    expect(
      unexplained,
      isEmpty,
      reason:
          '$phase: a socket that is neither loopback nor a Tor relay with '
          'Tor on: ${[for (final s in unexplained) '${s.name} ${s.socketLines}']}',
    );
  }
}
