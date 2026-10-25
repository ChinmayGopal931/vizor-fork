import 'dart:async';
import 'dart:typed_data';

import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_relayer_claims_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_swap_backend.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';

/// A forward record under way at [index] (or ended with [outcome]).
ApiForwardRecord forwardRecord({
  int index = 7,
  ApiForwardPhase phase = ApiForwardPhase.confirming,
  ApiForwardOutcome? outcome,
  ApiRefundCause? refundCause,
  ApiNothingSentCause? nothingSentCause,
  int acceptedAt = 1790000000,
  int quoteExpiresAt = 1790000300,
  BigInt? depositZat,
  BigInt? maxTotalZat,
  String amount = '16000000',
  String receives = '15500000',
  String relayerFee = '460000',
  int? t0,
  int? t1,
  String? depositTxid,
  int? depositConfirmations,
  String? sweepTxid,
  String? payoutTx,
  bool claimHeld = false,
  bool claimDeclined = false,
  int? endedAt,
}) => ApiForwardRecord(
  index: index,
  swapId: '0x${'ab' * 32}',
  phase: phase,
  acceptedAt: acceptedAt,
  quoteExpiresAt: quoteExpiresAt,
  depositZat: depositZat ?? BigInt.from(48000000),
  maxTotalZat: maxTotalZat ?? BigInt.from(48010000),
  amount: amount,
  receives: receives,
  relayerFee: relayerFee,
  t0: t0,
  t1: t1,
  depositTxid: depositTxid,
  depositConfirmations: depositConfirmations,
  sweepTxid: sweepTxid,
  payoutTx: payoutTx,
  claimHeld: claimHeld,
  claimDeclined: claimDeclined,
  outcome: outcome,
  refundCause: refundCause,
  nothingSentCause: nothingSentCause,
  endedAt: endedAt,
);

/// What one advance answers: a result, or an error it throws.
typedef AdvanceAnswer = FutureOr<ApiForwardAdvance> Function(ApiForwardRecord);

/// A step that waits for confirmations (zapp's `waiting()`).
ApiForwardAdvance waiting(ApiForwardRecord record) => ApiForwardAdvance(
  record: record,
  wait: ApiForwardWait.confirming,
  nextPollMs: 20000,
);

/// A failed step whose problem Rust folded to [problem].
AdvanceAnswer failing(ApiPrivateUsdErrorCode problem) =>
    (record) =>
        ApiForwardAdvance(record: record, problem: problem, nextPollMs: 15000);

/// An advance that throws [code] (`cancelled`, `busy`, a setup failure).
AdvanceAnswer throwing(ApiPrivateUsdErrorCode code) =>
    (_) => throw ApiPrivateUsdError(code: code, message: code.name);

/// The swap engine's calls on a script: [records] per account, and each
/// advance takes the next of [answers] (the last one repeats).
class FakePrivateUsdBackend implements PrivateUsdSwapBackend {
  FakePrivateUsdBackend({
    Map<String, List<ApiForwardRecord>>? records,
    List<AdvanceAnswer>? answers,
  }) : records =
           records ??
           {
             'account-1': [forwardRecord()],
           },
       answers = answers ?? [waiting];

  final Map<String, List<ApiForwardRecord>> records;
  final List<AdvanceAnswer> answers;

  int advances = 0;
  final advancedOpIds = <int>[];
  final cancelled = <int>[];
  int sessionClears = 0;
  final deleted = <String>[];
  final unfinishedCounts = <String, int>{};

  /// Copies of the seed bytes each key-using call was given.
  final secretsSeen = <List<int>>[];

  /// While set, advances wait for it before answering.
  Completer<void>? advanceGate;

  /// The step label [activity] reports.
  ApiActivity? currentActivity;

  ApiForwardQuote Function(int units)? onQuote;
  ApiAcceptResult Function(int index)? onAccept;
  Object? acceptError;

  /// The relayer-claims choice each accept was given.
  final acceptedRelayerClaims = <bool>[];

  @override
  Future<List<String>> accountsWithUnfinished() async => [
    for (final account in {...records.keys, ...reverse.keys})
      if ((records[account] ?? const []).any(
            (record) => record.outcome == null,
          ) ||
          (reverse[account] ?? const []).any(
            (record) => privateUsdReverseUnderWay(record.phase),
          ))
        account,
  ];

  @override
  Future<int> unfinishedCount(String accountUuid) async =>
      unfinishedCounts[accountUuid] ??
      (records[accountUuid] ?? const [])
          .where((record) => record.outcome == null)
          .length;

  @override
  Future<void> deleteAccount(String accountUuid) async {
    deleted.add(accountUuid);
    records.remove(accountUuid);
  }

  @override
  Future<List<ApiForwardRecord>> forwardRecords(String accountUuid) async =>
      List.of(records[accountUuid] ?? const []);

  Future<Uint8List> _secret(PrivateUsdSecretReader secret) async {
    final bytes = await secret();
    if (bytes == null || bytes.isEmpty) {
      throw const PrivateUsdKeyLockedException();
    }
    secretsSeen.add(List.of(bytes));
    return bytes;
  }

  @override
  Future<ApiForwardQuote> forwardQuote(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int units,
  }) async {
    await _secret(secret);
    return onQuote!(units);
  }

  @override
  Future<ApiAcceptResult> forwardAccept(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
    required BigInt maxTotalZat,
    required bool relayerClaims,
  }) async {
    await _secret(secret);
    acceptedRelayerClaims.add(relayerClaims);
    final error = acceptError;
    if (error != null) throw error;
    return onAccept?.call(index) ??
        ApiAcceptResult(kind: ApiAcceptKind.accepted, index: index);
  }

  @override
  Future<ApiForwardAdvance> forwardAdvance(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int opId,
    required int index,
  }) async {
    final bytes = await _secret(secret);
    // As the real backend: the bytes are zeroed once Rust has its copy.
    bytes.fillRange(0, bytes.length, 0);
    advances++;
    advancedOpIds.add(opId);
    final gate = advanceGate;
    if (gate != null) await gate.future;
    final record = records[accountUuid]!.firstWhere((r) => r.index == index);
    final answer = answers[(advances - 1).clamp(0, answers.length - 1)];
    final result = await answer(record);
    _store(accountUuid, result.record);
    return result;
  }

  @override
  Future<ApiForwardRecord> forwardAbandon(
    String accountUuid, {
    required int index,
  }) async {
    final record = records[accountUuid]!.firstWhere((r) => r.index == index);
    final ended = forwardRecord(
      index: index,
      phase: ApiForwardPhase.nothingSent,
      outcome: ApiForwardOutcome.nothingSent,
      nothingSentCause: ApiNothingSentCause.neverOpened,
      acceptedAt: record.acceptedAt,
      endedAt: record.acceptedAt + 100,
    );
    _store(accountUuid, ended);
    return ended;
  }

  void _store(String accountUuid, ApiForwardRecord record) {
    final list = records[accountUuid]!;
    final at = list.indexWhere((r) => r.index == record.index);
    if (at >= 0) list[at] = record;
  }

  // ── Reverse (M6) ───────────────────────────────────────────────────

  /// Reverse records per account.
  final reverse = <String, List<ApiReverseRecord>>{};

  /// What each reverse call answers; unset ones fail the test.
  ApiFundingRequest Function(int index)? onFundingRequest;
  ApiReverseRecord Function(int index, PrivateUsdFundingProof proof)?
  onSubmitFunding;
  int fundingRequests = 0;
  final submitted = <PrivateUsdFundingProof>[];

  @override
  Future<List<ApiReverseRecord>> reverseRecords(String accountUuid) async =>
      List.of(reverse[accountUuid] ?? const []);

  @override
  Future<ApiReverseQuote> reverseQuote(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int total,
    required int unshieldBasisPoints,
  }) => throw UnimplementedError();

  @override
  Future<ApiReverseCostRequest> reverseCostRequest(
    String accountUuid, {
    required int index,
  }) => throw UnimplementedError();

  @override
  Future<ApiReverseRecord> reverseSetCost(
    String accountUuid, {
    required int index,
    required String debit,
    required String railgunFee,
  }) => throw UnimplementedError();

  @override
  Future<ApiReverseRecord> reverseGoAhead(
    String accountUuid, {
    required int index,
  }) => throw UnimplementedError();

  @override
  Future<ApiAcceptResult> reverseAccept(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  }) => throw UnimplementedError();

  @override
  Future<ApiFundingRequest> reverseFundingRequest(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
    required String railgunAddress,
  }) async {
    final bytes = await _secret(secret);
    bytes.fillRange(0, bytes.length, 0);
    fundingRequests++;
    return onFundingRequest!(index);
  }

  @override
  Future<ApiReverseRecord> reverseSubmitFunding(
    String accountUuid, {
    required int index,
    required PrivateUsdFundingProof proof,
    required bool Function() stillCurrent,
  }) async {
    if (!stillCurrent()) throw const PrivateUsdStaleStepException();
    submitted.add(proof);
    return onSubmitFunding!(index, proof);
  }

  @override
  Future<ApiReverseAdvance> reverseAdvance(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int opId,
    required int index,
  }) => throw UnimplementedError();

  @override
  Future<ApiReverseRecord> reverseAuthorizeReady(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  }) => throw UnimplementedError();

  @override
  Future<ApiReverseRecord> reverseCancel(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  }) => throw UnimplementedError();

  @override
  Future<bool> reverseCanRescue(String accountUuid, {required int index}) =>
      throw UnimplementedError();

  @override
  Future<ApiReverseRecord> reverseRescue(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
  }) => throw UnimplementedError();

  @override
  void cancel(int opId) => cancelled.add(opId);

  @override
  ApiActivity? activity(int opId) => currentActivity;

  @override
  void clearSessions() => sessionClears++;
}

/// The relayer-claims setting in memory; while [failing], it can't be read.
class MemoryRelayerClaimsStore implements PrivateUsdRelayerClaimsStore {
  MemoryRelayerClaimsStore([this.stored]);

  bool? stored;
  bool failing = false;

  @override
  Future<bool?> read() async {
    if (failing) throw StateError('secure storage is unavailable');
    return stored;
  }

  @override
  Future<void> write(bool enabled) async => stored = enabled;
}
