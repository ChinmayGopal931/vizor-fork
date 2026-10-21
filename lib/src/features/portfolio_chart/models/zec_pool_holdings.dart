import 'package:flutter/foundation.dart';

import '../../../providers/sync_provider.dart';
import '../../home/services/transparent_balance_display.dart';

/// One shielded pool's ZEC; [total] includes the [pending] part that waits for
/// confirmations.
typedef ShieldedPoolHoldings = ({BigInt total, BigInt pending});

/// The active account's ZEC by pool, from the fields the Home sign reads.
///
/// Not the `display*` snapshot desktop Home and the migration surfaces read:
/// it has none for Sapling or transparent funds, and mixing the two could
/// leave the rows disagreeing with their own total and with the sign.
@immutable
class ZecPoolHoldings {
  ZecPoolHoldings.of(SyncState sync)
    : hasBalance = sync.hasBalanceData,
      ironwood = (
        total: sync.ironwoodBalance + sync.ironwoodPendingBalance,
        pending: sync.ironwoodPendingBalance,
      ),
      orchard = (
        total: sync.orchardBalance + sync.orchardPendingBalance,
        pending: sync.orchardPendingBalance,
      ),
      sapling = (
        total: sync.saplingBalance + sync.saplingPendingBalance,
        pending: sync.saplingPendingBalance,
      ),
      transparent = TransparentBalanceDisplay.of(sync),
      transparentPending = sync.transparentPendingBalance;

  /// Whether the account's balances have been read. Until then every amount
  /// is unknown, never zero.
  final bool hasBalance;
  final ShieldedPoolHoldings ironwood;
  final ShieldedPoolHoldings orchard;
  final ShieldedPoolHoldings sapling;

  /// Home's transparent row: the amount, or why it is not known.
  final TransparentBalanceDisplay transparent;

  /// The part of a current transparent amount that waits for confirmations.
  final BigInt transparentPending;

  /// Home's shielded balance: the three shielded pools, pending included.
  ShieldedPoolHoldings get shielded => (
    total: ironwood.total + orchard.total + sapling.total,
    pending: ironwood.pending + orchard.pending + sapling.pending,
  );

  @override
  bool operator ==(Object other) =>
      other is ZecPoolHoldings &&
      other.hasBalance == hasBalance &&
      other.ironwood == ironwood &&
      other.orchard == orchard &&
      other.sapling == sapling &&
      other.transparent.amount == transparent.amount &&
      other.transparent.authority == transparent.authority &&
      other.transparent.stop == transparent.stop &&
      other.transparentPending == transparentPending;

  @override
  int get hashCode => Object.hash(
    hasBalance,
    ironwood,
    orchard,
    sapling,
    transparent.amount,
    transparent.authority,
    transparent.stop,
    transparentPending,
  );
}
