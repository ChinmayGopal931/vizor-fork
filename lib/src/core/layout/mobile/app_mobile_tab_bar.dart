import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../feedback/app_haptics.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/mobile/tron_glyph.dart';

/// Height of [AppMobileTabBar] — Figma `Mobile Nav` (node 4394:88550):
/// 56px items inside 4px padding.
const double kMobileTabBarHeight = 64;

/// One destination in the floating mobile tab bar.
class AppMobileTabItem {
  const AppMobileTabItem({required this.iconName, required this.label});

  /// `AppIcons` name rendered at 28px.
  final String iconName;

  /// Accessibility label; the bar itself is icon-only.
  final String label;
}

/// The mobile tab bar. The neon redesign keeps only the glyphs: Tron line
/// icons ([TronGlyph]) floating over a fade, the active one lit, with a pool
/// of its light sliding under it. (Originally Figma `Mobile Nav`, node
/// 4394:88550.)
///
/// Selecting slides the light pool on a mild easeOutBack, crossfades the
/// glyph's light, pops the arriving glyph once, and presses with a light
/// haptic; all of it is instant under reduced motion.
class AppMobileTabBar extends StatelessWidget {
  const AppMobileTabBar({
    required this.items,
    required this.currentIndex,
    required this.onSelect,
    super.key,
  });

  final List<AppMobileTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onSelect;

  static const _itemHeight = 56.0;
  static const _glyphSize = 26.0;

  /// Selection transition — shared by the sliding pill and the icon
  /// tint so they read as one move. The curve is easeOutBack
  /// (cubic(0.34, 1.56, 0.64, 1)) with its back overshoot halved by
  /// lowering the second control point: ~5% past the target instead of
  /// the stock ~10%, which read as too springy.
  static const selectDuration = Duration(milliseconds: 240);
  static const _selectCurve = Cubic(0.34, 1.40, 0.64, 1.0);

  @visibleForTesting
  static const activePillKey = ValueKey('mobile_tab_bar_active_pill');

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final motion = !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final poolAlignment = Alignment(
      items.length > 1 ? -1 + 2 * currentIndex / (items.length - 1) : 0,
      0,
    );
    final light = colors.navPanel.activeIcon;

    // Only the glyphs: no slab, no border, no captions. The active glyph is
    // lit, and a pool of its light slides along under it.
    return SizedBox(
      height: kMobileTabBarHeight,
      child: Stack(
        children: [
          AnimatedAlign(
            key: activePillKey,
            duration: motion ? selectDuration : Duration.zero,
            curve: _selectCurve,
            alignment: poolAlignment,
            child: FractionallySizedBox(
              widthFactor: 1 / items.length,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        light.withValues(alpha: 0.22),
                        light.withValues(alpha: 0),
                      ],
                    ),
                  ),
                  child: const SizedBox.square(dimension: _itemHeight),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _TabBarItem(
                    item: items[i],
                    active: i == currentIndex,
                    motion: motion,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TabBarItem extends StatefulWidget {
  const _TabBarItem({
    required this.item,
    required this.active,
    required this.motion,
    required this.onTap,
  });

  final AppMobileTabItem item;
  final bool active;
  final bool motion;
  final VoidCallback onTap;

  @override
  State<_TabBarItem> createState() => _TabBarItemState();
}

class _TabBarItemState extends State<_TabBarItem>
    with SingleTickerProviderStateMixin {
  /// One-shot pop when this item becomes the active one — a small
  /// bounce timed to land with the arriving pill.
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<double> _popScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.12,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.12,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeIn)),
      weight: 55,
    ),
  ]).animate(_pop);

  var _pressed = false;

  @override
  void didUpdateWidget(covariant _TabBarItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active && widget.motion) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (!widget.motion || _pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Semantics(
      label: widget.item.label,
      button: true,
      selected: widget.active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: () {
          unawaited(AppHaptics.auxiliaryKey());
          widget.onTap();
        },
        child: SizedBox(
          height: AppMobileTabBar._itemHeight,
          child: Center(
            child: AnimatedScale(
              scale: _pressed ? 0.9 : 1.0,
              duration: Duration(milliseconds: _pressed ? 90 : 180),
              curve: _pressed ? Curves.easeOut : Curves.easeOutBack,
              child: ScaleTransition(
                scale: _popScale,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: widget.active ? 1 : 0),
                  duration: widget.motion
                      ? AppMobileTabBar.selectDuration
                      : Duration.zero,
                  builder: (_, lit, _) {
                    final color = Color.lerp(
                      colors.icon.muted,
                      colors.navPanel.activeIcon,
                      lit,
                    )!;
                    final glyph = _tronGlyphFor(widget.item.iconName);
                    if (glyph == null) {
                      return AppIcon(
                        widget.item.iconName,
                        size: AppMobileTabBar._glyphSize,
                        color: color,
                      );
                    }
                    return TronGlyph(
                      glyph,
                      color: color,
                      core: colors.neon.core,
                      lit: lit,
                      size: AppMobileTabBar._glyphSize,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tab bar draws its own line glyphs for the app's tabs; any other icon
/// keeps the icon set.
TronGlyphKind? _tronGlyphFor(String iconName) => switch (iconName) {
  AppIcons.home => TronGlyphKind.home,
  AppIcons.swapArrows => TronGlyphKind.swap,
  AppIcons.history => TronGlyphKind.activity,
  AppIcons.cog => TronGlyphKind.settings,
  _ => null,
};
