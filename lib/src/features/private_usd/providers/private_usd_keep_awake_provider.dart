import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_security_provider.dart';
import '../../../rust/api/private_usd.dart' show ApiReversePhase;
import '../models/private_usd_record_key.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';
import 'railgun_engine_provider.dart';

/// The bridges whose screen may sleep: the user turned "Keep screen on" off
/// on their progress. Every other bridge keeps the screen on while it needs
/// Veylor ([privateUsdBridgeKeepAwakeProvider]).
final privateUsdScreenMaySleepProvider =
    NotifierProvider<
      PrivateUsdScreenMaySleepNotifier,
      Set<PrivateUsdRecordKey>
    >(PrivateUsdScreenMaySleepNotifier.new);

class PrivateUsdScreenMaySleepNotifier
    extends Notifier<Set<PrivateUsdRecordKey>> {
  @override
  Set<PrivateUsdRecordKey> build() => const {};

  void keepScreenOn(PrivateUsdRecordKey key, {required bool on}) =>
      state = on ? ({...state}..remove(key)) : {...state, key};
}

/// One first sync of an account's Railgun wallet, running: the sync of a
/// wallet that never completed one, which reads all of Railgun's history, or
/// the catch-up of one last synced more than
/// `PrivateUsdBalanceTiming.longCatchUpAge` ago.
class PrivateUsdFirstSync {
  PrivateUsdFirstSync._(this._syncs, this.accountUuid);

  final PrivateUsdFirstSyncsNotifier _syncs;
  final String accountUuid;

  /// It completed or failed. Idempotent.
  void end() => _syncs._end(this);
}

/// The Railgun first syncs running now, whichever screen started them: the
/// sync goes on in the page when its screen closes.
final privateUsdFirstSyncsProvider =
    NotifierProvider<PrivateUsdFirstSyncsNotifier, Set<PrivateUsdFirstSync>>(
      PrivateUsdFirstSyncsNotifier.new,
    );

class PrivateUsdFirstSyncsNotifier extends Notifier<Set<PrivateUsdFirstSync>> {
  @override
  Set<PrivateUsdFirstSync> build() => const {};

  PrivateUsdFirstSync begin(String accountUuid) {
    final sync = PrivateUsdFirstSync._(this, accountUuid);
    state = {...state, sync};
    return sync;
  }

  void _end(PrivateUsdFirstSync sync) {
    if (!ref.mounted || !state.contains(sync)) return;
    state = {...state}..remove(sync);
  }
}

/// Keeps the screen awake while a Railgun first sync runs and the wallet is
/// unlocked: until its balance shows, then while the rest of a sync, Railgun's
/// transaction list, runs long in the page (`RailgunSync.syncing`), however
/// many refreshes it takes. One can take an hour, and screen-off means
/// background, where Android may throttle the page and iOS suspends it.
/// Locked, the page closes and the sync with it.
final privateUsdFirstSyncKeepAwakeProvider = Provider<bool>((ref) {
  if (ref.watch(appSecurityProvider.select((s) => s.requiresUnlock))) {
    return false;
  }
  if (ref.watch(privateUsdFirstSyncsProvider).isNotEmpty) return true;
  // Only where the engine runs, which its sender keeps alive anyway.
  if (!ref.watch(privateUsdEngineEnabledProvider)) return false;
  return ref.watch(
    railgunEngineStateProvider.select(
      (state) => state.lastSync?.syncing ?? false,
    ),
  );
});

/// Keeps the screen awake while a bridge needs Veylor and the wallet is
/// unlocked, whichever screen shows: screen-off means background, and
/// background means pause. Not once the relayer holds the claim, which it
/// sends without the app, nor for a bridge whose screen may sleep
/// ([privateUsdScreenMaySleepProvider]). Locked, no step runs.
final privateUsdBridgeKeepAwakeProvider = Provider<bool>((ref) {
  final unfinished = ref.watch(privateUsdUnfinishedProvider);
  if (unfinished.isEmpty) return false;
  if (ref.watch(appSecurityProvider.select((s) => s.requiresUnlock))) {
    return false;
  }
  final maySleep = ref.watch(privateUsdScreenMaySleepProvider);
  final conversions = ref.watch(privateUsdConversionsProvider);
  return unfinished.any(
    (key) =>
        !maySleep.contains(key) &&
        !(conversions[key]?.claimHandedOver ?? false),
  );
});

/// The phases of a USD → ZEC bridge before the user authorized settlement:
/// one of their two approvals is due now or comes next.
const _beforeSettlement = {
  ApiReversePhase.accepting,
  ApiReversePhase.awaitingFunding,
  ApiReversePhase.sendingUsdc,
  ApiReversePhase.confirmingEscrow,
  ApiReversePhase.receivingZec,
  ApiReversePhase.awaitingReady,
};

/// A USD → ZEC bridge still needs the user's approval, now or next (its
/// payment, or "Authorize settlement" once the maker's ZEC is in), while the
/// wallet is unlocked and its screen is kept on: the wallet sync's idle
/// privacy lock does not cover the app, so the approval never shows behind
/// it. From the authorization on, the bridge runs on under the lock.
final privateUsdBridgeAwaitsUserProvider = Provider<bool>((ref) {
  if (ref.watch(appSecurityProvider.select((s) => s.requiresUnlock))) {
    return false;
  }
  final maySleep = ref.watch(privateUsdScreenMaySleepProvider);
  return ref
      .watch(privateUsdReverseConversionsProvider)
      .entries
      .any(
        (entry) =>
            _beforeSettlement.contains(entry.value.record.phase) &&
            !entry.value.record.cancelRequested &&
            !maySleep.contains(entry.key),
      );
});

/// Keeps the screen awake through a bridge that needs Veylor
/// ([privateUsdBridgeKeepAwakeProvider]) or a Railgun first sync
/// ([privateUsdFirstSyncKeepAwakeProvider]). OR-ed into
/// `SyncKeepAwakeNativeHost`, which owns the one native flag and lets go in
/// the background.
final privateUsdKeepAwakeProvider = Provider<bool>(
  (ref) =>
      ref.watch(privateUsdFirstSyncKeepAwakeProvider) ||
      ref.watch(privateUsdBridgeKeepAwakeProvider),
);
