import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_copy_feedback.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_profile_picture.dart';
import '../../../../core/widgets/app_tooltip.dart';
import '../../../../core/widgets/mobile/mobile_address_verify_sheet.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/tron_glyph.dart';
import '../../../../core/widgets/review_list_row.dart' show kTxFeeHelpTooltip;
import '../../domain/swap_contract.dart';
import '../../models/swap_address_formatting.dart';
import '../../models/swap_activity_status_mapper.dart'
    show PayActivityStatusPhase, SwapActivityStatusPresentation;
import '../../models/swap_detail_tooltips.dart';
import '../../models/swap_status_presentation.dart';
import '../swap_asset_icon.dart';
import '../swap_status_page_content.dart' show SwapAnimatedProgressRoute;
import 'mobile_swap_review_header.dart';

const _mobileStatusDetailIconSize = 16.0;
const _mobileStatusHeaderToBodyGap = AppSpacing.sm + AppSpacing.s;

/// Mobile swap status — Figma `Review Progress` (4752:30028) and
/// `Swap Completed` (4752:82692), in the neon redesign: the paying/receiving
/// header over either the progress | Transaction details tabs (HUD captions)
/// with the neon step timeline, or (terminal states) the status panel. Both
/// sit on a glass panel with lit cut corners. The title renders in the host's
/// top nav, not here.
///
/// Purely presentational: consumes the same [SwapActivityStatusPresentation]
/// the desktop status page does, so the status logic stays
/// single-sourced.
class MobileSwapStatusContent extends StatelessWidget {
  const MobileSwapStatusContent({
    required this.presentation,
    required this.payHeaderRow,
    required this.receiveHeaderRow,
    required this.activeTab,
    required this.detailsExpanded,
    required this.onTabChanged,
    required this.onToggleDetails,
    this.paymentHeader,
    super.key,
  });

  final SwapActivityStatusPresentation presentation;
  final MobileSwapReviewHeaderRow payHeaderRow;
  final MobileSwapReviewHeaderRow receiveHeaderRow;
  final SwapStatusTab activeTab;
  final bool detailsExpanded;
  final ValueChanged<SwapStatusTab> onTabChanged;
  final VoidCallback onToggleDetails;
  final Widget? paymentHeader;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('mobile_swap_status_content'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (presentation.paymentMode) const SizedBox(height: AppSpacing.s),
        paymentHeader ??
            MobileSwapReviewHeader(
              pay: payHeaderRow,
              receive: receiveHeaderRow,
            ),
        const SizedBox(height: _mobileStatusHeaderToBodyGap),
        if (presentation.showTabs) ...[
          _MobileStatusTabs(
            activeTab: activeTab,
            progressLabel: presentation.progressTabLabel,
            onChanged: onTabChanged,
          ),
          const SizedBox(height: AppSpacing.sm),
          _StatusCard(
            key: const ValueKey('mobile_swap_status_card'),
            child: activeTab == SwapStatusTab.progress
                ? SwapAnimatedProgressRoute(
                    steps: presentation.steps,
                    progressIndex: presentation.progressIndex,
                    badgeKind: presentation.badgeKind,
                    builder: (_, steps) => _NeonProgressRoute(steps: steps),
                  )
                : presentation.paymentMode && presentation.payStatus != null
                ? _MobilePaymentDetails(presentation: presentation)
                : _MobileTransactionDetails(rows: presentation.details),
          ),
        ] else ...[
          if (presentation.paymentMode) const SizedBox(height: 48),
          _StatusCard(
            key: const ValueKey('mobile_swap_status_card'),
            child: presentation.paymentMode && presentation.payStatus != null
                ? _MobilePaymentDetails(presentation: presentation)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _MobileStatusChipRow(badgeKind: presentation.badgeKind),
                      const SizedBox(height: AppSpacing.sm),
                      _MobileFinalDetails(
                        rows: presentation.details,
                        hideSuccessAddressRows:
                            presentation.badgeKind ==
                            SwapStatusBadgeKind.completed,
                      ),
                    ],
                  ),
          ),
        ],
        // No global "View on Near Intents" link on mobile. Figma keeps the
        // external route on the Tx ID row inside transaction details.
      ],
    );
  }
}

/// Pay activity header from the mobile `Paying` / `Paid` frames. Unlike the
/// swap header, the primary amount is the delivered payment asset and the
/// second row identifies the recipient rather than repeating another asset.
class MobilePayStatusHeader extends StatelessWidget {
  const MobilePayStatusHeader({
    required this.asset,
    required this.amountText,
    required this.fiatText,
    required this.recipientAddress,
    this.label = "You're paying",
    this.recipientName,
    this.recipientProfilePictureId,
    super.key,
  });

  final SwapAsset asset;
  final String amountText;
  final String fiatText;
  final String recipientAddress;
  final String label;
  final String? recipientName;
  final String? recipientProfilePictureId;

  @override
  Widget build(BuildContext context) {
    final compactAddress = compactSwapAddress(
      recipientAddress,
      maxLength: 15,
      prefixLength: 7,
      suffixLength: 5,
      separator: '...',
    );
    final name = recipientName?.trim();
    final profilePictureId = recipientProfilePictureId?.trim();
    return ConstrainedBox(
      key: const ValueKey('mobile_pay_status_header'),
      constraints: const BoxConstraints(minHeight: 252),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MobilePayStatusHeaderRow(
              key: const ValueKey('mobile_pay_status_asset_row'),
              leading: SwapAssetIcon(
                asset: asset,
                size: 40,
                showChainBadge: !asset.isNativeZec,
              ),
              label: label,
              headline: amountText,
              scaleHeadlineToFit: true,
              bottomText: fiatText,
            ),
            const SizedBox(
              width: 40,
              height: 40,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 40,
                  child: Center(child: MobileSwapFlowArrow()),
                ),
              ),
            ),
            _MobilePayStatusHeaderRow(
              key: const ValueKey('mobile_pay_status_recipient_row'),
              leading: profilePictureId != null && profilePictureId.isNotEmpty
                  ? AppProfilePicture(
                      profilePictureId: profilePictureId,
                      size: AppProfilePictureSize.navLarge,
                    )
                  : _MobilePayRecipientPlaceholder(),
              label: 'To',
              headline: name == null || name.isEmpty ? compactAddress : name,
              bottomText: name == null || name.isEmpty ? null : compactAddress,
              bottomAction: _MobilePayFullAddressButton(
                onTap: () => showMobileAddressVerifySheet(
                  context,
                  title: '${asset.chainLabel} address',
                  address: recipientAddress,
                  leading: SwapAssetIcon(
                    asset: asset,
                    size: 32,
                    showChainBadge: false,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobilePayStatusHeaderRow extends StatelessWidget {
  const _MobilePayStatusHeaderRow({
    required this.leading,
    required this.label,
    required this.headline,
    this.scaleHeadlineToFit = false,
    this.bottomText,
    this.bottomAction,
    super.key,
  });

  final Widget leading;
  final String label;
  final String headline;
  final bool scaleHeadlineToFit;
  final String? bottomText;
  final Widget? bottomAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final headlineText = Text(
      headline,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTypography.headlineLarge.copyWith(color: colors.text.accent),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 90),
      child: Row(
        children: [
          SizedBox(width: 40, child: Center(child: leading)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 24),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label,
                      style: AppTypography.labelMedium.copyWith(
                        color: colors.text.secondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                if (scaleHeadlineToFit)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: headlineText,
                  )
                else
                  headlineText,
                const SizedBox(height: AppSpacing.xxs),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 24),
                  child: Row(
                    children: [
                      if (bottomText != null)
                        Expanded(
                          child: Text(
                            bottomText!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.labelMedium.copyWith(
                              color: colors.text.secondary,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      ?bottomAction,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A recipient without a picture: a cut-corner plate with a lit edge, as the
/// Settings rows' icons sit on.
class _MobilePayRecipientPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    return Container(
      width: 40,
      height: 40,
      decoration: ShapeDecoration(
        color: neon.glow.withValues(alpha: 0.08),
        shape: Neon.chamferBorder(
          cut: AppChamfer.medium,
          side: BorderSide(color: neon.glow.withValues(alpha: 0.45)),
        ),
      ),
      child: Center(child: AppIcon(AppIcons.user, size: 20, color: neon.core)),
    );
  }
}

class _MobilePayFullAddressButton extends StatelessWidget {
  const _MobilePayFullAddressButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      child: GestureDetector(
        key: const ValueKey('mobile_pay_status_full_address'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 24),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(
                  AppIcons.eye,
                  size: 16,
                  color: colors.button.ghost.label,
                ),
                const SizedBox(width: AppSpacing.xxs),
                Text(
                  'Full address',
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.button.ghost.label,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The surface hosting the tab content: the neon glass panel, cut at two
/// corners with the cuts lit, as the Settings groups and the holdings panel.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MobileSurfaceCard(
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.base,
        ),
        child: child,
      ),
    );
  }
}

/// The tabs' tracking: tighter than the section heads' so both captions fit
/// side by side on a phone.
const _tabCaptionTracking = 1.6;

class _MobileStatusTabs extends StatelessWidget {
  const _MobileStatusTabs({
    required this.activeTab,
    required this.progressLabel,
    required this.onChanged,
  });

  final SwapStatusTab activeTab;
  final String progressLabel;
  final ValueChanged<SwapStatusTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MobileStatusTabLabel(
              key: const ValueKey('mobile_swap_status_tab_progress'),
              label: progressLabel,
              selected: activeTab == SwapStatusTab.progress,
              onTap: () => onChanged(SwapStatusTab.progress),
            ),
            const SizedBox(width: AppSpacing.sm),
            _MobileStatusTabLabel(
              key: const ValueKey('mobile_swap_status_tab_details'),
              label: 'Transaction details',
              selected: activeTab == SwapStatusTab.details,
              onTap: () => onChanged(SwapStatusTab.details),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tab as a HUD caption: red and lit when selected, with a thin lit tube
/// under it; a quiet grey caption otherwise. No pill, no box.
class _MobileStatusTabLabel extends StatelessWidget {
  const _MobileStatusTabLabel({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final neon = colors.neon;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xxs,
            AppSpacing.xs,
            AppSpacing.xxs,
            AppSpacing.xxs,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs - 2),
                child: Text(
                  label.toUpperCase(),
                  // Drawn upper-cased; read as written.
                  semanticsLabel: label,
                  maxLines: 1,
                  softWrap: false,
                  style: kNeonHudCaptionStyle.copyWith(
                    letterSpacing: _tabCaptionTracking,
                    color: selected ? neon.glow : colors.text.muted,
                    shadows: selected
                        ? Neon.textGlow(neon.glow, intensity: 0.35)
                        : null,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                // The tracking trails the last letter; end under the glyph.
                right: _tabCaptionTracking,
                bottom: 0,
                height: 2,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: selected ? 1 : 0),
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  builder: (context, lit, _) => CustomPaint(
                    painter: _TabUnderlinePainter(
                      lit: lit,
                      glow: neon.glow,
                      core: neon.core,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabUnderlinePainter extends CustomPainter {
  _TabUnderlinePainter({
    required this.lit,
    required this.glow,
    required this.core,
  });

  final double lit;
  final Color glow;
  final Color core;

  @override
  void paint(Canvas canvas, Size size) {
    if (lit <= 0 || size.width <= 0) return;
    final y = size.height / 2;
    Neon.strokeTube(
      canvas,
      Path()
        ..moveTo(0, y)
        ..lineTo(size.width, y),
      glow: glow,
      core: core,
      width: 1,
      intensity: 0.7 * lit,
    );
  }

  @override
  bool shouldRepaint(_TabUnderlinePainter oldDelegate) =>
      oldDelegate.lit != lit ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core;
}

// --- The neon step timeline -------------------------------------------------
//
// Each step keeps the layout it had: a 24px marker column, a 24px title row,
// and the same minimum heights. Done steps are lit check plates; the current
// one keeps the loading spinner, now red with a faint glow behind it; steps
// ahead are unlit plates. A rail joins them: a lit tube from the top down
// into the spinner, dim after it. A packet of light runs down the lit rail
// into the spinner over and over (not under reduced motion).

/// Each marker sits in a square of this size at the top of its step.
const _routeMarkerBox = 24.0;
const _routeStepGap = AppSpacing.xs;

/// A step one title row tall, and the last step, which has no rail below.
const _routeStepHeight = 37.0;
const _routeLastStepHeight = 24.0;

/// Room for the current step's sublines.
const _routeActiveStepHeight = 112.0;

/// Step to step above the current one. Every step there is done and one row
/// tall, so the light's path down to the spinner is known without measuring.
const _routePitch = _routeStepHeight + _routeStepGap;

/// The lit feed above the first marker, drawn into the panel's top padding,
/// so the light has a line to run down even before the first step is done.
const _routeFeedLength = 22.0;

/// The spinner, and how far its spokes reach from its centre (11 units of
/// its 24-unit grid).
const _routeSpinnerSize = 20.0;
const _routeSpinnerReach = _routeSpinnerSize * 11 / 24;

/// The plates (the check glyph's, lit or not) and their half size (10 units
/// of the glyph's 24-unit grid).
const _routePlateGlyphSize = 18.0;
const _routePlateReach = _routePlateGlyphSize * 10 / 24;

double _routeMarkerReach(SwapStatusStepState state) =>
    state == SwapStatusStepState.active ? _routeSpinnerReach : _routePlateReach;

/// Where a rail coming down meets [state]'s marker, from the top of the
/// marker's box: it stops short of a plate and runs into the spinner's top
/// spoke.
double _routeRailEntry(SwapStatusStepState state) =>
    _routeMarkerBox / 2 -
    _routeMarkerReach(state) -
    (state == SwapStatusStepState.active ? 0.5 : 2.5);

/// Where the rail leaves [state]'s marker, from the top of the marker's box.
double _routeRailExit(SwapStatusStepState state) =>
    _routeMarkerBox / 2 + _routeMarkerReach(state) + 2.5;

/// The packet of light running down the lit rail, in route coordinates (0 is
/// the top of the first step).
@immutable
class _RouteLight {
  const _RouteLight({required this.flow, required this.end});

  /// One cycle: the packet's drop, then the spinner's flare fading.
  static const period = Duration(milliseconds: 2200);

  /// The share of the cycle the packet takes to fall.
  static const _drop = 0.6;
  static const _start = -_routeFeedLength;
  static const length = 18.0;

  /// Its bright leading end.
  static const head = 7.0;

  /// The cycle's phase, 0..1.
  final Animation<double> flow;

  /// Where the rail enters the spinner.
  final double end;

  /// The packet's leading point, past [end] once it sinks into the spinner;
  /// null between drops. It speeds up as it falls.
  double? get _lead {
    final t = flow.value;
    if (t >= _drop) return null;
    return _start +
        Curves.easeIn.transform(t / _drop) * (end + length - _start);
  }

  /// The packet's extent, or null between drops.
  ({double top, double bottom})? get packet {
    final lead = _lead;
    if (lead == null) return null;
    return (top: lead - length, bottom: math.min(lead, end));
  }

  /// How much the packet arriving lights the spinner's backdrop, 0..1: it
  /// rises as the packet sinks in and fades over the rest of the cycle.
  double get flare {
    final lead = _lead;
    if (lead != null) return ((lead - end) / length).clamp(0.0, 1.0);
    final fade = 1 - (flow.value - _drop) / (1 - _drop);
    return fade * fade;
  }

  /// How much the packet lights a plate centred at [y] as it passes through.
  double passing(double y) {
    final lead = _lead;
    if (lead == null) return 0;
    return (1 - (lead - length / 2 - y).abs() / length).clamp(0.0, 1.0);
  }

  @override
  bool operator ==(Object other) =>
      other is _RouteLight && identical(other.flow, flow) && other.end == end;

  @override
  int get hashCode => Object.hash(flow, end);
}

/// The steps of [SwapAnimatedProgressRoute] as the neon timeline. It owns the
/// light's cycle while a step is current.
class _NeonProgressRoute extends StatefulWidget {
  const _NeonProgressRoute({required this.steps});

  final List<SwapStatusStepData> steps;

  @override
  State<_NeonProgressRoute> createState() => _NeonProgressRouteState();
}

class _NeonProgressRouteState extends State<_NeonProgressRoute>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: _RouteLight.period,
  );

  int get _activeIndex => widget.steps.indexWhere(
    (step) => step.state == SwapStatusStepState.active,
  );

  /// The light runs while a step is current, unless motion is reduced.
  bool get _flowing =>
      _activeIndex >= 0 &&
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncFlow();
  }

  @override
  void didUpdateWidget(_NeonProgressRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFlow();
  }

  void _syncFlow() {
    if (_flowing) {
      if (!_flow.isAnimating) _flow.repeat();
    } else if (_flow.isAnimating) {
      _flow.stop();
    }
  }

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    final light = _flowing
        ? _RouteLight(
            flow: _flow,
            end:
                _activeIndex * _routePitch +
                _routeRailEntry(SwapStatusStepState.active),
          )
        : null;
    // The light repaints every frame; keep that to the timeline.
    return RepaintBoundary(
      child: Padding(
        key: const ValueKey('swap_progress_route'),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < steps.length; index++) ...[
              if (index > 0) const SizedBox(height: _routeStepGap),
              _NeonProgressStep(
                index: index,
                step: steps[index],
                next: index + 1 < steps.length ? steps[index + 1].state : null,
                light: light,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NeonProgressStep extends StatelessWidget {
  const _NeonProgressStep({
    required this.index,
    required this.step,
    required this.next,
    required this.light,
  });

  final int index;
  final SwapStatusStepData step;

  /// The state of the step below; null for the last step.
  final SwapStatusStepState? next;
  final _RouteLight? light;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final neon = colors.neon;
    final state = step.state;
    final active = state == SwapStatusStepState.active;
    final complete = state == SwapStatusStepState.complete;
    final next = this.next;
    // Exact for every step down to the current one, which is all the light
    // needs: below the current step the rail is dim and the light never runs.
    final top = index * _routePitch;
    final railTop = _routeRailExit(state);
    final minHeight = active
        ? _routeActiveStepHeight
        : (next == null ? _routeLastStepHeight : _routeStepHeight);
    final sublineColor = colors.text.secondary;
    final marker = switch (state) {
      SwapStatusStepState.complete => _LitPlate(
        centre: top + _routeMarkerBox / 2,
        light: light,
      ),
      SwapStatusStepState.active => _SpinnerMarker(light: light),
      SwapStatusStepState.pending => CustomPaint(
        painter: _UnlitPlatePainter(color: colors.text.muted),
      ),
    };
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _routeMarkerBox,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (index == 0)
                Positioned(
                  top: -_routeFeedLength,
                  left: 0,
                  right: 0,
                  height: _routeFeedLength + _routeRailEntry(state),
                  child: CustomPaint(
                    painter: _RailPainter(
                      lit: state != SwapStatusStepState.pending,
                      glow: neon.glow,
                      core: neon.core,
                      top: -_routeFeedLength,
                      light: light,
                      fadeIn: true,
                    ),
                  ),
                ),
              if (next != null)
                Positioned(
                  key: ValueKey('swap_activity_route_step_${index}_line'),
                  top: railTop,
                  // On through the gap to just above the next marker.
                  bottom: -(_routeStepGap + _routeRailEntry(next)),
                  left: 0,
                  right: 0,
                  child: CustomPaint(
                    painter: _RailPainter(
                      lit: complete,
                      glow: neon.glow,
                      core: neon.core,
                      top: top + railTop,
                      light: light,
                    ),
                  ),
                ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: _routeMarkerBox,
                child: marker,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.s),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                key: ValueKey('swap_activity_route_step_${index}_title_row'),
                height: _routeMarkerBox,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        step.titleForState(state),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // Gotham Light throughout: the current step lit,
                        // done steps in the primary text, steps ahead quiet.
                        style: AppTypography.labelLarge.copyWith(
                          color: active
                              ? neon.core
                              : complete
                              ? colors.text.primary
                              : colors.text.secondary,
                          shadows: active
                              ? Neon.textGlow(neon.glow, intensity: 0.3)
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (active && step.lastCheckedLabel != null) ...[
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  step.lastCheckedLabel!,
                  style: AppTypography.labelMedium.copyWith(
                    fontWeight: FontWeight.w100,
                    color: sublineColor,
                  ),
                ),
              ],
              if (active && step.description != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  step.description!,
                  style: AppTypography.bodyMedium.copyWith(
                    fontWeight: FontWeight.w100,
                    color: sublineColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    // Wrapped descriptions and larger text extend the step and its rail
    // together; the minimum keeps the reference rail length.
    return IntrinsicHeight(
      child: ConstrainedBox(
        key: ValueKey('swap_activity_route_step_${index}_${state.name}'),
        constraints: BoxConstraints(minHeight: minHeight),
        child: content,
      ),
    );
  }
}

/// A done step's marker: the check glyph lit red, brighter for a moment as
/// the light passes through it.
class _LitPlate extends StatelessWidget {
  const _LitPlate({required this.centre, required this.light});

  /// The plate's centre in route coordinates.
  final double centre;
  final _RouteLight? light;

  static const _lit = 0.45;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    Widget plate(double passing) => TronGlyph(
      TronGlyphKind.check,
      color: neon.glow,
      core: neon.core,
      lit: _lit + 0.35 * passing,
      size: _routePlateGlyphSize,
    );
    final light = this.light;
    return Center(
      child: light == null
          ? plate(0)
          : AnimatedBuilder(
              animation: light.flow,
              builder: (context, _) => plate(light.passing(centre)),
            ),
    );
  }
}

/// The current step's marker: the loading spinner in neon red over a faint
/// red glow, which flares as the light runs into it.
class _SpinnerMarker extends StatelessWidget {
  const _SpinnerMarker({required this.light});

  final _RouteLight? light;

  @override
  Widget build(BuildContext context) {
    final glow = context.colors.neon.glow;
    final animateLoader =
        !(MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    return CustomPaint(
      painter: _SpinnerGlowPainter(glow: glow, light: light),
      child: Center(
        child: AppIcon(
          AppIcons.loader,
          key: const ValueKey('swap_status_active_step_loader'),
          size: _routeSpinnerSize,
          color: glow,
          animated: animateLoader,
        ),
      ),
    );
  }
}

class _SpinnerGlowPainter extends CustomPainter {
  _SpinnerGlowPainter({required this.glow, required this.light})
    : super(repaint: light?.flow);

  final Color glow;
  final _RouteLight? light;

  @override
  void paint(Canvas canvas, Size size) {
    final level = 0.18 + 0.32 * (light?.flare ?? 0);
    final halo = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: _routeSpinnerSize - 2,
      height: _routeSpinnerSize - 2,
    );
    canvas.drawPath(
      Neon.chamferedRect(
        halo,
        topLeft: AppChamfer.small + 1,
        topRight: AppChamfer.small + 1,
        bottomRight: AppChamfer.small + 1,
        bottomLeft: AppChamfer.small + 1,
      ),
      Paint()
        ..color = glow.withValues(alpha: level)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
  }

  @override
  bool shouldRepaint(_SpinnerGlowPainter oldDelegate) =>
      oldDelegate.glow != glow || oldDelegate.light != light;
}

/// A step ahead: the check glyph's plate as a thin unlit outline.
class _UnlitPlatePainter extends CustomPainter {
  _UnlitPlatePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The check glyph's plate: 20 of its 24 units, two corners cut by 4.
    const u = _routePlateGlyphSize / 24;
    final plate = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 20 * u,
      height: 20 * u,
    );
    canvas.drawPath(
      Neon.chamferedRect(plate, topLeft: 4 * u, bottomRight: 4 * u),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * u
        ..strokeJoin = StrokeJoin.miter
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_UnlitPlatePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// A stretch of the rail down the middle of its box: a lit tube on the way to
/// the current step, with the light's packet where it passes; a dim line
/// after it. The feed above the first marker fades in from nothing.
class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.lit,
    required this.glow,
    required this.core,
    required this.top,
    required this.light,
    this.fadeIn = false,
  }) : super(repaint: lit ? light?.flow : null);

  final bool lit;
  final Color glow;
  final Color core;

  /// This stretch's top in route coordinates.
  final double top;
  final _RouteLight? light;
  final bool fadeIn;

  /// Room beside the line for the tubes' glow.
  static const _glowRoom = 32.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0) return;
    final x = size.width / 2;
    if (!lit) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = glow.withValues(alpha: 0.18)
          ..strokeWidth = 1,
      );
      return;
    }
    final bounds = Rect.fromLTRB(
      -_glowRoom,
      0,
      size.width + _glowRoom,
      size.height,
    );
    final layer = bounds.inflate(_glowRoom);
    if (fadeIn) canvas.saveLayer(layer, Paint());
    Neon.strokeTube(
      canvas,
      Path()
        ..moveTo(x, 0)
        ..lineTo(x, size.height),
      glow: glow,
      core: core,
      width: 1.2,
      intensity: 0.45,
    );
    final packet = light?.packet;
    if (packet != null) {
      // Only within this stretch: the packet passes behind the markers.
      canvas
        ..save()
        ..clipRect(bounds);
      void tube(double from, double to, double width, double intensity) {
        final a = math.max(0.0, from - top);
        final b = math.min(size.height, to - top);
        if (b <= a) return;
        Neon.strokeTube(
          canvas,
          Path()
            ..moveTo(x, a)
            ..lineTo(x, b),
          glow: glow,
          core: core,
          width: width,
          intensity: intensity,
        );
      }

      tube(packet.top, packet.bottom, 1.8, 0.55);
      tube(packet.bottom - _RouteLight.head, packet.bottom, 2.2, 0.95);
      canvas.restore();
    }
    if (fadeIn) {
      // Transparent at the top, fully lit from 80% of the way down (the
      // gradient clamps beyond its ends).
      final fade = Rect.fromLTRB(layer.left, 0, layer.right, size.height * 0.8);
      canvas
        ..drawRect(
          layer,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xFF000000)],
            ).createShader(fade),
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_RailPainter oldDelegate) =>
      oldDelegate.lit != lit ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core ||
      oldDelegate.top != top ||
      oldDelegate.light != light ||
      oldDelegate.fadeIn != fadeIn;
}

/// Status chip row of the terminal card — same chip language as the
/// transaction status screen, in neon glyphs: a check when completed, a
/// U-turn when refunded, the cancel glyph in red when failed, the warning
/// glyph when it needs attention, and the red spinner while in progress.
class _MobileStatusChipRow extends StatelessWidget {
  const _MobileStatusChipRow({
    required this.badgeKind,
    this.paymentMode = false,
  });

  final SwapStatusBadgeKind badgeKind;
  final bool paymentMode;

  static const _glyphSize = 18.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (Widget icon, String text, Color defaultColor) = switch (badgeKind) {
      SwapStatusBadgeKind.completed => (
        TronGlyph(
          TronGlyphKind.check,
          color: colors.text.positiveStrong,
          size: _glyphSize,
        ),
        'Completed',
        colors.text.positiveStrong,
      ),
      SwapStatusBadgeKind.refunded => (
        CustomPaint(
          size: const Size.square(_glyphSize),
          painter: _RefundGlyphPainter(color: colors.text.positiveStrong),
        ),
        'Refunded',
        colors.text.positiveStrong,
      ),
      SwapStatusBadgeKind.failed => (
        TronGlyph(
          TronGlyphKind.cancel,
          color: colors.text.destructive,
          size: _glyphSize,
        ),
        'Failed',
        colors.text.destructive,
      ),
      SwapStatusBadgeKind.warning => (
        TronGlyph(
          TronGlyphKind.warning,
          color: colors.text.warning,
          size: _glyphSize,
        ),
        'Needs attention',
        colors.text.warning,
      ),
      SwapStatusBadgeKind.liveQuote => (
        AppIcon(AppIcons.loader, size: 20, color: colors.neon.glow),
        'In progress',
        colors.text.secondary,
      ),
    };
    final paymentInProgress =
        paymentMode && badgeKind == SwapStatusBadgeKind.liveQuote;
    final textColor = paymentInProgress ? colors.text.primary : defaultColor;
    final labelStyle = paymentMode
        ? AppTypography.labelLarge
        : AppTypography.labelMedium;
    return SizedBox(
      key: paymentMode ? const ValueKey('mobile_pay_status_row') : null,
      height: 32,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xxs),
            child: Text(
              'Status',
              style: labelStyle.copyWith(
                color: badgeKind == SwapStatusBadgeKind.failed
                    ? colors.text.destructive
                    : colors.text.secondary,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xs,
                AppSpacing.xxs,
                AppSpacing.xxs,
                AppSpacing.xxs,
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    key: paymentMode
                        ? const ValueKey('mobile_pay_status_value')
                        : null,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 20,
                        child: Center(child: icon),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        text,
                        // Gotham Light, as the rest of the panel.
                        style: AppTypography.labelLarge.copyWith(
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The refund mark as a neon line glyph: up the left arm to a 45° head, down
/// and round a cut-cornered U.
class _RefundGlyphPainter extends CustomPainter {
  _RefundGlyphPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // On the line glyphs' 24-unit grid, with their unlit stroke. The arm
    // starts below the head's tip so its square end does not poke through.
    final path = Path()
      ..moveTo(4.5, 8.5)
      ..lineTo(8.5, 4.5)
      ..lineTo(12.5, 8.5)
      ..moveTo(8.5, 5.5)
      ..lineTo(8.5, 15)
      ..lineTo(12.5, 19)
      ..lineTo(14, 19)
      ..lineTo(18, 15)
      ..lineTo(18, 7);
    canvas
      ..save()
      ..scale(size.width / 24)
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.miter
          ..strokeCap = StrokeCap.square
          ..color = color,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_RefundGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// A faint red rule between detail groups, as the holdings panel's.
class _NeonRule extends StatelessWidget {
  const _NeonRule();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: context.colors.neon.glow.withValues(alpha: 0.2),
    );
  }
}

class _MobilePaymentDetails extends StatelessWidget {
  const _MobilePaymentDetails({required this.presentation});

  final SwapActivityStatusPresentation presentation;

  @override
  Widget build(BuildContext context) {
    final payStatus = presentation.payStatus;
    final timestamp = payStatus == null
        ? _paymentDetailRow(presentation.details, 'Timestamp')
        : SwapStatusDetailRowData(
            label: 'Timestamp',
            value: payStatus.timestampText,
          );
    final txId = payStatus == null
        ? _paymentDetailRow(presentation.details, 'Tx ID')
        : SwapStatusDetailRowData(
            label: 'Tx ID',
            value: payStatus.txIdText,
            linkUri: payStatus.txIdUri,
          );
    final convertedFrom = SwapStatusDetailRowData(
      label: 'Converted from',
      value: payStatus?.convertedFromText ?? presentation.payAmountText,
    );
    final displayFee = payStatus == null
        ? null
        : SwapStatusDetailRowData(
            label: 'Tx fee',
            value: payStatus.transactionFeeText,
            help: true,
            helpTooltip: kTxFeeHelpTooltip,
          );
    final terminalOutcome =
        payStatus?.phase == PayActivityStatusPhase.failed ||
        payStatus?.phase == PayActivityStatusPhase.refunded;
    final outcomeRows = <SwapStatusDetailRowData>[
      if (payStatus?.phase == PayActivityStatusPhase.failed)
        SwapStatusDetailRowData(
          label: 'Source amount',
          value: payStatus!.convertedFromText,
        ),
      if (payStatus?.phase == PayActivityStatusPhase.refunded &&
          payStatus?.refundedAmountText?.isNotEmpty == true)
        SwapStatusDetailRowData(
          label: 'Refunded amount',
          value: payStatus!.refundedAmountText!,
        ),
      if (terminalOutcome && payStatus?.refundAddress?.isNotEmpty == true)
        SwapStatusDetailRowData(
          label: 'Refund to',
          value: compactSwapAddress(payStatus!.refundAddress!),
          copyable: true,
          copyText: payStatus.refundAddress,
        ),
      if (payStatus?.phase == PayActivityStatusPhase.refunded &&
          payStatus?.refundFeeText?.isNotEmpty == true)
        SwapStatusDetailRowData(
          label: 'Refund fee',
          value: payStatus!.refundFeeText!,
        ),
    ];
    return Column(
      key: const ValueKey('mobile_pay_status_details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MobileStatusChipRow(
          badgeKind: presentation.badgeKind,
          paymentMode: true,
        ),
        if (timestamp != null || txId != null) ...[
          const SizedBox(height: AppSpacing.sm),
          if (timestamp != null)
            _MobileFinalDetailRow(row: timestamp, paymentMode: true),
          if (timestamp != null && txId != null)
            const SizedBox(height: AppSpacing.xs),
          if (txId != null)
            _MobileFinalDetailRow(
              row: txId,
              paymentMode: true,
              actionIconSize: 20,
              actionIconColor: context.colors.icon.muted,
            ),
        ],
        const SizedBox(height: AppSpacing.sm),
        const _NeonRule(),
        const SizedBox(height: AppSpacing.sm),
        if (terminalOutcome)
          for (final row in outcomeRows)
            _MobileFinalDetailRow(row: row, paymentMode: true)
        else ...[
          _MobileFinalDetailRow(
            row: convertedFrom,
            paymentMode: true,
            trailingIcon: AppIcons.shieldKeyhole,
            actionIconSize: 20,
            actionIconColor: context.colors.icon.accent,
          ),
          if (displayFee != null)
            _MobileFinalDetailRow(
              row: displayFee,
              paymentMode: true,
              actionIconSize: 20,
              actionIconColor: context.colors.icon.muted,
            ),
        ],
      ],
    );
  }
}

SwapStatusDetailRowData? _paymentDetailRow(
  Iterable<SwapStatusDetailRowData> rows,
  String label,
) {
  for (final row in rows) {
    if (row.label == label) return row;
  }
  return null;
}

/// Terminal-state rows in the transaction-status card style: small
/// grey label left, value right, a divider before the fee section.
class _MobileTransactionDetails extends StatelessWidget {
  const _MobileTransactionDetails({required this.rows});

  final List<SwapStatusDetailRowData> rows;

  @override
  Widget build(BuildContext context) {
    return _MobileDetailRows(
      key: const ValueKey('mobile_swap_transaction_details'),
      rows: rows,
      compactTransactionDetails: true,
    );
  }
}

class _MobileFinalDetails extends StatelessWidget {
  const _MobileFinalDetails({
    required this.rows,
    required this.hideSuccessAddressRows,
  });

  final List<SwapStatusDetailRowData> rows;
  final bool hideSuccessAddressRows;

  @override
  Widget build(BuildContext context) {
    return _MobileDetailRows(
      rows: rows,
      hideSuccessAddressRows: hideSuccessAddressRows,
    );
  }
}

class _MobileDetailRows extends StatelessWidget {
  const _MobileDetailRows({
    required this.rows,
    this.hideSuccessAddressRows = false,
    this.compactTransactionDetails = false,
    super.key,
  });

  final List<SwapStatusDetailRowData> rows;
  final bool hideSuccessAddressRows;
  final bool compactTransactionDetails;

  @override
  Widget build(BuildContext context) {
    final visibleRows = _mobileVisibleDetailRows(
      rows,
      hideSuccessAddressRows: hideSuccessAddressRows,
      compactTransactionDetails: compactTransactionDetails,
    );
    // Like desktop, a recorded refund starts the outcome group so its amount
    // and fee stay together below the transaction metadata.
    final refundIndex = visibleRows.indexWhere(
      (row) => row.label == 'Refunded amount',
    );
    final dividerIndex = refundIndex > 0
        ? refundIndex
        : visibleRows.indexWhere(_isMobileFeeDetailRow);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < visibleRows.length; i++) ...[
          if (i > 0 && i != dividerIndex) const SizedBox(height: AppSpacing.xs),
          if (i == dividerIndex) ...[
            const SizedBox(height: AppSpacing.sm),
            const _NeonRule(),
            const SizedBox(height: AppSpacing.sm),
          ],
          _MobileFinalDetailRow(row: visibleRows[i]),
        ],
      ],
    );
  }
}

List<SwapStatusDetailRowData> _mobileVisibleDetailRows(
  List<SwapStatusDetailRowData> rows, {
  bool hideSuccessAddressRows = false,
  bool compactTransactionDetails = false,
}) {
  final visible = rows
      .where((row) {
        if (compactTransactionDetails &&
            !_isMobileProgressTransactionDetailRow(row)) {
          return false;
        }
        return row.label != 'Price protection' &&
            row.label != 'Account' &&
            (!hideSuccessAddressRows || !_isMobileSuccessAddressDetailRow(row));
      })
      .toList(growable: false);
  final nonFeeRows = visible
      .where((row) => !_isMobileFeeDetailRow(row))
      .toList(growable: false);
  final feeRows = visible.where(_isMobileFeeDetailRow).toList(growable: false);
  return [...nonFeeRows, ...feeRows];
}

bool _isMobileProgressTransactionDetailRow(SwapStatusDetailRowData row) {
  final label = row.label.toLowerCase();
  return _isMobileDepositAddressDetailRow(row) ||
      label == 'slippage tolerance' ||
      label == 'guaranteed minimum' ||
      label == 'memo' ||
      label == 'missing deposit' ||
      label == 'required deposit' ||
      label == 'detected deposit' ||
      label == 'deposit deadline' ||
      label == 'refund fee' ||
      label == 'timestamp' ||
      label == 'tx id';
}

bool _isMobileDepositAddressDetailRow(SwapStatusDetailRowData row) {
  final label = row.label.toLowerCase();
  return label.contains(' deposit to') ||
      (label.startsWith('deposit ') && label.endsWith(' to'));
}

bool _isMobileSuccessAddressDetailRow(SwapStatusDetailRowData row) {
  final label = row.label.toLowerCase();
  return label.contains('recipient') || _isMobileDepositAddressDetailRow(row);
}

bool _isMobileFeeDetailRow(SwapStatusDetailRowData row) {
  final label = row.label.toLowerCase();
  return label == 'swap fee' ||
      label == 'total fees' ||
      label == 'tx fee' ||
      label == 'refund fee';
}

/// A detail line: the label in quiet grey, the value right-aligned in the
/// primary text, both Gotham Light. The value shrinks to stay on one line.
class _MobileFinalDetailRow extends StatelessWidget {
  const _MobileFinalDetailRow({
    required this.row,
    this.trailingIcon,
    this.paymentMode = false,
    this.actionIconSize = _mobileStatusDetailIconSize,
    this.actionIconColor,
  });

  final SwapStatusDetailRowData row;
  final String? trailingIcon;
  final bool paymentMode;
  final double actionIconSize;
  final Color? actionIconColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final displayLabel = _mobileStatusDetailLabel(row);
    final displayValue = _mobileStatusDetailDisplayValue(row);
    final linkUri = row.linkUri;
    final canTap = linkUri != null || row.copyable;
    // Pay keeps its larger Figma rows; the swap and conversion rows are
    // small.
    final textStyle = paymentMode
        ? AppTypography.labelLarge
        : AppTypography.labelMedium;
    return MouseRegion(
      cursor: canTap ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canTap
            ? () {
                if (linkUri != null) {
                  unawaited(_launchExternalUri(linkUri));
                } else {
                  copyTextWithToast(
                    context,
                    text: row.copyText ?? row.value,
                    toastMessage: 'Copied',
                  );
                }
              }
            : null,
        child: LayoutBuilder(
          builder: (context, constraints) => ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            // The padding fits inside the default 32px row, so only wrapped
            // labels gain separation from the neighbouring rows.
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      displayLabel,
                      style: textStyle.copyWith(color: colors.text.secondary),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: (constraints.maxWidth - AppSpacing.s) / 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: _MobileScaledDetailValueText(
                            value: displayValue,
                            style: textStyle.copyWith(
                              color: colors.text.primary,
                            ),
                          ),
                        ),
                        if (linkUri != null ||
                            row.copyable ||
                            row.help ||
                            trailingIcon != null) ...[
                          const SizedBox(width: AppSpacing.xxs),
                          _MobileStatusDetailActionIcon(
                            icon:
                                trailingIcon ??
                                (linkUri != null
                                    ? AppIcons.arrowTopRight
                                    : row.copyable
                                    ? AppIcons.copy
                                    : AppIcons.help),
                            size: actionIconSize,
                            color: actionIconColor,
                            tooltipMessage: row.help
                                ? row.helpTooltip ??
                                      _mobileStatusHelpTooltip(row.label)
                                : null,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileScaledDetailValueText extends StatelessWidget {
  const _MobileScaledDetailValueText({
    required this.value,
    required this.style,
  });

  final String value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(
        value,
        maxLines: 1,
        softWrap: false,
        textAlign: TextAlign.end,
        style: style,
      ),
    );
  }
}

Future<void> _launchExternalUri(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Opening the system browser is best effort; the row still exposes the ID.
  }
}

String _mobileStatusDetailLabel(SwapStatusDetailRowData row) {
  final label = row.label;
  if (label == 'Total fees') return 'Swap fee';
  return label;
}

String _mobileStatusDetailDisplayValue(SwapStatusDetailRowData row) {
  final source = row.copyText?.trim();
  if (source == null || source.isEmpty) return row.value;
  if (!_shouldCompactMobileStatusDetailValue(row, source)) return row.value;
  return compactSwapAddress(
    source,
    maxLength: 14,
    prefixLength: 6,
    suffixLength: 5,
    separator: '…',
  );
}

bool _shouldCompactMobileStatusDetailValue(
  SwapStatusDetailRowData row,
  String source,
) {
  if (source.length <= 18) return false;
  final label = row.label.toLowerCase();
  return label.contains('address') ||
      label.contains('recipient') ||
      label.contains('refund') ||
      label == 'tx id' ||
      label.contains(' tx') ||
      (label.startsWith('deposit ') && label.endsWith(' to'));
}

class _MobileStatusDetailActionIcon extends StatelessWidget {
  const _MobileStatusDetailActionIcon({
    required this.icon,
    required this.tooltipMessage,
    this.size = _mobileStatusDetailIconSize,
    this.color,
  });

  final String icon;
  final String? tooltipMessage;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final child = MouseRegion(
      cursor: tooltipMessage == null
          ? SystemMouseCursors.click
          : SystemMouseCursors.help,
      child: AppIcon(
        icon,
        size: size,
        color: color ?? colors.icon.regular.withValues(alpha: 0.72),
      ),
    );
    final message = tooltipMessage;
    if (message == null ||
        message.isEmpty ||
        Overlay.maybeOf(context) == null) {
      return child;
    }
    return AppTooltip(message: message, tapToShow: true, child: child);
  }
}

String _mobileStatusHelpTooltip(String label) {
  return switch (label) {
    'Swap fee' => swapFeeTooltip,
    'Guaranteed minimum' => swapGenericMinimumReceiveTooltip,
    'Total fees' => swapTotalFeesTooltip,
    _ => swapStatusDetailTooltip,
  };
}
