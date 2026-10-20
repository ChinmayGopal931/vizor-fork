import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';

/// The mobile look's motion: one line of light that switches screens on and
/// off as a CRT does, and runs along paths as a light cycle, drawing what it
/// lights.
abstract final class NeonMotion {
  static const intro = Duration(milliseconds: 1550);
  static const reveal = Duration(milliseconds: 760);
  static const revealTimeout = Duration(seconds: 2);
  static const crtOff = Duration(milliseconds: 380);
  static const syncDone = Duration(milliseconds: 1800);

  /// `NeonDoneSign` with its shockwave: the done sign, then two rings.
  static const bridged = Duration(milliseconds: 2600);

  /// Where the unlock backdrop and the reveal curtain put the wordmark, so
  /// the handoff between them is seamless.
  static const wordmarkAlignment = Alignment(0, -0.45);
  static const wordmarkSize = Size(200, 44);

  /// How far [t] is between [from] and [to], clamped to 0..1.
  static double span(double t, num from, num to) =>
      ((t - from) / (to - from)).clamp(0.0, 1.0);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// A one-shot animation that plays when its widget first appears.
///
/// [onAppear] runs once, on the first [didChangeDependencies], where reduced
/// motion can first be read; under reduced motion [onAppearReduced] runs
/// instead. Nothing replays it later, so turning reduced motion off never
/// sets off a sign that is already lit.
mixin NeonAppearMotion<T extends StatefulWidget> on State<T> {
  var _appeared = false;

  void onAppear();

  void onAppearReduced() {}

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_appeared) return;
    _appeared = true;
    if (NeonMotion.reduced(context)) {
      onAppearReduced();
    } else {
      onAppear();
    }
  }
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
      Neon.bead(canvas, tip.position, glow: glow, core: core);
    }
  }
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
    Neon.bead(
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

/// Switches a neon sign on once, when it first appears: dark for [delay],
/// then a couple of stutters, then steady. [builder] gets the light level,
/// 0..1. Under reduced motion, or when not [enabled], the light is simply on.
class NeonIgnition extends StatefulWidget {
  const NeonIgnition({
    required this.builder,
    this.delay = Duration.zero,
    this.enabled = true,
    super.key,
  });

  final Widget Function(BuildContext context, double light) builder;
  final Duration delay;
  final bool enabled;

  /// The switch-on itself, after [delay].
  static const duration = Duration(milliseconds: 900);

  /// The light level at [t] (0..1) of [duration]: stutter, catch, stutter,
  /// then full light.
  static double lightAt(double t) {
    if (t < 0.10) return 0.15;
    if (t < 0.16) return 0.85;
    if (t < 0.24) return 0.25;
    if (t < 0.34) return 1;
    if (t < 0.40) return 0.55;
    return Curves.easeOut.transform(((t - 0.40) / 0.60).clamp(0.0, 1.0)) * 0.3 +
        0.7;
  }

  @override
  State<NeonIgnition> createState() => _NeonIgnitionState();
}

class _NeonIgnitionState extends State<NeonIgnition>
    with SingleTickerProviderStateMixin, NeonAppearMotion<NeonIgnition> {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.delay + NeonIgnition.duration,
    value: 1,
  );

  @override
  void onAppear() {
    if (widget.enabled) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _light {
    if (_controller.isCompleted) return 1;
    final ms = _controller.value * _controller.duration!.inMilliseconds;
    final delay = widget.delay.inMilliseconds;
    if (ms < delay) return 0;
    return NeonIgnition.lightAt(
      NeonMotion.span(ms, delay, delay + NeonIgnition.duration.inMilliseconds),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => widget.builder(context, _light),
    );
  }
}
