@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/models/portfolio_chart_models.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/providers/portfolio_chart_provider.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_chart_format.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/widgets/mobile/mobile_portfolio_chart_card.dart';

PortfolioChartData _data({
  PortfolioChartMode mode = PortfolioChartMode.usd,
  PortfolioChartNotice notice = PortfolioChartNotice.none,
}) {
  return PortfolioChartData(
    mode: mode,
    range: PortfolioChartRange.week,
    notice: notice,
    points: [
      PortfolioChartPoint(DateTime.utc(2026, 10, 13), 100),
      PortfolioChartPoint(DateTime.utc(2026, 10, 14), 110),
    ],
  );
}

Widget _card(PortfolioChartViewState state, {String? source}) {
  return MaterialApp(
    builder: (context, child) =>
        AppTheme(data: AppThemeData.dark, child: child!),
    home: Scaffold(
      body: SingleChildScrollView(
        child: MobilePortfolioChartCard(
          state: state,
          priceSourceName: source ?? 'the pricing server',
          onRangeSelected: (_) {},
        ),
      ),
    ),
  );
}

String _sourceLine(WidgetTester tester) => tester
    .widget<Text>(
      find.byKey(const ValueKey('mobile_home_portfolio_chart_source')),
    )
    .data!;

void main() {
  testWidgets('the source line never names the pricing server, and says '
      'when nothing leaves the device', (tester) async {
    // Settings names the server; the card stays quiet about healthy prices.
    await tester.pumpWidget(
      _card(PortfolioChartReady(_data()), source: 'zapp-pricing-engine'),
    );
    expect(_sourceLine(tester), isEmpty);
    expect(find.textContaining('zapp-pricing-engine'), findsNothing);
    // The title is a HUD caption, drawn uppercase.
    expect(find.text('PORTFOLIO VALUE'), findsOneWidget);

    await tester.pumpWidget(
      _card(
        const PortfolioChartLoading(
          PortfolioChartRange.week,
          PortfolioChartMode.usd,
        ),
        source: 'zapp-pricing-engine',
      ),
    );
    expect(_sourceLine(tester), isEmpty);
    expect(find.textContaining('zapp-pricing-engine'), findsNothing);

    await tester.pumpWidget(
      _card(PortfolioChartReady(_data(mode: PortfolioChartMode.zec))),
    );
    expect(_sourceLine(tester), 'On this device');
    expect(find.text('ZEC BALANCE'), findsOneWidget);

    await tester.pumpWidget(
      _card(
        PortfolioChartReady(
          _data(
            mode: PortfolioChartMode.zec,
            notice: PortfolioChartNotice.pricesUnavailable,
          ),
        ),
      ),
    );
    expect(_sourceLine(tester), 'Prices unavailable');

    await tester.pumpWidget(
      _card(
        PortfolioChartReady(_data(notice: PortfolioChartNotice.pricesStale)),
      ),
    );
    expect(_sourceLine(tester), 'Older prices');
  });

  testWidgets('offers every range, All included, and says which was '
      'picked', (tester) async {
    final picked = <PortfolioChartRange>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AppTheme(data: AppThemeData.dark, child: child!),
        home: Scaffold(
          body: MobilePortfolioChartCard(
            state: PortfolioChartReady(_data()),
            onRangeSelected: picked.add,
          ),
        ),
      ),
    );

    for (final label in ['1w', '1m', '3m', '1y', 'All']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(
      find.byKey(const ValueKey('mobile_home_portfolio_chart_range_All')),
    );
    expect(picked, [PortfolioChartRange.all]);
    expect(PortfolioChartRange.all.description, 'All time');
  });

  testWidgets('the chart names no server whatever the build configures', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          portfolioChartViewProvider.overrideWithValue(
            const PortfolioChartLoading(
              PortfolioChartRange.week,
              PortfolioChartMode.usd,
            ),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) =>
              AppTheme(data: AppThemeData.dark, child: child!),
          home: const Scaffold(body: MobilePortfolioChartSlot()),
        ),
      ),
    );

    // The default build prices from the zapp pricing engine; the card does
    // not say so (Settings does).
    expect(_sourceLine(tester), isEmpty);
    expect(find.textContaining('zapp-pricing-engine'), findsNothing);
  });

  testWidgets('dragging along a daily price shows the UTC day it belongs to', (
    tester,
  ) async {
    await tester.pumpWidget(
      _card(PortfolioChartReady(_data()), source: 'zapp-pricing-engine'),
    );
    final plot = tester.getTopLeft(
      find.byKey(const ValueKey('mobile_home_portfolio_chart_plot')),
    );

    final gesture = await tester.startGesture(plot + const Offset(8, 40));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();

    // The first price is the 13th at 00:00 UTC, whatever zone the phone is in.
    expect(_sourceLine(tester), 'Oct 13, 2026');
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('mobile_home_portfolio_chart_value')),
          )
          .data,
      '\$100.00',
    );

    await gesture.up();
    await tester.pump();
    expect(_sourceLine(tester), isEmpty);
  });

  test(
    'dates a daily price by its UTC day and any other point by the clock',
    () {
      expect(
        formatPortfolioPointTime(
          DateTime.utc(2026, 10, 14),
          PortfolioChartRange.week,
          PortfolioChartMode.usd,
        ),
        'Oct 14, 2026',
      );
      // Midnight UTC of a block time is not a daily price.
      expect(
        formatPortfolioPointTime(
          DateTime.utc(2026, 10, 14),
          PortfolioChartRange.week,
          PortfolioChartMode.zec,
        ),
        isNot('Oct 14, 2026'),
      );
      // A receipt placed between two prices, or now, has a time of day.
      expect(
        formatPortfolioPointTime(
          DateTime.utc(2026, 10, 12, 12, 30),
          PortfolioChartRange.week,
          PortfolioChartMode.usd,
        ),
        contains(':'),
      );
    },
  );

  test(
    'names the pricing server in full in Settings and by service on Home',
    () {
      final engine = Uri.parse(
        'https://zapp-pricing-engine.majorworker.workers.dev',
      );
      expect(
        portfolioPricingServerHost(engine),
        'zapp-pricing-engine.majorworker.workers.dev',
      );
      expect(portfolioPriceSourceName(engine), 'zapp-pricing-engine');

      final short = Uri.parse('https://prices.example:8443');
      expect(portfolioPricingServerHost(short), 'prices.example:8443');
      expect(portfolioPriceSourceName(short), 'prices.example');

      expect(portfolioPricingServerHost(null), isEmpty);
      expect(portfolioPriceSourceName(null), 'the pricing server');
    },
  );
}
