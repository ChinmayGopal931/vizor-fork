import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/storage/app_secure_store.dart';
import 'private_usd_available_provider.dart';

/// Where the archive-sync setting is kept: one secure-storage key for the
/// app, which a full reset's wipe takes with the rest.
class PrivateUsdArchiveSyncStore {
  const PrivateUsdArchiveSyncStore(this._storage);

  final AppSecureStore _storage;

  static const _storageKey = 'vizor_private_usd_archive_sync_v1';

  /// The user's choice, or null while it is the default.
  Future<bool?> read() async {
    final stored = await _storage.readString(_storageKey);
    return stored == null ? null : stored == 'true';
  }

  Future<void> write(bool enabled) =>
      _storage.writeString(_storageKey, enabled ? 'true' : 'false');
}

final privateUsdArchiveSyncStoreProvider = Provider<PrivateUsdArchiveSyncStore>(
  (_) => PrivateUsdArchiveSyncStore(AppSecureStore.instance),
);

/// Whether the Railgun page can read Railgun's history from Anon's archive
/// here: Ethereum's archive, which only Android's host fetches for the page.
/// An OS difference, not a layout one.
final privateUsdArchiveAvailableProvider = Provider<bool>((ref) {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  final network = ref.watch(appBootstrapProvider).network;
  return ref.watch(privateUsdDeploymentProvider(network))?.railgunNetwork ==
      'mainnet';
});

/// Whether the Railgun page reads Railgun's history from Anon's archive
/// before rail-squid where it can (Settings, on by default). Changing it
/// closes the page, and the next one starts with the new choice.
final privateUsdArchiveSyncProvider =
    AsyncNotifierProvider<PrivateUsdArchiveSyncNotifier, bool>(
      PrivateUsdArchiveSyncNotifier.new,
    );

class PrivateUsdArchiveSyncNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async =>
      await ref.read(privateUsdArchiveSyncStoreProvider).read() ?? true;

  Future<void> set(bool enabled) async {
    await _settled();
    await ref.read(privateUsdArchiveSyncStoreProvider).write(enabled);
    state = AsyncData(enabled);
  }

  // A build still reading would otherwise land after a change and undo it.
  Future<void> _settled() async {
    try {
      await future;
    } catch (_) {
      // Unreadable: the change replaces it.
    }
  }
}

/// Whether a page starting now reads the archive. A setting that can't be
/// read leaves it off: rail-squid alone is how the page synced before.
Future<bool> privateUsdArchiveSyncOf(Ref ref) async {
  if (!ref.read(privateUsdArchiveAvailableProvider)) return false;
  try {
    return await ref.read(privateUsdArchiveSyncProvider.future);
  } catch (_) {
    ref.invalidate(privateUsdArchiveSyncProvider);
    return false;
  }
}
