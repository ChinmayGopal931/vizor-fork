import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';

/// Line glyphs of straight strokes and 45° cuts only, drawn on a 24-unit
/// grid. Lit, they are tubes (glow and a white-hot core); unlit, thin lines.
enum TronGlyphKind {
  home,
  swap,
  activity,
  settings,
  check,
  receive,
  plus,
  warning,
  cancel,
  help,
  backspace,
}

class TronGlyph extends StatelessWidget {
  const TronGlyph(
    this.kind, {
    required this.color,
    this.core,
    this.lit = 0,
    this.size = 26,
    super.key,
  });

  final TronGlyphKind kind;

  /// The line colour; when lit, the glow.
  final Color color;

  /// The lit tube's centre; defaults to [color].
  final Color? core;

  /// How lit the glyph is, 0..1.
  final double lit;
  final double size;

  /// The cut-corner plate that holds check, plus, cancel and help, in a
  /// [size] square: 20 of the 24 units, two opposite corners cut by 4.
  static Path platePath(double size) {
    final u = size / 24;
    return Path()..addPolygon([
      Offset(6 * u, 2 * u),
      Offset(22 * u, 2 * u),
      Offset(22 * u, 18 * u),
      Offset(18 * u, 22 * u),
      Offset(2 * u, 22 * u),
      Offset(2 * u, 6 * u),
    ], true);
  }

  /// The strokes of [kind] in a [size] square, as the glyph draws them.
  static Path pathFor(TronGlyphKind kind, double size) {
    final u = size / 24;
    Offset p(double x, double y) => Offset(x * u, y * u);
    final path = Path();
    void poly(List<Offset> points, {bool close = false}) {
      path.moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      if (close) path.close();
    }

    void plate() => path.addPath(platePath(size), Offset.zero);

    switch (kind) {
      case TronGlyphKind.home:
        // A wedge roof over a cut-corner base with a door slot.
        poly([p(2, 11), p(12, 3), p(22, 11)]);
        poly([
          p(5, 10),
          p(5, 21),
          p(10, 21),
          p(10, 15),
          p(14, 15),
          p(14, 21),
          p(17, 21),
          p(19, 19),
          p(19, 10),
        ]);
      case TronGlyphKind.swap:
        // Two rails passing each other, with chevron heads.
        poly([p(3, 8), p(19, 8)]);
        poly([p(15, 4), p(19, 8), p(15, 12)]);
        poly([p(21, 16), p(5, 16)]);
        poly([p(9, 12), p(5, 16), p(9, 20)]);
      case TronGlyphKind.activity:
        // A trace with a spike: the ledger's pulse.
        poly([
          p(1, 13),
          p(6, 13),
          p(8.5, 8),
          p(12, 20),
          p(15, 4),
          p(17.5, 13),
          p(23, 13),
        ]);
      case TronGlyphKind.settings:
        // A hex nut with a diamond core.
        poly([
          p(12, 2),
          p(20.7, 7),
          p(20.7, 17),
          p(12, 22),
          p(3.3, 17),
          p(3.3, 7),
        ], close: true);
        poly([p(12, 8), p(16, 12), p(12, 16), p(8, 12)], close: true);
      case TronGlyphKind.check:
        // The plate holding an angular tick.
        plate();
        poly([p(7, 12.5), p(10.5, 16), p(17, 8.5)]);
      case TronGlyphKind.receive:
        // A drop into a bracket.
        poly([p(12, 2), p(12, 15)]);
        poly([p(7, 10), p(12, 15), p(17, 10)]);
        poly([p(3, 15), p(3, 21), p(21, 21), p(21, 15)]);
      case TronGlyphKind.plus:
        plate();
        poly([p(12, 7), p(12, 17)]);
        poly([p(7, 12), p(17, 12)]);
      case TronGlyphKind.warning:
        poly([p(12, 3), p(22, 21), p(2, 21)], close: true);
        poly([p(12, 9), p(12, 14.5)]);
        poly([p(12, 17), p(12, 18)]);
      case TronGlyphKind.cancel:
        plate();
        poly([p(8, 8), p(16, 16)]);
        poly([p(16, 8), p(8, 16)]);
      case TronGlyphKind.help:
        // The plate holding a question mark of straight strokes.
        plate();
        poly([
          p(8.5, 9.5),
          p(8.5, 8),
          p(10, 6.5),
          p(14, 6.5),
          p(15.5, 8),
          p(15.5, 10),
          p(12, 13.5),
          p(12, 15),
        ]);
        poly([p(12, 17.5), p(12, 18.5)]);
      case TronGlyphKind.backspace:
        // A tag pointing left with a cross. It sits in the top 20 units, so
        // a box shorter than it is wide still holds it.
        poly([
          p(7.5, 3),
          p(23, 3),
          p(23, 15.5),
          p(19.5, 19),
          p(7.5, 19),
          p(1.5, 11),
        ], close: true);
        poly([p(11.5, 7.5), p(18.5, 14.5)]);
        poly([p(18.5, 7.5), p(11.5, 14.5)]);
    }
    return path;
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _TronGlyphPainter(
        kind: kind,
        color: color,
        core: core ?? color,
        lit: lit,
      ),
    );
  }
}

class _TronGlyphPainter extends CustomPainter {
  _TronGlyphPainter({
    required this.kind,
    required this.color,
    required this.core,
    required this.lit,
  });

  final TronGlyphKind kind;
  final Color color;
  final Color core;
  final double lit;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 24;
    final path = TronGlyph.pathFor(kind, size.width);
    if (lit > 0) {
      Neon.strokeTube(
        canvas,
        path,
        glow: color,
        core: core,
        width: 1.7 * u,
        intensity: lit,
      );
    }
    if (lit < 1) {
      Neon.strokeUnlit(
        canvas,
        path,
        color: color.withValues(alpha: 1 - lit),
        width: 1.6 * u,
      );
    }
  }

  @override
  bool shouldRepaint(_TronGlyphPainter oldDelegate) {
    return oldDelegate.kind != kind ||
        oldDelegate.color != color ||
        oldDelegate.core != core ||
        oldDelegate.lit != lit;
  }
}
