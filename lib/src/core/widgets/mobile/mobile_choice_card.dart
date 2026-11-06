import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../feedback/app_haptics.dart';
import '../../theme/app_theme.dart';
import '../app_icon.dart';

/// One of a few choices in a sheet: an icon, a label, a line under it, and a
/// check once chosen. A tap on an unchosen card calls [onTap] with a
/// selection haptic; a chosen or disabled card ignores the tap.
class MobileChoiceCard extends StatelessWidget {
  const MobileChoiceCard({
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    super.key,
  });

  /// An [AppIcons] name.
  final String icon;
  final String label;
  final String description;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: '$label. $description',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!enabled || selected) return;
          unawaited(AppHaptics.selection());
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: colors.background.ground,
            borderRadius: BorderRadius.circular(AppRadii.medium),
            border: Border.all(
              color: selected ? colors.border.strong : colors.border.subtle,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Opacity(
                opacity: selected ? 1 : 0.5,
                child: AppIcon(icon, size: 20, color: colors.icon.accent),
              ),
              const SizedBox(width: AppSpacing.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTypography.bodyMediumStrong.copyWith(
                        color: colors.text.accent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Opacity(
                      opacity: 0.7,
                      child: Text(
                        description,
                        style: AppTypography.bodySmall.copyWith(
                          color: colors.text.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: AppSpacing.s),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: colors.background.inverse,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: AppIcon(
                      AppIcons.check,
                      size: 14,
                      color: colors.text.inverse,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
