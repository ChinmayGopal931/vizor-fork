import '../../../core/storage/app_secure_store.dart';
import 'private_usd_balance_cache.dart';
import 'railgun_engine_key_store.dart';

/// Deletes what Private USD keeps for one account in secure storage, its
/// Railgun engine key and balance cache, once the Rust account delete
/// succeeded. The page's stored wallet goes separately
/// (`PrivateUsdLifecycle.deleteRailgunWallet`).
Future<void> deletePrivateUsdAccountData(
  AppSecureStore storage,
  String accountUuid,
) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final delete in [
    () => RailgunEngineKeyStore(storage).delete(accountUuid),
    () => PrivateUsdBalanceCache(storage).delete(accountUuid),
  ]) {
    try {
      await delete();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}
