import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_send.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_sender.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_spend_guard.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_swap_backend.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

import 'support/fake_private_usd_backend.dart';

const _account = 'account-1';
const _proxy = '0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9';
final _cap = BigInt.from(2000000);

/// The page: its proof finishes at once, or when the test says so.
class _Page implements PrivateUsdSendPage {
  _Page({this.holdProof = false});

  final bool holdProof;
  var fee = BigInt.from(500000);
  var proofs = 0;
  final proving = Completer<void>();
  final _proof = Completer<RailgunRelayedProof>();
  static const json = '{"chainId":11155111,"to":"$_proxy","data":"0x1234"}';

  void finish() => _proof.complete(
    RailgunRelayedProof(
      request: RailgunRelayRequest(
        chainId: 11155111,
        to: _proxy,
        data: '0x1234',
        value: BigInt.zero,
      ),
      spends: const [
        RailgunNullifiers(tree: 0, nullifiers: ['0x01']),
      ],
      json: json,
    ),
  );

  @override
  Future<RailgunFees> fees(String accountUuid) async =>
      const RailgunFees(unshieldBasisPoints: 25);

  @override
  Future<BigInt> broadcasterFee(
    String accountUuid,
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
  ) async => fee;

  @override
  Future<RailgunRelayedProof> prove(
    String accountUuid,
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
    BigInt fee,
  ) {
    proofs++;
    if (!proving.isCompleted) proving.complete();
    if (!holdProof && !_proof.isCompleted) finish();
    return _proof.future;
  }

  @override
  Future<void> sync(String accountUuid) async {}
}

/// Rust's send calls over an in-memory log: a settlement pass confirms what
/// the relayer sent.
class _Backend implements PrivateUsdSendBackend {
  String? feePerUnitGas;
  int? feeExpiresAt;
  final events = <String>[];
  final puts = <ApiProvedSend>[];
  var rows = <ApiSendRecord>[];
  var answer = const ApiTransactResult(
    kind: ApiTransactKind.sent,
    transactions: ['0xfeed'],
  );

  @override
  Future<ApiRailgunSendsTerms> terms() async => ApiRailgunSendsTerms(
    chainId: 11155111,
    railgunAddress: '0zk1relayer',
    railgunProxy: _proxy,
    token: previewPrivateUsdUsdc.address,
    feeFloor: '500000',
    feePerUnitGas: feePerUnitGas,
    feeExpiresAt: feeExpiresAt,
    maxGasLimit: '3000000',
    maxGasPriceWei: '100000000000',
    maxCalldataBytes: 135168,
  );

  @override
  Future<ApiSendRecord> put(
    String accountUuid,
    ApiProvedSend send, {
    required bool Function() stillCurrent,
  }) async {
    if (!stillCurrent()) throw const PrivateUsdStaleStepException();
    events.add('put');
    puts.add(send);
    final row = ApiSendRecord(
      sendId: send.sendId,
      token: send.token,
      amount: send.amount,
      fee: send.fee,
      to: send.to,
      withdraw: send.to.startsWith('0x'),
      sentAt: 1,
      state: ApiSendState.unconfirmed,
    );
    rows = [row, ...rows];
    return row;
  }

  @override
  Future<List<ApiSendRecord>> list(String accountUuid) async => rows;

  @override
  Future<ApiTransactResult> transact(String accountUuid, String sendId) async {
    events.add('transact ${sendId == puts.last.sendId ? 'kept' : sendId}');
    return answer;
  }

  @override
  Future<List<ApiSendRecord>> settleAll(String accountUuid) async {
    events.add('settle');
    rows = [
      for (final row in rows)
        ApiSendRecord(
          sendId: row.sendId,
          token: row.token,
          amount: row.amount,
          fee: row.fee,
          to: row.to,
          withdraw: row.withdraw,
          sentAt: row.sentAt,
          state: ApiSendState.confirmed,
          txHash: '0xfeed',
        ),
    ];
    return rows;
  }
}

class _Harness {
  _Harness({bool holdProof = false}) : page = _Page(holdProof: holdProof) {
    engine = PrivateUsdEngine(
      backend: FakePrivateUsdBackend(records: {}),
      readMnemonic: (_) async => Uint8List.fromList(List.filled(64, 7)),
      allowed: () => foreground && !locked,
    );
    sender = PrivateUsdSender(
      engine: engine,
      page: page,
      backend: backend,
      guard: PrivateUsdSpendGuard(
        readLog: backend.list,
        unfinishedCount: (_) async => 0,
      ),
      maxRelayerFee: _cap,
      landingPoll: Duration.zero,
    );
  }

  final _Page page;
  final backend = _Backend();
  late final PrivateUsdEngine engine;
  late final PrivateUsdSender sender;
  var foreground = true;
  var locked = false;

  final request = PrivateUsdSendRequest(
    token: previewPrivateUsdUsdc,
    amount: BigInt.from(25000000),
    to: const RailgunPrivateDestination(previewPrivateUsdRecipient),
  );

  PrivateUsdSendCost cost({BigInt? fee, int? expiresAt}) => PrivateUsdSendCost(
    railgunFee: BigInt.zero,
    feeBasisPoints: 0,
    networkFee: fee ?? BigInt.from(500000),
    networkFeeToken: previewPrivateUsdUsdc.address,
    networkFeeExpiresAt: expiresAt,
  );
}

int _inSeconds(Duration duration) =>
    DateTime.now().add(duration).millisecondsSinceEpoch ~/ 1000;

void main() {
  test('the network fee is held to the 2 USDC cap before anything is '
      'proved', () async {
    final h = _Harness();
    h.page.fee = _cap + BigInt.one;
    await expectLater(
      h.sender.cost(_account, h.request),
      throwsA(isA<PrivateUsdSendFeeCapException>()),
    );

    // A confirmed fee the relayer no longer holds through a proof is priced
    // again first: above the cap nothing goes, and a fee above the one
    // confirmed comes back to be confirmed.
    h.backend
      ..feePerUnitGas = '1000'
      ..feeExpiresAt = _inSeconds(const Duration(minutes: 1));
    final confirmed = h.cost(expiresAt: _inSeconds(const Duration(minutes: 1)));
    final capped = await h.sender.send(_account, h.request, confirmed);
    expect(
      capped,
      isA<PrivateUsdSendNotSent>().having(
        (o) => o.message,
        'message',
        PrivateUsdCopy.sendErrorFeeCap,
      ),
    );
    h.page.fee = BigInt.from(700000);
    final repriced = await h.sender.send(_account, h.request, confirmed);
    expect(
      repriced,
      isA<PrivateUsdSendRepriced>().having(
        (o) => o.cost.networkFee,
        'fee',
        BigInt.from(700000),
      ),
    );
    expect(h.page.proofs, 0, reason: 'a proof was made for an unpaid fee');
    expect(h.backend.puts, isEmpty);
  });

  test('a proof that lands after a lock, in the background or after the '
      'engine moved on is never kept', () async {
    for (final interrupt in ['lock', 'background', 'epoch']) {
      final h = _Harness(holdProof: true);
      final outcome = h.sender.send(_account, h.request, h.cost());
      await h.page.proving.future;
      switch (interrupt) {
        case 'lock':
          h.locked = true;
          await h.engine.pause(PrivateUsdPauseReason.lock);
        case 'background':
          h.foreground = false;
          await h.engine.pause(PrivateUsdPauseReason.background);
        case 'epoch':
          await h.engine.pause(PrivateUsdPauseReason.background);
          h.engine.start(resuming: true);
          expect(h.engine.canRun, isTrue);
      }
      h.page.finish();
      expect(await outcome, isA<PrivateUsdSendNotSent>(), reason: interrupt);
      expect(h.backend.puts, isEmpty, reason: '$interrupt: a late proof kept');
      expect(h.backend.events, isEmpty, reason: interrupt);
      await h.engine.dispose();
    }

    // In the foreground: kept first, then the kept bytes are posted, then
    // settlement finds it in a block. The page's JSON goes to Rust as is.
    final h = _Harness();
    final outcome = await h.sender.send(_account, h.request, h.cost());
    expect(
      outcome,
      isA<PrivateUsdSendSent>().having((o) => o.txHash, 'tx', '0xfeed'),
    );
    expect(h.backend.events, ['put', 'transact kept', 'settle']);
    expect(h.backend.puts.single.proofJson, _Page.json);
    expect(h.backend.puts.single.fee, '500000');
    expect(h.page.proofs, 1);
    await h.engine.dispose();
  });

  test('a refused send that the relayer now prices higher is confirmed '
      'again, and one it may still send is never proved again', () async {
    final h = _Harness();
    h.backend.answer = const ApiTransactResult(
      kind: ApiTransactKind.refused,
      transactions: [],
    );
    // The confirmed $0.50 still holds, so it is proved at once; after the
    // refusal it is priced again at the relayer's fee now.
    h.page.fee = BigInt.from(800000);
    expect(
      await h.sender.send(_account, h.request, h.cost()),
      isA<PrivateUsdSendRepriced>().having(
        (o) => o.cost.networkFee,
        'fee',
        BigInt.from(800000),
      ),
    );
    expect(h.backend.events, ['put', 'transact kept']);

    final retried = _Harness();
    retried.backend.answer = const ApiTransactResult(
      kind: ApiTransactKind.retry,
      transactions: [],
      retryAfterSecs: 30,
    );
    expect(
      await retried.sender.send(_account, retried.request, retried.cost()),
      isA<PrivateUsdSendUnconfirmed>(),
    );
    expect(retried.page.proofs, 1);
    // Unsettled: the next payment waits for settlement, and is not proved.
    expect(
      await retried.sender.send(_account, retried.request, retried.cost()),
      isA<PrivateUsdSendBusy>().having(
        (o) => o.status,
        'status',
        PrivateUsdSpendStatus.sending,
      ),
    );
    expect(retried.page.proofs, 1);
    await h.engine.dispose();
    await retried.engine.dispose();
  });
}
