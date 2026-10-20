import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/widgets/app_icon.dart';
import 'shield_haptics.dart';
import 'shield_motion.dart';

/// "Drag to shield": a cut-corner glass slab and a lit pin. The slab's edge
/// is a tube that lights from its left end as far as the pin.
///
/// The pin tracks the finger 1:1 from wherever it was grabbed, rubber-bands
/// past both ends, and on release either springs home with the finger's
/// velocity or — if released near the end or flicked toward it — gets pulled
/// into the end and locks with a rigid haptic.
class SlideToShield extends StatefulWidget {
  const SlideToShield({
    super.key,
    required this.onCommitted,
    this.progress,
    this.width = 284,
  });

  /// Fires on the frame the pin locks in.
  final VoidCallback onCommitted;

  /// Receives the pin's travel, 0..1, every frame it moves (finger, spring
  /// home or magnet), so the page can respond to the drag.
  final ValueNotifier<double>? progress;

  final double width;
  static const height = 50.0;

  @override
  State<SlideToShield> createState() => _SlideToShieldState();
}

class _SlideToShieldState extends State<SlideToShield>
    with TickerProviderStateMixin {
  static const _knob = Size(60, 50);
  double get _maxX => widget.width - _knob.width;
  double get _armAt => _maxX * 0.9;

  late final AnimationController _pos = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
    reverseDuration: const Duration(milliseconds: 220),
  );
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final AnimationController _squash = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  int? _pointer;
  double _grab = 0;
  VelocityTracker? _tracker;
  bool _armed = false;
  bool _committed = false;

  @override
  void initState() {
    super.initState();
    _pos.addListener(_report);
  }

  void _report() {
    widget.progress?.value = (_x / _maxX).clamp(0.0, 1.0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _shimmer.stop();
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _pos.dispose();
    _press.dispose();
    _flash.dispose();
    _squash.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  double get _x => _pos.value;

  void _down(PointerDownEvent e) {
    if (_pointer != null || _committed) return;
    final knob = Rect.fromLTWH(_x, 0, _knob.width, _knob.height).inflate(12);
    if (!knob.contains(e.localPosition)) return;
    _pointer = e.pointer;
    _pos.stop();
    _grab = e.localPosition.dx - _x;
    _tracker = VelocityTracker.withKind(e.kind)
      ..addPosition(e.timeStamp, e.localPosition);
    _press.forward();
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _tracker?.addPosition(e.timeStamp, e.localPosition);
    final raw = e.localPosition.dx - _grab;
    // Soft walls instead of hard stops.
    final x = raw < 0
        ? VMotion.rubberBand(raw, _knob.width)
        : raw > _maxX
        ? _maxX + VMotion.rubberBand(raw - _maxX, _knob.width)
        : raw;
    _pos.value = x;
    _updateArmed(x >= _armAt);
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _press.reverse();
    final v = e is PointerUpEvent
        ? (_tracker?.getVelocity().pixelsPerSecond.dx ?? 0)
        : 0.0;
    _tracker = null;
    if (e is PointerCancelEvent) {
      _updateArmed(false);
      _pos.animateWith(
        SpringSimulation(VMotion.spring(response: 0.34), _x, 0, 0),
      );
    } else {
      _release(v);
    }
  }

  void _updateArmed(bool armed) {
    if (armed == _armed) return;
    _armed = armed;
    Haptics.selection();
  }

  void _release(double velocity) {
    final x = _x;
    // Commit if it's nearly there, or if the flick would carry it there.
    final projected = x + VMotion.project(velocity);
    if (x >= _armAt || (x >= _maxX * 0.5 && projected >= _maxX)) {
      _commit(velocity);
    } else {
      _updateArmed(false);
      _pos.animateWith(
        SpringSimulation(VMotion.spring(response: 0.34), x, 0, velocity),
      );
    }
  }

  void _commit(double velocity) {
    if (_committed) return;
    _committed = true;
    final x = _x;
    if (x >= _maxX) {
      // Already at (or stretched past) the end: settle back onto it.
      _pos.animateWith(
        SpringSimulation(VMotion.spring(response: 0.2), x, _maxX, velocity),
      );
      _lockIn();
      return;
    }
    // Pulled the rest of the way, like a magnet catching the pin.
    _pos
        .animateWith(GravitySimulation(5200, x, _maxX, math.max(velocity, 450)))
        .whenComplete(() {
          _pos.value = _maxX;
          _lockIn();
        });
  }

  void _lockIn() {
    if (!mounted) return;
    Haptics.impact(ImpactStyle.rigid);
    _flash.forward(from: 0);
    _squash.value = 1;
    _squash.animateWith(
      SpringSimulation(
        VMotion.spring(response: 0.32, dampingRatio: 0.45),
        1,
        0,
        0,
      ),
    );
    widget.onCommitted();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      label: 'Drag to shield',
      enabled: !_committed,
      onTap: _committed ? null : () => _commit(1200),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        // The sheen repaints every frame; keep the lit sign beside it still.
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([
              _pos,
              _press,
              _flash,
              _squash,
              _shimmer,
            ]),
            builder: (context, _) {
              final x = _x.clamp(-_knob.width, widget.width);
              final p = (x / _maxX).clamp(0.0, 1.0);
              final flash = _flashCurve(_flash.value);
              return SizedBox.fromSize(
                size: Size(widget.width, SlideToShield.height),
                child: _Track(
                  progress: p,
                  flash: flash,
                  knobX: x,
                  label: _Label(
                    progress: p,
                    shimmer: reduce ? null : _shimmer.value,
                  ),
                  knob: Positioned(
                    left: x,
                    top: 0,
                    child: Transform(
                      alignment: Alignment.centerRight,
                      transform: Matrix4.diagonal3Values(
                        (1 - 0.04 * _press.value) * (1 + 0.07 * _squash.value),
                        (1 - 0.04 * _press.value) * (1 - 0.07 * _squash.value),
                        1,
                      ),
                      child: _Knob(press: _press.value),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Flash: near-instant attack, slow release.
  static double _flashCurve(double t) {
    if (t <= 0 || t >= 1) return 0;
    const attack = 0.12;
    if (t < attack) return VMotion.easeOut.transform(t / attack);
    return 1 - VMotion.easeOut.transform((t - attack) / (1 - attack));
  }
}

/// How far the slab's and the pin's corner cuts reach: a full-size button's.
const _cut = AppChamfer.medium;

Path _outline(Rect rect) => Neon.chamferedRect(
  rect,
  topLeft: _cut,
  topRight: _cut,
  bottomRight: _cut,
  bottomLeft: _cut,
);

class _Track extends StatelessWidget {
  const _Track({
    required this.progress,
    required this.flash,
    required this.knobX,
    required this.label,
    required this.knob,
  });

  final double progress;
  final double flash;
  final double knobX;
  final Widget label;
  final Widget knob;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final neon = colors.neon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Outer haze, fading in with the drag.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _OuterGlowPainter(progress, knobX, neon.glow),
            ),
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _TrackPainter(
              knobX: knobX,
              progress: progress,
              flash: flash,
              fill: colors.background.window.withValues(alpha: 0.62),
              glow: neon.glow,
              core: neon.core,
            ),
          ),
        ),
        // The slab's outline clips the pin as it rubber-bands past either end.
        Positioned.fill(
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: Neon.chamferBorder(cut: _cut)),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: label),
                knob,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Haze drawn only outside the slab, so the glass stays clean.
class _OuterGlowPainter extends CustomPainter {
  _OuterGlowPainter(this.progress, this.knobX, this.glow);

  final double progress;
  final double knobX;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect.inflate(400))
        ..addPath(_outline(rect), Offset.zero),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(knobX + 30, size.height / 2),
        width: 110,
        height: 52,
      ),
      Paint()
        ..color = glow.withValues(alpha: 0.14 + 0.2 * progress)
        ..maskFilter = const MaskFilter.blur(ui.BlurStyle.normal, 24),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterGlowPainter old) =>
      old.progress != progress || old.knobX != knobX || old.glow != glow;
}

/// The glass slab: a dark fill inside the cut outline, light pooled around
/// the pin, and the outline as a tube that is lit from the left end up to
/// the pin and unlit ahead of it. Locked in, the whole tube lights.
class _TrackPainter extends CustomPainter {
  const _TrackPainter({
    required this.knobX,
    required this.progress,
    required this.flash,
    required this.fill,
    required this.glow,
    required this.core,
  });

  final double knobX;
  final double progress;
  final double flash;
  final Color fill;
  final Color glow;
  final Color core;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.5);
    final outline = _outline(rect);
    final pin = knobX + 30;
    canvas.drawPath(outline, Paint()..color = fill);
    canvas.save();
    canvas.clipPath(outline);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(Offset(pin, size.height / 2), 100, [
          glow.withValues(alpha: 0.16 + 0.16 * progress),
          glow.withValues(alpha: 0),
        ]),
    );
    if (flash > 0) {
      canvas.drawRect(
        rect,
        Paint()..color = glow.withValues(alpha: 0.3 * flash),
      );
    }
    canvas.restore();
    Neon.strokeUnlit(
      canvas,
      outline,
      color: glow.withValues(alpha: 0.22),
      width: 1,
    );
    Neon.strokeTube(
      canvas,
      progress >= 1 ? outline : _litEdge(rect, pin),
      glow: glow,
      core: core,
      width: 1.4,
      intensity: 0.5 + 0.5 * progress + flash,
    );
  }

  /// The outline's left end, and its top and bottom edges as far as [x].
  static Path _litEdge(Rect r, double x) {
    final end = x.clamp(r.left + _cut, r.right - _cut);
    return Path()
      ..moveTo(end, r.top)
      ..lineTo(r.left + _cut, r.top)
      ..lineTo(r.left, r.top + _cut)
      ..lineTo(r.left, r.bottom - _cut)
      ..lineTo(r.left + _cut, r.bottom)
      ..lineTo(end, r.bottom);
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.knobX != knobX ||
      old.progress != progress ||
      old.flash != flash ||
      old.fill != fill ||
      old.glow != glow ||
      old.core != core;
}

class _Label extends StatelessWidget {
  const _Label({required this.progress, required this.shimmer});

  final double progress;

  /// 0..1 loop phase, or null for a static label (Reduce Motion).
  final double? shimmer;

  @override
  Widget build(BuildContext context) {
    // Clears by halfway and drifts a little with the pin.
    final opacity = (1 - progress / 0.5).clamp(0.0, 1.0);
    Widget text = Text(
      'Drag to shield',
      style: AppTypography.bodyMedium.copyWith(
        color: context.colors.text.primary,
      ),
    );
    final phase = shimmer;
    if (phase != null && progress == 0) {
      // Slide-to-unlock sheen: sweep for 60% of the loop, rest for 40%.
      final sweep = (phase / 0.6).clamp(0.0, 1.0);
      text = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) {
          final w = bounds.width;
          final center = -0.4 * w + sweep * 1.8 * w;
          return LinearGradient(
            colors: const [
              Color(0x9EFFFFFF),
              Color(0xFFFFFFFF),
              Color(0x9EFFFFFF),
            ],
            stops: const [0, 0.5, 1],
          ).createShader(
            Rect.fromLTWH(center - w * 0.35, 0, w * 0.7, bounds.height),
          );
        },
        child: text,
      );
    }
    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: Transform.translate(
          offset: Offset(progress * 24, 0),
          child: Center(child: text),
        ),
      ),
    );
  }
}

/// The pin: a cut-corner plate lit red, as a passcode key lights under the
/// finger, holding the shield. It only moves, squashes and brightens with a
/// press.
class _Knob extends StatelessWidget {
  const _Knob({required this.press});

  final double press;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final glow = colors.neon.glow;
    return SizedBox.fromSize(
      size: _SlideToShieldState._knob,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          // Opaque, so the lit edge ends out of sight beneath it.
          color: Color.alphaBlend(
            glow.withValues(alpha: 0.18 + 0.1 * press),
            colors.background.window,
          ),
          shape: Neon.chamferBorder(
            cut: _cut,
            side: BorderSide(color: glow),
          ),
          shadows: Neon.boxGlow(glow, intensity: 0.7 + 0.3 * press),
        ),
        child: Center(
          child: AppIcon(
            AppIcons.shieldKeyhole,
            size: 24,
            color: colors.neon.core,
          ),
        ),
      ),
    );
  }
}
