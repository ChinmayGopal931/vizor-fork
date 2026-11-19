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

/// [NeonGlassPanel]'s look as a [Decoration], for a card that is a
/// `Container` both form factors build: desktop swaps its decoration for this
/// one (`decoration: desktop ? NeonGlassDecoration.themed(...) : ...`) and
/// keeps the rest of the widget as it was.
class NeonGlassDecoration extends Decoration {
  const NeonGlassDecoration({
    required this.fill,
    required this.glow,
    required this.core,
    this.cut = AppChamfer.large,
  });

  /// The glass in [colors]: the window colour at 62% unless [fill] is given.
  factory NeonGlassDecoration.themed(
    AppColors colors, {
    Color? fill,
    double cut = AppChamfer.large,
  }) => NeonGlassDecoration(
    fill: fill ?? colors.background.window.withValues(alpha: 0.62),
    glow: colors.neon.glow,
    core: colors.neon.core,
    cut: cut,
  );

  final Color fill;
  final Color glow;
  final Color core;
  final double cut;

  @override
  Path getClipPath(Rect rect, TextDirection textDirection) =>
      Neon.wedgeBorder(cut: cut).getOuterPath(rect);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _NeonGlassBoxPainter(this, onChanged);

  @override
  bool operator ==(Object other) =>
      other is NeonGlassDecoration &&
      other.fill == fill &&
      other.glow == glow &&
      other.core == core &&
      other.cut == cut;

  @override
  int get hashCode => Object.hash(fill, glow, core, cut);
}

class _NeonGlassBoxPainter extends BoxPainter {
  _NeonGlassBoxPainter(this._decoration, super.onChanged);

  final NeonGlassDecoration _decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    NeonGlassPanelPainter(
      fill: _decoration.fill,
      glow: _decoration.glow,
      core: _decoration.core,
      cut: _decoration.cut,
    ).paint(canvas, size);
    canvas.restore();
  }
}
