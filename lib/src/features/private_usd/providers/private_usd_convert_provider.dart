import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../../migration/providers/ironwood_migration_announcement_provider.dart';
import '../models/private_usd_messages.dart';
import '../models/private_usd_record_key.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_engine.dart';
import '../services/private_usd_pause.dart';
import '../services/private_usd_zec_quote_search.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_engine_provider.dart';

/// The convert flows' timing.
abstract final class PrivateUsdConvertTiming {
  /// Typing pauses this long before its amount is quoted.
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

/// The convert flows' clock; tests replace it.
final privateUsdConvertClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

enum PrivateUsdConvertStep { amount, review, confirming }

/// What both convert flows' states hold: the amount, the quote's lifetime,
/// which step is up, and the rules that follow from them, so the amount and
/// review screens share them.
@immutable
abstract class PrivateUsdConvertFlowState<
  S extends PrivateUsdConvertFlowState<S>
> {
  const PrivateUsdConvertFlowState({
    required this.now,
    this.amountText = '',
    this.quoting = false,
    this.quoteError,
    this.startError,
    this.step = PrivateUsdConvertStep.amount,
    this.quoteSpent = false,
    this.underWay,
  });

  final DateTime now;
  final String amountText;
  final bool quoting;

  /// Why the last quote did not come.
  final String? quoteError;

  /// Why the last "Convert" did not start a conversion.
  final String? startError;
  final PrivateUsdConvertStep step;

  /// The quote was taken by a "Convert" that did not start a conversion: it
  /// cannot be accepted again.
  final bool quoteSpent;

  /// A conversion found under way (opening the screen, a quote refused as
  /// `busy`, or a start that may have opened one): its progress shows
  /// instead.
  final PrivateUsdRoutePath? underWay;

  /// When the quote stops being offered; null without one.
  DateTime? get offeredUntil;

  /// What "Review" and "Convert" need.
  bool get canGoOn;

  /// The quote stopped being offered: taken, or past [offeredUntil].
  bool get isExpired {
    final until = offeredUntil;
    if (until == null) return false;
    return quoteSpent || !now.isBefore(until);
  }

  /// Time left until the quote stops being offered.
  Duration get expiresIn {
    final until = offeredUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  bool get canReview => step == PrivateUsdConvertStep.amount && canGoOn;
  bool get canConfirm => step == PrivateUsdConvertStep.review && canGoOn;
  bool get isConfirming => step == PrivateUsdConvertStep.confirming;

  /// The line on the review: why "Convert" did not start, a refresh asked
  /// for there that did not come, or a quote that ran out.
  String? get reviewMessage {
    if (startError != null) return startError;
    if (quoteError != null) return quoteError;
    if (isExpired && !quoting) return PrivateUsdCopy.convertQuoteRanOut;
    return null;
  }

  S copyWith({
    DateTime? now,
    String? amountText,
    bool? quoting,
    String? quoteError,
    bool clearQuoteError = false,
    String? startError,
    bool clearStartError = false,
    PrivateUsdConvertStep? step,
    bool? quoteSpent,
    PrivateUsdRoutePath? underWay,
  });
}

/// What both convert flows' notifiers share: the review steps, quotes asked
/// for after typing stops and held while the engine cannot run, and the
/// conversion under way that shows instead of a new one. Every quote spends
/// a swap index, so a quote is never asked for on opening or per keystroke.
abstract class PrivateUsdConvertFlowNotifier<
  S extends PrivateUsdConvertFlowState<S>
>
    extends Notifier<S> {
  @protected
  late DateTime Function() clock;

  /// The active account when the flow opened.
  @protected
  String? account;

  Timer? _pending;
  int _generation = 0;

  /// Moves on with every quote asked for, every edit and disposal: a quote
  /// asked for before is dropped.
  @protected
  int get quoteGeneration => _generation;

  /// For [build]: the clock, the active account, the tick, and what
  /// disposal cancels.
  @protected
  void setUpFlow() {
    clock = ref.watch(privateUsdConvertClockProvider);
    account = ref.read(accountProvider).value?.activeAccountUuid;
    final tick = Timer.periodic(PrivateUsdConvertTiming.tick, (_) => _onTick());
    ref.onDispose(() {
      _generation++;
      _pending?.cancel();
      tick.cancel();
    });
  }

  /// Asks again for the quote that ran out on the amount step, when it may.
  @protected
  void replaceExpiredQuote();

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

  /// Looks for a conversion under way for the account (opening the screen):
  /// one shows instead of a new conversion.
  Future<void> findUnderWay() async {
    final account = this.account;
    if (account == null) return;
    final path = await privateUsdFindUnderWay(
      ref.read(privateUsdEngineProvider),
      account,
    );
    if (!ref.mounted || path == null) return;
    state = state.copyWith(underWay: path);
  }

  /// Back to the review after a pause stopped "Convert": never stuck in
  /// `confirming`, and a conversion under way shows instead.
  @protected
  PrivateUsdRoutePath? backToReview() {
    if (ref.mounted) {
      state = state.copyWith(step: PrivateUsdConvertStep.review);
      unawaited(findUnderWay());
    }
    return null;
  }

  /// "Convert" did not start a conversion: [message] says why, and the
  /// quote is spent.
  @protected
  void startFailed(String message) {
    state = state.copyWith(
      step: PrivateUsdConvertStep.review,
      startError: message,
      quoteSpent: true,
    );
  }

  @protected
  void cancelQuote() {
    _generation++;
    _pending?.cancel();
    _pending = null;
  }

  /// Asks for a quote through [run] after [debounce]. Backgrounded or locked
  /// meanwhile, the request waits until the engine can run: no swap index or
  /// seed is touched while paused, and an edit or disposal cancels it. [run]
  /// answers null once it finds itself no longer `current`.
  @protected
  void requestQuote<Q extends Object>(
    Future<Q?> Function(bool Function() current) run, {
    required void Function(Q quote) onQuote,
    required void Function(Object error) onFailure,
    Duration debounce = Duration.zero,
  }) {
    cancelQuote();
    final generation = _generation;
    bool current() => ref.mounted && generation == _generation;
    state = state.copyWith(quoting: true, clearQuoteError: true);
    _pending = Timer(debounce, () async {
      if (!current()) return;
      if (!ref.read(privateUsdEngineProvider).canRun) {
        requestQuote(
          run,
          onQuote: onQuote,
          onFailure: onFailure,
          debounce: PrivateUsdConvertTiming.tick,
        );
        return;
      }
      Q? quote;
      Object? failure;
      try {
        quote = await run(current);
      } catch (error) {
        failure = error;
      }
      if (!current()) return;
      if (quote != null) {
        onQuote(quote);
      } else if (failure != null) {
        onFailure(failure);
      }
    });
  }

  /// Whether a quote that just came is taken: one that lands while the
  /// review is up is dropped unless the review asked for it, and none is
  /// taken while confirming.
  @protected
  bool takesQuote({required bool forReview}) {
    final onReview = state.step != PrivateUsdConvertStep.amount;
    if (!state.isConfirming && (!onReview || forReview)) return true;
    state = state.copyWith(quoting: false);
    return false;
  }

  /// A quote refused as `busy` means a conversion is under way, which shows
  /// instead; whether [error] was that.
  @protected
  bool showsUnderWay(Object error) {
    if (error is! rust.ApiPrivateUsdError ||
        error.code != rust.ApiPrivateUsdErrorCode.busy) {
      return false;
    }
    state = state.copyWith(quoting: false);
    unawaited(findUnderWay());
    return true;
  }

  void _onTick() {
    if (!ref.mounted) return;
    state = state.copyWith(now: clock());
    // A quote left to run out on the amount step is replaced; on the review
    // the user decides. Never in the background or locked, and a failed
    // replacement is not retried every tick (each quote spends a swap
    // index): editing the amount asks again.
    if (state.step == PrivateUsdConvertStep.amount &&
        state.isExpired &&
        !state.quoting &&
        state.quoteError == null &&
        ref.read(privateUsdEngineProvider).canRun) {
      replaceExpiredQuote();
    }
  }
}

/// The ZEC → private USD convert screens' state: the amount, the quote it
/// got, and which step is up.
@immutable
class PrivateUsdConvertState
    extends PrivateUsdConvertFlowState<PrivateUsdConvertState> {
  const PrivateUsdConvertState({
    required super.now,
    super.amountText,
    this.quote,
    super.quoting,
    super.quoteError,
    super.startError,
    super.step,
    super.quoteSpent,
    this.holdings = const PrivateUsdZecHoldings(),
    super.underWay,
  });

  final PrivateUsdZecQuote? quote;
  final PrivateUsdZecHoldings holdings;

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

  @override
  DateTime? get offeredUntil =>
      quote?.expiresAt.subtract(PrivateUsdConvertTiming.expiryMargin);

  /// The quote leaves something after the relayer's fee.
  bool get paysOut => quote != null && quote!.receives > BigInt.zero;

  /// A quote that pays out and holds, and a known balance that covers it.
  @override
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
    if (step != PrivateUsdConvertStep.amount) return reviewMessage;
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

  @override
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

/// The ZEC → private USD convert flow. Quotes come 700 ms after typing
/// stops, for "Use it all" once the balance is Rust's, and to replace a
/// quote that ran out on the amount step; never while the review is up
/// unless asked to refresh.
final privateUsdConvertProvider =
    NotifierProvider.autoDispose<
      PrivateUsdConvertNotifier,
      PrivateUsdConvertState
    >(PrivateUsdConvertNotifier.new);

class PrivateUsdConvertNotifier
    extends PrivateUsdConvertFlowNotifier<PrivateUsdConvertState> {
  late PrivateUsdZecQuoteSearch _search;

  @override
  PrivateUsdConvertState build() {
    setUpFlow();
    _search = PrivateUsdZecQuoteSearch(
      (units) =>
          ref.read(privateUsdEngineProvider).quote(this.account!, units: units),
      nowSeconds: () => clock().millisecondsSinceEpoch ~/ 1000,
    );
    final account = this.account;
    var holdings = const PrivateUsdZecHoldings();
    if (account != null) {
      holdings = ref.read(privateUsdZecHoldingsProvider(account));
      ref.listen(privateUsdZecHoldingsProvider(account), (_, next) {
        state = state.copyWith(holdings: next);
      });
    }
    return PrivateUsdConvertState(now: clock(), holdings: holdings);
  }

  /// The amount field changed: an amount to quote, after typing stops.
  void onAmountChanged(String text) {
    if (state.step != PrivateUsdConvertStep.amount) return;
    cancelQuote();
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
    cancelQuote();
    state = state.copyWith(
      amountText: formatZecAmount(spendable),
      clearQuote: true,
      clearQuoteError: true,
    );
    _requestQuote(() => _search.quote(spendable), fillsAmount: true);
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
    final account = this.account;
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
          // The maker wants a Privacy Pass token and none is held: nothing
          // opened. End the record; never ask again in a loop.
          unawaited(_abandonQuietly(engine, account, quote.index));
          startFailed(PrivateUsdCopy.convertResultMakerUnavailable);
          return null;
        case rust.ApiAcceptKind.nothingSent:
          startFailed(privateUsdNothingSentMessage(result.cause));
          return null;
      }
    } on rust.ApiPrivateUsdError catch (error) {
      if (!ref.mounted) return null;
      switch (error.code) {
        // Refused before anything was saved.
        case rust.ApiPrivateUsdErrorCode.quoteExpired:
          startFailed(PrivateUsdCopy.convertQuoteRanOut);
          return null;
        case rust.ApiPrivateUsdErrorCode.relayerFee:
          startFailed(
            _aboveCap(quote.relayerFee)
                ? PrivateUsdCopy.convertErrorFeeCap
                : PrivateUsdCopy.convertErrorBelowFee,
          );
          return null;
        case rust.ApiPrivateUsdErrorCode.depositUnpayable:
          startFailed(PrivateUsdCopy.convertErrorUnpayable);
          return null;
        default:
          break;
      }
    } on PrivateUsdPause {
      // Rust may have saved it, and the engine picks a saved record up.
      return backToReview();
    } catch (error) {
      privateUsdLog('accept failed (${error.runtimeType})');
    }
    // Maybe opened: an accept that failed after its record was saved is
    // under way all the same.
    if (await _isUnderWay(engine, account, quote.index)) return path;
    if (!ref.mounted) return null;
    startFailed(PrivateUsdCopy.convertStartFailed);
    return null;
  }

  @override
  void replaceExpiredQuote() {
    final total = state.totalZat;
    if (total == null || state.isShort) return;
    final requested = state.quote!.requestedUnits;
    _requestQuote(() => _search.quote(total, requestedUnits: requested));
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
      privateUsdLog('abandon failed (${error.runtimeType})');
    }
  }

  // Without a cap from the deployment, no fee is within it.
  bool _aboveCap(BigInt fee) {
    final cap = privateUsdRelayerFeeCap(
      ref.read(privateUsdCurrentDeploymentProvider),
    );
    return cap == null || fee > cap;
  }

  void _requestQuote(
    Future<PrivateUsdZecQuote> Function() run, {
    Duration debounce = Duration.zero,
    bool fillsAmount = false,
    bool forReview = false,
  }) => requestQuote<PrivateUsdZecQuote>(
    (_) => run(),
    debounce: debounce,
    onQuote: (quote) =>
        _withQuote(quote, fillsAmount: fillsAmount, forReview: forReview),
    onFailure: _quoteFailed,
  );

  // One that arrives already expired says the clock is off.
  void _withQuote(
    PrivateUsdZecQuote quote, {
    required bool fillsAmount,
    required bool forReview,
  }) {
    if (!takesQuote(forReview: forReview)) return;
    final onReview = state.step != PrivateUsdConvertStep.amount;
    final arrivedExpired = !clock().isBefore(
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
    if (showsUnderWay(error)) return;
    final message = switch (error) {
      PrivateUsdNoQuoteFitsException() => PrivateUsdCopy.convertZecNoQuote,
      rust.ApiPrivateUsdError(:final code) => privateUsdErrorMessage(code),
      PrivateUsdPause() => null,
      _ => PrivateUsdCopy.convertErrorGeneric,
    };
    state = state.copyWith(
      quoting: false,
      quoteError: message,
      clearQuoteError: message == null,
    );
  }
}

/// [accountUuid]'s conversion under way in either direction, read from the
/// records (opening a convert screen, or after the app died mid-accept):
/// one at a time per account, so it shows instead of a new one. One of
/// another deployment holds up no new conversion. Reading them also
/// publishes the account's reverse drafts.
Future<PrivateUsdRoutePath?> privateUsdFindUnderWay(
  PrivateUsdEngine engine,
  String accountUuid,
) async {
  try {
    final forward = await engine.loadRecords(accountUuid);
    for (final record in forward) {
      if (record.outcome == null && !record.otherDeployment) {
        return PrivateUsdRoutePath(
          direction: PrivateUsdDirection.forward,
          index: record.index,
        );
      }
    }
    final reverse = await engine.loadReverseRecords(accountUuid);
    for (final record in reverse) {
      if (privateUsdReverseUnderWay(record.phase) && !record.otherDeployment) {
        return PrivateUsdRoutePath(
          direction: PrivateUsdDirection.reverse,
          index: record.index,
        );
      }
    }
  } catch (error) {
    privateUsdLog('reading conversions failed (${error.runtimeType})');
  }
  return null;
}
