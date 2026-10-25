import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../providers/privacy_mode_provider.dart';
import '../../models/private_usd_record_key.dart';
import '../../providers/private_usd_convert_provider.dart';
import '../../providers/private_usd_relayer_claims_provider.dart';
import '../../providers/private_usd_tokens_provider.dart';
import '../../providers/private_usd_reverse_convert_provider.dart';
import '../../widgets/mobile/private_usd_convert_views.dart';
import 'mobile_private_usd_convert_screen.dart';

/// `/private-usd/convert/review`: the reviewed quote, and the button that
/// bridges. It pops with the conversion's route once accepted, or found
/// under way after an accept that may have opened it, and the convert screen
/// replaces itself with that progress.
class MobilePrivateUsdConvertReviewScreen extends ConsumerWidget {
  const MobilePrivateUsdConvertReviewScreen({required this.args, super.key});

  final PrivateUsdReviewArgs args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    if (args.direction == PrivateUsdDirection.reverse) {
      final state = ref.watch(privateUsdReverseConvertProvider);
      final notifier = ref.read(privateUsdReverseConvertProvider.notifier);
      return _guarded(
        context,
        reviewable: state.draft != null,
        confirming: state.isConfirming,
        notifier: notifier,
        view: (onBack) => MobilePrivateUsdReverseReviewView(
          state: state,
          privacyModeEnabled: privacyModeEnabled,
          torOffDisclosure: ref.watch(privateUsdTokensTorOffDisclosureProvider),
          onBack: onBack,
          onConfirm: () => _confirm(context, notifier.confirm),
          onRefreshQuote: notifier.refreshQuote,
        ),
      );
    }
    final state = ref.watch(privateUsdConvertProvider);
    final notifier = ref.read(privateUsdConvertProvider.notifier);
    final relayerClaims =
        ref.watch(privateUsdRelayerClaimsProvider).value ?? true;
    return _guarded(
      context,
      reviewable: state.quote != null,
      confirming: state.isConfirming,
      notifier: notifier,
      view: (onBack) => MobilePrivateUsdConvertReviewView(
        state: state,
        privacyModeEnabled: privacyModeEnabled,
        relayerClaims: relayerClaims,
        torOffDisclosure: ref.watch(privateUsdTokensTorOffDisclosureProvider),
        onBack: onBack,
        onConfirm: () => _confirm(context, notifier.confirm),
        onRefreshQuote: notifier.refreshQuote,
      ),
    );
  }

  /// Back leaves the review, never while it confirms. Reopened without its
  /// flow (a stale stack) there is nothing to review, and back just pops.
  Widget _guarded<S extends PrivateUsdConvertFlowState<S>>(
    BuildContext context, {
    required bool reviewable,
    required bool confirming,
    required PrivateUsdConvertFlowNotifier<S> notifier,
    required Widget Function(VoidCallback onBack) view,
  }) {
    if (!reviewable) return view(() => context.pop());
    return PopScope(
      canPop: !confirming,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) notifier.leaveReview();
      },
      child: view(() {
        if (notifier.leaveReview()) context.pop();
      }),
    );
  }

  Future<void> _confirm(
    BuildContext context,
    Future<PrivateUsdRoutePath?> Function() confirm,
  ) async {
    final path = await confirm();
    if (path != null && context.mounted) {
      context.pop<PrivateUsdRoutePath>(path);
    }
  }
}
