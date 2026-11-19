import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import 'mobile/mobile_surface_card.dart' show NeonGlassPanelPainter;

/// A card or panel in the neon look: glass cut at its top-left and
/// bottom-right corners, with a faint red edge and the two cuts lit
/// ([NeonGlassPanelPainter]).
///
/// Desktop's cards and panels draw it; `MobileSurfaceCard` is the same panel
/// on mobile.
class NeonGlassPanel extends StatelessWidget {
  const NeonGlassPanel({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.cut = AppChamfer.large,
    this.fill,
    this.clipBehavior = Clip.none,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// How far the two corner cuts reach.
  final double cut;

  /// The panel's fill. Null is glass: the window colour at 62%. A panel that
  /// floats over content, such as a modal, passes an opaque one.
  final Color? fill;

  /// Clips the content to the panel's outline when not [Clip.none].
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget content = Padding(padding: padding, child: child);
    if (clipBehavior != Clip.none) {
      content = ClipPath(
        clipper: ShapeBorderClipper(shape: Neon.wedgeBorder(cut: cut)),
        clipBehavior: clipBehavior,
        child: content,
      );
    }
    return CustomPaint(
      painter: NeonGlassPanelPainter(
        fill: fill ?? colors.background.window.withValues(alpha: 0.62),
        glow: colors.neon.glow,
        core: colors.neon.core,
        cut: cut,
      ),
      child: content,
    );
  }
}
