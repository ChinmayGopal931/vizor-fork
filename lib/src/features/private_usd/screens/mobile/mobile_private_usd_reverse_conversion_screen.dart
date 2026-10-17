import 'dart:async';

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../swap/models/swap_status_presentation.dart';
import '../../../swap/widgets/mobile/mobile_swap_review_header.dart';
import '../../../swap/widgets/mobile/mobile_swap_status_content.dart';
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_reverse_presentation.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_keep_awake_provider.dart';
import '../../providers/private_usd_reverse_conversion_provider.dart';
import '../../widgets/mobile/private_usd_confirm_sheets.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import '../../widgets/mobile/private_usd_logo.dart';
import 'mobile_private_usd_conversion_screen.dart' show PrivateUsdProblemCard;
import 'mobile_private_usd_convert_screen.dart' show PrivateUsdInfoButton;

/// `/private-usd/conversion/reverse/:index` (plan reference §9.4 S6, §9.5):
/// one reverse conversion's progress, with the user's two approvals ("Pay
/// {debit}" and "Authorize settlement") and the call-off behind a sheet.
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
    extends ConsumerState<MobilePrivateUsdReverseConversionScreen> {
  PrivateUsdRecordKey? _visible;
  PrivateUsdProgressVisibleNotifier? _visibility;
  var _tab = SwapStatusTab.progress;
  var _detailsExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final account = ref.read(accountProvider).value?.activeAccountUuid;
      if (account == null) return;
      final key = widget.path.keyFor(account);
      // Opening the progress resumes the loop (§5.10).
      ref.read(privateUsdEngineProvider).start();
      final visibility = ref.read(privateUsdProgressVisibleProvider.notifier);
      visibility.show(key);
      _visibility = visibility;
      _visible = key;
    });
  }

  @override
  void dispose() {
    final visibility = _visibility;
    final key = _visible;
    if (visibility != null && key != null) {
      scheduleMicrotask(() {
        try {
          visibility.hide(key);
        } catch (_) {
          // The container went first.
        }
      });
    }
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

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
        activeTab: _tab,
        detailsExpanded: _detailsExpanded,
        onTabChanged: (tab) => setState(() => _tab = tab),
        onToggleDetails: () =>
            setState(() => _detailsExpanded = !_detailsExpanded),
        onBack: holds ? null : _back,
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

/// The reverse progress screen's content for a given presentation.
/// Widgetbook, capture scenarios and tests build it directly.
class MobilePrivateUsdReverseConversionView extends StatelessWidget {
  const MobilePrivateUsdReverseConversionView({
    required this.presentation,
    required this.onBack,
    required this.onInfo,
    required this.onRetry,
    this.onAction,
    this.onCallOff,
    this.onViewRefunds,
    this.message,
    this.acting,
    this.activeTab = SwapStatusTab.progress,
    this.detailsExpanded = false,
    this.onTabChanged,
    this.onToggleDetails,
    super.key,
  });

  /// Null until the record is known.
  final PrivateUsdReverseProgressPresentation? presentation;

  /// Why the last step did not go through.
  final String? message;
  final PrivateUsdReverseUserStep? acting;
  final SwapStatusTab activeTab;
  final bool detailsExpanded;
  final ValueChanged<SwapStatusTab>? onTabChanged;
  final VoidCallback? onToggleDetails;
  final VoidCallback? onBack;
  final VoidCallback onInfo;
  final VoidCallback onRetry;
  final VoidCallback? onAction;
  final VoidCallback? onCallOff;
  final VoidCallback? onViewRefunds;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final presentation = this.presentation;
    final label = presentation?.actionLabel;
    final working =
        acting == PrivateUsdReverseUserStep.readying &&
        presentation?.action == PrivateUsdReverseAction.authorizeSettlement;
    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileTopNav.back(
              title: PrivateUsdCopy.convertProgressTitle,
              onBack: onBack,
              trailing: PrivateUsdInfoButton(onTap: onInfo),
            ),
            Expanded(
              child: presentation == null
                  ? const Center(
                      child: AppLoadingIcon(
                        key: ValueKey('mobile_private_usd_progress_loading'),
                        size: AppIconSize.large,
                      ),
                    )
                  : ListView(
                      key: const ValueKey('mobile_private_usd_progress_list'),
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.sm,
                        0,
                        AppSpacing.sm,
                        AppSpacing.lg,
                      ),
                      children: _content(context, presentation),
                    ),
            ),
            if (label != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.s,
                  AppSpacing.sm,
                  AppSpacing.md,
                ),
                child: AppButton(
                  key: const ValueKey('mobile_private_usd_progress_action'),
                  expand: true,
                  onPressed: presentation!.actionEnabled ? onAction : null,
                  leading: working
                      ? const AppLoadingIcon(size: AppIconSize.medium)
                      : null,
                  child: Text(label),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    PrivateUsdReverseProgressPresentation presentation,
  ) {
    final colors = context.colors;
    final status = presentation.status;
    final resultTitle = presentation.resultTitle;
    final note = presentation.note;
    final problem = presentation.problem;
    final callOff = presentation.callOffLabel;
    final message = this.message;
    final cancelling = acting == PrivateUsdReverseUserStep.cancelling;
    return [
      if (resultTitle != null) ...[
        const SizedBox(height: AppSpacing.s),
        MobileSurfaceCard(
          key: const ValueKey('mobile_private_usd_progress_result'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                resultTitle,
                style: AppTypography.headlineSmall.copyWith(
                  color: colors.text.accent,
                ),
              ),
              if (presentation.resultBody case final body?) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  body,
                  style: AppTypography.bodyMedium.copyWith(
                    color: colors.text.secondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
      if (note != null) ...[
        const SizedBox(height: AppSpacing.s),
        Text(
          note,
          key: const ValueKey('mobile_private_usd_progress_note'),
          style: AppTypography.bodyMedium.copyWith(color: colors.text.primary),
        ),
      ],
      if (problem != null) ...[
        const SizedBox(height: AppSpacing.s),
        PrivateUsdProblemCard(message: problem, onRetry: onRetry),
      ],
      if (message != null) ...[
        const SizedBox(height: AppSpacing.s),
        MobileWarningNotice(
          key: const ValueKey('mobile_private_usd_progress_error'),
          message: message,
        ),
      ],
      if (callOff != null) ...[
        const SizedBox(height: AppSpacing.s),
        AppButton(
          key: const ValueKey('mobile_private_usd_progress_call_off'),
          variant: AppButtonVariant.secondary,
          expand: true,
          onPressed: cancelling || acting != null ? null : onCallOff,
          leading: cancelling
              ? const AppLoadingIcon(size: AppIconSize.medium)
              : null,
          child: Text(callOff),
        ),
      ],
      if (presentation.showsViewRefunds) ...[
        const SizedBox(height: AppSpacing.s),
        AppButton(
          key: const ValueKey('mobile_private_usd_progress_refunds'),
          variant: AppButtonVariant.secondary,
          expand: true,
          onPressed: onViewRefunds,
          child: const Text(PrivateUsdCopy.refundsView),
        ),
      ],
      MobileSwapStatusContent(
        presentation: status,
        payHeaderRow: MobileSwapReviewHeaderRow(
          label: status.payLabel,
          amountText: presentation.payAmountText,
          asset: status.payAsset,
          icon: privateUsdHeaderIcon(status.payAsset),
          bottomText: PrivateUsdCopy.title,
        ),
        receiveHeaderRow: MobileSwapReviewHeaderRow(
          label: status.receiveLabel,
          amountText: presentation.receiveAmountText,
          asset: status.receiveAsset,
          icon: privateUsdHeaderIcon(status.receiveAsset),
        ),
        activeTab: activeTab,
        detailsExpanded: detailsExpanded,
        onTabChanged: onTabChanged ?? (_) {},
        onToggleDetails: onToggleDetails ?? () {},
      ),
      if (presentation.provingNote case final proving?) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          proving,
          key: const ValueKey('mobile_private_usd_progress_proving'),
          style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
        ),
      ],
      if (presentation.showsKeepOpen) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          PrivateUsdCopy.convertBackgroundNote,
          key: const ValueKey('mobile_private_usd_progress_keep_open'),
          style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
        ),
      ],
    ];
  }
}
