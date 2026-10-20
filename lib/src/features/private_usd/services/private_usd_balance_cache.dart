import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/storage/app_secure_store.dart';
import '../models/railgun_models.dart';

const _cacheKeyPrefix = 'vizor_private_usd_balances_v1:';

/// The last balance shown for an account, so it shows at once before a sync
/// can finish (a first sync reads all of Railgun's history).
class CachedPrivateUsdBalances {
  const CachedPrivateUsdBalances({
    required this.address,
    required this.updatedAt,
    required this.balances,
  });

  /// The `0zk` address the balances belong to.
  final String address;
  final DateTime updatedAt;
  final RailgunBalances balances;
}

/// One entry per account in [AppSecureStore], `{address, updatedAt ms,
/// buckets}`. Failures are ignored: the cache is only a head start.
class PrivateUsdBalanceCache {
  const PrivateUsdBalanceCache(this._storage);

  final AppSecureStore _storage;

  static String storageKey(String accountUuid) =>
      '$_cacheKeyPrefix$accountUuid';

  /// Null when nothing, or nothing readable, is cached for [accountUuid].
  Future<CachedPrivateUsdBalances?> read(String accountUuid) async {
    try {
      final raw = await _storage.readString(storageKey(accountUuid));
      if (raw == null || raw.isEmpty) return null;
      return decode(raw);
    } catch (e) {
      privateUsdLog('balance cache unreadable (${e.runtimeType})');
      return null;
    }
  }

  Future<void> write(
    String accountUuid, {
    required String address,
    required DateTime updatedAt,
    required RailgunBalances balances,
  }) async {
    try {
      await _storage.writeString(
        storageKey(accountUuid),
        encode(address: address, updatedAt: updatedAt, balances: balances),
      );
    } catch (e) {
      privateUsdLog('balance not cached (${e.runtimeType})');
    }
  }

  Future<void> delete(String accountUuid) =>
      _storage.delete(storageKey(accountUuid));

  @visibleForTesting
  static String encode({
    required String address,
    required DateTime updatedAt,
    required RailgunBalances balances,
  }) => jsonEncode({
    'address': address,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'buckets': {
      for (final entry in balances.byBucket.entries)
        entry.key.wireName: [
          for (final held in entry.value)
            if (held.amount > BigInt.zero)
              {'token': held.token, 'amount': held.amount.toString()},
        ],
    },
  });

  /// Throws on anything it cannot read; a bucket it does not know is left
  /// out.
  @visibleForTesting
  static CachedPrivateUsdBalances decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('not an object');
    }
    final address = json['address'];
    final updatedAt = json['updatedAt'];
    if (address is! String || updatedAt is! int) {
      throw const FormatException('address or time unreadable');
    }
    return CachedPrivateUsdBalances(
      address: address,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt),
      balances: RailgunBalances.parse(json['buckets']),
    );
  }
}
