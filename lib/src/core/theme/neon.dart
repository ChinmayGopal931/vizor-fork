import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'app_radii.dart';
import 'gotham_fonts.dart' show kGothamFamily;

/// A HUD caption: section heads and small labels in wide-tracked Light. The
/// caller upper-cases the text, which stays sentence case in the source.
const kNeonHudCaptionStyle = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w300,
  fontSize: 11,
  height: 1.3,
  letterSpacing: 2.4,
);

/// A page title: wide-tracked Thin, upper-cased by the caller.
/// `MobileTopNav.back` draws its titles in it, and screens without a top bar
/// their own.
const kNeonPageTitleStyle = TextStyle(
  fontFamily: kGothamFamily,
  fontWeight: FontWeight.w100,
  fontSize: 20,
  height: 1.2,
  letterSpacing: 5,
);

/// Light effects for the mobile look: glowing glyphs, and lit tubes along
/// the 45° cuts of its outlines.
///
/// A lit tube is three layers: a wide soft halo in the tube colour, a tighter
/// glow, and a thin white-hot core. Every helper here builds that stack, so
/// the sign, the chart line and the tab bar's light read as the same light.
abstract final class Neon {
  /// Text shadows that make a glyph read as a lit tube. Pair with the tube's
  /// pale core (`colors.neon.core`) as the text colour.
  static List<Shadow> textGlow(Color glow, {double intensity = 1}) {
    final k = intensity.clamp(0.0, 1.0);
    return [
      Shadow(color: glow.withValues(alpha: 0.95 * k), blurRadius: 2),
      Shadow(color: glow.withValues(alpha: 0.8 * k), blurRadius: 8),
      Shadow(color: glow.withValues(alpha: 0.55 * k), blurRadius: 18),
      if (k > 0.5)
        Shadow(color: glow.withValues(alpha: 0.35 * k), blurRadius: 36),
    ];
  }

  /// A soft light cast by a lit edge onto what is behind it.
  static List<BoxShadow> boxGlow(Color glow, {double intensity = 1}) {
    final k = intensity.clamp(0.0, 1.0);
    return [
      BoxShadow(color: glow.withValues(alpha: 0.45 * k), blurRadius: 10),
      BoxShadow(color: glow.withValues(alpha: 0.22 * k), blurRadius: 28),
    ];
  }

  /// Strokes [path] as a lit tube: halo, glow, then [core] on top.
  static void strokeTube(
    Canvas canvas,
    Path path, {
    required Color glow,
    required Color core,
    double width = 2,
    double intensity = 1,
  }) {
    final k = intensity.clamp(0.0, 1.0);
    if (k <= 0) return;
    canvas
      ..drawPath(
        path,
        _stroke(width * 5)
          ..color = glow.withValues(alpha: 0.28 * k)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      )
      ..drawPath(
        path,
        _stroke(width * 2.2)
          ..color = glow.withValues(alpha: 0.75 * k)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      )
      ..drawPath(
        path,
        _stroke(width)
          ..color = Color.lerp(glow, core, 0.75)!.withValues(alpha: k),
      );
  }

  /// Strokes [path] as an unlit line, with the tube's square caps and
  /// mitred joins.
  static void strokeUnlit(
    Canvas canvas,
    Path path, {
    required Color color,
    required double width,
  }) {
    canvas.drawPath(path, _stroke(width)..color = color);
  }

  static Paint _stroke(double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.square
    ..strokeJoin = StrokeJoin.miter;

  /// A lit bead: a [size] square centred on [center] in a blurred halo of
  /// [glow] that spreads [halo] past it. A [rim] leaves that much of the
  /// square's edge lit [glow] around a white-hot [core]; without one, the
  /// whole square is the core.
  static void bead(
    Canvas canvas,
    Offset center, {
    required Color glow,
    required Color core,
    double size = 5,
    double halo = 5,
    double blur = 5,
    double rim = 0,
    double intensity = 1,
  }) {
    final k = intensity.clamp(0.0, 1.0);
    if (k <= 0) return;
    final square = Rect.fromCenter(center: center, width: size, height: size);
    canvas.drawRect(
      square.inflate(halo),
      Paint()
        ..color = glow.withValues(alpha: 0.6 * k)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
    );
    if (rim > 0) {
      canvas.drawRect(square, Paint()..color = glow.withValues(alpha: k));
    }
    canvas.drawRect(
      square.deflate(rim),
      Paint()..color = core.withValues(alpha: k),
    );
  }

  /// A grid floor in perspective, from [horizon] to the bottom of [size].
  ///
  /// Its [rows] are spaced by the square of their depth, so they crowd toward
  /// the horizon, and [phase] (0..1) walks them one step toward the viewer.
  /// [columns] + 1 lines fan out from the horizon's centre to points spread
  /// [spread] wide along the bottom. [skipHorizonRow] leaves out the row on
  /// the horizon itself, for a floor whose horizon is drawn lit.
  static void perspectiveGrid(
    Canvas canvas,
    Size size, {
    required double horizon,
    required Paint paint,
    required int rows,
    required int columns,
    required double spread,
    double phase = 0,
    bool skipHorizonRow = false,
  }) {
    final depth = size.height - horizon;
    for (var i = skipHorizonRow ? 1 : 0; i <= rows; i++) {
      final t = (i + phase) / rows;
      if (t > 1) continue;
      final y = horizon + depth * t * t;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    final vanishing = Offset(size.width / 2, horizon);
    for (var j = 0; j <= columns; j++) {
      final x = size.width / 2 + (j / columns - 0.5) * spread;
      canvas.drawLine(vanishing, Offset(x, size.height), paint);
    }
  }

  /// The outline of [rect] with 45° cuts of the given sizes, clockwise from
  /// the top-left corner.
  static Path chamferedRect(
    Rect rect, {
    double topLeft = 0,
    double topRight = 0,
    double bottomRight = 0,
    double bottomLeft = 0,
  }) {
    final tl = _cut(rect, topLeft);
    final tr = _cut(rect, topRight);
    final br = _cut(rect, bottomRight);
    final bl = _cut(rect, bottomLeft);
    return Path()
      ..moveTo(rect.left + tl, rect.top)
      ..lineTo(rect.right - tr, rect.top)
      ..lineTo(rect.right, rect.top + tr)
      ..lineTo(rect.right, rect.bottom - br)
      ..lineTo(rect.right - br, rect.bottom)
      ..lineTo(rect.left + bl, rect.bottom)
      ..lineTo(rect.left, rect.bottom - bl)
      ..lineTo(rect.left, rect.top + tl)
      ..close();
  }

  /// Only the cuts of [chamferedRect]'s outline, each a separate segment:
  /// the corners a panel lights brighter than its edges.
  static Path chamferCuts(
    Rect rect, {
    double topLeft = 0,
    double topRight = 0,
    double bottomRight = 0,
    double bottomLeft = 0,
  }) {
    final tl = _cut(rect, topLeft);
    final tr = _cut(rect, topRight);
    final br = _cut(rect, bottomRight);
    final bl = _cut(rect, bottomLeft);
    final path = Path();
    if (tl > 0) {
      path
        ..moveTo(rect.left, rect.top + tl)
        ..lineTo(rect.left + tl, rect.top);
    }
    if (tr > 0) {
      path
        ..moveTo(rect.right - tr, rect.top)
        ..lineTo(rect.right, rect.top + tr);
    }
    if (br > 0) {
      path
        ..moveTo(rect.right, rect.bottom - br)
        ..lineTo(rect.right - br, rect.bottom);
    }
    if (bl > 0) {
      path
        ..moveTo(rect.left + bl, rect.bottom)
        ..lineTo(rect.left, rect.bottom - bl);
    }
    return path;
  }

  /// A cut no deeper than half the shorter side, so two never cross.
  static double _cut(Rect rect, double cut) =>
      math.min(cut, math.min(rect.width, rect.height) / 2);

  /// The panel shape: the top-left and bottom-right corners cut.
  static BeveledRectangleBorder wedgeBorder({
    double cut = AppChamfer.large,
    BorderSide side = BorderSide.none,
  }) {
    return BeveledRectangleBorder(
      side: side,
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(cut),
        bottomRight: Radius.circular(cut),
      ),
    );
  }

  /// Every corner cut by [cut]: buttons and small badges.
  static BeveledRectangleBorder chamferBorder({
    double cut = AppChamfer.medium,
    BorderSide side = BorderSide.none,
  }) {
    return BeveledRectangleBorder(
      side: side,
      borderRadius: BorderRadius.circular(cut),
    );
  }
}
