import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_settlement_reminder_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// A USD → ZEC conversion buzzes when "Authorize settlement" is first offered,
// the user's turn mid-conversion (owner, 2026-10-19), and again two minutes
// before it closes, still unauthorized (D-128). "Authorize settlement" closes
// 120 s before the ready deadline.
void main() {
  final now = previewPrivateUsdNow;

  PrivateUsdSettlementBuzz due(
    ApiReverseRecord record,
    DateTime at, {
    bool offerBuzzed = false,
    bool closingBuzzed = false,
  }) => privateUsdSettlementBuzzDue(
    record,
    at,
    offerBuzzed: offerBuzzed,
    closingBuzzed: closingBuzzed,
  );

  final ready = previewPrivateUsdReverseRecord(
    phase: ApiReversePhase.awaitingReady,
    readyIn: const Duration(minutes: 30),
  );

  test("the user's turn buzzes as soon as Authorize settlement is offered",
      () {
    expect(due(ready, now), PrivateUsdSettlementBuzz.offered);
    expect(due(ready, now, offerBuzzed: true), PrivateUsdSettlementBuzz.none);
  });

  test('it buzzes again two minutes before it closes, still unauthorized',
      () {
    // It closes 28 minutes on; 1 m 30 s left.
    final late = now.add(const Duration(minutes: 26, seconds: 30));
    expect(
      due(ready, late, offerBuzzed: true),
      PrivateUsdSettlementBuzz.closing,
    );
    expect(
      due(ready, late, offerBuzzed: true, closingBuzzed: true),
      PrivateUsdSettlementBuzz.none,
    );
  });

  test('an offer inside the last two minutes buzzes once, as the closing', () {
    final short = previewPrivateUsdReverseRecord(
      phase: ApiReversePhase.awaitingReady,
      readyIn: const Duration(minutes: 3),
    );
    expect(due(short, now), PrivateUsdSettlementBuzz.closing);
  });

  test('nothing buzzes before the step, once it has closed, or when '
      'cancelled', () {
    for (final record in [
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.awaitingFunding),
      previewPrivateUsdReverseRecord(
        phase: ApiReversePhase.awaitingReady,
        readyIn: const Duration(seconds: 60),
      ),
      previewPrivateUsdReverseRecord(
        phase: ApiReversePhase.awaitingReady,
        cancelRequested: true,
      ),
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.settling),
    ]) {
      expect(due(record, now), PrivateUsdSettlementBuzz.none);
    }
  });
}
