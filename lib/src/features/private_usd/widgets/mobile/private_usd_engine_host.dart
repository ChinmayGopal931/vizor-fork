import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_send_provider.dart';
import '../../providers/private_usd_settlement_reminder_provider.dart';

/// Keeps the Private USD engine alive for the app's lifetime, with the
/// sender, which settles the sends a crash or a kill left unconfirmed, and
/// the settlement reminder. The engine advances every account's conversions
/// while the app is in the foreground and unlocked, and follows the lock and
/// the lifecycle itself. Inert unless the build has Private USD, the Railgun
/// page runs here and the network has a deployment; desktop never builds an
/// engine.
class PrivateUsdEngineHost extends ConsumerWidget {
  const PrivateUsdEngineHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(privateUsdEngineEnabledProvider)) {
      ref.watch(privateUsdEngineProvider);
      ref.watch(privateUsdSenderProvider);
      ref.watch(privateUsdSettlementReminderProvider);
    }
    return child;
  }
}
