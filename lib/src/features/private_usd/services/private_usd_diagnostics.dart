// l10n-ignore-file: patterns matched against page and host messages, and codes; nothing here is shown
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException, PanicException;
import 'package:path_provider/path_provider.dart';

import '../../../core/config/app_version_config.dart';
import '../../../core/config/network_config.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../models/railgun_models.dart' show RailgunProtocolException;
import 'private_usd_engine.dart'
    show
        PrivateUsdEngineInterruptedException,
        PrivateUsdEngineUnavailableException;
import 'private_usd_pause.dart';
import 'private_usd_spend_guard.dart' show PrivateUsdSpendBusyException;
import 'private_usd_swap_backend.dart'
    show PrivateUsdKeyLockedException, PrivateUsdStaleStepException;
import 'private_usd_zec_quote_search.dart' show PrivateUsdNoQuoteFitsException;
import 'railgun_engine.dart'
    show
        RailgunAddressMismatchException,
        RailgunEngineInterruptedException,
        RailgunEngineUnavailableException;
import 'railgun_engine_key_store.dart' show RailgunEngineKeyLockedException;
import 'railgun_host_channel.dart';

// Shielded USD's failure codes, kept by the desktop apps only.
//
// When a Shielded USD step fails, the desktop app keeps one short line of
// codes about it in `<support>/diagnostics/private-usd-*.jsonl`, so the next
// bug can be read from the device instead of a debug build. A line holds only
// codes from the fixed tables below, a counter and the minute: never text, a
// URL, an address, an amount, a txid, an index, an account id or a key.
//
// Every caller gates its call on `kDesktopFormFactor`, so the phones' builds
// fold the calls away and keep nothing of this file; and nothing is written
// until the desktop runtime calls [PrivateUsdDiagnostics.enable]
// (`initializeZcashWalletRuntime`), so tests write nothing either.

/// What was being done when something failed. A fixed table: a line never
/// names a call in free text.
enum PrivateUsdDiagnosticOp {
  // The Railgun page's calls (`RailgunEngine`), by method.
  refresh,
  broadcasterFee,
  transfer,
  unshield,
  reverseCost,
  prepareReverse,

  /// A page call the table above does not name.
  pageCall,

  /// Opening the page and the account's wallet in it: the bridge, `load`,
  /// `start`, `openWallet` and the address check.
  open,

  /// A refresh whose screening check failed: the balances stand, their
  /// screening statuses wait for a later sync.
  screening,

  /// Deleting a deleted account's wallet from the page's storage, and getting
  /// ready to.
  prepareWalletDeletion,
  deleteWallet,

  /// A balance refresh as the balance shows it ("Couldn't update the
  /// balance").
  balanceRefresh,

  /// Reading Railgun's head, which decides when a watched balance refreshes.
  railgunHead,

  // Bridges, ZEC → USD.
  quote,
  accept,
  confirm,
  abandon,

  // Bridges, USD → ZEC.
  reverseQuote,
  goAhead,
  reverseAccept,
  reverseConfirm,
  reprice,
  reverseCancel,

  /// The USD → ZEC payment, by the step it had reached.
  fundPreparing,
  fundProving,
  fundSubmitting,

  // The conversions' loop (`PrivateUsdEngine`).
  advance,
  reverseAdvance,
  loopPass,
  deposits,

  // Private sends and withdrawals.
  sendPrice,
  sendProve,
  sendKeep,
  sendPost;

  /// The op of the Railgun page's [method].
  static PrivateUsdDiagnosticOp ofPageMethod(String method) => switch (method) {
    'refresh' => refresh,
    'broadcasterFee' => broadcasterFee,
    'transfer' => transfer,
    'unshield' => unshield,
    'reverseCost' => reverseCost,
    'prepareReverse' => prepareReverse,
    _ => pageCall,
  };
}

/// How Dart took what happened. A fixed table.
enum PrivateUsdDiagnosticOutcome {
  /// It failed; the line's `host` or `rust` code says why.
  failed,

  /// Dart's own time limit ran out.
  timeout,

  /// A call Dart had timed out answered after all.
  late,

  /// A lock, an account switch, a route change, the idle close or the
  /// background closed the page or stopped the step under it.
  interrupted,

  /// The engine refused to run it: locked, in the background, or drained for
  /// an account deletion or a reset.
  paused,

  /// Its result was dropped: the engine moved on, or the conversion was
  /// called off.
  dropped,

  /// The screen's flow was gone before it could go on.
  flowGone,

  /// The fees changed: nothing was paid, and the new total shows.
  costChanged,

  /// A send not seen in a block yet holds the wallet's notes.
  spendBusy,

  /// The maker turned the accept away and nothing was sent; `rust` names
  /// Rust's cause.
  nothingSent,

  /// No quote fits the amount.
  noQuoteFits,

  /// The page opened another wallet than the account's.
  addressMismatch,

  /// An answer Dart could not read.
  unreadable,

  /// Rust panicked.
  rustPanic,

  /// Rust failed without a Private USD code.
  rustError,

  /// Any other error in Dart.
  dartError,
}

/// Why a Railgun page call failed, read from the message the host returns.
/// A fixed table: only [code] is kept, never the message.
///
/// The patterns match the lower-cased message. They are tried in this order,
/// and a match takes its words out of the message, so a more general reason
/// further down never matches them again: the page's own and the hosts' own
/// failures come first, then what the engine, WebKit or the network said
/// underneath.
enum PrivateUsdFailureReason {
  // The page's own failures (android/railgun-web/src/).
  notesScanBrokeOff('notes_scan_broke_off', [r'notes scan broke off']),
  notesScanStuck('notes_scan_stuck', [r'no notes scan started']),
  txidListStopped('txid_list_stopped', [r'txid list stopped']),
  txidIndexUnread('txid_index_unread', [r'validated txid index can.t be read']),
  rpcUnreachable('rpc_unreachable', [r'ethereum rpc does not answer']),
  rpcRefused('rpc_refused', [r'ethereum rpc answers (?:403|429)\b']),
  rpcError('rpc_error', [
    r'ethereum rpc answers \d+',
    r'\bserver_error\b',
    r'could not coalesce',
    r'\bbad_data\b',
    r'missing response',
    r'header not found',
    r'\bunknown_error\b',
  ]),
  stillProving('still_proving', [r'still proving']),
  gasAboveCap('gas_above_cap', [r'gas price is above']),
  noteKeysFailed('note_keys_failed', [r'note keys worker']),
  indexerUnreachable('indexer_unreachable', [r'indexer did not answer']),
  indexerInconsistent('indexer_inconsistent', [
    r'more than a page of events',
    r'event list ended before',
    r'no indexer for',
    r'has no \w+ indexer',
  ]),
  treesShort('trees_short', [r'trees stopped short']),
  sendRecordMismatch('send_record_mismatch', [r'hash to its railguntxid']),
  rootRefused('root_refused', [r'merkle ?root']),
  archiveFailed('archive_failed', [
    r'\barchive\b',
    r'\bchecksum\b',
    r'the tip moved',
    r'chunk index',
    r'\bmanifest\b',
  ]),
  artifactsFailed('artifacts_failed', [r'artifact']),
  noWallet('no_wallet', [r'no wallet is open']),
  anotherWallet('another_wallet', [r'another wallet is open']),
  engineNotRunning('engine_not_running', [r'engine is not running']),
  networkMismatch('network_mismatch', [
    r'the engine runs \w',
    r'unknown network',
  ]),
  fundingRefused('funding_refused', [
    r'\bfunding\b',
    r'\bescrow\b',
    r'sponsored',
    r'relayer fee',
    r'railgun contract is',
  ]),
  broadcasterRefused('broadcaster_refused', [
    r'broadcaster is not for',
    r'not a plain transact call',
  ]),
  badRequest('bad_request', [
    r'unknown method',
    r'no rpc urls',
    r'no mnemonic',
    r'deletes wallets',
    r'deleted on a page of their own',
  ]),

  // The hosts' own failures (closed, timeout, unavailable, protocol).
  pageCrashed('page_crashed', [
    r'process stopped',
    r'web ?process',
    r'renderer',
  ]),
  pageReplaced('page_replaced', [r'new page replaced it']),
  pageLoadTimeout('page_load_timeout', [r'loading the page timed out']),
  pageNotLoaded('page_not_loaded', [r'did not load', r'already loading']),
  callNotTaken('call_not_taken', [r'did not take the call']),
  pageClosed('page_closed', [
    r'closed while loading',
    r'^\s*(?:closed|wiped|no page)\s*$',
  ]),
  bridgeDown('bridge_down', [r'bridge is not running']),
  sandboxFailed('sandbox_failed', [r'sandbox']),
  pageStorageFailed('page_storage_failed', [r'storage could not be made']),
  osUnsupported('os_unsupported', [r'needs macos']),
  contentRulesFailed('content_rules_failed', [r'content rules']),
  hostFailed('host_failed', [
    r'host process did not start',
    r'link could not be made',
    r'railgun host failed',
  ]),
  replyUnreadable('reply_unreadable', [r'reply is unreadable']),
  dataNotRemoved('data_not_removed', [r'data could not be removed']),
  pageSaidNothing('page_said_nothing', [r'^\s*the page failed\s*$']),

  // What the engine, WebKit or the network said underneath.
  storageQuota('storage_quota', [
    r'quotaexceeded',
    r'quota has been exceeded',
    r'storage quota',
    r'disk full',
    r'no space left',
  ]),
  storageFailed('storage_failed', [
    r'indexeddb',
    r'\bidb',
    r'leveldb',
    r'level-js',
    r'transactioninactive',
    r'\bdatabase\b',
  ]),
  outOfMemory('out_of_memory', [
    r'out of memory',
    r'could not allocate',
    r'allocation failed',
  ]),
  screeningFailed('screening_failed', [
    r'\bpois?\b',
    r'proof of innocence',
    r'\bppoi\b',
    r'screening',
  ]),
  proofFailed('proof_failed', [
    r'invalid proof',
    r'invalid snark',
    r'proof (?:generation|verification) failed',
    r'(?:generate|create) (?:a |the )?proof',
    r'\bprover\b',
  ]),
  insufficientBalance('insufficient_balance', [
    r'insufficient',
    r'balance too low',
    r'not enough (?:balance|funds)',
  ]),
  contractReverted('contract_reverted', [
    r'revert',
    r'call_exception',
    r'call exception',
  ]),
  rateLimited('rate_limited', [
    r'\b429\b',
    r'rate.?limit',
    r'too many requests',
  ]),
  networkFailed('network_failed', [
    r'failed to fetch',
    r'load failed',
    r'networkerror',
    r'network error',
    r'network_error',
    r'fetch failed',
    r'could not connect',
    r'connection (?:was )?(?:refused|reset|lost|closed)',
    r'econnrefused',
    r'econnreset',
    r'enotfound',
    r'etimedout',
    r'\bsocket\b',
    r'\bdns\b',
    r'offline',
  ]),
  timedOut('timed_out', [
    r'timed? ?out',
    r'did not answer in time',
    r'\btimeout\b',
  ]),

  /// A message none of the above matched.
  unknown('unknown', []);

  const PrivateUsdFailureReason(this.code, this._patterns);

  /// What a line keeps.
  final String code;
  final List<String> _patterns;

  static final _compiled = {
    for (final reason in values)
      reason: [for (final pattern in reason._patterns) RegExp(pattern)],
  };
}

/// The reasons [message] gives, from [PrivateUsdFailureReason]'s table: the
/// first it names, and the last when it names more (a message reads "what
/// failed: what was underneath"). Null for no message; `unknown` for one the
/// table does not know. The message is read here and never kept.
({PrivateUsdFailureReason? reason, PrivateUsdFailureReason? cause})
classifyRailgunFailureMessage(String? message) {
  if (message == null || message.trim().isEmpty) {
    return (reason: null, cause: null);
  }
  // Long engine errors carry their payloads after what failed.
  var text = (message.length > 4096 ? message.substring(0, 4096) : message)
      .toLowerCase();
  final found = <({int at, PrivateUsdFailureReason reason})>[];
  for (final reason in PrivateUsdFailureReason.values) {
    for (final pattern in PrivateUsdFailureReason._compiled[reason]!) {
      final match = pattern.firstMatch(text);
      if (match == null || match.end == match.start) continue;
      found.add((at: match.start, reason: reason));
      text = text.replaceRange(
        match.start,
        match.end,
        ' ' * (match.end - match.start),
      );
      break;
    }
  }
  if (found.isEmpty) {
    return (reason: PrivateUsdFailureReason.unknown, cause: null);
  }
  found.sort((a, b) => a.at.compareTo(b.at));
  return (
    reason: found.first.reason,
    cause: found.length > 1 ? found.last.reason : null,
  );
}

/// One failure as a line keeps it: codes from the fixed tables only.
class PrivateUsdDiagnosticRecord {
  const PrivateUsdDiagnosticRecord(
    this.op,
    this.outcome, {
    this.host,
    this.rustCode,
    this.nothingSent,
    this.reason,
    this.cause,
  });

  /// What [error] says about [op]: the host's code with the reasons its
  /// message gives, Rust's code, or the kind of error, and how Dart took it.
  /// [outcome] overrides the outcome the error implies (a page that died
  /// under a payment is a drop, not a failure).
  factory PrivateUsdDiagnosticRecord.of(
    PrivateUsdDiagnosticOp op,
    Object error, {
    PrivateUsdDiagnosticOutcome? outcome,
  }) {
    switch (error) {
      case final RailgunHostException failed:
        // The message can quote a keyed RPC URL or what the page saw: only
        // the reasons it gives are kept.
        final reasons = classifyRailgunFailureMessage(failed.debugMessage());
        return PrivateUsdDiagnosticRecord(
          op,
          outcome ?? PrivateUsdDiagnosticOutcome.failed,
          host: failed.code,
          reason: reasons.reason,
          cause: reasons.cause,
        );
      case rust.ApiPrivateUsdError(:final code):
        return PrivateUsdDiagnosticRecord(
          op,
          outcome ??
              (code == rust.ApiPrivateUsdErrorCode.cancelled
                  ? PrivateUsdDiagnosticOutcome.interrupted
                  : PrivateUsdDiagnosticOutcome.failed),
          rustCode: code,
        );
      default:
        return PrivateUsdDiagnosticRecord(op, outcome ?? _outcomeOf(error));
    }
  }

  final PrivateUsdDiagnosticOp op;
  final PrivateUsdDiagnosticOutcome outcome;
  final RailgunHostErrorCode? host;
  final rust.ApiPrivateUsdErrorCode? rustCode;

  /// Rust's cause for a [PrivateUsdDiagnosticOutcome.nothingSent]; kept as
  /// the line's `rust`.
  final rust.ApiNothingSentCause? nothingSent;
  final PrivateUsdFailureReason? reason;
  final PrivateUsdFailureReason? cause;

  static PrivateUsdDiagnosticOutcome _outcomeOf(Object error) =>
      switch (error) {
        TimeoutException() => PrivateUsdDiagnosticOutcome.timeout,
        PrivateUsdStaleStepException() => PrivateUsdDiagnosticOutcome.dropped,
        RailgunEngineInterruptedException() ||
        PrivateUsdEngineInterruptedException() =>
          PrivateUsdDiagnosticOutcome.interrupted,
        RailgunEngineUnavailableException() ||
        PrivateUsdEngineUnavailableException() ||
        RailgunEngineKeyLockedException() ||
        PrivateUsdKeyLockedException() => PrivateUsdDiagnosticOutcome.paused,
        PrivateUsdPause() => PrivateUsdDiagnosticOutcome.interrupted,
        PrivateUsdSpendBusyException() => PrivateUsdDiagnosticOutcome.spendBusy,
        PrivateUsdNoQuoteFitsException() =>
          PrivateUsdDiagnosticOutcome.noQuoteFits,
        RailgunAddressMismatchException() =>
          PrivateUsdDiagnosticOutcome.addressMismatch,
        RailgunProtocolException() => PrivateUsdDiagnosticOutcome.unreadable,
        PanicException() => PrivateUsdDiagnosticOutcome.rustPanic,
        AnyhowException() => PrivateUsdDiagnosticOutcome.rustError,
        _ => PrivateUsdDiagnosticOutcome.dartError,
      };

  /// The same failure again, whatever minute it is.
  String get _key =>
      '${op.index}/${outcome.index}/${host?.index}/${rustCode?.index}/'
      '${nothingSent?.index}/${reason?.index}/${cause?.index}';

  Map<String, Object> _toJson({required String minute, required int count}) => {
    't': minute,
    'op': op.name,
    'outcome': outcome.name,
    'host': ?host?.name,
    'rust': ?(rustCode?.name ?? nothingSent?.name),
    'reason': ?reason?.code,
    'cause': ?cause?.code,
    'n': count,
  };
}

/// The desktop apps' record of Shielded USD failures: rotating JSONL files in
/// `<support>/diagnostics/`, `private-usd-<sequence>.jsonl`, at most
/// [kMaxFiles] of [kMaxFileBytes] each. Each file opens with a session line
/// (the app's version, build, network and OS). It stays on the device: the
/// app never sends it anywhere, and Settings copies it only when asked.
///
/// - A line keeps the op, the host's or Rust's code, the reasons the page's
///   message gives, Dart's outcome, `n` (how many times this same failure has
///   happened since the app started) and the minute, in UTC.
/// - The same failure again within the minute is only counted: the next line
///   for it carries the count.
/// - A logger never stops what it records: every failure here is swallowed.
class PrivateUsdDiagnostics {
  PrivateUsdDiagnostics._()
    : _now = DateTime.now,
      _maxFileBytes = kMaxFileBytes,
      _maxFiles = kMaxFiles;

  @visibleForTesting
  PrivateUsdDiagnostics.testing(
    Directory directory, {
    int maxFileBytes = kMaxFileBytes,
    int maxFiles = kMaxFiles,
    DateTime Function()? now,
  }) : _directory = directory,
       _maxFileBytes = maxFileBytes,
       _maxFiles = maxFiles,
       _now = now ?? DateTime.now,
       _enabled = true,
       assert(maxFileBytes >= 512),
       assert(maxFiles >= 1);

  static final instance = PrivateUsdDiagnostics._();

  static const kMaxFileBytes = 256 * 1024;
  static const kMaxFiles = 8;

  /// How much Settings copies: the newest lines that fit.
  static const kCopyBytes = 64 * 1024;

  @visibleForTesting
  static final filePattern = RegExp(r'^private-usd-(\d{12})\.jsonl$');

  // Distinct failures counted at once; past it the counts start over.
  static const _maxKeys = 512;

  final DateTime Function() _now;
  Directory? _directory;
  File? _file;
  int _fileBytes = 0;
  int? _nextSequence;
  final int _maxFileBytes;
  final int _maxFiles;
  bool _enabled = false;
  bool _reportedFailure = false;
  final _counts = <String, ({String minute, int count})>{};
  Future<void> _tail = Future<void>.value();

  /// Starts recording. The desktop runtime calls it once at startup.
  void enable() => _enabled = true;

  /// [op] failed with [error]: keeps its codes ([PrivateUsdDiagnosticRecord.of]).
  void failure(
    PrivateUsdDiagnosticOp op,
    Object error, {
    PrivateUsdDiagnosticOutcome? outcome,
  }) {
    if (!_enabled) return;
    try {
      record(PrivateUsdDiagnosticRecord.of(op, error, outcome: outcome));
    } catch (_) {
      _reportFailure();
    }
  }

  /// [op] ended as [outcome], with Rust's [code] or [nothingSent] cause.
  void outcome(
    PrivateUsdDiagnosticOp op,
    PrivateUsdDiagnosticOutcome outcome, {
    rust.ApiPrivateUsdErrorCode? code,
    rust.ApiNothingSentCause? nothingSent,
  }) => record(
    PrivateUsdDiagnosticRecord(
      op,
      outcome,
      rustCode: code,
      nothingSent: nothingSent,
    ),
  );

  void record(PrivateUsdDiagnosticRecord record) {
    if (!_enabled) return;
    try {
      final minute = _minute(_now());
      final key = record._key;
      final previous = _counts[key];
      if (previous == null && _counts.length >= _maxKeys) _counts.clear();
      final count = (previous?.count ?? 0) + 1;
      _counts[key] = (minute: minute, count: count);
      // Already written this minute: the next line for it carries the count.
      if (previous?.minute == minute) return;
      _append(record._toJson(minute: minute, count: count));
    } catch (_) {
      _reportFailure();
    }
  }

  /// The newest lines, oldest first, up to [maxBytes]: earlier sessions' too.
  /// Empty when nothing was recorded.
  Future<String> recent({int maxBytes = kCopyBytes}) async {
    await _tail;
    final directory = _directory ?? await _supportDirectory();
    if (!await directory.exists()) return '';
    final lines = <String>[];
    for (final file in await _files(directory)) {
      for (final line in const LineSplitter().convert(
        await file.readAsString(),
      )) {
        if (line.isNotEmpty) lines.add(line);
      }
    }
    var bytes = 0;
    var start = lines.length;
    while (start > 0) {
      final size = utf8.encode(lines[start - 1]).length + 1;
      if (bytes + size > maxBytes) break;
      bytes += size;
      start--;
    }
    return lines.isEmpty || start == lines.length
        ? ''
        : '${lines.sublist(start).join('\n')}\n';
  }

  /// Waits for the lines written so far.
  @visibleForTesting
  Future<void> flush() => _tail;

  void _append(Map<String, Object> record) {
    final line = '${jsonEncode(record)}\n';
    _tail = _tail.then((_) async {
      try {
        final directory = _directory ??= await _supportDirectory();
        if (_file == null ||
            _fileBytes + utf8.encode(line).length > _maxFileBytes) {
          await _startFile(directory);
        }
        await _write(line);
      } catch (_) {
        // The next line starts a new file (its folder may have been removed).
        _file = null;
        _reportFailure();
      }
    });
  }

  // A new file, never one an earlier session wrote, opened by the session
  // line; the oldest go so that at most [_maxFiles] stay.
  Future<void> _startFile(Directory directory) async {
    await directory.create(recursive: true);
    final existing = await _files(directory);
    var sequence =
        _nextSequence ??
        (existing.isEmpty ? 0 : _sequenceOf(existing.last) + 1);
    var file = _fileAt(directory, sequence);
    while (await file.exists()) {
      file = _fileAt(directory, ++sequence);
    }
    _nextSequence = sequence + 1;
    _file = file;
    _fileBytes = 0;
    final removeCount = existing.length - (_maxFiles - 1);
    for (final old in existing.take(removeCount > 0 ? removeCount : 0)) {
      await old.delete();
    }
    await _write('${jsonEncode(_session())}\n');
  }

  Future<void> _write(String line) async {
    await _file!.writeAsString(line, mode: FileMode.append, flush: true);
    _fileBytes += utf8.encode(line).length;
  }

  Map<String, Object> _session() => {
    't': _minute(_now()),
    'event': 'session',
    'version':
        kVizorReleaseVersion.length <= 64 &&
            RegExp(
              r'^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?$',
            ).hasMatch(kVizorReleaseVersion)
        ? kVizorReleaseVersion
        : 'unknown',
    'build': kVizorReleaseBuildNumber,
    'network': kZcashDefaultNetworkName,
    'platform': Platform.operatingSystem,
  };

  static Future<Directory> _supportDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/diagnostics');

  static File _fileAt(Directory directory, int sequence) => File(
    '${directory.path}/private-usd-${'$sequence'.padLeft(12, '0')}.jsonl',
  );

  static int _sequenceOf(File file) =>
      int.parse(filePattern.firstMatch(file.uri.pathSegments.last)!.group(1)!);

  /// This recorder's files, oldest first.
  static Future<List<File>> _files(Directory directory) async {
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          filePattern.hasMatch(entity.uri.pathSegments.last)) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  // UTC, to the minute: `2026-11-20T10:31Z`.
  static String _minute(DateTime time) {
    final utc = time.toUtc();
    String two(int value) => '$value'.padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
        '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}Z';
  }

  void _reportFailure() {
    if (_reportedFailure) return;
    _reportedFailure = true;
    debugPrint('[zcash] Private USD diagnostics could not be written.');
  }
}
