// Dev-only device harness for the Railgun page: drives it through the Rust
// SOCKS5 bridge, over the channel wrapper and page models the app uses.
// Debug builds only; never part of the app.
//
//   fvm flutter run -t lib/railgun_spike_main.dart \
//     --dart-define=VIZOR_FORM_FACTOR=mobile --dart-define=SPIKE_MODE=direct
//
// SPIKE_MODE: direct | tor | flip (Tor, then the route flips to direct
// mid-sync) | fail (Tor fails while the page is up). SPIKE_MNEMONIC is an
// optional funded Sepolia test wallet's Railgun mnemonic; otherwise a fresh
// one is generated. Lines print with a "[spike]" prefix and never carry a
// secret: no params, no results beyond counts and the public address, and
// page lines with keyed URLs redacted.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/core/config/private_usd_feature_config.dart';
import 'src/core/storage/wallet_paths.dart';
import 'src/features/private_usd/models/railgun_models.dart';
import 'src/features/private_usd/services/railgun_host_channel.dart';
import 'src/rust/api/network_privacy.dart' as np;
import 'src/rust/api/private_usd.dart' as rust_private_usd;
import 'src/rust/api/wallet.dart' as rust_wallet;
import 'src/rust/frb_generated.dart';

const _mode = String.fromEnvironment('SPIKE_MODE', defaultValue: 'direct');
const _givenMnemonic = String.fromEnvironment('SPIKE_MNEMONIC');
// Wipes the page origin first, so a run measures a true first sync.
const _wipeFirst = bool.fromEnvironment('SPIKE_WIPE', defaultValue: true);
const _flipAfter = Duration(
  seconds: int.fromEnvironment('SPIKE_FLIP_AFTER_S', defaultValue: 120),
);

const RailgunHost _host = RailgunHostChannel();

final _lines = ValueNotifier<List<String>>(const []);
final _clock = Stopwatch();
late final rust_private_usd.ApiDeployment _deployment;
late final List<String> _secrets;
double _lastScan = -1;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode) {
    runApp(const _HarnessApp(title: 'Debug builds only'));
    return;
  }
  await RustLib.init();
  runApp(const _HarnessApp(title: 'Railgun harness: $_mode'));
  unawaited(_run());
}

void _log(String line) {
  final seconds = (_clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
  final stamped = '[${seconds}s] $line';
  debugPrint('[spike] $stamped');
  _lines.value = [..._lines.value, stamped];
}

String _since(Duration start) {
  final elapsed = _clock.elapsed - start;
  return '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s';
}

String _describe(Object error) => switch (error) {
  RailgunHostException() =>
    '${error.code.name}: ${error.debugMessage(secrets: _secrets)}',
  _ => redactRailgunMessage('$error', secrets: _secrets),
};

Future<void> _run() async {
  _clock.start();
  _log('mode $_mode');
  // Sepolia, whatever the build's Zcash network: the testnet deployment.
  _deployment = rust_private_usd.privateUsdDeployment(network: 'test')!;
  final keyed = privateUsdKeyedRpcUrl(
    _deployment.railgunNetwork,
    allowedHosts: _deployment.allowedHosts,
  );
  _secrets = [?keyed];
  _log('keyed RPC: ${keyed == null ? 'none' : 'yes'}');
  _host.events.listen(
    _onEvent,
    onError: (Object e) => _log('event stream error: ${e.runtimeType}'),
  );
  if (_wipeFirst) {
    await _host.wipe();
    _log('page storage wiped');
  }
  try {
    switch (_mode) {
      case 'direct':
        await _session(tor: false);
      case 'tor':
        await _session(tor: true);
      case 'flip':
        await _flipRun();
      case 'fail':
        await _failRun();
      default:
        _log('unknown mode');
    }
  } catch (e) {
    _log('run failed: ${_describe(e)}');
  }
  _log('done');
}

Future<void> _enableTor() async {
  final started = _clock.elapsed;
  final status = await np.configureNetworkPrivacy(
    enabled: true,
    torDirectory: await getTorDataDirectoryPath(),
  );
  _log('tor -> $status in ${_since(started)}');
}

/// One page session: bridge, page, `start`, `openWallet`, then `refresh`.
Future<void> _session({required bool tor}) async {
  if (tor) await _enableTor();
  final port = await np.startRailgunBridge();
  _log('bridge on 127.0.0.1:$port');
  await _openPage(port);
  await _timedRefresh();
  // The wait shows whether Chromium drops its pooled sockets by itself.
  await _host.close();
  _log('page closed; waiting 10 s before stopping the bridge');
  await Future<void>.delayed(const Duration(seconds: 10));
  await np.stopRailgunBridge();
  _log('bridge stopped');
}

final String _mnemonic = _givenMnemonic.isNotEmpty
    ? _givenMnemonic
    : rust_wallet.generateMnemonic();
final String _encryptionKey = List.generate(
  32,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

Future<void> _openPage(int port) async {
  final loading = _clock.elapsed;
  await _host.load(proxyPort: port, debug: true);
  _log('page ready in ${_since(loading)}');
  final keyed = _secrets;
  final started = RailgunStartResult.parse(
    jsonDecode(
      await _host.call(
        'start',
        RailgunStartParams(
          network: _deployment.railgunNetwork,
          rpcUrls: [...keyed, _deployment.keylessRpcUrl],
          poiNodeUrls: [_deployment.poiNodeUrl],
          debug: true,
        ).toJson(),
      ),
    ),
  );
  _log('start -> unshield fee ${started.fees.unshieldBasisPoints} bps');
  final opened = RailgunOpenWalletResult.parse(
    jsonDecode(
      await _host.call(
        'openWallet',
        RailgunOpenWalletParams(
          encryptionKey: _encryptionKey,
          mnemonic: _mnemonic,
        ).toJson(),
      ),
    ),
  );
  _log('openWallet -> ${opened.address}');
}

Future<void> _timedRefresh() async {
  final began = _clock.elapsed;
  try {
    final refreshed = RailgunRefresh.parse(
      jsonDecode(await _host.call('refresh', '{}')),
    );
    final held = [
      for (final entry in refreshed.balances.byBucket.entries)
        if (entry.value.any((a) => a.amount > BigInt.zero))
          '${entry.key.wireName}×${entry.value.length}',
    ];
    _log(
      'refresh done in ${_since(began)}: '
      '${held.isEmpty ? 'nothing held' : held.join(', ')}, '
      'screening ${refreshed.screening.wireName}',
    );
  } on RailgunHostException catch (e) {
    _log('refresh failed after ${_since(began)}: ${_describe(e)}');
  }
}

/// Tor on, then the route flips to direct mid-sync. The harness does what the
/// app does: close the page, restart the bridge on the new route, reopen.
Future<void> _flipRun() async {
  await _enableTor();
  var port = await np.startRailgunBridge();
  _log('bridge (tor) on 127.0.0.1:$port');
  await _openPage(port);
  final refresh = _timedRefresh();
  await Future<void>.delayed(_flipAfter);
  _log('flipping the route to direct');
  await np.configureNetworkPrivacy(enabled: false, torDirectory: '');
  final closing = _clock.elapsed;
  await _host.close();
  await np.stopRailgunBridge();
  await refresh;
  _log('the in-flight refresh ended ${_since(closing)} after the close');
  port = await np.startRailgunBridge();
  _log('bridge (direct) on 127.0.0.1:$port');
  await _openPage(port);
  await _timedRefresh();
}

/// Tor fails while the page is up: the page's new connections are refused,
/// never sent direct. The harness then does what the app does (close the
/// page, stop the bridge), and no new bridge starts until Tor works again.
Future<void> _failRun() async {
  await _enableTor();
  final port = await np.startRailgunBridge();
  _log('bridge (tor) on 127.0.0.1:$port');
  await _openPage(port);
  final refresh = _timedRefresh();
  await Future<void>.delayed(const Duration(seconds: 30));
  _log('failing Tor');
  np.beginNetworkPrivacyEnable();
  np.failNetworkPrivacyEnable();
  _log('status ${np.getNetworkPrivacyStatus()}; watching the page for 20 s');
  await Future<void>.delayed(const Duration(seconds: 20));
  await _host.close();
  await np.stopRailgunBridge();
  await refresh;
  _log('page closed and bridge stopped');
  try {
    final again = await np.startRailgunBridge();
    _log('UNEXPECTED: a bridge started on $again while Tor failed');
  } catch (e) {
    _log('bridge refused while Tor failed: ${_describe(e)}');
  }
}

void _onEvent(String raw) {
  switch (RailgunEvent.decode(raw)) {
    case final RailgunScanEvent scan:
      final progress = scan.progress;
      if (scan.status != RailgunScanStatus.updated ||
          (progress - _lastScan).abs() >= 0.05) {
        _lastScan = progress;
        final percent = (progress * 100).toStringAsFixed(0);
        _log('scan ${scan.tree.name} ${scan.status.wireName} $percent%');
      }
    case final RailgunProofEvent proof:
      _log('proof ${proof.status} ${proof.progress}');
    case final RailgunScreeningEvent screening:
      _log(
        'screening txids ${screening.txids} downloading '
        '${screening.downloading} proving ${screening.proving?.index}',
      );
    case final RailgunLogEvent line:
      debugPrint(
        '[spike][page] ${redactRailgunMessage(line.message, secrets: _secrets)}',
      );
    case null:
      break;
  }
}

class _HarnessApp extends StatelessWidget {
  const _HarnessApp({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: _lines,
        builder: (context, lines, _) => ListView.builder(
          itemCount: lines.length,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Text(
              lines[i],
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      ),
    ),
  );
}
