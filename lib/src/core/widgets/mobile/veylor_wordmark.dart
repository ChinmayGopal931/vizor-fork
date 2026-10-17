import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';

/// The neon redesign's wordmark: VEYLOR in straight strokes and 45° cuts,
/// drawn as a lit tube, or as plain lines where it sits quietly in a footer.
class VeylorWordmarkPainter extends CustomPainter {
  VeylorWordmarkPainter({
    required this.glow,
    required this.core,
    this.lit = true,
    this.intensity = 0.75,
  });

  /// The tube's colour, or the line colour when unlit.
  final Color glow;

  /// The lit tube's white-hot centre.
  final Color core;
  final bool lit;
  final double intensity;

  // Six 10-unit letters, 4.5 units apart, 14 units tall.
  static const _artWidth = 82.5;
  static const _artHeight = 14.0;
  static const _letterStep = 14.5;

  /// Each letter's strokes in its own cell; a stroke that ends where it
  /// starts is closed.
  static const _letters = <List<List<Offset>>>[
    // V: a flat-bottomed wedge.
    [
      [Offset(0, 0), Offset(4, 14), Offset(6, 14), Offset(10, 0)],
    ],
    // E, with its middle bar floating free of the spine.
    [
      [Offset(10, 0), Offset(0, 0), Offset(0, 14), Offset(10, 14)],
      [Offset(2.6, 7), Offset(8.5, 7)],
    ],
    // Y
    [
      [Offset(0, 0), Offset(5, 7), Offset(10, 0)],
      [Offset(5, 7), Offset(5, 14)],
    ],
    // L
    [
      [Offset(0, 0), Offset(0, 14), Offset(10, 14)],
    ],
    // O, cut at two opposite corners like the panels.
    [
      [
        Offset(3, 0),
        Offset(10, 0),
        Offset(10, 11),
        Offset(7, 14),
        Offset(0, 14),
        Offset(0, 3),
        Offset(3, 0),
      ],
    ],
    // R, with a leg that kicks out and drops straight.
    [
      [
        Offset(0, 14),
        Offset(0, 0),
        Offset(7.5, 0),
        Offset(10, 2.5),
        Offset(10, 4.5),
        Offset(7.5, 7),
        Offset(0, 7),
      ],
      [Offset(6.5, 7), Offset(10, 10.5), Offset(10, 14)],
    ],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // A lit tube's glow needs room inside the box.
    final inset = lit ? 4.0 : 0.0;
    final scale = math.min(
      (size.width - 2 * inset) / _artWidth,
      (size.height - 2 * inset) / _artHeight,
    );
    if (scale <= 0) return;
    final left = (size.width - _artWidth * scale) / 2;
    final top = (size.height - _artHeight * scale) / 2;

    final path = Path();
    for (var i = 0; i < _letters.length; i++) {
      final x0 = left + i * _letterStep * scale;
      for (final stroke in _letters[i]) {
        Offset at(Offset unit) =>
            Offset(x0 + unit.dx * scale, top + unit.dy * scale);
        final first = at(stroke.first);
        path.moveTo(first.dx, first.dy);
        for (final point in stroke.skip(1)) {
          final next = at(point);
          path.lineTo(next.dx, next.dy);
        }
        if (stroke.length > 2 && stroke.first == stroke.last) path.close();
      }
    }

    final width = math.max(1.0, scale * 0.95);
    if (lit) {
      Neon.strokeTube(
        canvas,
        path,
        glow: glow,
        core: core,
        width: width,
        intensity: intensity,
      );
      return;
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.miter
        ..strokeCap = StrokeCap.square
        ..color = glow,
    );
  }

  @override
  bool shouldRepaint(VeylorWordmarkPainter oldDelegate) {
    return oldDelegate.glow != glow ||
        oldDelegate.core != core ||
        oldDelegate.lit != lit ||
        oldDelegate.intensity != intensity;
  }
}
