import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_price_history.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/services/portfolio_price_history_source.dart';

/// What the live pricing engine answered for
/// `asset=ZEC&fiat=USD&resolution=1d&from=2026-10-08&to=2026-10-14&limit=1000`.
const _liveAnswer =
    '{"asset":"ZEC","fiat":"USD","resolution":"1d",'
    '"from":"2026-10-08T00:00:00.000Z","to":"2026-10-14T00:00:00.000Z",'
    '"points":['
    '{"timestamp":"2026-10-08T00:00:00.000Z","price":1187.3722847088538,"priceUsd":1187.3722847088538,"unitsPerUsd":1},'
    '{"timestamp":"2026-10-09T00:00:00.000Z","price":1210.5090436348803,"priceUsd":1210.5090436348803,"unitsPerUsd":1},'
    '{"timestamp":"2026-10-10T00:00:00.000Z","price":1220.8627271783662,"priceUsd":1220.8627271783662,"unitsPerUsd":1},'
    '{"timestamp":"2026-10-11T00:00:00.000Z","price":1276.2214642417505,"priceUsd":1276.2214642417505,"unitsPerUsd":1},'
    '{"timestamp":"2026-10-12T00:00:00.000Z","price":1167.3085659317844,"priceUsd":1167.3085659317844,"unitsPerUsd":1},'
    '{"timestamp":"2026-10-13T00:00:00.000Z","price":1219.0003388543596,"priceUsd":1219.0003388543596,"unitsPerUsd":1},'
    '{"timestamp":"2026-10-14T00:00:00.000Z","price":1145.9528645630178,"priceUsd":1145.9528645630178,"unitsPerUsd":1}],'
    '"availableFrom":"2025-01-01T00:00:00.000Z",'
    '"availableTo":"2026-10-14T00:00:00.000Z",'
    '"dataAsOf":"2026-10-14T00:00:00.000Z","complete":true}';

final _from = DateTime.utc(2026, 10, 8);
final _to = DateTime.utc(2026, 10, 14);

PricingEnginePage? _parse(String body) =>
    parsePricingEnginePage(body, from: _from, to: _to);

/// The live answer with [change] applied to its decoded document.
String _live(void Function(Map<String, dynamic> body) change) {
  final body = jsonDecode(_liveAnswer) as Map<String, dynamic>;
  change(body);
  return jsonEncode(body);
}

List<Map<String, dynamic>> _pointsOf(Map<String, dynamic> body) =>
    (body['points'] as List).cast<Map<String, dynamic>>();

void main() {
  group('parsePricingEnginePage', () {
    test('reads the live answer', () {
      final page = _parse(_liveAnswer)!;

      expect(page.complete, isTrue);
      expect(page.nextCursor, isNull);
      expect(page.availableFrom, DateTime.utc(2025, 1, 1));
      expect(page.availableTo, _to);
      expect(page.dataAsOf, _to);
      expect(page.points.length, 7);
      expect(page.points.first.time, _from);
      expect(page.points.first.usd, 1187.3722847088538);
      expect(page.points.last.time, _to);
      expect(page.points.last.usd, 1145.9528645630178);
      expect(page.points.every((point) => point.time.isUtc), isTrue);
    });

    test('ignores fields it does not know and accepts whole-number prices', () {
      final page = _parse(
        _live((body) {
          body['somethingNew'] = {'a': 1};
          body['nextCursor'] = null;
          for (final point in _pointsOf(body)) {
            point['source'] = 'whatever';
            point['price'] = 1200;
            point['priceUsd'] = 1200;
          }
          _pointsOf(body).first['timestamp'] = '2026-10-08T00:00:00.000000000Z';
        }),
      );

      expect(page, isNotNull);
      expect(page!.points.first.usd, 1200);
      expect(page.points.first.time, _from);
    });

    test('rejects everything it cannot trust', () {
      final rejected = <String, String>{
        'another asset': _live((b) => b['asset'] = 'BTC'),
        'another currency': _live((b) => b['fiat'] = 'EUR'),
        'another resolution': _live((b) => b['resolution'] = '1h'),
        'a start that is not the request': _live(
          (b) => b['from'] = '2026-10-07T00:00:00.000Z',
        ),
        'an end that is not the request': _live(
          (b) => b['to'] = '2026-10-15T00:00:00.000Z',
        ),
        'bounds that are not an instant': _live(
          (b) => b['from'] = '2026-10-08',
        ),
        'availability that is not whole days': _live(
          (b) => b['availableFrom'] = '2025-01-01T06:00:00.000Z',
        ),
        'availability that runs backwards': _live(
          (b) => b['availableFrom'] = '2026-10-15T00:00:00.000Z',
        ),
        'data as of another day than the last available': _live(
          (b) => b['dataAsOf'] = '2026-10-13T00:00:00.000Z',
        ),
        'no complete flag': _live((b) => b.remove('complete')),
        'a complete flag that is not a boolean': _live(
          (b) => b['complete'] = 'true',
        ),
        'a complete answer with a cursor': _live(
          (b) => b['nextCursor'] = '2026-10-15T00:00:00.000Z',
        ),
        'a cursor that is not an instant': _live((b) {
          b['complete'] = false;
          b['nextCursor'] = 'later';
        }),
        'points that are not a list': _live((b) => b['points'] = {}),
        'a point that is not an object': _live(
          (b) => (b['points'] as List)[0] = 5,
        ),
        'a point with nothing in it': _live(
          (b) => (b['points'] as List)[0] = <String, dynamic>{},
        ),
        'a point with no timestamp': _live(
          (b) => _pointsOf(b).first.remove('timestamp'),
        ),
        'a timestamp that is not an instant': _live(
          (b) => _pointsOf(b).first['timestamp'] = 'yesterday',
        ),
        'a timestamp that is not a midnight': _live(
          (b) => _pointsOf(b).first['timestamp'] = '2026-10-08T06:00:00.000Z',
        ),
        'a timestamp before the request': _live(
          (b) => _pointsOf(b).first['timestamp'] = '2026-10-07T00:00:00.000Z',
        ),
        'a timestamp after the request': _live(
          (b) => _pointsOf(b).last['timestamp'] = '2026-10-15T00:00:00.000Z',
        ),
        'a timestamp before the data begins': _live(
          (b) => b['availableFrom'] = '2026-10-09T00:00:00.000Z',
        ),
        'a timestamp after the data ends': _live((b) {
          b['availableTo'] = '2026-10-13T00:00:00.000Z';
          b['dataAsOf'] = '2026-10-13T00:00:00.000Z';
        }),
        'a repeated timestamp': _live(
          (b) => _pointsOf(b)[1]['timestamp'] = '2026-10-08T00:00:00.000Z',
        ),
        'timestamps out of order': _live((b) {
          _pointsOf(b)[1]['timestamp'] = '2026-10-10T00:00:00.000Z';
          _pointsOf(b)[2]['timestamp'] = '2026-10-09T00:00:00.000Z';
        }),
        'a price of zero': _live((b) {
          _pointsOf(b).first['price'] = 0;
          _pointsOf(b).first['priceUsd'] = 0;
        }),
        'a negative price': _live((b) {
          _pointsOf(b).first['price'] = -5;
          _pointsOf(b).first['priceUsd'] = -5;
        }),
        'a price that is text': _live(
          (b) => _pointsOf(b).first['price'] = '1187.37',
        ),
        'a missing price': _live((b) => _pointsOf(b).first.remove('price')),
        'a price no ZEC could have': _live((b) {
          _pointsOf(b).first['price'] = 1e12;
          _pointsOf(b).first['priceUsd'] = 1e12;
        }),
        'a USD price that disagrees with the price': _live(
          (b) => _pointsOf(b).first['priceUsd'] = 1200.5,
        ),
        'a conversion rate that is not 1 for USD': _live((b) {
          _pointsOf(b).first['unitsPerUsd'] = 2;
          _pointsOf(b).first['price'] = 2 * 1187.3722847088538;
        }),
        'a missing conversion rate': _live(
          (b) => _pointsOf(b).first.remove('unitsPerUsd'),
        ),
        'an infinite price': _liveAnswer.replaceFirst(
          '"price":1187.3722847088538',
          '"price":1e999',
        ),
        'not JSON': 'not json',
        'a JSON list': '[]',
        'nothing': 'null',
        'an empty body': '',
      };

      for (final entry in rejected.entries) {
        expect(_parse(entry.value), isNull, reason: entry.key);
      }
    });

    test('does not let an impossible date roll over into a valid one', () {
      // `DateTime.parse` reads the 30th of February as the 2nd of March, which
      // is the start this request asks for.
      final body = jsonEncode({
        'asset': 'ZEC',
        'fiat': 'USD',
        'resolution': '1d',
        'from': '2026-02-30T00:00:00.000Z',
        'to': '2026-03-08T00:00:00.000Z',
        'points': const [],
        'availableFrom': '2025-01-01T00:00:00.000Z',
        'availableTo': '2026-03-08T00:00:00.000Z',
        'dataAsOf': '2026-03-08T00:00:00.000Z',
        'complete': true,
      });

      expect(
        parsePricingEnginePage(
          body,
          from: DateTime.utc(2026, 3, 2),
          to: DateTime.utc(2026, 3, 8),
        ),
        isNull,
      );
      expect(
        parsePricingEnginePage(
          body.replaceFirst('2026-02-30', '2026-03-02'),
          from: DateTime.utc(2026, 3, 2),
          to: DateTime.utc(2026, 3, 8),
        ),
        isNotNull,
      );
    });

    test('says where an unfinished answer continues, and only if it can', () {
      PricingEnginePage page({String? cursor, int points = 3}) => _parse(
        _live((b) {
          b['complete'] = false;
          if (cursor != null) b['nextCursor'] = cursor;
          (b['points'] as List).removeRange(points, 7);
        }),
      )!;
      final from = _from;
      final to = _to;

      // The last point is the 10th; the cursor starts the 11th.
      expect(
        page(
          cursor: '2026-10-11T00:00:00.000Z',
        ).nextRequestFrom(currentFrom: from, to: to),
        DateTime.utc(2026, 10, 11),
      );
      // Only the day counts, in UTC.
      expect(
        page(
          cursor: '2026-10-11T23:59:59.000Z',
        ).nextRequestFrom(currentFrom: from, to: to),
        DateTime.utc(2026, 10, 11),
      );
      // No cursor, none after the last point, one that stands still, one beyond
      // the request.
      expect(page().nextRequestFrom(currentFrom: from, to: to), isNull);
      expect(
        page(
          cursor: '2026-10-10T00:00:00.000Z',
        ).nextRequestFrom(currentFrom: from, to: to),
        isNull,
      );
      expect(
        page(
          cursor: '2026-10-11T00:00:00.000Z',
        ).nextRequestFrom(currentFrom: DateTime.utc(2026, 10, 11), to: to),
        isNull,
      );
      expect(
        page(
          cursor: '2026-10-15T00:00:00.000Z',
        ).nextRequestFrom(currentFrom: from, to: to),
        isNull,
      );
    });
  });

  group('assemblePriceSeries', () {
    PricingEnginePage page(
      List<int> days, {
      DateTime? availableFrom,
      DateTime? availableTo,
      double Function(int day)? price,
    }) {
      final end = availableTo ?? DateTime.utc(2026, 10, 14);
      return PricingEnginePage(
        points: [
          for (final day in days)
            PricePoint(DateTime.utc(2026, 10, day), price?.call(day) ?? 100),
        ],
        availableFrom: availableFrom ?? DateTime.utc(2025, 1, 1),
        availableTo: end,
        dataAsOf: end,
        complete: true,
        nextCursor: null,
      );
    }

    final window = PriceWindow(_from, _to);

    test('joins pages that meet without a repeated or missing day', () {
      final series = assemblePriceSeries(window, [
        page([8, 9, 10]),
        page([11, 12, 13, 14]),
      ])!;

      expect(series.points.length, 7);
      expect(series.window, window);
      expect(series.lastDay, _to);
      expect(series.reachesWindowEnd, isTrue);
    });

    test('accepts a price repeated at the seam once, when both agree', () {
      expect(
        assemblePriceSeries(window, [
          page([8, 9, 10, 11]),
          page([11, 12, 13, 14]),
        ])!.points.length,
        7,
      );
      expect(
        assemblePriceSeries(window, [
          page([8, 9, 10, 11]),
          page([11, 12, 13, 14], price: (day) => day == 11 ? 101 : 100),
        ]),
        isNull,
      );
    });

    test('refuses a series with a gap, a repeat or too few prices', () {
      expect(
        assemblePriceSeries(window, [
          page([8, 9, 10]),
          page([12, 13, 14]),
        ]),
        isNull,
        reason: 'a missing day',
      );
      expect(
        assemblePriceSeries(window, [
          page([8, 9, 10, 11]),
          page([10, 11, 12, 13, 14]),
        ]),
        isNull,
        reason: 'days repeated',
      );
      expect(
        assemblePriceSeries(window, [
          page([8, 9, 11, 12, 13, 14]),
        ]),
        isNull,
        reason: 'a gap inside one page',
      );
      expect(
        assemblePriceSeries(window, [
          page([14]),
        ]),
        isNull,
      );
      expect(assemblePriceSeries(window, const []), isNull);
    });

    test('refuses pages that describe different availability', () {
      expect(
        assemblePriceSeries(window, [
          page([8, 9, 10]),
          page([11, 12, 13, 14], availableFrom: DateTime.utc(2025, 2, 1)),
        ]),
        isNull,
      );
    });

    test('covers every day the server has inside the window', () {
      // The first or last day missing, though the server says it has them.
      expect(
        assemblePriceSeries(window, [
          page([9, 10, 11, 12, 13, 14]),
        ]),
        isNull,
      );
      expect(
        assemblePriceSeries(window, [
          page([8, 9, 10, 11, 12, 13]),
        ]),
        isNull,
      );
      // A server that begins later or ends sooner is covered up to what it has.
      final young = assemblePriceSeries(window, [
        page([10, 11, 12, 13, 14], availableFrom: DateTime.utc(2026, 10, 10)),
      ])!;
      expect(young.points.first.time, DateTime.utc(2026, 10, 10));
      final lagging = assemblePriceSeries(window, [
        page([8, 9, 10, 11, 12, 13], availableTo: DateTime.utc(2026, 10, 13)),
      ])!;
      expect(lagging.lastDay, DateTime.utc(2026, 10, 13));
      expect(lagging.reachesWindowEnd, isFalse);
    });
  });

  group('PricingEnginePortfolioPriceHistorySource', () {
    final window = PriceWindow.endingOn(_to, days: 7);

    PricingEnginePortfolioPriceHistorySource sourceFor(
      _FakePricingServer server, {
      Uri? baseUri,
      int? maxPageBytes,
      Duration? deadline,
    }) {
      final client = NetworkHttpClient(
        torDesired: () => true,
        torBootstrapping: () => false,
        torBridge: server,
      );
      addTearDown(() => client.close());
      return PricingEnginePortfolioPriceHistorySource(
        baseUri: baseUri ?? Uri.parse('https://pricing.example'),
        networkClient: client,
        maxPageBytes: maxPageBytes ?? 512 * 1024,
        deadline: deadline ?? const Duration(seconds: 90),
      );
    }

    test('asks once, with the fixed query and nothing else', () async {
      final server = _FakePricingServer();

      final series = await sourceFor(server).fetch(window);

      expect(server.requests.map((uri) => uri.toString()), [
        'https://pricing.example/v1/prices'
            '?asset=ZEC&fiat=USD&resolution=1d&from=2026-10-08&to=2026-10-14'
            '&limit=1000',
      ]);
      expect(server.headers.single, {'accept': 'application/json'});
      expect(
        server.timeouts.single!.inMilliseconds,
        inInclusiveRange(29000, 30000),
      );
      expect(series!.points.length, 7);
      expect(series.points.first.time, _from);
      expect(series.points.first.usd, _FakePricingServer.priceOn(_from));
      expect(series.window, window);
    });

    test('keeps a path prefix and drops a trailing slash', () async {
      final server = _FakePricingServer();

      await sourceFor(
        server,
        baseUri: Uri.parse('https://pricing.example/engine/'),
      ).fetch(window);

      expect(server.requests.single.path, '/engine/v1/prices');
    });

    test('follows the cursor, page by page, to one series', () async {
      // A year, a hundred days to a page.
      final year = PriceWindow.endingOn(_to, days: 365);
      final server = _FakePricingServer(pageSize: 100);

      final series = await sourceFor(server).fetch(year);

      expect(series!.points.length, 365);
      expect(series.points.first.time, year.from);
      expect(series.points.last.time, _to);
      expect(
        [
          for (final uri in server.requests)
            (
              uri.queryParameters['from'],
              uri.queryParameters['to'],
              uri.queryParameters['limit'],
            ),
        ],
        [
          ('2025-10-15', '2026-10-14', '1000'),
          ('2026-01-23', '2026-10-14', '1000'),
          ('2026-05-03', '2026-10-14', '1000'),
          ('2026-08-11', '2026-10-14', '1000'),
        ],
      );
      // Each day carries its own price: nothing was repeated or shifted.
      expect(series.points.map((point) => point.usd), [
        for (final point in series.points)
          _FakePricingServer.priceOn(point.time),
      ]);
    });

    test('refuses a series that needs more than four pages', () async {
      final year = PriceWindow.endingOn(_to, days: 365);
      final server = _FakePricingServer(pageSize: 90);

      expect(await sourceFor(server).fetch(year), isNull);
      expect(server.requests.length, kPricingEngineMaxPages);
    });

    test('refuses an answer that cannot be trusted', () async {
      final cases = <String, _FakePricingServer>{
        'a cursor that stands still': _FakePricingServer(
          pageSize: 3,
          tamper: (number, body) {
            if (number == 2) {
              body['nextCursor'] = (body['points'] as List).last['timestamp'];
            }
          },
        ),
        'a cursor that goes back': _FakePricingServer(
          pageSize: 3,
          tamper: (number, body) {
            if (number == 2) body['nextCursor'] = '2026-10-08T00:00:00.000Z';
          },
        ),
        'an unfinished page with no cursor': _FakePricingServer(
          pageSize: 3,
          tamper: (number, body) {
            if (number == 2) body.remove('nextCursor');
          },
        ),
        'availability that changes between pages': _FakePricingServer(
          pageSize: 3,
          tamper: (number, body) {
            if (number == 2) {
              body['availableFrom'] = '2025-02-01T00:00:00.000Z';
            }
          },
        ),
        'a day missing between pages': _FakePricingServer(
          pageSize: 3,
          tamper: (number, body) {
            if (number == 1) {
              body['nextCursor'] = '2026-10-12T00:00:00.000Z';
            }
          },
        ),
        'a page for another request': _FakePricingServer(
          tamper: (number, body) => body['to'] = '2026-10-13T00:00:00.000Z',
        ),
      };

      for (final entry in cases.entries) {
        expect(
          await sourceFor(entry.value).fetch(window),
          isNull,
          reason: entry.key,
        );
      }
    });

    test('is no prices for a failure of any kind', () async {
      final failures = <String, _FakePricingServer>{
        'a server error': _FakePricingServer(statusCode: 500),
        'a rate limit': _FakePricingServer(statusCode: 429),
        'a missing route': _FakePricingServer(statusCode: 404),
        'a transport error': _FakePricingServer(fails: true),
        'an answer that is not JSON': _FakePricingServer(
          rawBody: '<html>captive portal</html>',
        ),
        'an answer that is not UTF-8': _FakePricingServer(
          rawBytes: Uint8List.fromList([0xff, 0xfe, 0x7b, 0x7d]),
        ),
      };

      for (final entry in failures.entries) {
        expect(
          await sourceFor(entry.value).fetch(window),
          isNull,
          reason: entry.key,
        );
        expect(entry.value.requests.length, 1, reason: entry.key);
      }
    });

    test('refuses an answer over the size cap', () async {
      final server = _FakePricingServer();
      final honest = utf8.encode(server.answerFor(window)).length;

      expect(
        await sourceFor(server, maxPageBytes: honest - 1).fetch(window),
        isNull,
      );
      expect(
        await sourceFor(
          _FakePricingServer(),
          maxPageBytes: honest,
        ).fetch(window),
        isNotNull,
      );
    });

    test('speaks only https, and only within its time', () async {
      final plain = _FakePricingServer();
      expect(
        await sourceFor(
          plain,
          baseUri: Uri.parse('http://pricing.example'),
        ).fetch(window),
        isNull,
      );
      expect(plain.requests, isEmpty);

      final late = _FakePricingServer();
      expect(
        await sourceFor(late, deadline: Duration.zero).fetch(window),
        isNull,
      );
      expect(late.requests, isEmpty);
    });
  });
}

/// A pricing engine standing in for the live one: the same document, paged by
/// [pageSize] with a cursor, and optionally dishonest.
class _FakePricingServer implements TorHttpBridge {
  _FakePricingServer({
    this.pageSize = 1000,
    this.statusCode = 200,
    this.fails = false,
    this.rawBody,
    this.rawBytes,
    this.tamper,
  });

  static final _availableFrom = DateTime.utc(2025, 1, 1);
  static final _availableTo = DateTime.utc(2026, 10, 14);

  /// A price that differs on every day, so a day mixed up with another shows.
  static double priceOn(DateTime day) =>
      100 + day.difference(_availableFrom).inDays / 4;

  final int pageSize;
  final int statusCode;
  final bool fails;
  final String? rawBody;
  final Uint8List? rawBytes;

  /// Changes the document for request [number] (1-based) before it is sent.
  final void Function(int number, Map<String, dynamic> body)? tamper;

  final requests = <Uri>[];
  final headers = <Map<String, String>>[];
  final timeouts = <Duration?>[];

  @override
  Future<NetworkHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) async {
    requests.add(uri);
    this.headers.add(Map.of(headers));
    timeouts.add(timeout);
    if (fails) throw StateError('Tor is not ready');
    final bytes = rawBytes;
    if (bytes != null) {
      return NetworkHttpResponse(statusCode: statusCode, bodyBytes: bytes);
    }
    final answer = answerFor(
      PriceWindow(
        DateTime.parse('${uri.queryParameters['from']}T00:00:00.000Z'),
        DateTime.parse('${uri.queryParameters['to']}T00:00:00.000Z'),
      ),
    );
    if (rawBody != null) {
      return NetworkHttpResponse(
        statusCode: statusCode,
        bodyBytes: utf8.encode(rawBody!),
      );
    }
    final body = jsonDecode(answer) as Map<String, dynamic>;
    tamper?.call(requests.length, body);
    return NetworkHttpResponse(
      statusCode: statusCode,
      bodyBytes: utf8.encode(jsonEncode(body)),
    );
  }

  /// The honest answer to a request for [window].
  String answerFor(PriceWindow window) {
    final first = window.from.isAfter(_availableFrom)
        ? window.from
        : _availableFrom;
    final last = window.to.isBefore(_availableTo) ? window.to : _availableTo;
    final days = <DateTime>[];
    for (
      var day = first;
      !day.isAfter(last) && days.length < pageSize;
      day = day.add(const Duration(days: 1))
    ) {
      days.add(day);
    }
    final more = days.isNotEmpty && days.last.isBefore(last);
    return jsonEncode({
      'asset': 'ZEC',
      'fiat': 'USD',
      'resolution': '1d',
      'from': window.from.toIso8601String(),
      'to': window.to.toIso8601String(),
      'points': [
        for (final day in days)
          {
            'timestamp': day.toIso8601String(),
            'price': priceOn(day),
            'priceUsd': priceOn(day),
            'unitsPerUsd': 1,
          },
      ],
      'availableFrom': _availableFrom.toIso8601String(),
      'availableTo': _availableTo.toIso8601String(),
      'dataAsOf': _availableTo.toIso8601String(),
      'complete': !more,
      if (more)
        'nextCursor': days.last.add(const Duration(days: 1)).toIso8601String(),
    });
  }

  @override
  Future<NetworkHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required List<int> bodyBytes,
    required Duration? timeout,
    Future<void>? cancelSignal,
  }) => throw UnimplementedError('the pricing engine is only read');

  @override
  Future<NetworkHttpResponse> download(
    Uri uri, {
    required Map<String, String> headers,
    required String destinationPath,
  }) => throw UnimplementedError('the pricing engine is only read');
}
