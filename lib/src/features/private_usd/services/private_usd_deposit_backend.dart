import 'dart:typed_data';

import '../../../core/storage/wallet_paths.dart';
import '../../../rust/api/private_usd.dart' as rust;
import 'private_usd_paths.dart';
import 'private_usd_swap_backend.dart';

/// The Rust deposit calls (plan M9): public USDC sent to the account's own
/// deposit addresses, shielded into its private balance. The engine and the
/// screens reach Rust only through it, so tests can fake it.
///
/// Key-using calls take a [PrivateUsdSecretReader], read last and zeroed as
/// soon as Rust has copied it, as the swap calls do.
abstract interface class PrivateUsdDepositBackend {
  /// The relayer's deposit terms, held to the pin: `unavailable` or
  /// `wrongDeployment` when deposits are unavailable; anything else only
  /// means the fees could not load.
  Future<rust.ApiDepositTerms> terms();

  /// The address to show now, from the last scan kept (no network).
  Future<rust.ApiDepositAddress> address(
    String accountUuid,
    PrivateUsdSecretReader secret,
  );

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
  });

  /// The account's deposits, newest first (no network, no key).
  Future<List<rust.ApiDepositRecord>> records(String accountUuid);

  /// "Recover": shields again what came back to address [index]'s vault.
  Future<rust.ApiDepositRecord> rescue(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  });
}

/// [PrivateUsdDepositBackend] over the FRB calls of `api/private_usd.rs`.
class RustPrivateUsdDepositBackend implements PrivateUsdDepositBackend {
  RustPrivateUsdDepositBackend(this._context);

  final PrivateUsdSwapContext Function() _context;

  @override
  Future<rust.ApiDepositTerms> terms() =>
      rust.privateUsdDepositTerms(network: _context().network);

  @override
  Future<rust.ApiDepositAddress> address(
    String accountUuid,
    PrivateUsdSecretReader secret,
  ) async {
    final network = _context().network;
    final storeDir = await PrivateUsdPaths.storeDir(network);
    final dbPath = await getWalletDbPath();
    return _withSeed(
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

  @override
  Future<rust.ApiDepositPass> pass(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int opId,
    required bool signNew,
    required bool checkVaults,
    required bool onlyIfUsed,
  }) async {
    final context = _context();
    final storeDir = await PrivateUsdPaths.storeDir(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    return _withSeed(
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

  @override
  Future<List<rust.ApiDepositRecord>> records(String accountUuid) async {
    final storeDir = await PrivateUsdPaths.existingStoreDir(_context().network);
    if (storeDir == null) return const [];
    return rust.privateUsdDepositRecords(
      accountUuid: accountUuid,
      storeDir: storeDir,
    );
  }

  @override
  Future<rust.ApiDepositRecord> rescue(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  }) async {
    final context = _context();
    final storeDir = await PrivateUsdPaths.storeDir(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    return _withSeed(
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

  /// Reads the seed last, hands it to [call] (which must start the FRB call
  /// synchronously: FRB copies the bytes as it starts) and zeroes it.
  static Future<T> _withSeed<T>(
    PrivateUsdSecretReader secret,
    Future<T> Function(Uint8List mnemonic) call,
  ) async {
    final mnemonic = await secret();
    if (mnemonic == null || mnemonic.isEmpty) {
      throw const PrivateUsdKeyLockedException();
    }
    late final Future<T> started;
    try {
      started = call(mnemonic);
    } finally {
      mnemonic.fillRange(0, mnemonic.length, 0);
    }
    return started;
  }
}
