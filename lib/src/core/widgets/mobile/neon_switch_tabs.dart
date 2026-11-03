import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';

/// A two-way switch (the Receive screen's pools, the Private USD Receive
/// sheet's tokens): a cut-corner glass track whose active side is a lit
/// plate, its label white-hot.
class NeonSwitchTabs extends StatelessWidget {
  const NeonSwitchTabs({
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.width = 256,
    this.height = 36,
    this.labelStyle,
    this.indicatorKey,
    this.tabKeys = (null, null),
    this.position,
    super.key,
  });

  /// The left option's label and the right one's.
  final (String, String) labels;

  /// 0 for the left option, 1 for the right.
  final int selected;
  final ValueChanged<int> onChanged;
  final double width;
  final double height;
  final TextStyle? labelStyle;
  final Key? indicatorKey;
  final (Key?, Key?) tabKeys;

  /// A pager's page (0 to 1) for the plate to follow mid-swipe; null slides
  /// it to [selected].
  final double? position;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final glow = colors.neon.glow;
    return Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(
        color: colors.button.secondary.bg,
        shape: Neon.chamferBorder(
          side: BorderSide(color: colors.border.subtleOpacity),
        ),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            // A tracked position already moves with the finger.
            duration: position == null
                ? const Duration(milliseconds: 160)
                : Duration.zero,
            curve: Curves.easeOut,
            alignment: Alignment(
              (position?.clamp(0.0, 1.0) ?? selected.toDouble()) * 2 - 1,
              0,
            ),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Container(
                key: indicatorKey,
                width: (width - 8) / 2,
                decoration: ShapeDecoration(
                  color: glow.withValues(alpha: 0.1),
                  // One step inside the track's cut, so the two run parallel.
                  shape: Neon.chamferBorder(
                    cut: AppChamfer.medium - 1,
                    side: BorderSide(color: glow.withValues(alpha: 0.85)),
                  ),
                  shadows: Neon.boxGlow(glow, intensity: 0.3),
                ),
              ),
            ),
          ),
          Row(
            children: [
              _NeonSwitchTab(
                key: tabKeys.$1,
                label: labels.$1,
                active: selected == 0,
                labelStyle: labelStyle,
                onTap: () => onChanged(0),
              ),
              _NeonSwitchTab(
                key: tabKeys.$2,
                label: labels.$2,
                active: selected == 1,
                labelStyle: labelStyle,
                onTap: () => onChanged(1),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NeonSwitchTab extends StatelessWidget {
  const _NeonSwitchTab({
    required this.label,
    required this.active,
    required this.labelStyle,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool active;
  final TextStyle? labelStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Expanded(
      child: MouseRegion(
        cursor: active ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: active ? null : onTap,
          child: SizedBox.expand(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: (labelStyle ?? AppTypography.labelMedium).copyWith(
                      color: active ? colors.neon.core : colors.text.secondary,
                      shadows: active
                          ? Neon.textGlow(colors.neon.glow, intensity: 0.4)
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
