import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import 'neon_glyph_badge.dart';
import 'neon_motion.dart';
import 'tron_glyph.dart';

/// A done badge switching on as a sign: a scanline across the screen pulls
/// into the badge, a light cycle traces its cut plate and then its glyph, and
/// the badge flickers on in its place.
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
    with SingleTickerProviderStateMixin, NeonAppearMotion<NeonDoneSign> {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.shockwave ? NeonMotion.bridged : NeonMotion.syncDone,
    value: 1,
  )..addListener(_watchIgnition);
  late final AppLifecycleListener _lifecycle;

  /// [NeonDoneSign.onIgnite] ran, or must not (a jump to the end).
  var _ignited = true;

  /// The plate and the glyph as light-cycle paths, traced for the sign's
  /// current glyph and size.
  ({NeonTrail plate, NeonTrail glyph})? _trails;

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
  void didUpdateWidget(NeonDoneSign oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.glyph != widget.glyph || oldWidget.size != widget.size) {
      _trails = null;
    }
  }

  @override
  void onAppear() {
    _ignited = false;
    _controller.forward(from: 0);
  }

  @override
  void onAppearReduced() {
    final onIgnite = widget.onIgnite;
    if (onIgnite == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) onIgnite();
    });
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

  /// The badge's cut plate, and the glyph on its 24-unit grid centred in
  /// it, as [NeonGlyphBadge] and [TronGlyph] draw them.
  ({NeonTrail plate, NeonTrail glyph}) _trace() {
    final s = widget.size;
    final inner = s * NeonGlyphBadge.markScale;
    final inset = (s - inner) / 2;
    return (
      plate: NeonTrail(_cutSquare(Rect.fromLTWH(0, 0, s, s).deflate(0.5))),
      glyph: NeonTrail(
        TronGlyph.pathFor(widget.glyph, inner).shift(Offset(inset, inset)),
      ),
    );
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
                  NeonMotion.span(
                    ms,
                    NeonDoneSign.ignitesAt,
                    NeonMotion.syncDone.inMilliseconds,
                  ),
                );
          final trails = _trails ??= _trace();
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (light > 0) Opacity(opacity: light, child: badge),
              ExcludeSemantics(
                child: CustomPaint(
                  size: Size.square(widget.size),
                  painter: _DoneTrailPainter(
                    ms: ms,
                    plate: trails.plate,
                    glyph: trails.glyph,
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

/// A square with the badge's cuts.
Path _cutSquare(Rect rect) {
  final cut = rect.width * NeonGlyphBadge.cutScale;
  return Neon.chamferedRect(
    rect,
    topLeft: cut,
    topRight: cut,
    bottomRight: cut,
    bottomLeft: cut,
  );
}

class _DoneTrailPainter extends CustomPainter {
  _DoneTrailPainter({
    required this.ms,
    required this.plate,
    required this.glyph,
    required this.glow,
    required this.core,
    required this.screenWidth,
    required this.shockwave,
  });

  final double ms;
  final NeonTrail plate;
  final NeonTrail glyph;
  final Color glow;
  final Color core;
  final double screenWidth;
  final bool shockwave;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
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
    plate.paint(
      canvas,
      Curves.easeInOutCubic.transform(NeonMotion.span(ms, 380, 1000)),
      glow: glow,
      core: core,
      width: 1.2,
      intensity: 0.55 * fade,
    );
    glyph.paint(
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
      _ring(
        canvas,
        center,
        s,
        NeonMotion.span(ms, 1550, NeonMotion.bridged.inMilliseconds),
      );
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

  @override
  bool shouldRepaint(_DoneTrailPainter oldDelegate) =>
      oldDelegate.ms != ms ||
      oldDelegate.plate != plate ||
      oldDelegate.glyph != glyph ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core ||
      oldDelegate.screenWidth != screenWidth ||
      oldDelegate.shockwave != shockwave;
}
