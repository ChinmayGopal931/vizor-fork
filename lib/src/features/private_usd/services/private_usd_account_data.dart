import '../../../core/storage/app_secure_store.dart';
import 'private_usd_balance_cache.dart';
import 'railgun_engine_key_store.dart';

/// Deletes what Private USD keeps for one account in secure storage: its
/// Railgun engine key and its balance cache (plan reference §8.4). Called
/// only after the Rust account delete succeeded. A full reset's `deleteAll`
/// removes both for every account.
///
/// The page's stored wallet itself stays until a reset wipes the page
/// origin: the bundle has no `deleteWallet` yet (E5). Without its key it is
/// an unreadable blob.
Future<void> deletePrivateUsdAccountData(
  AppSecureStore storage,
  String accountUuid,
) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final delete in [
    () => SecureRailgunEngineKeyStore(storage).delete(accountUuid),
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
