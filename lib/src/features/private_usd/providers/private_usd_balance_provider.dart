import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_secure_store.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/private_usd_lifecycle_provider.dart';
import '../models/private_usd_balances.dart';
import '../services/private_usd_balance_cache.dart';
import '../services/private_usd_balance_repository.dart';
import '../services/railgun_engine.dart';
import '../services/railgun_engine_key_store.dart';
import '../models/private_usd_record_key.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_keep_awake_provider.dart';
import 'private_usd_unfinished_provider.dart';
import 'railgun_engine_provider.dart';

final privateUsdBalanceCacheProvider = Provider<PrivateUsdBalanceCache>(
  (_) => PrivateUsdBalanceCache(AppSecureStore.instance),
);

final privateUsdBalanceClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// One account's private USD balance (plan reference §6.6): the cached one
/// at once, then each sync's. Nothing refreshes until something watches it
/// through [privateUsdBalanceKeepFreshProvider].
final privateUsdBalanceProvider = NotifierProvider.autoDispose
    .family<PrivateUsdBalanceNotifier, PrivateUsdBalanceState, String>(
      PrivateUsdBalanceNotifier.new,
    );

/// Who keeps a balance fresh: the home strip asks only once Private USD is
/// in use (`ifUsed`), so it never starts the page or a first sync by
/// itself; the Private USD screen always asks.
typedef PrivateUsdBalanceWatchKey = ({String accountUuid, bool ifUsed});

/// Keeps a balance fresh while watched: every 30 s it refreshes what is
/// older than 30 s while funds arrive, else 5 min, in the foreground and
/// unlocked only.
final privateUsdBalanceKeepFreshProvider = Provider.autoDispose
    .family<void, PrivateUsdBalanceWatchKey>((ref, key) {
      final notifier = ref.watch(
        privateUsdBalanceProvider(key.accountUuid).notifier,
      );
      // Watching starts polling, which can refresh at once and so change the
      // balance provider; Riverpod forbids that while this provider builds.
      // Register right after the build instead.
      PrivateUsdBalanceWatch? watch;
      var disposed = false;
      scheduleMicrotask(() {
        if (!disposed) watch = notifier.watch(ifUsed: key.ifUsed);
      });
      ref.onDispose(() {
        disposed = true;
        watch?.cancel();
      });
    });

/// A watcher's hold on [PrivateUsdBalanceNotifier]'s polling.
class PrivateUsdBalanceWatch {
  PrivateUsdBalanceWatch._(this._cancel);

  final void Function() _cancel;
  var _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancel();
  }
}

class PrivateUsdBalanceNotifier extends Notifier<PrivateUsdBalanceState> {
  PrivateUsdBalanceNotifier(this.accountUuid);

  final String accountUuid;

  late DateTime Function() _now;
  late PrivateUsdBalanceRetries _retries;
  final _firstSync = PrivateUsdFirstSyncProgress();
  AppLifecycleListener? _lifecycle;
  Timer? _pollTimer;
  Timer? _firstSyncTimer;
  var _foreground = true;
  var _inUse = false;
  var _watchers = 0;
  var _strictWatchers = 0;
  Future<void>? _refreshing;
  RailgunSync? _shown;

  // The first sync this notifier started, while it runs (VI-18).
  PrivateUsdFirstSync? _runningFirstSync;

  @override
  PrivateUsdBalanceState build() {
    _now = ref.watch(privateUsdBalanceClockProvider);
    _retries = PrivateUsdBalanceRetries(_now);
    _lifecycle = AppLifecycleListener(
      onHide: _pausePolling,
      onPause: _pausePolling,
      onResume: () {
        _foreground = true;
        _ensurePolling();
      },
    );
    ref.onDispose(() {
      _lifecycle?.dispose();
      _lifecycle = null;
      _pollTimer?.cancel();
      _pollTimer = null;
      _firstSyncTimer?.cancel();
      _firstSyncTimer = null;
    });
    // Syncs made for sending or converting count too, and the engine's scan
    // reports drive the first-sync percentage.
    ref.listen(railgunEngineStateProvider, (_, next) => _onEngine(next));
    // An account that converted is in use: its payouts arrive here.
    bool converted(Map<PrivateUsdRecordKey, Object?> all) =>
        all.keys.any((key) => key.accountUuid == accountUuid);
    _inUse = converted(ref.read(privateUsdConversionsProvider));
    ref.listen(privateUsdConversionsProvider.select(converted), (_, next) {
      if (!next || _inUse) return;
      _inUse = true;
      if (_pollTimer != null) _poll();
    });
    unawaited(_load());
    return const PrivateUsdBalanceState();
  }

  /// Keeps the balance fresh until the returned watch is cancelled.
  PrivateUsdBalanceWatch watch({required bool ifUsed}) {
    _watchers++;
    if (!ifUsed) _strictWatchers++;
    _ensurePolling();
    return PrivateUsdBalanceWatch._(() {
      _watchers--;
      if (!ifUsed) _strictWatchers--;
      if (_watchers == 0) _stopPolling();
    });
  }

  /// Refreshes unless the balance is younger than [maxAge]. An explicit
  /// refresh ([maxAge] zero) ignores the back-off after failures.
  void refresh({Duration maxAge = Duration.zero}) {
    if (!_allowed) return;
    final updatedAt = state.updatedAt;
    final isFresh = updatedAt != null && _now().difference(updatedAt) < maxAge;
    final isBackingOff = maxAge > Duration.zero && !_retries.isDue;
    if (_refreshing != null || isFresh || isBackingOff) return;
    _refreshing = _refreshNow().whenComplete(() => _refreshing = null);
  }

  bool get _allowed =>
      ref.mounted &&
      _foreground &&
      !ref.read(appSecurityProvider).requiresUnlock &&
      !ref.read(privateUsdLifecycleProvider).isQuiesced;

  Future<void> _refreshNow() async {
    // With nothing shown yet, this may be the wallet's first sync, which
    // keeps the screen on until it completes or fails (VI-18), even past
    // this notifier: the page goes on syncing.
    final firstSync = state.balances == null
        ? ref.read(privateUsdFirstSyncsProvider.notifier).begin(accountUuid)
        : null;
    _runningFirstSync = firstSync;
    state = state.copyWith(isRefreshing: true, refreshFailed: false);
    final timeout = firstSync != null
        ? PrivateUsdBalanceTiming.firstSyncTimeout
        : PrivateUsdBalanceTiming.refreshTimeout;
    final sync = ref.read(railgunEngineProvider).sync(accountUuid);
    try {
      _shownIfMounted(await sync.timeout(timeout));
    } on TimeoutException {
      firstSync?.end();
      _failed();
      // The page keeps at it; a late result still shows, and no other
      // refresh starts meanwhile.
      try {
        _shownIfMounted(await sync);
      } catch (_) {}
    } on RailgunEngineInterruptedException {
      // A lock, switch or route change closed the page: not a failure.
      _settled();
    } on RailgunEngineUnavailableException {
      _settled();
    } on RailgunEngineKeyLockedException {
      _settled();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('privateUsd: refresh failed (${error.runtimeType})');
      }
      _failed();
    } finally {
      firstSync?.end();
    }
  }

  void _shownIfMounted(RailgunSync sync) {
    if (!ref.mounted) return;
    _show(sync);
    _retries.record(succeeded: true);
    state = state.copyWith(isRefreshing: false, refreshFailed: false);
  }

  void _failed() {
    if (!ref.mounted) return;
    _retries.record(succeeded: false);
    state = state.copyWith(isRefreshing: false, refreshFailed: true);
  }

  void _settled() {
    if (!ref.mounted) return;
    state = state.copyWith(isRefreshing: false);
  }

  Future<void> _load() async {
    final cached = await ref
        .read(privateUsdBalanceCacheProvider)
        .read(accountUuid);
    if (!ref.mounted) return;
    final lastSync = ref.read(railgunEngineStateProvider).lastSync;
    if (lastSync != null &&
        lastSync.accountUuid == accountUuid &&
        (cached == null || lastSync.at.isAfter(cached.updatedAt))) {
      _show(lastSync);
      return;
    }
    if (cached == null || state.balances != null) return;
    final balances = PrivateUsdBalances.of(cached.balances, _tokens());
    if (balances.total > BigInt.zero) _inUse = true;
    state = state.copyWith(
      balances: balances,
      updatedAt: cached.updatedAt,
      address: cached.address,
      clearFirstSyncPercent: true,
    );
    // The wallet synced before: a refresh that started first is no first
    // sync after all.
    _runningFirstSync?.end();
    // A cached balance in use: the home strip may now refresh it.
    if (_inUse && _pollTimer != null) _poll();
  }

  // Only a sync of this account counts, whichever account the page held.
  void _show(RailgunSync sync) {
    if (sync.accountUuid != accountUuid || identical(sync, _shown)) return;
    _shown = sync;
    final balances = PrivateUsdBalances.of(sync.balances, _tokens());
    if (balances.total > BigInt.zero) _inUse = true;
    state = state.copyWith(
      balances: balances,
      updatedAt: sync.at,
      address: sync.address,
      refreshFailed: false,
      clearFirstSyncPercent: true,
    );
    _runningFirstSync?.end();
    unawaited(
      ref
          .read(privateUsdBalanceCacheProvider)
          .write(
            accountUuid,
            address: sync.address,
            updatedAt: sync.at,
            balances: sync.balances,
          ),
    );
  }

  void _onEngine(RailgunEngineState engine) {
    if (!ref.mounted) return;
    final lastSync = engine.lastSync;
    if (lastSync != null) _show(lastSync);
    _showFirstSync(engine);
  }

  // Between the engine's reports the number creeps, so it is worked out
  // again now and then.
  void _showFirstSync(RailgunEngineState engine) {
    _firstSyncTimer?.cancel();
    _firstSyncTimer = null;
    if (!ref.mounted) return;
    final percent = state.balances != null || engine.accountUuid != accountUuid
        ? null
        : _firstSync.percent(notes: engine.utxoScan, ids: engine.txidScan);
    if (percent != state.firstSyncPercent) {
      state = percent == null
          ? state.copyWith(clearFirstSyncPercent: true)
          : state.copyWith(firstSyncPercent: percent);
    }
    if (percent != null && _firstSync.isCreeping) {
      _firstSyncTimer = Timer(
        PrivateUsdBalanceTiming.firstSyncTick,
        () => _showFirstSync(ref.read(railgunEngineStateProvider)),
      );
    }
  }

  List<PrivateUsdToken> _tokens() {
    final deployment = ref.read(privateUsdCurrentDeploymentProvider);
    return deployment == null ? const [] : PrivateUsdToken.of(deployment);
  }

  void _ensurePolling() {
    if (_pollTimer != null || _watchers == 0 || !_foreground) return;
    if (!ref.mounted) return;
    _poll();
    _pollTimer = Timer.periodic(
      PrivateUsdBalanceTiming.arrivingPoll,
      (_) => _poll(),
    );
  }

  void _poll() {
    if (_strictWatchers == 0 && !_inUse) return;
    refresh(
      maxAge: isPrivateUsdArriving(state)
          ? PrivateUsdBalanceTiming.arrivingPoll
          : PrivateUsdBalanceTiming.staleAfter,
    );
  }

  void _pausePolling() {
    _foreground = false;
    _stopPolling();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}

/// A balance that only shows [fixed]: Widgetbook, capture scenarios and
/// widget tests. It never polls or opens the page.
class FixedPrivateUsdBalanceNotifier extends PrivateUsdBalanceNotifier {
  FixedPrivateUsdBalanceNotifier(super.accountUuid, this.fixed);

  final PrivateUsdBalanceState fixed;

  @override
  PrivateUsdBalanceState build() => fixed;

  @override
  PrivateUsdBalanceWatch watch({required bool ifUsed}) =>
      PrivateUsdBalanceWatch._(() {});

  @override
  void refresh({Duration maxAge = Duration.zero}) {}
}
