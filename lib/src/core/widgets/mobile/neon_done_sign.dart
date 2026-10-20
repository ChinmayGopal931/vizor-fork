import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import 'neon_horizon.dart';
import 'neon_motion.dart';
import 'tron_glyph.dart';

/// A done badge switching on as a sign (`docs/neon-motion-plan.md`): a
/// scanline across the screen pulls into the badge, a light cycle traces its
/// cut plate and then its glyph, and the badge flickers on in its place.
///
/// With [shockwave] (a finished bridge), two rings of the plate's cut outline
/// then spread from it across the screen and fade: the send screen's ripple,
/// drawn as lit tubes. [onIgnite] runs once as the badge switches on, for a
/// haptic. Decorative only. Reduced motion shows the lit badge at once (and
/// still runs [onIgnite]); leaving the foreground jumps to the end, so it
/// never resumes halfway.
class NeonDoneSign extends StatefulWidget {
  const NeonDoneSign({
    required this.glyph,
    required this.size,
    this.shockwave = false,
    this.onIgnite,
    super.key,
  });

  final TronGlyphKind glyph;
  final double size;
  final bool shockwave;
  final VoidCallback? onIgnite;

  /// When the light cycle has drawn the glyph and the badge switches on.
  static const ignitesAt = 1350.0;

  @override
  State<NeonDoneSign> createState() => _NeonDoneSignState();
}

class _NeonDoneSignState extends State<NeonDoneSign>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.shockwave ? NeonMotion.bridged : NeonMotion.syncDone,
    value: 1,
  )..addListener(_watchIgnition);
  late final AppLifecycleListener _lifecycle;
  var _started = false;

  /// [NeonDoneSign.onIgnite] ran, or must not (a jump to the end).
  var _ignited = true;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onHide: () {
        _ignited = true;
        _controller.value = 1;
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (NeonMotion.reduced(context)) {
      final onIgnite = widget.onIgnite;
      if (onIgnite != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) onIgnite();
        });
      }
      return;
    }
    _ignited = false;
    _controller.forward(from: 0);
  }

  void _watchIgnition() {
    if (_ignited) return;
    final ms = _controller.value * _controller.duration!.inMilliseconds;
    if (ms < NeonDoneSign.ignitesAt) return;
    _ignited = true;
    widget.onIgnite?.call();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    final badge = NeonGlyphBadge(glyph: widget.glyph, size: widget.size);
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        child: badge,
        builder: (context, badge) {
          if (_controller.isCompleted) return badge!;
          final ms = _controller.value * _controller.duration!.inMilliseconds;
          final light = ms < NeonDoneSign.ignitesAt
              ? 0.0
              : NeonIgnition.lightAt(
                  NeonMotion.span(ms, NeonDoneSign.ignitesAt, 1800),
                );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (light > 0) Opacity(opacity: light, child: badge),
              ExcludeSemantics(
                child: CustomPaint(
                  size: Size.square(widget.size),
                  painter: _DoneTrailPainter(
                    ms: ms,
                    glow: neon.glow,
                    core: neon.core,
                    screenWidth: MediaQuery.sizeOf(context).width,
                    shockwave: widget.shockwave,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DoneTrailPainter extends CustomPainter {
  _DoneTrailPainter({
    required this.ms,
    required this.glow,
    required this.core,
    required this.screenWidth,
    required this.shockwave,
  });

  final double ms;
  final Color glow;
  final Color core;
  final double screenWidth;
  final bool shockwave;

  static NeonTrail? _plate;
  static NeonTrail? _glyph;
  static double? _cachedFor;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    if (_cachedFor != s) {
      _cachedFor = s;
      // The badge's cut plate, and the check glyph's own plate and tick on
      // the glyph's 24-unit grid, as `NeonGlyphBadge` and `TronGlyph` draw
      // them.
      _plate = NeonTrail(_cutSquare((Offset.zero & size).deflate(0.5)));
      final inner = s * 0.46;
      final offset = (s - inner) / 2;
      Offset p(double x, double y) =>
          Offset(offset + x / 24 * inner, offset + y / 24 * inner);
      _glyph = NeonTrail(
        Path()
          ..addPolygon([
            p(6, 2),
            p(22, 2),
            p(22, 18),
            p(18, 22),
            p(2, 22),
            p(2, 6),
          ], true)
          ..addPolygon([p(7, 12.5), p(10.5, 16), p(17, 8.5)], false),
      );
    }

    final center = size.center(Offset.zero);
    if (ms < 460) {
      final grow = Curves.easeOutCubic.transform(NeonMotion.span(ms, 0, 260));
      final shrink = Curves.easeInCubic.transform(
        NeonMotion.span(ms, 260, 420),
      );
      final full = screenWidth / 2;
      final half = (full * grow) - (full - s / 2) * shrink;
      paintNeonScanline(
        canvas,
        center.dy,
        center.dx - math.max(0, half),
        center.dx + math.max(0, half),
        glow: glow,
        core: core,
        intensity: 1 - NeonMotion.span(ms, 380, 460),
      );
    }
    final fade = 1 - NeonMotion.span(ms, NeonDoneSign.ignitesAt, 1600);
    _plate!.paint(
      canvas,
      Curves.easeInOutCubic.transform(NeonMotion.span(ms, 380, 1000)),
      glow: glow,
      core: core,
      width: 1.2,
      intensity: 0.55 * fade,
    );
    _glyph!.paint(
      canvas,
      Curves.easeInOutCubic.transform(
        NeonMotion.span(ms, 950, NeonDoneSign.ignitesAt),
      ),
      glow: glow,
      core: core,
      width: 1.4,
      intensity: 0.7 * fade,
      headLength: 10,
    );
    if (shockwave) {
      _ring(
        canvas,
        center,
        s,
        NeonMotion.span(ms, NeonDoneSign.ignitesAt, 2350),
      );
      _ring(canvas, center, s, NeonMotion.span(ms, 1550, 2600));
    }
  }

  /// One ring of the shockwave at [t] of its run: the plate's outline grown
  /// from the badge until it has crossed the screen, dimming as it goes.
  void _ring(Canvas canvas, Offset center, double badge, double t) {
    if (t <= 0 || t >= 1) return;
    final half = lerpDouble(
      badge / 2,
      screenWidth,
      Curves.easeOutCubic.transform(t),
    )!;
    Neon.strokeTube(
      canvas,
      _cutSquare(Rect.fromCircle(center: center, radius: half)),
      glow: glow,
      core: core,
      width: 1.4,
      intensity: 0.8 * math.pow(1 - t, 1.5),
    );
  }

  /// A square with the badge's cuts: a fifth of its side at every corner.
  static Path _cutSquare(Rect rect) {
    final cut = rect.width * 0.2;
    return Neon.chamferedRect(
      rect,
      topLeft: cut,
      topRight: cut,
      bottomRight: cut,
      bottomLeft: cut,
    );
  }

  @override
  bool shouldRepaint(_DoneTrailPainter oldDelegate) =>
      oldDelegate.ms != ms ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core ||
      oldDelegate.screenWidth != screenWidth ||
      oldDelegate.shockwave != shockwave;
}
