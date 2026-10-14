import 'dart:math' as math;

import '../models/private_usd_balances.dart';
import '../models/railgun_models.dart';

/// How often a watched balance is looked at, and how stale it may get
/// (plan reference §6.6; zapp `PrivateUsdBalanceRepository`).
abstract final class PrivateUsdBalanceTiming {
  /// The polling tick, and the freshness wanted while funds arrive.
  static const arrivingPoll = Duration(seconds: 30);

  /// The freshness wanted otherwise.
  static const staleAfter = Duration(minutes: 5);

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
    this.firstSyncPercent,
  });

  /// Null until a sync or the cache has something to show.
  final PrivateUsdBalances? balances;
  final DateTime? updatedAt;

  /// The `0zk` address [balances] belong to.
  final String? address;
  final bool isRefreshing;
  final bool refreshFailed;

  /// How far the wallet's first sync has come, while nothing shows yet.
  final int? firstSyncPercent;

  /// No balance yet, and one is on its way.
  bool get isLoading => balances == null && (!refreshFailed || isRefreshing);

  PrivateUsdBalanceState copyWith({
    PrivateUsdBalances? balances,
    DateTime? updatedAt,
    String? address,
    bool? isRefreshing,
    bool? refreshFailed,
    int? firstSyncPercent,
    bool clearFirstSyncPercent = false,
  }) => PrivateUsdBalanceState(
    balances: balances ?? this.balances,
    updatedAt: updatedAt ?? this.updatedAt,
    address: address ?? this.address,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    refreshFailed: refreshFailed ?? this.refreshFailed,
    firstSyncPercent: clearFirstSyncPercent
        ? null
        : (firstSyncPercent ?? this.firstSyncPercent),
  );

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdBalanceState &&
      other.balances == balances &&
      other.updatedAt == updatedAt &&
      other.address == address &&
      other.isRefreshing == isRefreshing &&
      other.refreshFailed == refreshFailed &&
      other.firstSyncPercent == firstSyncPercent;

  @override
  int get hashCode => Object.hash(
    balances,
    updatedAt,
    address,
    isRefreshing,
    refreshFailed,
    firstSyncPercent,
  );
}

/// Something is in screening, so the balance is worth looking at often.
/// A forward payout landing (M5) will count too.
bool isPrivateUsdArriving(PrivateUsdBalanceState state) =>
    (state.balances?.arriving ?? BigInt.zero) > BigInt.zero;

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

/// A first sync's progress, in percent of the time one takes: Railgun's
/// notes, then the transaction ids its screening needs (zapp
/// `FirstSyncProgress`). The engine reports the notes at milestones that can
/// be minutes apart, so between two the number creeps toward the next one's,
/// slower the nearer it gets, without passing it. The ids come in batches
/// whose progress each starts over, so every batch covers part of what is
/// left and the number never goes back.
class PrivateUsdFirstSyncProgress {
  PrivateUsdFirstSyncProgress({Duration Function()? elapsed})
    : _elapsed = elapsed ?? _stopwatch();

  final Duration Function() _elapsed;
  int _idBatches = 0;
  double _lastIds = 0;
  double _lastNotes = -1;
  Duration _notesSince = Duration.zero;

  /// Whether the number can move before the engine's next report.
  bool isCreeping = false;

  int? percent({RailgunScanEvent? notes, RailgunScanEvent? ids}) {
    isCreeping = false;
    if (notes == null) return null;
    if (notes.status != RailgunScanStatus.complete) {
      _idBatches = 0;
      _lastIds = 0;
      return _notesPercent(notes.progress.clamp(0, 1).toDouble());
    }
    if (ids == null) return _notesShare;
    if (ids.status == RailgunScanStatus.complete) return _lastPercent;
    if (ids.progress < _lastIds) _idBatches += 1;
    _lastIds = ids.progress;
    final left = math.pow(
      _idBatchLeft,
      _idBatches + ids.progress.clamp(0, 1).toDouble(),
    );
    return _lastPercent - ((_lastPercent - _notesShare) * left).toInt();
  }

  int _notesPercent(double progress) {
    if (progress != _lastNotes) {
      _lastNotes = progress;
      _notesSince = _elapsed();
    }
    final next = _notesSteps.indexWhere((step) => step.at > progress);
    if (next == -1) return _notesShare;
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

  // On Ethereum the notes take about 60% of a first sync, and each of its 15
  // or so id batches leaves 85% of the rest.
  static const _notesShare = 60;
  static const _lastPercent = 99;
  static const _idBatchLeft = 0.85;

  // The engine's notes milestones, each with how long the next one took on a
  // Galaxy A35 over Wi-Fi.
  static final _notesSteps = _steps(const [
    (0.03, Duration(seconds: 5)), // loading the network
    (0.10, Duration(minutes: 6)), // downloading Railgun's history
    (0.15, Duration(minutes: 7)), // saving its unshields
    (0.25, Duration(minutes: 4)), // and nullifiers
    (0.30, Duration(minutes: 16)), // building its trees
    (0.40, Duration(seconds: 5)),
    (0.50, Duration(seconds: 5)), // catching up with the chain
    (0.70, Duration(minutes: 6)), // finding this wallet's notes
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
          percent: _notesShare * before.inMicroseconds / total.inMicroseconds,
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
