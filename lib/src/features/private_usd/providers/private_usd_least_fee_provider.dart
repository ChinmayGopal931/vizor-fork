import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/wallet_paths.dart';
import '../../../providers/block_spacing_provider.dart';
import '../../../rust/api/sync.dart' as rust_sync;
import '../models/private_usd_fees.dart';

/// ZIP 317's least fee at the wallet's target on `network`, from the local
/// wallet DB; null with no wallet.
typedef PrivateUsdLeastFeeReader = Future<BigInt?> Function(String network);

final privateUsdLeastFeeReaderProvider = Provider<PrivateUsdLeastFeeReader>(
  (_) => (network) async {
    final dbPath = await getExistingWalletDbPath();
    if (dbPath == null) return null;
    final policy = await rust_sync.getWalletFeePolicy(
      dbPath: dbPath,
      network: network,
    );
    return policy.minimumFeeZatoshi;
  },
);

/// ZIP 317's least fee at the wallet's target, which NU7 lowers: a quote's
/// deposit fee and the sweep home's floor while their own are not known.
/// Read from Rust again only when the fee policy epoch moves.
final privateUsdLeastFeeProvider = FutureProvider<BigInt?>(
  (ref) => ref.watch(privateUsdLeastFeeReaderProvider)(
    ref.watch(walletFeePolicyEpochProvider).network,
  ),
);

/// [privateUsdLeastFeeProvider] once read, else the pre-NU7 least fee.
final privateUsdLeastFeeZatProvider = Provider<BigInt>(
  (ref) =>
      ref.watch(privateUsdLeastFeeProvider).value ??
      kPrivateUsdPreNu7LeastFeeZat,
);
