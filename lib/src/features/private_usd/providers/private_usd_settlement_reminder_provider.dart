import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/feedback/app_haptics.dart';
import '../../../providers/app_foreground_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../models/private_usd_record_key.dart';
import '../models/private_usd_reverse_presentation.dart';
import 'private_usd_reverse_conversion_provider.dart';
import 'private_usd_unfinished_provider.dart';

/// How long before "Authorize settlement" closes the phone buzzes.
const kPrivateUsdSettlementWarning = Duration(minutes: 2);

/// Buzzes once per conversion ([AppHaptics.settlementDeadline], a hold that
/// fades out) when a USD → ZEC conversion still waiting for "Authorize
/// settlement" comes within [kPrivateUsdSettlementWarning] of its cut-off
/// (`readyDeadline − 120 s`), for every account's conversions as the engine
/// publishes them (D14). Only while Veylor is in the foreground and
/// unlocked: there is no background work or notification (D9), so a closed
/// app cannot buzz. `PrivateUsdEngineHost` keeps it alive.
final privateUsdSettlementReminderProvider = Provider<void>((ref) {
  final warned = <PrivateUsdRecordKey>{};
  void check() {
    if (!ref.read(appInForegroundProvider) ||
        ref.read(appSecurityProvider).requiresUnlock) {
      return;
    }
    final now = DateTime.now();
    final reverse = ref.read(privateUsdReverseConversionsProvider);
    for (final MapEntry(:key, value: status) in reverse.entries) {
      final record = status.record;
      if (warned.contains(key) ||
          !privateUsdCanAuthorizeReady(record, now) ||
          privateUsdReadyBy(record).difference(now) >
              kPrivateUsdSettlementWarning) {
        continue;
      }
      warned.add(key);
      unawaited(AppHaptics.settlementDeadline());
      return;
    }
  }

  final timer = Timer.periodic(kPrivateUsdReverseTick, (_) => check());
  ref.onDispose(timer.cancel);
});
