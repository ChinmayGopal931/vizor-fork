import '../models/portfolio_chart_models.dart';
import 'portfolio_balance_history.dart';
import 'portfolio_price_history.dart';

const _zatoshiPerZec = 100000000.0;

/// More points than a phone can show add nothing, and the hourly series for a
/// quarter has over two thousand.
const kPortfolioChartMaxPoints = 240;

/// A price sample may be stamped a little ahead of this device's clock.
const _clockSlack = Duration(minutes: 10);

/// Builds the chart for [range] counted back from [now].
///
/// With [prices] the line is the balance valued at each price sample (USD);
/// without, it is the ZEC balance as a step function. Either way the line
/// starts at the first moment the balance was above zero, so a young wallet is
/// not drawn from a long flat zero.
///
/// Returns `null` when fewer than two points remain, or the line would start
/// at nothing.
PortfolioChartData? buildPortfolioChart({
  required BalanceHistory balance,
  required PortfolioChartRange range,
  required DateTime now,
  List<PricePoint>? prices,
  PortfolioChartNotice notice = PortfolioChartNotice.none,
}) {
  final end = now.toUtc();
  final start = end.subtract(range.window);
  final points = prices == null
      ? _balancePoints(balance, start, end)
      : _downsample(
          _valuedPoints(balance, prices, start, end),
          kPortfolioChartMaxPoints,
        );
  if (points.length < 2 || points.first.value <= 0) return null;
  return PortfolioChartData(
    mode: prices == null ? PortfolioChartMode.zec : PortfolioChartMode.usd,
    range: range,
    points: points,
    notice: notice,
  );
}

double _zec(int zatoshi) => zatoshi / _zatoshiPerZec;

List<PortfolioChartPoint> _balancePoints(
  BalanceHistory balance,
  DateTime start,
  DateTime end,
) {
  final points = <PortfolioChartPoint>[];
  var current = balance.balanceAt(start);
  if (current > 0) points.add(PortfolioChartPoint(start, _zec(current)));
  for (final step in balance.steps) {
    if (!step.time.isAfter(start)) continue;
    if (step.time.isAfter(end)) break;
    // Hold the old balance up to the moment it changes, so the line steps
    // instead of sloping between two blocks.
    if (current > 0) points.add(PortfolioChartPoint(step.time, _zec(current)));
    current = step.zatoshi;
    points.add(PortfolioChartPoint(step.time, _zec(current)));
  }
  if (points.isNotEmpty) points.add(PortfolioChartPoint(end, _zec(current)));
  return points;
}

List<PortfolioChartPoint> _valuedPoints(
  BalanceHistory balance,
  List<PricePoint> prices,
  DateTime start,
  DateTime end,
) {
  final limit = end.add(_clockSlack);
  final points = <PortfolioChartPoint>[];
  PricePoint? latest;
  for (final price in prices) {
    if (price.time.isBefore(start)) continue;
    if (price.time.isAfter(limit)) break;
    latest = price;
    final value = _zec(balance.balanceAt(price.time)) * price.usd;
    // Leading zero balance is not part of the story.
    if (value <= 0 && points.isEmpty) continue;
    points.add(PortfolioChartPoint(price.time, value));
  }
  // A balance change after the last price sample would otherwise wait for the
  // next sample to show.
  if (latest != null && points.isNotEmpty && latest.time.isBefore(end)) {
    final settled = balance.balanceAt(end);
    if (settled != balance.balanceAt(latest.time)) {
      points.add(PortfolioChartPoint(end, _zec(settled) * latest.usd));
    }
  }
  return points;
}

List<PortfolioChartPoint> _downsample(
  List<PortfolioChartPoint> points,
  int maxPoints,
) {
  if (points.length <= maxPoints) return points;
  final stride = (points.length / maxPoints).ceil();
  final sampled = <PortfolioChartPoint>[
    for (var i = 0; i < points.length; i += stride) points[i],
  ];
  if (!identical(sampled.last, points.last)) sampled.add(points.last);
  return sampled;
}
