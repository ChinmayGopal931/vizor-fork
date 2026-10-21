import '../../../core/storage/wallet_paths.dart';
import '../../../rust/api/private_usd.dart' as rust;
import 'private_usd_swap_backend.dart';

/// The Rust deposit calls: public USDC sent to the account's own deposit
/// addresses, shielded into its private balance. Key-using calls read the
/// seed last, through [withPrivateUsdSeed], as the swap calls do.
class PrivateUsdDepositBackend {
  PrivateUsdDepositBackend(this._context);

  final PrivateUsdSwapContext Function() _context;

  /// The address to show now, from the last scan kept (no network).
  Future<rust.ApiDepositAddress> address(
    String accountUuid,
    PrivateUsdSecretReader secret,
  ) async {
    final network = _context().network;
    final storeDir = await getPrivateUsdDirPath(network);
    final dbPath = await getWalletDbPath();
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdDepositAddress(
        dbPath: dbPath,
        network: network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
      ),
    );
  }

  /// One pass: scan, post again, follow, and with [signNew] sign what is
  /// due; with [checkVaults], which vaults can be rescued. With [onlyIfUsed]
  /// an account that never used deposits gets its address and no network.
  Future<rust.ApiDepositPass> pass(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int opId,
    required bool signNew,
    required bool checkVaults,
    required bool onlyIfUsed,
  }) async {
    final context = _context();
    final storeDir = await getPrivateUsdDirPath(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdDepositPass(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        ethRpcUrl: ethRpcUrl,
        opId: opId,
        signNew: signNew,
        checkVaults: checkVaults,
        onlyIfUsed: onlyIfUsed,
      ),
    );
  }

  /// The account's deposits, newest first (no network, no key).
  Future<List<rust.ApiDepositRecord>> records(String accountUuid) async {
    final storeDir = await getExistingPrivateUsdDirPath(_context().network);
    if (storeDir == null) return const [];
    return rust.privateUsdDepositRecords(
      accountUuid: accountUuid,
      storeDir: storeDir,
    );
  }

  /// "Recover": shields again what came back to address [index]'s vault.
  Future<rust.ApiDepositRecord> rescue(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  }) async {
    final context = _context();
    final storeDir = await getPrivateUsdDirPath(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdDepositRescue(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        ethRpcUrl: ethRpcUrl,
        index: index,
      ),
    );
  }
}
