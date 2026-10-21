import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_reverse_amount.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_reverse_presentation.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_send.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';

void main() {
  test('reverse amounts take at most 2 decimals, from the digits alone', () {
    BigInt units(String text) => privateUsdDollarUnits(text)!;
    expect(units('12.34'), BigInt.from(12340000));
    expect(units('0.05'), BigInt.from(50000));
    expect(units('.5'), BigInt.from(500000));
    expect(units('5.'), BigInt.from(5000000));
    expect(units('007'), BigInt.from(7000000));
    // The most one quote can name: Rust takes a u32, in whole cents.
    expect(units('4294.96'), BigInt.from(4294960000));
    for (final refused in [
      '',
      '.',
      '0',
      '0.00',
      '1.234',
      '1.2.3',
      'x',
      '4294.97',
    ]) {
      expect(privateUsdDollarUnits(refused), isNull, reason: refused);
    }
    expect(privateUsdTooPrecise('1.234', 2), isTrue);
    expect(privateUsdTooPrecise('1.23', 2), isFalse);
    expect(privateUsdDollarIsPositive('0.0'), isFalse);
    expect(privateUsdDollarIsPositive('0.001'), isTrue);
    expect(privateUsdDollarText(BigInt.from(12345678)), '12.34');
    expect(privateUsdDollarText(BigInt.from(5000000)), '5');
    expect(privateUsdDollarText(BigInt.from(50000)), '0.05');
  });

  test('Max is the balance less both fees, rounded down to the cent', () {
    BigInt max(int available, {int basisPoints = 25, int fee = 250000}) =>
        privateUsdReverseMax(
          available: BigInt.from(available),
          unshieldBasisPoints: basisPoints,
          fundingFee: BigInt.from(fee),
        );
    // $10.00 − $0.025 (25 bps) − $0.25 = $9.725 → $9.72.
    expect(max(10000000), BigInt.from(9720000));
    // 1,234,567 − 3,086 − 0 = 1,231,481 → $1.23.
    expect(max(1234567, fee: 0), BigInt.from(1230000));
    // The fees take it all.
    expect(max(250000), BigInt.zero);
    expect(max(0), BigInt.zero);
    // Never more than one quote can name.
    expect(max(9000000000), kPrivateUsdReverseMaxUnits);
  });

  test(
    '"Authorize settlement" holds until 120 s before the ready deadline',
    () {
      final record = previewPrivateUsdReverseRecord(
        phase: ApiReversePhase.awaitingReady,
      );
      final deadline = DateTime.fromMillisecondsSinceEpoch(
        record.readyDeadline * 1000,
      );
      bool at(Duration before, [ApiReverseRecord? other]) =>
          privateUsdCanAuthorizeReady(
            other ?? record,
            deadline.subtract(before),
          );
      expect(at(const Duration(minutes: 30)), isTrue);
      expect(at(const Duration(seconds: 121)), isTrue);
      expect(at(const Duration(seconds: 120)), isFalse);
      expect(at(const Duration(seconds: 1)), isFalse);
      expect(at(Duration.zero), isFalse);
      // Only while waiting on settlement, and never once called off.
      final cancelled = previewPrivateUsdReverseRecord(
        phase: ApiReversePhase.awaitingReady,
        cancelRequested: true,
      );
      expect(at(const Duration(minutes: 30), cancelled), isFalse);
      final settling = previewPrivateUsdReverseRecord(
        phase: ApiReversePhase.settling,
      );
      expect(at(const Duration(minutes: 30), settling), isFalse);
    },
  );
}
