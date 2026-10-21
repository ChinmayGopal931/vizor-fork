import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../rust/api/private_usd.dart' as rust;

/// What a wallet's private dollars are doing: one outgoing Railgun payment
/// at a time per account (one Railgun wallet per software account),
/// conversions included.
enum PrivateUsdSpendStatus {
  /// The send log has not been read yet.
  checking,
  available,

  /// A send is being proved or posted now, or the log holds one not seen in
  /// a block yet (`unconfirmed`, across restarts).
  sending,

  /// A conversion is under way (either direction), or its funding runs.
  converting,

  /// The send log does not read: spending stays blocked.
  unreadable;

  /// Send and Withdraw may start.
  bool get canSend => this == available;

  /// "Convert" may open (the conversion under way opens instead).
  bool get canStartConversion => this == available || this == converting;
}

/// Another outgoing payment of the wallet is under way: nothing was started.
class PrivateUsdSpendBusyException implements Exception {
  const PrivateUsdSpendBusyException(this.status);

  final PrivateUsdSpendStatus status;

  @override
  String toString() => 'A private USD payment is already under way.';
}

/// Reads an account's send log (Rust `private_usd_send_log_list`).
typedef PrivateUsdSendLogReader =
    Future<List<rust.ApiSendRecord>> Function(String accountUuid);

/// Counts an account's conversions under way in Rust's store.
typedef PrivateUsdUnfinishedCounter = Future<int> Function(String accountUuid);

/// Whether a send that [before] holds unconfirmed is confirmed in [after]:
/// it was seen landing between two reads of the log.
bool privateUsdSendsLanded(
  List<rust.ApiSendRecord> before,
  List<rust.ApiSendRecord> after,
) {
  final waiting = {
    for (final row in before)
      if (row.state == rust.ApiSendState.unconfirmed) row.sendId,
  };
  return after.any(
    (row) =>
        row.state == rust.ApiSendState.confirmed &&
        waiting.contains(row.sendId),
  );
}

/// One outgoing Railgun payment at a time per account, across screens and
/// restarts:
///
/// - a payment starting now ([send], [startConversion]) holds the account
///   in memory until it returns;
/// - the send log's `unconfirmed` rows (Rust keeps them across restarts)
///   block until settlement confirms or drops them;
/// - a conversion under way blocks a send ([statusFor]'s `converting`, and
///   Rust's count just before a send proves).
///
/// Rust enforces the same rule again when it keeps a proof. The guard holds
/// the last rows it read, for the activity. It never logs a row.
class PrivateUsdSpendGuard extends ChangeNotifier {
  PrivateUsdSpendGuard({
    PrivateUsdSendLogReader? readLog,
    PrivateUsdUnfinishedCounter? unfinishedCount,
    this.retryAfter = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _readLog = readLog,
       _unfinishedCount = unfinishedCount,
       _now = now ?? DateTime.now;

  final PrivateUsdSendLogReader? _readLog;
  final PrivateUsdUnfinishedCounter? _unfinishedCount;
  final DateTime Function() _now;

  /// How soon an unreadable log is read again.
  final Duration retryAfter;

  final _starting = <String, PrivateUsdSpendStatus>{};
  final _rows = <String, List<rust.ApiSendRecord>>{};
  final _landedAt = <String, DateTime>{};
  final _unreadable = <String>{};
  final _reads = <String, Future<void>>{};
  final _retries = <String, Timer>{};
  bool _disposed = false;

  /// [accountUuid]'s status now; [converting] when the engine knows a
  /// conversion of it under way.
  PrivateUsdSpendStatus statusFor(
    String accountUuid, {
    bool converting = false,
  }) {
    final starting = _starting[accountUuid];
    if (starting != null) return starting;
    if (_readLog != null) {
      if (_unreadable.contains(accountUuid)) {
        return PrivateUsdSpendStatus.unreadable;
      }
      final rows = _rows[accountUuid];
      if (rows == null) return PrivateUsdSpendStatus.checking;
      if (rows.any(_unsettled)) return PrivateUsdSpendStatus.sending;
    }
    return converting
        ? PrivateUsdSpendStatus.converting
        : PrivateUsdSpendStatus.available;
  }

  /// The account's sends as last read, newest first; empty until read.
  List<rust.ApiSendRecord> recordsFor(String accountUuid) =>
      _rows[accountUuid] ?? const [];

  /// Whether the log as last read holds a send not seen in a block yet.
  bool hasUnsettled(String accountUuid) =>
      (_rows[accountUuid] ?? const []).any(_unsettled);

  /// When a send of [accountUuid]'s was last seen landing: read as
  /// unconfirmed, then as confirmed (the device's clock). Null when none was
  /// seen this run.
  DateTime? landedAt(String accountUuid) => _landedAt[accountUuid];

  /// Reads [accountUuid]'s log now (one read at a time per account). A log
  /// that does not read is `unreadable`, and read again after [retryAfter].
  Future<void> check(String accountUuid) {
    final readLog = _readLog;
    if (readLog == null || _disposed) return Future.value();
    final running = _reads[accountUuid];
    if (running != null) return running;
    final read = () async {
      try {
        noteSends(accountUuid, await readLog(accountUuid));
      } catch (_) {
        noteUnreadable(accountUuid);
      }
    }();
    _reads[accountUuid] = read;
    return read.whenComplete(() {
      if (identical(_reads[accountUuid], read)) _reads.remove(accountUuid);
    });
  }

  /// The rows a keep, a settlement pass or a read returned.
  void noteSends(String accountUuid, List<rust.ApiSendRecord> rows) {
    if (_disposed) return;
    _retries.remove(accountUuid)?.cancel();
    _unreadable.remove(accountUuid);
    if (privateUsdSendsLanded(_rows[accountUuid] ?? const [], rows)) {
      _landedAt[accountUuid] = _now();
    }
    _rows[accountUuid] = List.unmodifiable(rows);
    notifyListeners();
  }

  /// The log did not read: spending stays blocked until it does.
  void noteUnreadable(String accountUuid) {
    if (_disposed) return;
    _unreadable.add(accountUuid);
    _retries.remove(accountUuid)?.cancel();
    _retries[accountUuid] = Timer(retryAfter, () {
      _retries.remove(accountUuid);
      unawaited(check(accountUuid));
    });
    notifyListeners();
  }

  /// Drops what the guard knows about [accountUuid] (deleted).
  void forget(String accountUuid) {
    _rows.remove(accountUuid);
    _landedAt.remove(accountUuid);
    _unreadable.remove(accountUuid);
    _retries.remove(accountUuid)?.cancel();
    if (!_disposed) notifyListeners();
  }

  /// Runs [block], a send, as [accountUuid]'s one outgoing payment. Throws
  /// [PrivateUsdSpendBusyException], starting nothing, while another payment
  /// of the account runs, its log holds an unsettled send, or a conversion is
  /// under way in Rust's store; its status is `unreadable` when the log or
  /// the store does not read.
  Future<T> send<T>(String accountUuid, Future<T> Function() block) =>
      _run(accountUuid, PrivateUsdSpendStatus.sending, block, isSend: true);

  /// Runs [pay], a conversion's funding, as [accountUuid]'s one outgoing
  /// payment, refused as [send] is, but for the conversion itself: Rust's
  /// reverse calls do not read the send log, so this does.
  Future<T> startConversion<T>(String accountUuid, Future<T> Function() pay) =>
      _run(accountUuid, PrivateUsdSpendStatus.converting, pay);

  Future<T> _run<T>(
    String accountUuid,
    PrivateUsdSpendStatus holding,
    Future<T> Function() block, {
    bool isSend = false,
  }) async {
    final current = _starting[accountUuid];
    if (current != null) throw PrivateUsdSpendBusyException(current);
    // Held from here: nothing else starts meanwhile.
    _start(accountUuid, holding);
    try {
      final readLog = _readLog;
      if (readLog != null) {
        final List<rust.ApiSendRecord> rows;
        try {
          rows = await readLog(accountUuid);
        } catch (_) {
          noteUnreadable(accountUuid);
          throw const PrivateUsdSpendBusyException(
            PrivateUsdSpendStatus.unreadable,
          );
        }
        noteSends(accountUuid, rows);
        if (rows.any(_unsettled)) {
          throw const PrivateUsdSpendBusyException(
            PrivateUsdSpendStatus.sending,
          );
        }
      }
      final unfinishedCount = _unfinishedCount;
      if (isSend && unfinishedCount != null) {
        final int count;
        try {
          count = await unfinishedCount(accountUuid);
        } catch (_) {
          throw const PrivateUsdSpendBusyException(
            PrivateUsdSpendStatus.unreadable,
          );
        }
        if (count > 0) {
          throw const PrivateUsdSpendBusyException(
            PrivateUsdSpendStatus.converting,
          );
        }
      }
      return await block();
    } finally {
      _finish(accountUuid);
      // A send changed the log: read it again.
      if (isSend) unawaited(check(accountUuid));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _retries.values) {
      timer.cancel();
    }
    _retries.clear();
    super.dispose();
  }

  void _start(String accountUuid, PrivateUsdSpendStatus status) {
    _starting[accountUuid] = status;
    if (!_disposed) notifyListeners();
  }

  void _finish(String accountUuid) {
    _starting.remove(accountUuid);
    if (!_disposed) notifyListeners();
  }

  static bool _unsettled(rust.ApiSendRecord row) =>
      row.state == rust.ApiSendState.unconfirmed;
}
