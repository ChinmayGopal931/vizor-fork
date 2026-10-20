import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import '../../../../../core/theme/app_theme.dart';

/// True black over the frozen home, and Home's Tron floor receding to a red
/// horizon low on the screen. The floor flows while the shield forms, and
/// its light warms and widens once the shield locks.
class ShieldScrimPainter extends CustomPainter {
  ShieldScrimPainter({
    required this.shift,
    required this.scrim,
    required this.glow,
    this.flow = 0,
  });

  /// 0 before the shield locks, 1 once the lock has played out.
  final double shift;

  /// How far the floor's rows have walked toward the viewer, 0..1 of a row.
  final double flow;
  final Color scrim;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final s = shift;
    final rect = Offset.zero & size;
    // The original video retains the blurred home through success.
    canvas.drawRect(rect, Paint()..color = scrim);

    // Light pooled on the floor from below.
    final matrix = Matrix4.identity()
      ..translateByDouble(size.width * 0.5, size.height * 1.02, 0, 1)
      ..scaleByDouble(
        size.width * ui.lerpDouble(2.8, 3.4, s)!,
        size.height * ui.lerpDouble(0.34, 0.4, s)!,
        1,
        1,
      );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [
            glow.withValues(alpha: ui.lerpDouble(0.05, 0.12, s)!),
            glow.withValues(alpha: 0),
          ],
          const [0, 1],
          TileMode.clamp,
          matrix.storage,
        ),
    );

    final k = ui.lerpDouble(0.6, 1, s)!;
    final horizon = size.height * 0.8;
    // The horizon: a thin lit seam with a soft bloom over the floor.
    final seam = Rect.fromLTWH(0, horizon - 40, size.width, 80);
    canvas.drawRect(
      seam,
      Paint()
        ..shader = ui.Gradient.linear(
          seam.topCenter,
          seam.bottomCenter,
          [
            glow.withValues(alpha: 0),
            glow.withValues(alpha: 0.05 * k),
            glow.withValues(alpha: 0),
          ],
          const [0, 0.5, 1],
        ),
    );
    canvas.drawLine(
      Offset(0, horizon),
      Offset(size.width, horizon),
      Paint()
        ..color = glow.withValues(alpha: 0.1 * k)
        ..strokeWidth = 1,
    );
    final floor = Rect.fromLTWH(0, horizon, size.width, size.height - horizon);
    Neon.perspectiveGrid(
      canvas,
      size,
      horizon: horizon,
      paint: Paint()
        ..strokeWidth = 1
        ..shader = ui.Gradient.linear(floor.topCenter, floor.bottomCenter, [
          glow.withValues(alpha: 0.02 * k),
          glow.withValues(alpha: 0.2 * k),
        ]),
      rows: 9,
      columns: 14,
      spread: size.width * 2.6,
      phase: flow,
    );
  }

  @override
  bool shouldRepaint(ShieldScrimPainter old) =>
      old.shift != shift ||
      old.flow != flow ||
      old.scrim != scrim ||
      old.glow != glow;
}
