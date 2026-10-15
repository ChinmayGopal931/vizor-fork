/// Public ZEC/USD price history for the Home portfolio chart.
///
/// Privacy contract. A request names the coin, the currency and a number of
/// days, and nothing else: no address, viewing key, seed, balance, account or
/// wallet identifier, and no date derived from the wallet (the span is one of
/// the fixed `PortfolioChartRange` choices counted back from today). The
/// balance side of the chart is read from the local wallet database and joined
/// to these prices on the device. [coinGeckoMarketChartUri] is the only place
/// the request is built, and `portfolio_chart_history_test.dart` pins its
/// shape, so adding a parameter fails a test.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One price sample.
@immutable
class PricePoint {
  const PricePoint(this.time, this.usd);

  /// UTC.
  final DateTime time;
  final double usd;
}

const _coinGeckoCoinId = 'zcash';

/// CoinGecko's `/coins/zcash/market_chart` for the last [days] days in USD.
///
/// CoinGecko picks the granularity from the span: hourly up to 90 days, daily
/// beyond. The public API answers nothing older than 365 days.
Uri coinGeckoMarketChartUri(Uri baseUri, {required int days}) {
  final basePath = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
  return baseUri.replace(
    path: '$basePath/coins/$_coinGeckoCoinId/market_chart',
    queryParameters: {'vs_currency': 'usd', 'days': '$days'},
  );
}

/// Parses a `market_chart` body into ascending, de-duplicated price points.
///
/// Entries that are not a finite, positive price at a valid time are dropped,
/// and of two prices at one time the first is kept.
/// Returns `null` when the body is not a price series or fewer than two usable
/// points remain, because one point draws nothing.
List<PricePoint>? parseCoinGeckoMarketChart(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final prices = decoded['prices'];
    if (prices is! List) return null;
    // Keyed by time so a repeated timestamp keeps its first price, whatever
    // the sort does with equal keys.
    final byTime = <int, PricePoint>{};
    for (final entry in prices) {
      if (entry is! List || entry.length < 2) continue;
      final milliseconds = entry[0];
      final price = entry[1];
      if (milliseconds is! num || price is! num) continue;
      if (!milliseconds.isFinite || !price.isFinite || price <= 0) continue;
      final time = milliseconds.toInt();
      byTime.putIfAbsent(
        time,
        () => PricePoint(
          DateTime.fromMillisecondsSinceEpoch(time, isUtc: true),
          price.toDouble(),
        ),
      );
    }
    final points = byTime.values.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return points.length < 2 ? null : points;
  } catch (_) {
    return null;
  }
}
