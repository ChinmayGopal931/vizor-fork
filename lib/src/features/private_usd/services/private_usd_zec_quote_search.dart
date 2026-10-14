import '../../../rust/api/private_usd.dart' as rust;

/// An offer the wallet can pay now: the maker's quote for [requestedUnits],
/// its deposit, and the network fee on it (zapp `ZecQuote`).
class PrivateUsdZecQuote {
  const PrivateUsdZecQuote({required this.quote, required this.requestedUnits});

  final rust.ApiForwardQuote quote;

  /// What was asked for, in USDC base units: asked for again first when
  /// this quote runs out.
  final int requestedUnits;

  int get index => quote.index;
  BigInt get depositZat => quote.depositZat;
  BigInt get feeZat => quote.depositFeeZat!;

  /// What it costs in all: the deposit and the network fee on it.
  BigInt get totalZat => depositZat + feeZat;

  /// The most the deposit may cost, as accept takes it.
  BigInt get maxTotalZat => quote.maxTotalZat!;

  /// The dollars that arrive, in USDC base units (never a `double`).
  BigInt get receives => BigInt.parse(quote.receives);
  BigInt get relayerFee => BigInt.parse(quote.relayerFee);
  BigInt? get networkCost => switch (quote.networkCost) {
    final cost? => BigInt.parse(cost),
    null => null,
  };

  DateTime get expiresAt =>
      DateTime.fromMillisecondsSinceEpoch(quote.expiresAt * 1000);
}

/// No quote fits the entered ZEC: too little for any dollar after the fee,
/// or still too dear after every refinement.
class PrivateUsdNoQuoteFitsException implements Exception {
  const PrivateUsdNoQuoteFitsException();

  @override
  String toString() => 'No quote fits the entered ZEC amount.';
}

/// Finds the dearest quote whose deposit and network fee fit a ZEC total
/// (plan reference §9.1 rule 3; zapp `PrivateUsdZecQuotes`).
///
/// Every quote spends a swap index, so the latest quote prices the next
/// while it holds, and an amount usually takes one: a search makes at most
/// a one-dollar price probe and [maxQuotes] quotes. Amounts are integers
/// throughout: zatoshi and USDC base units, never a `double`.
class PrivateUsdZecQuoteSearch {
  PrivateUsdZecQuoteSearch(this._quote, {int Function()? nowSeconds})
    : _nowSeconds =
          nowSeconds ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  final Future<rust.ApiForwardQuote> Function(int units) _quote;
  final int Function() _nowSeconds;
  rust.ApiForwardQuote? _latest;

  /// Quoted for the maker's price while no quote holds: a dollar's deposit
  /// prices the next to the zatoshi.
  static const priceProbeUnits = 1000000;
  static const maxQuotes = 3;

  /// The fee assumed while a quote's own fee is not known (ZIP 317's least).
  static final zip317MinFeeZat = BigInt.from(10000);

  /// `units` crosses FRB as a `u32`; nothing larger can be quoted.
  static const maxUnits = 0xFFFFFFFF;

  /// The dearest quote within [totalZat]; [requestedUnits] goes first when
  /// a quote for it just ran out. A maker's refusal is its own error.
  Future<PrivateUsdZecQuote> quote(
    BigInt totalZat, {
    int? requestedUnits,
  }) async {
    var units = requestedUnits ?? _unitsFor(totalZat, await _basis());
    for (var attempt = 0; attempt < maxQuotes; attempt++) {
      final quote = await _quote(units);
      _latest = quote;
      final payable = _payable(quote, units);
      if (payable.totalZat <= totalZat) return payable;
      units = _unitsFor(totalZat, quote, lessThan: units);
    }
    throw const PrivateUsdNoQuoteFitsException();
  }

  // The latest quote while it holds; otherwise one for a dollar.
  Future<rust.ApiForwardQuote> _basis() async {
    final latest = _latest;
    if (latest != null && latest.expiresAt > _nowSeconds()) return latest;
    return _latest = await _quote(priceProbeUnits);
  }

  // What [basis]'s price buys with [totalZat], less [basis]'s fee or the
  // least one there is. A deposit pays the maker's network cost on top of
  // the amount, at the same price.
  static int _unitsFor(
    BigInt totalZat,
    rust.ApiForwardQuote basis, {
    int? lessThan,
  }) {
    var depositZat = totalZat - (basis.depositFeeZat ?? zip317MinFeeZat);
    if (depositZat < BigInt.zero) depositZat = BigInt.zero;
    final amount = BigInt.parse(basis.amount);
    final cost = basis.networkCost == null
        ? BigInt.zero
        : BigInt.parse(basis.networkCost!);
    if (basis.depositZat <= BigInt.zero) {
      throw const PrivateUsdNoQuoteFitsException();
    }
    var priced = depositZat * (amount + cost) ~/ basis.depositZat - cost;
    if (lessThan != null) {
      final below = BigInt.from(lessThan) - BigInt.one;
      if (below < priced) priced = below;
    }
    if (priced <= BigInt.zero) throw const PrivateUsdNoQuoteFitsException();
    final max = BigInt.from(maxUnits);
    return (priced > max ? max : priced).toInt();
  }

  static PrivateUsdZecQuote _payable(rust.ApiForwardQuote quote, int units) {
    if (quote.depositFeeZat == null || quote.maxTotalZat == null) {
      throw const rust.ApiPrivateUsdError(
        code: rust.ApiPrivateUsdErrorCode.depositUnpayable,
        message: 'no fee estimate for the deposit',
      );
    }
    return PrivateUsdZecQuote(quote: quote, requestedUnits: units);
  }
}
