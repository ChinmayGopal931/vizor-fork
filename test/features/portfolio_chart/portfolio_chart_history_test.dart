import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/profile_pictures.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/models/portfolio_chart_models.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/providers/portfolio_chart_provider.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_balance_history.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_price_history.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_price_history_source.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_valuation.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/providers/zec_price_change_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import '../../fakes/fake_sync_notifier.dart';

const _zec = 100000000;
final _now = DateTime.utc(2026, 10, 15, 12);

BalanceDelta _delta(int height, Duration ago, int zatoshi) =>
    BalanceDelta(height: height, time: _now.subtract(ago), zatoshi: zatoshi);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a price request names the coin, the currency and the days only', () {
    final uri = coinGeckoMarketChartUri(
      Uri.parse('https://api.coingecko.com/api/v3/'),
      days: PortfolioChartRange.month.days,
    );

    expect(uri.host, 'api.coingecko.com');
    expect(uri.path, '/api/v3/coins/zcash/market_chart');
    // Adding any parameter, such as an address or a start date taken from the
    // wallet, has to be a deliberate change to this list.
    expect(uri.queryParameters, {'vs_currency': 'usd', 'days': '30'});

    expect(PortfolioChartRange.tryParse('3m'), PortfolioChartRange.quarter);
    expect(PortfolioChartRange.tryParse('all'), isNull);
    expect(
      [for (final range in PortfolioChartRange.values) range.days],
      [7, 30, 90, 365],
    );
  });

  test('parses a market_chart body and drops what cannot be drawn', () {
    final points = parseCoinGeckoMarketChart('''
{"prices": [
  [1792090370000, 1232.5], [1792086800000, 1228.25], [1792086800000, 9999],
  [1792083200000, null], [1792079600000, -3], [1792076000000, "x"], "junk"
], "market_caps": [], "total_volumes": []}''');

    expect([for (final point in points!) point.usd], [1228.25, 1232.5]);
    expect(points.first.time, DateTime.utc(2026, 10, 15, 17, 53, 20));
    expect(points.every((point) => point.time.isUtc), isTrue);

    expect(
      parseCoinGeckoMarketChart('{"prices": [[1792090370000, 5]]}'),
      isNull,
    );
    expect(parseCoinGeckoMarketChart('{"error": {"status": 401}}'), isNull);
    expect(parseCoinGeckoMarketChart('not json'), isNull);
  });

  test('builds the balance from blocks and refuses an impossible one', () {
    final history = buildBalanceHistory([
      // Out of order, and two receipts in one block: their order is unknown, so
      // they are summed.
      _delta(300, const Duration(days: 3), 5 * _zec),
      _delta(100, const Duration(days: 40), 40 * _zec),
      _delta(300, const Duration(days: 3), -1 * _zec),
    ])!;

    expect(
      [for (final step in history.steps) step.zatoshi],
      [40 * _zec, 44 * _zec],
    );
    expect(history.balanceAt(_now.subtract(const Duration(days: 50))), 0);
    expect(
      history.balanceAt(_now.subtract(const Duration(days: 10))),
      40 * _zec,
    );
    expect(history.currentZatoshi, 44 * _zec);

    // A spend with no receipt before it: the wallet has not scanned that far.
    expect(
      buildBalanceHistory([_delta(1, const Duration(days: 1), -_zec)]),
      isNull,
    );
  });

  test('values the balance over a range from its first positive moment', () {
    final balance = buildBalanceHistory([
      _delta(100, const Duration(days: 40), 40 * _zec),
      _delta(300, const Duration(days: 3), 20 * _zec),
    ])!;
    final hourly = [
      for (var hours = 24 * 7; hours >= 0; hours--)
        PricePoint(_now.subtract(Duration(hours: hours)), 100.0),
    ];

    final usd = buildPortfolioChart(
      balance: balance,
      range: PortfolioChartRange.week,
      now: _now,
      prices: hourly,
    )!;
    expect(usd.mode, PortfolioChartMode.usd);
    expect(usd.startValue, 4000);
    expect(usd.endValue, 6000);
    expect(usd.change, 2000);
    expect(usd.changeFraction, closeTo(0.5, 1e-9));

    final zec = buildPortfolioChart(
      balance: balance,
      range: PortfolioChartRange.week,
      now: _now,
    )!;
    expect(zec.mode, PortfolioChartMode.zec);
    // Held at 40 until the block that made it 60, so the line steps.
    final step = _now.subtract(const Duration(days: 3));
    expect(
      [for (final point in zec.points) (point.time, point.value)],
      [
        (_now.subtract(const Duration(days: 7)), 40.0),
        (step, 40.0),
        (step, 60.0),
        (_now, 60.0),
      ],
    );

    // A wallet younger than the range is drawn from its first balance, and one
    // with nothing in range is not drawn at all.
    final young = buildBalanceHistory([
      _delta(300, const Duration(days: 3), 20 * _zec),
    ])!;
    final fromFirst = buildPortfolioChart(
      balance: young,
      range: PortfolioChartRange.year,
      now: _now,
    )!;
    expect(fromFirst.points.first.time, step);
    expect(
      buildPortfolioChart(
        balance: const BalanceHistory([]),
        range: PortfolioChartRange.week,
        now: _now,
      ),
      isNull,
    );
  });

  test(
    'prices are cached per range and left alone for a while after a failure',
    () async {
      final hourly = [
        for (var hours = 24; hours >= 0; hours--)
          PricePoint(_now.subtract(Duration(hours: hours)), 50.0),
      ];
      var clock = _now;
      final source = _FakePriceSource(hourly);
      final repository = PortfolioPriceHistoryRepository(
        source: source,
        now: () => clock,
      );

      // Callers that ask together share one request, and a fresh series is not
      // fetched again. Another range is its own series.
      final together = await Future.wait([
        repository.load(7),
        repository.load(7),
      ]);
      expect(together.first, same(together.last));
      await repository.load(7);
      await repository.load(30);
      expect(source.requestedDays, [7, 30]);

      // Past its time to live a refresh fails: the old series is still served,
      // and the range is not asked for again until the cool-down has passed.
      clock = clock.add(const Duration(minutes: 31));
      source.prices = null;
      expect((await repository.load(7))?.points, hourly);
      await repository.load(7);
      expect(source.requestedDays, [7, 30, 7]);

      clock = clock.add(const Duration(minutes: 6));
      source.prices = hourly;
      await repository.load(7);
      expect(source.requestedDays, [7, 30, 7, 7]);
    },
  );

  group('Home chart state', () {
    final transactions = [
      _transaction(100, const Duration(days: 40), 40 * _zec),
      _transaction(300, const Duration(days: 3), 23 * _zec),
      // Not part of the history: never mined.
      _transaction(0, const Duration(days: 1), 9 * _zec),
    ];
    final hourly = [
      for (var hours = 24 * 7; hours >= 0; hours--)
        PricePoint(_now.subtract(Duration(hours: hours)), 50.0 + hours / 100),
    ];

    Future<PortfolioChartViewState> settle(ProviderContainer container) async {
      final subscription = container.listen(
        portfolioChartViewProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      await pumpEventQueue();
      return container.read(portfolioChartViewProvider);
    }

    test(
      'values the wallet history with prices fetched by range alone',
      () async {
        final source = _FakePriceSource(hourly);
        final loads = <String>[];
        final container = _container(
          source: source,
          transactions: transactions,
          loads: loads,
        );

        final view = await settle(container);

        expect(view, isA<PortfolioChartReady>());
        final data = (view as PortfolioChartReady).data;
        expect(data.mode, PortfolioChartMode.usd);
        expect(data.notice, PortfolioChartNotice.none);
        expect(data.points.last.value, closeTo(63 * 50.0, 1e-6));
        // The history was read for this account on this network, locally, and
        // the only thing asked of the price service was a number of days.
        expect(loads, ['account-1:main']);
        expect(source.requestedDays, [7]);
      },
    );

    test(
      'shows the ZEC balance, and says so, when no prices come back',
      () async {
        final container = _container(
          source: _FakePriceSource(null),
          transactions: transactions,
        );

        final data = (await settle(container) as PortfolioChartReady).data;

        expect(data.mode, PortfolioChartMode.zec);
        expect(data.notice, PortfolioChartNotice.pricesUnavailable);
        expect(data.endValue, 63);
      },
    );

    test('asks nobody for anything with market prices off, privacy mode on '
        'or the chart hidden', () async {
      final cases = <(bool, bool, bool, Matcher)>[
        // enabled, market prices, privacy mode, what Home shows
        (true, false, false, isA<PortfolioChartReady>()),
        (true, true, true, isA<PortfolioChartPrivate>()),
        (false, true, false, isA<PortfolioChartHidden>()),
      ];
      for (final (enabled, marketPrices, privacyMode, shows) in cases) {
        final source = _FakePriceSource(hourly);
        final container = _container(
          source: source,
          transactions: transactions,
          enabled: enabled,
          marketPrices: marketPrices,
          privacyMode: privacyMode,
        );

        final view = await settle(container);

        expect(view, shows);
        expect(source.requestedDays, isEmpty);
        if (view is PortfolioChartReady) {
          expect(view.data.mode, PortfolioChartMode.zec);
        }
      }
    });
  });
}

rust_sync.TransactionInfo _transaction(int height, Duration ago, int delta) {
  final seconds = BigInt.from(
    _now.subtract(ago).millisecondsSinceEpoch ~/ 1000,
  );
  return rust_sync.TransactionInfo(
    txidHex: 'tx-$height',
    minedHeight: BigInt.from(height),
    expiredUnmined: false,
    accountBalanceDelta: delta,
    fee: BigInt.zero,
    feeState: rust_sync.TransactionFeeState.notApplicable,
    blockTime: height == 0 ? BigInt.zero : seconds,
    isTransparent: false,
    txKind: 'received',
    displayAmount: BigInt.from(delta),
    displayPool: 'shielded',
    createdTime: seconds,
    detailsComplete: true,
    provisional: false,
    amountIncludesFee: false,
  );
}

class _FakePriceSource implements PortfolioPriceHistorySource {
  _FakePriceSource(this.prices);

  List<PricePoint>? prices;
  final requestedDays = <int>[];

  @override
  Future<List<PricePoint>?> fetch({required int days}) async {
    requestedDays.add(days);
    return prices;
  }
}

ProviderContainer _container({
  required PortfolioPriceHistorySource source,
  required List<rust_sync.TransactionInfo> transactions,
  List<String>? loads,
  bool enabled = true,
  bool marketPrices = true,
  bool privacyMode = false,
}) {
  final container = ProviderContainer(
    overrides: [
      appBootstrapProvider.overrideWithValue(
        AppBootstrapState(
          initialLocation: '/home',
          initialAccountState: const AccountState(
            accounts: [
              AccountInfo(
                uuid: 'account-1',
                name: 'John',
                order: 0,
                profilePictureId: kDefaultProfilePictureId,
              ),
            ],
            activeAccountUuid: 'account-1',
            activeAddress: 'u1address',
          ),
          initialSyncSnapshot: AppSyncSnapshot.empty,
          network: 'main',
          rpcEndpointConfig: defaultRpcEndpointConfig('main'),
          themeMode: ThemeMode.dark,
          privacyModeEnabled: privacyMode,
          isPasswordConfigured: true,
          isUnlocked: true,
          passwordRotationRecoveryFailed: false,
          portfolioChartEnabled: enabled,
          portfolioChartMarketPrices: marketPrices,
        ),
      ),
      syncProvider.overrideWith(
        () => FakeSyncNotifier(
          SyncState(
            accountUuid: 'account-1',
            hasAccountScopedData: true,
            isSyncComplete: true,
            percentage: 1,
            totalBalance: BigInt.from(63 * _zec),
          ),
        ),
      ),
      zecMarketDataAvailableProvider.overrideWithValue(true),
      portfolioChartNowProvider.overrideWithValue(() => _now),
      portfolioPriceHistorySourceProvider.overrideWithValue(source),
      portfolioTransactionLoaderProvider.overrideWithValue((
        accountUuid,
        network,
      ) async {
        loads?.add('$accountUuid:$network');
        return transactions;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}
