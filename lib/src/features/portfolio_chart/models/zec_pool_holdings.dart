import 'package:flutter/foundation.dart';

import '../../../providers/sync_provider.dart';
import '../../home/services/transparent_balance_display.dart';

/// One shielded pool's ZEC; [total] includes the [pending] part that waits for
/// confirmations.
typedef ShieldedPoolHoldings = ({BigInt total, BigInt pending});

/// The active account's ZEC by pool, from the `display*` snapshot the Home
/// sign reads, so the rows add up to the sign while a catch-up sync holds
/// it. The snapshot has no Sapling total: Sapling is what its shielded total
/// leaves.
@immutable
class ZecPoolHoldings {
  ZecPoolHoldings.of(SyncState sync)
    : hasBalance = sync.hasDisplayBalance,
      ironwood = (
        total: sync.displayIronwoodBalance + sync.displayIronwoodPendingBalance,
        pending: sync.displayIronwoodPendingBalance,
      ),
      orchard = (
        total: sync.displayOrchardBalance + sync.displayOrchardPendingBalance,
        pending: sync.displayOrchardPendingBalance,
      ),
      sapling = _sapling(sync),
      transparent = TransparentBalanceDisplay.of(sync),
      transparentPending = sync.transparentPendingBalance;

  static ShieldedPoolHoldings _sapling(SyncState sync) {
    final rest =
        sync.displayShieldedBalance -
        sync.displayIronwoodBalance -
        sync.displayIronwoodPendingBalance -
        sync.displayOrchardBalance -
        sync.displayOrchardPendingBalance;
    final total = rest.isNegative ? BigInt.zero : rest;
    final pending = sync.displaySaplingPendingBalance;
    return (total: total, pending: pending > total ? total : pending);
  }

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
