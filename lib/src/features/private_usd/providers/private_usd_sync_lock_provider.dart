import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/private_usd_balance_repository.dart';
import 'private_usd_balance_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_keep_awake_provider.dart';
import 'railgun_engine_provider.dart';

/// Where Railgun's sync stands, for the wallet sync's privacy lock.
enum PrivateUsdSyncStatus {
  /// It keeps the screen on ([privateUsdFirstSyncKeepAwakeProvider]).
  syncing,

  /// The page's wallet has a sync's balances, and nothing more runs.
  synced,

  /// It stopped before the page's wallet had a balance: it failed, or the
  /// page closed.
  paused,
}

/// Where Railgun's sync stands now ([PrivateUsdSyncStatus]).
final privateUsdSyncStatusProvider = Provider<PrivateUsdSyncStatus>((ref) {
  if (ref.watch(privateUsdFirstSyncKeepAwakeProvider)) {
    return PrivateUsdSyncStatus.syncing;
  }
  // Only where the engine runs: nothing else builds it.
  if (!ref.watch(privateUsdEngineEnabledProvider)) {
    return PrivateUsdSyncStatus.paused;
  }
  final synced = ref.watch(
    railgunEngineStateProvider.select((engine) {
      final lastSync = engine.lastSync;
      // A closed page names no wallet, and keeps the last sync's.
      return lastSync != null &&
          (engine.accountUuid == null ||
              lastSync.accountUuid == engine.accountUuid);
    }),
  );
  return synced ? PrivateUsdSyncStatus.synced : PrivateUsdSyncStatus.paused;
});

/// What Railgun's sync is doing, as the privacy lock names it.
enum PrivateUsdSyncLockStage {
  /// The first sync, until the balance shows.
  balance,

  /// Railgun's transaction list, which the change from the wallet's own
  /// sends waits on: after a first sync's balance, or a long catch-up.
  transactions,
  synced,
  paused,
}

/// Railgun's ring on the privacy lock: how far its sync has come, 0 to 1,
/// and what it is doing.
@immutable
class PrivateUsdSyncLockTrack {
  const PrivateUsdSyncLockTrack({required this.progress, required this.stage});

  final double progress;
  final PrivateUsdSyncLockStage stage;

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdSyncLockTrack &&
      other.progress == progress &&
      other.stage == stage;

  @override
  int get hashCode => Object.hash(progress, stage);
}

/// Railgun's sync as its ring shows it, in the Shielded USD screen's own
/// figures: a first sync climbs to its balance (the screen's first-sync
/// percentage, [balance]'s `firstSyncPercent`), and Railgun's transaction
/// list, which syncs on after the balance or in a long catch-up, climbs
/// again, as far as the page has caught up on it ([txids], the screening
/// activity's share). The line under the rings names which climb it is.
PrivateUsdSyncLockTrack privateUsdSyncLockTrack({
  required PrivateUsdSyncStatus status,
  required PrivateUsdBalanceState balance,
  double? txids,
}) {
  final hasBalance = balance.balances != null;
  final stage = switch (status) {
    PrivateUsdSyncStatus.synced => PrivateUsdSyncLockStage.synced,
    PrivateUsdSyncStatus.paused => PrivateUsdSyncLockStage.paused,
    PrivateUsdSyncStatus.syncing when hasBalance =>
      PrivateUsdSyncLockStage.transactions,
    PrivateUsdSyncStatus.syncing => PrivateUsdSyncLockStage.balance,
  };
  final progress = switch (stage) {
    PrivateUsdSyncLockStage.synced => 1.0,
    _ when !hasBalance => (balance.firstSyncPercent ?? 0) / 100,
    _ => txids ?? 0,
  };
  return PrivateUsdSyncLockTrack(
    progress: progress.clamp(0.0, 1.0),
    stage: stage,
  );
}

/// Railgun's ring on the privacy lock ([privateUsdSyncLockTrack]), for the
/// wallet whose first sync runs, else the open page's. Within a climb it
/// never goes back while the lock shows it: a step the page stops
/// reporting, as the transaction list's at its end, leaves the ring where it
/// was. The transaction list's climb starts again from its own figure.
final privateUsdSyncLockTrackProvider =
    NotifierProvider.autoDispose<
      PrivateUsdSyncLockTrackNotifier,
      PrivateUsdSyncLockTrack
    >(PrivateUsdSyncLockTrackNotifier.new);

class PrivateUsdSyncLockTrackNotifier
    extends Notifier<PrivateUsdSyncLockTrack> {
  ProviderSubscription<PrivateUsdBalanceState>? _balance;
  String? _balanceOf;

  @override
  PrivateUsdSyncLockTrack build() {
    if (!ref.watch(privateUsdEngineEnabledProvider)) {
      return const PrivateUsdSyncLockTrack(
        progress: 0,
        stage: PrivateUsdSyncLockStage.paused,
      );
    }
    // Listened rather than watched: a rebuild would forget what it showed.
    ref.listen(privateUsdSyncStatusProvider, (_, _) => _update());
    ref.listen(privateUsdFirstSyncsProvider, (_, _) => _update());
    ref.listen(railgunEngineStateProvider, (_, _) => _update());
    return _track();
  }

  void _update() => state = _track(shown: state);

  PrivateUsdSyncLockTrack _track({PrivateUsdSyncLockTrack? shown}) {
    final syncs = ref.read(privateUsdFirstSyncsProvider);
    final engine = ref.read(railgunEngineStateProvider);
    final accountUuid = syncs.isNotEmpty
        ? syncs.first.accountUuid
        : engine.accountUuid ?? engine.lastSync?.accountUuid;
    final track = privateUsdSyncLockTrack(
      status: ref.read(privateUsdSyncStatusProvider),
      balance: _balanceFor(accountUuid),
      // The screening activity is the open page's.
      txids: engine.accountUuid == accountUuid ? engine.screening?.txids : null,
    );
    // The transaction list climbs from its own figure once the balance shows.
    final newClimb =
        shown == null ||
        (track.stage == PrivateUsdSyncLockStage.transactions &&
            shown.stage == PrivateUsdSyncLockStage.balance);
    return newClimb
        ? track
        : PrivateUsdSyncLockTrack(
            progress: math.max(shown.progress, track.progress),
            stage: track.stage,
          );
  }

  PrivateUsdBalanceState _balanceFor(String? accountUuid) {
    if (accountUuid != _balanceOf) {
      _balance?.close();
      _balance = accountUuid == null
          ? null
          : ref.listen(
              privateUsdBalanceProvider(accountUuid),
              (_, _) => _update(),
            );
      _balanceOf = accountUuid;
    }
    return _balance?.read() ?? const PrivateUsdBalanceState();
  }
}
