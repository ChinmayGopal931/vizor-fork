import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/storage/wallet_paths.dart';
import '../../../providers/account_provider.dart';
import '../../../rust/api/private_usd.dart' as rust_private_usd;
import '../services/railgun_engine_key_store.dart';

/// An account's private USD receive address: the `0zk` address Rust derives
/// from its seed after checking the seed against the account (plan §3.3).
/// It is the address the Railgun page must open, so it needs no page. Not
/// sensitive. Only while unlocked.
final privateUsdReceiveAddressProvider = FutureProvider.autoDispose
    .family<String, String>((ref, accountUuid) async {
      final network = ref.read(appBootstrapProvider).network;
      final dbPath = await getWalletDbPath();
      final mnemonicBytes = await ref
          .read(accountProvider.notifier)
          .getMnemonicBytesForAccount(accountUuid);
      if (mnemonicBytes == null || mnemonicBytes.isEmpty) {
        throw const RailgunEngineKeyLockedException();
      }
      final Future<String> address;
      try {
        address = rust_private_usd.privateUsdRailgunAddress(
          dbPath: dbPath,
          network: network,
          accountUuid: accountUuid,
          mnemonicBytes: mnemonicBytes,
        );
      } finally {
        mnemonicBytes.fillRange(0, mnemonicBytes.length, 0);
      }
      return address;
    });
