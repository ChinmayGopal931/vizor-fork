import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/account_provider.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../services/private_usd_engine.dart';
import '../services/railgun_engine_key_store.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';

/// Whether "Receive" (public USDC deposits) shows for the active account:
/// the build follows deposits, the network pins a Deposits contract, and
/// Private USD is available to the account (the kill switch included; a
/// deposit already under way is followed regardless).
final privateUsdDepositsAvailableProvider = Provider<bool>(
  (ref) =>
      ref.watch(privateUsdDepositsEnabledProvider) &&
      ref.watch(privateUsdAvailableProvider),
);

/// [accountUuid]'s last deposit pass, if the engine ran one for it.
final privateUsdDepositPassProvider = Provider.autoDispose
    .family<rust.ApiDepositPass?, String>((ref, accountUuid) {
      final status = ref.watch(privateUsdDepositsProvider);
      return status?.accountUuid == accountUuid ? status?.pass : null;
    });

/// The deposit address to show for [accountUuid] before a pass has run:
/// the last scan's (index 0 before any), derived from the seed after its
/// check, with no network. Only while unlocked.
final privateUsdDepositAddressProvider = FutureProvider.autoDispose
    .family<rust.ApiDepositAddress, String>((ref, accountUuid) async {
      // Read before the first await: nothing may watch this provider while
      // its caller awaits.
      final backend = ref.read(privateUsdDepositBackendProvider);
      final accounts = ref.read(accountProvider.notifier);
      return backend.address(accountUuid, () async {
        final bytes = await accounts.getMnemonicBytesForAccount(accountUuid);
        if (bytes == null || bytes.isEmpty) {
          throw const RailgunEngineKeyLockedException();
        }
        return bytes;
      });
    });

/// Reads [accountUuid]'s kept deposits once, with no network, for the feeds
/// before a pass has run for it.
final _privateUsdDepositHistoryProvider = FutureProvider.autoDispose
    .family<List<rust.ApiDepositRecord>, String>(
      (ref, accountUuid) =>
          ref.read(privateUsdDepositBackendProvider).records(accountUuid),
    );

/// [accountUuid]'s deposits for activity rows, newest first: the last
/// pass's, else what `swaps.db` keeps. Empty in builds without deposits.
final privateUsdDepositRecordsProvider = Provider.autoDispose
    .family<List<rust.ApiDepositRecord>, String>((ref, accountUuid) {
      if (!ref.watch(privateUsdDepositsEnabledProvider)) return const [];
      final pass = ref.watch(privateUsdDepositPassProvider(accountUuid));
      if (pass != null) return pass.records;
      return ref.watch(_privateUsdDepositHistoryProvider(accountUuid)).value ??
          const [];
    });

/// The deposit addresses whose vaults hold more than a rescue's fee, as the
/// last pass that checked them saw.
final privateUsdDepositRescuesProvider = Provider.autoDispose
    .family<List<rust.ApiDepositRescuable>, String>((ref, accountUuid) {
      final pass = ref.watch(privateUsdDepositPassProvider(accountUuid));
      return pass?.rescuable ?? const [];
    });

/// The deposit pass the screens ask the engine for.
@immutable
class PrivateUsdDepositActions {
  const PrivateUsdDepositActions(this._engine);

  final PrivateUsdEngine? _engine;

  /// Asks for a pass now (a screen or the sheet opened, its timer).
  void refresh({bool checkVaults = false}) =>
      _engine?.requestDeposits(checkVaults: checkVaults);
}

/// The deposit calls; inert where the build follows no deposits.
final privateUsdDepositActionsProvider = Provider<PrivateUsdDepositActions>(
  (ref) => PrivateUsdDepositActions(
    ref.watch(privateUsdDepositsEnabledProvider)
        ? ref.watch(privateUsdEngineProvider)
        : null,
  ),
);
