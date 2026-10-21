import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../app_icon.dart';
import 'tron_glyph.dart';

/// A hero or status mark: one lit glyph on a cut-corner plate. Give it a
/// [glyph] (drawn as a neon tube), an [iconName] from `AppIcons`, or any
/// [child] for shapes the glyphs lack.
class NeonGlyphBadge extends StatelessWidget {
  const NeonGlyphBadge({
    this.glyph,
    this.iconName,
    this.child,
    this.size = 96,
    super.key,
  }) : assert(glyph != null || iconName != null || child != null);

  final TronGlyphKind? glyph;
  final String? iconName;

  /// Any other mark, drawn in the core colour (through `IconTheme`).
  final Widget? child;
  final double size;

  /// The mark's share of the badge's side.
  static const markScale = 0.46;

  /// How far the plate's corner cuts reach, as a share of its side.
  static const cutScale = 0.2;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    final inner = size * markScale;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: neon.glow.withValues(alpha: 0.07),
        shape: Neon.chamferBorder(
          cut: size * cutScale,
          side: BorderSide(color: neon.glow.withValues(alpha: 0.55)),
        ),
        shadows: Neon.boxGlow(neon.glow, intensity: 0.35),
      ),
      child: glyph != null
          ? TronGlyph(
              glyph!,
              color: neon.glow,
              core: neon.core,
              lit: 1,
              size: inner,
            )
          : iconName != null
          ? AppIcon(iconName!, size: inner, color: neon.core)
          : IconTheme.merge(
              data: IconThemeData(color: neon.core, size: inner),
              child: child!,
            ),
    );
  }
}
