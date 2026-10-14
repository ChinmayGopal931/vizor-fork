import 'dart:math';

import '../../../core/storage/app_secure_store.dart';

/// The random 32-byte key that encrypts one account's Railgun wallet in the
/// page's IndexedDB (plan §3.3, §3.4). It is stored as an app-managed secret,
/// encrypted under the session password and rotated with it, like the voting
/// hotkeys: together with the page's storage it opens the Railgun wallet.
///
/// Losing it costs a rescan, never funds: the page recreates a wallet whose
/// stored copy no longer opens.
abstract interface class RailgunEngineKeyStore {
  /// The key for [accountUuid] as 64 hex characters, created on first use.
  /// Throws [RailgunEngineKeyLockedException] while the wallet is locked.
  Future<String> keyFor(String accountUuid);

  Future<void> delete(String accountUuid);
}

class RailgunEngineKeyLockedException implements Exception {
  const RailgunEngineKeyLockedException();

  @override
  String toString() => 'The wallet is locked.';
}

class SecureRailgunEngineKeyStore implements RailgunEngineKeyStore {
  SecureRailgunEngineKeyStore(this._storage, {Random? random})
    : _random = random ?? Random.secure();

  final AppSecureStore _storage;
  final Random _random;

  static String storageKey(String accountUuid) =>
      '$kRailgunEncryptionKeyStoragePrefix$accountUuid';

  static final _hexKey = RegExp(r'^[0-9a-f]{64}$');

  @override
  Future<String> keyFor(String accountUuid) async {
    if (!_storage.hasSessionPassword) {
      throw const RailgunEngineKeyLockedException();
    }
    final key = storageKey(accountUuid);
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

  @override
  Future<void> delete(String accountUuid) =>
      _storage.delete(storageKey(accountUuid));
}
