import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/mobile/veylor_wordmark.dart';

class OnboardingWelcomeBackdrop extends StatelessWidget {
  const OnboardingWelcomeBackdrop({
    super.key,
    this.fit = BoxFit.fill,
    this.alignment = Alignment.center,
  });

  final BoxFit fit;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.of(context) == AppThemeData.dark;
    final asset = isDark
        ? 'assets/illustrations/welcome_bg_dark.webp'
        : 'assets/illustrations/welcome_bg_light.webp';
    return Image.asset(asset, fit: fit, alignment: alignment);
  }
}

const _vizorWordmarkFrameWidth = 140.0;
const _vizorWordmarkFrameHeight = 52.83;

/// The VEYLOR wordmark, drawn as a lit tube, or as plain lines in [color]
/// where a caller sets one. The 140×52.83 frame is upstream's Figma frame for
/// its wordmark, which Veylor no longer draws.
class VizorWordmark extends StatelessWidget {
  const VizorWordmark({
    super.key,
    this.width = _vizorWordmarkFrameWidth,
    this.height = _vizorWordmarkFrameHeight,
    this.color,
  });

  final double width;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: VeylorWordmarkPainter(
          glow: color ?? colors.neon.glow,
          core: colors.neon.core,
          lit: color == null,
        ),
      ),
    );
  }
}
