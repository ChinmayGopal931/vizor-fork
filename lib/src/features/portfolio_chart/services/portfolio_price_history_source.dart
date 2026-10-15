import 'dart:convert';
import 'dart:io';

import '../../../../main.dart' show log;
import '../../../core/network/network_http_client.dart';
import '../models/portfolio_chart_models.dart';
import 'portfolio_price_history.dart';

/// Where the chart gets public ZEC/USD price history.
abstract interface class PortfolioPriceHistorySource {
  /// The daily prices for [window], or `null` for any failure. Never throws.
  Future<PriceSeries?> fetch(PriceWindow window);
}

/// A source for a build with no usable pricing server: it has no prices and
/// asks nobody.
class UnavailablePortfolioPriceHistorySource
    implements PortfolioPriceHistorySource {
  const UnavailablePortfolioPriceHistorySource();

  @override
  Future<PriceSeries?> fetch(PriceWindow window) async => null;
}

/// The pricing engine, through the same route-aware client as the Home price:
/// Tor when Tor is on, a direct connection otherwise, and never a fallback from
/// one to the other. Only `https` is spoken. What a request carries is fixed by
/// [pricingEnginePricesUri].
///
/// The answer is untrusted. A page is rejected unless it is a 2xx of at most
/// [maxPageBytes] that [parsePricingEnginePage] accepts; a series that does not
/// end on the first page follows the server's cursor for at most
/// [kPricingEngineMaxPages] pages, and one that would need more is refused
/// rather than drawn short. [NetworkHttpClient] buffers a body before handing
/// it over, so the size cap refuses an oversized answer; it does not stop its
/// download.
class PricingEnginePortfolioPriceHistorySource
    implements PortfolioPriceHistorySource {
  PricingEnginePortfolioPriceHistorySource({
    required Uri baseUri,
    NetworkHttpClient? networkClient,
    // A fresh Tor circuit is slow, and a page is small.
    this.timeout = const Duration(seconds: 30),
    // Paging is sequential: the whole series gets this long, in total.
    this.deadline = const Duration(seconds: 90),
    // A full page of 1000 days is about 140 KB.
    this.maxPageBytes = 512 * 1024,
  }) : _client = networkClient ?? NetworkHttpClient(),
       _baseUri = baseUri;

  final NetworkHttpClient _client;
  final Uri _baseUri;
  final Duration timeout;
  final Duration deadline;
  final int maxPageBytes;

  @override
  Future<PriceSeries?> fetch(PriceWindow window) async {
    if (_baseUri.scheme != 'https') return null;
    try {
      return await _fetchPages(window);
    } catch (e) {
      // The type only: a message can carry the URL.
      log('portfolioChart: price history fetch failed: ${e.runtimeType}');
      return null;
    }
  }

  Future<PriceSeries?> _fetchPages(PriceWindow window) async {
    final clock = Stopwatch()..start();
    final pages = <PricingEnginePage>[];
    var from = window.from;
    for (var index = 0; index < kPricingEngineMaxPages; index++) {
      final remaining = deadline - clock.elapsed;
      if (remaining <= Duration.zero) {
        log('portfolioChart: price history ran out of time');
        return null;
      }
      final response = await _client.request(
        'GET',
        pricingEnginePricesUri(_baseUri, from: from, to: window.to),
        headers: const {HttpHeaders.acceptHeader: 'application/json'},
        timeout: remaining < timeout ? remaining : timeout,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        log('portfolioChart: price history returned ${response.statusCode}');
        return null;
      }
      if (response.bodyBytes.length > maxPageBytes) {
        log('portfolioChart: price history answer is too large');
        return null;
      }
      final page = parsePricingEnginePage(
        utf8.decode(response.bodyBytes),
        from: from,
        to: window.to,
      );
      if (page == null ||
          (pages.isNotEmpty && !page.hasSameAvailability(pages.first))) {
        log('portfolioChart: price history answer rejected');
        return null;
      }
      pages.add(page);
      if (page.complete) return assemblePriceSeries(window, pages);
      final next = page.nextRequestFrom(currentFrom: from, to: window.to);
      if (next == null) {
        log('portfolioChart: price history cursor rejected');
        return null;
      }
      from = next;
    }
    log('portfolioChart: price history needs too many pages');
    return null;
  }

  void close() => _client.close();
}

/// Prices as last fetched.
class PortfolioPriceHistory {
  const PortfolioPriceHistory({required this.series, required this.fetchedAt});

  final PriceSeries series;
  final DateTime fetchedAt;

  List<PricePoint> get points => series.points;

  /// Whether the newest price is more than [staleAfter] older than the last
  /// completed UTC day at [now]. A price a day behind is normal for the minutes
  /// before a new day is asked for.
  bool isStaleAt(DateTime now) =>
      lastCompletedUtcDay(now).difference(series.lastDay) > staleAfter;

  static const staleAfter = Duration(days: 1);
}

/// Caches price history per range, so rebuilding the chart does not refetch it.
///
/// A range's series is for one window of whole UTC days, which moves at UTC
/// midnight; a cached series is served for as long as it is for today's window
/// and the server had every day of it. A window the server had not caught up
/// with is asked again after [recheckAfter]. A fetch is shared between callers
/// that ask while it is in flight. When a refresh fails the previous series is
/// served, and the range is left alone for [failureCooldown] so a flaky route
/// is not hammered. The cache lives in memory only: nothing about the wallet is
/// in it, and a restart costs one request per range viewed.
///
/// [PortfolioChartRange.all] begins where the server's own history does, which
/// only an answer can say. Until one has, the shortest range is asked for
/// first: the request every device sends anyway, so nothing extra leaves the
/// device but the second, equally fixed, request.
class PortfolioPriceHistoryRepository {
  PortfolioPriceHistoryRepository({
    required PortfolioPriceHistorySource source,
    DateTime Function()? now,
    this.recheckAfter = const Duration(minutes: 30),
    this.failureCooldown = const Duration(minutes: 5),
  }) : _source = source,
       _now = now ?? DateTime.now;

  final PortfolioPriceHistorySource _source;
  final DateTime Function() _now;
  final Duration recheckAfter;
  final Duration failureCooldown;

  final _cache = <PortfolioChartRange, PortfolioPriceHistory>{};
  final _inFlight = <PortfolioChartRange, Future<PortfolioPriceHistory?>>{};
  final _failedAt = <PortfolioChartRange, DateTime>{};

  /// The first day the server has prices for, as its latest answer said.
  DateTime? _availableFrom;

  /// What is cached for [range], however old. Asks nobody.
  PortfolioPriceHistory? cached(PortfolioChartRange range) => _cache[range];

  /// The prices for [range], or `null` when there are none.
  Future<PortfolioPriceHistory?> load(PortfolioChartRange range) {
    final now = _now().toUtc();
    final cached = _cache[range];
    final window = _windowFor(range, now);
    if (cached != null && window != null && _isCurrent(cached, window, now)) {
      return Future.value(cached);
    }
    final failedAt = _failedAt[range];
    if (failedAt != null && now.difference(failedAt) < failureCooldown) {
      return Future.value(cached);
    }
    // The callback must not return the removed future: whenComplete waits for
    // a returned future, and this one is the future it is completing.
    return _inFlight[range] ??= _fetch(range, now).whenComplete(() {
      _inFlight.remove(range);
    });
  }

  bool _isCurrent(
    PortfolioPriceHistory history,
    PriceWindow window,
    DateTime now,
  ) {
    return history.series.window == window &&
        (history.series.reachesWindowEnd ||
            now.difference(history.fetchedAt) < recheckAfter);
  }

  /// The window of [range] at [now], or `null` for [PortfolioChartRange.all]
  /// before the server has said where its history begins.
  PriceWindow? _windowFor(PortfolioChartRange range, DateTime now) {
    final to = lastCompletedUtcDay(now);
    final days = range.days;
    if (days != null) return PriceWindow.endingOn(to, days: days);
    final first = _availableFrom;
    if (first == null || first.isAfter(to)) return null;
    return PriceWindow.since(first, to: to);
  }

  Future<PortfolioPriceHistory?> _fetch(
    PortfolioChartRange range,
    DateTime now,
  ) async {
    var window = _windowFor(range, now);
    if (window == null) {
      await load(PortfolioChartRange.week);
      window = _windowFor(range, _now().toUtc());
    }
    PriceSeries? series;
    if (window != null) {
      try {
        series = await _source.fetch(window);
      } catch (_) {
        series = null;
      }
    }
    final finished = _now().toUtc();
    if (series == null) {
      _failedAt[range] = finished;
      return _cache[range];
    }
    _availableFrom = series.availableFrom;
    _failedAt.remove(range);
    return _cache[range] = PortfolioPriceHistory(
      series: series,
      fetchedAt: finished,
    );
  }
}
