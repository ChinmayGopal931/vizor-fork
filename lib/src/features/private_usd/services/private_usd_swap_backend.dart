import 'dart:typed_data';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/storage/wallet_paths.dart';
import '../../../rust/api/private_usd.dart' as rust;
import 'private_usd_paths.dart';

/// Reads an account's stored seed bytes for one key-using call: null while
/// the wallet is locked, or once the engine moved on (a lock, the background
/// or a drain) since the call was queued.
typedef PrivateUsdSecretReader = Future<Uint8List?> Function();

/// A key-using call found the wallet locked: nothing reached Rust.
class PrivateUsdKeyLockedException implements Exception {
  const PrivateUsdKeyLockedException();

  @override
  String toString() => 'The wallet is locked.';
}

/// What this wallet needs to reach the swap engine: the network, the store
/// directory, the lightwalletd endpoint and the Ethereum RPC.
class PrivateUsdSwapContext {
  const PrivateUsdSwapContext({
    required this.network,
    required this.lightwalletdUrl,
    this.railgunNetwork,
    this.allowedHosts = const [],
  });

  /// `main` or `test`.
  final String network;
  final String lightwalletdUrl;

  /// The deployment's Railgun network (`mainnet`, `sepolia`) and the hosts
  /// its pages may reach, to pick the keyed Ethereum RPC (§8.2). Without
  /// them Rust uses the deployment's keyless endpoint.
  final String? railgunNetwork;
  final List<String> allowedHosts;

  /// The keyed RPC URL when the build has one on an allowed host, else
  /// empty (Rust then uses publicnode). A secret: never log it.
  String get ethRpcUrl {
    final railgun = railgunNetwork;
    if (railgun == null) return '';
    return privateUsdKeyedRpcUrl(railgun, allowedHosts: allowedHosts) ?? '';
  }
}

/// The Rust swap engine's calls (reference §8.2, M5) for this wallet. The
/// engine and the screens reach Rust only through it, so tests can fake it.
///
/// Key-using calls take a [PrivateUsdSecretReader] rather than the bytes:
/// the seed is read only once everything else the call needs is known, is
/// handed to Rust in the same synchronous step (FRB copies it as the call
/// starts), and is zeroed right after, as `swap_deposit_sender.dart` does.
abstract interface class PrivateUsdSwapBackend {
  /// Every account with a conversion under way (the engine loop's input,
  /// D14). Empty for a wallet that never converted; creates nothing.
  Future<List<String>> accountsWithUnfinished();

  /// The account's conversions under way, in either direction (the
  /// deletion and reset warnings). 0 when the wallet never converted.
  Future<int> unfinishedCount(String accountUuid);

  /// Removes the account's conversions and joint accounts, after the user
  /// confirmed and the engine drained.
  Future<void> deleteAccount(String accountUuid);

  /// The account's forward conversions, the active one first.
  Future<List<rust.ApiForwardRecord>> forwardRecords(String accountUuid);

  /// Quotes [units] (USDC base units) for a fresh swap index.
  Future<rust.ApiForwardQuote> forwardQuote(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int units,
  });

  /// Accepts the quote of swap [index]; re-entrant for the same index.
  Future<rust.ApiAcceptResult> forwardAccept(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
    required BigInt maxTotalZat,
  });

  /// One look at the chain for swap [index], then at most one key step.
  Future<rust.ApiForwardAdvance> forwardAdvance(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int opId,
    required int index,
  });

  /// "Call it off" before anything reached the chain. No key.
  Future<rust.ApiForwardRecord> forwardAbandon(
    String accountUuid, {
    required int index,
  });

  /// Stops call [opId] at its next safe point (`cancelled`).
  void cancel(int opId);

  /// The step call [opId] is in now, while it runs.
  rust.ApiActivity? activity(int opId);

  /// Drops every held quote and maker check: on lock.
  void clearSessions();
}

/// [PrivateUsdSwapBackend] over the FRB calls of `api/private_usd.rs`.
class RustPrivateUsdSwapBackend implements PrivateUsdSwapBackend {
  RustPrivateUsdSwapBackend(this._context);

  final PrivateUsdSwapContext Function() _context;

  @override
  Future<List<String>> accountsWithUnfinished() async {
    final storeDir = await PrivateUsdPaths.existingStoreDir(_context().network);
    if (storeDir == null) return const [];
    return rust.privateUsdAccountsWithUnfinished(storeDir: storeDir);
  }

  @override
  Future<int> unfinishedCount(String accountUuid) async {
    final storeDir = await PrivateUsdPaths.existingStoreDir(_context().network);
    if (storeDir == null) return 0;
    return rust.privateUsdUnfinishedCount(
      storeDir: storeDir,
      accountUuid: accountUuid,
    );
  }

  @override
  Future<void> deleteAccount(String accountUuid) async {
    final network = _context().network;
    final storeDir = await PrivateUsdPaths.existingStoreDir(network);
    if (storeDir == null) return;
    await rust.privateUsdDeleteAccount(
      storeDir: storeDir,
      network: network,
      accountUuid: accountUuid,
    );
  }

  @override
  Future<List<rust.ApiForwardRecord>> forwardRecords(String accountUuid) async {
    final network = _context().network;
    final storeDir = await PrivateUsdPaths.existingStoreDir(network);
    if (storeDir == null) return const [];
    return rust.privateUsdForwardRecords(
      dbPath: await getWalletDbPath(),
      network: network,
      accountUuid: accountUuid,
      storeDir: storeDir,
    );
  }

  @override
  Future<rust.ApiForwardQuote> forwardQuote(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int units,
  }) async {
    final context = _context();
    // A quote takes the wallet's first swap index: the store may not exist.
    final storeDir = await PrivateUsdPaths.storeDir(context.network);
    final dbPath = await getWalletDbPath();
    final mnemonic = await _read(secret);
    late final Future<rust.ApiForwardQuote> call;
    try {
      call = rust.privateUsdForwardQuote(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: context.ethRpcUrl,
        units: units,
      );
    } finally {
      mnemonic.fillRange(0, mnemonic.length, 0);
    }
    return call;
  }

  @override
  Future<rust.ApiAcceptResult> forwardAccept(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
    required BigInt maxTotalZat,
  }) async {
    final context = _context();
    final storeDir = await PrivateUsdPaths.storeDir(context.network);
    final dbPath = await getWalletDbPath();
    final mnemonic = await _read(secret);
    late final Future<rust.ApiAcceptResult> call;
    try {
      call = rust.privateUsdForwardAccept(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: context.ethRpcUrl,
        index: index,
        maxTotalZat: maxTotalZat,
      );
    } finally {
      mnemonic.fillRange(0, mnemonic.length, 0);
    }
    return call;
  }

  @override
  Future<rust.ApiForwardAdvance> forwardAdvance(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int opId,
    required int index,
  }) async {
    final context = _context();
    final storeDir = await PrivateUsdPaths.storeDir(context.network);
    final dbPath = await getWalletDbPath();
    final mnemonic = await _read(secret);
    late final Future<rust.ApiForwardAdvance> call;
    try {
      call = rust.privateUsdForwardAdvance(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: context.ethRpcUrl,
        opId: opId,
        index: index,
      );
    } finally {
      mnemonic.fillRange(0, mnemonic.length, 0);
    }
    return call;
  }

  @override
  Future<rust.ApiForwardRecord> forwardAbandon(
    String accountUuid, {
    required int index,
  }) async {
    final context = _context();
    final storeDir = await PrivateUsdPaths.storeDir(context.network);
    return rust.privateUsdForwardAbandon(
      network: context.network,
      accountUuid: accountUuid,
      storeDir: storeDir,
      ethRpcUrl: context.ethRpcUrl,
      index: index,
    );
  }

  @override
  void cancel(int opId) => rust.privateUsdCancel(opId: opId);

  @override
  rust.ApiActivity? activity(int opId) => rust.privateUsdActivity(opId: opId);

  @override
  void clearSessions() => rust.privateUsdClearSessions();

  static Future<Uint8List> _read(PrivateUsdSecretReader secret) async {
    final bytes = await secret();
    if (bytes == null || bytes.isEmpty) {
      throw const PrivateUsdKeyLockedException();
    }
    return bytes;
  }
}
