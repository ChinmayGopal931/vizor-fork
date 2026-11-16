import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_record_key.dart';
import '../models/private_usd_reverse_presentation.dart';
import '../models/private_usd_status_presentation.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_engine.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_convert_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';
import '../../../core/l10n/l10n.dart';

/// How often the progress screen looks at the clock (the slow opening and
/// the maker's deadline notes).
const kPrivateUsdProgressTick = Duration(seconds: 15);

/// One conversion as its progress screen shows it.
@immutable
class PrivateUsdConversionState {
  const PrivateUsdConversionState({
    required this.now,
    this.status,
    this.loaded = false,
    this.callingOff = false,
    this.callOffError,
  });

  /// The engine's view of the record; null until it is known.
  final PrivateUsdConversionStatus? status;

  /// The account's records were read: no [status] then means no such
  /// conversion.
  final bool loaded;
  final DateTime now;
  final bool callingOff;
  final PrivateUsdText? callOffError;

  PrivateUsdConversionState copyWith({
    PrivateUsdConversionStatus? status,
    bool? loaded,
    DateTime? now,
    bool? callingOff,
    PrivateUsdText? callOffError,
    bool clearCallOffError = false,
  }) => PrivateUsdConversionState(
    status: status ?? this.status,
    loaded: loaded ?? this.loaded,
    now: now ?? this.now,
    callingOff: callingOff ?? this.callingOff,
    callOffError: clearCallOffError
        ? null
        : (callOffError ?? this.callOffError),
  );
}

/// One conversion's progress, driven by the foreground engine loop: it
/// follows the engine's snapshot, reads the records once if the engine has
/// not, and offers "Try now" and "Call it off".
final privateUsdConversionProvider = NotifierProvider.autoDispose
    .family<
      PrivateUsdConversionNotifier,
      PrivateUsdConversionState,
      PrivateUsdRecordKey
    >(PrivateUsdConversionNotifier.new);

class PrivateUsdConversionNotifier extends Notifier<PrivateUsdConversionState> {
  PrivateUsdConversionNotifier(this.key);

  final PrivateUsdRecordKey key;

  @override
  PrivateUsdConversionState build() {
    final clock = ref.watch(privateUsdConvertClockProvider);
    ref.listen(privateUsdConversionsProvider.select((all) => all[key]), (
      _,
      next,
    ) {
      if (next != null) state = state.copyWith(status: next, loaded: true);
    });
    final tick = Timer.periodic(
      kPrivateUsdProgressTick,
      (_) => state = state.copyWith(now: clock()),
    );
    ref.onDispose(tick.cancel);
    final status = ref.read(privateUsdConversionsProvider)[key];
    if (status == null) scheduleMicrotask(_load);
    return PrivateUsdConversionState(
      now: clock(),
      status: status,
      loaded: status != null,
    );
  }

  Future<void> _load() async {
    try {
      await ref.read(privateUsdEngineProvider).loadRecords(key.accountUuid);
    } catch (error) {
      privateUsdLog('reading conversions failed (${error.runtimeType})');
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      loaded: true,
      status: ref.read(privateUsdConversionsProvider)[key],
    );
  }

  /// "Try now": cuts the loop's nap short.
  void retryNow() => ref.read(privateUsdEngineProvider).nudge();

  /// "Call it off": only before anything reached the chain.
  Future<void> callOff() async {
    if (state.callingOff) return;
    state = state.copyWith(callingOff: true, clearCallOffError: true);
    PrivateUsdText? error;
    try {
      await ref
          .read(privateUsdEngineProvider)
          .abandon(key.accountUuid, index: key.index);
    } on rust.ApiPrivateUsdError catch (failure) {
      error = failure.code == rust.ApiPrivateUsdErrorCode.tooLate
          ? (l10n) => l10n.privateUsdConvertCallOffTooLate
          : (l10n) => l10n.privateUsdConvertCallOffFailed;
    } catch (_) {
      error = (l10n) => l10n.privateUsdConvertCallOffFailed;
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      callingOff: false,
      callOffError: error,
      clearCallOffError: error == null,
    );
  }
}

/// The in-flight conversion banner: its progress route and the conversion,
/// whose stage the widget puts into words ([title], [detail]).
@immutable
class PrivateUsdBannerState {
  const PrivateUsdBannerState.forward({
    required this.path,
    required PrivateUsdConversionStatus this.forward,
    required this.zcashConfirmations,
    required this.attention,
    this.claimHandedOver = false,
  }) : reverse = null;

  const PrivateUsdBannerState.reverse({
    required this.path,
    required rust.ApiReverseRecord this.reverse,
    required this.attention,
  }) : forward = null,
       zcashConfirmations = 0,
       claimHandedOver = false;

  final PrivateUsdRoutePath path;

  /// The forward conversion under way; null for a reverse one.
  final PrivateUsdConversionStatus? forward;

  /// The reverse conversion's record; null for a forward one.
  final rust.ApiReverseRecord? reverse;

  /// The confirmations a forward deposit waits for.
  final int zcashConfirmations;
  final bool attention;

  /// The relayer holds the claim: the user can leave.
  final bool claimHandedOver;

  String title(AppLocalizations l10n) => attention
      ? l10n.privateUsdBannerAttention
      : forward != null
      ? l10n.privateUsdConvertingToUsd
      : l10n.privateUsdConvertingToZec;

  /// The stage it is at.
  String detail(AppLocalizations l10n) {
    final forward = this.forward;
    return forward != null
        ? privateUsdForwardStageLabel(
            l10n,
            forward,
            zcashConfirmations: zcashConfirmations,
          )
        : privateUsdReverseStageLabel(l10n, reverse!);
  }

  // The engine replaces a conversion's status as it changes, so the same
  // objects mean the same words.
  @override
  bool operator ==(Object other) =>
      other is PrivateUsdBannerState &&
      other.path == path &&
      identical(other.forward, forward) &&
      identical(other.reverse, reverse) &&
      other.zcashConfirmations == zcashConfirmations &&
      other.attention == attention &&
      other.claimHandedOver == claimHandedOver;

  @override
  int get hashCode => Object.hash(
    path,
    identityHashCode(forward),
    identityHashCode(reverse),
    zcashConfirmations,
    attention,
    claimHandedOver,
  );
}

/// [accountUuid]'s conversion under way as a banner, or null. It stays while
/// a conversion is unfinished, even when Private USD is otherwise
/// unavailable: only one runs at a time per account.
final privateUsdConversionBannerProvider = Provider.autoDispose
    .family<PrivateUsdBannerState?, String>((ref, accountUuid) {
      final status = ref.watch(
        privateUsdConversionsProvider.select((all) {
          for (final entry in all.entries) {
            if (entry.key.accountUuid == accountUuid &&
                entry.value.isUnderWay) {
              return entry;
            }
          }
          return null;
        }),
      );
      if (status == null) return _reverseBanner(ref, accountUuid);
      final confirmations =
          ref.watch(privateUsdCurrentDeploymentProvider)?.zcashConfirmations ??
          2;
      final attention = status.value.problem != null;
      return PrivateUsdBannerState.forward(
        path: status.key.path,
        forward: status.value,
        zcashConfirmations: confirmations,
        attention: attention,
        claimHandedOver: status.value.claimHandedOver,
      );
    });

/// [accountUuid]'s reverse conversion under way as a banner: it asks for
/// attention while it waits on the user's payment or settlement approval
/// (`needs_you`), or once its steps keep failing.
PrivateUsdBannerState? _reverseBanner(Ref ref, String accountUuid) {
  final entry = ref.watch(
    privateUsdReverseConversionsProvider.select((all) {
      for (final entry in all.entries) {
        if (entry.key.accountUuid == accountUuid && entry.value.isUnderWay) {
          return entry;
        }
      }
      return null;
    }),
  );
  if (entry == null) return null;
  final status = entry.value;
  final attention = status.needsYou || status.problem != null;
  return PrivateUsdBannerState.reverse(
    path: entry.key.path,
    reverse: status.record,
    attention: attention,
  );
}
