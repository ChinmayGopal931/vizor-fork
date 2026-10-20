import 'dart:async';

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feedback/app_haptics.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../rust/api/private_usd.dart' show ApiForwardOutcome;
import '../../../swap/models/swap_status_presentation.dart';
import '../../../swap/widgets/mobile/mobile_swap_review_header.dart';
import '../../../swap/widgets/mobile/mobile_swap_status_content.dart';
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_status_presentation.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_conversion_provider.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_keep_awake_provider.dart';
import '../../services/private_usd_balance_repository.dart';
import '../../widgets/mobile/private_usd_bridged_hero.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import '../../widgets/mobile/private_usd_logo.dart';
import 'mobile_private_usd_convert_screen.dart';

/// `/private-usd/conversion/:direction/:index` (plan reference §9.4 S5,
/// §9.5): one conversion's progress, driven by the foreground engine loop.
/// The route carries its key, so a cold start, the banner and a deep link
/// open it alike; it pairs the path with the active account.
class MobilePrivateUsdConversionScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdConversionScreen({required this.path, super.key});

  final PrivateUsdRoutePath path;

  @override
  ConsumerState<MobilePrivateUsdConversionScreen> createState() =>
      _MobilePrivateUsdConversionScreenState();
}

class _MobilePrivateUsdConversionScreenState
    extends ConsumerState<MobilePrivateUsdConversionScreen> {
  PrivateUsdRecordKey? _visible;
  PrivateUsdProgressVisibleNotifier? _visibility;
  var _tab = SwapStatusTab.progress;
  var _detailsExpanded = false;

  /// Whether the last presentation shown was bridged; null before one.
  bool? _wasBridged;

  /// The bridge finished in view (not opened finished): its sign plays.
  var _celebrate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = _key;
      if (key == null) return;
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

  PrivateUsdRecordKey? get _key {
    final account = ref.read(accountProvider).value?.activeAccountUuid;
    return account == null ? null : widget.path.keyFor(account);
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  void _viewBalance() {
    final router = GoRouter.of(context);
    router.go('/home');
    unawaited(router.push<void>('/private-usd'));
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    if (account == null) return const SizedBox.shrink();
    final key = widget.path.keyFor(account);
    final state = ref.watch(privateUsdConversionProvider(key));
    final status = state.status;
    if (status == null && state.loaded) {
      // No such conversion for this account: start a new one instead.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pushReplacement('/private-usd/convert');
      });
    }
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final screening = Duration(seconds: deployment?.screeningSeconds ?? 0);
    final confirmations = deployment?.zcashConfirmations ?? 2;
    final paid = status?.record.outcome == ApiForwardOutcome.paid;
    final balance = paid ? ref.watch(privateUsdBalanceProvider(account)) : null;
    final endedAt = status?.record.endedAt;
    if (paid) {
      // A payout arrives in the private balance: keep it fresh meanwhile,
      // and read it once the payout had time to land (§9.5).
      ref.watch(
        privateUsdBalanceKeepFreshProvider((
          accountUuid: account,
          ifUsed: false,
        )),
      );
      final updatedAt = balance?.updatedAt;
      final landed = endedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              endedAt * 1000,
            ).add(PrivateUsdBalanceTiming.arrivingPoll);
      if (landed != null &&
          !state.now.isBefore(landed) &&
          (updatedAt == null || updatedAt.isBefore(landed))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref
              .read(privateUsdBalanceProvider(account).notifier)
              .refresh(maxAge: PrivateUsdBalanceTiming.arrivingPoll);
        });
      }
    }
    final presentation = status == null
        ? null
        : privateUsdProgressPresentation(
            status: status,
            now: state.now,
            zcashConfirmations: confirmations,
            screening: screening,
            balance: balance,
            privacyModeEnabled: ref.watch(privacyModeProvider),
            explorerTxPrefix: deployment?.explorerTxPrefix,
          );
    if (presentation != null) {
      if (presentation.bridged && _wasBridged == false) _celebrate = true;
      _wasBridged = presentation.bridged;
    }
    final notifier = ref.read(privateUsdConversionProvider(key).notifier);
    return PopScope(
      canPop: !state.callingOff,
      child: MobilePrivateUsdConversionView(
        presentation: presentation,
        callingOff: state.callingOff,
        callOffError: state.callOffError,
        celebrate: _celebrate,
        onBridgedImpact: () => unawaited(AppHaptics.sendSuccess()),
        activeTab: _tab,
        detailsExpanded: _detailsExpanded,
        onTabChanged: (tab) => setState(() => _tab = tab),
        onToggleDetails: () =>
            setState(() => _detailsExpanded = !_detailsExpanded),
        onBack: state.callingOff ? null : _back,
        onInfo: () => showPrivateUsdProgressInfoSheet(
          context,
          zcashConfirmations: confirmations,
          screening: screening,
        ),
        onRetry: notifier.retryNow,
        onCallOff: () => unawaited(notifier.callOff()),
        onViewBalance: _viewBalance,
        onTryAgain: () => context.pushReplacement('/private-usd/convert'),
      ),
    );
  }
}

/// The progress screen's content for a given presentation. Widgetbook,
/// capture scenarios and tests build it directly.
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

  /// Null until the record is known.
  final PrivateUsdProgressPresentation? presentation;
  final bool callingOff;
  final String? callOffError;

  /// Plays the "Bridged" sign: the bridge finished while it showed.
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
  final VoidCallback onCallOff;
  final VoidCallback onViewBalance;
  final VoidCallback onTryAgain;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final presentation = this.presentation;
    final action = presentation?.action;
    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileTopNav.back(
              title: presentation?.title ?? PrivateUsdCopy.convertProgressTitle,
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
            if (action != null)
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
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    PrivateUsdProgressPresentation presentation,
  ) {
    final colors = context.colors;
    final status = presentation.status;
    final resultTitle = presentation.resultTitle;
    final note = presentation.note;
    final problem = presentation.problem;
    final error = callOffError;
    return [
      if (presentation.bridged)
        PrivateUsdBridgedHero(
          body: presentation.resultBody ?? '',
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
      if (presentation.showsCallOff) ...[
        const SizedBox(height: AppSpacing.s),
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
      ],
      if (error != null) ...[
        const SizedBox(height: AppSpacing.s),
        MobileWarningNotice(
          key: const ValueKey('mobile_private_usd_progress_error'),
          message: error,
        ),
      ],
      MobileSwapStatusContent(
        presentation: status,
        payHeaderRow: MobileSwapReviewHeaderRow(
          label: status.payLabel,
          amountText: presentation.payAmountText,
          asset: status.payAsset,
          icon: privateUsdHeaderIcon(status.payAsset),
          bottomText: PrivateUsdCopy.shieldedZec,
        ),
        receiveHeaderRow: MobileSwapReviewHeaderRow(
          label: status.receiveLabel,
          amountText: presentation.receiveAmountText,
          asset: status.receiveAsset,
          icon: privateUsdHeaderIcon(status.receiveAsset),
          bottomText: PrivateUsdCopy.title,
        ),
        headerToBodyGap: AppSpacing.xs,
        activeTab: activeTab,
        detailsExpanded: detailsExpanded,
        onTabChanged: onTabChanged ?? (_) {},
        onToggleDetails: onToggleDetails ?? () {},
      ),
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

/// "Taking longer than usual", why, and "Try now" (both directions).
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
