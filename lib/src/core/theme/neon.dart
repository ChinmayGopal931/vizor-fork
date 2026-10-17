import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'app_radii.dart';

/// The neon redesign's HUD caption: Gotham Light, uppercase (the caller
/// upper-cases the text), wide-tracked. Section heads and small labels.
const kNeonHudCaptionStyle = TextStyle(
  fontFamily: 'Gotham',
  fontWeight: FontWeight.w300,
  fontSize: 11,
  height: 1.3,
  letterSpacing: 2.4,
);

/// Light effects for Veylor's neon redesign (mobile): glowing glyphs, lit
/// tubes along chamfered outlines, and the flicker of a sign switching on.
///
/// A lit tube is three layers: a wide soft halo in the tube colour, a tighter
/// glow, and a thin white-hot core. Every helper here builds that stack, so
/// the sign, the chart line and the tab bar's light read as the same light.
abstract final class Neon {
  /// Text shadows that make a glyph read as a lit tube. Pair with a pale core
  /// colour (for example `NeonPrimitives.redCore`) as the text colour.
  static List<Shadow> textGlow(Color glow, {double intensity = 1}) {
    final k = intensity.clamp(0.0, 2.0);
    return [
      Shadow(
        color: glow.withValues(alpha: 0.95 * math.min(k, 1)),
        blurRadius: 2,
      ),
      Shadow(
        color: glow.withValues(alpha: 0.8 * math.min(k, 1)),
        blurRadius: 8,
      ),
      Shadow(
        color: glow.withValues(alpha: 0.55 * math.min(k, 1)),
        blurRadius: 18,
      ),
      if (k > 0.5)
        Shadow(
          color: glow.withValues(alpha: 0.35 * math.min(k, 1)),
          blurRadius: 36,
        ),
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
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 5
          ..strokeCap = StrokeCap.square
          ..strokeJoin = StrokeJoin.miter
          ..color = glow.withValues(alpha: 0.28 * k)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      )
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 2.2
          ..strokeCap = StrokeCap.square
          ..strokeJoin = StrokeJoin.miter
          ..color = glow.withValues(alpha: 0.75 * k)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      )
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.square
          ..strokeJoin = StrokeJoin.miter
          ..color = Color.lerp(glow, core, 0.75)!.withValues(alpha: k),
      );
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
    final maxCut = math.min(rect.width, rect.height) / 2;
    final tl = math.min(topLeft, maxCut);
    final tr = math.min(topRight, maxCut);
    final br = math.min(bottomRight, maxCut);
    final bl = math.min(bottomLeft, maxCut);
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

  /// The redesign's panel shape: two opposite corners cut, as the wedge
  /// profiles in the reference frames.
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

/// Plays a neon sign's switch-on once when it first appears: a couple of
/// stutters, then steady. [builder] receives the light level in 0..1.
/// Under reduced motion the light is simply on.
class NeonIgnition extends StatefulWidget {
  const NeonIgnition({required this.builder, this.enabled = true, super.key});

  final Widget Function(BuildContext context, double light) builder;

  /// False keeps the light steady (no animation).
  final bool enabled;

  static const duration = Duration(milliseconds: 900);

  @override
  State<NeonIgnition> createState() => _NeonIgnitionState();
}

class _NeonIgnitionState extends State<NeonIgnition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: NeonIgnition.duration,
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.enabled && !reduced && _controller.value == 1 && !_started) {
      _started = true;
      _controller.forward(from: 0);
    }
  }

  var _started = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Stutter, catch, stutter, then full light.
  static double _lightAt(double t) {
    if (t < 0.10) return 0.15;
    if (t < 0.16) return 0.85;
    if (t < 0.24) return 0.25;
    if (t < 0.34) return 1;
    if (t < 0.40) return 0.55;
    return Curves.easeOut.transform(((t - 0.40) / 0.60).clamp(0.0, 1.0)) * 0.3 +
        0.7;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => widget.builder(
        context,
        _controller.isCompleted ? 1 : _lightAt(_controller.value),
      ),
    );
  }
}
