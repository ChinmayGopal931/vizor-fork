import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/formatting/zec_amount.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_record_key.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_available_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_balance_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_convert_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_reverse_convert_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_reverse_funding.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_swap_backend.dart';
import 'package:zcash_wallet/src/providers/account_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';

import 'support/fake_private_usd_backend.dart';

// The forward convert flow (plan reference §9.4 S3): zapp's
// `PrivateUsdConvertVMTest` button-enable cases, plus vizor's back and
// expiry rules (the review is its own route here). Time is the widget
// tester's fake clock; each quote is a real search over a scripted maker.
void main() {
  const account = 'account-1';
  const oneZec = 100000000;
  const zatPerUnit = 3;
  const feeZat = 10000;
  const validity = Duration(seconds: 300);
  const typing = PrivateUsdConvertTiming.typingDebounce;

  late FakePrivateUsdBackend backend;
  late PrivateUsdEngine engine;
  late ProviderContainer container;
  late List<int> asked;
  Completer<void>? quoteGate;
  late int? nextFee;
  var allowed = true;
  late _UnavailableReversePage reversePage;

  PrivateUsdConvertNotifier notifier() =>
      container.read(privateUsdConvertProvider.notifier);
  PrivateUsdConvertState state() => container.read(privateUsdConvertProvider);

  void setHoldings(PrivateUsdZecHoldings holdings) =>
      container.read(_holdingsSource.notifier).set(holdings);

  Future<void> start(
    WidgetTester tester, {
    PrivateUsdZecHoldings holdings = const PrivateUsdZecHoldings(
      spendable: null,
    ),
  }) async {
    asked = [];
    nextFee = feeZat;
    quoteGate = null;
    allowed = true;
    reversePage = _UnavailableReversePage();
    DateTime now() => tester.binding.clock.now();
    backend = FakePrivateUsdBackend(records: {account: []})
      ..onQuote = (units) {
        asked.add(units);
        final depositZat = BigInt.from(units * zatPerUnit);
        final fee = nextFee == null ? null : BigInt.from(nextFee!);
        return ApiForwardQuote(
          index: asked.length,
          expiresAt: now().add(validity).millisecondsSinceEpoch ~/ 1000,
          amount: '$units',
          relayerFee: '460000',
          receives: '${units * 97 ~/ 100}',
          depositZat: depositZat,
          depositFeeZat: fee,
          maxTotalZat: fee == null ? null : depositZat + fee,
        );
      };
    engine = PrivateUsdEngine(
      backend: _GatedBackend(backend, () => quoteGate),
      readMnemonic: (_) async => Uint8List.fromList(List.filled(32, 1)),
      allowed: () => allowed,
      now: now,
    );
    container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith(_OneAccount.new),
        privateUsdEngineProvider.overrideWithValue(engine),
        privateUsdCurrentDeploymentProvider.overrideWithValue(null),
        privateUsdReversePageProvider.overrideWithValue(reversePage),
        privateUsdBalanceProvider(
          account,
        ).overrideWith(() => _EmptyBalance(account)),
        privateUsdReverseConvertProvider.overrideWith(_FundedReverse.new),
        privateUsdConvertClockProvider.overrideWithValue(now),
        _holdingsSource.overrideWith(() => _HoldingsNotifier(holdings)),
        privateUsdZecHoldingsProvider.overrideWith(
          (ref, _) => ref.watch(_holdingsSource),
        ),
      ],
    );
    await container.read(accountProvider.future);
    container.listen(privateUsdConvertProvider, (_, _) {});
  }

  Future<void> finish(WidgetTester tester) async {
    container.dispose();
    await engine.dispose();
    await tester.pump(Duration.zero);
  }

  void convertTest(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        await finish(tester);
      }
    });
  }

  Future<void> type(WidgetTester tester, String amount) async {
    notifier().onAmountChanged(amount);
    await tester.pump(typing + const Duration(milliseconds: 1));
    await tester.pump(Duration.zero);
  }

  PrivateUsdZecHoldings spendable(int zatoshi) => PrivateUsdZecHoldings(
    spendable: BigInt.from(zatoshi),
    authoritative: true,
  );

  convertTest('a paused quote waits, then quotes the latest amount once', (
    tester,
  ) async {
    await start(tester, holdings: spendable(oneZec));
    allowed = false;
    await type(tester, '0.5');
    await tester.pump(const Duration(seconds: 3));
    expect(asked, isEmpty);
    expect(state().quoting, isTrue);

    await type(tester, '0.4');
    allowed = true;
    await tester.pump(PrivateUsdConvertTiming.tick);
    await tester.pump(Duration.zero);
    expect(state().canReview, isTrue);
    expect(state().quote!.totalZat, lessThanOrEqualTo(BigInt.from(40000000)));
    final count = asked.length;
    await tester.pump(const Duration(seconds: 3));
    expect(asked, hasLength(count));
  });

  convertTest('clearing a paused amount cancels its quote', (tester) async {
    await start(tester, holdings: spendable(oneZec));
    allowed = false;
    await type(tester, '0.5');
    await type(tester, '');
    allowed = true;
    await tester.pump(const Duration(seconds: 3));
    expect(asked, isEmpty);
    expect(state().quoting, isFalse);
  });

  convertTest('a paused reverse quote opens no page until resumed, and a '
      'failed page is not retried automatically', (tester) async {
    await start(tester);
    container.listen(privateUsdReverseConvertProvider, (_, _) {});
    final reverse = container.read(privateUsdReverseConvertProvider.notifier);
    allowed = false;
    reverse.onAmountChanged('1');
    await tester.pump(const Duration(seconds: 3));
    expect(reversePage.feeRequests, 0);
    expect(backend.secretsSeen, isEmpty);

    allowed = true;
    await tester.pump(PrivateUsdConvertTiming.tick);
    await tester.pump(Duration.zero);
    expect(reversePage.feeRequests, 1);
    expect(container.read(privateUsdReverseConvertProvider).quoting, isFalse);
    await tester.pump(const Duration(seconds: 3));
    expect(reversePage.feeRequests, 1);
    expect(backend.secretsSeen, isEmpty);
  });

  convertTest('clearing a paused reverse amount cancels the pending page '
      'and quote', (tester) async {
    await start(tester);
    container.listen(privateUsdReverseConvertProvider, (_, _) {});
    final reverse = container.read(privateUsdReverseConvertProvider.notifier);
    allowed = false;
    reverse.onAmountChanged('1');
    await tester.pump(const Duration(seconds: 3));
    reverse.onAmountChanged('');
    allowed = true;
    await tester.pump(const Duration(seconds: 3));
    expect(reversePage.feeRequests, 0);
    expect(backend.secretsSeen, isEmpty);
    expect(container.read(privateUsdReverseConvertProvider).quoting, isFalse);
  });

  convertTest(
    'a typed amount is quoted once its price is known, and reviewed as it '
    'costs in all',
    (tester) async {
      await start(tester, holdings: spendable(oneZec));

      await type(tester, '0.5');

      final quote = state().quote!;
      expect(quote.totalZat, BigInt.from(49999999));
      expect(quote.feeZat, BigInt.from(feeZat));
      expect(state().canReview, isTrue);
      expect(asked.where((u) => u == 1000000), hasLength(1));
      expect(asked, hasLength(2));

      await type(tester, '0.4');

      expect(asked, hasLength(3));
    },
  );

  convertTest(
    'more than the wallet can spend is said at once, without asking for a '
    'quote',
    (tester) async {
      await start(tester, holdings: spendable(oneZec));

      await type(tester, '2');

      expect(
        state().message,
        PrivateUsdCopy.convertInsufficient(
          ZecAmount.fromZatoshi(BigInt.from(oneZec)).activity.toString(),
        ),
      );
      expect(state().isAmountInvalid, isTrue);
      expect(state().canReview, isFalse);
      expect(asked, isEmpty);
    },
  );

  convertTest("a zero still being typed isn't flagged or quoted", (
    tester,
  ) async {
    await start(tester, holdings: spendable(oneZec));

    for (final typed in ['0', '0.0']) {
      await type(tester, typed);
    }

    expect(state().isAmountInvalid, isFalse);
    expect(state().message, isNull);
    expect(asked, isEmpty);
  });

  convertTest("the maximum can't change an amount once the review is up", (
    tester,
  ) async {
    await start(tester, holdings: spendable(oneZec));
    await type(tester, '0.5');
    quoteGate = Completer<void>();

    notifier().onMax();
    await tester.pump(Duration.zero);
    expect(state().canReview, isFalse);
    expect(notifier().openReview(), isFalse);
    expect(state().step, PrivateUsdConvertStep.amount);
    quoteGate!.complete();
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);

    expect(state().step, PrivateUsdConvertStep.amount);
    expect(parseZecAmount(state().amountText), BigInt.from(oneZec));
    expect(state().quote!.totalZat, BigInt.from(oneZec));
    expect(asked.last, 33330000);
  });

  convertTest(
    'the maximum fills in the whole balance at once, then what its quote '
    'pays for',
    (tester) async {
      await start(tester, holdings: spendable(oneZec + 2));
      quoteGate = Completer<void>();

      notifier().onMax();
      await tester.pump(Duration.zero);

      expect(state().amountText, '1.00000002');
      expect(state().quoting, isTrue);
      expect(state().canReview, isFalse);
      quoteGate!.complete();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(parseZecAmount(state().amountText), BigInt.from(oneZec));
      expect(state().quoting, isFalse);
      expect(asked.last, 33330000);
    },
  );

  convertTest(
    "while the wallet syncs, the balance it hasn't caught up on is said, and "
    'the maximum waits for it',
    (tester) async {
      await start(
        tester,
        holdings: PrivateUsdZecHoldings(
          spendable: BigInt.from(oneZec),
          authoritative: true,
          catchingUp: true,
          syncPercent: 42,
        ),
      );

      expect(state().holdings.syncPercent, 42);
      expect(state().canMax, isFalse);

      setHoldings(spendable(oneZec));
      await tester.pump(Duration.zero);
      expect(state().holdings.catchingUp, isFalse);
      expect(state().canMax, isTrue);

      // Nor before the balance is Rust's own (the last completed sync's).
      setHoldings(PrivateUsdZecHoldings(spendable: BigInt.from(oneZec)));
      await tester.pump(Duration.zero);
      expect(state().canMax, isFalse);
    },
  );

  convertTest(
    "an offer the wallet can't price the fee of can't be reviewed, and says "
    'why',
    (tester) async {
      await start(tester, holdings: spendable(oneZec));
      nextFee = null;

      await type(tester, '0.5');

      expect(state().quote, isNull);
      expect(state().message, PrivateUsdCopy.convertErrorUnpayable);
      expect(state().canReview, isFalse);
    },
  );

  convertTest('back from the review returns to the amount, but not while '
      'confirming', (tester) async {
    await start(tester, holdings: spendable(oneZec));
    await type(tester, '0.5');
    expect(notifier().openReview(), isTrue);
    expect(state().step, PrivateUsdConvertStep.review);

    expect(notifier().leaveReview(), isTrue);
    expect(state().step, PrivateUsdConvertStep.amount);

    expect(notifier().openReview(), isTrue);
    final accepting = Completer<void>();
    backend.onAccept = (index) =>
        ApiAcceptResult(kind: ApiAcceptKind.accepted, index: index);
    quoteGate = accepting;
    final confirmed = notifier().confirm();
    await tester.pump(Duration.zero);
    expect(state().isConfirming, isTrue);
    expect(notifier().leaveReview(), isFalse);
    expect(state().isConfirming, isTrue);
    accepting.complete();
    await tester.pump(Duration.zero);
    expect(
      await confirmed,
      PrivateUsdRoutePath(
        direction: PrivateUsdDirection.forward,
        index: state().quote!.index,
      ),
    );
  });

  convertTest(
    'a quote stops being offered 20 s before it expires, and on the amount '
    'step it is replaced at its size',
    (tester) async {
      await start(tester, holdings: spendable(oneZec));
      await type(tester, '0.5');
      final first = state().quote!;
      expect(state().canReview, isTrue);

      // Hold the replacement, to see the expired quote meanwhile.
      quoteGate = Completer<void>();
      await tester.pump(validity);
      expect(state().quote!.index, first.index);
      expect(state().isExpired, isTrue);
      expect(state().canReview, isFalse);
      expect(state().quoting, isTrue);

      quoteGate!.complete();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(asked, hasLength(3));
      expect(asked.last, first.requestedUnits);
      expect(state().quote!.index, isNot(first.index));
      expect(state().canReview, isTrue);
    },
  );

  convertTest(
    "on the review an expired quote waits for 'Refresh quote', which keeps "
    'the review',
    (tester) async {
      await start(tester, holdings: spendable(oneZec));
      await type(tester, '0.5');
      expect(notifier().openReview(), isTrue);

      await tester.pump(validity);
      expect(state().isExpired, isTrue);
      expect(state().canConfirm, isFalse);
      expect(state().message, PrivateUsdCopy.convertQuoteRanOut);
      expect(asked, hasLength(2));

      final requested = state().quote!.requestedUnits;
      notifier().refreshQuote();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);

      expect(asked.last, requested);
      expect(state().step, PrivateUsdConvertStep.review);
      expect(state().isExpired, isFalse);
      expect(state().canConfirm, isTrue);
    },
  );
}

final _holdingsSource =
    NotifierProvider<_HoldingsNotifier, PrivateUsdZecHoldings>(
      () => _HoldingsNotifier(const PrivateUsdZecHoldings()),
    );

class _EmptyBalance extends PrivateUsdBalanceNotifier {
  _EmptyBalance(super.accountUuid);

  @override
  PrivateUsdBalanceState build() => const PrivateUsdBalanceState();
}

class _FundedReverse extends PrivateUsdReverseConvertNotifier {
  @override
  PrivateUsdReverseConvertState build() =>
      super.build().copyWith(available: BigInt.from(10000000));
}

class _UnavailableReversePage implements PrivateUsdReversePage {
  var feeRequests = 0;

  @override
  Future<RailgunFees> fees(String accountUuid) async {
    feeRequests++;
    throw StateError('page unavailable');
  }

  @override
  Future<String> address(String accountUuid) => throw UnimplementedError();

  @override
  Future<RailgunReverseCost> reverseCost(
    String accountUuid,
    RailgunReverseCostRequest request,
  ) => throw UnimplementedError();

  @override
  Future<RailgunReverseTransaction> prepareReverse(
    String accountUuid,
    RailgunReverseRequest request,
  ) => throw UnimplementedError();
}

class _HoldingsNotifier extends Notifier<PrivateUsdZecHoldings> {
  _HoldingsNotifier(this.initial);

  final PrivateUsdZecHoldings initial;

  @override
  PrivateUsdZecHoldings build() => initial;

  void set(PrivateUsdZecHoldings next) => state = next;
}

class _OneAccount extends AccountNotifier {
  @override
  FutureOr<AccountState> build() => const AccountState(
    accounts: [
      AccountInfo(
        uuid: 'account-1',
        name: 'Main',
        order: 0,
        zip32AccountIndex: 0,
      ),
    ],
    activeAccountUuid: 'account-1',
  );
}

/// Holds quotes and accepts while [gate] is set.
class _GatedBackend extends FakePrivateUsdBackend {
  _GatedBackend(this.inner, this.gate) : super(records: inner.records);

  final FakePrivateUsdBackend inner;
  final Completer<void>? Function() gate;

  @override
  Future<ApiForwardQuote> forwardQuote(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int units,
  }) async {
    final hold = gate();
    if (hold != null) await hold.future;
    return inner.forwardQuote(accountUuid, secret, units: units);
  }

  @override
  Future<ApiAcceptResult> forwardAccept(
    String accountUuid,
    PrivateUsdSecretReader secret, {
    required int index,
    required BigInt maxTotalZat,
  }) async {
    final hold = gate();
    if (hold != null) await hold.future;
    return inner.forwardAccept(
      accountUuid,
      secret,
      index: index,
      maxTotalZat: maxTotalZat,
    );
  }
}
