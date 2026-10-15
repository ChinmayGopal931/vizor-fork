import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../../main.dart' show log;
import '../../../core/network/network_http_client.dart';
import '../../../providers/zec_price_change_provider.dart'
    show kVizorCoinGeckoPriceBaseUrl;
import 'portfolio_price_history.dart';

/// Where the chart gets public ZEC/USD price history.
abstract interface class PortfolioPriceHistorySource {
  /// Prices for the last [days] days, ascending; `null` for any failure.
  /// Never throws.
  Future<List<PricePoint>?> fetch({required int days});
}

/// CoinGecko, on the same base URL, and through the same route-aware client, as
/// the Home price (`CoinGeckoZecMarketDataSource`): Tor when Tor is on, a
/// direct connection otherwise, and never a fallback from one to the other.
/// What a request carries is fixed by [coinGeckoMarketChartUri].
class CoinGeckoPortfolioPriceHistorySource
    implements PortfolioPriceHistorySource {
  CoinGeckoPortfolioPriceHistorySource({
    NetworkHttpClient? networkClient,
    Uri? baseUri,
    // A quarter of hourly samples is a larger body than a spot price, and a
    // fresh Tor circuit is slow.
    this.timeout = const Duration(seconds: 30),
  }) : _client = networkClient ?? NetworkHttpClient(),
       _baseUri = baseUri ?? Uri.parse(kVizorCoinGeckoPriceBaseUrl);

  final NetworkHttpClient _client;
  final Uri _baseUri;
  final Duration timeout;

  @override
  Future<List<PricePoint>?> fetch({required int days}) async {
    final endpoint = coinGeckoMarketChartUri(_baseUri, days: days);
    try {
      final response = await _client.request(
        'GET',
        endpoint,
        headers: const {HttpHeaders.acceptHeader: 'application/json'},
        timeout: timeout,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        log('portfolioChart: price history returned ${response.statusCode}');
        return null;
      }
      return parseCoinGeckoMarketChart(utf8.decode(response.bodyBytes));
    } catch (e) {
      log('portfolioChart: price history fetch failed: ${e.runtimeType}');
      return null;
    }
  }

  void close() => _client.close();
}

/// Prices as last fetched.
class PortfolioPriceHistory {
  const PortfolioPriceHistory({required this.points, required this.fetchedAt});

  final List<PricePoint> points;
  final DateTime fetchedAt;
}

/// Caches price history per span, so rebuilding the chart does not refetch it.
///
/// A fetch is shared between callers that ask while it is in flight. A cached
/// span is served until [ttl] passes. When a refresh fails the previous series
/// is served, and the span is left alone for [failureCooldown] so a flaky route
/// is not hammered. The cache lives in memory only: nothing about the wallet is
/// in it, and a restart costs one request per span viewed.
class PortfolioPriceHistoryRepository {
  PortfolioPriceHistoryRepository({
    required PortfolioPriceHistorySource source,
    DateTime Function()? now,
    this.ttl = const Duration(minutes: 30),
    this.failureCooldown = const Duration(minutes: 5),
  }) : _source = source,
       _now = now ?? DateTime.now;

  final PortfolioPriceHistorySource _source;
  final DateTime Function() _now;
  final Duration ttl;
  final Duration failureCooldown;

  final _cache = <int, PortfolioPriceHistory>{};
  final _inFlight = <int, Future<PortfolioPriceHistory?>>{};
  final _failedAt = <int, DateTime>{};

  /// The prices for the last [days] days, or `null` when there are none.
  Future<PortfolioPriceHistory?> load(int days) {
    final cached = _cache[days];
    final now = _now().toUtc();
    if (cached != null && now.difference(cached.fetchedAt) < ttl) {
      return Future.value(cached);
    }
    final failedAt = _failedAt[days];
    if (failedAt != null && now.difference(failedAt) < failureCooldown) {
      return Future.value(cached);
    }
    // The callback must not return the removed future: whenComplete waits for
    // a returned future, and this one is the future it is completing.
    return _inFlight[days] ??= _fetch(days).whenComplete(() {
      _inFlight.remove(days);
    });
  }

  Future<PortfolioPriceHistory?> _fetch(int days) async {
    List<PricePoint>? points;
    try {
      points = await _source.fetch(days: days);
    } catch (_) {
      points = null;
    }
    final now = _now().toUtc();
    if (points == null) {
      _failedAt[days] = now;
      return _cache[days];
    }
    _failedAt.remove(days);
    return _cache[days] = PortfolioPriceHistory(points: points, fetchedAt: now);
  }
}
