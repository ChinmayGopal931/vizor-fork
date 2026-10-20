import 'dart:math';

import '../../../core/storage/app_secure_store.dart';
import 'private_usd_pause.dart';

class RailgunEngineKeyLockedException implements PrivateUsdPause {
  const RailgunEngineKeyLockedException();

  @override
  String toString() => 'The wallet is locked.';
}

/// The random 32-byte key that encrypts one account's Railgun wallet in the
/// page's IndexedDB. It is stored as an app-managed secret, encrypted under
/// the session password and rotated with it, like the voting hotkeys:
/// together with the page's storage it opens the Railgun wallet.
///
/// Losing it costs a rescan, never funds: the page recreates a wallet whose
/// stored copy no longer opens.
class RailgunEngineKeyStore {
  RailgunEngineKeyStore(this._storage, {Random? random})
    : _random = random ?? Random.secure();

  final AppSecureStore _storage;
  final Random _random;

  static final _hexKey = RegExp(r'^[0-9a-f]{64}$');

  /// The key for [accountUuid] as 64 hex characters, created on first use.
  /// Throws [RailgunEngineKeyLockedException] while the wallet is locked.
  Future<String> keyFor(String accountUuid) async {
    if (!_storage.hasSessionPassword) {
      throw const RailgunEngineKeyLockedException();
    }
    final key = AppSecureStore.railgunEncryptionKeyStorageKey(accountUuid);
    final stored = await _storage.readSecretStringWithOptions(
      key,
      requireUnlockedSession: true,
    );
    if (stored != null && _hexKey.hasMatch(stored)) return stored;
    if (!_storage.hasSessionPassword) {
      throw const RailgunEngineKeyLockedException();
    }
    final created = [
      for (var i = 0; i < 32; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    await _storage.writeSecretString(key, created);
    return created;
  }

  /// Whether [accountUuid] has a key, which [keyFor] makes when the page
  /// first opens the account's wallet: whether the account used Private USD.
  /// Reads no secret (the stored value stays encrypted), so it works while
  /// locked.
  Future<bool> has(String accountUuid) async =>
      await _storage.readString(
        AppSecureStore.railgunEncryptionKeyStorageKey(accountUuid),
      ) !=
      null;

  Future<void> delete(String accountUuid) => _storage.delete(
    AppSecureStore.railgunEncryptionKeyStorageKey(accountUuid),
  );
}
