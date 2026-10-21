@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/models/portfolio_chart_models.dart';
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

Widget _card(PortfolioChartViewState state) {
  return MaterialApp(
    builder: (context, child) =>
        AppTheme(data: AppThemeData.dark, child: child!),
    home: Scaffold(
      body: SingleChildScrollView(
        child: MobilePortfolioChartCard(state: state, onRangeSelected: (_) {}),
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
    // Healthy prices get no note.
    await tester.pumpWidget(_card(PortfolioChartReady(_data())));
    expect(_sourceLine(tester), isEmpty);
    // The title is a HUD caption, drawn uppercase.
    expect(find.text('PORTFOLIO VALUE'), findsOneWidget);

    await tester.pumpWidget(
      _card(
        const PortfolioChartLoading(
          PortfolioChartRange.week,
          PortfolioChartMode.usd,
        ),
      ),
    );
    expect(_sourceLine(tester), isEmpty);

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

  testWidgets('dragging along a daily price shows the UTC day it belongs to', (
    tester,
  ) async {
    await tester.pumpWidget(_card(PortfolioChartReady(_data())));
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
}
