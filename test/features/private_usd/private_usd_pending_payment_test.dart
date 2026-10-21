import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_pending_payment.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_spend_guard.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// An outgoing payment in flight on the Private USD screen (owner,
// 2026-10-17): its stages, from observed data only.
void main() {
  const account = 'account-1';
  final out = previewPrivateUsdSendRecord(
    confirmed: false,
    ago: const Duration(minutes: 1),
  );
  final landed = previewPrivateUsdSendRecord(ago: const Duration(minutes: 1));
  final landedAt = DateTime(2026, 10, 14, 9, 41);

  test('the stages: the proof, the wait for a block, the balance', () {
    expect(privateUsdPendingPayment(), isNull);

    // The page proves it: the SDK's progress, whatever the log holds.
    expect(
      privateUsdPendingPayment(proofProgress: 0.427, sends: [out]),
      const PrivateUsdPaymentProving(42),
    );
    expect(
      privateUsdPendingPayment(proofProgress: 0),
      const PrivateUsdPaymentProving(0),
    );

    // Kept and posted: the clock runs from when it was kept.
    expect(
      privateUsdPendingPayment(sends: [landed, out]),
      PrivateUsdPaymentWaitingForBlock(
        DateTime.fromMillisecondsSinceEpoch(out.sentAt * 1000),
      ),
    );

    // In a block: until the balance has synced after it.
    expect(
      privateUsdPendingPayment(sends: [landed], landedAt: landedAt),
      const PrivateUsdPaymentUpdatingBalance(),
    );
    expect(
      privateUsdPendingPayment(
        sends: [landed],
        landedAt: landedAt,
        balanceUpdatedAt: landedAt.subtract(const Duration(seconds: 5)),
      ),
      const PrivateUsdPaymentUpdatingBalance(),
    );
    expect(
      privateUsdPendingPayment(
        sends: [landed],
        landedAt: landedAt,
        balanceUpdatedAt: landedAt.add(const Duration(seconds: 3)),
      ),
      isNull,
    );
  });

  test('the guard notes a send landing only when it saw it out', () {
    var now = landedAt;
    final guard = PrivateUsdSpendGuard(now: () => now);
    addTearDown(guard.dispose);

    // Read as already in a block: no landing was seen.
    guard.noteSends(account, [landed]);
    expect(guard.landedAt(account), isNull);

    final second = previewPrivateUsdSendRecord(
      sendId: 'second',
      confirmed: false,
    );
    guard.noteSends(account, [second, landed]);
    expect(guard.landedAt(account), isNull);
    now = now.add(const Duration(minutes: 2));
    guard.noteSends(account, [
      previewPrivateUsdSendRecord(sendId: 'second'),
      landed,
    ]);
    expect(guard.landedAt(account), now);

    // Dropped rather than landed: no landing.
    expect(
      privateUsdSendsLanded([out], const []),
      isFalse,
      reason: 'a send gone from the log did not land',
    );
    guard.forget(account);
    expect(guard.landedAt(account), isNull);
  });
}
