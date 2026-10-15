import '../../../core/config/network_config.dart';
import '../../../core/formatting/date_format.dart';
import '../../../core/formatting/number_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../models/portfolio_chart_models.dart';

/// `$1,234.56`. Sign is the caller's.
String formatPortfolioUsd(double value) {
  final cents = (value.abs() * 100).round();
  final fraction = (cents % 100).toString().padLeft(2, '0');
  return '\$${formatGroupedInteger(cents ~/ 100)}.$fraction';
}

/// `12.345 ZEC`, with the balance card's precision. Sign is the caller's.
String formatPortfolioZec(double value) {
  final zatoshi = BigInt.from((value.abs() * 100000000).round());
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
/// minute for the shorter spans, the day for a year.
String formatPortfolioPointTime(
  DateTime time,
  PortfolioChartRange range,
  PortfolioChartMode mode,
) {
  final utc = time.toUtc();
  final isDailyPrice =
      mode == PortfolioChartMode.usd &&
      utc.hour == 0 &&
      utc.minute == 0 &&
      utc.second == 0 &&
      utc.millisecond == 0 &&
      utc.microsecond == 0;
  if (isDailyPrice) {
    return '${monthAbbreviation(utc.month)} ${utc.day}, ${utc.year}';
  }
  return range == PortfolioChartRange.year
      ? formatMonthDayYear(time)
      : formatDayMonthTime(time);
}

/// The pricing server's host as Settings names it, in full: `host`, or
/// `host:port` when the origin has a port of its own. Empty without a server.
String portfolioPricingServerHost(Uri? baseUri) {
  if (baseUri == null || baseUri.host.isEmpty) return '';
  return baseUri.hasPort ? '${baseUri.host}:${baseUri.port}' : baseUri.host;
}

/// The longest host the Home card names in full; a longer one is shortened to
/// its first label, which for `zapp-pricing-engine.majorworker.workers.dev` is
/// the service's own name. Settings always names the host in full.
const _fullHostLimit = 24;

/// What the Home card calls the pricing server in "Prices from ...": the host
/// when it is short enough to fit beside the card's title, otherwise its first
/// label.
String portfolioPriceSourceName(Uri? baseUri) {
  final host = baseUri?.host ?? '';
  if (host.isEmpty) return 'the pricing server';
  return host.length <= _fullHostLimit ? host : host.split('.').first;
}
