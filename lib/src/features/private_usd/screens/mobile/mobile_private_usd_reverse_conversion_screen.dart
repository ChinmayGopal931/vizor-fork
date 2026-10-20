import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feedback/app_haptics.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_reverse_presentation.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_reverse_conversion_provider.dart';
import '../../widgets/mobile/private_usd_confirm_sheets.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import '../../widgets/mobile/private_usd_progress_views.dart';

/// `/private-usd/conversion/reverse/:index`: one reverse conversion's
/// progress, with the user's two approvals, paying and authorizing
/// settlement, and the call-off behind a confirmation sheet.
class MobilePrivateUsdReverseConversionScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdReverseConversionScreen({
    required this.path,
    super.key,
  });

  final PrivateUsdRoutePath path;

  @override
  ConsumerState<MobilePrivateUsdReverseConversionScreen> createState() =>
      _MobilePrivateUsdReverseConversionScreenState();
}

class _MobilePrivateUsdReverseConversionScreenState
    extends ConsumerState<MobilePrivateUsdReverseConversionScreen>
    with PrivateUsdProgressScreenState {
  @override
  PrivateUsdRoutePath get path => widget.path;

  Future<void> _callOff(
    PrivateUsdReverseConversionNotifier notifier,
    PrivateUsdReverseProgressPresentation presentation,
  ) async {
    final action = presentation.callOffLabel;
    if (action == null) return;
    final confirmed = await confirmPrivateUsdReverseCancel(
      context,
      action: action,
      paid: presentation.callOffPaid,
    );
    if (!confirmed || !mounted) return;
    await notifier.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    if (account == null) return const SizedBox.shrink();
    final key = widget.path.keyFor(account);
    final state = ref.watch(privateUsdReverseConversionProvider(key));
    final status = state.status;
    if (status == null && state.loaded) {
      // No such conversion for this account: start a new one instead.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pushReplacement('/private-usd/convert?to=zec');
      });
    }
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final presentation = status == null
        ? null
        : privateUsdReverseProgressPresentation(
            status: status,
            now: state.now,
            funding: state.funding,
            proofProgress: state.proofProgress,
            busy: state.busy,
            privacyModeEnabled: ref.watch(privacyModeProvider),
            explorerTxPrefix: deployment?.explorerTxPrefix,
          );
    if (presentation != null) noteBridged(presentation.bridged);
    final notifier = ref.read(
      privateUsdReverseConversionProvider(key).notifier,
    );
    // An authorized step (settlement, the call-off) holds the screen.
    final holds =
        state.acting == PrivateUsdReverseUserStep.readying ||
        state.acting == PrivateUsdReverseUserStep.cancelling;
    return PopScope(
      canPop: !holds,
      child: MobilePrivateUsdReverseConversionView(
        presentation: presentation,
        message: state.message,
        acting: state.acting,
        celebrate: celebrate,
        onBridgedImpact: () => unawaited(AppHaptics.sendSuccess()),
        activeTab: tab,
        detailsExpanded: detailsExpanded,
        onTabChanged: selectTab,
        onToggleDetails: toggleDetails,
        onBack: holds ? null : back,
        onInfo: () => showPrivateUsdReverseInfoSheet(context),
        onRetry: notifier.retryNow,
        onAction: switch (presentation?.action) {
          PrivateUsdReverseAction.pay => notifier.pay,
          PrivateUsdReverseAction.authorizeSettlement => () => unawaited(
            notifier.authorizeReady(),
          ),
          PrivateUsdReverseAction.newConversion =>
            () => context.pushReplacement('/private-usd/convert?to=zec'),
          null => null,
        },
        onCallOff: presentation == null
            ? null
            : () => unawaited(_callOff(notifier, presentation)),
        onViewRefunds: () => context.push('/private-usd/refunds'),
      ),
    );
  }
}
