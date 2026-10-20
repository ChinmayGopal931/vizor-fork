import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/feedback/app_haptics.dart';
import '../../../providers/app_foreground_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../rust/api/private_usd.dart' show ApiReverseRecord;
import '../models/private_usd_record_key.dart';
import '../models/private_usd_reverse_presentation.dart';
import 'private_usd_reverse_conversion_provider.dart';
import 'private_usd_unfinished_provider.dart';

/// How long before "Authorize settlement" closes the phone buzzes again.
const kPrivateUsdSettlementWarning = Duration(minutes: 2);

/// A buzz a USD → ZEC conversion is due: the user's turn, once "Authorize
/// settlement" is first offered, or its closing within
/// [kPrivateUsdSettlementWarning] while still unauthorized.
enum PrivateUsdSettlementBuzz { none, offered, closing }

/// Which buzz [record] is due at [now], given whether its offer and its
/// closing were buzzed for already. Each buzzes once; a closing buzz also
/// stands for an offer it falls on, so the two never come together.
PrivateUsdSettlementBuzz privateUsdSettlementBuzzDue(
  ApiReverseRecord record,
  DateTime now, {
  required bool offerBuzzed,
  required bool closingBuzzed,
}) {
  if (!privateUsdCanAuthorizeReady(record, now)) {
    return PrivateUsdSettlementBuzz.none;
  }
  final closing =
      privateUsdReadyBy(record).difference(now) <= kPrivateUsdSettlementWarning;
  if (closing && !closingBuzzed) return PrivateUsdSettlementBuzz.closing;
  if (!offerBuzzed) return PrivateUsdSettlementBuzz.offered;
  return PrivateUsdSettlementBuzz.none;
}

/// Buzzes ([AppHaptics.settlementDeadline], a hold that fades out) when a
/// USD → ZEC conversion first offers "Authorize settlement", the user's turn
/// mid-conversion, and again when it comes within
/// [kPrivateUsdSettlementWarning] of its cut-off (`readyDeadline − 120 s`)
/// still unauthorized ([privateUsdSettlementBuzzDue]). For every account's
/// conversions as the engine publishes them. Only while the app is in the
/// foreground and unlocked: there is no background work or notification, so
/// a closed app cannot buzz, and a step offered while the app was away
/// buzzes on its return. `PrivateUsdEngineHost` keeps it alive.
final privateUsdSettlementReminderProvider = Provider<void>((ref) {
  final offered = <PrivateUsdRecordKey>{};
  final closing = <PrivateUsdRecordKey>{};
  void check() {
    if (!ref.read(appInForegroundProvider) ||
        ref.read(appSecurityProvider).requiresUnlock) {
      return;
    }
    final now = DateTime.now();
    final reverse = ref.read(privateUsdReverseConversionsProvider);
    for (final MapEntry(:key, value: status) in reverse.entries) {
      final due = privateUsdSettlementBuzzDue(
        status.record,
        now,
        offerBuzzed: offered.contains(key),
        closingBuzzed: closing.contains(key),
      );
      if (due == PrivateUsdSettlementBuzz.none) continue;
      offered.add(key);
      if (due == PrivateUsdSettlementBuzz.closing) closing.add(key);
      unawaited(AppHaptics.settlementDeadline());
      return;
    }
  }

  final timer = Timer.periodic(kPrivateUsdReverseTick, (_) => check());
  ref.onDispose(timer.cancel);
});
