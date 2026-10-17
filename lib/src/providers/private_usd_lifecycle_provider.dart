import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/private_usd_feature_config.dart';
import '../core/layout/app_form_factor.dart';
import '../features/private_usd/providers/railgun_engine_provider.dart'
    show RailgunEngineWallets;
import '../features/private_usd/services/private_usd_swap_backend.dart';
import '../features/private_usd/services/railgun_engine.dart'
    show RailgunWalletDeletion;
import '../features/private_usd/services/railgun_host_channel.dart';
import '../rust/api/private_usd.dart' as rust_private_usd;
import 'rpc_endpoint_failover_provider.dart';

final privateUsdLifecycleProvider = Provider(
  (ref) => PrivateUsdLifecycle(
    // Const, so builds without Private USD (desktop among them) never look
    // for conversions or Railgun wallets: they have none.
    conversions:
        kVizorPrivateUsdEnabled && kAppFormFactor == AppFormFactor.mobile
        ? RustPrivateUsdSwapBackend(
            () => PrivateUsdSwapContext(
              network: ref
                  .read(rpcEndpointFailoverProvider)
                  .current
                  .networkName,
              lightwalletdUrl: '',
            ),
          )
        : null,
    railgunWallets:
        kVizorPrivateUsdEnabled && kAppFormFactor == AppFormFactor.mobile
        ? RailgunEngineWallets(ref.container)
        : null,
  ),
);

/// What an account deletion needs to delete the account's Railgun wallet
/// from the page's storage (iOS progress BI-3, VI-17).
abstract interface class PrivateUsdRailgunWallets {
  /// Derives the deletion, before the Rust account delete. Null when the
  /// account never used Private USD, or its seed can't be read now.
  Future<RailgunWalletDeletion?> prepareDeletion(String accountUuid);

  /// Deletes the wallet from the page's storage, after the Rust account
  /// delete.
  Future<void> delete(RailgunWalletDeletion deletion);
}

/// An account deletion or a wallet reset was refused: the account (or the
/// wallet) has [count] Private USD conversions under way that the user has
/// not confirmed losing (plan §3.5, invariant 15). The UI shows the count
/// and lets the user confirm; it never blocks a confirmed deletion.
class PrivateUsdUnfinishedConversionsException implements Exception {
  const PrivateUsdUnfinishedConversionsException({required this.count});

  final int count;

  @override
  String toString() =>
      '$count unfinished private USD conversion(s). Confirm to continue.';
}

/// The Private USD work an account deletion or a wallet reset drains first
/// (plan reference §8.4): the Railgun page from M3, the swap engine from M5.
/// Like the Gift Card fence, it holds even before any of that work exists,
/// so work built during a drain starts drained.
///
/// It also answers how many conversions are under way (the deletion and
/// reset warnings), and removes a deleted account's conversions and its
/// Railgun wallet once the Rust account delete went through.
class PrivateUsdLifecycle {
  PrivateUsdLifecycle({
    RailgunHost host = const RailgunHostChannel(),
    PrivateUsdSwapBackend? conversions,
    PrivateUsdRailgunWallets? railgunWallets,
  }) : _host = host,
       _conversions = conversions,
       _railgunWallets = railgunWallets;

  final RailgunHost _host;
  final PrivateUsdSwapBackend? _conversions;
  final PrivateUsdRailgunWallets? _railgunWallets;
  final _owners = <Object, _Registration>{};
  bool _quiesced = false;
  final _pending = <Future<void>>[];

  bool get isQuiesced => _quiesced;

  /// [wipe] deletes the Railgun page's storage, for the owner that holds
  /// the page.
  void register({
    required Object owner,
    required Future<void> Function() quiesceAndDrain,
    required void Function() resume,
    Future<void> Function()? wipe,
  }) {
    _owners[owner] = _Registration(quiesceAndDrain, resume, wipe);
    if (_quiesced) _pending.add(quiesceAndDrain());
  }

  void unregister(Object owner) => _owners.remove(owner);

  /// Stops new work, cancels the running swap step, closes the Railgun page
  /// and waits for running work. Pair with [resume], also when the
  /// destructive step fails.
  Future<void> quiesceAndDrain() async {
    _quiesced = true;
    await Future.wait([
      for (final registration in _owners.values.toList())
        registration.quiesceAndDrain(),
    ]);
    final pending = _pending.toList();
    _pending.clear();
    await Future.wait(pending);
  }

  void resume() {
    _quiesced = false;
    for (final registration in _owners.values.toList()) {
      registration.resume();
    }
  }

  /// For a full reset, once the wallet is deleted: closes the page and
  /// deletes everything the page origin stored, every account's Railgun
  /// wallet with it. Works with or without a Railgun engine in this run.
  Future<void> wipeRailgunPage() async {
    final wipes = [
      for (final registration in _owners.values) ?registration.wipe,
    ];
    if (wipes.isEmpty) {
      await _host.wipe();
      return;
    }
    for (final wipe in wipes) {
      await wipe();
    }
  }

  /// The conversions under way across [accountUuids]: 0 for a build or a
  /// wallet without any. Reads only; creates nothing.
  Future<int> unfinishedCount(Iterable<String> accountUuids) async {
    final conversions = _conversions;
    if (conversions == null) return 0;
    var count = 0;
    for (final uuid in accountUuids) {
      count += await conversions.unfinishedCount(uuid);
    }
    return count;
  }

  /// Before the Rust account delete: what deleting [accountUuid]'s Railgun
  /// wallet from the page takes (iOS progress BI-3, VI-17), or null for an
  /// account that never used Private USD. Rust derives the wallet's mnemonic
  /// only after checking the seed against the account, which it can do only
  /// while the account exists. Best effort: a failure is null and never
  /// stops the deletion. Hand the result to [deleteRailgunWallet] once the
  /// account is gone, or discard it if the deletion stops.
  Future<RailgunWalletDeletion?> prepareRailgunWalletDeletion(
    String accountUuid, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final wallets = _railgunWallets;
    if (wallets == null) return null;
    try {
      return await wallets.prepareDeletion(accountUuid).timeout(timeout);
    } catch (error) {
      // The type only: an error can quote what the page or Rust saw.
      _debugLog('preparing the Railgun wallet deletion failed', error);
      return null;
    }
  }

  /// After the Rust account delete: deletes the wallet
  /// [prepareRailgunWalletDeletion] found from the page's storage, the notes
  /// the engine keeps unencrypted included. Best effort and bounded: on a
  /// failure the wallet stays, unreadable without its deleted engine key,
  /// until a reset wipes the page's storage. The mnemonic is dropped either
  /// way.
  Future<void> deleteRailgunWallet(RailgunWalletDeletion? deletion) async {
    if (deletion == null) return;
    try {
      await _railgunWallets?.delete(deletion);
    } catch (error) {
      _debugLog('deleting the Railgun wallet failed', error);
    } finally {
      deletion.discard();
    }
  }

  void _debugLog(String line, Object error) {
    if (kDebugMode) debugPrint('privateUsd: $line (${error.runtimeType})');
  }

  /// Removes [accountUuid]'s conversion records and joint accounts, after
  /// the Rust account delete and with the swap engine drained. A step that
  /// outlived the drain answers `busy`; it is asked again a few times.
  Future<void> deleteAccountConversions(
    String accountUuid, {
    Duration busyRetry = const Duration(seconds: 1),
  }) async {
    final conversions = _conversions;
    if (conversions == null) return;
    for (var attempt = 1; ; attempt++) {
      try {
        await conversions.deleteAccount(accountUuid);
        return;
      } on rust_private_usd.ApiPrivateUsdError catch (error) {
        if (error.code != rust_private_usd.ApiPrivateUsdErrorCode.busy ||
            attempt >= 3) {
          rethrow;
        }
        await Future<void>.delayed(busyRetry);
      }
    }
  }
}

class _Registration {
  const _Registration(this.quiesceAndDrain, this.resume, this.wipe);

  final Future<void> Function() quiesceAndDrain;
  final void Function() resume;
  final Future<void> Function()? wipe;
}
