import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_zec_quote_search.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';

// zapp's `PrivateUsdZecQuotesTest`, every case: the forward quote search
// (plan reference §9.1 rule 3). Each quote spends a swap index, so how many
// quotes a search asks for is what these pin.
void main() {
  const now = 1790000000;
  const validity = 300;
  const oneZec = 100000000;
  const zatPerUnit = 3;
  const feeZat = 10000;
  const networkCost = 220000;

  late int clock;
  late List<int> asked;
  late ApiForwardQuote Function(int units) answer;
  late PrivateUsdZecQuoteSearch quotes;

  ApiForwardQuote quoteFor(int units, {int? fee = feeZat, int? cost}) {
    final depositZat = BigInt.from((units + (cost ?? 0)) * zatPerUnit);
    final fees = fee == null ? null : BigInt.from(fee);
    return ApiForwardQuote(
      index: asked.length,
      expiresAt: clock + validity,
      amount: '$units',
      networkCost: cost == null ? null : '$cost',
      relayerFee: '0',
      receives: '$units',
      depositZat: depositZat,
      depositFeeZat: fees,
      maxTotalZat: fees == null ? null : depositZat + fees,
    );
  }

  setUp(() {
    clock = now;
    asked = [];
    answer = quoteFor;
    quotes = PrivateUsdZecQuoteSearch((units) async {
      asked.add(units);
      return answer(units);
    }, nowSeconds: () => clock);
  });

  int probes() =>
      asked.where((u) => u == PrivateUsdZecQuoteSearch.priceProbeUnits).length;

  test('the price comes from a dollar\'s quote, then each quote prices the '
      'next while it holds', () async {
    await quotes.quote(BigInt.from(50000000));
    await quotes.quote(BigInt.from(40000000));
    clock = now + validity;
    await quotes.quote(BigInt.from(30000000));

    expect(probes(), 2);
    expect(asked, hasLength(5));
  });

  test('a quote costing more than the total is asked for again, smaller, '
      'with its real fee', () async {
    answer = (units) => quoteFor(
      units,
      fee: units == PrivateUsdZecQuoteSearch.priceProbeUnits ? feeZat : 25000,
    );

    final quote = await quotes.quote(BigInt.from(50000000));

    expect(quote.totalZat, BigInt.from(49999999));
    expect(quote.feeZat, BigInt.from(25000));
    expect(asked, hasLength(3));
  });

  test('what a quote costs in all is the most its deposit may cost', () async {
    final quote = await quotes.quote(BigInt.from(50000000));

    expect(quote.totalZat, quote.maxTotalZat);
    expect(quote.totalZat, quote.depositZat + quote.feeZat);
    expect(quote.totalZat <= BigInt.from(50000000), isTrue);
  });

  // Rust's accept refuses unless the spendable ZEC covers the open fee, its
  // payment's network fee and the deposit's approved total (`forward.rs`,
  // `propose_open_fee`): the review's total is exactly that.
  test('a fee quote\'s total is what the bridge needs the wallet to hold', () {
    final quote = PrivateUsdZecQuote(
      quote: ApiForwardQuote(
        index: 0,
        expiresAt: now + validity,
        amount: '1000000',
        relayerFee: '20000',
        receives: '980000',
        depositZat: BigInt.from(202021),
        depositFeeZat: BigInt.from(15000),
        maxTotalZat: BigInt.from(217021),
        openFeeZat: BigInt.from(20000),
        openFeeNetworkZat: BigInt.from(10000),
        openFeePayBy: now + validity - 200,
      ),
      requestedUnits: 1000000,
    );
    expect(
      quote.totalZat,
      quote.openFeeZat + quote.quote.openFeeNetworkZat! + quote.maxTotalZat,
    );
    expect(quote.totalZat, BigInt.from(247021));
    final noFee = PrivateUsdZecQuote(
      quote: quoteFor(1000000),
      requestedUnits: 1000000,
    );
    expect(noFee.totalZat, noFee.maxTotalZat);
  });

  test("an offer whose fee the wallet can't work out can't be paid", () async {
    answer = (units) => quoteFor(units, fee: null);

    await expectLater(
      quotes.quote(BigInt.from(50000000)),
      throwsA(
        isA<ApiPrivateUsdError>().having(
          (e) => e.code,
          'code',
          ApiPrivateUsdErrorCode.depositUnpayable,
        ),
      ),
    );
  });

  test("a whole balance is asked for in full, with no most of the app's "
      'own', () async {
    final quote = await quotes.quote(BigInt.from(10 * oneZec));

    expect(quote.requestedUnits, 333330000);
    expect(quote.totalZat, BigInt.from(10 * oneZec));
  });

  test(
    'an amount the maker refuses is its refusal, not asked for again',
    () async {
      answer = (units) {
        if (units == PrivateUsdZecQuoteSearch.priceProbeUnits) {
          return quoteFor(units);
        }
        throw const ApiPrivateUsdError(
          code: ApiPrivateUsdErrorCode.amountRefused,
          message: 'range',
        );
      };

      await expectLater(
        quotes.quote(BigInt.from(10 * oneZec)),
        throwsA(
          isA<ApiPrivateUsdError>().having(
            (e) => e.code,
            'code',
            ApiPrivateUsdErrorCode.amountRefused,
          ),
        ),
      );
      expect(asked, hasLength(2));
    },
  );

  test('ZEC that only covers the network fee has no quote', () async {
    await expectLater(
      quotes.quote(BigInt.from(feeZat)),
      throwsA(isA<PrivateUsdNoQuoteFitsException>()),
    );
  });

  test(
    "typed ZEC pays for the maker's network cost as well as the amount",
    () async {
      answer = (units) => quoteFor(units, cost: networkCost);

      final quote = await quotes.quote(BigInt.from(3000000 + feeZat));

      expect(quote.requestedUnits, 780000);
      expect(quote.totalZat, BigInt.from(3000000 + feeZat));
      expect(asked, hasLength(2));
    },
  );

  test('a quote that ran out is asked for again at its size first', () async {
    await quotes.quote(BigInt.from(50000000), requestedUnits: 16000000);

    expect(asked, [16000000]);
  });

  // vizor: `units` is a u32 across FRB, so a total past it asks for the most
  // a quote can name instead (the maker may still turn that down).
  test('a total worth more than a u32 of units asks for the most', () async {
    final quote = await quotes.quote(BigInt.from(1000000 * oneZec));

    expect(quote.requestedUnits, PrivateUsdZecQuoteSearch.maxUnits);
  });
}
