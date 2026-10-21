import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../providers/account_provider.dart';
import '../../../swap/domain/swap_asset.dart';
import '../../../swap/models/swap_activity_status_mapper.dart';
import '../../../swap/models/swap_status_presentation.dart';
import '../../../swap/widgets/mobile/mobile_swap_review_header.dart';
import '../../../swap/widgets/mobile/mobile_swap_status_content.dart';
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_reverse_presentation.dart';
import '../../models/private_usd_status_presentation.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_keep_awake_provider.dart';
import '../../providers/private_usd_reverse_conversion_provider.dart';
import 'private_usd_bridged_hero.dart';
import 'private_usd_flow_widgets.dart';
import 'private_usd_logo.dart';

const _loading = Center(
  child: AppLoadingIcon(
    key: ValueKey('mobile_private_usd_progress_loading'),
    size: AppIconSize.large,
  ),
);

/// The forward progress for a presentation; null until the record is known.
class MobilePrivateUsdConversionView extends StatelessWidget {
  const MobilePrivateUsdConversionView({
    required this.presentation,
    required this.onBack,
    required this.onInfo,
    required this.onRetry,
    required this.onCallOff,
    required this.onViewBalance,
    required this.onTryAgain,
    this.callingOff = false,
    this.callOffError,
    this.celebrate = false,
    this.onBridgedImpact,
    this.activeTab = SwapStatusTab.progress,
    this.detailsExpanded = false,
    this.onTabChanged,
    this.onToggleDetails,
    super.key,
  });

  final PrivateUsdProgressPresentation? presentation;
  final bool callingOff;
  final String? callOffError;

  /// Switches [PrivateUsdBridgedHero] on, with its shockwave: the bridge
  /// finished while it showed.
  final bool celebrate;

  /// As the sign lights, for the success haptic.
  final VoidCallback? onBridgedImpact;
  final SwapStatusTab activeTab;
  final bool detailsExpanded;
  final ValueChanged<SwapStatusTab>? onTabChanged;
  final VoidCallback? onToggleDetails;
  final VoidCallback? onBack;

  /// Null without a deployment, whose numbers the info sheet states.
  final VoidCallback? onInfo;
  final VoidCallback onRetry;
  final VoidCallback onCallOff;
  final VoidCallback onViewBalance;
  final VoidCallback onTryAgain;

  @override
  Widget build(BuildContext context) {
    final presentation = this.presentation;
    final action = presentation?.action;
    final error = callOffError;
    return PrivateUsdFlowScaffold(
      title: presentation?.title ?? PrivateUsdCopy.convertProgressTitle,
      onBack: onBack,
      onInfo: onInfo,
      body: presentation == null
          ? _loading
          : PrivateUsdProgressBody(
              status: presentation.status,
              payAmountText: presentation.payAmountText,
              receiveAmountText: presentation.receiveAmountText,
              bridged: presentation.bridged,
              celebrate: celebrate,
              onBridgedImpact: onBridgedImpact,
              resultTitle: presentation.resultTitle,
              resultBody: presentation.resultBody,
              note: presentation.note,
              problem: presentation.problem,
              onRetry: onRetry,
              actions: [
                if (presentation.showsCallOff)
                  AppButton(
                    key: const ValueKey('mobile_private_usd_progress_call_off'),
                    variant: AppButtonVariant.secondary,
                    expand: true,
                    onPressed: callingOff ? null : onCallOff,
                    leading: callingOff
                        ? const AppLoadingIcon(size: AppIconSize.medium)
                        : null,
                    child: const Text(PrivateUsdCopy.convertCallOff),
                  ),
                if (error != null)
                  MobileWarningNotice(
                    key: const ValueKey('mobile_private_usd_progress_error'),
                    message: error,
                  ),
              ],
              showsKeepOpen: presentation.showsKeepOpen,
              activeTab: activeTab,
              detailsExpanded: detailsExpanded,
              onTabChanged: onTabChanged,
              onToggleDetails: onToggleDetails,
            ),
      action: action == null
          ? null
          : AppButton(
              key: const ValueKey('mobile_private_usd_progress_action'),
              expand: true,
              onPressed: switch (action) {
                PrivateUsdProgressAction.viewBalance => onViewBalance,
                PrivateUsdProgressAction.tryAgain => onTryAgain,
              },
              child: Text(switch (action) {
                PrivateUsdProgressAction.viewBalance =>
                  PrivateUsdCopy.convertResultViewBalance,
                PrivateUsdProgressAction.tryAgain =>
                  PrivateUsdCopy.convertResultTryAgain,
              }),
            ),
    );
  }
}

/// The reverse progress for a presentation; null until the record is known.
/// The user's two approvals are its action, and the call-off its own button.
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
    this.celebrate = false,
    this.onBridgedImpact,
    this.activeTab = SwapStatusTab.progress,
    this.detailsExpanded = false,
    this.onTabChanged,
    this.onToggleDetails,
    super.key,
  });

  final PrivateUsdReverseProgressPresentation? presentation;

  /// Why the last step did not go through.
  final String? message;
  final PrivateUsdReverseUserStep? acting;

  /// Switches [PrivateUsdBridgedHero] on, with its shockwave: the bridge
  /// finished while it showed.
  final bool celebrate;

  /// As the sign lights, for the success haptic.
  final VoidCallback? onBridgedImpact;
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
    final presentation = this.presentation;
    final label = presentation?.actionLabel;
    final message = this.message;
    final callOff = presentation?.callOffLabel;
    final cancelling = acting == PrivateUsdReverseUserStep.cancelling;
    final working =
        acting == PrivateUsdReverseUserStep.readying &&
        presentation?.action == PrivateUsdReverseAction.authorizeSettlement;
    return PrivateUsdFlowScaffold(
      title: presentation?.title ?? PrivateUsdCopy.convertProgressTitle,
      onBack: onBack,
      onInfo: onInfo,
      body: presentation == null
          ? _loading
          : PrivateUsdProgressBody(
              status: presentation.status,
              payAmountText: presentation.payAmountText,
              receiveAmountText: presentation.receiveAmountText,
              bridged: presentation.bridged,
              celebrate: celebrate,
              onBridgedImpact: onBridgedImpact,
              resultTitle: presentation.resultTitle,
              resultBody: presentation.resultBody,
              note: presentation.note,
              problem: presentation.problem,
              onRetry: onRetry,
              actions: [
                if (message != null)
                  MobileWarningNotice(
                    key: const ValueKey('mobile_private_usd_progress_error'),
                    message: message,
                  ),
                if (callOff != null)
                  AppButton(
                    key: const ValueKey('mobile_private_usd_progress_call_off'),
                    variant: AppButtonVariant.secondary,
                    expand: true,
                    onPressed: acting != null ? null : onCallOff,
                    leading: cancelling
                        ? const AppLoadingIcon(size: AppIconSize.medium)
                        : null,
                    child: Text(callOff),
                  ),
                if (presentation.showsViewRefunds)
                  AppButton(
                    key: const ValueKey('mobile_private_usd_progress_refunds'),
                    variant: AppButtonVariant.secondary,
                    expand: true,
                    onPressed: onViewRefunds,
                    child: const Text(PrivateUsdCopy.refundsView),
                  ),
              ],
              provingNote: presentation.provingNote,
              showsKeepOpen: presentation.showsKeepOpen,
              activeTab: activeTab,
              detailsExpanded: detailsExpanded,
              onTabChanged: onTabChanged,
              onToggleDetails: onToggleDetails,
            ),
      action: label == null
          ? null
          : AppButton(
              key: const ValueKey('mobile_private_usd_progress_action'),
              expand: true,
              onPressed: presentation!.actionEnabled ? onAction : null,
              leading: working
                  ? const AppLoadingIcon(size: AppIconSize.medium)
                  : null,
              child: Text(label),
            ),
    );
  }
}

/// A conversion's progress, both directions: the finished sign or the
/// result, the note, the problem card, the direction's own [actions], the
/// steps with their details, and the notes under them.
class PrivateUsdProgressBody extends StatelessWidget {
  const PrivateUsdProgressBody({
    required this.status,
    required this.payAmountText,
    required this.receiveAmountText,
    required this.onRetry,
    this.bridged = false,
    this.celebrate = false,
    this.onBridgedImpact,
    this.resultTitle,
    this.resultBody,
    this.note,
    this.problem,
    this.actions = const [],
    this.provingNote,
    this.showsKeepOpen = false,
    this.activeTab = SwapStatusTab.progress,
    this.detailsExpanded = false,
    this.onTabChanged,
    this.onToggleDetails,
    super.key,
  });

  final SwapActivityStatusPresentation status;
  final String payAmountText;
  final String receiveAmountText;
  final VoidCallback onRetry;

  /// It finished, screened: [PrivateUsdBridgedHero] stands for the result
  /// card.
  final bool bridged;
  final bool celebrate;
  final VoidCallback? onBridgedImpact;
  final String? resultTitle;
  final String? resultBody;
  final String? note;

  /// The problem card's message, once steps have failed for a minute.
  final String? problem;
  final List<Widget> actions;

  /// Under the steps while the page proves a payment.
  final String? provingNote;
  final bool showsKeepOpen;
  final SwapStatusTab activeTab;
  final bool detailsExpanded;
  final ValueChanged<SwapStatusTab>? onTabChanged;
  final VoidCallback? onToggleDetails;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final resultTitle = this.resultTitle;
    final note = this.note;
    final problem = this.problem;
    final provingNote = this.provingNote;
    final footnote = AppTypography.bodySmall.copyWith(
      color: colors.text.secondary,
    );
    return ListView(
      key: const ValueKey('mobile_private_usd_progress_list'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        AppSpacing.lg,
      ),
      children: [
        if (bridged)
          PrivateUsdBridgedHero(
            body: resultBody ?? '',
            celebrate: celebrate,
            onImpact: onBridgedImpact,
          )
        else if (resultTitle != null) ...[
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
                if (resultBody case final body?) ...[
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
            style: AppTypography.bodyMedium.copyWith(
              color: colors.text.primary,
            ),
          ),
        ],
        if (problem != null) ...[
          const SizedBox(height: AppSpacing.s),
          PrivateUsdProblemCard(message: problem, onRetry: onRetry),
        ],
        for (final action in actions) ...[
          const SizedBox(height: AppSpacing.s),
          action,
        ],
        MobileSwapStatusContent(
          presentation: status,
          payHeaderRow: _headerRow(
            status.payLabel,
            payAmountText,
            status.payAsset,
          ),
          receiveHeaderRow: _headerRow(
            status.receiveLabel,
            receiveAmountText,
            status.receiveAsset,
          ),
          headerToBodyGap: AppSpacing.xs,
          activeTab: activeTab,
          detailsExpanded: detailsExpanded,
          onTabChanged: onTabChanged ?? (_) {},
          onToggleDetails: onToggleDetails ?? () {},
        ),
        if (provingNote != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            provingNote,
            key: const ValueKey('mobile_private_usd_progress_proving'),
            style: footnote,
          ),
        ],
        if (showsKeepOpen) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            PrivateUsdCopy.convertBackgroundNote,
            key: const ValueKey('mobile_private_usd_progress_keep_open'),
            style: footnote,
          ),
        ],
      ],
    );
  }

  // Private USD's logo stands for USDC on Ethereum, and each amount is
  // named for the side it is on.
  static MobileSwapReviewHeaderRow _headerRow(
    String label,
    String amountText,
    SwapAsset asset,
  ) => MobileSwapReviewHeaderRow(
    label: label,
    amountText: amountText,
    asset: asset,
    icon: privateUsdHeaderIcon(asset),
    bottomText: asset == SwapAsset.zec
        ? PrivateUsdCopy.shieldedZec
        : PrivateUsdCopy.title,
  );
}

/// The problem card, once a conversion's steps have failed for a minute:
/// why, and a retry now.
class PrivateUsdProblemCard extends StatelessWidget {
  const PrivateUsdProblemCard({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_progress_problem'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.warning,
                size: AppIconSize.medium,
                color: colors.text.warning,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  PrivateUsdCopy.convertProblemTitle,
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.text.accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            message,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          AppButton(
            key: const ValueKey('mobile_private_usd_progress_retry'),
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.medium,
            onPressed: onRetry,
            child: const Text(PrivateUsdCopy.convertProblemRetry),
          ),
        ],
      ),
    );
  }
}

/// What both progress screens' states share: opening the progress resumes
/// the engine and marks it visible, which keeps the screen awake through a
/// key step; a bridge that finishes in view plays its sign.
mixin PrivateUsdProgressScreenState<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  PrivateUsdRoutePath get path;

  PrivateUsdRecordKey? _visible;
  PrivateUsdProgressVisibleNotifier? _visibility;
  bool? _wasBridged;

  SwapStatusTab tab = SwapStatusTab.progress;
  bool detailsExpanded = false;

  /// The bridge finished in view, not opened finished: its sign plays.
  bool celebrate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final account = ref.read(accountProvider).value?.activeAccountUuid;
      if (account == null) return;
      final key = path.keyFor(account);
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
      // After the frame: the keep-awake host listens to it.
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

  /// Follows whether the progress shows as bridged.
  void noteBridged(bool bridged) {
    if (bridged && _wasBridged == false) celebrate = true;
    _wasBridged = bridged;
  }

  void selectTab(SwapStatusTab next) => setState(() => tab = next);

  void toggleDetails() => setState(() => detailsExpanded = !detailsExpanded);

  void back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }
}
