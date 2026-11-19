import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/mobile/tron_glyph.dart';
import 'app_mobile_tab_bar.dart';
import 'neon_sync_backdrop.dart';

/// A sidebar destination's glyph: its [TronGlyph], lit while [selected] and
/// standing in a pool of its light, as the tab bar lights its active tab.
/// The light crossfades to a newly selected row, at once under reduced
/// motion.
class NeonSidebarGlyph extends StatelessWidget {
  const NeonSidebarGlyph({
    required this.item,
    required this.selected,
    this.glyph,
    this.dimension = size,
    this.wasSelected,
    super.key,
  });

  final AppMobileTabItem item;
  final bool selected;

  /// The glyph to draw; null draws [item]'s ([AppMobileTabItem.glyph]). The
  /// desktop sidebar names glyphs for destinations the tab bar does not have.
  final TronGlyphKind? glyph;

  /// The glyph's square; its pool of light scales with it.
  final double dimension;

  /// Whether the row was lit when this glyph first showed. Desktop builds a
  /// new sidebar on every page, so it passes the last page's light here and
  /// the light crossfades from the row that had it. Null starts as
  /// [selected].
  final bool? wasSelected;

  static const size = 24.0;
  static const _poolSize = 56.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final light = colors.navPanel.activeIcon;
    final motion = !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final poolSize = _poolSize * dimension / size;
    return TweenAnimationBuilder<double>(
      tween: Tween(
        begin: switch (wasSelected) {
          null => null,
          final lit => lit ? 1.0 : 0.0,
        },
        end: selected ? 1 : 0,
      ),
      duration: motion ? AppMobileTabBar.selectDuration : Duration.zero,
      builder: (context, lit, _) {
        final color = Color.lerp(colors.icon.muted, light, lit)!;
        final glyph = this.glyph ?? item.glyph;
        return SizedBox.square(
          dimension: dimension,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: (dimension - poolSize) / 2,
                top: (dimension - poolSize) / 2,
                width: poolSize,
                height: poolSize,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        light.withValues(alpha: 0.22 * lit),
                        light.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              if (glyph == null)
                AppIcon(item.iconName, size: dimension, color: color)
              else
                TronGlyph(
                  glyph,
                  color: color,
                  core: colors.neon.core,
                  lit: lit,
                  size: dimension,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The sidebar's sync readout, for the pages that have no sync line of their
/// own: a short line in the glyphs' column that rises with the scan as
/// Home's does, and its readout beside it as a red HUD caption.
///
/// The line breathes while it climbs, and holds still under reduced motion.
class NeonSidebarSyncReadout extends StatefulWidget {
  const NeonSidebarSyncReadout({
    required this.line,
    this.textKey,
    this.glow,
    this.core,
    this.textFirst = false,
    super.key,
  });

  final NeonSyncLine line;

  /// Keys the readout's text; the desktop sidebar keeps the key its sync
  /// status had, which its end-to-end tests read.
  final Key? textKey;

  /// The light of the line and its readout; the red neon light when null.
  /// The desktop sidebar draws Railgun's sync in steel beside the wallet's.
  final Color? glow;
  final Color? core;

  /// Puts the readout before the line, aligned to it: the desktop sidebar's
  /// left readout, when two stand side by side.
  final bool textFirst;

  @override
  State<NeonSidebarSyncReadout> createState() => _NeonSidebarSyncReadoutState();
}

class _NeonSidebarSyncReadoutState extends State<NeonSidebarSyncReadout>
    with SingleTickerProviderStateMixin {
  static const _lineHeight = 28.0;

  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  bool get _breathes =>
      widget.line.climbing &&
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBreath();
  }

  @override
  void didUpdateWidget(NeonSidebarSyncReadout oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBreath();
  }

  void _syncBreath() {
    if (!_breathes) {
      // At rest the line holds the middle of its breath.
      _breath.stop();
      if (_breath.value != 0) _breath.value = 0;
    } else if (!_breath.isAnimating) {
      _breath.repeat();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final neon = context.colors.neon;
    final glow = widget.glow ?? neon.glow;
    final core = widget.core ?? neon.core;
    final lineBox = SizedBox(
      width: NeonSidebarGlyph.size,
      height: _lineHeight,
      child: CustomPaint(
        painter: _SidebarSyncLinePainter(
          breath: _breath,
          line: line,
          glow: glow,
          core: core,
        ),
      ),
    );
    final readout = Expanded(
      child: Text(
        line.readout.toUpperCase(),
        key: widget.textKey,
        textAlign: widget.textFirst ? TextAlign.end : null,
        style: kNeonHudCaptionStyle.copyWith(
          color: glow,
          shadows: Neon.textGlow(glow, intensity: 0.35),
        ),
      ),
    );
    const gap = SizedBox(width: AppSpacing.s);
    return Semantics(
      label: line.semanticsLabel,
      excludeSemantics: true,
      liveRegion: line.failed,
      child: Row(
        children: widget.textFirst
            ? [readout, gap, lineBox]
            : [lineBox, gap, readout],
      ),
    );
  }
}

class _SidebarSyncLinePainter extends CustomPainter {
  _SidebarSyncLinePainter({
    required this.breath,
    required this.line,
    required this.glow,
    required this.core,
  }) : super(repaint: breath);

  final Animation<double> breath;
  final NeonSyncLine line;
  final Color glow;
  final Color core;

  @override
  void paint(Canvas canvas, Size size) {
    final x = (size.width / 2).roundToDouble() + 0.5;
    final headY = size.height * (1 - line.progress.clamp(0.0, 1.0));
    // Home's intensities: lit while it climbs, quiet once synced, dim when
    // the sync failed.
    final intensity = line.failed
        ? 0.4
        : line.climbing
        ? 0.8 + 0.2 * math.sin(2 * math.pi * breath.value)
        : 0.6;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = glow.withValues(alpha: 0.2)
        ..strokeWidth = 1,
    );
    Neon.strokeTube(
      canvas,
      Path()
        ..moveTo(x, size.height)
        ..lineTo(x, headY),
      glow: glow,
      core: core,
      width: 1.6,
      intensity: intensity,
    );
    Neon.bead(
      canvas,
      Offset(x, headY),
      glow: glow,
      core: core,
      size: 5,
      halo: 3,
      blur: 4,
      rim: 1.5,
      intensity: intensity,
    );
  }

  @override
  bool shouldRepaint(_SidebarSyncLinePainter oldDelegate) =>
      oldDelegate.line.progress != line.progress ||
      oldDelegate.line.climbing != line.climbing ||
      oldDelegate.line.failed != line.failed ||
      oldDelegate.glow != glow ||
      oldDelegate.core != core;
}
