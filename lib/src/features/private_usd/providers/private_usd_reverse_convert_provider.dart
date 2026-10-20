import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_messages.dart';
import '../models/private_usd_record_key.dart';
import '../models/private_usd_reverse_amount.dart';
import '../models/private_usd_send.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_balance_repository.dart';
import '../services/private_usd_engine.dart';
import '../services/private_usd_pause.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_balance_provider.dart';
import 'private_usd_convert_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';

DateTime _at(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

/// The private USD → ZEC convert screens' state: the dollars typed, the
/// priced `quoted` draft they got, and which step is up.
@immutable
class PrivateUsdReverseConvertState
    extends PrivateUsdConvertFlowState<PrivateUsdReverseConvertState> {
  const PrivateUsdReverseConvertState({
    required super.now,
    super.amountText,
    this.draft,
    super.quoting,
    this.lookingUp = false,
    super.quoteError,
    super.startError,
    super.step,
    super.quoteSpent,
    this.available,
    this.hasRefunds = false,
    super.underWay,
    this.stale,
  });

  /// The priced draft for the typed amount (a `quoted` record).
  final rust.ApiReverseRecord? draft;

  /// Max is working out the most that can be converted.
  final bool lookingUp;

  /// The swap token's spendable private balance in base units; null while
  /// unknown (no quote until it is known).
  final BigInt? available;

  /// An earlier conversion was refunded: "View refunds" shows.
  final bool hasRefunds;

  /// The amount whose quote failed: not asked again until it changes.
  final BigInt? stale;

  /// The typed dollars in base units; null when empty, malformed, zero or
  /// more than 2 decimals.
  BigInt? get units => privateUsdDollarUnits(amountText);

  bool get isPositive => privateUsdDollarIsPositive(amountText);
  bool get isTooPrecise => privateUsdTooPrecise(amountText, 2);

  /// The reviewed debit, while the draft prices the typed amount.
  BigInt? get debit {
    final draft = this.draft;
    final cost = draft?.cost;
    if (draft == null || cost == null) return null;
    if (BigInt.parse(draft.amount) != units) return null;
    return BigInt.parse(cost.debit);
  }

  /// More than the private balance holds: the debit once priced, the typed
  /// amount before.
  bool get isShort {
    final available = this.available;
    if (available == null) return false;
    final amount = debit ?? units;
    return amount != null && amount > available;
  }

  bool get isAmountInvalid => isShort || (isPositive && units == null);

  /// The draft's expiry or its funding deadline, whichever comes first.
  @override
  DateTime? get offeredUntil {
    final draft = this.draft;
    if (draft == null) return null;
    final expiry = _at(draft.quoteExpiresAt);
    final funding = _at(draft.fundingDeadline);
    return (funding.isBefore(expiry) ? funding : expiry).subtract(
      PrivateUsdConvertTiming.expiryMargin,
    );
  }

  /// A priced draft for the typed amount that holds, and a known balance
  /// that covers its debit.
  @override
  bool get canGoOn =>
      debit != null &&
      !quoting &&
      !lookingUp &&
      !isExpired &&
      available != null &&
      !isShort;

  /// Max: on the amount step, with a balance to convert.
  bool get canMax {
    final available = this.available;
    return step == PrivateUsdConvertStep.amount &&
        available != null &&
        available > BigInt.zero &&
        !lookingUp;
  }

  /// "View refunds": an earlier conversion was refunded, and nothing is
  /// under review.
  bool get showsRefunds => hasRefunds && step == PrivateUsdConvertStep.amount;

  /// The line under the amount, or on the review.
  String? get message {
    if (step != PrivateUsdConvertStep.amount) return reviewMessage;
    if (isTooPrecise) return PrivateUsdCopy.reverseAmountCents;
    if (isShort) return PrivateUsdCopy.reverseInsufficient;
    return quoteError;
  }

  @override
  PrivateUsdReverseConvertState copyWith({
    DateTime? now,
    String? amountText,
    rust.ApiReverseRecord? draft,
    bool clearDraft = false,
    bool? quoting,
    bool? lookingUp,
    String? quoteError,
    bool clearQuoteError = false,
    String? startError,
    bool clearStartError = false,
    PrivateUsdConvertStep? step,
    bool? quoteSpent,
    BigInt? available,
    bool clearAvailable = false,
    bool? hasRefunds,
    PrivateUsdRoutePath? underWay,
    BigInt? stale,
    bool clearStale = false,
  }) => PrivateUsdReverseConvertState(
    now: now ?? this.now,
    amountText: amountText ?? this.amountText,
    draft: clearDraft ? null : (draft ?? this.draft),
    quoting: quoting ?? this.quoting,
    lookingUp: lookingUp ?? this.lookingUp,
    quoteError: clearQuoteError ? null : (quoteError ?? this.quoteError),
    startError: clearStartError ? null : (startError ?? this.startError),
    step: step ?? this.step,
    quoteSpent: quoteSpent ?? (clearDraft ? false : this.quoteSpent),
    available: clearAvailable ? null : (available ?? this.available),
    hasRefunds: hasRefunds ?? this.hasRefunds,
    underWay: underWay ?? this.underWay,
    stale: clearStale ? null : (stale ?? this.stale),
  );
}

/// The private USD → ZEC convert flow. Quotes come 700 ms after typing
/// stops, for Max, and once to replace one that ran out on the amount step.
/// The page prices a quote before it can be reviewed, so the direction needs
/// the page; "Convert" goes ahead, accepts and then pays.
final privateUsdReverseConvertProvider =
    NotifierProvider.autoDispose<
      PrivateUsdReverseConvertNotifier,
      PrivateUsdReverseConvertState
    >(PrivateUsdReverseConvertNotifier.new);

class PrivateUsdReverseConvertNotifier
    extends PrivateUsdConvertFlowNotifier<PrivateUsdReverseConvertState> {
  @override
  PrivateUsdReverseConvertState build() {
    setUpFlow();
    final account = this.account;
    BigInt? available;
    var hasRefunds = false;
    if (account != null) {
      available = _available(ref.read(privateUsdBalanceProvider(account)));
      ref.listen(privateUsdBalanceProvider(account), (_, next) {
        final value = _available(next);
        state = state.copyWith(available: value, clearAvailable: value == null);
      });
      bool refunded(Map<PrivateUsdRecordKey, PrivateUsdReverseStatus> all) =>
          all.entries.any(
            (entry) =>
                entry.key.accountUuid == account &&
                entry.value.record.phase == rust.ApiReversePhase.refunded,
          );
      hasRefunds = refunded(ref.read(privateUsdReverseConversionsProvider));
      ref.listen(privateUsdReverseConversionsProvider.select(refunded), (
        _,
        next,
      ) {
        state = state.copyWith(hasRefunds: next);
      });
    }
    return PrivateUsdReverseConvertState(
      now: clock(),
      available: available,
      hasRefunds: hasRefunds,
    );
  }

  /// The swap token's spendable notes: the funding unshields that token.
  BigInt? _available(PrivateUsdBalanceState balance) {
    final balances = balance.balances;
    if (balances == null) return null;
    final token = ref
        .read(privateUsdCurrentDeploymentProvider)
        ?.token
        .toLowerCase();
    for (final asset in balances.assets) {
      if (asset.token.address == token) return asset.available;
    }
    return BigInt.zero;
  }

  /// The amount field changed: an amount to quote, after typing stops.
  /// Typing also cancels a Max look-up.
  void onAmountChanged(String text) {
    if (state.step != PrivateUsdConvertStep.amount) return;
    cancelQuote();
    state = state.copyWith(
      amountText: text,
      clearDraft: true,
      quoting: false,
      lookingUp: false,
      clearQuoteError: true,
      clearStale: true,
    );
    final units = state.units;
    if (units == null || state.isShort || state.available == null) return;
    _requestQuote(units, debounce: PrivateUsdConvertTiming.typingDebounce);
  }

  /// Max: the balance less Railgun's unshield fee and the relayer's funding
  /// fee, rounded down to the cent, then quoted.
  Future<void> onMax() async {
    final account = this.account;
    final available = state.available;
    if (!state.canMax || account == null || available == null) return;
    cancelQuote();
    final generation = quoteGeneration;
    state = state.copyWith(lookingUp: true, clearQuoteError: true);
    try {
      final fees = await ref.read(privateUsdReversePageProvider).fees(account);
      final fundingFee = await _fundingFee(account);
      // Typing meanwhile took over (it cleared the look-up).
      if (!ref.mounted || generation != quoteGeneration) return;
      final max = privateUsdReverseMax(
        available: available,
        unshieldBasisPoints: fees.unshieldBasisPoints,
        fundingFee: fundingFee,
      );
      state = state.copyWith(lookingUp: false);
      if (max <= BigInt.zero) {
        state = state.copyWith(quoteError: PrivateUsdCopy.reverseInsufficient);
        return;
      }
      onAmountChanged(privateUsdDollarText(max));
    } catch (error) {
      if (!ref.mounted || generation != quoteGeneration) return;
      privateUsdLog('max failed (${error.runtimeType})');
      state = state.copyWith(
        lookingUp: false,
        quoteError: PrivateUsdCopy.reverseErrorMax,
      );
    }
  }

  /// The relayer's funding fee now. Read through a draft an earlier quote
  /// left, which spends no index; without one, the deployment's cap on it,
  /// so Max never asks for more than the fees leave.
  Future<BigInt> _fundingFee(String account) async {
    final engine = ref.read(privateUsdEngineProvider);
    final draft = ref
        .read(privateUsdReverseConversionsProvider)
        .entries
        .where(
          (entry) =>
              entry.key.accountUuid == account &&
              entry.value.record.phase == rust.ApiReversePhase.quoted,
        )
        .firstOrNull;
    if (draft != null) {
      try {
        final request = await engine.reverseCostRequest(
          account,
          index: draft.key.index,
        );
        return BigInt.parse(request.fee);
      } catch (_) {
        // The cap below.
      }
    }
    final cap = privateUsdRelayerFeeCap(
      ref.read(privateUsdCurrentDeploymentProvider),
    );
    if (cap == null) throw StateError('no relayer fee cap');
    return cap;
  }

  /// "Refresh quote" on the review: the same amount, a new index.
  void refreshQuote() {
    if (state.step != PrivateUsdConvertStep.review ||
        !state.isExpired ||
        state.quoting) {
      return;
    }
    final units = state.units;
    if (units == null) return;
    state = state.copyWith(clearStartError: true);
    _requestQuote(units, forReview: true);
  }

  /// "Convert": go ahead, accept with the maker (which imports the joint
  /// account), then pay the reviewed debit. Returns the conversion to show
  /// once it is under way; the payment's proof then shows on its progress.
  /// Null with [PrivateUsdReverseConvertState.startError] set otherwise.
  Future<PrivateUsdRoutePath?> confirm() async {
    final account = this.account;
    final draft = state.draft;
    if (!state.canConfirm || account == null || draft == null) return null;
    state = state.copyWith(
      step: PrivateUsdConvertStep.confirming,
      clearStartError: true,
    );
    final engine = ref.read(privateUsdEngineProvider);
    final index = draft.index;
    final path = PrivateUsdRoutePath(
      direction: PrivateUsdDirection.reverse,
      index: index,
    );
    // The first authorization: nothing reached the maker if it fails.
    try {
      await engine.reverseGoAhead(account, index: index);
    } on rust.ApiPrivateUsdError catch (error) {
      if (!ref.mounted) return null;
      switch (error.code) {
        case rust.ApiPrivateUsdErrorCode.fundingCostChanged:
          await _repriced(account, index);
        case rust.ApiPrivateUsdErrorCode.quoteExpired ||
            rust.ApiPrivateUsdErrorCode.tooLate:
          startFailed(PrivateUsdCopy.convertQuoteRanOut);
        case rust.ApiPrivateUsdErrorCode.busy:
          return backToReview();
        default:
          startFailed(
            privateUsdReverseQuoteMessage(error.code) ??
                PrivateUsdCopy.convertStartFailed,
          );
      }
      return null;
    } on PrivateUsdPause {
      return backToReview();
    } catch (_) {
      if (ref.mounted) startFailed(PrivateUsdCopy.convertStartFailed);
      return null;
    }
    // Gone ahead: the conversion is under way from here, whatever follows.
    try {
      final result = await engine.reverseAccept(account, index: index);
      if (!ref.mounted) return null;
      switch (result.kind) {
        case rust.ApiAcceptKind.accepted:
          break;
        case rust.ApiAcceptKind.tokensNeeded:
          // The maker wants a Privacy Pass token and none is held: call it
          // off, nothing paid.
          unawaited(_cancelQuietly(engine, account, index));
          startFailed(PrivateUsdCopy.convertResultMakerUnavailable);
          return null;
        case rust.ApiAcceptKind.nothingSent:
          startFailed(privateUsdReverseNothingSentMessage(result.cause));
          return null;
      }
    } on PrivateUsdPause {
      return backToReview();
    } catch (error) {
      privateUsdLog('accept failed (${error.runtimeType})');
      // The loop accepts again (idempotent); its progress shows it.
      if (await _isUnderWay(engine, account, index)) return path;
      if (ref.mounted) startFailed(PrivateUsdCopy.convertStartFailed);
      return null;
    }
    // The payment the review showed. It outlives this screen; its proof and
    // any failure show on the progress, with "Pay" again.
    unawaited(
      ref.read(privateUsdReverseFundingProvider).fund(path.keyFor(account)),
    );
    return path;
  }

  @override
  void replaceExpiredQuote() {
    final units = state.units;
    if (state.lookingUp ||
        units == null ||
        units == state.stale ||
        state.isShort) {
      return;
    }
    _requestQuote(units);
  }

  Future<bool> _isUnderWay(
    PrivateUsdEngine engine,
    String account,
    int index,
  ) async {
    try {
      final records = await engine.loadReverseRecords(account);
      return records.any(
        (record) =>
            record.index == index && privateUsdReverseUnderWay(record.phase),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _cancelQuietly(
    PrivateUsdEngine engine,
    String account,
    int index,
  ) async {
    try {
      await engine.reverseCancel(account, index: index);
    } catch (error) {
      privateUsdLog('cancel failed (${error.runtimeType})');
    }
  }

  /// The relayer's fee moved since the review: price the draft again and
  /// show the new total with why.
  Future<void> _repriced(String account, int index) async {
    try {
      final engine = ref.read(privateUsdEngineProvider);
      final request = await engine.reverseCostRequest(account, index: index);
      final record = await ref
          .read(privateUsdReverseFundingProvider)
          .price(account, request);
      if (!ref.mounted) return;
      state = state.copyWith(
        draft: record,
        step: PrivateUsdConvertStep.review,
        startError: PrivateUsdCopy.reverseErrorCostChanged,
      );
    } catch (_) {
      if (ref.mounted) startFailed(PrivateUsdCopy.convertStartFailed);
    }
  }

  void _requestQuote(
    BigInt units, {
    Duration debounce = Duration.zero,
    bool forReview = false,
  }) {
    final account = this.account;
    if (account == null) return;
    requestQuote<rust.ApiReverseRecord>(
      (current) async {
        // The page prices the quote: it opens first, so a page that cannot
        // start spends no swap index.
        await ref.read(privateUsdReversePageProvider).fees(account);
        if (!current()) return null;
        final quote = await ref
            .read(privateUsdEngineProvider)
            .reverseQuote(account, units: units.toInt());
        return ref
            .read(privateUsdReverseFundingProvider)
            .price(account, quote.costRequest);
      },
      debounce: debounce,
      onQuote: (record) => _withDraft(record, forReview: forReview),
      onFailure: (error) => _quoteFailed(error, units),
    );
  }

  void _withDraft(rust.ApiReverseRecord record, {required bool forReview}) {
    if (!takesQuote(forReview: forReview)) return;
    final onReview = state.step != PrivateUsdConvertStep.amount;
    final next = state.copyWith(
      draft: record,
      quoting: false,
      quoteSpent: false,
      clearQuoteError: true,
    );
    if (next.isExpired) {
      // It arrived already expired: the phone's clock is off.
      state = state.copyWith(
        quoting: false,
        clearDraft: !onReview,
        quoteError: PrivateUsdCopy.convertQuoteClockAhead,
        stale: next.units,
      );
      return;
    }
    state = next;
  }

  void _quoteFailed(Object error, BigInt units) {
    if (showsUnderWay(error)) return;
    final message = switch (error) {
      rust.ApiPrivateUsdError(:final code) => privateUsdReverseQuoteMessage(
        code,
      ),
      PrivateUsdPause() => null,
      _ => PrivateUsdCopy.convertErrorGeneric,
    };
    state = state.copyWith(
      quoting: false,
      quoteError: message,
      clearQuoteError: message == null,
      stale: units,
    );
  }
}
