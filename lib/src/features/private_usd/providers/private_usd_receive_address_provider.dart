import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/storage/wallet_paths.dart';
import '../../../providers/account_provider.dart';
import '../../../rust/api/private_usd.dart' as rust_private_usd;
import '../services/private_usd_swap_backend.dart' show startWithPrivateUsdSeed;
import '../services/railgun_engine_key_store.dart';

/// An account's private USD receive address: the `0zk` address Rust derives
/// from its seed after checking the seed against the account. It is the
/// address the Railgun page must open, so it needs no page. Not sensitive.
/// Only while unlocked.
final privateUsdReceiveAddressProvider = FutureProvider.autoDispose
    .family<String, String>((ref, accountUuid) async {
      // Read before the first await: nothing watches this provider while its
      // caller awaits, so it can be disposed in between and a later `ref.read`
      // would throw.
      final network = ref.read(appBootstrapProvider).network;
      final accounts = ref.read(accountProvider.notifier);
      final dbPath = await getWalletDbPath();
      final mnemonicBytes = await accounts.getMnemonicBytesForAccount(
        accountUuid,
      );
      if (mnemonicBytes == null || mnemonicBytes.isEmpty) {
        throw const RailgunEngineKeyLockedException();
      }
      return startWithPrivateUsdSeed(
        mnemonicBytes,
        (seed) => rust_private_usd.privateUsdRailgunAddress(
          dbPath: dbPath,
          network: network,
          accountUuid: accountUuid,
          mnemonicBytes: seed,
        ),
      );
    });
