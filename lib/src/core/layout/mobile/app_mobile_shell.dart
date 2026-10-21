import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_toast.dart';
import 'mobile_bottom_safe_area.dart';
import 'mobile_navigation_scope.dart';

/// Mobile counterpart of `AppDesktopShell`: a full-bleed body with the
/// floating tab bar overlaid at the bottom.
///
/// Layout from the Figma mobile frames (e.g. `Home Default`, node
/// 4394:88353): the tab bar floats 16px from the horizontal edges and
/// page content scrolls underneath it (`extendBody`). Below the bar,
/// Android keeps the Figma 12px gap above the navigation-bar inset; on
/// iOS the home indicator floats inside the gap instead, which is
/// widened to 16px so all three margins around the bar match (see
/// [MobileBottomSafeArea]).
class AppMobileShell extends StatelessWidget {
  const AppMobileShell({required this.body, required this.tabBar, super.key});

  final Widget body;
  final Widget tabBar;

  @override
  Widget build(BuildContext context) {
    final bottomGap = defaultTargetPlatform == TargetPlatform.iOS
        ? AppSpacing.sm
        : AppSpacing.s;
    final navigation = MobileNavigationScope.maybeOf(context);
    final mode = navigation?.mode ?? MobileNavigationMode.bottomTabs;
    final rail = navigation?.railRect;
    final railOnLeft =
        rail != null && rail.center.dx < MediaQuery.sizeOf(context).width / 2;
    return Scaffold(
      backgroundColor: context.colors.background.window,
      extendBody: true,
      // Desktop hosts toasts inside AppDesktopPane; the mobile shell is
      // the equivalent surface, so it hosts them for all tab content.
      body: AppToastHost(
        overlayBounds: mode == MobileNavigationMode.sidebar
            ? navigation?.contentRect
            : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            body,
            if (mode == MobileNavigationMode.systemSideTabs &&
                rail != null) ...[
              // As under the bottom bar, content fades into black around the
              // side rail, toward the screen edge and the bottom it stands
              // at. Above the rail that edge stays clear.
              Positioned(
                top: rail.top - AppSpacing.md,
                bottom: 0,
                left: railOnLeft ? 0 : rail.left - AppSpacing.md,
                width: railOnLeft ? rail.right + AppSpacing.md : null,
                right: railOnLeft ? null : 0,
                child: IgnorePointer(
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: _fadeToward(
                      context,
                      Alignment.bottomCenter,
                    ).createShader,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: _fadeToward(
                          context,
                          railOnLeft
                              ? Alignment.centerLeft
                              : Alignment.centerRight,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: rail,
                child: SingleChildScrollView(child: tabBar),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: mode != MobileNavigationMode.bottomTabs
          ? null
          : DecoratedBox(
              decoration: BoxDecoration(
                gradient: _fadeToward(context, Alignment.bottomCenter),
              ),
              child: MobileBottomSafeArea(
                bottomPadding: bottomGap,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.sm,
                    AppSpacing.md,
                    AppSpacing.sm,
                    bottomGap,
                  ),
                  child: tabBar,
                ),
              ),
            ),
    );
  }

  /// No bar behind the tab glyphs: content fades into black toward the
  /// [edge] the bar stands on, so they stay legible over anything beneath.
  static LinearGradient _fadeToward(BuildContext context, Alignment edge) {
    final window = context.colors.background.window;
    return LinearGradient(
      begin: -edge,
      end: edge,
      colors: [
        window.withValues(alpha: 0),
        window.withValues(alpha: 0.97),
        window,
      ],
      stops: const [0, 0.16, 1],
    );
  }
}
