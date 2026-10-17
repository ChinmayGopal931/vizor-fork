import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../app_icon.dart';
import 'tron_glyph.dart';

/// The neon redesign's stand-in for an empty-state illustration: an 80s sun
/// sliced by stripes, setting behind a Tron grid floor.
class NeonHorizon extends StatelessWidget {
  const NeonHorizon({this.width = 280, this.height = 124, super.key});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.hasBoundedWidth && constraints.maxWidth < width
            ? constraints.maxWidth
            : width;
        return SizedBox(
          width: w,
          height: height,
          child: CustomPaint(
            painter: NeonHorizonPainter(glow: neon.glow, core: neon.core),
          ),
        );
      },
    );
  }
}

/// The neon redesign's stand-in for a hero or status illustration: one lit
/// glyph on a cut-corner plate. Give it a [glyph] (drawn as a neon tube), an
/// [iconName] from `AppIcons`, or any [child] for shapes the glyphs lack.
class NeonGlyphBadge extends StatelessWidget {
  const NeonGlyphBadge({
    this.glyph,
    this.iconName,
    this.child,
    this.size = 96,
    super.key,
  }) : assert(glyph != null || iconName != null || child != null);

  final TronGlyphKind? glyph;
  final String? iconName;

  /// Any other mark, drawn in the core colour (through `IconTheme`).
  final Widget? child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    final inner = size * 0.46;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: neon.glow.withValues(alpha: 0.07),
        shape: Neon.chamferBorder(
          cut: size * 0.2,
          side: BorderSide(color: neon.glow.withValues(alpha: 0.55)),
        ),
        shadows: Neon.boxGlow(neon.glow, intensity: 0.35),
      ),
      child: glyph != null
          ? TronGlyph(
              glyph!,
              color: neon.glow,
              core: neon.core,
              lit: 1,
              size: inner,
            )
          : iconName != null
          ? AppIcon(iconName!, size: inner, color: neon.core)
          : IconTheme.merge(
              data: IconThemeData(color: neon.core, size: inner),
              child: child!,
            ),
    );
  }
}

class NeonHorizonPainter extends CustomPainter {
  NeonHorizonPainter({required this.glow, required this.core});

  final Color glow;
  final Color core;

  @override
  void paint(Canvas canvas, Size size) {
    final horizon = size.height * 0.62;
    final center = Offset(size.width / 2, horizon);
    final radius = size.height * 0.46;

    // The sun: a half disc fading upward, cut by widening dark stripes.
    final sun = Rect.fromCircle(center: center, radius: radius);
    canvas
      ..save()
      ..clipRect(Rect.fromLTRB(0, 0, size.width, horizon))
      ..drawCircle(
        center,
        radius + 10,
        Paint()
          ..color = glow.withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      )
      ..saveLayer(Offset.zero & size, Paint())
      ..drawCircle(
        center,
        radius,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [glow, glow.withValues(alpha: 0.15)],
          ).createShader(sun),
      );
    final cut = Paint()..blendMode = BlendMode.clear;
    for (var i = 0; i < 5; i++) {
      final gap = 2.0 + i * 1.6;
      final y = horizon - 6 - i * (radius / 5.2);
      canvas.drawRect(Rect.fromLTWH(0, y - gap, size.width, gap), cut);
    }
    canvas
      ..restore()
      ..restore();

    // The floor.
    Neon.strokeTube(
      canvas,
      Path()
        ..moveTo(0, horizon)
        ..lineTo(size.width, horizon),
      glow: glow,
      core: core,
      width: 1.2,
    );
    final grid = Paint()
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [glow.withValues(alpha: 0.35), glow.withValues(alpha: 0.05)],
      ).createShader(Rect.fromLTWH(0, horizon, size.width, size.height));
    final depth = size.height - horizon;
    for (var i = 1; i <= 4; i++) {
      final t = i / 4;
      final y = horizon + depth * t * t;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var j = -6; j <= 6; j++) {
      canvas.drawLine(
        center,
        Offset(size.width / 2 + j * size.width / 5, size.height),
        grid,
      );
    }
  }

  @override
  bool shouldRepaint(NeonHorizonPainter oldDelegate) =>
      oldDelegate.glow != glow || oldDelegate.core != core;
}
