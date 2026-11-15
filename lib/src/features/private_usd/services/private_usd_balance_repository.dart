import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/private_usd_balances.dart';
import '../models/railgun_models.dart';

/// How often a watched balance is looked at, and how stale it may get.
abstract final class PrivateUsdBalanceTiming {
  /// How often a watched balance asks for Railgun's head
  /// ([PrivateUsdRailgunHeads]): one rate for every wallet, whatever it
  /// expects.
  static const headPoll = Duration(seconds: 30);

  /// A watched balance refreshes at least this often, so a head that stops
  /// moving hides nothing and screening's verdicts still come in.
  static const backstop = Duration(minutes: 10);

  /// Opening the Private USD screen refreshes a balance older than this.
  static const openedAge = Duration(seconds: 30);

  /// A refresh gives up after this...
  static const refreshTimeout = Duration(minutes: 5);

  /// ...or after this while nothing has been shown yet: it may be the
  /// wallet's first sync, which reads all of Railgun's history.
  static const firstSyncTimeout = Duration(hours: 2);

  /// How often the first-sync percentage creeps between engine reports.
  static const firstSyncTick = Duration(seconds: 3);
}

/// The private USD balance of one account, as the home strip and the
/// Private USD screen show it.
class PrivateUsdBalanceState {
  const PrivateUsdBalanceState({
    this.balances,
    this.updatedAt,
    this.address,
    this.isRefreshing = false,
    this.refreshFailed = false,
    this.rpcFailed = false,
    this.screeningFailed = false,
    this.firstSyncPercent,
    this.refreshPercent,
    this.received = const [],
    this.shieldingSince,
    this.syncing = false,
  });

  /// Null until a sync or the cache has something to show.
  final PrivateUsdBalances? balances;
  final DateTime? updatedAt;

  /// The `0zk` address [balances] belong to.
  final String? address;
  final bool isRefreshing;
  final bool refreshFailed;

  /// The last refresh failed while the Ethereum RPC did not answer, or
  /// turned requests away, and none has succeeded since: the screen offers
  /// another RPC. It outlives the retries, which show as loading, until a
  /// sync succeeds or the user changes the RPC.
  final bool rpcFailed;

  /// The last sync found the screening failing ([RailgunScreening.failed]),
  /// so what is processing is waiting on the screening nodes, not on a send.
  /// Never cached: a cached balance shows without it.
  final bool screeningFailed;

  /// How far the wallet's first sync has come, while nothing shows yet.
  final int? firstSyncPercent;

  /// How far a refresh the user waits on has come, in whole percent below
  /// 100, while it runs: one asked for outright, or by opening the screen.
  /// Null for the automatic ones, which show no percentage.
  final int? refreshPercent;

  /// The private sends the wallet received, as the last sync that could read
  /// them found them. Never cached.
  final List<RailgunReceipt> received;

  /// When the newest dollar shield screening still holds landed, as the last
  /// sync that could read it found it; null with none, or none dated. Never
  /// cached.
  final DateTime? shieldingSince;

  /// The rest of the last sync runs on in the page ([RailgunRefresh.syncing]):
  /// Railgun's transaction list, which the change from the wallet's own
  /// sends waits on. Never cached.
  final bool syncing;

  /// No balance yet, and one is on its way.
  bool get isLoading => balances == null && (!refreshFailed || isRefreshing);

  PrivateUsdBalanceState copyWith({
    PrivateUsdBalances? balances,
    DateTime? updatedAt,
    String? address,
    bool? isRefreshing,
    bool? refreshFailed,
    bool? rpcFailed,
    bool? screeningFailed,
    int? firstSyncPercent,
    bool clearFirstSyncPercent = false,
    int? refreshPercent,
    bool clearRefreshPercent = false,
    List<RailgunReceipt>? received,
    DateTime? shieldingSince,
    bool clearShieldingSince = false,
    bool? syncing,
  }) => PrivateUsdBalanceState(
    balances: balances ?? this.balances,
    updatedAt: updatedAt ?? this.updatedAt,
    address: address ?? this.address,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    refreshFailed: refreshFailed ?? this.refreshFailed,
    rpcFailed: rpcFailed ?? this.rpcFailed,
    screeningFailed: screeningFailed ?? this.screeningFailed,
    firstSyncPercent: clearFirstSyncPercent
        ? null
        : (firstSyncPercent ?? this.firstSyncPercent),
    refreshPercent: clearRefreshPercent
        ? null
        : (refreshPercent ?? this.refreshPercent),
    received: received ?? this.received,
    shieldingSince: clearShieldingSince
        ? null
        : (shieldingSince ?? this.shieldingSince),
    syncing: syncing ?? this.syncing,
  );

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdBalanceState &&
      other.balances == balances &&
      other.updatedAt == updatedAt &&
      other.address == address &&
      other.isRefreshing == isRefreshing &&
      other.refreshFailed == refreshFailed &&
      other.rpcFailed == rpcFailed &&
      other.screeningFailed == screeningFailed &&
      other.firstSyncPercent == firstSyncPercent &&
      other.refreshPercent == refreshPercent &&
      listEquals(other.received, received) &&
      other.shieldingSince == shieldingSince &&
      other.syncing == syncing;

  @override
  int get hashCode => Object.hash(
    balances,
    updatedAt,
    address,
    isRefreshing,
    refreshFailed,
    rpcFailed,
    screeningFailed,
    firstSyncPercent,
    refreshPercent,
    Object.hashAll(received),
    shieldingSince,
    syncing,
  );
}

/// Railgun's head as its indexer lists it, shared by every watched balance:
/// asked for at one rate whatever the wallets expect, once however many
/// balances ask together. A balance refreshes once the head has moved past
/// the one its last successful refresh began with, and at the latest
/// [PrivateUsdBalanceTiming.backstop] after it, so its refreshes follow
/// Railgun's history, never what the wallet expects.
class PrivateUsdRailgunHeads {
  PrivateUsdRailgunHeads({
    required Future<String?> Function() read,
    required DateTime Function() now,
  }) : _read = read,
       _now = now;

  final Future<String?> Function() _read;
  final DateTime Function() _now;
  final _refreshedWith = <String, String>{};
  Future<String?>? _reading;
  String? _answer;
  DateTime? _answeredAt;
  String? _latest;

  // Balances that ask within this of each other share one request.
  static const _shared = Duration(seconds: 25);

  /// The newest head read; null before one was.
  String? get latest => _latest;

  /// Railgun's head now: null when it could not be read.
  Future<String?> read() {
    final at = _answeredAt;
    if (at != null && _now().difference(at) < _shared) {
      return Future.value(_answer);
    }
    return _reading ??= _read()
        .then((head) {
          _answer = head;
          _answeredAt = _now();
          if (head != null) _latest = head;
          return head;
        })
        .whenComplete(() => _reading = null);
  }

  /// Whether [account]'s balance, [age] old (null for none shown), refreshes
  /// now, Railgun's head being [head] (null when it could not be read).
  /// Before [account]'s first refresh, a head counts as moved unless the
  /// balance is younger than [PrivateUsdBalanceTiming.headPoll], when it is
  /// taken as that balance's.
  bool shouldRefresh(String account, String? head, {required Duration? age}) {
    if (age == null || age >= PrivateUsdBalanceTiming.backstop) return true;
    final refreshedWith = _refreshedWith[account];
    if (head == null || head == refreshedWith) return false;
    if (refreshedWith == null && age < PrivateUsdBalanceTiming.headPoll) {
      _refreshedWith[account] = head;
      return false;
    }
    return true;
  }

  /// [account]'s refresh that began with [head] the newest head read went
  /// through.
  void refreshed(String account, String? head) {
    if (head != null) _refreshedWith[account] = head;
  }
}

/// Automatic refreshes wait longer after each failure in a row: 30 s, then
/// doubling up to 32 times that. A refresh asked for outright ignores it.
class PrivateUsdBalanceRetries {
  PrivateUsdBalanceRetries(this._now);

  final DateTime Function() _now;
  int _failures = 0;
  DateTime? _dueAt;

  static const _firstRetry = Duration(seconds: 30);
  static const _maxDoublings = 5;

  bool get isDue {
    final dueAt = _dueAt;
    return dueAt == null || !_now().isBefore(dueAt);
  }

  void record({required bool succeeded}) {
    _failures = succeeded ? 0 : _failures + 1;
    _dueAt = succeeded
        ? null
        : _now().add(
            _firstRetry * (1 << math.min(_failures - 1, _maxDoublings)),
          );
  }
}

/// A first sync's progress, in percent of the time one takes until its
/// balance shows: Railgun's notes, which the quick sync reports by block as it
/// stores their history and the decryption batch by batch. Between two
/// reports the number creeps toward the next milestone's, slower the nearer it
/// gets, without passing it, and it never goes back: a report below what crept
/// leaves it where it is. Railgun's transaction list comes after the balance,
/// on the sync line.
class PrivateUsdFirstSyncProgress {
  PrivateUsdFirstSyncProgress({Duration Function()? elapsed})
    : _elapsed = elapsed ?? _stopwatch();

  final Duration Function() _elapsed;
  double _lastNotes = -1;
  Duration _notesSince = Duration.zero;
  int _shown = 0;

  /// Whether the number can move before the engine's next report.
  bool isCreeping = false;

  int? percent({RailgunScanEvent? notes}) {
    isCreeping = false;
    if (notes == null) return null;
    final percent = notes.status == RailgunScanStatus.complete
        ? _lastPercent
        : _notesPercent(notes.progress.clamp(0, 1).toDouble());
    return _shown = math.max(_shown, percent);
  }

  int _notesPercent(double progress) {
    if (progress != _lastNotes) {
      _lastNotes = progress;
      _notesSince = _elapsed();
    }
    final next = _notesSteps.indexWhere((step) => step.at > progress);
    if (next == -1) return _lastPercent;
    if (next == 0) return 0;
    final from = _notesSteps[next - 1];
    final to = _notesSteps[next];
    final done = (progress - from.at) / (to.at - from.at);
    final reported = from.percent + (to.percent - from.percent) * done;
    final waited = (_elapsed() - _notesSince).inMicroseconds;
    final expected = from.takes.inMicroseconds * (1 - done) / 2;
    final wait = expected <= 0 ? 0.0 : waited / expected;
    final crept = reported + (to.percent - reported) * (1 - math.exp(-wait));
    isCreeping = crept.toInt() + 1 < to.percent;
    return crept.toInt();
  }

  // The balance shows once the notes are in, a moment after 99.
  static const _lastPercent = 99;

  // The engine's notes milestones, each with how long the next one took on a
  // OnePlus 15 over 4G.
  static final _notesSteps = _steps(const [
    (0.03, Duration(seconds: 5)), // loading the network
    (0.10, Duration(minutes: 9)), // storing Railgun's history, by block
    (0.40, Duration(seconds: 10)),
    (0.50, Duration(seconds: 10)), // catching up with the chain
    (0.70, Duration(minutes: 4)), // finding this wallet's notes
    (0.97, Duration(seconds: 5)),
    (1.0, Duration.zero),
  ]);

  static List<_NotesStep> _steps(List<(double, Duration)> steps) {
    final total = steps.fold(Duration.zero, (sum, step) => sum + step.$2);
    var before = Duration.zero;
    final result = <_NotesStep>[];
    for (final (at, takes) in steps) {
      result.add(
        _NotesStep(
          at: at,
          takes: takes,
          percent: _lastPercent * before.inMicroseconds / total.inMicroseconds,
        ),
      );
      before += takes;
    }
    return result;
  }

  static Duration Function() _stopwatch() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}

class _NotesStep {
  const _NotesStep({
    required this.at,
    required this.takes,
    required this.percent,
  });

  final double at;
  final Duration takes;
  final double percent;
}
