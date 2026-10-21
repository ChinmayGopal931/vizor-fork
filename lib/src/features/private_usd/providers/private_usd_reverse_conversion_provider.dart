import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_messages.dart';
import '../models/private_usd_record_key.dart';
import '../models/private_usd_reverse_presentation.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_engine.dart';
import '../services/private_usd_pause.dart';
import '../services/private_usd_reverse_funding.dart';
import 'private_usd_convert_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';
import 'railgun_engine_provider.dart';

/// How often the reverse progress looks at the clock: "Authorize settlement"
/// stops being offered 120 s before the ready deadline.
const kPrivateUsdReverseTick = Duration(seconds: 5);

/// A user step the reverse progress is running.
enum PrivateUsdReverseUserStep { pricing, readying, cancelling }

/// One reverse conversion as its progress screen shows it.
@immutable
class PrivateUsdReverseConversionState {
  const PrivateUsdReverseConversionState({
    required this.now,
    this.status,
    this.loaded = false,
    this.funding,
    this.proofProgress,
    this.acting,
    this.error,
  });

  final DateTime now;

  /// The engine's view of the record; null until it is known.
  final PrivateUsdReverseStatus? status;

  /// The records were read: no [status] then means no such conversion.
  final bool loaded;

  /// The payment's funding, while it runs or after it paid nothing.
  final PrivateUsdFundingState? funding;

  /// The page's proof (0..1) while it proves; null between proofs.
  final double? proofProgress;
  final PrivateUsdReverseUserStep? acting;

  /// Why the last step the user took did not go through.
  final String? error;

  bool get busy => acting != null;

  /// The line under the actions: the user's last step, else the payment's.
  String? get message {
    if (error != null) return error;
    final record = status?.record;
    if (record?.phase == rust.ApiReversePhase.awaitingFunding) {
      return funding?.error;
    }
    return null;
  }

  PrivateUsdReverseConversionState copyWith({
    DateTime? now,
    PrivateUsdReverseStatus? status,
    bool? loaded,
    PrivateUsdFundingState? funding,
    bool clearFunding = false,
    double? proofProgress,
    bool clearProofProgress = false,
    PrivateUsdReverseUserStep? acting,
    bool clearActing = false,
    String? error,
    bool clearError = false,
  }) => PrivateUsdReverseConversionState(
    now: now ?? this.now,
    status: status ?? this.status,
    loaded: loaded ?? this.loaded,
    funding: clearFunding ? null : (funding ?? this.funding),
    proofProgress: clearProofProgress
        ? null
        : (proofProgress ?? this.proofProgress),
    acting: clearActing ? null : (acting ?? this.acting),
    error: clearError ? null : (error ?? this.error),
  );
}

/// One reverse conversion's progress, driven by the foreground engine loop
/// (`reverse_advance`), with the user's steps: "Pay {debit}", "Authorize
/// settlement" and the call-off (each behind a sheet in the screen).
final privateUsdReverseConversionProvider = NotifierProvider.autoDispose
    .family<
      PrivateUsdReverseConversionNotifier,
      PrivateUsdReverseConversionState,
      PrivateUsdRecordKey
    >(PrivateUsdReverseConversionNotifier.new);

class PrivateUsdReverseConversionNotifier
    extends Notifier<PrivateUsdReverseConversionState> {
  PrivateUsdReverseConversionNotifier(this.key);

  final PrivateUsdRecordKey key;
  late DateTime Function() _clock;

  // Pricing asked for once per screen: after a refused funding the relayer's
  // new fee cleared the cost.
  bool _priced = false;

  @override
  PrivateUsdReverseConversionState build() {
    _clock = ref.watch(privateUsdConvertClockProvider);
    ref.listen(privateUsdReverseConversionsProvider.select((all) => all[key]), (
      _,
      next,
    ) {
      if (next == null) return;
      state = state.copyWith(status: next, loaded: true);
      _priceIfCleared();
    });
    ref.listen(privateUsdFundingStatesProvider.select((all) => all[key]), (
      _,
      next,
    ) {
      state = state.copyWith(funding: next, clearFunding: next == null);
    });
    // A new proof starts from none, so a second "Pay" never shows the last
    // proof's share.
    ref.listen(
      railgunEngineStateProvider.select((engine) => engine.proof?.progress),
      (_, next) => state = state.copyWith(
        proofProgress: next,
        clearProofProgress: next == null,
      ),
    );
    final tick = Timer.periodic(
      kPrivateUsdReverseTick,
      (_) => state = state.copyWith(now: _clock()),
    );
    ref.onDispose(tick.cancel);
    final status = ref.read(privateUsdReverseConversionsProvider)[key];
    scheduleMicrotask(status == null ? _load : _priceIfCleared);
    return PrivateUsdReverseConversionState(
      now: _clock(),
      status: status,
      loaded: status != null,
      funding: ref.read(privateUsdFundingStatesProvider)[key],
    );
  }

  PrivateUsdEngine get _engine => ref.read(privateUsdEngineProvider);

  Future<void> _load() async {
    try {
      await _engine.loadReverseRecords(key.accountUuid);
    } catch (error) {
      privateUsdLog('reading conversions failed (${error.runtimeType})');
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      loaded: true,
      status: ref.read(privateUsdReverseConversionsProvider)[key],
    );
    _priceIfCleared();
  }

  /// "Try now": cuts the loop's nap short.
  void retryNow() => _engine.nudge();

  /// "Pay {debit}": funds the conversion at its reviewed cost. Its proof and
  /// outcome show through the funding's state.
  void pay() {
    final record = state.status?.record;
    if (record == null ||
        state.busy ||
        record.phase != rust.ApiReversePhase.awaitingFunding ||
        record.funded ||
        record.cancelRequested ||
        record.cost == null) {
      return;
    }
    final funding = ref.read(privateUsdReverseFundingProvider);
    funding.clearError(key);
    state = state.copyWith(clearError: true);
    unawaited(funding.fund(key));
  }

  /// "Authorize settlement": only in `awaitingReady` before
  /// `readyDeadline − 120 s`. Rust signs `ready` once; a repeat sends the
  /// kept one.
  Future<void> authorizeReady() async {
    final record = state.status?.record;
    if (record == null ||
        state.busy ||
        !privateUsdCanAuthorizeReady(record, _clock())) {
      return;
    }
    state = state.copyWith(
      acting: PrivateUsdReverseUserStep.readying,
      clearError: true,
    );
    String? error;
    try {
      await _engine.reverseAuthorizeReady(key.accountUuid, index: key.index);
    } on rust.ApiPrivateUsdError catch (failure) {
      if (failure.code != rust.ApiPrivateUsdErrorCode.cancelled) {
        error = privateUsdReverseStepMessage(failure.code);
      }
    } catch (failure) {
      if (failure is! PrivateUsdPause) error = PrivateUsdCopy.reverseError;
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      clearActing: true,
      error: error,
      clearError: error == null,
    );
  }

  /// "Cancel conversion" / "Request refund", once its sheet was confirmed. It
  /// runs while a payment's proof may still run (that proof is then never
  /// submitted); a settled conversion can no longer be refunded.
  Future<void> cancel() async {
    final record = state.status?.record;
    if (record == null || state.busy) return;
    if (record.settled) {
      state = state.copyWith(error: PrivateUsdCopy.reverseRefundUnavailable);
      return;
    }
    if (!record.cancellable) return;
    state = state.copyWith(
      acting: PrivateUsdReverseUserStep.cancelling,
      clearError: true,
    );
    String? error;
    try {
      await _engine.reverseCancel(key.accountUuid, index: key.index);
      ref.read(privateUsdReverseFundingProvider).drop(key);
    } on rust.ApiPrivateUsdError catch (failure) {
      error = switch (failure.code) {
        rust.ApiPrivateUsdErrorCode.cancelled => null,
        rust.ApiPrivateUsdErrorCode.tooLate =>
          PrivateUsdCopy.reverseRefundUnavailable,
        _ => PrivateUsdCopy.convertCallOffFailed,
      };
    } catch (failure) {
      if (failure is! PrivateUsdPause) {
        error = PrivateUsdCopy.convertCallOffFailed;
      }
    }
    if (!ref.mounted) return;
    // A cancel Rust recorded stands, whatever the call said after.
    final now = ref.read(privateUsdReverseConversionsProvider)[key]?.record;
    if (now != null && now.cancelRequested && !now.settled) error = null;
    state = state.copyWith(
      clearActing: true,
      error: error,
      clearError: error == null,
    );
  }

  /// After a refused funding the relayer's new fee cleared the cost: price
  /// it again (a read and the page; no index, no key), once.
  void _priceIfCleared() {
    final record = state.status?.record;
    if (_priced ||
        record == null ||
        record.phase != rust.ApiReversePhase.awaitingFunding ||
        record.cost != null ||
        record.funded ||
        record.cancelRequested ||
        (state.funding?.running ?? false)) {
      return;
    }
    _priced = true;
    unawaited(_price());
  }

  Future<void> _price() async {
    state = state.copyWith(acting: PrivateUsdReverseUserStep.pricing);
    String? error;
    try {
      final request = await _engine.reverseCostRequest(
        key.accountUuid,
        index: key.index,
      );
      await ref
          .read(privateUsdReverseFundingProvider)
          .price(key.accountUuid, request);
    } on rust.ApiPrivateUsdError catch (failure) {
      error = privateUsdReverseStepMessage(failure.code);
    } catch (failure) {
      if (failure is! PrivateUsdPause) error = PrivateUsdCopy.reverseError;
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      clearActing: true,
      error: error,
      clearError: error == null,
    );
  }
}
