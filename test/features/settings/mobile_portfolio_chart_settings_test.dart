@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/pricing_engine_config.dart';
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

const _host = 'zapp-pricing-engine.majorworker.workers.dev';

Widget _app(
  _FakeSettingsNotifier notifier, {
  bool pricesAvailable = true,
  Uri? pricingServer,
  bool hasPricingServer = true,
}) {
  return ProviderScope(
    overrides: [
      portfolioChartSettingsProvider.overrideWith(() => notifier),
      zecMarketDataAvailableProvider.overrideWithValue(pricesAvailable),
      portfolioPricingEngineBaseUriProvider.overrideWithValue(
        hasPricingServer
            ? pricingServer ??
                  parsePricingEngineBaseUri(kVizorPricingEngineBaseUrl)
            : null,
      ),
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

    // Shown by default, and nothing is requested: the card says so, and what
    // turning prices on would do.
    expect(_isOn(tester, 'toggle'), isTrue);
    expect(_description(tester), portfolioChartPricesOffCopy(_host));
    // The range is picked on the chart itself; the card has no range row.
    expect(find.text('Default range'), findsNothing);

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

  testWidgets('market prices are off until turned on, and the card then '
      'says exactly what is contacted', (tester) async {
    final notifier = _FakeSettingsNotifier();
    await tester.pumpWidget(_app(notifier));

    // Opt-in: off by default, with the offer and its cost stated up front.
    expect(_isOn(tester, 'prices_toggle'), isFalse);
    expect(_description(tester), contains(_host));
    expect(_description(tester), contains('Nothing is requested'));
    expect(_description(tester), contains('IP address unless Tor is on'));
    expect(_description(tester), isNot(contains('CoinGecko')));

    await tester.tap(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_prices_row')),
    );
    await tester.pumpAndSettle();

    expect(notifier.changes, ['marketPrices=true']);
    expect(_isOn(tester, 'prices_toggle'), isTrue);
    final copy = _description(tester);
    expect(copy, portfolioChartMarketPricesCopy(_host));
    // The host in full, what a request carries, who sees the address, and the
    // currency.
    expect(copy, contains('requested from $_host'));
    expect(
      copy,
      contains('names only ZEC, USD, daily prices and a date range'),
    );
    expect(copy, contains('nothing from your wallet'));
    expect(copy, contains('sees your IP address unless Tor is on'));
    expect(copy, contains('USD only'));
    expect(copy, isNot(contains('CoinGecko')));

    await tester.tap(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_prices_row')),
    );
    await tester.pumpAndSettle();
    expect(notifier.changes, ['marketPrices=true', 'marketPrices=false']);
    expect(_isOn(tester, 'prices_toggle'), isFalse);
    expect(_description(tester), portfolioChartPricesOffCopy(_host));

    // No range chips: the card never changes the default range.
    expect(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_range_1y')),
      findsNothing,
    );
    expect(
      notifier.changes.where((change) => change.startsWith('range=')),
      isEmpty,
    );
  });

  testWidgets('names the host the build is configured with, port included', (
    tester,
  ) async {
    final notifier = _FakeSettingsNotifier();
    await tester.pumpWidget(
      _app(notifier, pricingServer: Uri.parse('https://prices.example:8443')),
    );
    await tester.tap(
      find.byKey(const ValueKey('mobile_settings_portfolio_chart_prices_row')),
    );
    await tester.pumpAndSettle();

    expect(
      _description(tester),
      portfolioChartMarketPricesCopy('prices.example:8443'),
    );
    expect(_description(tester), isNot(contains(_host)));
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

  testWidgets('a build with no usable pricing server offers no price switch', (
    tester,
  ) async {
    // An empty, non-https or invalid VIZOR_PRICING_ENGINE_BASE_URL.
    await tester.pumpWidget(
      _app(_FakeSettingsNotifier(), hasPricingServer: false),
    );

    expect(find.text('Use market prices'), findsNothing);
    expect(_description(tester), kPortfolioChartLocalCopy);
    expect(_description(tester), isNot(contains('IP address')));
  });
}
