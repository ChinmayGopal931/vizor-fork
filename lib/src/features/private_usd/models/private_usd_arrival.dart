import '../../../rust/api/private_usd.dart' as rust;
import '../private_usd_copy.dart';

/// When the private USD arriving now landed, as far as the account's own
/// payouts tell; null when they don't. Every payout waits out the same
/// screening, so the newest clears last and the estimate follows it: a paid
/// conversion's (`endedAt`, as Rust read it confirmed), a refunded USD → ZEC
/// conversion's (`updatedAt`) or a landed deposit's (`endedAt`). The page
/// reports balances only, so when [arriving] (micro-dollars) is less than
/// what the newest payout brought (`receives`, `arrives`), that payout is not
/// what is arriving: null. A refund keeps no amount; it is taken as it comes.
DateTime? privateUsdArrivingSince({
  required BigInt arriving,
  Iterable<rust.ApiForwardRecord> forward = const [],
  Iterable<rust.ApiReverseRecord> reverse = const [],
  Iterable<rust.ApiDepositRecord> deposits = const [],
}) {
  if (arriving <= BigInt.zero) return null;
  int? landedAt;
  BigInt? amount;
  for (final record in forward) {
    final endedAt = record.endedAt;
    if (record.outcome != rust.ApiForwardOutcome.paid || endedAt == null) {
      continue;
    }
    if (landedAt == null || endedAt > landedAt) {
      landedAt = endedAt;
      amount = BigInt.tryParse(record.receives);
    }
  }
  for (final record in reverse) {
    if (record.phase != rust.ApiReversePhase.refunded) continue;
    if (landedAt == null || record.updatedAt > landedAt) {
      landedAt = record.updatedAt;
      amount = null;
    }
  }
  for (final record in deposits) {
    final endedAt = record.endedAt;
    if (record.state != rust.ApiDepositState.landed || endedAt == null) {
      continue;
    }
    if (landedAt == null || endedAt > landedAt) {
      landedAt = endedAt;
      amount = BigInt.tryParse(record.arrives);
    }
  }
  if (landedAt == null || (amount != null && arriving < amount)) return null;
  return DateTime.fromMillisecondsSinceEpoch(landedAt * 1000);
}

/// The Arriving row's label at [now]: the share of the [screening] period
/// gone by since the funds landed at [since], in whole percent and never 100
/// ([PrivateUsdCopy.rowArrivingPercent]); once the period has passed with
/// them still arriving, [PrivateUsdCopy.rowArrivingLate]; plain
/// [PrivateUsdCopy.rowArriving] without a landing time or a period.
String privateUsdArrivingLabel({
  required DateTime? since,
  required Duration screening,
  required DateTime now,
}) {
  if (since == null || screening <= Duration.zero) {
    return PrivateUsdCopy.rowArriving;
  }
  final elapsed = now.difference(since);
  if (elapsed >= screening) return PrivateUsdCopy.rowArrivingLate;
  // A landing time ahead of this clock counts as just landed.
  final percent = elapsed.isNegative
      ? 0
      : elapsed.inMicroseconds * 100 ~/ screening.inMicroseconds;
  return PrivateUsdCopy.rowArrivingPercent(percent);
}
