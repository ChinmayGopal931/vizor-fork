import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatting/zec_amount.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../../migration/providers/ironwood_migration_announcement_provider.dart';
import '../models/private_usd_record_key.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_engine.dart';
import '../services/private_usd_swap_backend.dart';
import '../services/private_usd_zec_quote_search.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_engine_provider.dart';

/// The convert flow's timing (plan reference §9.1, §9.4 S3).
abstract final class PrivateUsdConvertTiming {
  /// Typing pauses this long before its amount is quoted (X10).
  static const typingDebounce = Duration(milliseconds: 700);

  /// A quote stops being offered this long before it expires: the driver
  /// won't accept one about to run out.
  static const expiryMargin = Duration(seconds: 20);

  static const tick = Duration(seconds: 1);
}

/// The ZEC the active account can convert, as the convert screen shows it.
@immutable
class PrivateUsdZecHoldings {
  const PrivateUsdZecHoldings({
    this.spendable,
    this.authoritative = false,
    this.catchingUp = false,
    this.syncPercent,
  });

  /// The shielded spendable balance; null until the wallet has one.
  final BigInt? spendable;

  /// The balance is Rust's current value, not the last completed sync's:
  /// "Max" quotes only then.
  final bool authoritative;

  /// The wallet is still syncing, and more ZEC than is spendable is held.
  final bool catchingUp;
  final int? syncPercent;

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdZecHoldings &&
      other.spendable == spendable &&
      other.authoritative == authoritative &&
      other.catchingUp == catchingUp &&
      other.syncPercent == syncPercent;

  @override
  int get hashCode =>
      Object.hash(spendable, authoritative, catchingUp, syncPercent);
}

final privateUsdZecHoldingsProvider = Provider.autoDispose
    .family<PrivateUsdZecHoldings, String>((ref, accountUuid) {
      final sync = ref.watch(
        syncProvider.select(
          (value) => (value.value ?? SyncState()).scopedToAccount(accountUuid),
        ),
      );
      if (!sync.hasBalanceData) return const PrivateUsdZecHoldings();
      final spendable = ref.watch(
        ironwoodMigrationAwareDisplaySpendableProvider(accountUuid),
      );
      final catchingUp =
          !sync.isSyncComplete && sync.displayShieldedBalance > spendable;
      return PrivateUsdZecHoldings(
        spendable: spendable,
        authoritative:
            sync.displaySpendableFreshness ==
            SpendableBalanceFreshness.authoritative,
        catchingUp: catchingUp,
        syncPercent: catchingUp
            ? (sync.percentage * 100).floor().clamp(0, 99)
            : null,
      );
    });

/// The convert flow's clock; tests replace it.
final privateUsdConvertClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

enum PrivateUsdConvertStep { amount, review, confirming }

/// The convert screens' state (plan reference §9.4 S3): the amount, the
/// quote it got, and which step is up. The rules that decide what may be
/// tapped are getters, so the amount and review screens share them.
@immutable
class PrivateUsdConvertState {
  const PrivateUsdConvertState({
    required this.now,
    this.amountText = '',
    this.quote,
    this.quoting = false,
    this.quoteError,
    this.startError,
    this.step = PrivateUsdConvertStep.amount,
    this.quoteSpent = false,
    this.holdings = const PrivateUsdZecHoldings(),
    this.underWay,
  });

  final DateTime now;
  final String amountText;
  final PrivateUsdZecQuote? quote;
  final bool quoting;

  /// Why the last quote did not come.
  final String? quoteError;

  /// Why the last "Convert" did not start a conversion.
  final String? startError;
  final PrivateUsdConvertStep step;

  /// The quote was consumed by an accept that did not open a conversion: it
  /// cannot be accepted again.
  final bool quoteSpent;
  final PrivateUsdZecHoldings holdings;

  /// A conversion found under way (opening the screen, a quote refused as
  /// `busy`, or an accept that may have opened): its progress shows instead.
  final PrivateUsdRoutePath? underWay;

  static final _maxZatoshi = BigInt.from(2100000000000000);

  /// The typed ZEC in zatoshi; null for none, or one no wallet could hold.
  BigInt? get totalZat {
    final zatoshi = parseZecAmount(amountText);
    if (zatoshi == null || zatoshi < BigInt.one || zatoshi > _maxZatoshi) {
      return null;
    }
    return zatoshi;
  }

  /// Something more than zero was typed: a zero still being typed is not
  /// flagged.
  bool get isPositive {
    final zatoshi = parseZecAmount(amountText);
    return zatoshi != null && zatoshi > BigInt.zero;
  }

  /// More than the wallet can spend: said at once, without a quote.
  bool get isShort {
    final total = totalZat;
    final spendable = holdings.spendable;
    return total != null && spendable != null && total > spendable;
  }

  bool get isAmountInvalid => isShort || (isPositive && totalZat == null);

  /// The quote stopped being offered: spent, or within the margin of its
  /// expiry.
  bool get isExpired {
    final quote = this.quote;
    if (quote == null) return false;
    return quoteSpent ||
        !now.isBefore(
          quote.expiresAt.subtract(PrivateUsdConvertTiming.expiryMargin),
        );
  }

  /// Time left until the quote stops being offered.
  Duration get expiresIn {
    final quote = this.quote;
    if (quote == null) return Duration.zero;
    final left = quote.expiresAt
        .subtract(PrivateUsdConvertTiming.expiryMargin)
        .difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// The quote leaves something after the relayer's fee.
  bool get paysOut => quote != null && quote!.receives > BigInt.zero;

  /// What "Review" and "Convert" need: a quote that pays out and holds,
  /// and a known balance that covers it.
  bool get canGoOn {
    final quote = this.quote;
    final spendable = holdings.spendable;
    return quote != null &&
        !quoting &&
        paysOut &&
        !isExpired &&
        spendable != null &&
        quote.totalZat <= spendable;
  }

  bool get canReview => step == PrivateUsdConvertStep.amount && canGoOn;
  bool get canConfirm => step == PrivateUsdConvertStep.review && canGoOn;
  bool get isConfirming => step == PrivateUsdConvertStep.confirming;

  /// "Use it all": on the amount step, with a balance Rust vouches for, and
  /// not while the wallet catches up.
  bool get canMax {
    final spendable = holdings.spendable;
    return step == PrivateUsdConvertStep.amount &&
        spendable != null &&
        spendable > BigInt.zero &&
        holdings.authoritative &&
        !holdings.catchingUp;
  }

  /// The line under the amount, or on the review.
  String? get message {
    if (step != PrivateUsdConvertStep.amount) {
      if (startError != null) return startError;
      // A refresh asked for on the review that did not come.
      if (quoteError != null) return quoteError;
      if (isExpired && !quoting) return PrivateUsdCopy.convertQuoteRanOut;
      return null;
    }
    if (isShort) {
      return PrivateUsdCopy.convertInsufficient(
        ZecAmount.fromZatoshi(holdings.spendable!).activity.toString(),
      );
    }
    if (quoteError != null) return quoteError;
    if (quote != null && !quoting && !paysOut) {
      return PrivateUsdCopy.convertErrorBelowFee;
    }
    return null;
  }

  PrivateUsdConvertState copyWith({
    DateTime? now,
    String? amountText,
    PrivateUsdZecQuote? quote,
    bool clearQuote = false,
    bool? quoting,
    String? quoteError,
    bool clearQuoteError = false,
    String? startError,
    bool clearStartError = false,
    PrivateUsdConvertStep? step,
    bool? quoteSpent,
    PrivateUsdZecHoldings? holdings,
    PrivateUsdRoutePath? underWay,
  }) => PrivateUsdConvertState(
    now: now ?? this.now,
    amountText: amountText ?? this.amountText,
    quote: clearQuote ? null : (quote ?? this.quote),
    quoting: quoting ?? this.quoting,
    quoteError: clearQuoteError ? null : (quoteError ?? this.quoteError),
    startError: clearStartError ? null : (startError ?? this.startError),
    step: step ?? this.step,
    quoteSpent: quoteSpent ?? (clearQuote ? false : this.quoteSpent),
    holdings: holdings ?? this.holdings,
    underWay: underWay ?? this.underWay,
  );
}

/// The forward convert flow (plan reference §9.4 S3, zapp
/// `PrivateUsdConvertVM`). Every quote spends a swap index, so quotes come
/// only 700 ms after typing stops, for "Use it all" once the balance is
/// Rust's, and to replace a quote that ran out on the amount step: never on
/// opening, and never while the review is up unless asked to refresh.
final privateUsdConvertProvider =
    NotifierProvider.autoDispose<
      PrivateUsdConvertNotifier,
      PrivateUsdConvertState
    >(PrivateUsdConvertNotifier.new);

class PrivateUsdConvertNotifier extends Notifier<PrivateUsdConvertState> {
  late DateTime Function() _clock;
  late PrivateUsdZecQuoteSearch _search;
  String? _account;
  Timer? _pending;
  Timer? _tick;
  int _generation = 0;

  @override
  PrivateUsdConvertState build() {
    _clock = ref.watch(privateUsdConvertClockProvider);
    _account = ref.read(accountProvider).value?.activeAccountUuid;
    _search = PrivateUsdZecQuoteSearch(
      (units) =>
          ref.read(privateUsdEngineProvider).quote(_account!, units: units),
      nowSeconds: () => _clock().millisecondsSinceEpoch ~/ 1000,
    );
    final account = _account;
    var holdings = const PrivateUsdZecHoldings();
    if (account != null) {
      holdings = ref.read(privateUsdZecHoldingsProvider(account));
      ref.listen(privateUsdZecHoldingsProvider(account), (_, next) {
        state = state.copyWith(holdings: next);
      });
    }
    _tick = Timer.periodic(PrivateUsdConvertTiming.tick, (_) => _onTick());
    ref.onDispose(() {
      _generation++;
      _pending?.cancel();
      _tick?.cancel();
    });
    return PrivateUsdConvertState(now: _clock(), holdings: holdings);
  }

  /// The amount field changed: an amount to quote, after typing stops.
  void onAmountChanged(String text) {
    if (state.step != PrivateUsdConvertStep.amount) return;
    _cancelQuote();
    state = state.copyWith(
      amountText: text,
      clearQuote: true,
      quoting: false,
      clearQuoteError: true,
    );
    final total = state.totalZat;
    if (total == null || state.isShort) return;
    _requestQuote(
      () => _search.quote(total),
      debounce: PrivateUsdConvertTiming.typingDebounce,
    );
  }

  /// "Use it all": the whole balance shows at once; its quote then brings
  /// it to what that pays for.
  void onMax() {
    if (!state.canMax) return;
    final spendable = state.holdings.spendable!;
    _cancelQuote();
    state = state.copyWith(
      amountText: formatZecAmount(spendable),
      clearQuote: true,
      clearQuoteError: true,
    );
    _requestQuote(() => _search.quote(spendable), fillsAmount: true);
  }

  /// Opens the review; false when the quote cannot be reviewed.
  bool openReview() {
    if (!state.canReview) return false;
    state = state.copyWith(
      step: PrivateUsdConvertStep.review,
      clearStartError: true,
    );
    return true;
  }

  /// Back from the review to the amount; false (blocked) while confirming.
  bool leaveReview() {
    if (state.isConfirming) return false;
    if (state.step == PrivateUsdConvertStep.review) {
      state = state.copyWith(
        step: PrivateUsdConvertStep.amount,
        clearStartError: true,
      );
    }
    return true;
  }

  /// "Refresh quote" on the review, once the quote ran out: the same size
  /// first. The review takes the new quote (it was asked for there).
  void refreshQuote() {
    if (state.step != PrivateUsdConvertStep.review ||
        !state.isExpired ||
        state.quoting) {
      return;
    }
    final total = state.totalZat;
    if (total == null) return;
    final requested = state.quote?.requestedUnits;
    state = state.copyWith(clearStartError: true);
    _requestQuote(
      () => _search.quote(total, requestedUnits: requested),
      forReview: true,
    );
  }

  /// Accepts the reviewed quote. Returns the conversion to show (accepted,
  /// or under way all the same after an accept that failed once its record
  /// was saved), or null with [PrivateUsdConvertState.startError] set.
  Future<PrivateUsdRoutePath?> confirm() async {
    if (!state.canConfirm) return null;
    final account = _account;
    final quote = state.quote!;
    if (account == null) return null;
    state = state.copyWith(
      step: PrivateUsdConvertStep.confirming,
      clearStartError: true,
    );
    final engine = ref.read(privateUsdEngineProvider);
    final path = PrivateUsdRoutePath(
      direction: PrivateUsdDirection.forward,
      index: quote.index,
    );
    try {
      final result = await engine.accept(
        account,
        index: quote.index,
        maxTotalZat: quote.maxTotalZat,
      );
      if (!ref.mounted) return null;
      switch (result.kind) {
        case rust.ApiAcceptKind.accepted:
          return path;
        case rust.ApiAcceptKind.tokensNeeded:
          // No tokens client before M4 (D-33): nothing opened. End the
          // record; never ask again in a loop.
          unawaited(_abandonQuietly(engine, account, quote.index));
          _startFailed(PrivateUsdCopy.convertResultMakerUnavailable);
          return null;
        case rust.ApiAcceptKind.nothingSent:
          _startFailed(privateUsdNothingSentMessage(result.cause));
          return null;
      }
    } on rust.ApiPrivateUsdError catch (error) {
      if (!ref.mounted) return null;
      switch (error.code) {
        // Refused before anything was saved.
        case rust.ApiPrivateUsdErrorCode.quoteExpired:
          _startFailed(PrivateUsdCopy.convertQuoteRanOut);
          return null;
        case rust.ApiPrivateUsdErrorCode.relayerFee:
          _startFailed(
            _aboveCap(quote.relayerFee)
                ? PrivateUsdCopy.convertErrorFeeCap
                : PrivateUsdCopy.convertErrorBelowFee,
          );
          return null;
        case rust.ApiPrivateUsdErrorCode.depositUnpayable:
          _startFailed(PrivateUsdCopy.convertErrorUnpayable);
          return null;
        default:
          break;
      }
    } on PrivateUsdEngineInterruptedException {
      // Locked or backgrounded mid-accept: Rust may have saved it, and the
      // engine picks a saved record up. Back to the review, never stuck in
      // `confirming`; a conversion under way shows instead.
      return _backToReview();
    } on PrivateUsdKeyLockedException {
      return _backToReview();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('privateUsd: accept failed (${error.runtimeType})');
      }
    }
    // Maybe opened: an accept that failed after its record was saved is
    // under way all the same.
    if (await _isUnderWay(engine, account, quote.index)) return path;
    if (!ref.mounted) return null;
    _startFailed(PrivateUsdCopy.convertStartFailed);
    return null;
  }

  /// Looks for a conversion under way for the account (opening the screen):
  /// one shows instead of a new conversion.
  Future<void> findUnderWay() async {
    final account = _account;
    if (account == null) return;
    final engine = ref.read(privateUsdEngineProvider);
    try {
      final records = await engine.loadRecords(account);
      if (!ref.mounted) return;
      for (final record in records) {
        if (record.outcome == null) {
          state = state.copyWith(
            underWay: PrivateUsdRoutePath(
              direction: PrivateUsdDirection.forward,
              index: record.index,
            ),
          );
          return;
        }
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('privateUsd: reading conversions failed');
      }
    }
  }

  Future<bool> _isUnderWay(
    PrivateUsdEngine engine,
    String account,
    int index,
  ) async {
    try {
      final records = await engine.loadRecords(account);
      return records.any(
        (record) => record.index == index && record.outcome == null,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _abandonQuietly(
    PrivateUsdEngine engine,
    String account,
    int index,
  ) async {
    try {
      await engine.abandon(account, index: index);
    } catch (error) {
      if (kDebugMode) debugPrint('privateUsd: abandon failed');
    }
  }

  bool _aboveCap(BigInt fee) {
    final cap = ref.read(privateUsdCurrentDeploymentProvider)?.maxRelayerFee;
    final limit = cap == null ? null : BigInt.tryParse(cap);
    return limit == null || fee > limit;
  }

  PrivateUsdRoutePath? _backToReview() {
    if (ref.mounted) {
      state = state.copyWith(step: PrivateUsdConvertStep.review);
      unawaited(findUnderWay());
    }
    return null;
  }

  void _startFailed(String message) {
    state = state.copyWith(
      step: PrivateUsdConvertStep.review,
      startError: message,
      quoteSpent: true,
    );
  }

  void _onTick() {
    if (!ref.mounted) return;
    state = state.copyWith(now: _clock());
    // A quote left to run out on the amount step is replaced, its size
    // first; on the review the user decides. Never in the background or
    // locked: each quote spends a swap index.
    final quote = state.quote;
    if (state.step != PrivateUsdConvertStep.amount ||
        quote == null ||
        !state.isExpired ||
        state.quoting ||
        // A failed replacement is not retried every tick: each try spends a
        // swap index. Editing the amount asks again.
        state.quoteError != null ||
        !ref.read(privateUsdEngineProvider).canRun) {
      return;
    }
    final total = state.totalZat;
    if (total == null || state.isShort) return;
    _requestQuote(
      () => _search.quote(total, requestedUnits: quote.requestedUnits),
    );
  }

  void _cancelQuote() {
    _generation++;
    _pending?.cancel();
    _pending = null;
  }

  void _requestQuote(
    Future<PrivateUsdZecQuote> Function() run, {
    Duration debounce = Duration.zero,
    bool fillsAmount = false,
    bool forReview = false,
  }) {
    _cancelQuote();
    final generation = _generation;
    state = state.copyWith(quoting: true, clearQuoteError: true);
    _pending = Timer(debounce, () async {
      if (!ref.mounted || generation != _generation) return;
      // Backgrounded or locked during the debounce: no quote, since each one
      // spends a swap index and reads the seed.
      if (!ref.read(privateUsdEngineProvider).canRun) {
        state = state.copyWith(quoting: false);
        return;
      }
      PrivateUsdZecQuote? quote;
      Object? failure;
      try {
        quote = await run();
      } catch (error) {
        failure = error;
      }
      if (!ref.mounted || generation != _generation) return;
      if (quote != null) {
        _withQuote(quote, fillsAmount: fillsAmount, forReview: forReview);
      } else {
        _quoteFailed(failure!);
      }
    });
  }

  // A quote that lands while the review is up is dropped unless the review
  // asked for it; one that arrives already expired says the clock is off.
  void _withQuote(
    PrivateUsdZecQuote quote, {
    required bool fillsAmount,
    required bool forReview,
  }) {
    final onReview = state.step != PrivateUsdConvertStep.amount;
    if (state.isConfirming || (onReview && !forReview)) {
      state = state.copyWith(quoting: false);
      return;
    }
    final arrivedExpired = !_clock().isBefore(
      quote.expiresAt.subtract(PrivateUsdConvertTiming.expiryMargin),
    );
    if (arrivedExpired) {
      // On the review the expired quote stays, so "Refresh quote" does too.
      state = state.copyWith(
        quoting: false,
        clearQuote: !onReview,
        quoteError: PrivateUsdCopy.convertQuoteClockAhead,
      );
      return;
    }
    state = state.copyWith(
      quote: quote,
      quoting: false,
      quoteSpent: false,
      clearQuoteError: true,
      amountText: fillsAmount ? formatZecAmount(quote.totalZat) : null,
    );
  }

  void _quoteFailed(Object error) {
    if (error is rust.ApiPrivateUsdError &&
        error.code == rust.ApiPrivateUsdErrorCode.busy) {
      // A conversion is under way: it shows instead.
      state = state.copyWith(quoting: false);
      unawaited(findUnderWay());
      return;
    }
    final message = switch (error) {
      PrivateUsdNoQuoteFitsException() => PrivateUsdCopy.convertZecNoQuote,
      rust.ApiPrivateUsdError(:final code) => privateUsdErrorMessage(code),
      PrivateUsdKeyLockedException() => null,
      _ => PrivateUsdCopy.convertErrorGeneric,
    };
    state = state.copyWith(
      quoting: false,
      quoteError: message,
      clearQuoteError: message == null,
    );
  }
}
