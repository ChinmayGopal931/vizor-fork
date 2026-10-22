import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_security_provider.dart';
import '../models/private_usd_record_key.dart';
import 'private_usd_unfinished_provider.dart';

/// The progress screens showing now, so the screen stays awake while a key
/// step is pending.
final privateUsdProgressVisibleProvider =
    NotifierProvider<
      PrivateUsdProgressVisibleNotifier,
      Set<PrivateUsdRecordKey>
    >(PrivateUsdProgressVisibleNotifier.new);

class PrivateUsdProgressVisibleNotifier
    extends Notifier<Set<PrivateUsdRecordKey>> {
  @override
  Set<PrivateUsdRecordKey> build() => const {};

  void show(PrivateUsdRecordKey key) => state = {...state, key};

  void hide(PrivateUsdRecordKey key) => state = {...state}..remove(key);
}

/// One first sync of an account's Railgun wallet, running: the sync of a
/// wallet that never completed one, which reads all of Railgun's history.
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
/// unlocked. One can take an hour, and screen-off means background, where
/// Android may throttle the page and iOS suspends it. Locked, the page
/// closes and the sync with it.
final privateUsdFirstSyncKeepAwakeProvider = Provider<bool>((ref) {
  if (ref.watch(privateUsdFirstSyncsProvider).isEmpty) return false;
  return !ref.watch(appSecurityProvider.select((s) => s.requiresUnlock));
});

/// Keeps the screen awake while a conversion's progress shows and a key
/// step (deposit, claim, sweep) is still to come: screen-off means
/// background, and background means pause. Not once the relayer holds the
/// claim, which it sends without the app. Also through a Railgun first sync
/// ([privateUsdFirstSyncKeepAwakeProvider]). OR-ed into
/// `SyncKeepAwakeNativeHost`, which owns the one native flag and lets go in
/// the background.
final privateUsdKeepAwakeProvider = Provider<bool>((ref) {
  if (ref.watch(privateUsdFirstSyncKeepAwakeProvider)) return true;
  final visible = ref.watch(privateUsdProgressVisibleProvider);
  if (visible.isEmpty) return false;
  final unfinished = ref.watch(privateUsdUnfinishedProvider);
  final conversions = ref.watch(privateUsdConversionsProvider);
  return visible.any(
    (key) =>
        unfinished.contains(key) &&
        !(conversions[key]?.claimHandedOver ?? false),
  );
});
