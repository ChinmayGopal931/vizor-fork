import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../../widgets/mobile/mobile_surface_card.dart';

/// The sidebar's panel: neon glass with its top-left and bottom-right corners
/// cut and lit, as the mobile surfaces are. Its content is clipped to the
/// same outline.
class MobileSidebarSurface extends StatelessWidget {
  const MobileSidebarSurface({required this.child, super.key});

  /// How far the panel's corner cuts reach.
  static const cut = AppChamfer.xLarge;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return CustomPaint(
      painter: NeonGlassPanelPainter(
        fill: colors.background.window.withValues(alpha: 0.62),
        glow: colors.neon.glow,
        core: colors.neon.core,
        cut: cut,
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: Neon.wedgeBorder(cut: cut)),
        child: child,
      ),
    );
  }
}
