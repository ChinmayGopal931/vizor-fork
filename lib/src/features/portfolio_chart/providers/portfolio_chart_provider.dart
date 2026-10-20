import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../main.dart' show log;
import '../../../core/config/pricing_engine_config.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/app_foreground_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/privacy_mode_provider.dart';
import '../../../providers/rpc_endpoint_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../rust/api/sync.dart' as rust_sync;
import '../../activity/activity_eta_provider.dart';
import '../models/portfolio_chart_models.dart';
import '../services/portfolio_balance_history.dart';
import '../services/portfolio_price_history_source.dart';
import '../services/portfolio_valuation.dart';
import 'portfolio_chart_settings_provider.dart';

final portfolioChartNowProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final portfolioPriceHistorySourceProvider =
    Provider<PortfolioPriceHistorySource>((ref) {
      final baseUri = ref.watch(portfolioPricingEngineBaseUriProvider);
      if (baseUri == null) {
        return const UnavailablePortfolioPriceHistorySource();
      }
      final source = PricingEnginePortfolioPriceHistorySource(baseUri: baseUri);
      ref.onDispose(source.close);
      return source;
    });

/// One cache for the session, so the chart never refetches on a rebuild.
final portfolioPriceHistoryRepositoryProvider =
    Provider<PortfolioPriceHistoryRepository>((ref) {
      return PortfolioPriceHistoryRepository(
        source: ref.watch(portfolioPriceHistorySourceProvider),
        now: ref.watch(portfolioChartNowProvider),
      );
    });

/// Whose wallet, whether it is scanned far enough to trust, and when the last
/// sync finished: the heartbeat that refreshes prices and the chart's "now".
typedef _WalletKey = ({String? accountUuid, bool ready, DateTime? completedAt});

final _walletKeyProvider = Provider<_WalletKey>((ref) {
  final accountUuid = ref.watch(
    accountProvider.select((state) => state.value?.activeAccountUuid),
  );
  final locked = ref.watch(
    appSecurityProvider.select((state) => state.requiresUnlock),
  );
  final sync = ref.watch(
    syncProvider.select(
      (state) => (
        complete: state.value?.isSyncComplete ?? false,
        completedAt: state.value?.lastSyncCompletedAt,
      ),
    ),
  );
  // A wallet that is still scanning has missing receipts, and a history built
  // from it would show a balance that never existed. A locked wallet shows
  // nothing, and drops what it held.
  return (
    accountUuid: accountUuid,
    ready: !locked && (sync.complete || sync.completedAt != null),
    completedAt: sync.completedAt,
  );
});

/// A full transaction history read is not free on a busy wallet, and a sync
/// finishes about every block. So the history is read again when a recent
/// transaction appears or changes state, and otherwise at most this often.
const _historyRefresh = Duration(minutes: 30);

typedef _HistoryKey = ({
  String? accountUuid,
  bool ready,
  int? refreshBucket,
  String recent,
});

final _historyKeyProvider = Provider<_HistoryKey>((ref) {
  final wallet = ref.watch(_walletKeyProvider);
  final recent = ref.watch(
    syncProvider.select(
      (state) => [
        for (final transaction
            in state.value?.recentTransactions ??
                const <rust_sync.TransactionInfo>[])
          '${transaction.txidHex}:${transaction.minedHeight}:'
              '${transaction.expiredUnmined}',
      ].join('|'),
    ),
  );
  final completedAt = wallet.completedAt;
  return (
    accountUuid: wallet.accountUuid,
    ready: wallet.ready,
    refreshBucket: completedAt == null
        ? null
        : completedAt.millisecondsSinceEpoch ~/ _historyRefresh.inMilliseconds,
    recent: recent,
  );
});

class PortfolioBalanceSnapshot {
  const PortfolioBalanceSnapshot(this.accountUuid, this.history);

  final String accountUuid;
  final BalanceHistory history;
}

/// The active account's balance over time: `null` while the wallet is locked
/// or still scanning, or when its transactions do not add up to a history.
/// The previous snapshot stays the value while it reloads, so it names its
/// account.
final portfolioBalanceHistoryProvider =
    FutureProvider<PortfolioBalanceSnapshot?>((ref) async {
      final key = ref.watch(_historyKeyProvider);
      final accountUuid = key.accountUuid;
      if (accountUuid == null || !key.ready) return null;
      final loader = ref.watch(activityEtaClaimHistoryLoaderProvider);
      final network = ref.watch(
        rpcEndpointProvider.select((endpoint) => endpoint.networkName),
      );
      try {
        final transactions = await loader(accountUuid, network);
        if (!ref.mounted) return null;
        final deltas = balanceDeltasFromTransactions(transactions);
        final history = deltas == null ? null : buildBalanceHistory(deltas);
        return history == null
            ? null
            : PortfolioBalanceSnapshot(accountUuid, history);
      } catch (e) {
        // Not the message: it can name wallet files.
        log('portfolioChart: balance history unavailable: ${e.runtimeType}');
        return null;
      }
    });

/// Whether a price request may leave the device right now. Every condition has
/// to hold, and the chart makes no request while any does not:
///
/// - the user turned "Use market prices" on (it is off by default) and the
///   chart is shown on Home;
/// - market prices are available ([portfolioChartPricesAvailableProvider]);
/// - the wallet is unlocked;
/// - privacy mode is off, so there is a chart to draw;
/// - the app is in the foreground.
///
/// This is the single gate in front of the price source. The chart is also not
/// asked for while there is no balance history to draw it from, which the view
/// provider decides before it reads prices.
final portfolioPriceRequestsAllowedProvider = Provider<bool>((ref) {
  final wantsPrices = ref.watch(
    portfolioChartSettingsProvider.select(
      (settings) => settings.enabled && settings.marketPrices,
    ),
  );
  if (!wantsPrices) return false;
  if (!ref.watch(portfolioChartPricesAvailableProvider)) return false;
  final locked = ref.watch(
    appSecurityProvider.select((state) => state.requiresUnlock),
  );
  if (locked) return false;
  if (ref.watch(privacyModeProvider)) return false;
  return ref.watch(appInForegroundProvider);
});

/// Prices for one range, from the shared cache. Asked again after each sync, so
/// a window that has moved on or a series the server had not finished is
/// refreshed without a timer. While [portfolioPriceRequestsAllowedProvider] is
/// false only what is already cached is served, and nothing is requested.
final portfolioPriceHistoryProvider = FutureProvider.autoDispose
    .family<PortfolioPriceHistory?, PortfolioChartRange>((ref, range) {
      final repository = ref.watch(portfolioPriceHistoryRepositoryProvider);
      if (!ref.watch(portfolioPriceRequestsAllowedProvider)) {
        return repository.cached(range);
      }
      ref.watch(_walletKeyProvider.select((key) => key.completedAt));
      return repository.load(range);
    });

final portfolioChartModeProvider = Provider<PortfolioChartMode>((ref) {
  final wantsPrices = ref.watch(
    portfolioChartSettingsProvider.select((settings) => settings.marketPrices),
  );
  final available = ref.watch(portfolioChartPricesAvailableProvider);
  return wantsPrices && available
      ? PortfolioChartMode.usd
      : PortfolioChartMode.zec;
});

final portfolioChartViewProvider =
    Provider.autoDispose<PortfolioChartViewState>((ref) {
      if (!ref.watch(
        portfolioChartSettingsProvider.select((settings) => settings.enabled),
      )) {
        return const PortfolioChartHidden();
      }
      final range = ref.watch(portfolioChartRangeProvider);
      final mode = ref.watch(portfolioChartModeProvider);
      final hasFunds = ref.watch(
        syncProvider.select(
          (state) => (state.value?.totalBalance ?? BigInt.zero) > BigInt.zero,
        ),
      );
      if (!hasFunds) return const PortfolioChartHidden();

      final history = ref.watch(portfolioBalanceHistoryProvider);
      final activeAccount = ref.watch(
        _walletKeyProvider.select((key) => key.accountUuid),
      );
      // While another account's history reloads, the previous one is still the
      // value: it must not be drawn for this account.
      final snapshot = history.value;
      final balance = snapshot != null && snapshot.accountUuid == activeAccount
          ? snapshot.history
          : null;
      if (balance == null) {
        return history.isLoading
            ? PortfolioChartLoading(range, mode)
            : const PortfolioChartHidden();
      }
      if (balance.currentZatoshi <= 0) return const PortfolioChartHidden();
      // Before any price is asked for: a chart nobody can see needs none.
      if (ref.watch(privacyModeProvider)) {
        return PortfolioChartPrivate(range, mode);
      }

      // Each finished sync moves "now", and with it the chart's right edge.
      ref.watch(_walletKeyProvider.select((key) => key.completedAt));
      final now = ref.watch(portfolioChartNowProvider)();
      PortfolioChartData? data;
      if (mode == PortfolioChartMode.usd) {
        final prices = ref.watch(portfolioPriceHistoryProvider(range));
        final series = prices.value;
        if (series != null) {
          data = buildPortfolioChart(
            balance: balance,
            range: range,
            now: now,
            prices: series.points,
            notice: series.isStaleAt(now)
                ? PortfolioChartNotice.pricesStale
                : PortfolioChartNotice.none,
          );
        } else if (prices.isLoading) {
          return PortfolioChartLoading(range, mode);
        } else {
          // No prices to be had: say so, and show what the device knows.
          data = buildPortfolioChart(
            balance: balance,
            range: range,
            now: now,
            notice: PortfolioChartNotice.pricesUnavailable,
          );
        }
      } else {
        data = buildPortfolioChart(balance: balance, range: range, now: now);
      }
      return data == null
          ? PortfolioChartEmpty(range, mode)
          : PortfolioChartReady(data);
    });
