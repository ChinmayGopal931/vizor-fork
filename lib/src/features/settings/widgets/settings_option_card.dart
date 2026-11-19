import 'package:flutter/material.dart';

import '../../../core/l10n/locale_typography.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/mobile/mobile_radio_card.dart';
import '../../../core/widgets/neon_option_panel.dart';

/// Applies [labelLocale]'s glyphs to a label written in another language,
/// such as a language's own name in a picker.
TextStyle _labelStyle(TextStyle style, Locale? labelLocale) {
  if (labelLocale == null) return style;
  return style.copyWith(fontFamilyFallback: fontFamilyFallbackFor(labelLocale));
}

/// A selectable row of a desktop settings picker modal (theme, language).
class SettingsOptionCard extends StatelessWidget {
  const SettingsOptionCard({
    required this.label,
    required this.selected,
    required this.onTap,
    this.iconName,
    this.labelLocale,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? iconName;
  final Locale? labelLocale;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final iconName = this.iconName;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: NeonOptionPanel(
          selected: selected,
          constraints: const BoxConstraints.tightFor(height: 40),
          padding: EdgeInsets.only(
            left: iconName == null ? AppSpacing.s : AppSpacing.xs,
            right: AppSpacing.s,
          ),
          child: Row(
            children: [
              if (iconName != null) ...[
                SizedBox(
                  width: 32,
                  height: 32,
                  child: Center(
                    child: AppIcon(
                      iconName,
                      size: 18,
                      color: selected
                          ? colors.icon.accent
                          : colors.icon.accent.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              Expanded(
                child: Text(
                  label,
                  locale: labelLocale,
                  overflow: TextOverflow.ellipsis,
                  style: _labelStyle(
                    AppTypography.labelMedium.copyWith(
                      color: colors.text.accent,
                      fontWeight: selected
                          ? AppFontWeight.semiBold
                          : AppFontWeight.medium,
                    ),
                    labelLocale,
                  ),
                ),
              ),
              _SettingsOptionIndicator(selected: selected),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsOptionIndicator extends StatelessWidget {
  const _SettingsOptionIndicator({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return NeonOptionCheck(selected: selected);
  }
}

/// A selectable row of a mobile settings picker sheet — Figma `Theme Modal`
/// (4494:92272): the standard [MobileRadioCard].
class MobileSettingsOptionCard extends StatelessWidget {
  const MobileSettingsOptionCard({
    required this.label,
    required this.selected,
    required this.onTap,
    this.iconName,
    this.labelLocale,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? iconName;
  final Locale? labelLocale;

  @override
  Widget build(BuildContext context) => MobileRadioCard(
    title: label,
    selected: selected,
    onTap: onTap,
    iconName: iconName,
    titleLocale: labelLocale,
  );
}
