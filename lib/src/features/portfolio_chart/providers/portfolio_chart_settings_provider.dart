import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/config/pricing_engine_config.dart';
import '../../../core/storage/app_secure_store.dart';
import '../../../providers/zec_price_change_provider.dart';
import '../models/portfolio_chart_models.dart';

/// The Home portfolio chart's settings.
@immutable
class PortfolioChartSettings {
  const PortfolioChartSettings({
    required this.enabled,
    required this.marketPrices,
    required this.defaultRange,
  });

  /// The shipped defaults: shown, the ZEC balance, one week. Market prices are
  /// off until the user turns them on, because they are the one thing here that
  /// contacts a server: a fresh install requests nothing for the chart.
  static const defaults = PortfolioChartSettings(
    enabled: true,
    marketPrices: false,
    defaultRange: PortfolioChartRange.defaultRange,
  );

  /// Whether the chart is on Home at all.
  final bool enabled;

  /// Whether to value the balance in USD, which asks the pricing server for
  /// daily prices. Off, the chart shows the ZEC balance and makes no request.
  final bool marketPrices;

  /// The range the chart opens on.
  final PortfolioChartRange defaultRange;

  PortfolioChartSettings copyWith({
    bool? enabled,
    bool? marketPrices,
    PortfolioChartRange? defaultRange,
  }) {
    return PortfolioChartSettings(
      enabled: enabled ?? this.enabled,
      marketPrices: marketPrices ?? this.marketPrices,
      defaultRange: defaultRange ?? this.defaultRange,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PortfolioChartSettings &&
            other.enabled == enabled &&
            other.marketPrices == marketPrices &&
            other.defaultRange == defaultRange;
  }

  @override
  int get hashCode => Object.hash(enabled, marketPrices, defaultRange);
}

/// The pricing server the chart would ask, or `null` when this build has none
/// it can use: the define is empty, not `https`, or not a plain origin.
final portfolioPricingEngineBaseUriProvider = Provider<Uri?>(
  (ref) => parsePricingEngineBaseUri(kVizorPricingEngineBaseUrl),
);

/// Whether this build can value the chart at market prices at all: where Home
/// shows a price (its own gate, so the chart never reaches a price service on a
/// build where the Home price would not) and with a usable pricing server.
/// Where it is false the chart is the ZEC balance and Settings offers no price
/// switch.
final portfolioChartPricesAvailableProvider = Provider<bool>((ref) {
  return ref.watch(zecMarketDataAvailableProvider) &&
      ref.watch(portfolioPricingEngineBaseUriProvider) != null;
});

class PortfolioChartSettingsNotifier extends Notifier<PortfolioChartSettings> {
  static final _store = AppSecureStore.instance;

  @override
  PortfolioChartSettings build() {
    final bootstrap = ref.watch(appBootstrapProvider);
    return PortfolioChartSettings(
      enabled: bootstrap.portfolioChartEnabled,
      marketPrices: bootstrap.portfolioChartMarketPrices,
      defaultRange:
          PortfolioChartRange.tryParse(bootstrap.portfolioChartRange) ??
          PortfolioChartRange.defaultRange,
    );
  }

  Future<void> setEnabled(bool enabled) async {
    await _store.writePlain(
      kPortfolioChartEnabledKey,
      enabled ? 'true' : 'false',
    );
    state = state.copyWith(enabled: enabled);
  }

  Future<void> setMarketPrices(bool marketPrices) async {
    await _store.writePlain(
      kPortfolioChartMarketPricesKey,
      marketPrices ? 'true' : 'false',
    );
    state = state.copyWith(marketPrices: marketPrices);
  }

  Future<void> setDefaultRange(PortfolioChartRange range) async {
    await _store.writePlain(kPortfolioChartRangeKey, range.label);
    state = state.copyWith(defaultRange: range);
  }
}

final portfolioChartSettingsProvider =
    NotifierProvider<PortfolioChartSettingsNotifier, PortfolioChartSettings>(
      PortfolioChartSettingsNotifier.new,
    );

/// The range on show right now. It opens on the saved default and changes with
/// the chips on Home for the rest of the session only; changing the default in
/// Settings resets it.
class PortfolioChartRangeNotifier extends Notifier<PortfolioChartRange> {
  @override
  PortfolioChartRange build() {
    return ref.watch(
      portfolioChartSettingsProvider.select(
        (settings) => settings.defaultRange,
      ),
    );
  }

  void select(PortfolioChartRange range) => state = range;
}

final portfolioChartRangeProvider =
    NotifierProvider<PortfolioChartRangeNotifier, PortfolioChartRange>(
      PortfolioChartRangeNotifier.new,
    );
