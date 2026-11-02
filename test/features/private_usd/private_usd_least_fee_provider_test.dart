import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_fees.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_reverse_presentation.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_least_fee_provider.dart';
import 'package:zcash_wallet/src/providers/block_spacing_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';

// ZIP 317's least fee drops from 10,000 to 2,000 zatoshis at NU7. The
// estimates that stand in for a fee not yet known follow the wallet's.
void main() {
  ProviderContainer container({required bool nu7, BigInt? leastFee}) {
    final container = ProviderContainer(
      overrides: [
        walletFeePolicyEpochProvider.overrideWithValue((
          network: 'mainnet',
          nu7: nu7,
        )),
        privateUsdLeastFeeReaderProvider.overrideWithValue(
          (_) async => leastFee,
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the least fee is the wallet\'s once read', () async {
    final c = container(nu7: true, leastFee: BigInt.from(2000));
    expect(c.read(privateUsdLeastFeeZatProvider), kPrivateUsdPreNu7LeastFeeZat);
    await c.read(privateUsdLeastFeeProvider.future);
    expect(c.read(privateUsdLeastFeeZatProvider), BigInt.from(2000));
  });

  test('without a wallet it stays the pre-NU7 least fee', () async {
    final c = container(nu7: false);
    await c.read(privateUsdLeastFeeProvider.future);
    expect(c.read(privateUsdLeastFeeZatProvider), kPrivateUsdPreNu7LeastFeeZat);
  });

  test('before its estimate a bridge receives its deposit less the floor', () {
    // A quote: the maker's ZEC is not in, so there is no estimate yet.
    final record = previewPrivateUsdReverseRecord(
      phase: ApiReversePhase.quoted,
    );
    expect(record.receiveEstimateZat, isNull);
    expect(
      privateUsdReverseReceivedZat(record, sweepFeeFloorZat: BigInt.from(2000)),
      record.depositZat - BigInt.from(2000),
    );
  });
}
