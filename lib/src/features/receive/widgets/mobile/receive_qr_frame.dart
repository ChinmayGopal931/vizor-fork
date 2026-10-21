import 'package:flutter/widgets.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/mobile/neon_motion.dart';

/// Space between [ReceiveQrFrame]'s lit outline and the code's plate.
const double kReceiveQrFrameGap = AppSpacing.xs;

/// The lit cut-corner frame the mobile receive and request codes sit in.
///
/// Only the frame is lit. The code keeps its own light plate inside it, dark
/// modules on a light ground, and the frame paints behind that plate, so its
/// glow never reaches the code a camera reads. It switches on with a sign's
/// flicker ([NeonIgnition]) the first time it appears.
class ReceiveQrFrame extends StatelessWidget {
  const ReceiveQrFrame({this.child, super.key});

  /// The code's plate, inset by [kReceiveQrFrameGap]. Without one the frame
  /// fills the size it is given, for a caller that lays the codes over it.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final child = this.child;
    return NeonIgnition(
      builder: (context, light) => CustomPaint(
        painter: _ReceiveQrFramePainter(
          glow: colors.neon.glow,
          core: colors.neon.core,
          light: light,
        ),
        child: child == null
            ? null
            : Padding(
                padding: const EdgeInsets.all(kReceiveQrFrameGap),
                child: child,
              ),
      ),
    );
  }
}

/// A chamfered outline lit low along its edges and full at its four cuts, as
/// the glass panels light theirs.
class _ReceiveQrFramePainter extends CustomPainter {
  const _ReceiveQrFramePainter({
    required this.glow,
    required this.core,
    required this.light,
  });

  final Color glow;
  final Color core;

  /// The ignition's light level, 0..1.
  final double light;

  static const _cut = AppChamfer.xLarge;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.75);
    final outline = Neon.chamferedRect(
      rect,
      topLeft: _cut,
      topRight: _cut,
      bottomRight: _cut,
      bottomLeft: _cut,
    );
    Neon.strokeTube(
      canvas,
      outline,
      glow: glow,
      core: core,
      width: 1.2,
      intensity: 0.55 * light,
    );
    Neon.strokeTube(
      canvas,
      Neon.chamferCuts(
        rect,
        topLeft: _cut,
        topRight: _cut,
        bottomRight: _cut,
        bottomLeft: _cut,
      ),
      glow: glow,
      core: core,
      width: 1.6,
      intensity: light,
    );
  }

  @override
  bool shouldRepaint(_ReceiveQrFramePainter oldDelegate) =>
      oldDelegate.glow != glow ||
      oldDelegate.core != core ||
      oldDelegate.light != light;
}
