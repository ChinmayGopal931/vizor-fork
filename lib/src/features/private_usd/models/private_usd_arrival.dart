import '../../../rust/api/private_usd.dart' as rust;
import '../private_usd_copy.dart';

/// When the private USD arriving now landed, as far as the account's own
/// conversions tell (owner, 2026-10-17); null when they don't. Every payout
/// into the private balance waits out the same screening, so the newest one
/// clears last, and it is the one the estimate follows:
///
/// - a paid conversion's payout, by the time Rust read it confirmed
///   (`endedAt`, this device's clock; the progress screen reads the same);
/// - a refunded USD to ZEC conversion's refund, by its record's last change
///   (`updatedAt`: the refund paid, or a rescue after it).
///
/// The page reports balances only, with no note's time, and funds shielded
/// from elsewhere carry no time this app knows. So when [arriving]
/// (micro-dollars) is less than the newest payout paid, that payout is not
/// what is arriving (it cleared, or the balance does not show it yet):
/// null. A paid conversion keeps what it paid (`receives`, in the 6-decimal
/// swap token's base units, so micro-dollars); a refund's record does not,
/// so a refund is taken as it comes.
///
/// A deposit (M9) that landed counts as a payout does: it landed when the
/// pass saw its mined event (`endedAt`), and brought what the contract
/// shielded less Railgun's fee (`arrives`).
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

/// The Arriving row's label at [now] (owner, 2026-10-17): the share of the
/// [screening] period gone by since the funds landed at [since], in whole
/// percent and never 100 ("Arriving · 40%"); once the period has passed
/// with them still arriving, "Arriving · taking longer than usual"; plain
/// "Arriving" without a landing time or a period.
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
