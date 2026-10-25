import 'dart:typed_data';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/storage/wallet_paths.dart';
import '../../../rust/api/private_usd.dart' as rust;
import 'private_usd_pause.dart';

/// Reads an account's stored seed bytes for one key-using call: null while
/// the wallet is locked, or once the engine moved on (a lock, the background
/// or a drain) since the call was queued.
typedef PrivateUsdSecretReader = Future<Uint8List?> Function();

/// Reads the seed through [secret], hands it to [call] and zeroes it.
/// Throws [PrivateUsdKeyLockedException] while the wallet is locked.
Future<T> withPrivateUsdSeed<T>(
  PrivateUsdSecretReader secret,
  Future<T> Function(Uint8List seed) call,
) async {
  final seed = await secret();
  if (seed == null || seed.isEmpty) throw const PrivateUsdKeyLockedException();
  return startWithPrivateUsdSeed(seed, call);
}

/// Hands [seed] to [call] and zeroes it right after. [call] must start its
/// FRB calls synchronously: FRB copies the bytes as a call starts.
Future<T> startWithPrivateUsdSeed<T>(
  Uint8List seed,
  Future<T> Function(Uint8List seed) call,
) {
  try {
    return call(seed);
  } finally {
    seed.fillRange(0, seed.length, 0);
  }
}

/// A key-using call found the wallet locked: nothing reached Rust.
class PrivateUsdKeyLockedException implements PrivateUsdPause {
  const PrivateUsdKeyLockedException();

  @override
  String toString() => 'The wallet is locked.';
}

/// A step bound to an earlier moment found the app locked, in the
/// background or the engine moved on just before it reached Rust, so it
/// never started (a funding proof that finished too late).
class PrivateUsdStaleStepException implements PrivateUsdPause {
  const PrivateUsdStaleStepException();

  @override
  String toString() => 'The step was dropped.';
}

/// The page's `prepareReverse` result, as `submit_funding` takes it.
class PrivateUsdFundingProof {
  const PrivateUsdFundingProof({
    required this.to,
    required this.data,
    required this.value,
    required this.debit,
    required this.railgunFee,
  });

  final String to;
  final String data;
  final String value;
  final String debit;
  final String railgunFee;

  @override
  String toString() => 'PrivateUsdFundingProof(to: $to)';
}

/// What this wallet needs to reach the swap engine: the network, the store
/// directory, the lightwalletd endpoint and the Ethereum RPC.
class PrivateUsdSwapContext {
  const PrivateUsdSwapContext({
    required this.network,
    required this.lightwalletdUrl,
    this.railgunNetwork,
    this.allowedHosts = const [],
    Future<String?> Function()? customRpcUrl,
  }) : _customRpcUrl = customRpcUrl;

  /// `main` or `test`.
  final String network;
  final String lightwalletdUrl;

  /// The deployment's Railgun network (`mainnet`, `sepolia`) and the hosts
  /// its pages may reach, to pick the keyed Ethereum RPC. Without them Rust
  /// uses the deployment's keyless endpoint.
  final String? railgunNetwork;
  final List<String> allowedHosts;

  /// Reads the user's own RPC URL (Settings), null for the default.
  final Future<String?> Function()? _customRpcUrl;

  /// The Ethereum RPC URL for Rust: the user's own when set (alone, Rust
  /// never falls back from it), else the keyed URL when the build has one on
  /// an allowed host, else empty (Rust then uses publicnode). A secret: never
  /// log it. Resolve it before reading a seed, which must go to Rust in the
  /// same synchronous step.
  Future<String> ethRpcUrl() async {
    final custom = await _customRpcUrl?.call();
    if (custom != null) return custom;
    final railgun = railgunNetwork;
    if (railgun == null) return '';
    return privateUsdKeyedRpcUrl(railgun, allowedHosts: allowedHosts) ?? '';
  }
}

/// The Rust swap engine's calls for this wallet. The engine and the screens
/// reach Rust only through it, so tests can fake it.
///
/// Key-using calls take a [PrivateUsdSecretReader] rather than the bytes:
/// the seed is read only once everything else the call needs is known, and
/// [withPrivateUsdSeed] hands it to Rust and zeroes it, as
/// `swap_deposit_sender.dart` does.
abstract interface class PrivateUsdSwapBackend {
  /// Every account with a conversion under way (the engine loop's input).
  /// Empty for a wallet that never converted; creates nothing.
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

  /// Accepts the quote of swap [index]; re-entrant for the same index. With
  /// [relayerClaims] the relayer gets the claim once the deposit is out.
  Future<rust.ApiAcceptResult> forwardAccept(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
    required BigInt maxTotalZat,
    required bool relayerClaims,
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

  // ── Reverse ───────────────────────────────────────────────────────

  /// The account's reverse conversions: the active one first (a `quoted`
  /// draft too), then the rest, newest first.
  Future<List<rust.ApiReverseRecord>> reverseRecords(String accountUuid);

  /// Quotes the most that [total] (token base units, whole cents) funds
  /// once Railgun's unshield fee ([unshieldBasisPoints], as the page loads
  /// it) and the relayer's funding fee come off it, for a fresh swap index,
  /// and keeps it as an unpriced `quoted` draft.
  Future<rust.ApiReverseQuote> reverseQuote(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int total,
    required int unshieldBasisPoints,
  });

  /// The page's `reverseCost` params for swap [index] now. No key.
  Future<rust.ApiReverseCostRequest> reverseCostRequest(
    String accountUuid, {
    required int index,
  });

  /// Keeps the page's price for swap [index]. No key.
  Future<rust.ApiReverseRecord> reverseSetCost(
    String accountUuid, {
    required int index,
    required String debit,
    required String railgunFee,
  });

  /// The user's first authorization (`ACCEPTING`). No key.
  Future<rust.ApiReverseRecord> reverseGoAhead(
    String accountUuid, {
    required int index,
  });

  /// Accepts swap [index] with the maker and imports its joint account;
  /// re-entrant.
  Future<rust.ApiAcceptResult> reverseAccept(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  });

  /// Signs `OpenReverse` and returns the page's `prepareReverse` params;
  /// [railgunAddress] is the page's open wallet.
  Future<rust.ApiFundingRequest> reverseFundingRequest(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
    required String railgunAddress,
  });

  /// Keeps and posts the page's proof. [stillCurrent] is asked right before
  /// the call reaches Rust: false throws [PrivateUsdStaleStepException].
  Future<rust.ApiReverseRecord> reverseSubmitFunding(
    String accountUuid, {
    required int index,
    required PrivateUsdFundingProof proof,
    required bool Function() stillCurrent,
  });

  /// One look at the chains for swap [index], then at most one key step.
  Future<rust.ApiReverseAdvance> reverseAdvance(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int opId,
    required int index,
  });

  /// The user's settlement approval: signs `ready` (never again after).
  Future<rust.ApiReverseRecord> reverseAuthorizeReady(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  });

  /// Calls swap [index] off: "Cancel conversion" or "Request refund".
  Future<rust.ApiReverseRecord> reverseCancel(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  });

  /// Whether a refunded swap's vault holds more than the relayer's fee: a
  /// chain read, no key, no lock.
  Future<bool> reverseCanRescue(String accountUuid, {required int index});

  /// Recovers a refund that could not enter the private balance.
  Future<rust.ApiReverseRecord> reverseRescue(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  });

  /// Starts an issuance of today's Privacy Pass tokens (plan M4): what the
  /// keystore signs, or null when nothing is needed (no maker asks, a token
  /// is held, or today is spent).
  Future<rust.ApiIssuanceBegin?> tokensIssuanceBegin();

  /// Finishes the issuance [sessionId] with the keystore's chain and
  /// signature; `signAgain` once asks for a second signature over `next`.
  Future<rust.ApiIssuanceFinish> tokensIssuanceFinish({
    required BigInt sessionId,
    required List<String> chain,
    required String signature,
  });

  /// What the device holds of the makers' tokens.
  Future<rust.ApiTokenStatus> tokensStatus();

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
    final storeDir = await getExistingPrivateUsdDirPath(_context().network);
    if (storeDir == null) return const [];
    return rust.privateUsdAccountsWithUnfinished(storeDir: storeDir);
  }

  @override
  Future<int> unfinishedCount(String accountUuid) async {
    final storeDir = await getExistingPrivateUsdDirPath(_context().network);
    if (storeDir == null) return 0;
    return rust.privateUsdUnfinishedCount(
      storeDir: storeDir,
      accountUuid: accountUuid,
    );
  }

  @override
  Future<void> deleteAccount(String accountUuid) async {
    final network = _context().network;
    final storeDir = await getExistingPrivateUsdDirPath(network);
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
    final storeDir = await getExistingPrivateUsdDirPath(network);
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
    final storeDir = await getPrivateUsdDirPath(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdForwardQuote(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: ethRpcUrl,
        units: units,
      ),
    );
  }

  @override
  Future<rust.ApiAcceptResult> forwardAccept(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
    required BigInt maxTotalZat,
    required bool relayerClaims,
  }) async {
    final context = _context();
    final storeDir = await getPrivateUsdDirPath(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    final tokensPath = await getPrivateUsdTokenStorePath(context.network);
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdForwardAccept(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: ethRpcUrl,
        tokensPath: tokensPath,
        index: index,
        maxTotalZat: maxTotalZat,
        relayerClaims: relayerClaims,
      ),
    );
  }

  @override
  Future<rust.ApiForwardAdvance> forwardAdvance(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int opId,
    required int index,
  }) async {
    final context = _context();
    final storeDir = await getPrivateUsdDirPath(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    final tokensPath = await getPrivateUsdTokenStorePath(context.network);
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdForwardAdvance(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: ethRpcUrl,
        tokensPath: tokensPath,
        opId: opId,
        index: index,
      ),
    );
  }

  @override
  Future<rust.ApiForwardRecord> forwardAbandon(
    String accountUuid, {
    required int index,
  }) async {
    final context = _context();
    final storeDir = await getPrivateUsdDirPath(context.network);
    return rust.privateUsdForwardAbandon(
      network: context.network,
      accountUuid: accountUuid,
      storeDir: storeDir,
      ethRpcUrl: await context.ethRpcUrl(),
      index: index,
    );
  }

  @override
  Future<List<rust.ApiReverseRecord>> reverseRecords(String accountUuid) async {
    final storeDir = await getExistingPrivateUsdDirPath(_context().network);
    if (storeDir == null) return const [];
    return rust.privateUsdReverseRecords(
      accountUuid: accountUuid,
      storeDir: storeDir,
    );
  }

  @override
  Future<rust.ApiReverseQuote> reverseQuote(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int total,
    required int unshieldBasisPoints,
  }) async {
    final context = _context();
    // A quote may write the wallet's first record: the store may not exist.
    final storeDir = await getPrivateUsdDirPath(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdReverseQuote(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: ethRpcUrl,
        total: total,
        unshieldBasisPoints: unshieldBasisPoints,
      ),
    );
  }

  @override
  Future<rust.ApiReverseCostRequest> reverseCostRequest(
    String accountUuid, {
    required int index,
  }) async {
    final network = _context().network;
    return rust.privateUsdReverseCostRequest(
      network: network,
      accountUuid: accountUuid,
      storeDir: await getPrivateUsdDirPath(network),
      index: index,
    );
  }

  @override
  Future<rust.ApiReverseRecord> reverseSetCost(
    String accountUuid, {
    required int index,
    required String debit,
    required String railgunFee,
  }) async {
    final network = _context().network;
    return rust.privateUsdReverseSetCost(
      network: network,
      accountUuid: accountUuid,
      storeDir: await getPrivateUsdDirPath(network),
      index: index,
      debit: debit,
      railgunFee: railgunFee,
    );
  }

  @override
  Future<rust.ApiReverseRecord> reverseGoAhead(
    String accountUuid, {
    required int index,
  }) async {
    final context = _context();
    return rust.privateUsdReverseGoAhead(
      network: context.network,
      accountUuid: accountUuid,
      storeDir: await getPrivateUsdDirPath(context.network),
      ethRpcUrl: await context.ethRpcUrl(),
      index: index,
    );
  }

  @override
  Future<rust.ApiAcceptResult> reverseAccept(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  }) async {
    final context = _context();
    final storeDir = await getPrivateUsdDirPath(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    final tokensPath = await getPrivateUsdTokenStorePath(context.network);
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdReverseAccept(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: ethRpcUrl,
        tokensPath: tokensPath,
        index: index,
      ),
    );
  }

  @override
  Future<rust.ApiFundingRequest> reverseFundingRequest(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
    required String railgunAddress,
  }) async {
    final context = _context();
    final storeDir = await getPrivateUsdDirPath(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdReverseFundingRequest(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        ethRpcUrl: ethRpcUrl,
        index: index,
        railgunAddress: railgunAddress,
      ),
    );
  }

  @override
  Future<rust.ApiReverseRecord> reverseSubmitFunding(
    String accountUuid, {
    required int index,
    required PrivateUsdFundingProof proof,
    required bool Function() stillCurrent,
  }) async {
    final context = _context();
    final storeDir = await getPrivateUsdDirPath(context.network);
    final ethRpcUrl = await context.ethRpcUrl();
    // Asked after the last await: nothing can lock between it and the call.
    if (!stillCurrent()) throw const PrivateUsdStaleStepException();
    return rust.privateUsdReverseSubmitFunding(
      network: context.network,
      accountUuid: accountUuid,
      storeDir: storeDir,
      ethRpcUrl: ethRpcUrl,
      index: index,
      to: proof.to,
      data: proof.data,
      value: proof.value,
      debit: proof.debit,
      railgunFee: proof.railgunFee,
    );
  }

  @override
  Future<rust.ApiReverseAdvance> reverseAdvance(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int opId,
    required int index,
  }) async {
    final context = _context();
    final storeDir = await getPrivateUsdDirPath(context.network);
    final dbPath = await getWalletDbPath();
    final ethRpcUrl = await context.ethRpcUrl();
    final tokensPath = await getPrivateUsdTokenStorePath(context.network);
    return withPrivateUsdSeed(
      secret,
      (mnemonic) => rust.privateUsdReverseAdvance(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: ethRpcUrl,
        tokensPath: tokensPath,
        opId: opId,
        index: index,
      ),
    );
  }

  @override
  Future<rust.ApiReverseRecord> reverseAuthorizeReady(
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
      (mnemonic) => rust.privateUsdReverseAuthorizeReady(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: ethRpcUrl,
        index: index,
      ),
    );
  }

  @override
  Future<rust.ApiReverseRecord> reverseCancel(
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
      (mnemonic) => rust.privateUsdReverseCancel(
        dbPath: dbPath,
        network: context.network,
        accountUuid: accountUuid,
        storeDir: storeDir,
        mnemonicBytes: mnemonic,
        lightwalletdUrl: context.lightwalletdUrl,
        ethRpcUrl: ethRpcUrl,
        index: index,
      ),
    );
  }

  @override
  Future<bool> reverseCanRescue(
    String accountUuid, {
    required int index,
  }) async {
    final context = _context();
    final storeDir = await getExistingPrivateUsdDirPath(context.network);
    if (storeDir == null) return false;
    return rust.privateUsdReverseCanRescue(
      network: context.network,
      accountUuid: accountUuid,
      storeDir: storeDir,
      ethRpcUrl: await context.ethRpcUrl(),
      index: index,
    );
  }

  @override
  Future<rust.ApiReverseRecord> reverseRescue(
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
      (mnemonic) => rust.privateUsdReverseRescue(
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

  @override
  Future<rust.ApiIssuanceBegin?> tokensIssuanceBegin() async {
    final network = _context().network;
    return rust.privateUsdTokensIssuanceBegin(
      tokensPath: await getPrivateUsdTokenStorePath(network),
      network: network,
    );
  }

  @override
  Future<rust.ApiIssuanceFinish> tokensIssuanceFinish({
    required BigInt sessionId,
    required List<String> chain,
    required String signature,
  }) async {
    final network = _context().network;
    return rust.privateUsdTokensIssuanceFinish(
      tokensPath: await getPrivateUsdTokenStorePath(network),
      network: network,
      sessionId: sessionId,
      chain: chain,
      signature: signature,
    );
  }

  @override
  Future<rust.ApiTokenStatus> tokensStatus() async {
    final network = _context().network;
    return rust.privateUsdTokensStatus(
      tokensPath: await getPrivateUsdTokenStorePath(network),
      network: network,
    );
  }

  @override
  void cancel(int opId) => rust.privateUsdCancel(opId: opId);

  @override
  rust.ApiActivity? activity(int opId) => rust.privateUsdActivity(opId: opId);

  @override
  void clearSessions() => rust.privateUsdClearSessions();
}
