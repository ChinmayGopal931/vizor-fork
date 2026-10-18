import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import 'veylor_wordmark.dart';

/// The neon look's motion: one line of light that switches screens on and
/// off as a CRT does, and runs along paths as a light cycle, drawing what it
/// lights. Plan and rules: `docs/neon-motion-plan.md`.
abstract final class NeonMotion {
  static const intro = Duration(milliseconds: 1550);
  static const reveal = Duration(milliseconds: 760);
  static const revealTimeout = Duration(seconds: 2);
  static const crtOff = Duration(milliseconds: 380);
  static const syncDone = Duration(milliseconds: 1800);

  /// Where the unlock backdrop and the reveal curtain put the wordmark, so
  /// the handoff between them is seamless.
  static const wordmarkAlignment = Alignment(0, -0.45);
  static const wordmarkSize = Size(200, 44);

  /// How far [t] is between [from] and [to], clamped to 0..1.
  static double span(double t, double from, double to) =>
      ((t - from) / (to - from)).clamp(0.0, 1.0);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// A path a light cycle can run along: its lengths are measured once.
class NeonTrail {
  NeonTrail(Path path) : _metrics = path.computeMetrics().toList() {
    length = _metrics.fold(0.0, (sum, m) => sum + m.length);
  }

  final List<PathMetric> _metrics;
  late final double length;

  /// The first [progress] of the path as a lit trail, with a brighter
  /// stretch and a white-hot bead at its head while it is still running.
  void paint(
    Canvas canvas,
    double progress, {
    required Color glow,
    required Color core,
    required double width,
    double intensity = 0.5,
    double headLength = 18,
  }) {
    final p = progress.clamp(0.0, 1.0);
    var remaining = length * p;
    if (remaining <= 0) return;
    final drawn = Path();
    PathMetric? head;
    var headAt = 0.0;
    for (final metric in _metrics) {
      if (remaining <= 0) break;
      final take = math.min(remaining, metric.length);
      drawn.addPath(metric.extractPath(0, take), Offset.zero);
      head = metric;
      headAt = take;
      remaining -= take;
    }
    Neon.strokeTube(
      canvas,
      drawn,
      glow: glow,
      core: core,
      width: width,
      intensity: intensity,
    );
    if (p >= 1 || head == null) return;
    Neon.strokeTube(
      canvas,
      head.extractPath(math.max(0, headAt - headLength), headAt),
      glow: glow,
      core: core,
      width: width * 1.3,
    );
    final tip = head.getTangentForOffset(headAt);
    if (tip != null) {
      paintNeonBead(canvas, tip.position, glow: glow, core: core);
    }
  }
}

/// A light cycle's head, or a CRT's dot: a small white-hot square in a halo.
void paintNeonBead(
  Canvas canvas,
  Offset at, {
  required Color glow,
  required Color core,
  double size = 5,
  double intensity = 1,
}) {
  final k = intensity.clamp(0.0, 1.0);
  if (k <= 0) return;
  final bead = Rect.fromCenter(center: at, width: size, height: size);
  canvas
    ..drawRect(
      bead.inflate(size),
      Paint()
        ..color = glow.withValues(alpha: 0.6 * k)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size),
    )
    ..drawRect(bead, Paint()..color = core.withValues(alpha: k));
}

/// A CRT's horizontal scanline from [left] to [right] at [y]; a dot when
/// it has no length yet.
void paintNeonScanline(
  Canvas canvas,
  double y,
  double left,
  double right, {
  required Color glow,
  required Color core,
  double width = 1.4,
  double intensity = 1,
}) {
  if (right - left < 1) {
    paintNeonBead(
      canvas,
      Offset((left + right) / 2, y),
      glow: glow,
      core: core,
      intensity: intensity,
    );
    return;
  }
  Neon.strokeTube(
    canvas,
    Path()
      ..moveTo(left, y)
      ..lineTo(right, y),
    glow: glow,
    core: core,
    width: width,
    intensity: intensity,
  );
}

/// The lit VEYLOR wordmark that, the first time it is shown in a process,
/// switches on: a dot, a CRT scanline across the screen, a light cycle that
/// traces the letters, then the sign's flicker. Later it is simply lit.
class VeylorWordmarkIntro extends StatefulWidget {
  const VeylorWordmarkIntro({this.size = NeonMotion.wordmarkSize, super.key});

  final Size size;

  static var _played = false;

  @override
  State<VeylorWordmarkIntro> createState() => _VeylorWordmarkIntroState();
}

class _VeylorWordmarkIntroState extends State<VeylorWordmarkIntro>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: NeonMotion.intro,
    value: 1,
  );
  late final AppLifecycleListener _lifecycle;
  var _started = false;

  @override
  void initState() {
    super.initState();
    // Never resume halfway after a trip to the background.
    _lifecycle = AppLifecycleListener(onHide: () => _controller.value = 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (VeylorWordmarkIntro._played || NeonMotion.reduced(context)) return;
    VeylorWordmarkIntro._played = true;
    _controller.value = 0;
    // Startup frames must not eat the opening.
    unawaited(
      WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
        if (mounted && _controller.value == 0) _controller.forward();
      }),
    );
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
    return ExcludeSemantics(
      child: CustomPaint(
        size: widget.size,
        painter: _WordmarkIntroPainter(
          animation: _controller,
          glow: neon.glow,
          core: neon.core,
          screenWidth: MediaQuery.sizeOf(context).width,
        ),
      ),
    );
  }
}

class _WordmarkIntroPainter extends CustomPainter {
  _WordmarkIntroPainter({
    required this.animation,
    required this.glow,
    required this.core,
    required this.screenWidth,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color glow;
  final Color core;
  final double screenWidth;

  static const _lit = 0.75;
  Size? _trailSize;
  NeonTrail? _trail;
  ({Path path, double width})? _art;

  @override
  void paint(Canvas canvas, Size size) {
    if (_trailSize != size) {
      _trailSize = size;
      _art = VeylorWordmarkPainter.geometry(size);
      _trail = _art == null ? null : NeonTrail(_art!.path);
    }
    final art = _art;
    if (art == null) return;
    final t = animation.value;
    if (t >= 1) {
      Neon.strokeTube(
        canvas,
        art.path,
        glow: glow,
        core: core,
        width: art.width,
        intensity: _lit,
      );
      return;
    }

    final ms = t * NeonMotion.intro.inMilliseconds;
    final center = size.center(Offset.zero);
    if (ms < 560) {
      final grow = Curves.easeOutCubic.transform(NeonMotion.span(ms, 120, 380));
      final shrink = Curves.easeInCubic.transform(
        NeonMotion.span(ms, 380, 560),
      );
      final half = screenWidth / 2 * grow * (1 - shrink);
      paintNeonScanline(
        canvas,
        center.dy,
        center.dx - half,
        center.dx + half,
        glow: glow,
        core: core,
        intensity: ms < 120 ? NeonMotion.span(ms, 0, 120) : 1 - 0.6 * shrink,
      );
    }
    if (ms < 1250) {
      _trail!.paint(
        canvas,
        Curves.easeInOutCubic.transform(NeonMotion.span(ms, 450, 1250)),
        glow: glow,
        core: core,
        width: art.width,
      );
      return;
    }
    Neon.strokeTube(
      canvas,
      art.path,
      glow: glow,
      core: core,
      width: art.width,
      intensity: _lit * NeonIgnition.lightAt(NeonMotion.span(ms, 1250, 1550)),
    );
  }

  @override
  bool shouldRepaint(_WordmarkIntroPainter oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core ||
      oldDelegate.screenWidth != screenWidth;
}

/// Dark for [delay], then switches on with the sign's flicker; [builder]
/// gets the light level, 0..1. Under reduced motion it is lit at once.
class NeonDelayedIgnition extends StatefulWidget {
  const NeonDelayedIgnition({
    required this.delay,
    required this.builder,
    super.key,
  });

  final Duration delay;
  final Widget Function(BuildContext context, double light) builder;

  @override
  State<NeonDelayedIgnition> createState() => _NeonDelayedIgnitionState();
}

class _NeonDelayedIgnitionState extends State<NeonDelayedIgnition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.delay + NeonIgnition.duration,
    value: 1,
  );
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!NeonMotion.reduced(context)) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (_controller.isCompleted) return widget.builder(context, 1);
        final ms = _controller.value * _controller.duration!.inMilliseconds;
        final delay = widget.delay.inMilliseconds;
        if (ms < delay) return widget.builder(context, 0);
        return widget.builder(
          context,
          NeonIgnition.lightAt(
            NeonMotion.span(
              ms,
              delay.toDouble(),
              (delay + NeonIgnition.duration.inMilliseconds).toDouble(),
            ),
          ),
        );
      },
    );
  }
}
