import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/storage/app_secure_store.dart';
import '../../../core/storage/wallet_paths.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/network_privacy_provider.dart';
import '../../../providers/private_usd_lifecycle_provider.dart';
import '../../../rust/api/network_privacy.dart' as rust_network_privacy;
import '../../../rust/api/private_usd.dart' as rust_private_usd;
import '../models/railgun_models.dart';
import '../services/private_usd_swap_backend.dart' show startWithPrivateUsdSeed;
import '../services/railgun_engine.dart';
import '../services/railgun_engine_key_store.dart';
import '../services/railgun_host_channel.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_custom_rpc_provider.dart';

/// The platform's page host (Kotlin or Swift); replaced by a fake in tests.
final railgunHostProvider = Provider<RailgunHost>(
  (_) => const RailgunHostChannel(),
);

/// The Rust loopback SOCKS5 bridge the page goes through.
class RailgunBridge {
  const RailgunBridge({
    required this.start,
    required this.startOffline,
    required this.stop,
  });

  /// Starts it, or returns the running bridge's port. Waits out a Tor
  /// bootstrap (up to 3 minutes) and fails closed when Tor is unusable.
  final Future<int> Function() start;

  /// Starts one that refuses every connection, for a page that must reach
  /// nothing (deleting a wallet); it never waits for Tor.
  final Future<int> Function() startOffline;

  /// Stops whichever kind runs.
  final Future<void> Function() stop;
}

final railgunBridgeProvider = Provider<RailgunBridge>(
  (_) => const RailgunBridge(
    start: rust_network_privacy.startRailgunBridge,
    startOffline: rust_network_privacy.startOfflineRailgunBridge,
    stop: rust_network_privacy.stopRailgunBridge,
  ),
);

final railgunEngineKeyStoreProvider = Provider<RailgunEngineKeyStore>(
  (_) => RailgunEngineKeyStore(AppSecureStore.instance),
);

final railgunWalletSourceProvider = Provider<RailgunWalletSource>(
  (ref) => RustRailgunWalletSource(ref),
);

/// The Railgun page for the active software account. It lives outside the
/// widget tree (kept alive) and closes only on lock, an account switch, a
/// route change, the idle close or a wallet change.
final railgunEngineProvider = Provider<RailgunEngine>((ref) {
  final bridge = ref.watch(railgunBridgeProvider);
  final engine = RailgunEngine(
    host: ref.watch(railgunHostProvider),
    wallets: ref.watch(railgunWalletSourceProvider),
    startBridge: bridge.start,
    stopBridge: bridge.stop,
    startOfflineBridge: bridge.startOffline,
    debugPage: kDebugMode,
  );
  final lifecycle = ref.watch(privateUsdLifecycleProvider);
  lifecycle.register(
    owner: engine,
    quiesceAndDrain: engine.quiesceAndDrain,
    resume: engine.resume,
    wipe: engine.wipe,
  );
  // The page holds the wallet's keys in memory.
  ref.listen(appSecurityProvider.select((s) => s.requiresUnlock), (_, locked) {
    if (locked) unawaited(engine.close());
  });
  // One wallet per page; the next use opens the new account's.
  ref.listen(accountProvider.select((s) => s.value?.activeAccountUuid), (
    previous,
    next,
  ) {
    if (previous != next) unawaited(engine.close());
  });
  // Chromium keeps pooled sockets, and a bridge whose route changed refuses
  // new tunnels: close, and reopen on a new bridge.
  ref.listen(networkPrivacyProvider, (previous, next) {
    if (isRailgunRouteChange(previous, next)) unawaited(engine.close());
  });
  // The user's own Ethereum RPC saved or cleared in Settings: the page's
  // `start` took the old one, so close as for a route change; the next use
  // starts with the new one. The first read is no change.
  ref.listen(
    privateUsdCustomRpcProvider(ref.read(appBootstrapProvider).network),
    (previous, next) {
      if (previous == null || !previous.hasValue || !next.hasValue) return;
      if (previous.value != next.value) unawaited(engine.close());
    },
  );
  // iOS may reclaim a suspended app's listening socket, so back from the
  // background the bridge is checked. An OS behaviour, not a layout choice;
  // Android's bridge is never reclaimed.
  final returns = defaultTargetPlatform == TargetPlatform.iOS
      ? AppLifecycleListener(
          onShow: () => unawaited(engine.replaceDeadBridge()),
        )
      : null;
  ref.onDispose(() {
    returns?.dispose();
    lifecycle.unregister(engine);
    unawaited(engine.dispose());
  });
  return engine;
});

/// The engine's progress, for first-sync percentages and proof progress.
final railgunEngineStateProvider =
    NotifierProvider<RailgunEngineStateNotifier, RailgunEngineState>(
      RailgunEngineStateNotifier.new,
    );

class RailgunEngineStateNotifier extends Notifier<RailgunEngineState> {
  @override
  RailgunEngineState build() {
    final engine = ref.watch(railgunEngineProvider);
    void listener() => state = engine.state.value;
    engine.state.addListener(listener);
    ref.onDispose(() => engine.state.removeListener(listener));
    return engine.state.value;
  }
}

/// Whether [next] routes the page differently from [previous]: Tor turned
/// on or off, a toggle under way, or the Tor connection failing or starting
/// over. A bootstrap finishing is the route the bridge already waited for.
bool isRailgunRouteChange(
  NetworkPrivacyState? previous,
  NetworkPrivacyState next,
) {
  if (previous == null) return false;
  if (previous.torEnabled != next.torEnabled) return true;
  if (previous.targetTorEnabled != next.targetTorEnabled) return true;
  if (previous.status == next.status) return false;
  return !(previous.status == NetworkPrivacyConnectionStatus.connecting &&
      next.status == NetworkPrivacyConnectionStatus.connected);
}

/// Deletes a deleted account's Railgun wallet with [container]'s wallet
/// source and engine; the engine is built for it when no use built it yet.
/// It reads through the container, not a provider's ref: the engine watches
/// the lifecycle fence that holds this, so a ref read from there would be a
/// dependency loop.
class RailgunEngineWallets {
  const RailgunEngineWallets(this.container);

  final ProviderContainer container;

  /// Derives the deletion, before the Rust account delete. Null when the
  /// account never used Private USD, or its seed can't be read now.
  Future<RailgunWalletDeletion?> prepareDeletion(String accountUuid) =>
      container.read(railgunWalletSourceProvider).prepareDeletion(accountUuid);

  /// Deletes the wallet from the page's storage, after the Rust account
  /// delete.
  Future<void> delete(RailgunWalletDeletion deletion) =>
      container.read(railgunEngineProvider).deleteWallet(deletion);
}

/// Opens an account's Railgun wallet from its stored seed: Rust derives the
/// Railgun mnemonic and the `0zk` address after checking the seed against
/// the account. Only while unlocked.
class RustRailgunWalletSource implements RailgunWalletSource {
  RustRailgunWalletSource(this._ref);

  final Ref _ref;

  @override
  Future<RailgunWalletOpening> prepare(String accountUuid) async {
    final network = _ref.read(appBootstrapProvider).network;
    final deployment = _ref.read(privateUsdDeploymentProvider(network));
    if (deployment == null) throw const RailgunEngineUnavailableException();
    final custom = await privateUsdCustomRpcUrlOf(_ref, network);
    final encryptionKey = await _ref
        .read(railgunEngineKeyStoreProvider)
        .keyFor(accountUuid);
    final dbPath = await getWalletDbPath();
    final mnemonicBytes = await _ref
        .read(accountProvider.notifier)
        .getMnemonicBytesForAccount(accountUuid);
    if (mnemonicBytes == null || mnemonicBytes.isEmpty) {
      throw const RailgunEngineKeyLockedException();
    }
    final [mnemonic, address] = await startWithPrivateUsdSeed(
      mnemonicBytes,
      (seed) => Future.wait([
        rust_private_usd.privateUsdRailgunMnemonic(
          dbPath: dbPath,
          network: network,
          accountUuid: accountUuid,
          mnemonicBytes: seed,
        ),
        rust_private_usd.privateUsdRailgunAddress(
          dbPath: dbPath,
          network: network,
          accountUuid: accountUuid,
          mnemonicBytes: seed,
        ),
      ]),
    );
    final keyed = custom != null
        ? null
        : privateUsdKeyedRpcUrl(
            deployment.railgunNetwork,
            allowedHosts: deployment.allowedHosts,
          );
    return RailgunWalletOpening(
      start: RailgunStartParams(
        network: deployment.railgunNetwork,
        // The user's own RPC (Settings) alone, with no fallback. Else the
        // keyed endpoint first; publicnode keeps the page going without.
        rpcUrls: custom != null ? [custom] : [?keyed, deployment.keylessRpcUrl],
        poiNodeUrls: [deployment.poiNodeUrl],
      ),
      wallet: RailgunOpenWalletParams(
        encryptionKey: encryptionKey,
        mnemonic: mnemonic,
      ),
      expectedAddress: address,
      secrets: [?custom, ?keyed],
    );
  }

  @override
  Future<RailgunWalletDeletion?> prepareDeletion(String accountUuid) async {
    final network = _ref.read(appBootstrapProvider).network;
    final deployment = _ref.read(privateUsdDeploymentProvider(network));
    if (deployment == null) return null;
    // Only an account whose wallet the page opened has one to delete.
    if (!await _ref.read(railgunEngineKeyStoreProvider).has(accountUuid)) {
      return null;
    }
    final dbPath = await getWalletDbPath();
    final mnemonicBytes = await _ref
        .read(accountProvider.notifier)
        .getMnemonicBytesForAccount(accountUuid);
    if (mnemonicBytes == null || mnemonicBytes.isEmpty) return null;
    return RailgunWalletDeletion(
      accountUuid: accountUuid,
      network: deployment.railgunNetwork,
      mnemonic: await startWithPrivateUsdSeed(
        mnemonicBytes,
        (seed) => rust_private_usd.privateUsdRailgunMnemonic(
          dbPath: dbPath,
          network: network,
          accountUuid: accountUuid,
          mnemonicBytes: seed,
        ),
      ),
    );
  }
}
