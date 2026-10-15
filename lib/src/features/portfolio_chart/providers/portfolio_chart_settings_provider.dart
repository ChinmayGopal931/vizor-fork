import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/storage/app_secure_store.dart';
import '../models/portfolio_chart_models.dart';

/// The Home portfolio chart's settings.
@immutable
class PortfolioChartSettings {
  const PortfolioChartSettings({
    required this.enabled,
    required this.marketPrices,
    required this.defaultRange,
  });

  /// The shipped defaults: shown, valued with market prices, one week. Market
  /// prices default to on because the Home price beside the chart is fetched
  /// without being asked either.
  static const defaults = PortfolioChartSettings(
    enabled: true,
    marketPrices: true,
    defaultRange: PortfolioChartRange.defaultRange,
  );

  /// Whether the chart is on Home at all.
  final bool enabled;

  /// Whether to value the balance in USD, which asks a price service for
  /// prices. Off, the chart shows the ZEC balance and makes no request.
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
