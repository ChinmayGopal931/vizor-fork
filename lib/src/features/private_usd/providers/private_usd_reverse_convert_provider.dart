import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/account_provider.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_record_key.dart';
import '../models/private_usd_reverse_amount.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_balance_repository.dart';
import '../services/private_usd_engine.dart';
import '../services/private_usd_swap_backend.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_balance_provider.dart';
import 'private_usd_convert_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';

DateTime _at(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

/// The reverse convert screens' state (plan reference §9.4 S4): the dollars
/// typed, the priced `quoted` draft they got, and which step is up.
@immutable
class PrivateUsdReverseConvertState {
  const PrivateUsdReverseConvertState({
    required this.now,
    this.amountText = '',
    this.draft,
    this.quoting = false,
    this.lookingUp = false,
    this.quoteError,
    this.startError,
    this.step = PrivateUsdConvertStep.amount,
    this.quoteSpent = false,
    this.available,
    this.hasRefunds = false,
    this.underWay,
    this.stale,
  });

  final DateTime now;
  final String amountText;

  /// The priced draft for the typed amount (a `quoted` record).
  final rust.ApiReverseRecord? draft;
  final bool quoting;

  /// Max is working out the most that can be converted.
  final bool lookingUp;
  final String? quoteError;
  final String? startError;
  final PrivateUsdConvertStep step;

  /// The draft was taken by a "Convert" that did not start: quote again.
  final bool quoteSpent;

  /// The swap token's spendable private balance in base units; null while
  /// unknown (no quote until it is known).
  final BigInt? available;

  /// An earlier conversion was refunded: "View refunds" shows.
  final bool hasRefunds;

  /// A conversion found under way: its progress shows instead.
  final PrivateUsdRoutePath? underWay;

  /// The amount whose quote failed: not asked again until it changes.
  final BigInt? stale;

  /// The typed dollars in base units; null when empty, malformed, zero or
  /// more than 2 decimals.
  BigInt? get units => privateUsdDollarUnits(amountText);

  bool get isPositive => privateUsdDollarIsPositive(amountText);
  bool get isTooPrecise => privateUsdDollarTooPrecise(amountText);

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

  DateTime? get _cutoff {
    final draft = this.draft;
    if (draft == null) return null;
    final expiry = _at(draft.quoteExpiresAt);
    final funding = _at(draft.fundingDeadline);
    return (funding.isBefore(expiry) ? funding : expiry).subtract(
      PrivateUsdConvertTiming.expiryMargin,
    );
  }

  /// The draft stopped being offered: taken, or near its expiry or its
  /// funding deadline.
  bool get isExpired {
    final cutoff = _cutoff;
    if (cutoff == null) return false;
    return quoteSpent || !now.isBefore(cutoff);
  }

  Duration get expiresIn {
    final cutoff = _cutoff;
    if (cutoff == null) return Duration.zero;
    final left = cutoff.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// What "Review" and "Convert" need: a priced draft for the typed amount
  /// that holds, and a known balance that covers its debit.
  bool get canGoOn =>
      debit != null &&
      !quoting &&
      !lookingUp &&
      !isExpired &&
      available != null &&
      !isShort;

  bool get canReview => step == PrivateUsdConvertStep.amount && canGoOn;
  bool get canConfirm => step == PrivateUsdConvertStep.review && canGoOn;
  bool get isConfirming => step == PrivateUsdConvertStep.confirming;

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
    if (step != PrivateUsdConvertStep.amount) {
      if (startError != null) return startError;
      if (quoteError != null) return quoteError;
      if (isExpired && !quoting) return PrivateUsdCopy.convertQuoteRanOut;
      return null;
    }
    if (isTooPrecise) return PrivateUsdCopy.reverseAmountCents;
    if (isShort) return PrivateUsdCopy.reverseInsufficient;
    return quoteError;
  }

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

/// The reverse convert flow (plan reference §9.4 S4, zapp
/// `PrivateUsdReverseVM`), private USD → ZEC. Each quote spends a swap
/// index, so quotes come only 700 ms after typing stops, for Max, and once
/// to replace one that ran out on the amount step. A quote is priced by the
/// page before it can be reviewed (§5.11 R2), so the direction needs the
/// page; "Convert" goes ahead, accepts and then pays (R3–R6).
final privateUsdReverseConvertProvider =
    NotifierProvider.autoDispose<
      PrivateUsdReverseConvertNotifier,
      PrivateUsdReverseConvertState
    >(PrivateUsdReverseConvertNotifier.new);

class PrivateUsdReverseConvertNotifier
    extends Notifier<PrivateUsdReverseConvertState> {
  late DateTime Function() _clock;
  String? _account;
  Timer? _pending;
  Timer? _tick;
  int _generation = 0;

  @override
  PrivateUsdReverseConvertState build() {
    _clock = ref.watch(privateUsdConvertClockProvider);
    final account = _account = ref
        .read(accountProvider)
        .value
        ?.activeAccountUuid;
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
    _tick = Timer.periodic(PrivateUsdConvertTiming.tick, (_) => _onTick());
    ref.onDispose(() {
      _generation++;
      _pending?.cancel();
      _tick?.cancel();
    });
    return PrivateUsdReverseConvertState(
      now: _clock(),
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
  /// Typing also cancels a Max look-up (zapp: back cancels a look-up).
  void onAmountChanged(String text) {
    if (state.step != PrivateUsdConvertStep.amount) return;
    _cancelQuote();
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

  /// Max (zapp `onMax`): the balance less Railgun's unshield fee and the
  /// relayer's funding fee, rounded down to the cent, then quoted.
  Future<void> onMax() async {
    final account = _account;
    final available = state.available;
    if (!state.canMax || account == null || available == null) return;
    _cancelQuote();
    final generation = _generation;
    state = state.copyWith(lookingUp: true, clearQuoteError: true);
    try {
      final fees = await ref.read(privateUsdReversePageProvider).fees(account);
      final fundingFee = await _fundingFee(account);
      // Typing meanwhile took over (it cleared the look-up).
      if (!ref.mounted || generation != _generation) return;
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
      if (!ref.mounted || generation != _generation) return;
      if (kDebugMode) {
        debugPrint('privateUsd: max failed (${error.runtimeType})');
      }
      state = state.copyWith(
        lookingUp: false,
        quoteError: PrivateUsdCopy.reverseErrorMax,
      );
    }
  }

  /// The relayer's funding fee now. Read through a draft an earlier quote
  /// left, which spends no index; without one, its 2 USDC cap (X6), so Max
  /// never asks for more than the fees leave (D-83).
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
    final cap = BigInt.tryParse(
      ref.read(privateUsdCurrentDeploymentProvider)?.maxRelayerFee ?? '',
    );
    if (cap == null) throw StateError('no relayer fee cap');
    return cap;
  }

  /// Opens the review; false when the draft cannot be reviewed.
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

  /// "Convert" (zapp's one authorized step): go ahead, accept with the
  /// maker (which imports the joint account), then pay the reviewed debit.
  /// Returns the conversion to show once it is under way; the payment's
  /// proof then shows on its progress. Null with
  /// [PrivateUsdReverseConvertState.startError] set otherwise.
  Future<PrivateUsdRoutePath?> confirm() async {
    final account = _account;
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
          _startFailed(PrivateUsdCopy.convertQuoteRanOut);
        case rust.ApiPrivateUsdErrorCode.busy:
          return _backToReview();
        default:
          _startFailed(
            privateUsdReverseQuoteMessage(error.code) ??
                PrivateUsdCopy.convertStartFailed,
          );
      }
      return null;
    } on PrivateUsdEngineInterruptedException {
      return _backToReview();
    } on PrivateUsdEngineUnavailableException {
      return _backToReview();
    } catch (_) {
      if (ref.mounted) _startFailed(PrivateUsdCopy.convertStartFailed);
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
          // No tokens client before M4 (D-33): call it off, nothing paid.
          unawaited(_cancelQuietly(engine, account, index));
          _startFailed(PrivateUsdCopy.convertResultMakerUnavailable);
          return null;
        case rust.ApiAcceptKind.nothingSent:
          _startFailed(privateUsdReverseNothingSentMessage(result.cause));
          return null;
      }
    } on PrivateUsdEngineInterruptedException {
      return _backToReview();
    } on PrivateUsdKeyLockedException {
      return _backToReview();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('privateUsd: accept failed (${error.runtimeType})');
      }
      // The loop accepts again (idempotent); its progress shows it.
      if (await _isUnderWay(engine, account, index)) return path;
      if (ref.mounted) _startFailed(PrivateUsdCopy.convertStartFailed);
      return null;
    }
    // The payment the review showed (R4–R6). It outlives this screen; its
    // proof and any failure show on the progress, with "Pay" again.
    unawaited(
      ref.read(privateUsdReverseFundingProvider).fund(path.keyFor(account)),
    );
    return path;
  }

  /// Looks for a conversion under way for the account (opening the screen).
  Future<void> findUnderWay() async {
    final account = _account;
    if (account == null) return;
    final path = await privateUsdFindUnderWay(
      ref.read(privateUsdEngineProvider),
      account,
    );
    if (!ref.mounted || path == null) return;
    state = state.copyWith(underWay: path);
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
    } catch (_) {
      if (kDebugMode) debugPrint('privateUsd: cancel failed');
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
      if (ref.mounted) _startFailed(PrivateUsdCopy.convertStartFailed);
    }
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
    // A draft left to run out on the amount step is replaced, once; on the
    // review the user decides. A failed amount is not asked again until it
    // changes, and never in the background or locked.
    final units = state.units;
    if (state.step != PrivateUsdConvertStep.amount ||
        state.draft == null ||
        !state.isExpired ||
        state.quoting ||
        state.lookingUp ||
        state.quoteError != null ||
        units == null ||
        units == state.stale ||
        state.isShort ||
        !ref.read(privateUsdEngineProvider).canRun) {
      return;
    }
    _requestQuote(units);
  }

  void _cancelQuote() {
    _generation++;
    _pending?.cancel();
    _pending = null;
  }

  void _requestQuote(
    BigInt units, {
    Duration debounce = Duration.zero,
    bool forReview = false,
  }) {
    _cancelQuote();
    final generation = _generation;
    final account = _account;
    if (account == null) return;
    state = state.copyWith(quoting: true, clearQuoteError: true);
    _pending = Timer(debounce, () async {
      if (!ref.mounted || generation != _generation) return;
      final engine = ref.read(privateUsdEngineProvider);
      // Preserve a request paused during the debounce. No page or quote is
      // opened until the engine can run; editing or disposal cancels it.
      if (!engine.canRun) {
        _requestQuote(
          units,
          debounce: PrivateUsdConvertTiming.tick,
          forReview: forReview,
        );
        return;
      }
      rust.ApiReverseRecord? record;
      Object? failure;
      try {
        // The direction needs the page (it prices the quote): open it
        // first, so a page that cannot start spends no swap index.
        await ref.read(privateUsdReversePageProvider).fees(account);
        if (!ref.mounted || generation != _generation) return;
        final quote = await engine.reverseQuote(account, units: units.toInt());
        record = await ref
            .read(privateUsdReverseFundingProvider)
            .price(account, quote.costRequest);
      } catch (error) {
        failure = error;
      }
      if (!ref.mounted || generation != _generation) return;
      if (record != null) {
        _withDraft(record, forReview: forReview);
      } else {
        _quoteFailed(failure!, units);
      }
    });
  }

  void _withDraft(rust.ApiReverseRecord record, {required bool forReview}) {
    final onReview = state.step != PrivateUsdConvertStep.amount;
    if (state.isConfirming || (onReview && !forReview)) {
      state = state.copyWith(quoting: false);
      return;
    }
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
    if (error is rust.ApiPrivateUsdError &&
        error.code == rust.ApiPrivateUsdErrorCode.busy) {
      // A conversion is under way: it shows instead.
      state = state.copyWith(quoting: false);
      unawaited(findUnderWay());
      return;
    }
    final message = switch (error) {
      rust.ApiPrivateUsdError(:final code) => privateUsdReverseQuoteMessage(
        code,
      ),
      PrivateUsdKeyLockedException() => null,
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
