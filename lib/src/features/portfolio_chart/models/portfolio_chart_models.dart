import 'package:flutter/foundation.dart';

/// The spans the portfolio chart offers.
enum PortfolioChartRange {
  week('1w', 'Past week', Duration(days: 7)),
  month('1m', 'Past month', Duration(days: 30)),
  quarter('3m', 'Past 3 months', Duration(days: 90)),
  year('1y', 'Past year', Duration(days: 365)),
  all('All', 'All time', null);

  const PortfolioChartRange(this.label, this.description, this.window);

  /// Short label on the range chips; also the stored value.
  final String label;

  /// Screen-reader wording for the span.
  final String description;

  /// How far back the span reaches, or `null` for all of the history there is.
  final Duration? window;

  int? get days => window?.inDays;

  static const defaultRange = PortfolioChartRange.week;

  static PortfolioChartRange? tryParse(String? raw) {
    for (final range in values) {
      if (range.label == raw) return range;
    }
    return null;
  }
}

enum PortfolioChartMode {
  /// The balance valued at the pricing server's daily ZEC/USD prices.
  usd,

  /// The ZEC balance alone, from the wallet database.
  zec,
}

/// Why a chart differs from what the settings ask for.
enum PortfolioChartNotice {
  none,

  /// USD was asked for but no prices could be had, so the ZEC balance is shown.
  pricesUnavailable,

  /// USD prices are shown, but the newest is more than a day behind.
  pricesStale,
}

@immutable
class PortfolioChartPoint {
  const PortfolioChartPoint(this.time, this.value);

  /// UTC.
  final DateTime time;

  /// USD for [PortfolioChartMode.usd], ZEC for [PortfolioChartMode.zec].
  final double value;
}

/// A chart ready to draw: at least two points, ascending in time.
/// `buildPortfolioChart` is what guarantees that.
@immutable
class PortfolioChartData {
  const PortfolioChartData({
    required this.mode,
    required this.range,
    required this.points,
    this.notice = PortfolioChartNotice.none,
  });

  final PortfolioChartMode mode;
  final PortfolioChartRange range;
  final List<PortfolioChartPoint> points;
  final PortfolioChartNotice notice;

  double get startValue => points.first.value;
  double get endValue => points.last.value;
  double get change => endValue - startValue;

  /// The change as a fraction of the starting value, or `null` when the chart
  /// starts at nothing.
  double? get changeFraction => startValue > 0 ? change / startValue : null;
}

sealed class PortfolioChartViewState {
  const PortfolioChartViewState();
}

/// Nothing: switched off, or no balance history to draw.
final class PortfolioChartHidden extends PortfolioChartViewState {
  const PortfolioChartHidden();
}

/// A chart for [range] in [mode] that shows a placeholder instead of a line.
sealed class PortfolioChartPlaceholder extends PortfolioChartViewState {
  const PortfolioChartPlaceholder(this.range, this.mode);

  final PortfolioChartRange range;
  final PortfolioChartMode mode;
}

/// Waiting on the balance history or the prices.
final class PortfolioChartLoading extends PortfolioChartPlaceholder {
  const PortfolioChartLoading(super.range, super.mode);
}

/// A balance history that is too short for [range].
final class PortfolioChartEmpty extends PortfolioChartPlaceholder {
  const PortfolioChartEmpty(super.range, super.mode);
}

/// Privacy mode is on: the shape and values of the history stay hidden.
final class PortfolioChartPrivate extends PortfolioChartPlaceholder {
  const PortfolioChartPrivate(super.range, super.mode);
}

final class PortfolioChartReady extends PortfolioChartViewState {
  const PortfolioChartReady(this.data);

  final PortfolioChartData data;
}
