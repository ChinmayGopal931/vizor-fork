import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../app_icon.dart';

/// A tappable home card: an icon, a title with a chevron, and a subtitle.
/// [emphasized] is the raised card the home screen uses for what needs the
/// user (the backup reminder, a conversion under way); the plain one is for
/// entries such as coinholder voting. Shared by home and the Private USD
/// screen.
class MobileHomeEntryCard extends StatelessWidget {
  const MobileHomeEntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.emphasized = false,
    this.showChevron = true,
    this.semanticsLabel,
    super.key,
  });

  final String icon;
  final String title;
  final String subtitle;
  final bool emphasized;
  final bool showChevron;

  /// Replaces [title] as the spoken name; the subtitle is always read after.
  final String? semanticsLabel;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      // One item for screen readers whether or not it is tappable.
      container: true,
      button: true,
      label: '${semanticsLabel ?? title}\n$subtitle',
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: emphasized ? 88 : 77),
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: emphasized ? AppSpacing.sm : AppSpacing.s,
          ),
          decoration: BoxDecoration(
            color: emphasized ? colors.surface.card : colors.background.ground,
            borderRadius: BorderRadius.circular(AppRadii.large),
            boxShadow: emphasized ? appSurfaceShadow(colors) : null,
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.large),
            border: emphasized
                ? Border.all(color: colors.border.regular)
                : Border.all(color: const Color(0x12FFFFFF), width: 1.5),
          ),
          child: Padding(
            padding: emphasized
                ? EdgeInsets.zero
                : const EdgeInsets.all(AppSpacing.xxs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (emphasized)
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: colors.background.brandCrimsonSubtle,
                      borderRadius: BorderRadius.circular(AppRadii.xSmall),
                    ),
                    alignment: Alignment.center,
                    child: AppIcon(
                      icon,
                      size: 20,
                      color: colors.icon.brandCrimson,
                    ),
                  )
                else
                  AppIcon(icon, size: 20, color: colors.icon.accent),
                const SizedBox(width: AppSpacing.s),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: emphasized ? null : 1,
                              overflow: emphasized
                                  ? null
                                  : TextOverflow.ellipsis,
                              style: AppTypography.labelLarge.copyWith(
                                color: colors.text.accent,
                              ),
                            ),
                          ),
                          if (showChevron)
                            AppIcon(
                              AppIcons.chevronForward,
                              size: 20,
                              color: colors.icon.accent,
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        subtitle,
                        maxLines: emphasized ? null : 1,
                        overflow: emphasized ? null : TextOverflow.ellipsis,
                        style: AppTypography.bodyMedium.copyWith(
                          color: colors.text.secondary,
                          height: 17 / 16,
                          letterSpacing: -0.04,
                        ),
                      ),
                    ],
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
