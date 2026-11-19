import 'dart:async';

import 'package:flutter/material.dart' show Colors, Scaffold;
import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import '../widgets/app_back_link.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_toast.dart';
import '../widgets/mobile/tron_glyph.dart';
import '../widgets/neon_glass_panel.dart';
import 'content_overlay_inset.dart';
import 'mobile/app_mobile_tab_bar.dart';
import 'mobile/neon_sidebar.dart';

/// Width the desktop shell reserves for its main sidebar.
///
/// Named rather than repeated because window-level overlays derive the
/// content pane's geometry from it — see [contentOverlayInsets].
const double kAppDesktopSidebarWidth = 256;

/// Margin the shell leaves around the sidebar/pane row: outer padding on both
/// window edges, and the same gap again between the two columns.
const double kAppDesktopShellMargin = AppSpacing.xs;

/// Where the trailing pane begins: outer padding + [sidebarWidth] + the gap.
double appDesktopPaneLeftInset(double sidebarWidth) =>
    kAppDesktopShellMargin * 2 + sidebarWidth;

class AppDesktopShell extends StatelessWidget {
  const AppDesktopShell({
    required this.sidebar,
    required this.pane,
    this.background,
    this.backgroundColor,
    this.sidebarWidth = kAppDesktopSidebarWidth,
    super.key,
  });

  final Widget sidebar;
  final Widget pane;
  final Widget? background;
  final Color? backgroundColor;
  final double sidebarWidth;

  @override
  Widget build(BuildContext context) {
    final background = this.background;
    // Window-level overlays clear these so they align with the pane rather
    // than with the whole window.
    return ContentOverlayInset(
      leftInset: appDesktopPaneLeftInset(sidebarWidth),
      rightInset: kAppDesktopShellMargin,
      child: Scaffold(
        backgroundColor: backgroundColor ?? context.colors.macosUtility.window,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (background != null)
                Positioned.fill(child: IgnorePointer(child: background)),
              Padding(
                padding: const EdgeInsets.all(kAppDesktopShellMargin),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: sidebarWidth, child: sidebar),
                    const SizedBox(width: kAppDesktopShellMargin),
                    Expanded(child: pane),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppDesktopSidebarSurface extends StatelessWidget {
  const AppDesktopSidebarSurface({
    required this.child,
    this.backgroundColor,
    this.clipBehavior = Clip.antiAlias,
    this.glass = false,
    super.key,
  });

  final Widget child;
  final Color? backgroundColor;
  final Clip clipBehavior;

  /// Draws the sidebar's neon glass panel: its top-left and bottom-right
  /// corners cut and lit, its content clipped to the same outline.
  final bool glass;

  /// The corner radius of the surfaces that follow the sidebar's shape, such
  /// as the onboarding modals: near-square, as the neon look's corners are.
  static const glassRadius = AppRadii.large;

  /// How far the glass panel's corner cuts reach: the panel's own cut, short
  /// of mobile's sidebar cut so the lit top-left corner clears the macOS
  /// window controls above the sidebar's content.
  static const glassCut = AppChamfer.large;

  @override
  Widget build(BuildContext context) {
    if (glass) {
      return NeonGlassPanel(
        cut: glassCut,
        fill: backgroundColor,
        clipBehavior: clipBehavior,
        child: child,
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.xSmall),
      ),
      clipBehavior: clipBehavior,
      child: child,
    );
  }
}

class AppDesktopPane extends StatelessWidget {
  const AppDesktopPane({
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.backgroundColor,
    this.paintBackground = true,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final bool paintBackground;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: paintBackground ? backgroundColor ?? Colors.transparent : null,
        // Near-square, as the neon look's corners are; the Figma pane
        // corner is [AppWindowSizing.paneRadius].
        borderRadius: BorderRadius.circular(AppRadii.large),
      ),
      clipBehavior: Clip.antiAlias,
      child: AppToastHost(
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Pane-level back toolbar.
///
/// Design rule (verified across every Figma section): the back chevron sits
/// 16px from the pane's left edge, inside a 48px toolbar band, and the label
/// grows to the right. That 16px is composed of this toolbar's 4px
/// (`AppSpacing.xxs`) left padding plus [AppBackLink]'s own 12px
/// (`AppSpacing.s`) internal horizontal inset (the pill button's design inset).
/// The default [padding] encodes the toolbar half of that rule, so screens
/// should NOT pass their own horizontal padding unless a design explicitly
/// deviates. The vertical `xs` keeps the band visually balanced; because the
/// back link is vertically centered within [height], the exact symmetric
/// vertical padding does not move the link.
class AppPaneToolbar extends StatelessWidget {
  const AppPaneToolbar({
    this.onBeforeNavigate,
    this.leading,
    this.trailing,
    this.height = 48,
    this.padding = const EdgeInsets.only(
      left: AppSpacing.xxs,
      top: AppSpacing.xs,
      bottom: AppSpacing.xs,
    ),
    this.backLinkMinWidth = 0,
    super.key,
  });

  final FutureOr<void> Function()? onBeforeNavigate;
  final Widget? leading;
  final Widget? trailing;
  final double height;
  final EdgeInsetsGeometry padding;
  final double backLinkMinWidth;

  @override
  Widget build(BuildContext context) {
    final leadingWidget =
        leading ??
        AppRouteBackLink(
          onBeforeNavigate: onBeforeNavigate,
          minWidth: backLinkMinWidth,
        );

    return SizedBox(
      height: height,
      child: Padding(
        padding: padding,
        child: trailing == null
            ? Align(alignment: Alignment.centerLeft, child: leadingWidget)
            : Row(children: [leadingWidget, const Spacer(), trailing!]),
      ),
    );
  }
}

/// A main sidebar destination in the neon look: its line glyph (the phone
/// sidebar's [NeonSidebarGlyph]) beside a Light label. The active row is lit
/// rather than filled: its glyph and red label glow over a pool of light,
/// which crossfades from the row lit before ([wasActive]).
class AppSidebarItem extends StatelessWidget {
  const AppSidebarItem({
    required this.label,
    this.iconName,
    this.leading,
    this.trailing,
    this.active = false,
    this.wasActive,
    this.onTap,
    this.leadingGap = AppSpacing.sm,
    this.inactiveOpacity = 1,
    this.iconAnimated = true,
    super.key,
  }) : assert(iconName != null || leading != null);

  final String label;
  final String? iconName;
  final Widget? leading;
  final Widget? trailing;
  final bool active;

  /// Whether this row was lit on the page before: desktop builds a new
  /// sidebar on every page, so the light starts there and crossfades to
  /// [active]. Null starts at [active].
  final bool? wasActive;
  final VoidCallback? onTap;
  final double leadingGap;
  final double inactiveOpacity;
  final bool iconAnimated;

  /// The glyph's square: upstream's icon size, so the rows keep their
  /// geometry.
  static const glyphSize = 20.0;

  /// Where a row's glyph starts inside the row.
  static const glyphInset = AppSpacing.sm;

  /// The line glyph of a destination's icon; null keeps the icon (the
  /// importing loader).
  static TronGlyphKind? glyphFor(String iconName) => switch (iconName) {
    AppIcons.home => TronGlyphKind.home,
    AppIcons.swapArrows => TronGlyphKind.swap,
    AppIcons.paid => TronGlyphKind.pay,
    AppIcons.vote => TronGlyphKind.vote,
    AppIcons.history => TronGlyphKind.activity,
    AppIcons.cog => TronGlyphKind.settings,
    AppIcons.logOut => TronGlyphKind.signOut,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final disabled = onTap == null && !active;
    final light = colors.navPanel.activeIcon;
    final motion = !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final unlitLabel = colors.text.accent.withValues(alpha: inactiveOpacity);
    final iconName = this.iconName;
    final glyph = iconName == null ? null : glyphFor(iconName);
    final Widget leadingWidget;
    if (leading case final leading?) {
      leadingWidget = leading;
    } else if (glyph != null) {
      leadingWidget = NeonSidebarGlyph(
        item: AppMobileTabItem(iconName: iconName!, label: label),
        glyph: glyph,
        dimension: glyphSize,
        selected: active,
        wasSelected: wasActive,
      );
    } else {
      leadingWidget = AppIcon(
        iconName!,
        size: glyphSize,
        color: active
            ? light
            : colors.icon.accent.withValues(alpha: inactiveOpacity),
        animated: iconAnimated,
      );
    }
    final row = SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.only(left: glyphInset, right: AppSpacing.xs),
        child: Row(
          children: [
            leadingWidget,
            SizedBox(width: leadingGap),
            Expanded(
              // The label lights with the glyph: red, with a glow.
              child: TweenAnimationBuilder<double>(
                tween: Tween(
                  begin: switch (wasActive) {
                    null => null,
                    final lit => lit ? 1.0 : 0.0,
                  },
                  end: active ? 1 : 0,
                ),
                duration: motion
                    ? AppMobileTabBar.selectDuration
                    : Duration.zero,
                builder: (context, lit, _) => Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.labelLarge.copyWith(
                    color: Color.lerp(unlitLabel, light, lit),
                    shadows: lit > 0
                        ? Neon.textGlow(light, intensity: 0.3 * lit)
                        : null,
                  ),
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );

    final styledRow = disabled ? Opacity(opacity: 0.5, child: row) : row;

    return onTap == null
        ? styledRow
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: styledRow,
            ),
          );
  }
}
