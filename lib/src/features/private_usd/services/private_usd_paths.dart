import '../../../core/storage/wallet_paths.dart';

/// Where Private USD keeps `swaps.db` and `joint.db` for this wallet and
/// [network] (plan §3.4), over `wallet_paths.dart`.
abstract final class PrivateUsdPaths {
  /// The store directory, created if needed: for calls that may write a
  /// first record (a quote takes a swap index).
  static Future<String> storeDir(String network) =>
      getPrivateUsdDirPath(network);

  /// The store directory if it exists, else null: for reads and cleanups,
  /// which must not create it.
  static Future<String?> existingStoreDir(String network) =>
      getExistingPrivateUsdDirPath(network);

  /// The device-wide token store (M4).
  static Future<String> tokensPath(String network) =>
      getPrivateUsdTokenStorePath(network);
}
