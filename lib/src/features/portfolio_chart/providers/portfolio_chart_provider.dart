import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../main.dart' show log;
import '../../../core/storage/wallet_paths.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/privacy_mode_provider.dart';
import '../../../providers/rpc_endpoint_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../providers/zec_price_change_provider.dart';
import '../../../rust/api/sync.dart' as rust_sync;
import '../models/portfolio_chart_models.dart';
import '../services/portfolio_balance_history.dart';
import '../services/portfolio_price_history_source.dart';
import '../services/portfolio_valuation.dart';
import 'portfolio_chart_settings_provider.dart';

/// Reads an account's full transaction history from the local wallet database.
/// Injectable so tests and previews never reach Rust.
typedef PortfolioTransactionLoader =
    Future<List<rust_sync.TransactionInfo>> Function(
      String accountUuid,
      String network,
    );

final portfolioTransactionLoaderProvider = Provider<PortfolioTransactionLoader>(
  (ref) =>
      (accountUuid, network) async => rust_sync.getTransactionHistory(
        dbPath: await getWalletDbPath(),
        network: network,
        accountUuid: accountUuid,
      ),
);

final portfolioChartNowProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final portfolioPriceHistorySourceProvider =
    Provider<PortfolioPriceHistorySource>((ref) {
      final source = CoinGeckoPortfolioPriceHistorySource();
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
        state.value?.isSyncComplete ?? false,
        state.value?.lastSyncCompletedAt,
      ),
    ),
  );
  // A wallet that is still scanning has missing receipts, and a history built
  // from it would show a balance that never existed. A locked wallet shows
  // nothing, and drops what it held.
  return (
    accountUuid: accountUuid,
    ready: !locked && (sync.$1 || sync.$2 != null),
    completedAt: sync.$2,
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

/// The transactions that moved the balance, as deltas the chart can place in
/// time. Unmined and expired transactions did not move it. A mined transaction
/// with no block time cannot be placed, so there is no coherent history: `null`.
List<BalanceDelta>? balanceDeltasFromTransactions(
  Iterable<rust_sync.TransactionInfo> transactions,
) {
  final deltas = <BalanceDelta>[];
  for (final transaction in transactions) {
    if (transaction.expiredUnmined || transaction.minedHeight == BigInt.zero) {
      continue;
    }
    final delta = transaction.accountBalanceDelta;
    if (delta == 0) continue;
    if (transaction.blockTime == BigInt.zero) return null;
    deltas.add(
      BalanceDelta(
        height: transaction.minedHeight.toInt(),
        time: DateTime.fromMillisecondsSinceEpoch(
          transaction.blockTime.toInt() * 1000,
          isUtc: true,
        ),
        zatoshi: delta,
      ),
    );
  }
  return deltas;
}

/// A balance history and the account it belongs to.
class PortfolioBalanceSnapshot {
  const PortfolioBalanceSnapshot(this.accountUuid, this.history);

  final String accountUuid;
  final BalanceHistory history;
}

/// The active account's balance over time, from the local wallet database
/// alone. `null` while the wallet is locked or still scanning, or when the
/// transactions do not add up to a history. Reloads when a sync finishes, and
/// keeps the previous snapshot while it does, so it names its account.
final portfolioBalanceHistoryProvider =
    FutureProvider<PortfolioBalanceSnapshot?>((ref) async {
      final key = ref.watch(_historyKeyProvider);
      final accountUuid = key.accountUuid;
      if (accountUuid == null || !key.ready) return null;
      final loader = ref.watch(portfolioTransactionLoaderProvider);
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

/// Prices for one range, from the shared cache. Asked again after each sync, so
/// a series past its time to live is refreshed without a timer.
final portfolioPriceHistoryProvider = FutureProvider.autoDispose
    .family<PortfolioPriceHistory?, PortfolioChartRange>((ref, range) {
      ref.watch(_walletKeyProvider.select((key) => key.completedAt));
      return ref
          .watch(portfolioPriceHistoryRepositoryProvider)
          .load(range.days);
    });

/// USD only where this build shows market prices at all (the Home price's own
/// gate) and the user has not turned them off.
final portfolioChartModeProvider = Provider<PortfolioChartMode>((ref) {
  final wantsPrices = ref.watch(
    portfolioChartSettingsProvider.select((settings) => settings.marketPrices),
  );
  final available = ref.watch(zecMarketDataAvailableProvider);
  return wantsPrices && available
      ? PortfolioChartMode.usd
      : PortfolioChartMode.zec;
});

/// What the Home chart slot shows.
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
          final stale =
              now.toUtc().difference(series.fetchedAt) >
              const Duration(hours: 1);
          data = buildPortfolioChart(
            balance: balance,
            range: range,
            now: now,
            prices: series.points,
            notice: stale
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
