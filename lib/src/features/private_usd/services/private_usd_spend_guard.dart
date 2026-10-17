import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../rust/api/private_usd.dart' as rust;

/// What a wallet's private dollars are doing (zapp `PrivateUsdSpendGuard`,
/// reference §6.7): one outgoing Railgun payment at a time per account
/// (one Railgun wallet per software account, D6), conversions included
/// (plan §3.5, invariant 16).
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

  /// "Convert" may open (zapp: the conversion under way opens instead).
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
/// restarts (zapp `PrivateUsdSpendGuard`):
///
/// - a payment starting now ([send], [startConversion]) holds the account
///   in memory until it returns;
/// - the send log's `unconfirmed` rows (Rust keeps them across restarts)
///   block until settlement confirms or drops them;
/// - a conversion under way blocks a send ([statusFor]'s `converting`, and
///   Rust's count just before a send proves).
///
/// Rust enforces the same rule again when it keeps a proof (D-91). The guard
/// holds the last rows it read, for the activity. It never logs a row.
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

  /// How soon an unreadable log is read again (zapp: 30 s).
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

  /// Whether "Convert" may open now.
  bool canStartConversion(String accountUuid, {bool converting = false}) =>
      statusFor(accountUuid, converting: converting).canStartConversion;

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

  /// Runs [block], a send, as [accountUuid]'s one outgoing payment. Returns
  /// [busy] instead, starting nothing, while another payment of the account
  /// runs, its log holds an unsettled send, or a conversion is under way in
  /// Rust's store; [unreadable] when the log or the store does not read.
  Future<T> send<T>(
    String accountUuid,
    Future<T> Function() block, {
    required T Function(PrivateUsdSpendStatus status) busy,
    required T Function() unreadable,
  }) async {
    final current = _starting[accountUuid];
    if (current != null) return busy(current);
    // Held from here (zapp's tryLock): nothing else starts meanwhile.
    _start(accountUuid, PrivateUsdSpendStatus.sending);
    try {
      final readLog = _readLog;
      if (readLog != null) {
        final List<rust.ApiSendRecord> rows;
        try {
          rows = await readLog(accountUuid);
        } catch (_) {
          noteUnreadable(accountUuid);
          return unreadable();
        }
        noteSends(accountUuid, rows);
        if (rows.any(_unsettled)) return busy(PrivateUsdSpendStatus.sending);
      }
      final unfinishedCount = _unfinishedCount;
      if (unfinishedCount != null) {
        final int count;
        try {
          count = await unfinishedCount(accountUuid);
        } catch (_) {
          return unreadable();
        }
        if (count > 0) return busy(PrivateUsdSpendStatus.converting);
      }
      return await block();
    } finally {
      _finish(accountUuid);
      // The send changed the log: read it again.
      unawaited(check(accountUuid));
    }
  }

  /// Runs [pay], a conversion's funding, as [accountUuid]'s one outgoing
  /// payment; throws [PrivateUsdSpendBusyException] while another payment
  /// of the account runs, or its log holds an unsettled send or does not
  /// read. Rust's reverse calls do not read the send log, so this does.
  Future<T> startConversion<T>(
    String accountUuid,
    Future<T> Function() pay,
  ) async {
    final current = _starting[accountUuid];
    if (current != null) throw PrivateUsdSpendBusyException(current);
    _start(accountUuid, PrivateUsdSpendStatus.converting);
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
      return await pay();
    } finally {
      _finish(accountUuid);
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
