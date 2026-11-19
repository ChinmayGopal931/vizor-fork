import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../layout/app_form_factor.dart';
import '../theme/app_theme.dart';

/// Decorative divider used in onboarding hero sections and similar layouts.
///
/// The Figma component (node `422:8647`) is a 256 × 16 row:
/// faded line, ornament, faded line. It is purely decorative and should not
/// be used as a semantic section separator for assistive technologies.
class AppDecorativeDivider extends StatelessWidget {
  const AppDecorativeDivider({
    super.key,
    this.width = 256,
    this.middleWidth = 53.553,
    this.middleHeight = 14,
  });

  final double width;
  final double middleWidth;
  final double middleHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Desktop's divider is lit: faint red lines either side of a white-hot
    // diamond bead, in place of upstream's ornament. The phones keep theirs.
    if (kDesktopFormFactor) return _NeonDivider(width: width);
    final dividerColor = colors.text.primary;
    return SizedBox(
      width: width,
      height: 16,
      child: Row(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: dividerColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(AppRadii.full),
              ),
              child: const SizedBox(height: 1),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          SvgPicture.asset(
            'assets/illustrations/onboarding_intro_divider_middle.svg',
            width: middleWidth,
            height: middleHeight,
            colorMapper: _DividerColorMapper(dividerColor),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: dividerColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(AppRadii.full),
              ),
              child: const SizedBox(height: 1),
            ),
          ),
        ],
      ),
    );
  }
}

class _DividerColorMapper extends ColorMapper {
  const _DividerColorMapper(this.color);

  final Color color;

  @override
  Color substitute(
    String? id,
    String elementName,
    String attributeName,
    Color color,
  ) => this.color;
}

class _NeonDivider extends StatelessWidget {
  const _NeonDivider({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    Widget line() => Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(color: neon.glow.withValues(alpha: 0.3)),
        child: const SizedBox(height: 1),
      ),
    );
    return SizedBox(
      width: width,
      height: 16,
      child: Row(
        children: [
          line(),
          const SizedBox(width: AppSpacing.md),
          Transform.rotate(
            angle: 0.785398,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: neon.core,
                boxShadow: Neon.boxGlow(neon.glow, intensity: 0.8),
              ),
              child: const SizedBox.square(dimension: 6),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          line(),
        ],
      ),
    );
  }
}
