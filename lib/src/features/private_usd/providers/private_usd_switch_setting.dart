import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_secure_store.dart';

/// Where one of Private USD's switches in Settings is kept: one secure-storage
/// key for the app, which a full reset's wipe takes with the rest.
class PrivateUsdSwitchStore {
  const PrivateUsdSwitchStore(this._storage, this._key);

  final AppSecureStore _storage;
  final String _key;

  /// The user's choice, or null while it is the default.
  Future<bool?> read() async {
    final stored = await _storage.readString(_key);
    return stored == null ? null : stored == 'true';
  }

  Future<void> write(bool enabled) =>
      _storage.writeString(_key, enabled ? 'true' : 'false');
}

/// A switch kept in [store], on by default.
abstract class PrivateUsdSwitchNotifier extends AsyncNotifier<bool> {
  PrivateUsdSwitchStore get store;

  @override
  Future<bool> build() async => await store.read() ?? true;

  Future<void> set(bool enabled) async {
    await _settled();
    await store.write(enabled);
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
