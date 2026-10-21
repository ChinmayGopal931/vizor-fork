/// Which way a conversion runs: ZEC → private USD (forward) or private USD →
/// ZEC (reverse). The name is the progress route's path segment.
enum PrivateUsdDirection { forward, reverse }

/// One conversion: an account's swap index in one direction. Swap indices
/// are per account and shared by both directions, so the three together
/// name a record in `swaps.db`.
class PrivateUsdRecordKey {
  const PrivateUsdRecordKey({
    required this.accountUuid,
    required this.direction,
    required this.index,
  });

  final String accountUuid;
  final PrivateUsdDirection direction;
  final int index;

  /// The progress route of this conversion.
  PrivateUsdRoutePath get path =>
      PrivateUsdRoutePath(direction: direction, index: index);

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdRecordKey &&
      other.accountUuid == accountUuid &&
      other.direction == direction &&
      other.index == index;

  @override
  int get hashCode => Object.hash(accountUuid, direction, index);

  @override
  String toString() =>
      'PrivateUsdRecordKey($accountUuid, ${direction.name}, $index)';
}

/// `/private-usd/conversion/:direction/:index`: a conversion's progress
/// route. The key is in the path, never in `extra`, so a cold start, the
/// banner and a deep link can all open it; the screen pairs it with the
/// active account. Amounts and quotes never go in the URL.
class PrivateUsdRoutePath {
  const PrivateUsdRoutePath({required this.direction, required this.index});

  final PrivateUsdDirection direction;
  final int index;

  static const prefix = '/private-usd/conversion';

  static final _location = RegExp(
    r'^/private-usd/conversion/(forward|reverse)/(\d{1,10})$',
  );

  String get location => '$prefix/${direction.name}/$index';

  /// The path parameters of the progress route, or null when they name no
  /// conversion (`direction` ∈ {forward, reverse}, `index` a u32).
  static PrivateUsdRoutePath? tryParse(Map<String, String> parameters) {
    final direction = switch (parameters['direction']) {
      'forward' => PrivateUsdDirection.forward,
      'reverse' => PrivateUsdDirection.reverse,
      _ => null,
    };
    final index = _index(parameters['index']);
    if (direction == null || index == null) return null;
    return PrivateUsdRoutePath(direction: direction, index: index);
  }

  /// The same, from a matched location such as
  /// `/private-usd/conversion/forward/3` (the router's synchronous guard).
  static PrivateUsdRoutePath? tryParseLocation(String location) {
    final match = _location.firstMatch(location);
    if (match == null) return null;
    return tryParse({'direction': match[1]!, 'index': match[2]!});
  }

  static int? _index(String? text) {
    if (text == null || !RegExp(r'^\d{1,10}$').hasMatch(text)) return null;
    final index = int.parse(text);
    return index <= 0xFFFFFFFF ? index : null;
  }

  PrivateUsdRecordKey keyFor(String accountUuid) => PrivateUsdRecordKey(
    accountUuid: accountUuid,
    direction: direction,
    index: index,
  );

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdRoutePath &&
      other.direction == direction &&
      other.index == index;

  @override
  int get hashCode => Object.hash(direction, index);

  @override
  String toString() => location;
}
