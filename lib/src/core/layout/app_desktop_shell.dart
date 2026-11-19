import 'dart:async';

import 'package:flutter/material.dart' show Colors, Scaffold;
import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import '../widgets/app_back_link.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_toast.dart';
import '../widgets/neon_glass_panel.dart';
import 'content_overlay_inset.dart';

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

class AppSidebarItem extends StatelessWidget {
  const AppSidebarItem({
    required this.label,
    this.iconName,
    this.leading,
    this.trailing,
    this.active = false,
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
  final VoidCallback? onTap;
  final double leadingGap;
  final double inactiveOpacity;
  final bool iconAnimated;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final disabled = onTap == null && !active;
    final itemOpacity = active ? 1.0 : inactiveOpacity;
    final iconColor = active
        ? colors.navPanel.activeIcon
        : colors.icon.accent.withValues(alpha: itemOpacity);
    final textColor = active
        ? colors.navPanel.activeLabel
        : colors.text.accent.withValues(alpha: itemOpacity);
    final row = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      height: 40,
      padding: const EdgeInsets.only(left: AppSpacing.sm, right: AppSpacing.xs),
      decoration: BoxDecoration(
        color: active ? colors.navPanel.activeBg : null,
        borderRadius: BorderRadius.circular(AppRadii.small),
      ),
      child: Row(
        children: [
          leading ??
              AppIcon(
                iconName!,
                size: 20,
                color: iconColor,
                animated: iconAnimated,
              ),
          SizedBox(width: leadingGap),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.labelLarge.copyWith(color: textColor),
            ),
          ),
          ?trailing,
        ],
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
