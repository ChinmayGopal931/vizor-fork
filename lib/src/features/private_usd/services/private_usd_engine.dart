import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_record_key.dart';
import 'private_usd_swap_backend.dart';

/// The foreground loop's timing (plan reference §5.10, zapp `SwapLoop`).
abstract final class PrivateUsdEngineTiming {
  /// After a failed step, or a step another caller held up (`busy`).
  static const retry = Duration(seconds: 15);

  /// After the loop itself failed (it could not list the conversions).
  static const restart = Duration(seconds: 30);

  /// A failing step shows its problem only once steps have failed for this
  /// long in a row: the next try often gets past a failure.
  static const problemAfter = Duration(minutes: 1);

  /// How often the step label of a running advance is read.
  static const activityPoll = Duration(milliseconds: 500);

  /// How long a lock waits for the running call to stop (M5 pitfalls).
  static const lockDrain = Duration(seconds: 5);

  /// How long an account deletion or a reset waits for it (§8.4).
  static const quiesceDrain = Duration(seconds: 30);

  /// The shortest nap, so a record that keeps answering "now" never spins.
  static const minNap = Duration(seconds: 1);
}

/// Why the loop stopped: a lock drops the held quotes and the problem
/// timers as well; the background only stops the step.
enum PrivateUsdPauseReason { lock, background }

/// Calls are refused while an account deletion or a reset drains the engine.
class PrivateUsdEngineUnavailableException implements Exception {
  const PrivateUsdEngineUnavailableException();

  @override
  String toString() => 'Private USD is busy with a wallet change.';
}

/// The engine paused (a lock, the background or a drain) under a call, so
/// its result was dropped. Rust kept whatever it saved; the loop picks the
/// conversion up again once allowed.
class PrivateUsdEngineInterruptedException implements Exception {
  const PrivateUsdEngineInterruptedException();

  @override
  String toString() => 'The conversion step was interrupted.';
}

/// What the loop knows about one conversion: the record as Rust last
/// returned it, what it waits for, the step running now, and the problem to
/// show once its steps have failed for [PrivateUsdEngineTiming.problemAfter].
@immutable
class PrivateUsdConversionStatus {
  const PrivateUsdConversionStatus({
    required this.record,
    this.wait,
    this.activity,
    this.problem,
    this.failingSince,
    this.resuming = false,
    this.checkedAt,
  });

  final rust.ApiForwardRecord record;
  final rust.ApiForwardWait? wait;

  /// The step a running advance is in (depositing, claiming, …).
  final rust.ApiActivity? activity;

  /// Shown only after a minute of failures; cleared by any step that goes
  /// through. `ZcashSyncing` is a wait, never a problem.
  final rust.ApiPrivateUsdErrorCode? problem;
  final DateTime? failingSince;

  /// Picking up after a restart, a lock or the background, until the first
  /// advance after it returns ("Picking up where it left off.").
  final bool resuming;

  /// When an advance last returned.
  final DateTime? checkedAt;

  bool get isUnderWay => record.outcome == null;

  PrivateUsdConversionStatus copyWith({
    rust.ApiForwardRecord? record,
    rust.ApiForwardWait? wait,
    bool clearWait = false,
    rust.ApiActivity? activity,
    bool clearActivity = false,
    rust.ApiPrivateUsdErrorCode? problem,
    bool clearProblem = false,
    DateTime? failingSince,
    bool clearFailingSince = false,
    bool? resuming,
    DateTime? checkedAt,
  }) => PrivateUsdConversionStatus(
    record: record ?? this.record,
    wait: clearWait ? null : (wait ?? this.wait),
    activity: clearActivity ? null : (activity ?? this.activity),
    problem: clearProblem ? null : (problem ?? this.problem),
    failingSince: clearFailingSince
        ? null
        : (failingSince ?? this.failingSince),
    resuming: resuming ?? this.resuming,
    checkedAt: checkedAt ?? this.checkedAt,
  );
}

/// The foreground swap loop (plan reference §5.10, D9, D14): it advances
/// every account's conversions under way while the app is open, in the
/// foreground and unlocked, and not while a deletion or reset drains it.
///
/// - Every call that touches a record (quote, accept, advance, abandon) runs
///   on one serial queue per account, so Rust's per-account driver lock
///   answers `busy` only in a rare race.
/// - Each queued call remembers the engine's epoch. [pause] and
///   [quiesceAndDrain] bump it: a call queued before that never starts, a
///   result that lands after it is dropped, and a seed read after it is
///   zeroed and never reaches Rust.
/// - The seed is read just before each key-using call and zeroed as soon as
///   Rust has copied it (see [PrivateUsdSwapBackend]).
///
/// It never logs a record, an amount, a txid or a secret.
class PrivateUsdEngine {
  PrivateUsdEngine({
    required PrivateUsdSwapBackend backend,
    required Future<Uint8List?> Function(String accountUuid) readMnemonic,
    required bool Function() allowed,
    bool Function(String accountUuid)? isKnownAccount,
    DateTime Function()? now,
  }) : _backend = backend,
       _readMnemonic = readMnemonic,
       _allowed = allowed,
       _isKnownAccount = isKnownAccount ?? _anyAccount,
       _now = now ?? DateTime.now;

  static bool _anyAccount(String _) => true;

  final PrivateUsdSwapBackend _backend;
  final Future<Uint8List?> Function(String accountUuid) _readMnemonic;

  /// The host's conditions: in the foreground and unlocked.
  final bool Function() _allowed;

  /// False for an account the wallet no longer lists: a deletion whose
  /// conversion cleanup did not finish leaves its rows, and its seed is gone,
  /// so advancing it would only fail every pass.
  final bool Function(String accountUuid) _isKnownAccount;
  final DateTime Function() _now;

  /// Every conversion the engine has seen, by key.
  final conversions =
      ValueNotifier<Map<PrivateUsdRecordKey, PrivateUsdConversionStatus>>(
        const {},
      );

  final _statuses = <PrivateUsdRecordKey, PrivateUsdConversionStatus>{};
  final _tails = <String, Future<void>>{};
  final _running = <Future<void>>{};
  final _inFlight = <int>{};

  // Bumped by every pause, drain and dispose: work from an older epoch is
  // stale.
  int _epoch = 0;
  int _quiesceDepth = 0;
  bool _disposed = false;

  Future<void>? _loop;
  int _loopEpoch = -1;
  bool _wanted = false;
  bool _nudged = false;
  bool _resumeLoaded = false;
  Timer? _napTimer;
  Completer<void>? _napWaker;

  // Op ids are unique per process, so a cancel Rust remembers for an old id
  // can never stop a newer call.
  static int _lastOpId = 0;

  static int _nextOpId() {
    _lastOpId = _lastOpId >= 0xFFFFFFFF ? 1 : _lastOpId + 1;
    return _lastOpId;
  }

  bool get isQuiesced => _quiesceDepth > 0;

  /// Whether the loop may run steps now.
  bool get canRun => !_disposed && _quiesceDepth == 0 && _allowed();

  /// Whether the loop is running (a pass or a nap).
  @visibleForTesting
  bool get isLooping => _loop != null;

  // ── The loop ───────────────────────────────────────────────────────

  /// Starts the loop, or cuts its nap short. [resuming] marks conversions
  /// under way as being picked up again (after a restart, a lock or the
  /// background) until their next advance returns.
  void start({bool resuming = false}) {
    if (_disposed) return;
    if (resuming) _markResuming();
    _wanted = true;
    _nudged = true;
    _kick();
  }

  /// Cuts the nap short ("Try now", after accept, on opening progress).
  void nudge() => start();

  void _kick() {
    if (!_wanted || !canRun) return;
    if (_loop != null) {
      // A live loop wakes; one left from before a pause is unwinding and
      // restarts this when it ends.
      if (_loopEpoch == _epoch) _wake();
      return;
    }
    final epoch = _loopEpoch = _epoch;
    _loop = _run(epoch).whenComplete(() {
      _loop = null;
      _kick();
    });
  }

  Future<void> _run(int epoch) async {
    while (epoch == _epoch && canRun) {
      _nudged = false;
      Duration? nap;
      try {
        nap = await _pass(epoch);
      } catch (error) {
        _debugLog('a pass failed (${error.runtimeType})');
        nap = PrivateUsdEngineTiming.restart;
      }
      if (epoch != _epoch || !canRun) return;
      if (nap == null) {
        if (_nudged) continue;
        _wanted = false;
        return;
      }
      await _nap(nap, epoch);
    }
  }

  /// One pass over every conversion under way; the nap before the next, or
  /// null when nothing is under way.
  Future<Duration?> _pass(int epoch) async {
    final List<String> accounts;
    try {
      accounts = await _backend.accountsWithUnfinished();
    } catch (error) {
      _debugLog('listing conversions failed (${error.runtimeType})');
      return PrivateUsdEngineTiming.restart;
    }
    if (epoch != _epoch) return null;
    Duration? nap;
    for (final account in accounts) {
      if (!_isKnownAccount(account)) continue;
      final List<rust.ApiForwardRecord> records;
      try {
        records = await loadRecords(account);
      } catch (error) {
        _debugLog('reading conversions failed (${error.runtimeType})');
        nap = _shorter(nap, PrivateUsdEngineTiming.restart);
        continue;
      }
      if (epoch != _epoch) return null;
      for (final record in records) {
        if (record.outcome != null) continue;
        final next = await _advance(account, record, epoch);
        if (epoch != _epoch) return null;
        if (next != null) nap = _shorter(nap, next);
      }
    }
    _resumeLoaded = false;
    return nap;
  }

  /// Advances one conversion; the nap it asks for, or null once it ended.
  Future<Duration?> _advance(
    String accountUuid,
    rust.ApiForwardRecord record,
    int epoch,
  ) async {
    final key = PrivateUsdRecordKey(
      accountUuid: accountUuid,
      direction: PrivateUsdDirection.forward,
      index: record.index,
    );
    Timer? poller;
    try {
      final result = await _queue(accountUuid, epoch, (opId, secret) {
        poller = Timer.periodic(
          PrivateUsdEngineTiming.activityPoll,
          (_) => _showActivity(key, opId),
        );
        return _backend.forwardAdvance(
          accountUuid,
          secret,
          opId: opId,
          index: record.index,
        );
      });
      _advanced(key, result);
      if (result.record.outcome != null) return null;
      final asked = Duration(milliseconds: result.nextPollMs);
      return asked < PrivateUsdEngineTiming.minNap
          ? PrivateUsdEngineTiming.minNap
          : asked;
    } on rust.ApiPrivateUsdError catch (error) {
      switch (error.code) {
        // A cancelled step is never a failure: a pause stopped it.
        case rust.ApiPrivateUsdErrorCode.cancelled:
        // Another call held the account: try again shortly.
        case rust.ApiPrivateUsdErrorCode.busy:
          break;
        default:
          _failed(key, record, _problemOf(error.code));
      }
      return PrivateUsdEngineTiming.retry;
    } on PrivateUsdEngineInterruptedException {
      return PrivateUsdEngineTiming.retry;
    } on PrivateUsdEngineUnavailableException {
      return PrivateUsdEngineTiming.retry;
    } on PrivateUsdKeyLockedException {
      // Locked meanwhile: the lock pauses the loop.
      return PrivateUsdEngineTiming.retry;
    } catch (error) {
      _debugLog('an advance failed (${error.runtimeType})');
      _failed(key, record, rust.ApiPrivateUsdErrorCode.other);
      return PrivateUsdEngineTiming.retry;
    } finally {
      poller?.cancel();
      final status = _statuses[key];
      if (status != null && status.activity != null) {
        _put(key, status.copyWith(clearActivity: true));
      }
    }
  }

  void _advanced(PrivateUsdRecordKey key, rust.ApiForwardAdvance result) {
    final now = _now();
    final problem = result.problem;
    final previous = _statuses[key];
    if (problem == null) {
      _put(
        key,
        PrivateUsdConversionStatus(
          record: result.record,
          wait: result.wait,
          checkedAt: now,
        ),
      );
      return;
    }
    final since = previous?.failingSince ?? now;
    _put(
      key,
      PrivateUsdConversionStatus(
        record: result.record,
        wait: result.wait,
        problem: _shows(since, now) ? problem : null,
        failingSince: since,
        checkedAt: now,
      ),
    );
  }

  void _failed(
    PrivateUsdRecordKey key,
    rust.ApiForwardRecord record,
    rust.ApiPrivateUsdErrorCode problem,
  ) {
    final now = _now();
    final previous =
        _statuses[key] ?? PrivateUsdConversionStatus(record: record);
    final since = previous.failingSince ?? now;
    _put(
      key,
      previous.copyWith(
        problem: _shows(since, now) ? problem : null,
        clearProblem: !_shows(since, now),
        failingSince: since,
        resuming: false,
        checkedAt: now,
        clearActivity: true,
      ),
    );
  }

  bool _shows(DateTime failingSince, DateTime now) =>
      now.difference(failingSince) >= PrivateUsdEngineTiming.problemAfter;

  /// An error an advance threw, as one of the problems the progress screen
  /// explains (reference §5.8; Rust folds a failed step's own code).
  static rust.ApiPrivateUsdErrorCode _problemOf(
    rust.ApiPrivateUsdErrorCode code,
  ) => switch (code) {
    rust.ApiPrivateUsdErrorCode.mismatch ||
    rust.ApiPrivateUsdErrorCode.zcashWallet ||
    rust.ApiPrivateUsdErrorCode.storeUnreadable ||
    rust.ApiPrivateUsdErrorCode.routeBlocked ||
    rust.ApiPrivateUsdErrorCode.relayerUnreachable ||
    rust.ApiPrivateUsdErrorCode.ethereumUnreachable => code,
    _ => rust.ApiPrivateUsdErrorCode.other,
  };

  void _showActivity(PrivateUsdRecordKey key, int opId) {
    final rust.ApiActivity? activity;
    try {
      activity = _backend.activity(opId);
    } catch (_) {
      return;
    }
    final status = _statuses[key];
    if (status == null || status.activity == activity) return;
    _put(
      key,
      activity == null
          ? status.copyWith(clearActivity: true)
          : status.copyWith(activity: activity),
    );
  }

  Future<void> _nap(Duration duration, int epoch) {
    if (_nudged || epoch != _epoch) return Future<void>.value();
    final waker = _napWaker = Completer<void>();
    _napTimer = Timer(duration, _wake);
    return waker.future.whenComplete(() {
      _napTimer?.cancel();
      _napTimer = null;
      if (identical(_napWaker, waker)) _napWaker = null;
    });
  }

  void _wake() {
    final waker = _napWaker;
    if (waker != null && !waker.isCompleted) waker.complete();
  }

  static Duration _shorter(Duration? a, Duration b) =>
      a == null || b < a ? b : a;

  // ── Calls ──────────────────────────────────────────────────────────

  /// Runs [step] on [accountUuid]'s serial queue with a fresh op id. A step
  /// queued before a pause never starts, and a seed read after one never
  /// reaches Rust. With [dropLateResult], a result that lands after a pause
  /// is dropped too ([PrivateUsdEngineInterruptedException]).
  Future<T> runFor<T>(
    String accountUuid,
    Future<T> Function(int opId, PrivateUsdSecretReader secret) step, {
    bool dropLateResult = true,
  }) => _queue(accountUuid, _epoch, step, dropLateResult: dropLateResult);

  Future<T> _queue<T>(
    String accountUuid,
    int epoch,
    Future<T> Function(int opId, PrivateUsdSecretReader secret) step, {
    bool dropLateResult = true,
  }) {
    if (_disposed || _quiesceDepth > 0) {
      return Future<T>.error(const PrivateUsdEngineUnavailableException());
    }
    final previous = _tails[accountUuid] ?? Future<void>.value();
    final result = previous.then(
      (_) => _step(accountUuid, epoch, step, dropLateResult: dropLateResult),
    );
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _tails[accountUuid] = tail;
    _running.add(tail);
    unawaited(
      tail.whenComplete(() {
        _running.remove(tail);
        if (identical(_tails[accountUuid], tail)) _tails.remove(accountUuid);
      }),
    );
    return result;
  }

  Future<T> _step<T>(
    String accountUuid,
    int epoch,
    Future<T> Function(int opId, PrivateUsdSecretReader secret) step, {
    required bool dropLateResult,
  }) async {
    if (_disposed || _quiesceDepth > 0) {
      throw const PrivateUsdEngineUnavailableException();
    }
    if (epoch != _epoch) throw const PrivateUsdEngineInterruptedException();
    final opId = _nextOpId();
    _inFlight.add(opId);
    try {
      final result = await step(opId, () => _readSecret(accountUuid, epoch));
      if (dropLateResult && epoch != _epoch) {
        throw const PrivateUsdEngineInterruptedException();
      }
      return result;
    } finally {
      _inFlight.remove(opId);
    }
  }

  Future<Uint8List?> _readSecret(String accountUuid, int epoch) async {
    if (!_current(epoch)) return null;
    final bytes = await _readMnemonic(accountUuid);
    if (bytes != null && !_current(epoch)) {
      // Locked or drained during the read: it never reaches Rust.
      bytes.fillRange(0, bytes.length, 0);
      return null;
    }
    return bytes;
  }

  bool _current(int epoch) =>
      epoch == _epoch && !_disposed && _quiesceDepth == 0;

  /// Quotes [units] for a fresh swap index (every quote spends one). A
  /// quote that arrives after the app went to the background still counts:
  /// its index is spent either way, and a lock drops the offer in Rust.
  Future<rust.ApiForwardQuote> quote(
    String accountUuid, {
    required int units,
  }) => runFor(
    accountUuid,
    (_, secret) => _backend.forwardQuote(accountUuid, secret, units: units),
    dropLateResult: false,
  );

  /// Accepts swap [index]'s quote. Afterwards (also after a failure: an
  /// accept cut short may still have opened the swap) the records are read
  /// again and the loop starts.
  Future<rust.ApiAcceptResult> accept(
    String accountUuid, {
    required int index,
    required BigInt maxTotalZat,
  }) async {
    try {
      return await runFor(
        accountUuid,
        (_, secret) => _backend.forwardAccept(
          accountUuid,
          secret,
          index: index,
          maxTotalZat: maxTotalZat,
        ),
      );
    } finally {
      unawaited(_refreshThenStart(accountUuid));
    }
  }

  /// "Call it off": ends swap [index] before it reached the chain.
  Future<rust.ApiForwardRecord> abandon(
    String accountUuid, {
    required int index,
  }) async {
    final record = await runFor(
      accountUuid,
      (_, _) => _backend.forwardAbandon(accountUuid, index: index),
      dropLateResult: false,
    );
    _merge(accountUuid, record);
    return record;
  }

  /// Reads [accountUuid]'s forward records and publishes them.
  Future<List<rust.ApiForwardRecord>> loadRecords(String accountUuid) async {
    final records = await _backend.forwardRecords(accountUuid);
    if (_disposed) return records;
    final seen = <PrivateUsdRecordKey>{};
    for (final record in records) {
      seen.add(_merge(accountUuid, record, publish: false));
    }
    _statuses.removeWhere(
      (key, _) => key.accountUuid == accountUuid && !seen.contains(key),
    );
    _publish();
    return records;
  }

  Future<void> _refreshThenStart(String accountUuid) async {
    try {
      await loadRecords(accountUuid);
    } catch (error) {
      _debugLog('reading conversions failed (${error.runtimeType})');
    }
    start();
  }

  PrivateUsdRecordKey _merge(
    String accountUuid,
    rust.ApiForwardRecord record, {
    bool publish = true,
  }) {
    final key = PrivateUsdRecordKey(
      accountUuid: accountUuid,
      direction: PrivateUsdDirection.forward,
      index: record.index,
    );
    final previous = _statuses[key];
    final PrivateUsdConversionStatus next;
    if (previous == null) {
      next = PrivateUsdConversionStatus(
        record: record,
        resuming: _resumeLoaded && record.outcome == null,
      );
    } else if (record.outcome != null) {
      // Ended: nothing waits or fails any more.
      next = PrivateUsdConversionStatus(
        record: record,
        checkedAt: previous.checkedAt,
      );
    } else {
      next = previous.copyWith(record: record);
    }
    _statuses[key] = next;
    if (publish) _publish();
    return key;
  }

  // ── Pausing and draining ───────────────────────────────────────────

  /// Stops starting steps and cancels the running one (lock, background).
  /// On lock it also drops the held quotes and the problem timers, and
  /// waits (at most [PrivateUsdEngineTiming.lockDrain]) for the running
  /// call to stop; its result is dropped. Pair with [start].
  Future<void> pause(PrivateUsdPauseReason reason) async {
    _interrupt();
    if (reason != PrivateUsdPauseReason.lock) return;
    try {
      _backend.clearSessions();
    } catch (error) {
      _debugLog('clearing sessions failed (${error.runtimeType})');
    }
    _forgetProblems();
    await _settle(PrivateUsdEngineTiming.lockDrain);
  }

  /// Refuses new calls, cancels the running one and waits (at most
  /// [timeout]) for every queued call: before an account deletion or a
  /// reset. Pair with [resumeAfterMutation], also when it fails.
  Future<void> quiesceAndDrain({
    Duration timeout = PrivateUsdEngineTiming.quiesceDrain,
  }) async {
    _quiesceDepth++;
    _interrupt();
    await _settle(timeout);
  }

  void resumeAfterMutation() {
    if (_quiesceDepth > 0) _quiesceDepth--;
    if (_quiesceDepth == 0) start(resuming: true);
  }

  /// Drops what the engine knows about [accountUuid] (deleted).
  void forgetAccount(String accountUuid) {
    _statuses.removeWhere((key, _) => key.accountUuid == accountUuid);
    _publish();
  }

  /// Drops everything (the wallet was reset).
  void forgetAll() {
    _statuses.clear();
    _publish();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _interrupt();
    conversions.dispose();
  }

  void _interrupt() {
    _epoch++;
    _nudged = false;
    _napTimer?.cancel();
    _napTimer = null;
    _wake();
    for (final opId in _inFlight.toList()) {
      try {
        _backend.cancel(opId);
      } catch (error) {
        _debugLog('cancel failed (${error.runtimeType})');
      }
    }
  }

  Future<void> _settle(Duration timeout) async {
    final running = [..._running, ?_loop];
    if (running.isEmpty) return;
    try {
      await Future.wait(running).timeout(timeout);
    } on TimeoutException {
      _debugLog('the running call did not stop in time');
    } catch (_) {
      // The loop's failures are its own.
    }
  }

  void _markResuming() {
    _resumeLoaded = true;
    var changed = false;
    for (final entry in _statuses.entries.toList()) {
      if (entry.value.isUnderWay && !entry.value.resuming) {
        _statuses[entry.key] = entry.value.copyWith(resuming: true);
        changed = true;
      }
    }
    if (changed) _publish();
  }

  void _forgetProblems() {
    var changed = false;
    for (final entry in _statuses.entries.toList()) {
      final status = entry.value;
      if (status.failingSince != null || status.problem != null) {
        _statuses[entry.key] = status.copyWith(
          clearProblem: true,
          clearFailingSince: true,
        );
        changed = true;
      }
    }
    if (changed) _publish();
  }

  void _put(PrivateUsdRecordKey key, PrivateUsdConversionStatus status) {
    if (_disposed) return;
    _statuses[key] = status;
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    conversions.value = Map.unmodifiable(_statuses);
  }

  static void _debugLog(String message) {
    if (kDebugMode) debugPrint('privateUsd engine: $message');
  }
}
