import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/private_usd/providers/private_usd_engine_provider.dart';

/// Starts the Private USD swap engine (plan reference §5.10) for the app's
/// lifetime: it keeps advancing every account's conversions under way while
/// the app is open, in the foreground and unlocked (D9, D14). Inert unless
/// the build has Private USD, is mobile and runs on Android, and the network
/// has a deployment; desktop never builds an engine.
///
/// The engine itself listens to the lock and the app lifecycle; this widget
/// only keeps it alive.
class PrivateUsdEngineHost extends ConsumerWidget {
  const PrivateUsdEngineHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(privateUsdEngineEnabledProvider)) {
      ref.watch(privateUsdEngineProvider);
    }
    return child;
  }
}
