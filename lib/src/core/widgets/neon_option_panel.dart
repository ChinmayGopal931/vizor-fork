import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import 'app_icon.dart';
import 'neon_glass_panel.dart';

/// A choice among others in the neon look (desktop): a [NeonGlassPanel],
/// its two cut corners lit, whose whole outline a selection strokes.
///
/// The phone's radio cards are the same glass with a strong edge once
/// selected; desktop's option rows (endpoints, explorers, themes) draw this.
class NeonOptionPanel extends StatelessWidget {
  const NeonOptionPanel({
    required this.child,
    this.selected = false,
    this.selectedColor,
    this.hovered = false,
    this.padding = EdgeInsets.zero,
    this.cut = AppChamfer.medium,
    this.constraints,
    super.key,
  });

  final Widget child;

  /// Strokes the outline, in [selectedColor] (the strong border colour when
  /// null).
  final bool selected;
  final Color? selectedColor;

  /// Lifts the glass toward the hover fill.
  final bool hovered;
  final EdgeInsetsGeometry padding;
  final double cut;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget panel = NeonGlassPanel(
      cut: cut,
      fill: hovered ? colors.state.hover : null,
      padding: padding,
      child: child,
    );
    if (constraints case final constraints?) {
      panel = ConstrainedBox(constraints: constraints, child: panel);
    }
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: ShapeDecoration(
        shape: Neon.wedgeBorder(cut: cut).copyWith(
          side: selected
              ? BorderSide(
                  color: selectedColor ?? colors.border.strong,
                  width: 2,
                )
              : BorderSide.none,
        ),
      ),
      child: panel,
    );
  }
}

/// An option's check in the neon look (desktop): a cut-corner plate, filled
/// white with a check when [selected], an unlit plate otherwise. It stands in
/// for upstream's round radio check.
class NeonOptionCheck extends StatelessWidget {
  const NeonOptionCheck({
    required this.selected,
    this.size = 16,
    this.checkSize = 12,
    this.unselectedColor,
    super.key,
  });

  final bool selected;
  final double size;
  final double checkSize;

  /// The unlit plate's fill; the subtle neutral when null.
  final Color? unselectedColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: selected
            ? colors.background.inverse
            : unselectedColor ?? colors.background.neutralSubtleOpacity,
        shape: Neon.chamferBorder(cut: size / 5),
      ),
      child: selected
          ? Center(
              child: AppIcon(
                AppIcons.check,
                size: checkSize,
                color: colors.background.ground,
              ),
            )
          : null,
    );
  }
}
