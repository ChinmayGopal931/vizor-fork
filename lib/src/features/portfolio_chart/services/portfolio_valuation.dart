import '../../../core/formatting/zec_amount.dart';
import '../models/portfolio_chart_models.dart';
import 'portfolio_balance_history.dart';
import 'portfolio_price_history.dart';

/// Earlier than any wallet history, for a span with no start of its own.
final _beforeAnyBalance = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// More points than a phone can show add nothing.
const kPortfolioChartMaxPoints = 240;

/// A price sample may be stamped a little ahead of this device's clock.
const _clockSlack = Duration(minutes: 10);

/// Builds the chart for [range] counted back from [now]: with [prices], the
/// balance valued at each of them (the series is already the range, so it is
/// not cut again at the device's clock); without, the ZEC balance as a step
/// function. Either way the line starts once the balance is above zero, so a
/// young wallet is not drawn from a long flat zero. `null` when fewer than two
/// points remain, or the line would start at nothing.
PortfolioChartData? buildPortfolioChart({
  required BalanceHistory balance,
  required PortfolioChartRange range,
  required DateTime now,
  List<PricePoint>? prices,
  PortfolioChartNotice notice = PortfolioChartNotice.none,
}) {
  final end = now.toUtc();
  final window = range.window;
  final points = prices == null
      ? _balancePoints(
          balance,
          window == null ? _beforeAnyBalance : end.subtract(window),
          end,
        )
      : _downsample(
          _valuedPoints(balance, prices, end),
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

double _zec(int zatoshi) => zatoshi / zatoshiPerZec.toDouble();

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

/// The balance valued at each daily price.
///
/// A daily price is one sample a day, but the balance changes at block times,
/// so a change between two samples is placed at its own time, valued on the
/// straight line between the two prices around it. Without that, a receipt
/// would be drawn as a slope across the whole day, and a wallet funded since
/// the last sample would have no chart until the next one.
List<PortfolioChartPoint> _valuedPoints(
  BalanceHistory balance,
  List<PricePoint> prices,
  DateTime end,
) {
  final limit = end.add(_clockSlack);
  final steps = balance.steps;
  final points = <PortfolioChartPoint>[];

  void add(DateTime time, int zatoshi, double usd) {
    final value = _zec(zatoshi) * usd;
    // Leading zero balance is not part of the story.
    if (value <= 0 && points.isEmpty) return;
    points.add(PortfolioChartPoint(time, value));
  }

  // The first step not placed yet, and the balance after the last point placed.
  var next = 0;
  var held = 0;
  PricePoint? previous;
  for (final price in prices) {
    if (price.time.isAfter(limit)) break;
    while (next < steps.length && steps[next].time.isBefore(price.time)) {
      final step = steps[next++];
      // Before the first sample, or at the previous one: already in the balance.
      if (previous == null || !step.time.isAfter(previous.time)) continue;
      final usd = _priceBetween(previous, price, step.time);
      add(step.time, held, usd);
      add(step.time, step.zatoshi, usd);
      held = step.zatoshi;
    }
    held = balance.balanceAt(price.time);
    add(price.time, held, price.usd);
    previous = price;
  }

  // A balance change after the last price sample would otherwise wait for the
  // next sample to show. It keeps that price, up to now.
  final latest = previous;
  if (latest != null && latest.time.isBefore(end)) {
    final sampled = held;
    while (next < steps.length && !steps[next].time.isAfter(end)) {
      final step = steps[next++];
      if (!step.time.isAfter(latest.time)) continue;
      add(step.time, held, latest.usd);
      add(step.time, step.zatoshi, latest.usd);
      held = step.zatoshi;
    }
    if (held != sampled) add(end, held, latest.usd);
  }
  return points;
}

/// The price at [time], between [before] and [after], on the line through them.
double _priceBetween(PricePoint before, PricePoint after, DateTime time) {
  final span = after.time.difference(before.time).inMicroseconds;
  if (span <= 0) return after.usd;
  final elapsed = time.difference(before.time).inMicroseconds;
  return before.usd + (after.usd - before.usd) * (elapsed / span);
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
