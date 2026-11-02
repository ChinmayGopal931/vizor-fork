import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/wallet_paths.dart';
import '../../../providers/block_spacing_provider.dart';
import '../../../providers/rpc_endpoint_failover_provider.dart';
import '../../../providers/sync_provider.dart';
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

/// What the least fee is read again for: the network, and whether the
/// wallet's scan is past NU7. Rust prices at the wallet DB's own target,
/// which can trail the chain tip [walletFeePolicyEpochProvider] follows.
typedef PrivateUsdLeastFeeKey = ({String network, bool nu7});

final privateUsdLeastFeeKeyProvider = Provider<PrivateUsdLeastFeeKey>((ref) {
  final activation = ref.watch(
    blockSpacingProvider.select((spacing) => spacing.nu7ActivationHeight),
  );
  final scanned = ref.watch(
    syncProvider.select((sync) => sync.value?.scannedHeight ?? 0),
  );
  return (
    network: ref.watch(
      rpcEndpointFailoverProvider.select((state) => state.current.networkName),
    ),
    nu7: activation != null && scanned > 0 && scanned + 1 >= activation,
  );
});

/// ZIP 317's least fee at the wallet's target, which NU7 lowers: a quote's
/// deposit fee and the sweep home's floor while their own are not known.
final privateUsdLeastFeeProvider = FutureProvider<BigInt?>(
  (ref) => ref.watch(privateUsdLeastFeeReaderProvider)(
    ref.watch(privateUsdLeastFeeKeyProvider).network,
  ),
);

/// [privateUsdLeastFeeProvider] once read, else the pre-NU7 least fee.
final privateUsdLeastFeeZatProvider = Provider<BigInt>(
  (ref) =>
      ref.watch(privateUsdLeastFeeProvider).value ??
      kPrivateUsdPreNu7LeastFeeZat,
);
