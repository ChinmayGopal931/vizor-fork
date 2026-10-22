import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_secure_store.dart';

/// Where the relayer-claims setting is kept: one secure-storage key for the
/// app, which a full reset's wipe takes with the rest.
class PrivateUsdRelayerClaimsStore {
  const PrivateUsdRelayerClaimsStore(this._storage);

  final AppSecureStore _storage;

  static const _storageKey = 'vizor_private_usd_relayer_claims_v1';

  /// The user's choice, or null while it is the default.
  Future<bool?> read() async {
    final stored = await _storage.readString(_storageKey);
    return stored == null ? null : stored == 'true';
  }

  Future<void> write(bool enabled) =>
      _storage.writeString(_storageKey, enabled ? 'true' : 'false');
}

final privateUsdRelayerClaimsStoreProvider =
    Provider<PrivateUsdRelayerClaimsStore>(
      (_) => PrivateUsdRelayerClaimsStore(AppSecureStore.instance),
    );

/// Whether a new bridge to private USD hands its claim to the relayer once
/// its ZEC is out, so the user can leave before it finishes (Settings, on by
/// default). Each bridge keeps the choice it started with.
final privateUsdRelayerClaimsProvider =
    AsyncNotifierProvider<PrivateUsdRelayerClaimsNotifier, bool>(
      PrivateUsdRelayerClaimsNotifier.new,
    );

class PrivateUsdRelayerClaimsNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async =>
      await ref.read(privateUsdRelayerClaimsStoreProvider).read() ?? true;

  Future<void> set(bool enabled) async {
    await _settled();
    await ref.read(privateUsdRelayerClaimsStoreProvider).write(enabled);
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

/// The relayer-claims setting, once read. One that can't be read fails the
/// bridge rather than fall back to the default, which the user may have
/// turned off; the next try reads it again.
Future<bool> privateUsdRelayerClaimsOf(Ref ref) async {
  try {
    return await ref.read(privateUsdRelayerClaimsProvider.future);
  } catch (_) {
    ref.invalidate(privateUsdRelayerClaimsProvider);
    rethrow;
  }
}
