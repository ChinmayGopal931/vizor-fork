import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/core/profile_pictures.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/models/portfolio_chart_models.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/providers/portfolio_chart_provider.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/providers/portfolio_chart_settings_provider.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_balance_history.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_price_history.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_price_history_source.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_valuation.dart';
import 'package:zcash_wallet/src/providers/account_models.dart';
import 'package:zcash_wallet/src/providers/app_foreground_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/providers/zec_price_change_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;

import '../../fakes/fake_sync_notifier.dart';

const _zec = 100000000;
final _now = DateTime.utc(2026, 10, 15, 12);

BalanceDelta _delta(int height, Duration ago, int zatoshi) =>
    BalanceDelta(height: height, time: _now.subtract(ago), zatoshi: zatoshi);

/// One price per UTC day from [first] to [last], flat at [usd] unless [price]
/// gives the price of day number `index`.
List<PricePoint> _daily(
  DateTime first,
  DateTime last, {
  double usd = 100,
  double Function(int index)? price,
}) {
  final points = <PricePoint>[];
  var index = 0;
  for (
    var day = first;
    !day.isAfter(last);
    day = day.add(const Duration(days: 1))
  ) {
    points.add(PricePoint(day, price?.call(index) ?? usd));
    index++;
  }
  return points;
}

final _serverStart = DateTime.utc(2025, 1, 1);

PriceSeries _series(
  PriceWindow window, {
  DateTime? availableFrom,
  DateTime? availableTo,
}) {
  final first = availableFrom ?? _serverStart;
  final end = availableTo ?? window.to;
  return PriceSeries(
    window: window,
    points: _daily(
      window.from.isAfter(first) ? window.from : first,
      end,
      usd: 50,
    ),
    availableFrom: first,
    availableTo: end,
  );
}

List<(DateTime, double)> _shape(PortfolioChartData chart) => [
  for (final point in chart.points) (point.time, point.value),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a price request names the coin, the currency, the dates and the page '
      'size only', () {
    final uri = pricingEnginePricesUri(
      Uri.parse('https://zapp-pricing-engine.majorworker.workers.dev'),
      from: DateTime.utc(2026, 10, 8),
      to: DateTime.utc(2026, 10, 14),
    );

    expect(uri.scheme, 'https');
    expect(uri.host, 'zapp-pricing-engine.majorworker.workers.dev');
    expect(uri.path, '/v1/prices');
    // Adding any parameter, such as an address or a start date taken from the
    // wallet, has to be a deliberate change to this list. The order is part of
    // the server's cache key.
    expect(uri.queryParameters, {
      'asset': 'ZEC',
      'fiat': 'USD',
      'resolution': '1d',
      'from': '2026-10-08',
      'to': '2026-10-14',
      'limit': '1000',
    });
    expect(
      uri.query,
      'asset=ZEC&fiat=USD&resolution=1d&from=2026-10-08&to=2026-10-14'
      '&limit=1000',
    );
    expect(uri.hasFragment, isFalse);
    expect(uri.userInfo, isEmpty);

    expect(PortfolioChartRange.tryParse('3m'), PortfolioChartRange.quarter);
    expect(PortfolioChartRange.tryParse('All'), PortfolioChartRange.all);
    expect(PortfolioChartRange.tryParse('all'), isNull);
    // All has no number of days: it starts where the server's history does.
    expect(
      [for (final range in PortfolioChartRange.values) range.days],
      [7, 30, 90, 365, null],
    );
  });

  test('every device asks for the same whole UTC days on a given day', () {
    // The last completed UTC day is yesterday, or the day before in the first
    // ten minutes of a UTC day, while the engine is still publishing it.
    final completed = <DateTime, DateTime>{
      DateTime.utc(2026, 10, 15, 0, 0): DateTime.utc(2026, 10, 13),
      DateTime.utc(2026, 10, 15, 0, 9, 59, 999): DateTime.utc(2026, 10, 13),
      DateTime.utc(2026, 10, 15, 0, 10): DateTime.utc(2026, 10, 14),
      DateTime.utc(2026, 10, 15, 12, 34, 56, 789): DateTime.utc(2026, 10, 14),
      DateTime.utc(2026, 10, 15, 23, 59, 59, 999): DateTime.utc(2026, 10, 14),
      DateTime.utc(2026, 1, 1, 0, 5): DateTime.utc(2025, 12, 30),
      DateTime.utc(2026, 3, 1, 8): DateTime.utc(2026, 2, 28),
    };
    for (final MapEntry(key: now, value: day) in completed.entries) {
      expect(lastCompletedUtcDay(now), day, reason: '$now');
    }
    // A local-time clock reads the same instant the same way.
    expect(
      lastCompletedUtcDay(DateTime.utc(2026, 10, 15, 12).toLocal()),
      DateTime.utc(2026, 10, 14),
    );

    final to = DateTime.utc(2026, 10, 14);
    final windows = {
      for (final range in PortfolioChartRange.values)
        if (range.days case final days?)
          range: PriceWindow.endingOn(to, days: days),
    };
    expect(
      {
        for (final entry in windows.entries)
          entry.key.label: (utcDateText(entry.value.from), entry.value.days),
      },
      {
        '1w': ('2026-10-08', 7),
        '1m': ('2026-09-15', 30),
        '3m': ('2026-07-17', 90),
        '1y': ('2025-10-15', 365),
      },
    );
    for (final window in windows.values) {
      expect(window.to, to);
      expect(window.from.isUtc && window.to.isUtc, isTrue);
      expect(window.from.hour + window.from.minute + window.from.second, 0);
    }
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

  group('valuing the balance at daily prices', () {
    final firstDay = DateTime.utc(2026, 10, 8);
    final lastDay = DateTime.utc(2026, 10, 14);

    test('draws every price of the range, from its first day', () {
      final balance = buildBalanceHistory([
        _delta(100, const Duration(days: 40), 40 * _zec),
        // Mid-day on the 12th, between two daily prices.
        _delta(300, const Duration(days: 3), 20 * _zec),
      ])!;

      final usd = buildPortfolioChart(
        balance: balance,
        range: PortfolioChartRange.week,
        now: _now,
        prices: _daily(firstDay, lastDay),
      )!;

      expect(usd.mode, PortfolioChartMode.usd);
      expect(usd.startValue, 4000);
      expect(usd.endValue, 6000);
      expect(usd.change, 2000);
      expect(usd.changeFraction, closeTo(0.5, 1e-9));
      // The first day is not cut at the device's clock, and the change is
      // placed at the hour it happened rather than spread over the day.
      final step = DateTime.utc(2026, 10, 12, 12);
      expect(_shape(usd), [
        (DateTime.utc(2026, 10, 8), 4000.0),
        (DateTime.utc(2026, 10, 9), 4000.0),
        (DateTime.utc(2026, 10, 10), 4000.0),
        (DateTime.utc(2026, 10, 11), 4000.0),
        (DateTime.utc(2026, 10, 12), 4000.0),
        (step, 4000.0),
        (step, 6000.0),
        (DateTime.utc(2026, 10, 13), 6000.0),
        (DateTime.utc(2026, 10, 14), 6000.0),
      ]);
    });

    test('values a change between two prices on the line between them', () {
      final balance = buildBalanceHistory([
        _delta(100, const Duration(days: 40), 10 * _zec),
        _delta(300, const Duration(days: 3), 10 * _zec),
      ])!;
      // 100 on the 12th and 110 on the 13th: 105 at the receipt at noon.
      final prices = _daily(
        firstDay,
        lastDay,
        price: (index) => index == 5 ? 110 : 100,
      );

      final chart = buildPortfolioChart(
        balance: balance,
        range: PortfolioChartRange.week,
        now: _now,
        prices: prices,
      )!;

      final step = DateTime.utc(2026, 10, 12, 12);
      expect(
        [
          for (final (time, value) in _shape(chart))
            if (time == step) value,
        ],
        [closeTo(10 * 105, 1e-9), closeTo(20 * 105, 1e-9)],
      );
    });

    test('charts a wallet funded since the last price, held at that price '
        'until now', () {
      final balance = buildBalanceHistory([
        _delta(300, const Duration(hours: 9), 5 * _zec),
      ])!;

      final chart = buildPortfolioChart(
        balance: balance,
        range: PortfolioChartRange.week,
        now: _now,
        prices: _daily(firstDay, lastDay, usd: 80),
      )!;

      expect(_shape(chart), [
        (_now.subtract(const Duration(hours: 9)), 400.0),
        (_now, 400.0),
      ]);
    });

    test(
      'charts a wallet funded between two prices from its first balance',
      () {
        final balance = buildBalanceHistory([
          _delta(300, const Duration(days: 2), 5 * _zec),
        ])!;

        final chart = buildPortfolioChart(
          balance: balance,
          range: PortfolioChartRange.week,
          now: _now,
          prices: _daily(firstDay, lastDay, usd: 80),
        )!;

        expect(_shape(chart), [
          (DateTime.utc(2026, 10, 13, 12), 400.0),
          (DateTime.utc(2026, 10, 14), 400.0),
        ]);
      },
    );

    test('draws nothing for an empty history', () {
      expect(
        buildPortfolioChart(
          balance: const BalanceHistory([]),
          range: PortfolioChartRange.week,
          now: _now,
          prices: _daily(firstDay, lastDay),
        ),
        isNull,
      );
    });

    test('draws all of the history there is for All, from the first '
        'balance', () {
      final balance = buildBalanceHistory([
        _delta(100, const Duration(days: 40), 40 * _zec),
        _delta(300, const Duration(days: 3), 20 * _zec),
      ])!;

      final zec = buildPortfolioChart(
        balance: balance,
        range: PortfolioChartRange.all,
        now: _now,
      )!;
      expect(zec.range, PortfolioChartRange.all);
      expect(zec.points.first.time, _now.subtract(const Duration(days: 40)));
      expect(zec.points.first.value, 40);
      expect(zec.endValue, 60);

      // The prices are the server's, back to its first day; the line begins
      // where the wallet's balance does.
      final usd = buildPortfolioChart(
        balance: balance,
        range: PortfolioChartRange.all,
        now: _now,
        prices: _daily(DateTime.utc(2025, 1, 1), DateTime.utc(2026, 10, 14)),
      )!;
      expect(usd.points.first.time, _now.subtract(const Duration(days: 40)));
      expect(usd.startValue, 4000);
      expect(usd.endValue, 6000);
    });

    test('draws the ZEC balance as steps over the range', () {
      final balance = buildBalanceHistory([
        _delta(100, const Duration(days: 40), 40 * _zec),
        _delta(300, const Duration(days: 3), 20 * _zec),
      ])!;

      final zec = buildPortfolioChart(
        balance: balance,
        range: PortfolioChartRange.week,
        now: _now,
      )!;

      expect(zec.mode, PortfolioChartMode.zec);
      // Held at 40 until the block that made it 60, so the line steps.
      final step = _now.subtract(const Duration(days: 3));
      expect(_shape(zec), [
        (_now.subtract(const Duration(days: 7)), 40.0),
        (step, 40.0),
        (step, 60.0),
        (_now, 60.0),
      ]);

      // A wallet younger than the range is drawn from its first balance, and one
      // with nothing in range is not drawn at all.
      final young = buildBalanceHistory([
        _delta(300, const Duration(days: 3), 20 * _zec),
      ])!;
      expect(
        buildPortfolioChart(
          balance: young,
          range: PortfolioChartRange.year,
          now: _now,
        )!.points.first.time,
        step,
      );
      expect(
        buildPortfolioChart(
          balance: const BalanceHistory([]),
          range: PortfolioChartRange.week,
          now: _now,
        ),
        isNull,
      );
    });
  });

  group('PortfolioPriceHistoryRepository', () {
    late _FakePriceSource source;
    late DateTime clock;
    late PortfolioPriceHistoryRepository repository;

    setUp(() {
      source = _FakePriceSource();
      clock = _now;
      repository = PortfolioPriceHistoryRepository(
        source: source,
        now: () => clock,
      );
    });

    test('asks for each range as whole UTC days ending yesterday', () async {
      for (final range in PortfolioChartRange.values) {
        if (range != PortfolioChartRange.all) await repository.load(range);
      }

      expect(
        [
          for (final window in source.windows)
            '${utcDateText(window.from)}..${utcDateText(window.to)}',
        ],
        [
          '2026-10-08..2026-10-14',
          '2026-09-15..2026-10-14',
          '2026-07-17..2026-10-14',
          '2025-10-15..2026-10-14',
        ],
      );
    });

    test('asks the same thing whenever in a UTC day it is asked', () async {
      final early = PortfolioPriceHistoryRepository(
        source: source,
        now: () => DateTime.utc(2026, 10, 15, 0, 10),
      );
      final late = PortfolioPriceHistoryRepository(
        source: source,
        now: () => DateTime.utc(2026, 10, 15, 23, 59, 59),
      );

      await early.load(PortfolioChartRange.month);
      await late.load(PortfolioChartRange.month);

      expect(source.windows.length, 2);
      expect(source.windows.toSet().length, 1);
    });

    test('shares one request and caches a range for its window', () async {
      final together = await Future.wait([
        repository.load(PortfolioChartRange.week),
        repository.load(PortfolioChartRange.week),
      ]);
      expect(together.first, same(together.last));
      await repository.load(PortfolioChartRange.week);
      await repository.load(PortfolioChartRange.month);
      expect(source.windows.map((window) => window.days), [7, 30]);

      // Hours later on the same day: the same window, so nothing is asked.
      clock = DateTime.utc(2026, 10, 15, 22);
      await repository.load(PortfolioChartRange.week);
      expect(source.windows.length, 2);
    });

    test('asks again when the UTC day turns, and keeps the old series if that '
        'fails', () async {
      final first = (await repository.load(PortfolioChartRange.week))!;

      clock = DateTime.utc(2026, 10, 16, 0, 30);
      source.fail = true;
      expect(await repository.load(PortfolioChartRange.week), same(first));
      expect(source.windows.length, 2);
      expect(source.windows.last.to, DateTime.utc(2026, 10, 15));

      // Left alone while the cool-down lasts.
      await repository.load(PortfolioChartRange.week);
      expect(source.windows.length, 2);

      clock = clock.add(const Duration(minutes: 6));
      source.fail = false;
      final next = (await repository.load(PortfolioChartRange.week))!;
      expect(next.series.window.to, DateTime.utc(2026, 10, 15));
      expect(source.windows.length, 3);
    });

    test('asks again for a window the server had not caught up with', () async {
      source.availableTo = DateTime.utc(2026, 10, 13);
      final lagging = (await repository.load(PortfolioChartRange.week))!;
      expect(lagging.series.reachesWindowEnd, isFalse);

      clock = clock.add(const Duration(minutes: 29));
      await repository.load(PortfolioChartRange.week);
      expect(source.windows.length, 1);

      clock = clock.add(const Duration(minutes: 2));
      source.availableTo = DateTime.utc(2026, 10, 14);
      final caughtUp = (await repository.load(PortfolioChartRange.week))!;
      expect(source.windows.length, 2);
      expect(caughtUp.series.reachesWindowEnd, isTrue);
    });

    test('leaves a failed range alone for a while, and cached asks '
        'nobody', () async {
      source.fail = true;
      expect(await repository.load(PortfolioChartRange.week), isNull);
      expect(await repository.load(PortfolioChartRange.week), isNull);
      expect(source.windows.length, 1);
      expect(repository.cached(PortfolioChartRange.week), isNull);

      clock = clock.add(const Duration(minutes: 6));
      source.fail = false;
      final loaded = await repository.load(PortfolioChartRange.week);
      expect(source.windows.length, 2);
      expect(repository.cached(PortfolioChartRange.week), same(loaded));
      expect(repository.cached(PortfolioChartRange.month), isNull);
      expect(source.windows.length, 2);
    });

    test('asks for the shortest range first, then for all the server '
        'has', () async {
      final all = (await repository.load(PortfolioChartRange.all))!;

      expect(
        [
          for (final window in source.windows)
            '${utcDateText(window.from)}..${utcDateText(window.to)}',
        ],
        ['2026-10-08..2026-10-14', '2025-01-01..2026-10-14'],
      );
      expect(all.series.points.length, 652);
      expect(all.series.points.first.time, DateTime.utc(2025, 1, 1));

      // It moves with the UTC day like any other, and now needs only itself.
      expect(await repository.load(PortfolioChartRange.all), same(all));
      expect(source.windows.length, 2);
      clock = DateTime.utc(2026, 10, 16, 1);
      await repository.load(PortfolioChartRange.all);
      expect(source.windows.length, 3);
      expect(utcDateText(source.windows.last.from), '2025-01-01');
      expect(utcDateText(source.windows.last.to), '2026-10-15');
    });

    test('needs no extra request once a shorter range has been seen', () async {
      await repository.load(PortfolioChartRange.month);
      await repository.load(PortfolioChartRange.all);

      expect(source.windows.map((window) => window.days), [30, 652]);
    });

    test('is nothing for All when not even the shortest range comes '
        'back', () async {
      source.fail = true;

      expect(await repository.load(PortfolioChartRange.all), isNull);
      expect(source.windows.map((window) => window.days), [7]);

      // And it is left alone for a while, not asked for again at once.
      expect(await repository.load(PortfolioChartRange.all), isNull);
      expect(source.windows.length, 1);
    });

    test('never asks for more days than four pages can carry', () async {
      source.availableFrom = DateTime.utc(2000, 1, 1);

      await repository.load(PortfolioChartRange.all);

      final window = source.windows.last;
      expect(window.days, kPricingEngineMaxDays);
      expect(window.to, DateTime.utc(2026, 10, 14));
      expect(window.from.isAfter(DateTime.utc(2000, 1, 1)), isTrue);
    });

    test('calls a series old only when it is over a day behind', () async {
      final loaded = (await repository.load(PortfolioChartRange.week))!;

      expect(loaded.isStaleAt(_now), isFalse);
      expect(loaded.isStaleAt(DateTime.utc(2026, 10, 16, 12)), isFalse);
      expect(loaded.isStaleAt(DateTime.utc(2026, 10, 17, 12)), isTrue);
    });
  });

  test('the source is the pricing engine, or one that asks nobody without '
      'a usable server', () async {
    final configured = ProviderContainer();
    addTearDown(configured.dispose);
    expect(
      configured.read(portfolioPriceHistorySourceProvider),
      isA<PricingEnginePortfolioPriceHistorySource>(),
    );

    final unconfigured = ProviderContainer(
      overrides: [
        portfolioPricingEngineBaseUriProvider.overrideWithValue(null),
      ],
    );
    addTearDown(unconfigured.dispose);
    final source = unconfigured.read(portfolioPriceHistorySourceProvider);
    expect(source, isA<UnavailablePortfolioPriceHistorySource>());
    expect(
      await source.fetch(
        PriceWindow.endingOn(DateTime.utc(2026, 10, 14), days: 7),
      ),
      isNull,
    );
  });

  group('Home chart state', () {
    final transactions = [
      _transaction(100, const Duration(days: 40), 40 * _zec),
      _transaction(300, const Duration(days: 3), 23 * _zec),
      // Not part of the history: never mined.
      _transaction(0, const Duration(days: 1), 9 * _zec),
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

    test('a fresh install shows the ZEC balance and asks nobody for '
        'anything', () async {
      expect(PortfolioChartSettings.defaults.enabled, isTrue);
      expect(PortfolioChartSettings.defaults.marketPrices, isFalse);
      final source = _FakePriceSource();
      // Nothing about the settings is passed: this is what a new install is.
      final container = _container(source: source, transactions: transactions);

      final view = await settle(container);

      expect(
        container.read(portfolioChartSettingsProvider),
        PortfolioChartSettings.defaults,
      );
      expect(view, isA<PortfolioChartReady>());
      final data = (view as PortfolioChartReady).data;
      expect(data.mode, PortfolioChartMode.zec);
      expect(data.notice, PortfolioChartNotice.none);
      expect(data.endValue, 63);
      expect(source.windows, isEmpty);
      expect(container.read(portfolioPriceRequestsAllowedProvider), isFalse);
    });

    test('with market prices on, values the wallet history with the prices of '
        'a fixed window', () async {
      final source = _FakePriceSource();
      final loads = <String>[];
      final container = _container(
        source: source,
        transactions: transactions,
        marketPrices: true,
        loads: loads,
      );

      final view = await settle(container);

      expect(view, isA<PortfolioChartReady>());
      final data = (view as PortfolioChartReady).data;
      expect(data.mode, PortfolioChartMode.usd);
      expect(data.notice, PortfolioChartNotice.none);
      expect(data.points.last.value, closeTo(63 * 50.0, 1e-6));
      // The history was read for this account on this network, locally, and
      // the only thing asked of the pricing server was a window of dates.
      expect(loads, ['account-1:main']);
      expect(source.windows, [
        PriceWindow(DateTime.utc(2026, 10, 8), DateTime.utc(2026, 10, 14)),
      ]);
      expect(container.read(portfolioPriceRequestsAllowedProvider), isTrue);
    });

    test(
      'shows the ZEC balance, and says so, when no prices come back',
      () async {
        final container = _container(
          source: _FakePriceSource()..fail = true,
          transactions: transactions,
          marketPrices: true,
        );

        final data = (await settle(container) as PortfolioChartReady).data;

        expect(data.mode, PortfolioChartMode.zec);
        expect(data.notice, PortfolioChartNotice.pricesUnavailable);
        expect(data.endValue, 63);
      },
    );

    test('asks nobody unless every condition holds', () async {
      // Each case switches off one condition of: the chart shown, market prices
      // on, privacy mode off, the wallet unlocked, the app in the foreground, a
      // build that offers prices, and a usable pricing server.
      final cases = <_BlockedCase>[
        _BlockedCase(
          'the chart is hidden',
          isA<PortfolioChartHidden>(),
          enabled: false,
        ),
        _BlockedCase(
          'market prices are off',
          isA<PortfolioChartReady>(),
          marketPrices: false,
        ),
        _BlockedCase(
          'privacy mode is on',
          isA<PortfolioChartPrivate>(),
          privacyMode: true,
        ),
        _BlockedCase(
          'the wallet is locked',
          isA<PortfolioChartHidden>(),
          unlocked: false,
        ),
        _BlockedCase(
          'the app is in the background',
          isA<PortfolioChartReady>(),
          foreground: false,
          // Nothing cached to draw yet, and none may be asked for.
          notice: PortfolioChartNotice.pricesUnavailable,
        ),
        _BlockedCase(
          'the build offers no prices',
          isA<PortfolioChartReady>(),
          pricesAvailable: false,
        ),
        _BlockedCase(
          'there is no usable pricing server',
          isA<PortfolioChartReady>(),
          pricingServer: false,
        ),
      ];
      for (final blocked in cases) {
        final source = _FakePriceSource();
        final container = _container(
          source: source,
          transactions: transactions,
          marketPrices: blocked.marketPrices,
          enabled: blocked.enabled,
          privacyMode: blocked.privacyMode,
          unlocked: blocked.unlocked,
          foreground: blocked.foreground,
          pricesAvailable: blocked.pricesAvailable,
          pricingServer: blocked.pricingServer,
        );

        final view = await settle(container);

        expect(view, blocked.shows, reason: blocked.name);
        expect(source.windows, isEmpty, reason: blocked.name);
        expect(
          container.read(portfolioPriceRequestsAllowedProvider),
          isFalse,
          reason: blocked.name,
        );
        if (view is PortfolioChartReady) {
          expect(view.data.mode, PortfolioChartMode.zec, reason: blocked.name);
          expect(view.data.notice, blocked.notice, reason: blocked.name);
        }
      }
    });

    test('goes quiet in the background, and asks for the new day when it '
        'returns', () async {
      var clock = _now;
      final source = _FakePriceSource();
      final foreground = _SwitchableForeground();
      final container = _container(
        source: source,
        transactions: transactions,
        marketPrices: true,
        foregroundNotifier: foreground,
        now: () => clock,
      );

      final loaded = await settle(container);
      expect((loaded as PortfolioChartReady).data.mode, PortfolioChartMode.usd);
      expect(source.windows.length, 1);

      // Hidden: what is cached still draws, and nothing is requested, not even
      // once the next UTC day has begun.
      foreground.set(false);
      clock = DateTime.utc(2026, 10, 16, 3);
      await pumpEventQueue();
      final hidden = container.read(portfolioChartViewProvider);
      expect((hidden as PortfolioChartReady).data.mode, PortfolioChartMode.usd);
      expect(source.windows.length, 1);

      foreground.set(true);
      await pumpEventQueue();
      expect(source.windows.length, 2);
      expect(source.windows.last.to, DateTime.utc(2026, 10, 15));
    });

    test('says the prices are older when the newest is over a day '
        'behind', () async {
      var clock = _now;
      final source = _FakePriceSource();
      final container = _container(
        source: source,
        transactions: transactions,
        marketPrices: true,
        now: () => clock,
      );
      await settle(container);

      // Two days on, the refresh fails: the cached series is shown, and said to
      // be old.
      source.fail = true;
      clock = DateTime.utc(2026, 10, 17, 12);
      container.invalidate(portfolioPriceHistoryProvider);
      await pumpEventQueue();

      final view = container.read(portfolioChartViewProvider);
      final data = (view as PortfolioChartReady).data;
      expect(data.mode, PortfolioChartMode.usd);
      expect(data.notice, PortfolioChartNotice.pricesStale);
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

/// A pricing server that answers every window with a flat series, or with
/// nothing.
class _FakePriceSource implements PortfolioPriceHistorySource {
  bool fail = false;
  DateTime? availableFrom;
  DateTime? availableTo;
  final windows = <PriceWindow>[];

  @override
  Future<PriceSeries?> fetch(PriceWindow window) async {
    windows.add(window);
    return fail
        ? null
        : _series(
            window,
            availableFrom: availableFrom,
            availableTo: availableTo,
          );
  }
}

/// The app's foreground state, set by the test.
class _SwitchableForeground extends AppForegroundNotifier {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

class _FixedForeground extends AppForegroundNotifier {
  _FixedForeground(this.value);

  final bool value;

  @override
  bool build() => value;
}

/// One way to arrive at the chart with a condition for asking not met.
class _BlockedCase {
  _BlockedCase(
    this.name,
    this.shows, {
    this.enabled = true,
    this.marketPrices = true,
    this.privacyMode = false,
    this.unlocked = true,
    this.foreground = true,
    this.pricesAvailable = true,
    this.pricingServer = true,
    this.notice = PortfolioChartNotice.none,
  });

  final String name;

  /// What Home shows.
  final Matcher shows;
  final bool enabled;
  final bool marketPrices;
  final bool privacyMode;
  final bool unlocked;
  final bool foreground;
  final bool pricesAvailable;
  final bool pricingServer;

  /// The note on a ZEC chart that was drawn.
  final PortfolioChartNotice notice;
}

/// A container for the Home chart. Leaving [enabled] or [marketPrices] out
/// leaves them at what a new install has, read from the app's own defaults.
ProviderContainer _container({
  required PortfolioPriceHistorySource source,
  required List<rust_sync.TransactionInfo> transactions,
  List<String>? loads,
  bool? enabled,
  bool? marketPrices,
  bool privacyMode = false,
  bool unlocked = true,
  bool foreground = true,
  bool pricesAvailable = true,
  bool pricingServer = true,
  AppForegroundNotifier? foregroundNotifier,
  DateTime Function()? now,
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
          isUnlocked: unlocked,
          passwordRotationRecoveryFailed: false,
          portfolioChartEnabled:
              enabled ?? AppBootstrapState.empty.portfolioChartEnabled,
          portfolioChartMarketPrices:
              marketPrices ??
              AppBootstrapState.empty.portfolioChartMarketPrices,
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
      zecMarketDataAvailableProvider.overrideWithValue(pricesAvailable),
      portfolioPricingEngineBaseUriProvider.overrideWithValue(
        pricingServer ? Uri.parse('https://prices.example') : null,
      ),
      appInForegroundProvider.overrideWith(
        () => foregroundNotifier ?? _FixedForeground(foreground),
      ),
      portfolioChartNowProvider.overrideWithValue(now ?? () => _now),
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
