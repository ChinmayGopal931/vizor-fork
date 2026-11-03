import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../main.dart' show log;
import '../core/storage/wallet_paths.dart';
import '../core/zcash/block_spacing.dart';
import '../rust/api/sync.dart' as rust_sync;
import '../rust/api/wallet.dart' as rust_wallet;
import 'rpc_endpoint_failover_provider.dart';
import 'sync_provider.dart';

typedef BlockSpacingScheduleGetter =
    rust_wallet.BlockSpacingSchedule Function({required String network});

final blockSpacingScheduleGetterProvider = Provider<BlockSpacingScheduleGetter>(
  (_) => rust_wallet.getBlockSpacingSchedule,
);

/// Block spacing of the current network, for wall-clock estimates.
final blockSpacingProvider = Provider<BlockSpacing>((ref) {
  try {
    final network = ref.watch(
      rpcEndpointFailoverProvider.select((state) => state.current.networkName),
    );
    final schedule = ref.watch(blockSpacingScheduleGetterProvider)(
      network: network,
    );
    return BlockSpacing(
      nu7ActivationHeight: schedule.nu7ActivationHeight?.toInt(),
      preNu7BlockSeconds: schedule.preNu7BlockSeconds,
      nu7BlockSeconds: schedule.nu7BlockSeconds,
    );
  } catch (error) {
    // Estimates only: keep the pre-NU7 spacing rather than failing the screen.
    log('BlockSpacing: schedule unavailable, using pre-NU7 spacing: $error');
    return BlockSpacing.preNu7;
  }
});

/// Whether the wallet's tip has reached NU7, read as
/// `networkUpgradeWindowProvider` reads the tip.
final nu7ActiveAtWalletTipProvider = Provider<bool>((ref) {
  final activation = ref.watch(
    blockSpacingProvider.select((spacing) => spacing.nu7ActivationHeight),
  );
  if (activation == null) return false;
  final tipHeight = ref.watch(
    syncProvider.select((sync) {
      final state = sync.value;
      return state == null
          ? 0
          : math.max(state.chainTipHeight, state.scannedHeight);
    }),
  );
  return tipHeight >= activation;
});

typedef WalletFeePolicyGetter =
    Future<rust_sync.WalletFeePolicy> Function({
      required String dbPath,
      required String network,
    });
final walletFeePolicyGetterProvider = Provider<WalletFeePolicyGetter>(
  (ref) => rust_sync.getWalletFeePolicy,
);

/// The target the polled tip implies: one past the higher of the chain tip
/// and the scan, or 0 before either is known.
int _tipTarget(int chainTip, int scanned) {
  final tip = math.max(chainTip, scanned);
  return tip > 0 ? tip + 1 : 0;
}

final _walletTipTargetProvider = Provider<int>(
  (ref) => ref.watch(
    syncProvider.select((state) {
      final sync = state.value;
      return sync == null
          ? 0
          : _tipTarget(sync.chainTipHeight, sync.scannedHeight);
    }),
  ),
);

/// Rust's fee policy at the wallet DB's own target, the height it prices new
/// transactions at; null with no wallet, or before its first sync.
///
/// The DB records a new chain tip only once a sync starts, after the polled
/// tip has moved, so a read can predate it: while the polled tip puts NU7 on
/// the other side of the last target read, moves of the tip or the scan read
/// it again, one read at a time and at most one per
/// [WalletFeePolicyNotifier.readAgainInterval].
final walletFeePolicyProvider =
    AsyncNotifierProvider<WalletFeePolicyNotifier, rust_sync.WalletFeePolicy?>(
      WalletFeePolicyNotifier.new,
    );

class WalletFeePolicyNotifier
    extends AsyncNotifier<rust_sync.WalletFeePolicy?> {
  WalletFeePolicyNotifier({
    Future<String?> Function() resolveExistingDbPath = getExistingWalletDbPath,
    this.readAgainInterval = const Duration(seconds: 5),
  }) : _resolveExistingDbPath = resolveExistingDbPath;

  final Future<String?> Function() _resolveExistingDbPath;

  /// The least time between the end of one read and the next: a scan
  /// reports every batch, and each read opens the wallet DB.
  final Duration readAgainInterval;

  /// A read from an earlier network or wallet does not land after a rebuild.
  int _generation = 0;
  bool _reading = false;
  bool _readAgain = false;
  Timer? _pause;

  @override
  Future<rust_sync.WalletFeePolicy?> build() async {
    final network = ref.watch(
      rpcEndpointFailoverProvider.select((state) => state.current.networkName),
    );
    // A reset leaves no active account and a new wallet brings its own DB,
    // so the policy last read is dropped with them.
    ref.watch(syncProvider.select((state) => state.value?.accountUuid));
    final generation = ++_generation;
    _pause?.cancel();
    _pause = null;
    _readAgain = false;
    // A move while this first read runs asks for another after it, never
    // one beside it: the older of two reads could land last.
    _reading = true;
    ref.onDispose(() => _pause?.cancel());
    // Every move counts, not only the target's: a sync scans up to a tip the
    // poller already reported, after recording it in the DB.
    ref.listen(
      syncProvider.select((state) {
        final sync = state.value;
        return (
          tip: sync?.chainTipHeight ?? 0,
          scanned: sync?.scannedHeight ?? 0,
          completed: sync?.lastSyncCompletedAt,
        );
      }),
      (_, sync) {
        final activation = ref.read(blockSpacingProvider).nu7ActivationHeight;
        final target = _tipTarget(sync.tip, sync.scanned);
        // Before the first poll, and once a lock clears the sync state, the
        // polled tip says nothing about the DB.
        if (activation == null || target == 0) return;
        final read = state.value;
        if (read != null &&
            (read.targetHeight >= activation) == (target >= activation)) {
          return;
        }
        _readAgainFor(network, generation);
      },
    );
    try {
      return await _read(network);
    } catch (error) {
      // A wallet that has not synced has no target to price at yet.
      log('WalletFeePolicy: unavailable: $error');
      return null;
    } finally {
      if (ref.mounted && generation == _generation) {
        _pauseAfterRead(network, generation);
      }
    }
  }

  void _readAgainFor(String network, int generation) {
    if (_reading || _pause != null) {
      _readAgain = true;
      return;
    }
    _reading = true;
    _readAgain = false;
    unawaited(() async {
      try {
        final policy = await _read(network);
        if (!ref.mounted || generation != _generation) return;
        state = AsyncData(policy);
      } catch (error) {
        // The policy last read stands, so the polled tip cannot flip the
        // epoch ahead of the DB; a later move of the tip or the scan reads
        // again.
        log('WalletFeePolicy: read again failed: $error');
      } finally {
        if (ref.mounted && generation == _generation) {
          _pauseAfterRead(network, generation);
        }
      }
    }());
  }

  /// Holds the next read for [readAgainInterval], then makes the one a move
  /// asked for meanwhile, so the last move is never lost.
  void _pauseAfterRead(String network, int generation) {
    _reading = false;
    _pause = Timer(readAgainInterval, () {
      _pause = null;
      if (_readAgain && ref.mounted && generation == _generation) {
        _readAgainFor(network, generation);
      }
    });
  }

  Future<rust_sync.WalletFeePolicy?> _read(String network) async {
    final dbPath = await _resolveExistingDbPath();
    if (dbPath == null) return null;
    return ref.read(walletFeePolicyGetterProvider)(
      dbPath: dbPath,
      network: network,
    );
  }
}

/// UI invalidation key only. Transaction fees themselves are quoted by Rust
/// from the wallet DB's authoritative target, which this follows once read
/// ([walletFeePolicyProvider]); until then the polled tip stands in for it.
typedef WalletFeePolicyEpoch = ({String network, bool nu7});
final walletFeePolicyEpochProvider = Provider<WalletFeePolicyEpoch>((ref) {
  final network = ref.watch(
    rpcEndpointFailoverProvider.select((state) => state.current.networkName),
  );
  final activation = ref.watch(
    blockSpacingProvider.select((spacing) => spacing.nu7ActivationHeight),
  );
  final int target =
      ref.watch(walletFeePolicyProvider).value?.targetHeight ??
      ref.watch(_walletTipTargetProvider);
  return (
    network: network,
    nu7: activation != null && target > 0 && target >= activation,
  );
});
