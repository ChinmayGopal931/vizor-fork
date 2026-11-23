import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_diagnostics.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_host_channel.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart' as rust;

// Shielded USD's failure codes (desktop only): the message is classified into
// codes from a fixed table, and a line keeps nothing else.
void main() {
  group('classifyRailgunFailureMessage', () {
    String? codes(String? message) {
      final result = classifyRailgunFailureMessage(message);
      final reason = result.reason?.code;
      final cause = result.cause?.code;
      return cause == null ? reason : '$reason($cause)';
    }

    test('maps the page, host and engine messages it knows', () {
      const expected = {
        // The page's own (android/railgun-web/src/).
        'the notes scan broke off, so the balances may be stale':
            'notes_scan_broke_off',
        'no notes scan started for a minute: one may be stuck':
            'notes_scan_stuck',
        'the txid list stopped at 1204 of 1500 after 4 syncs':
            'txid_list_stopped',
        "the validated txid index can't be read: Failed to fetch":
            'txid_index_unread(network_failed)',
        'the Ethereum RPC does not answer: the notes scan broke off, so the '
                'balances may be stale':
            'rpc_unreachable(notes_scan_broke_off)',
        // 429 is the RPC's verdict, not a second rate limit.
        'the Ethereum RPC answers 429: no notes scan started for a minute: '
                'one may be stuck':
            'rpc_refused(notes_scan_stuck)',
        'the Ethereum RPC answers 502: something else': 'rpc_error',
        'the note keys workers did not answer in time':
            'note_keys_failed(timed_out)',
        'Invalid merkleroot: 0x0b2f. Tree: 1. Index: 5.': 'root_refused',
        "the network's gas price is above the broadcaster's cap":
            'gas_above_cap',
        'no wallet is open': 'no_wallet',
        // The hosts' own.
        'loading the page timed out': 'page_load_timeout',
        'refresh timed out': 'timed_out',
        "the page's content process stopped": 'page_crashed',
        "the page's host process stopped": 'page_crashed',
        'a new page replaced it': 'page_replaced',
        'closed': 'page_closed',
        'the bridge is not running': 'bridge_down',
        "WebKit's sandbox can't start here": 'sandbox_failed',
        "the page's storage could not be made": 'page_storage_failed',
        'the page failed': 'page_said_nothing',
        // Underneath: WebKit's IndexedDB past its quota, the network.
        'QuotaExceededError: The quota has been exceeded.': 'storage_quota',
        'the notes scan broke off, so the balances may be stale: '
                'QuotaExceededError':
            'notes_scan_broke_off(storage_quota)',
        'POI node request failed: Load failed':
            'screening_failed(network_failed)',
        // Windows's host.
        'Shielded USD needs the WebView2 Runtime': 'os_unsupported',
        "the last page's WebView2 did not close": 'webview_failed',
        'a message nobody has seen before': 'unknown',
      };
      for (final MapEntry(key: message, value: code) in expected.entries) {
        expect(codes(message), code, reason: message);
      }
    });

    test('gives no reason without a message', () {
      expect(codes(null), isNull);
      expect(codes(''), isNull);
      expect(codes('   '), isNull);
    });

    test('returns codes from its table only, never the message', () {
      final table = {
        for (final reason in PrivateUsdFailureReason.values) reason.code,
      };
      for (final message in [
        _secretMessage,
        'the Ethereum RPC does not answer: $_secretMessage',
        'Failed to fetch $_keyedUrl',
        _mnemonic,
      ]) {
        final result = classifyRailgunFailureMessage(message);
        for (final reason in [result.reason, result.cause]) {
          if (reason == null) continue;
          expect(table, contains(reason.code));
          for (final secret in _secrets) {
            expect(reason.code, isNot(contains(secret.toLowerCase())));
          }
        }
      }
    });
  });

  group('PrivateUsdDiagnostics', () {
    late Directory directory;
    late DateTime now;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('private_usd_diag_');
      now = DateTime.utc(2026, 11, 20, 10, 31, 5);
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    PrivateUsdDiagnostics recorder({int maxFileBytes = 1024, int? maxFiles}) =>
        PrivateUsdDiagnostics.testing(
          directory,
          maxFileBytes: maxFileBytes,
          maxFiles: maxFiles ?? PrivateUsdDiagnostics.kMaxFiles,
          now: () => now,
        );

    List<File> files() =>
        directory
            .listSync()
            .whereType<File>()
            .where(
              (file) => PrivateUsdDiagnostics.filePattern.hasMatch(
                file.uri.pathSegments.last,
              ),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    List<Map<String, Object?>> lines() => [
      for (final file in files())
        for (final line in file.readAsLinesSync())
          jsonDecode(line) as Map<String, Object?>,
    ];

    final failedScan = RailgunHostException(
      RailgunHostErrorCode.failed,
      message: 'the notes scan broke off, so the balances may be stale',
    );

    test('rotates its files and keeps them within the limits', () async {
      final diagnostics = recorder(maxFileBytes: 1024, maxFiles: 3);
      for (var i = 0; i < 60; i++) {
        diagnostics.failure(PrivateUsdDiagnosticOp.refresh, failedScan);
        now = now.add(const Duration(minutes: 1));
      }
      await diagnostics.flush();

      final kept = files();
      expect(kept, hasLength(3));
      for (final file in kept) {
        expect(file.lengthSync(), lessThanOrEqualTo(1024));
        // Each file says which build wrote it.
        final first = jsonDecode(file.readAsLinesSync().first) as Map;
        expect(first['event'], 'session');
      }
      final counts = [
        for (final line in lines())
          if (line['op'] == 'refresh') line['n'],
      ];
      // The oldest went; the newest stayed, in order.
      expect(counts.last, 60);
      expect(counts, isNot(contains(1)));
      expect(counts, orderedEquals([...counts]..sort()));

      // A new session never writes into a file an earlier one wrote.
      final next = recorder(maxFileBytes: 1024, maxFiles: 3);
      next.failure(PrivateUsdDiagnosticOp.refresh, failedScan);
      await next.flush();
      expect(files(), hasLength(3));
      expect(files().last.path, isNot(kept.last.path));
      expect(files().first.path, isNot(kept.first.path));

      // A folder removed under it: the line after the failed one starts over.
      directory.deleteSync(recursive: true);
      next.failure(PrivateUsdDiagnosticOp.open, failedScan);
      next.failure(PrivateUsdDiagnosticOp.open, failedScan);
      now = now.add(const Duration(minutes: 1));
      next.failure(PrivateUsdDiagnosticOp.open, failedScan);
      await next.flush();
      expect(files(), hasLength(1));
      expect(lines().last['n'], 3);
    });

    test('counts the same failure within a minute on one line', () async {
      final diagnostics = recorder();
      for (var i = 0; i < 3; i++) {
        diagnostics.failure(PrivateUsdDiagnosticOp.refresh, failedScan);
      }
      now = now.add(const Duration(minutes: 1));
      diagnostics.failure(PrivateUsdDiagnosticOp.refresh, failedScan);
      diagnostics.outcome(
        PrivateUsdDiagnosticOp.reverseConfirm,
        PrivateUsdDiagnosticOutcome.flowGone,
      );
      await diagnostics.flush();

      final records = lines().where((line) => line['event'] == null).toList();
      expect(records, [
        {
          't': '2026-11-20T10:31Z',
          'op': 'refresh',
          'outcome': 'failed',
          'host': 'failed',
          'reason': 'notes_scan_broke_off',
          'n': 1,
        },
        {
          't': '2026-11-20T10:32Z',
          'op': 'refresh',
          'outcome': 'failed',
          'host': 'failed',
          'reason': 'notes_scan_broke_off',
          'n': 4,
        },
        {
          't': '2026-11-20T10:32Z',
          'op': 'reverseConfirm',
          'outcome': 'flowGone',
          'n': 1,
        },
      ]);
      // Settings copies the newest lines that fit, oldest first.
      final all = await diagnostics.recent();
      expect(const LineSplitter().convert(all), hasLength(4));
      final newest = await diagnostics.recent(maxBytes: 120);
      expect(const LineSplitter().convert(newest), [jsonEncode(records.last)]);
    });

    test('keeps no text, URL, address, amount, txid or account', () async {
      final diagnostics = recorder(maxFileBytes: 64 * 1024);
      final errors = <Object>[
        RailgunHostException(
          RailgunHostErrorCode.rpcFailed,
          message: 'the Ethereum RPC does not answer: $_secretMessage',
        ),
        RailgunHostException(
          RailgunHostErrorCode.protocol,
          message: _secretMessage,
        ),
        const rust.ApiPrivateUsdError(
          code: rust.ApiPrivateUsdErrorCode.relayerUnreachable,
          message: _secretMessage,
        ),
        AnyhowException(_secretMessage),
        StateError(_secretMessage),
        const RailgunEngineInterruptedException(),
      ];
      for (final op in PrivateUsdDiagnosticOp.values) {
        for (final error in errors) {
          diagnostics.failure(op, error);
        }
      }
      diagnostics.outcome(
        PrivateUsdDiagnosticOp.reverseAccept,
        PrivateUsdDiagnosticOutcome.nothingSent,
        nothingSent: rust.ApiNothingSentCause.makerRefused,
      );
      await diagnostics.flush();

      final text = files().map((file) => file.readAsStringSync()).join();
      for (final secret in _secrets) {
        expect(text, isNot(contains(secret)), reason: secret);
      }

      final allowed = <String, Set<String>>{
        'op': {for (final op in PrivateUsdDiagnosticOp.values) op.name},
        'outcome': {
          for (final outcome in PrivateUsdDiagnosticOutcome.values)
            outcome.name,
        },
        'host': {for (final code in RailgunHostErrorCode.values) code.name},
        'rust': {
          for (final code in rust.ApiPrivateUsdErrorCode.values) code.name,
          for (final cause in rust.ApiNothingSentCause.values) cause.name,
        },
        'reason': {
          for (final reason in PrivateUsdFailureReason.values) reason.code,
        },
        'cause': {
          for (final reason in PrivateUsdFailureReason.values) reason.code,
        },
      };
      final minute = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z$');
      final records = lines();
      expect(records.where((line) => line['op'] != null), isNotEmpty);
      for (final line in records) {
        expect(line['t'], matches(minute));
        if (line['event'] == 'session') {
          expect(line.keys.toSet(), {
            't',
            'event',
            'version',
            'build',
            'network',
            'platform',
          });
          continue;
        }
        expect(
          allowed.keys.toSet()..addAll(['t', 'n']),
          containsAll(line.keys),
        );
        expect(line['n'], isA<int>());
        for (final MapEntry(:key, :value) in allowed.entries) {
          if (line.containsKey(key)) {
            expect(value, contains(line[key]), reason: '$key: ${line[key]}');
          }
        }
      }
    });
  });
}

const _keyedUrl = 'https://eth-mainnet.g.alchemy.com/v2/k3yK3yK3yK3yK3y';
const _address = '0x8ba1f109551bD432803012645Ac136ddd64DBA72';
const _zkAddress =
    '0zk1qyk9nn28x0u3rwn5pknglda68wrn7gw6anjw8gg94mcj6eq5u48tlrv7j6fe3z53lam';
const _txid =
    '0x5c504ed432cb51138bcf09aa5e8a410dd4a1e204ef84bfed1be16dfba1b22060';
const _amount = '1234.567891';
const _account = '550e8400-e29b-41d4-a716-446655440000';
const _mnemonic = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';
const _secretMessage =
    'POI node $_keyedUrl refused $_amount USDC from $_address to $_zkAddress '
    'in $_txid for account $_account at index 42 with $_mnemonic';
const _secrets = [
  _keyedUrl,
  'alchemy',
  _address,
  _zkAddress,
  _txid,
  _amount,
  _account,
  'zoo zoo',
  'wrong',
  'USDC',
];
