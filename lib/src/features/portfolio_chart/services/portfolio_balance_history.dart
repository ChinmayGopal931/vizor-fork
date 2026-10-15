import 'package:flutter/foundation.dart';

/// One block's net effect on an account's balance, read from the wallet
/// database. This is the only wallet data the portfolio chart uses, and it
/// never leaves the device.
@immutable
class BalanceDelta {
  const BalanceDelta({
    required this.height,
    required this.time,
    required this.zatoshi,
  });

  final int height;

  /// The block's time.
  final DateTime time;

  /// Signed: negative for spends, including the fee.
  final int zatoshi;
}

/// The balance from [time] until the next step.
@immutable
class BalanceStep {
  const BalanceStep(this.time, this.zatoshi);

  final DateTime time;
  final int zatoshi;
}

/// A step function of an account's balance over time.
@immutable
class BalanceHistory {
  const BalanceHistory(this.steps);

  /// Ascending in time; each holds the balance after that moment.
  final List<BalanceStep> steps;

  int get currentZatoshi => steps.isEmpty ? 0 : steps.last.zatoshi;

  /// The balance at [time]: zero before the first step.
  int balanceAt(DateTime time) {
    var low = 0;
    var high = steps.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (steps[middle].time.isAfter(time)) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low == 0 ? 0 : steps[low - 1].zatoshi;
  }
}

/// Folds per-block deltas into a balance history.
///
/// Blocks are ordered by height, not by time, so a block whose time is a few
/// seconds out of order cannot reorder the history; a time that would run
/// backwards is held at the previous step's. Deltas in one block are summed
/// first, because the order of transactions inside a block is not known.
///
/// Returns `null` when the deltas cannot describe a real history: the balance
/// would go negative, which means a receive is missing, usually because the
/// wallet has not finished scanning.
BalanceHistory? buildBalanceHistory(Iterable<BalanceDelta> deltas) {
  final sorted = deltas.toList()..sort((a, b) => a.height.compareTo(b.height));
  final steps = <BalanceStep>[];
  var balance = 0;
  DateTime? previousTime;
  var index = 0;
  while (index < sorted.length) {
    final height = sorted[index].height;
    var net = 0;
    var time = sorted[index].time;
    while (index < sorted.length && sorted[index].height == height) {
      net += sorted[index].zatoshi;
      if (sorted[index].time.isAfter(time)) time = sorted[index].time;
      index++;
    }
    if (net == 0) continue;
    balance += net;
    if (balance < 0) return null;
    final previous = previousTime;
    if (previous != null && time.isBefore(previous)) time = previous;
    steps.add(BalanceStep(time, balance));
    previousTime = time;
  }
  return BalanceHistory(steps);
}
