// ignore_for_file: depend_on_referenced_packages
// Dev-only: Widgetbook and Figma comparison fixtures for the Home portfolio
// chart. Nothing here is reachable from `lib/main.dart`.

import 'dart:math' as math;

import '../src/features/portfolio_chart/models/portfolio_chart_models.dart';
import '../src/features/portfolio_chart/providers/portfolio_chart_settings_provider.dart';
import '../src/features/portfolio_chart/services/portfolio_balance_history.dart';
import '../src/features/portfolio_chart/services/portfolio_price_history.dart';
import '../src/features/portfolio_chart/services/portfolio_valuation.dart';

/// The instant every preview is drawn at, so captures never move.
final previewPortfolioChartNow = DateTime.utc(2026, 10, 15, 12);

/// 143.12 ZEC, the balance the Home previews show, reached in three receipts.
final _previewBalance = buildBalanceHistory([
  BalanceDelta(
    height: 3_100_000,
    time: previewPortfolioChartNow.subtract(const Duration(days: 400)),
    zatoshi: 8000000000,
  ),
  BalanceDelta(
    height: 3_380_000,
    time: previewPortfolioChartNow.subtract(const Duration(days: 40)),
    zatoshi: 4000000000,
  ),
  BalanceDelta(
    height: 3_420_000,
    time: previewPortfolioChartNow.subtract(const Duration(days: 3)),
    zatoshi: 2312000000,
  ),
])!;

/// A repeatable price walk ending near $70, hourly up to a quarter and daily
/// beyond, like the real series. [falling] makes it end lower than it began.
List<PricePoint> _previewPrices(PortfolioChartRange range, bool falling) {
  final step = range.days > 90
      ? const Duration(days: 1)
      : const Duration(hours: 1);
  final count = range.window.inMinutes ~/ step.inMinutes;
  return [
    for (var i = 0; i <= count; i++)
      PricePoint(
        previewPortfolioChartNow.subtract(step * (count - i)),
        _previewPrice(i / count, falling, i),
      ),
  ];
}

double _previewPrice(double progress, bool falling, int index) {
  final trend = falling ? 1 - 0.28 * progress : 0.78 + 0.28 * progress;
  final swing =
      0.05 * math.sin(progress * 11) +
      0.025 * math.sin(progress * 37 + 1) +
      0.008 * math.sin(index * 1.7);
  return 70 * (trend + swing);
}

/// A finished chart through the real valuation code, so a preview shows what
/// the pipeline draws for this history rather than a hand-made curve.
PortfolioChartData previewPortfolioChartData({
  PortfolioChartMode mode = PortfolioChartMode.usd,
  PortfolioChartRange range = PortfolioChartRange.week,
  bool falling = false,
  PortfolioChartNotice notice = PortfolioChartNotice.none,
}) {
  final fromPrices = mode == PortfolioChartMode.usd;
  return buildPortfolioChart(
    balance: _previewBalance,
    range: range,
    now: previewPortfolioChartNow,
    prices: fromPrices ? _previewPrices(range, falling) : null,
    notice: notice,
  )!;
}

/// Settings that change on screen and never reach storage, so the Settings
/// card is live in Widgetbook without a platform channel.
class PreviewPortfolioChartSettingsNotifier
    extends PortfolioChartSettingsNotifier {
  PreviewPortfolioChartSettingsNotifier(this.initial);

  final PortfolioChartSettings initial;

  @override
  PortfolioChartSettings build() => initial;

  @override
  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
  }

  @override
  Future<void> setMarketPrices(bool marketPrices) async {
    state = state.copyWith(marketPrices: marketPrices);
  }

  @override
  Future<void> setDefaultRange(PortfolioChartRange range) async {
    state = state.copyWith(defaultRange: range);
  }
}
