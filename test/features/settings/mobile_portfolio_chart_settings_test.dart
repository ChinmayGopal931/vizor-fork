@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/models/portfolio_chart_models.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/providers/portfolio_chart_settings_provider.dart';
import 'package:zcash_wallet/src/features/settings/widgets/mobile/mobile_portfolio_chart_settings_card.dart';
import 'package:zcash_wallet/src/providers/zec_price_change_provider.dart';

/// Skips the secure-storage write so a toggle works without a platform channel
/// in widget tests, and records what was asked.
class _FakeSettingsNotifier extends PortfolioChartSettingsNotifier {
  final changes = <String>[];

  @override
  PortfolioChartSettings build() => PortfolioChartSettings.defaults;

  @override
  Future<void> setEnabled(bool enabled) async {
    changes.add('enabled=$enabled');
    state = state.copyWith(enabled: enabled);
  }

  @override
  Future<void> setMarketPrices(bool marketPrices) async {
    changes.add('marketPrices=$marketPrices');
    state = state.copyWith(marketPrices: marketPrices);
  }

  @override
  Future<void> setDefaultRange(PortfolioChartRange range) async {
    changes.add('range=${range.label}');
    state = state.copyWith(defaultRange: range);
  }
}

Widget _app(_FakeSettingsNotifier notifier, {bool pricesAvailable = true}) {
  return ProviderScope(
    overrides: [
      portfolioChartSettingsProvider.overrideWith(() => notifier),
      zecMarketDataAvailableProvider.overrideWithValue(pricesAvailable),
    ],
    child: MaterialApp(
      builder: (context, child) =>
          AppTheme(data: AppThemeData.dark, child: child!),
      home: const Scaffold(
        body: SingleChildScrollView(child: MobilePortfolioChartSettingsCard()),
      ),
    ),
  );
}

String _description(WidgetTester tester) => tester
    .widget<Text>(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_description')),
    )
    .data!;

bool _isOn(WidgetTester tester, String toggle) {
  final track = find.byKey(ValueKey('mobile_settings_portfolio_chart_$toggle'));
  final thumb = find.byKey(
    ValueKey('mobile_settings_portfolio_chart_${toggle}_thumb'),
  );
  return tester.getCenter(thumb).dx > tester.getCenter(track).dx;
}

void main() {
  testWidgets('shows or hides the chart, and says what it contacts', (
    tester,
  ) async {
    final notifier = _FakeSettingsNotifier();
    await tester.pumpWidget(_app(notifier));

    // On by default, with prices: the card names the server and the request.
    expect(_isOn(tester, 'toggle'), isTrue);
    expect(_description(tester), kPortfolioChartMarketPricesCopy);
    expect(_description(tester), contains('CoinGecko (api.coingecko.com)'));
    expect(find.text('Default range'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_row')),
    );
    await tester.pumpAndSettle();

    expect(notifier.changes, ['enabled=false']);
    expect(_isOn(tester, 'toggle'), isFalse);
    expect(_description(tester), kPortfolioChartHiddenCopy);
    expect(find.text('Default range'), findsNothing);

    // The price switch keeps its saved value but cannot be changed while the
    // chart is hidden.
    await tester.tap(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_prices_row')),
    );
    await tester.pumpAndSettle();
    expect(notifier.changes, ['enabled=false']);

    await tester.tap(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_row')),
    );
    await tester.pumpAndSettle();
    expect(notifier.changes, ['enabled=false', 'enabled=true']);
    expect(_isOn(tester, 'toggle'), isTrue);
  });

  testWidgets('market prices off charts the ZEC balance with no request', (
    tester,
  ) async {
    final notifier = _FakeSettingsNotifier();
    await tester.pumpWidget(_app(notifier));

    expect(_isOn(tester, 'prices_toggle'), isTrue);
    await tester.tap(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_prices_row')),
    );
    await tester.pumpAndSettle();

    expect(notifier.changes, ['marketPrices=false']);
    expect(_isOn(tester, 'prices_toggle'), isFalse);
    expect(_description(tester), kPortfolioChartLocalCopy);
    expect(_description(tester), isNot(contains('CoinGecko')));

    await tester.tap(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_range_1y')),
    );
    await tester.pumpAndSettle();
    expect(notifier.changes.last, 'range=1y');
  });

  testWidgets('a build without market prices offers no price switch', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_FakeSettingsNotifier(), pricesAvailable: false),
    );

    expect(find.text('Use market prices'), findsNothing);
    expect(_description(tester), kPortfolioChartLocalCopy);
    expect(find.text('Show on home'), findsOneWidget);
  });
}
