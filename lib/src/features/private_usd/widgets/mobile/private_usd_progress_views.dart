import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../core/widgets/mobile/neon_motion.dart';
import '../../../settings/widgets/mobile/mobile_tor_control.dart'
    show MobilePrivacyToggle;
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
import 'private_usd_convert_widgets.dart';
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
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
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

  /// The keep-open card's "Keep screen on".
  final bool keepScreenOn;
  final ValueChanged<bool>? onKeepScreenOnChanged;

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
              keepScreenOn: keepScreenOn,
              onKeepScreenOnChanged: onKeepScreenOnChanged,
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
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
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

  /// The keep-open card's "Keep screen on".
  final bool keepScreenOn;
  final ValueChanged<bool>? onKeepScreenOnChanged;

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
              keepScreenOn: keepScreenOn,
              onKeepScreenOnChanged: onKeepScreenOnChanged,
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
/// keep-open card, the steps with their details, and the note under them.
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
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
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

  /// [PrivateUsdKeepOpenCard] slides in over the steps.
  final bool showsKeepOpen;
  final bool keepScreenOn;
  final ValueChanged<bool>? onKeepScreenOnChanged;
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
        _Reveal(
          visible: showsKeepOpen,
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s),
            child: PrivateUsdKeepOpenCard(
              keepScreenOn: keepScreenOn,
              onKeepScreenOnChanged: onKeepScreenOnChanged ?? (_) {},
            ),
          ),
        ),
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

/// The keep-open card slides in once the progress has been on screen a
/// moment, as the user watches.
const _keepOpenDelay = Duration(milliseconds: 500);
const _keepOpenSlide = Duration(milliseconds: 300);

/// While a bridge needs Veylor: why it has to stay open and online, and
/// "Keep screen on", which holds the screen on, whichever screen shows,
/// until the bridge no longer needs Veylor.
class PrivateUsdKeepOpenCard extends StatelessWidget {
  const PrivateUsdKeepOpenCard({
    required this.keepScreenOn,
    required this.onKeepScreenOnChanged,
    super.key,
  });

  final bool keepScreenOn;
  final ValueChanged<bool> onKeepScreenOnChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    void toggle() => onKeepScreenOnChanged(!keepScreenOn);
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_progress_keep_open'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PrivateUsdPanelCaption(PrivateUsdCopy.keepOpenTitle),
          const SizedBox(height: AppSpacing.xs),
          Text(
            PrivateUsdCopy.keepOpenBody,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Semantics(
            button: true,
            toggled: keepScreenOn,
            label: PrivateUsdCopy.keepScreenOn,
            onTap: toggle,
            excludeSemantics: true,
            child: GestureDetector(
              key: const ValueKey('mobile_private_usd_keep_screen_on'),
              behavior: HitTestBehavior.opaque,
              onTap: toggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  children: [
                    AppIcon(
                      AppIcons.day,
                      size: AppIconSize.medium,
                      color: colors.icon.accent,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        PrivateUsdCopy.keepScreenOn,
                        style: AppTypography.labelLarge.copyWith(
                          color: colors.text.accent,
                        ),
                      ),
                    ),
                    MobilePrivacyToggle(
                      enabled: keepScreenOn,
                      interactive: true,
                      thumbKey: const ValueKey(
                        'mobile_private_usd_keep_screen_on_thumb',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Unfolds [child] when [visible] turns on and folds it away when it turns
/// off. Visible from the start, it unfolds after [_keepOpenDelay]; under
/// reduced motion it simply shows.
class _Reveal extends StatefulWidget {
  const _Reveal({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal>
    with SingleTickerProviderStateMixin, NeonAppearMotion<_Reveal> {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void onAppear() {
    if (!widget.visible) return;
    final total = _keepOpenDelay + _keepOpenSlide;
    _controller.animateTo(
      1,
      duration: total,
      curve: Interval(
        _keepOpenDelay.inMilliseconds / total.inMilliseconds,
        1,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  void onAppearReduced() {
    if (widget.visible) _controller.value = 1;
  }

  @override
  void didUpdateWidget(_Reveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    final target = widget.visible ? 1.0 : 0.0;
    if (NeonMotion.reduced(context)) {
      _controller.value = target;
      return;
    }
    _controller.animateTo(
      target,
      duration: _keepOpenSlide,
      curve: widget.visible ? Curves.easeOutCubic : Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final t = _controller.value;
      if (t == 0) return const SizedBox.shrink();
      // Slides down into the room it opens.
      return ClipRect(
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: t,
          child: Opacity(opacity: t, child: child),
        ),
      );
    },
  );
}

/// What both progress screens' states share: opening the progress resumes
/// the engine, the keep-open card's "Keep screen on" follows the bridge's
/// choice, and a bridge that finishes in view plays its sign.
mixin PrivateUsdProgressScreenState<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  bool? _wasBridged;

  SwapStatusTab tab = SwapStatusTab.progress;
  bool detailsExpanded = false;

  /// The bridge finished in view, not opened finished: its sign plays.
  bool celebrate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(privateUsdEngineProvider).start();
    });
  }

  /// Whether bridge [key] keeps the screen on while it needs Veylor: on
  /// until the user turns it off.
  bool keepsScreenOn(PrivateUsdRecordKey key) => !ref.watch(
    privateUsdScreenMaySleepProvider.select((keys) => keys.contains(key)),
  );

  void keepScreenOn(PrivateUsdRecordKey key, {required bool on}) => ref
      .read(privateUsdScreenMaySleepProvider.notifier)
      .keepScreenOn(key, on: on);

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
