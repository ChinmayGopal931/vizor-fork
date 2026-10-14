import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_record_key.dart';
import '../models/private_usd_status_presentation.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_engine.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_convert_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';

/// How often the progress screen looks at the clock (the slow opening and
/// the maker's deadline notes).
const kPrivateUsdProgressTick = Duration(seconds: 15);

/// One conversion as its progress screen shows it (plan reference §9.4 S5).
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
  final String? callOffError;

  PrivateUsdConversionState copyWith({
    PrivateUsdConversionStatus? status,
    bool? loaded,
    DateTime? now,
    bool? callingOff,
    String? callOffError,
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

/// One conversion's progress, driven by the foreground engine loop (§8.2
/// `forward_advance`): it follows the engine's snapshot, reads the records
/// once if the engine has not, and offers "Try now" and "Call it off".
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
      if (kDebugMode) debugPrint('privateUsd: reading conversions failed');
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      loaded: true,
      status: ref.read(privateUsdConversionsProvider)[key],
    );
  }

  /// "Try now": cuts the loop's nap short.
  void retryNow() => ref.read(privateUsdEngineProvider).nudge();

  /// "Call it off" (§5.6 step 12): only before anything reached the chain.
  Future<void> callOff() async {
    if (state.callingOff) return;
    state = state.copyWith(callingOff: true, clearCallOffError: true);
    String? error;
    try {
      await ref
          .read(privateUsdEngineProvider)
          .abandon(key.accountUuid, index: key.index);
    } on rust.ApiPrivateUsdError catch (failure) {
      error = failure.code == rust.ApiPrivateUsdErrorCode.tooLate
          ? PrivateUsdCopy.convertCallOffTooLate
          : PrivateUsdCopy.convertCallOffFailed;
    } catch (_) {
      error = PrivateUsdCopy.convertCallOffFailed;
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      callingOff: false,
      callOffError: error,
      clearCallOffError: error == null,
    );
  }
}

/// The in-flight conversion banner (plan reference §9.4 S1): its progress
/// route, the title, and the stage it is at.
@immutable
class PrivateUsdBannerState {
  const PrivateUsdBannerState({
    required this.path,
    required this.title,
    required this.detail,
    required this.attention,
  });

  final PrivateUsdRoutePath path;
  final String title;
  final String detail;
  final bool attention;

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdBannerState &&
      other.path == path &&
      other.title == title &&
      other.detail == detail &&
      other.attention == attention;

  @override
  int get hashCode => Object.hash(path, title, detail, attention);
}

/// [accountUuid]'s conversion under way as a banner, or null. It stays while
/// a conversion is unfinished, even when Private USD is otherwise unavailable
/// (D16): only one runs at a time per account.
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
      if (status == null) return null;
      final confirmations =
          ref.watch(privateUsdCurrentDeploymentProvider)?.zcashConfirmations ??
          2;
      final attention = status.value.problem != null;
      return PrivateUsdBannerState(
        path: status.key.path,
        title: attention
            ? PrivateUsdCopy.bannerAttention
            : PrivateUsdCopy.bannerToUsd,
        detail: privateUsdForwardStageLabel(
          status.value,
          zcashConfirmations: confirmations,
        ),
        attention: attention,
      );
    });
