import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_security_provider.dart';
import '../../layout/app_form_factor.dart';
import '../../theme/app_theme.dart';
import 'neon_motion.dart';
import 'veylor_wordmark.dart';

final _revealRequests = ValueNotifier<int>(0);

/// Plays the unlock reveal over whatever the router shows next. Call it
/// only after a successful unlock, just before navigating into the app.
void requestUnlockReveal() {
  if (kAppFormFactor != AppFormFactor.mobile) return;
  _revealRequests.value++;
}

/// The curtain that carries the unlock backdrop into the app: the lit
/// wordmark collapses into a scanline and the black splits along it,
/// showing the app beneath. It blocks touches while it plays, removes
/// itself after [NeonMotion.revealTimeout] whatever happens, and is gone at
/// once if the wallet locks.
class UnlockRevealHost extends ConsumerStatefulWidget {
  const UnlockRevealHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<UnlockRevealHost> createState() => _UnlockRevealHostState();
}

class _UnlockRevealHostState extends ConsumerState<UnlockRevealHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: NeonMotion.reveal)
        ..addListener(_onTick)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) _end();
        });
  Timer? _timeout;
  var _active = false;
  var _hapticDone = false;

  @override
  void initState() {
    super.initState();
    _revealRequests.addListener(_start);
  }

  @override
  void dispose() {
    _revealRequests.removeListener(_start);
    _timeout?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    if (!mounted || NeonMotion.reduced(context)) return;
    _timeout?.cancel();
    _timeout = Timer(NeonMotion.revealTimeout, _end);
    _hapticDone = false;
    setState(() => _active = true);
    _controller.forward(from: 0);
  }

  void _onTick() {
    if (_hapticDone || _controller.value < _splitStart) return;
    _hapticDone = true;
    unawaited(HapticFeedback.lightImpact());
  }

  void _end() {
    _timeout?.cancel();
    _timeout = null;
    _controller.stop();
    if (_active && mounted) setState(() => _active = false);
  }

  static const _splitStart = 300 / 760;

  @override
  Widget build(BuildContext context) {
    ref.listen(appSecurityProvider.select((s) => s.requiresUnlock), (
      _,
      locked,
    ) {
      if (locked) _end();
    });
    final colors = context.colors;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_active)
          Positioned.fill(
            child: AbsorbPointer(
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _RevealPainter(
                      animation: _controller,
                      black: colors.background.window,
                      glow: colors.neon.glow,
                      core: colors.neon.core,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RevealPainter extends CustomPainter {
  _RevealPainter({
    required this.animation,
    required this.black,
    required this.glow,
    required this.core,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color black;
  final Color glow;
  final Color core;

  @override
  void paint(Canvas canvas, Size size) {
    final ms = animation.value * NeonMotion.reveal.inMilliseconds;
    final w = size.width;
    final h = size.height;
    final cy = h * (1 + NeonMotion.wordmarkAlignment.y) / 2;
    final split = Curves.easeInOutCubic.transform(
      NeonMotion.span(ms, 300, 760),
    );
    final top = cy - split * cy;
    final bottom = cy + split * (h - cy);
    final fill = Paint()..color = black;
    canvas
      ..drawRect(Rect.fromLTRB(0, 0, w, top), fill)
      ..drawRect(Rect.fromLTRB(0, bottom, w, h), fill);

    if (ms < 300) {
      // The wordmark brightens, then folds flat into a scanline.
      final box = Rect.fromCenter(
        center: Offset(w / 2, cy),
        width: NeonMotion.wordmarkSize.width,
        height: NeonMotion.wordmarkSize.height,
      );
      final art = VeylorWordmarkPainter.geometry(box.size);
      final collapse = Curves.easeInCubic.transform(
        NeonMotion.span(ms, 110, 260),
      );
      if (art != null && collapse < 1) {
        canvas
          ..save()
          ..translate(box.center.dx, box.center.dy)
          ..scale(1, 1 - collapse)
          ..translate(-box.width / 2, -box.height / 2);
        Neon.strokeTube(
          canvas,
          art.path,
          glow: glow,
          core: core,
          width: art.width,
          intensity: 0.75 + 0.25 * NeonMotion.span(ms, 0, 110),
        );
        canvas.restore();
      }
      final reach = Curves.easeOutCubic.transform(
        NeonMotion.span(ms, 180, 300),
      );
      if (collapse > 0) {
        final half = box.width / 2 + (w / 2 - box.width / 2) * reach;
        paintNeonScanline(
          canvas,
          cy,
          w / 2 - half,
          w / 2 + half,
          glow: glow,
          core: core,
          intensity: collapse,
        );
      }
      return;
    }

    // The two halves part, their lit edges fading as they go.
    final edge = 1 - NeonMotion.span(ms, 300, 640);
    for (final y in [top, bottom]) {
      paintNeonScanline(
        canvas,
        y,
        0,
        w,
        glow: glow,
        core: core,
        intensity: edge,
      );
    }
  }

  @override
  bool shouldRepaint(_RevealPainter oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.black != black ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core;
}
