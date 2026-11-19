import 'dart:async';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/mobile/neon_motion.dart';
import '../../../../core/zcash/block_spacing.dart';
import '../../../settings/widgets/network_privacy_control.dart'
    show PrivacyToggle;
import '../../../swap/domain/swap_asset.dart';
import '../../../swap/models/swap_activity_status_mapper.dart';
import '../../../swap/models/swap_status_presentation.dart';
import '../../../swap/widgets/mobile/mobile_swap_review_header.dart';
import '../../../swap/widgets/mobile/mobile_swap_status_content.dart';
import '../../models/private_usd_record_key.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_conversion_provider.dart';
import '../mobile/private_usd_banner.dart';
import '../mobile/private_usd_bridged_hero.dart';
import '../mobile/private_usd_convert_widgets.dart';
import '../mobile/private_usd_logo.dart';
import '../mobile/private_usd_progress_views.dart';
import 'desktop_private_usd_widgets.dart';

/// How long a ZEC → shielded USD bridge usually takes, for the info card:
/// about five and a half minutes, and the deposit's two confirmations at the
/// chain's block time (the phone's convert screen says the same).
Duration desktopPrivateUsdForwardTakes(BlockTimeEstimate blockTimes) =>
    Duration(seconds: 330 + blockTimes.secondsForBlocks(2));

/// The convert screen's info, ZEC → shielded USD, as the phone's sheet says
/// it; with [relayerClaims] (Settings), the relayer claims.
Future<void> showDesktopPrivateUsdConvertInfo(
  BuildContext context, {
  required Duration takes,
  required bool relayerClaims,
}) {
  final l10n = context.l10n;
  final about = PrivateUsdCopy.about(l10n, takes);
  return showDesktopPrivateUsdInfo(
    context,
    title: l10n.privateUsdConvertInfoTitle,
    steps: [
      l10n.privateUsdConvertInfoStepQuote,
      l10n.privateUsdConvertInfoStepDeposit,
      relayerClaims
          ? l10n.privateUsdConvertInfoStepClaimRelayer
          : l10n.privateUsdConvertInfoStepClaim,
    ],
    notes: [
      l10n.privateUsdConvertInfoNoteEither,
      relayerClaims
          ? l10n.privateUsdConvertInfoNoteTimeRelayer(about)
          : l10n.privateUsdConvertInfoNoteTime(about),
    ],
  );
}

/// The forward review's info, as the phone's sheet says it.
Future<void> showDesktopPrivateUsdReviewInfo(
  BuildContext context, {
  required String railgunPercent,
  required bool relayerClaims,
}) {
  final l10n = context.l10n;
  return showDesktopPrivateUsdInfo(
    context,
    title: l10n.privateUsdConvertReviewInfoTitle,
    steps: [
      l10n.privateUsdConvertReviewInfoPay,
      l10n.privateUsdConvertReviewInfoReceive(railgunPercent),
      l10n.privateUsdConvertReviewInfoQuote,
    ],
    notes: [
      relayerClaims
          ? l10n.privateUsdConvertRelayerInfoKeepOpen
          : l10n.privateUsdInfoKeepOpen,
    ],
  );
}

/// A forward bridge's progress info; with [relayerClaims], the relayer holds
/// the claim.
Future<void> showDesktopPrivateUsdProgressInfo(
  BuildContext context, {
  required int zcashConfirmations,
  required Duration screening,
  required bool relayerClaims,
}) {
  final l10n = context.l10n;
  return showDesktopPrivateUsdInfo(
    context,
    title: l10n.privateUsdConvertProgressInfoTitle,
    steps: [
      l10n.privateUsdConvertProgressInfoOpen,
      l10n.privateUsdConvertProgressInfoDeposit,
      l10n.privateUsdConvertProgressInfoConfirm(zcashConfirmations),
      relayerClaims
          ? l10n.privateUsdConvertProgressInfoClaimRelayer
          : l10n.privateUsdConvertProgressInfoClaim,
      l10n.privateUsdConvertProgressInfoScreen(
        PrivateUsdCopy.about(l10n, screening),
      ),
    ],
    notes: [
      l10n.privateUsdConvertProgressInfoRefund,
      relayerClaims
          ? l10n.privateUsdConvertRelayerInfoKeepOpen
          : l10n.privateUsdInfoKeepOpen,
    ],
  );
}

/// The shielded USD → ZEC screens' info: the user's two approvals, and when
/// a refund can follow.
Future<void> showDesktopPrivateUsdReverseInfo(BuildContext context) {
  final l10n = context.l10n;
  return showDesktopPrivateUsdInfo(
    context,
    title: l10n.privateUsdReverseTitle,
    steps: [l10n.privateUsdReverseIntro],
    notes: [l10n.privateUsdReverseRefundNote, l10n.privateUsdInfoKeepOpen],
  );
}

/// Asks before a shielded USD → ZEC bridge is called off, as the phone's
/// sheet does: [action] is the button that asked (cancel, or request a
/// refund), and [paid] says whether the dollars went already. True once
/// confirmed.
Future<bool> confirmDesktopPrivateUsdReverseCancel(
  BuildContext context, {
  required String action,
  required bool paid,
}) {
  final l10n = context.l10n;
  return showDesktopPrivateUsdConfirm(
    context,
    title: l10n.privateUsdReverseCancelConfirmTitle,
    body: paid
        ? l10n.privateUsdReverseCancelConfirmBody
        : l10n.privateUsdReverseCancelConfirmUnpaidBody,
    confirmLabel: action,
    dismissLabel: l10n.privateUsdNotNow,
    destructive: true,
  );
}

/// The review's pay or receive row of the header, with Private USD's logo
/// for the private dollars and each amount named for its side.
MobileSwapReviewHeaderRow desktopPrivateUsdHeaderRow(
  AppLocalizations l10n, {
  required String label,
  required String amountText,
  required SwapAsset asset,
  String? bottomText,
}) => MobileSwapReviewHeaderRow(
  label: label,
  amountText: amountText,
  asset: asset,
  icon: privateUsdHeaderIcon(asset),
  bottomText:
      bottomText ??
      (asset == SwapAsset.zec
          ? l10n.privateUsdShieldedZec
          : l10n.privateUsdTitle),
);

/// A bridge's outcome, when it ended without the "Bridged" sign: its title
/// and what follows, in the glass panel.
class DesktopPrivateUsdResultPanel extends StatelessWidget {
  const DesktopPrivateUsdResultPanel({
    required this.title,
    this.body,
    super.key,
  });

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = this.body;
    return DesktopPrivateUsdPanel(
      key: const ValueKey('desktop_private_usd_progress_result'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: AppTypography.headlineSmall.copyWith(
              color: colors.text.accent,
            ),
          ),
          if (body != null) ...[
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
    );
  }
}

/// While a bridge needs Veylor, on the Mac: why it has to stay open with its
/// window showing (a hidden window pauses the bridge, and WebKit suspends the
/// Railgun page, which proves a USD → ZEC payment), and "Keep screen on",
/// which holds the Mac's display (and so the Mac) awake until the bridge no
/// longer needs Veylor. The phone's card says the same of the phone's screen.
class DesktopPrivateUsdKeepOpenCard extends StatelessWidget {
  const DesktopPrivateUsdKeepOpenCard({
    required this.keepScreenOn,
    required this.onKeepScreenOnChanged,
    super.key,
  });

  final bool keepScreenOn;
  final ValueChanged<bool> onKeepScreenOnChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = context.l10n.privateUsdKeepScreenOn;
    return DesktopPrivateUsdPanel(
      key: const ValueKey('desktop_private_usd_progress_keep_open'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrivateUsdPanelCaption(context.l10n.privateUsdKeepOpenTitle),
          const SizedBox(height: AppSpacing.xs),
          Text(
            context.l10n.privateUsdKeepOpenBodyDesktop,
            key: const ValueKey('desktop_private_usd_keep_open_body'),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppTypography.labelMedium.copyWith(
                    color: colors.text.accent,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              PrivacyToggle(
                enabled: keepScreenOn,
                trackKey: const ValueKey('desktop_private_usd_keep_screen_on'),
                semanticsLabel: label,
                onToggle: () => onKeepScreenOnChanged(!keepScreenOn),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A bridge's progress on desktop, both directions: the "Bridged" sign or
/// the result, the note, the problem card, the direction's own [actions], the
/// keep-open card (sliding in while the bridge needs Veylor), the red timeline
/// with the bridge's details (the phone's `MobileSwapStatusContent`), and the
/// note under it while the page proves a payment.
class DesktopPrivateUsdProgressBody extends StatelessWidget {
  const DesktopPrivateUsdProgressBody({
    required this.status,
    required this.payAmountText,
    required this.receiveAmountText,
    required this.onRetry,
    required this.activeTab,
    required this.detailsExpanded,
    required this.onTabChanged,
    required this.onToggleDetails,
    this.bridged = false,
    this.celebrate = false,
    this.resultTitle,
    this.resultBody,
    this.note,
    this.problem,
    this.actions = const [],
    this.provingNote,
    this.showsKeepOpen = false,
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
    super.key,
  });

  final SwapActivityStatusPresentation status;
  final String payAmountText;
  final String receiveAmountText;
  final VoidCallback onRetry;
  final SwapStatusTab activeTab;
  final bool detailsExpanded;
  final ValueChanged<SwapStatusTab> onTabChanged;
  final VoidCallback onToggleDetails;

  /// It finished: [PrivateUsdBridgedHero] stands for the result.
  final bool bridged;

  /// The bridge finished in view: the sign switches on with its shockwave.
  final bool celebrate;
  final String? resultTitle;
  final String? resultBody;
  final String? note;

  /// The problem card's message, once steps have failed for a minute.
  final String? problem;
  final List<Widget> actions;

  /// Under the steps while the page proves a payment.
  final String? provingNote;
  final bool showsKeepOpen;
  final bool keepScreenOn;
  final ValueChanged<bool>? onKeepScreenOnChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final resultTitle = this.resultTitle;
    final note = this.note;
    final problem = this.problem;
    final provingNote = this.provingNote;
    final l10n = context.l10n;
    return Column(
      key: const ValueKey('desktop_private_usd_progress_body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (bridged)
          PrivateUsdBridgedHero(body: resultBody ?? '', celebrate: celebrate)
        else if (resultTitle != null)
          DesktopPrivateUsdResultPanel(title: resultTitle, body: resultBody),
        if (note != null) ...[
          const SizedBox(height: AppSpacing.s),
          Text(
            note,
            key: const ValueKey('desktop_private_usd_progress_note'),
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
        _DesktopReveal(
          visible: showsKeepOpen,
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s),
            child: DesktopPrivateUsdKeepOpenCard(
              keepScreenOn: keepScreenOn,
              onKeepScreenOnChanged: onKeepScreenOnChanged ?? (_) {},
            ),
          ),
        ),
        MobileSwapStatusContent(
          presentation: status,
          payHeaderRow: desktopPrivateUsdHeaderRow(
            l10n,
            label: status.payLabel,
            amountText: payAmountText,
            asset: status.payAsset,
          ),
          receiveHeaderRow: desktopPrivateUsdHeaderRow(
            l10n,
            label: status.receiveLabel,
            amountText: receiveAmountText,
            asset: status.receiveAsset,
          ),
          headerToBodyGap: AppSpacing.xs,
          activeTab: activeTab,
          detailsExpanded: detailsExpanded,
          onTabChanged: onTabChanged,
          onToggleDetails: onToggleDetails,
        ),
        if (provingNote != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            provingNote,
            key: const ValueKey('desktop_private_usd_progress_proving'),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// The keep-open card slides in once the progress has been on screen a
/// moment, as on the phone.
const _keepOpenDelay = Duration(milliseconds: 500);
const _keepOpenSlide = Duration(milliseconds: 300);

/// Unfolds [child] when [visible] turns on and folds it away when it turns
/// off. Visible from the start, it unfolds after [_keepOpenDelay]; under
/// reduced motion it simply shows.
class _DesktopReveal extends StatefulWidget {
  const _DesktopReveal({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_DesktopReveal> createState() => _DesktopRevealState();
}

class _DesktopRevealState extends State<_DesktopReveal>
    with SingleTickerProviderStateMixin, NeonAppearMotion<_DesktopReveal> {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void onAppear() {
    if (!widget.visible) return;
    final total = _keepOpenDelay + _keepOpenSlide;
    unawaited(
      _controller.animateTo(
        1,
        duration: total,
        curve: Interval(
          _keepOpenDelay.inMilliseconds / total.inMilliseconds,
          1,
          curve: Curves.easeOutCubic,
        ),
      ),
    );
  }

  @override
  void onAppearReduced() {
    if (widget.visible) _controller.value = 1;
  }

  @override
  void didUpdateWidget(_DesktopReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    final target = widget.visible ? 1.0 : 0.0;
    if (NeonMotion.reduced(context)) {
      _controller.value = target;
      return;
    }
    unawaited(
      _controller.animateTo(
        target,
        duration: _keepOpenSlide,
        curve: widget.visible ? Curves.easeOutCubic : Curves.easeInCubic,
      ),
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

/// Enter and Space open the banner's bridge.
const _activationShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
};

/// The banner of a bridge under way, on desktop's Home and Shielded USD
/// page: the phone's banner ([PrivateUsdConversionBannerView]), with a click
/// cursor and the keyboard, opening the bridge's progress. It stays while a
/// bridge is unfinished, even when Shielded USD is otherwise unavailable.
class DesktopPrivateUsdConversionBanner extends StatelessWidget {
  const DesktopPrivateUsdConversionBanner({
    required this.banner,
    required this.onOpen,
    super.key,
  });

  final PrivateUsdBannerState banner;
  final ValueChanged<PrivateUsdRoutePath> onOpen;

  @override
  Widget build(BuildContext context) {
    void open() => onOpen(banner.path);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: FocusableActionDetector(
        shortcuts: _activationShortcuts,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<Intent>(
            onInvoke: (_) {
              open();
              return null;
            },
          ),
        },
        child: PrivateUsdConversionBannerView(banner: banner, onTap: open),
      ),
    );
  }
}
