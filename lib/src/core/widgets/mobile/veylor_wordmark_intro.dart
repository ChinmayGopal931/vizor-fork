import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import 'neon_motion.dart';
import 'veylor_wordmark.dart';

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
    with SingleTickerProviderStateMixin, NeonAppearMotion<VeylorWordmarkIntro> {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: NeonMotion.intro,
    value: 1,
  );
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Never resume halfway after a trip to the background.
    _lifecycle = AppLifecycleListener(onHide: () => _controller.value = 1);
  }

  @override
  void onAppear() {
    if (VeylorWordmarkIntro._played) return;
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

  /// When the light cycle has traced the letters and the sign flickers on;
  /// the flicker runs to the end of [NeonMotion.intro].
  static const _ignitesAt = 1250;

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

    final end = NeonMotion.intro.inMilliseconds;
    final ms = t * end;
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
    if (ms < _ignitesAt) {
      _trail!.paint(
        canvas,
        Curves.easeInOutCubic.transform(NeonMotion.span(ms, 450, _ignitesAt)),
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
      intensity:
          _lit * NeonIgnition.lightAt(NeonMotion.span(ms, _ignitesAt, end)),
    );
  }

  @override
  bool shouldRepaint(_WordmarkIntroPainter oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core ||
      oldDelegate.screenWidth != screenWidth;
}
