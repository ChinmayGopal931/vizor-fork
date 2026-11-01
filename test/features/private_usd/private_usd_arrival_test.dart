import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_arrival.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';

// The Arriving row's estimate: how much of the screening time has gone by
// since what arrives landed.
void main() {
  final landed = DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000);
  final shielded = landed.add(const Duration(minutes: 20));

  ApiDepositRecord deposit({String arrives = '5000000'}) => ApiDepositRecord(
    id: 'deposit-1',
    kind: ApiDepositKind.shield,
    index: 0,
    address: '0x0000000000000000000000000000000000000001',
    state: ApiDepositState.landed,
    value: '5100000',
    fee: '100000',
    arrives: arrives,
    createdAt: 1789999000,
    endedAt: 1790000000,
    waiting: false,
  );

  test("the page's newest shield in screening dates what arrives, another "
      "wallet's included", () {
    expect(
      privateUsdArrivingSince(
        arriving: BigInt.from(5000000),
        shielded: shielded,
        deposits: [deposit()],
      ),
      shielded,
    );
    expect(
      privateUsdArrivingSince(arriving: BigInt.one, shielded: shielded),
      shielded,
      reason: 'it needs no payout of its own',
    );
    expect(
      privateUsdArrivingSince(arriving: BigInt.zero, shielded: shielded),
      isNull,
      reason: 'nothing arrives',
    );
  });

  test("without the page's word, the account's own payout dates it unless "
      'less arrives than it brought', () {
    expect(
      privateUsdArrivingSince(
        arriving: BigInt.from(5000000),
        deposits: [deposit()],
      ),
      landed,
    );
    expect(
      privateUsdArrivingSince(arriving: BigInt.one, deposits: [deposit()]),
      isNull,
    );
  });

  test('the label is the share of the screening time gone by, then that it '
      'takes longer than usual', () {
    const hour = Duration(hours: 1);
    expect(
      privateUsdArrivingLabel(
        since: landed,
        screening: hour,
        now: landed.add(const Duration(minutes: 24)),
      ),
      PrivateUsdCopy.rowArrivingPercent(40),
    );
    expect(
      privateUsdArrivingLabel(
        since: landed,
        screening: hour,
        now: landed.add(hour),
      ),
      PrivateUsdCopy.rowArrivingLate,
    );
    expect(
      privateUsdArrivingLabel(since: null, screening: hour, now: landed),
      PrivateUsdCopy.rowArriving,
    );
  });
}
