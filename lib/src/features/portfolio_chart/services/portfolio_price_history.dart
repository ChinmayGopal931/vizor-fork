import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// One price sample: ZEC in USD at an instant (a UTC midnight, for the pricing
/// engine's daily prices).
@immutable
class PricePoint {
  const PricePoint(this.time, this.usd);

  /// UTC.
  final DateTime time;
  final double usd;
}

const kPricingEnginePageLimit = 1000;

/// A series that needs more pages than this is refused, not truncated.
const kPricingEngineMaxPages = 4;

const kPricingEngineMaxDays = kPricingEnginePageLimit * kPricingEngineMaxPages;

/// A ZEC price above this is not a price. It bounds what a hostile answer can
/// do to the chart's arithmetic and to the amounts it formats.
const kMaxUsdPerZec = 10000000.0;

const _asset = 'ZEC';
const _fiat = 'USD';
const _resolution = '1d';

/// The pricing engine publishes a day a short while after it ends, so for the
/// first minutes of a UTC day the last completed day is still the day before
/// yesterday.
const _publishGraceMinutes = 10;

const _oneDay = Duration(days: 1);

/// The UTC calendar day [time] falls on, as midnight UTC.
DateTime utcDay(DateTime time) {
  final utc = time.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day);
}

/// Whether [time] is a UTC midnight, the instant every daily price is dated.
bool isUtcMidnight(DateTime time) => utcDay(time).isAtSameMomentAs(time);

/// `2026-10-14`: the UTC date, as the request writes it.
String utcDateText(DateTime time) {
  final utc = time.toUtc();
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-$month-$day';
}

/// The newest UTC day whose daily price is final at [now]: yesterday, or the
/// day before that in the first ten minutes of a UTC day.
DateTime lastCompletedUtcDay(DateTime now) {
  final utc = now.toUtc();
  final inGrace = utc.hour == 0 && utc.minute < _publishGraceMinutes;
  return DateTime.utc(utc.year, utc.month, utc.day - (inGrace ? 2 : 1));
}

/// A run of whole UTC days, [from] to [to] inclusive, each a UTC midnight.
@immutable
class PriceWindow {
  PriceWindow(this.from, this.to)
    : assert(!from.isAfter(to), 'a window cannot end before it starts'),
      assert(from.isUtc && to.isUtc, 'a window is in UTC');

  /// The [days] days that end on [to].
  factory PriceWindow.endingOn(DateTime to, {required int days}) {
    final last = utcDay(to);
    return PriceWindow(last.subtract(_oneDay * (days - 1)), last);
  }

  /// From [first] to [to], cut to its newest [kPricingEngineMaxDays] days when
  /// that is more than the pages can carry.
  factory PriceWindow.since(DateTime first, {required DateTime to}) {
    final last = utcDay(to);
    final earliest = last.subtract(_oneDay * (kPricingEngineMaxDays - 1));
    final start = utcDay(first);
    return PriceWindow(start.isBefore(earliest) ? earliest : start, last);
  }

  final DateTime from;
  final DateTime to;

  /// How many daily prices the window holds when none is missing.
  int get days => to.difference(from).inDays + 1;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PriceWindow && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'PriceWindow(${utcDateText(from)}..${utcDateText(to)})';
}

/// The one place a price request is built: `GET <base>/v1/prices` with exactly
/// these query keys, in this order (the order is part of the server's cache
/// key), and `portfolio_chart_history_test.dart` pins them.
///
/// Nothing about the wallet goes into it: no address, key, balance, account,
/// or date taken from the wallet's history. The dates are whole UTC days, [to]
/// the last completed one and [from] the start of a fixed window or a page's
/// cursor, so every device sends the same request on a given day. Balances and
/// prices are joined on the device.
Uri pricingEnginePricesUri(
  Uri baseUri, {
  required DateTime from,
  required DateTime to,
}) {
  final basePath = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
  return baseUri.replace(
    path: '$basePath/v1/prices',
    queryParameters: {
      'asset': _asset,
      'fiat': _fiat,
      'resolution': _resolution,
      'from': utcDateText(from),
      'to': utcDateText(to),
      'limit': '$kPricingEnginePageLimit',
    },
  );
}

/// One validated page of an answer.
@immutable
class PricingEnginePage {
  const PricingEnginePage({
    required this.points,
    required this.availableFrom,
    required this.availableTo,
    required this.dataAsOf,
    required this.complete,
    required this.nextCursor,
  });

  /// Ascending UTC midnights inside the page's requested bounds and the
  /// server's availability.
  final List<PricePoint> points;
  final DateTime availableFrom;
  final DateTime availableTo;
  final DateTime dataAsOf;

  /// Whether this page ends the series. When it does not, [nextCursor] says
  /// where the next page starts.
  final bool complete;
  final DateTime? nextCursor;

  bool hasSameAvailability(PricingEnginePage other) =>
      availableFrom == other.availableFrom &&
      availableTo == other.availableTo &&
      dataAsOf == other.dataAsOf;

  /// The date the next page must start from, or `null` when [nextCursor]
  /// cannot be followed: absent, not after this page's last point, or a start
  /// that repeats, goes back, or lies beyond [to].
  DateTime? nextRequestFrom({
    required DateTime currentFrom,
    required DateTime to,
  }) {
    final cursor = nextCursor;
    if (cursor == null || points.isEmpty) return null;
    if (!cursor.isAfter(points.last.time)) return null;
    final next = utcDay(cursor);
    if (!next.isAfter(currentFrom) || next.isAfter(to)) return null;
    return next;
  }
}

final _instantPattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$',
);

/// An ISO-8601 UTC instant, or `null`. `DateTime.parse` rolls an impossible
/// date (the 30th of February, hour 24) over into the next one, which would
/// turn a malformed day into a valid-looking different one, so the parsed value
/// has to print back as the text it came from.
DateTime? _parseInstant(Object? value) {
  if (value is! String || !_instantPattern.hasMatch(value)) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) return null;
  return parsed.toIso8601String().substring(0, 19) == value.substring(0, 19)
      ? parsed
      : null;
}

double? _number(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

/// The USD price in [point], or `null` when it is not one. The three fields
/// the engine sends must all be there and agree: the price in the requested
/// currency, the USD price, and the conversion rate, which for USD is 1.
double? _parsePointPrice(Map<dynamic, dynamic> point) {
  final price = _number(point['price']);
  final priceUsd = _number(point['priceUsd']);
  final unitsPerUsd = _number(point['unitsPerUsd']);
  if (price == null || priceUsd == null || unitsPerUsd == null) return null;
  if (price <= 0 || priceUsd <= 0 || unitsPerUsd <= 0) return null;
  if (price > kMaxUsdPerZec || priceUsd > kMaxUsdPerZec) return null;
  if (unitsPerUsd != 1) return null;
  final expected = priceUsd * unitsPerUsd;
  final tolerance = math.max(expected.abs(), 1.0) * 1e-12;
  return (price - expected).abs() <= tolerance ? price : null;
}

/// Parses and validates one page of the answer to a request for [from]..[to].
/// The answer is untrusted, and a wrong chart is worse than none, so anything
/// but the documented answer to this request is `null`. Fields it does not
/// know are ignored.
PricingEnginePage? parsePricingEnginePage(
  String body, {
  required DateTime from,
  required DateTime to,
}) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    if (decoded['asset'] != _asset ||
        decoded['fiat'] != _fiat ||
        decoded['resolution'] != _resolution) {
      return null;
    }
    if (_parseInstant(decoded['from']) != from ||
        _parseInstant(decoded['to']) != to) {
      return null;
    }

    final availableFrom = _parseInstant(decoded['availableFrom']);
    final availableTo = _parseInstant(decoded['availableTo']);
    final dataAsOf = _parseInstant(decoded['dataAsOf']);
    if (availableFrom == null || availableTo == null || dataAsOf == null) {
      return null;
    }
    if (!isUtcMidnight(availableFrom) || !isUtcMidnight(availableTo)) {
      return null;
    }
    if (availableFrom.isAfter(availableTo) || dataAsOf != availableTo) {
      return null;
    }

    final complete = decoded['complete'];
    if (complete is! bool) return null;
    final rawCursor = decoded['nextCursor'];
    final nextCursor = rawCursor == null ? null : _parseInstant(rawCursor);
    if (rawCursor != null && nextCursor == null) return null;
    if (complete && nextCursor != null) return null;

    final rawPoints = decoded['points'];
    if (rawPoints is! List) return null;
    final points = <PricePoint>[];
    for (final raw in rawPoints) {
      if (raw is! Map) return null;
      final time = _parseInstant(raw['timestamp']);
      final usd = _parsePointPrice(raw);
      if (time == null || usd == null || !isUtcMidnight(time)) return null;
      if (time.isBefore(from) || time.isAfter(to)) return null;
      if (time.isBefore(availableFrom) || time.isAfter(availableTo)) {
        return null;
      }
      if (points.isNotEmpty && !time.isAfter(points.last.time)) return null;
      points.add(PricePoint(time, usd));
    }
    return PricingEnginePage(
      points: points,
      availableFrom: availableFrom,
      availableTo: availableTo,
      dataAsOf: dataAsOf,
      complete: complete,
      nextCursor: nextCursor,
    );
  } catch (_) {
    return null;
  }
}

/// A finished series: daily prices for [window] without a gap.
@immutable
class PriceSeries {
  const PriceSeries({
    required this.window,
    required this.points,
    required this.availableFrom,
    required this.availableTo,
  });

  final PriceWindow window;

  /// At least two, one per UTC day, ascending.
  final List<PricePoint> points;

  /// The server's own first and last day.
  final DateTime availableFrom;
  final DateTime availableTo;

  DateTime get lastDay => points.last.time;

  /// Whether the server had every day up to the window's end. When it had not,
  /// the series is complete up to [availableTo] and is asked for again later.
  bool get reachesWindowEnd => !availableTo.isBefore(window.to);
}

/// Joins validated [pages] of one answer into the series for [window], or
/// `null` unless they join without a repeated or missing day and cover every
/// day the server has inside the window. A price repeated at the seam between
/// two pages is accepted once, when both copies agree.
PriceSeries? assemblePriceSeries(
  PriceWindow window,
  List<PricingEnginePage> pages,
) {
  if (pages.isEmpty) return null;
  final first = pages.first;
  final points = <PricePoint>[];
  for (final page in pages) {
    if (!page.hasSameAvailability(first)) return null;
    for (final point in page.points) {
      if (points.isNotEmpty && point.time == points.last.time) {
        if (point.usd != points.last.usd) return null;
        continue;
      }
      points.add(point);
    }
  }
  if (points.length < 2) return null;
  for (var i = 1; i < points.length; i++) {
    if (points[i].time.difference(points[i - 1].time) != _oneDay) return null;
  }
  final expectedFirst = window.from.isAfter(first.availableFrom)
      ? window.from
      : first.availableFrom;
  final expectedLast = window.to.isBefore(first.availableTo)
      ? window.to
      : first.availableTo;
  if (points.first.time != expectedFirst || points.last.time != expectedLast) {
    return null;
  }
  return PriceSeries(
    window: window,
    points: List.unmodifiable(points),
    availableFrom: first.availableFrom,
    availableTo: first.availableTo,
  );
}
