import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';

/// Content surface used by the mobile screens: it sections settings rows,
/// activity groups, and similar list content.
///
/// In the neon redesign it is a glass panel: dark, see-through, cut at two
/// opposite corners, with a faint red edge whose cut corners are lit, so the
/// backdrop's light reads through and the panel still has a shape.
class MobileSurfaceCard extends StatelessWidget {
  const MobileSurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.sm),
    this.cornerRadius = defaultRadius,
    super.key,
  });

  /// Kept for callers written against the Figma surfaces; the neon panel's
  /// corners are cut ([AppChamfer.large]) rather than rounded.
  static const defaultRadius = 20.0;

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return CustomPaint(
      painter: NeonGlassPanelPainter(
        fill: colors.background.window.withValues(alpha: 0.62),
        glow: colors.neon.glow,
        core: colors.neon.core,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Paints a neon glass panel: a translucent fill inside a wedge outline (two
/// opposite corners cut), a faint edge, and the two cuts lit as tubes.
class NeonGlassPanelPainter extends CustomPainter {
  NeonGlassPanelPainter({
    required this.fill,
    required this.glow,
    required this.core,
    this.cut = AppChamfer.large,
  });

  final Color fill;
  final Color glow;
  final Color core;
  final double cut;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.5);
    final outline = Neon.chamferedRect(rect, topLeft: cut, bottomRight: cut);
    canvas
      ..drawPath(outline, Paint()..color = fill)
      ..drawPath(
        outline,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = glow.withValues(alpha: 0.22),
      );
    final corners = Path()
      ..moveTo(rect.left, rect.top + cut)
      ..lineTo(rect.left + cut, rect.top)
      ..moveTo(rect.right, rect.bottom - cut)
      ..lineTo(rect.right - cut, rect.bottom);
    Neon.strokeTube(canvas, corners, glow: glow, core: core, width: 1.4);
  }

  @override
  bool shouldRepaint(NeonGlassPanelPainter oldDelegate) =>
      oldDelegate.fill != fill ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core ||
      oldDelegate.cut != cut;
}
