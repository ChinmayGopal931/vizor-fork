import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/private_usd_record_key.dart';
import 'private_usd_unfinished_provider.dart';

/// The progress screens showing now, so the screen stays awake while a key
/// step is pending (X8).
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

/// Keeps the screen awake while a conversion's progress shows and a key
/// step (deposit, claim, sweep) is still to come: under D9 screen-off means
/// background, and background means pause (X8). OR-ed into
/// `SyncKeepAwakeNativeHost`, which owns the one native flag.
final privateUsdKeepAwakeProvider = Provider<bool>((ref) {
  final visible = ref.watch(privateUsdProgressVisibleProvider);
  if (visible.isEmpty) return false;
  final unfinished = ref.watch(privateUsdUnfinishedProvider);
  return visible.any(unfinished.contains);
});
