import '../../../core/config/network_config.dart';
import '../../../core/formatting/date_format.dart';
import '../../../core/formatting/number_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../models/portfolio_chart_models.dart';
import 'portfolio_price_history.dart';

/// `$1,234.56`. Sign is the caller's.
String formatPortfolioUsd(double value) {
  final cents = (value.abs() * 100).round();
  final fraction = (cents % 100).toString().padLeft(2, '0');
  return '\$${formatGroupedInteger(cents ~/ 100)}.$fraction';
}

/// `12.345 ZEC`, with the balance card's precision. Sign is the caller's.
String formatPortfolioZec(double value) {
  final zatoshi = BigInt.from((value.abs() * zatoshiPerZec.toDouble()).round());
  final amount = ZecAmount.fromZatoshi(zatoshi).compactBalance.amountText;
  return '$amount $kZcashDefaultCurrencyTicker';
}

String formatPortfolioValue(PortfolioChartMode mode, double value) {
  return switch (mode) {
    PortfolioChartMode.usd => formatPortfolioUsd(value),
    PortfolioChartMode.zec => formatPortfolioZec(value),
  };
}

enum PortfolioChartTrend { up, down, flat }

class PortfolioChartChange {
  const PortfolioChartChange(this.text, this.trend);

  /// `+ $12.34 · 5.67%`: the change over the range, in the chart's unit and as
  /// a share of where it started.
  final String text;
  final PortfolioChartTrend trend;
}

/// The change over the whole range. Amounts that round to nothing at the
/// precision shown read as flat rather than as a signed zero.
PortfolioChartChange describePortfolioChange(PortfolioChartData data) {
  final change = data.change;
  final fraction = data.changeFraction;
  final percent = fraction == null ? null : fraction.abs() * 100;
  final amount = formatPortfolioValue(data.mode, change.abs());
  final percentText = percent == null
      ? ''
      : ' · ${percent.toStringAsFixed(2)}%';
  final flat =
      amount == formatPortfolioValue(data.mode, 0) &&
      (percent == null || percent.toStringAsFixed(2) == '0.00');
  if (flat) {
    return PortfolioChartChange(
      '$amount$percentText',
      PortfolioChartTrend.flat,
    );
  }
  final up = change > 0;
  return PortfolioChartChange(
    '${up ? '+' : '-'} $amount$percentText',
    up ? PortfolioChartTrend.up : PortfolioChartTrend.down,
  );
}

/// When a point was.
///
/// A daily price (a USD point at a UTC midnight) is that UTC day's, so it is
/// dated by its UTC day: shifted into local time it would read a day early west
/// of Greenwich. Any other point is an instant (a block time, or now): to the
/// minute for the shorter spans, the day for a year or all of it.
String formatPortfolioPointTime(
  DateTime time,
  PortfolioChartRange range,
  PortfolioChartMode mode,
) {
  if (mode == PortfolioChartMode.usd && isUtcMidnight(time)) {
    final utc = time.toUtc();
    return '${monthAbbreviation(utc.month)} ${utc.day}, ${utc.year}';
  }
  return range == PortfolioChartRange.year || range == PortfolioChartRange.all
      ? formatMonthDayYear(time)
      : formatDayMonthTime(time);
}
