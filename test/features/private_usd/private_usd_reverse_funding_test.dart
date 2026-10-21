import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_record_key.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_reverse_funding.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_spend_guard.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';

import 'support/fake_private_usd_backend.dart';

const _relayAdapt = '0x4025ee6512dbbda97049bcf5aa5d38c54af6be8a';
const _key = PrivateUsdRecordKey(
  accountUuid: 'account-1',
  direction: PrivateUsdDirection.reverse,
  index: 9,
);

/// The page: its proof finishes only when the test says so.
class _FakePage implements PrivateUsdReversePage {
  final proving = Completer<void>();
  final _proof = Completer<RailgunReverseTransaction>();

  void finish() => _proof.complete(
    RailgunReverseTransaction(
      to: _relayAdapt,
      data: '0x1234',
      value: BigInt.zero,
      cost: RailgunReverseCost(
        debit: BigInt.from(25313282),
        railgunFee: BigInt.from(63282),
      ),
    ),
  );

  @override
  Future<String> address(String accountUuid) async => '0zk1qyfake';

  @override
  Future<RailgunFees> fees(String accountUuid) async =>
      const RailgunFees(unshieldBasisPoints: 25);

  @override
  Future<RailgunReverseCost> reverseCost(
    String accountUuid,
    RailgunReverseCostRequest request,
  ) => throw UnimplementedError();

  @override
  Future<RailgunReverseTransaction> prepareReverse(
    String accountUuid,
    RailgunReverseRequest request,
  ) {
    proving.complete();
    return _proof.future;
  }
}

/// The funding (plan reference §5.11 R4–R6) over a scripted backend: the
/// app's foreground and lock state are the test's to flip.
class _Harness {
  _Harness() {
    backend.onFundingRequest = (_) => ApiFundingRequest(
      amount: '25000000',
      railgunProxy: '0xeca1fb4b4c7b4ea4b2e1fb2bd8e1d1a6c1a0b5c4',
      token: '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238',
      callsTo: const ['0xa', '0xb', '0xc'],
      callsData: const ['0x01', '0x02', '0x03'],
      relayAdapt: _relayAdapt,
      fee: '250000',
      alreadyFunded: false,
    );
    backend.onSubmitFunding = (index, _) => previewPrivateUsdReverseRecord(
      index: index,
      phase: ApiReversePhase.sendingUsdc,
    );
    engine = PrivateUsdEngine(
      backend: backend,
      readMnemonic: (_) async => Uint8List.fromList(List.filled(64, 7)),
      allowed: () => foreground && !locked,
    );
    funding = PrivateUsdReverseFunding(
      engine: engine,
      page: page,
      guard: PrivateUsdSpendGuard(),
    );
  }

  final backend = FakePrivateUsdBackend(records: {});
  final page = _FakePage();
  late final PrivateUsdEngine engine;
  late final PrivateUsdReverseFunding funding;
  var foreground = true;
  var locked = false;

  /// Starts a funding and waits until the page proves it.
  Future<Future<PrivateUsdFundingResult>> proving() async {
    final outcome = funding.fund(_key);
    await page.proving.future;
    expect(funding.states.value[_key]?.stage, PrivateUsdFundingStage.proving);
    return outcome;
  }

  /// The proof finished: nothing reached Rust's submit, nothing is shown.
  Future<void> expectDropped(Future<PrivateUsdFundingResult> outcome) async {
    page.finish();
    expect(await outcome, PrivateUsdFundingResult.dropped);
    expect(backend.fundingRequests, 1);
    expect(backend.submitted, isEmpty, reason: 'a late proof was submitted');
    expect(funding.states.value[_key], isNull);
  }
}

void main() {
  test('a proof that finishes in the foreground is submitted once', () async {
    final harness = _Harness();
    final outcome = await harness.proving();
    harness.page.finish();
    expect(await outcome, PrivateUsdFundingResult.submitted);
    expect(harness.backend.submitted, hasLength(1));
    expect(harness.backend.submitted.single.debit, '25313282');
  });

  test('a proof that finishes after a lock is dropped', () async {
    final harness = _Harness();
    final outcome = await harness.proving();
    harness.locked = true;
    await harness.engine.pause(PrivateUsdPauseReason.lock);
    await harness.expectDropped(outcome);
    // The lock also dropped the request Rust held for the submit.
    expect(harness.backend.sessionClears, 1);
  });

  test('a proof that finishes in the background is dropped', () async {
    final harness = _Harness();
    final outcome = await harness.proving();
    harness.foreground = false;
    await harness.engine.pause(PrivateUsdPauseReason.background);
    await harness.expectDropped(outcome);
  });

  test(
    'a proof that outlives a pause is dropped even back in the foreground',
    () async {
      final harness = _Harness();
      final outcome = await harness.proving();
      harness.foreground = false;
      await harness.engine.pause(PrivateUsdPauseReason.background);
      harness.foreground = true;
      harness.engine.start(resuming: true);
      expect(harness.engine.canRun, isTrue);
      await harness.expectDropped(outcome);
    },
  );
}
