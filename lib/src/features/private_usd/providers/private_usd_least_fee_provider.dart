import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/block_spacing_provider.dart';
import '../models/private_usd_fees.dart';

/// ZIP 317's least fee at the wallet's target, which NU7 lowers: a quote's
/// deposit fee and the sweep home's floor while their own are not known. The
/// pre-NU7 least fee until the wallet's fee policy is read.
final privateUsdLeastFeeZatProvider = Provider<BigInt>(
  (ref) =>
      ref.watch(walletFeePolicyProvider).value?.minimumFeeZatoshi ??
      kPrivateUsdPreNu7LeastFeeZat,
);
