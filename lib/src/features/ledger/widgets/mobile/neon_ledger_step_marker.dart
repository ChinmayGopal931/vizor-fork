import 'package:flutter/widgets.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/mobile/neon_motion.dart';
import '../../../../core/widgets/mobile/tron_glyph.dart';

/// Where a step stands in a Ledger procedure.
enum LedgerStepProgress { done, current, ahead }

/// A Ledger procedure step's marker in the neon look, on the cut-corner plate
/// of the check glyph: a done step's check lit red, the current step's
/// ordinal on a lit plate that switches on as the step begins, and a step
/// ahead's ordinal on an unlit plate.
class NeonLedgerStepMarker extends StatelessWidget {
  const NeonLedgerStepMarker({
    required this.ordinal,
    required this.progress,
    required this.size,
    required this.style,
    super.key,
  });

  final int ordinal;
  final LedgerStepProgress progress;

  /// The marker's square. It scales with the text.
  final double size;

  /// The ordinal's style. Its metrics are the step label's, which keeps the
  /// two on one baseline.
  final TextStyle style;

  /// How lit a done step's check is, as the swap timeline's.
  static const doneLight = 0.45;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final neon = colors.neon;
    return switch (progress) {
      LedgerStepProgress.done => TronGlyph(
        TronGlyphKind.check,
        color: neon.glow,
        core: neon.core,
        lit: doneLight,
        size: size,
      ),
      LedgerStepProgress.current => NeonIgnition(
        builder: (context, light) => _OrdinalPlate(
          ordinal: ordinal,
          size: size,
          style: style.copyWith(
            color: Color.lerp(colors.text.secondary, neon.core, light),
            shadows: Neon.textGlow(neon.glow, intensity: 0.4 * light),
          ),
          painter: _PlatePainter(
            color: neon.glow,
            core: neon.core,
            light: light,
          ),
        ),
      ),
      LedgerStepProgress.ahead => _OrdinalPlate(
        ordinal: ordinal,
        size: size,
        style: style.copyWith(color: colors.text.secondary),
        painter: _PlatePainter(color: colors.text.muted),
      ),
    };
  }
}

class _OrdinalPlate extends StatelessWidget {
  const _OrdinalPlate({
    required this.ordinal,
    required this.size,
    required this.style,
    required this.painter,
  });

  final int ordinal;
  final double size;
  final TextStyle style;
  final CustomPainter painter;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      CustomPaint(size: Size.square(size), painter: painter),
      Text('$ordinal', style: style),
    ],
  );
}

/// The check glyph's plate around an ordinal: a lit tube over a faint red
/// fill when [core] is given, otherwise a thin unlit line.
class _PlatePainter extends CustomPainter {
  _PlatePainter({required this.color, this.core, this.light = 0});

  final Color color;
  final Color? core;
  final double light;

  @override
  void paint(Canvas canvas, Size size) {
    final plate = TronGlyph.platePath(size.width);
    // The glyph's own line widths, lit and unlit.
    final u = size.width / 24;
    final core = this.core;
    if (core == null) {
      Neon.strokeUnlit(canvas, plate, color: color, width: 1.6 * u);
      return;
    }
    canvas.drawPath(
      plate,
      Paint()..color = color.withValues(alpha: 0.16 * light),
    );
    Neon.strokeTube(
      canvas,
      plate,
      glow: color,
      core: core,
      width: 1.7 * u,
      intensity: light,
    );
    if (light < 1) {
      Neon.strokeUnlit(
        canvas,
        plate,
        color: color.withValues(alpha: 1 - light),
        width: 1.6 * u,
      );
    }
  }

  @override
  bool shouldRepaint(_PlatePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.core != core ||
      oldDelegate.light != light;
}
