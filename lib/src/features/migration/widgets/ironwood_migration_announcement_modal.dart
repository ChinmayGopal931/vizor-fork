import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/mobile/neon_glyph_badge.dart';
import '../../../core/widgets/neon_glass_panel.dart';

class IronwoodMigrationAnnouncementModal extends StatelessWidget {
  const IronwoodMigrationAnnouncementModal({
    required this.onStartMigration,
    required this.onOpenReleaseNotes,
    super.key,
  });

  static const width = 312.0;
  static const height = 414.0;
  static const _contentWidth = 280.0;
  static const _heroHeight = 154.0;

  final VoidCallback onStartMigration;
  final VoidCallback onOpenReleaseNotes;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // An opaque neon glass panel over the pane; its hero is the phone
    // sheet's lit glyph badge in place of upstream's painted art.
    return SizedBox(
      key: const ValueKey('ironwood_migration_announcement_modal'),
      width: width,
      height: height,
      child: NeonGlassPanel(
        fill: colors.background.ground,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            const Positioned(
              left: 0,
              top: 0,
              width: width,
              height: _heroHeight,
              child: Center(
                child: NeonGlyphBadge(iconName: AppIcons.zcash, size: 100),
              ),
            ),
            Positioned(
              left: AppSpacing.sm,
              top: 168,
              width: _contentWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: SvgPicture.asset(
                      'assets/illustrations/ironwood_wordmark.svg',
                      width: 184,
                      height: 25,
                      colorFilter: ColorFilter.mode(
                        colors.text.accent,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                  const SizedBox(height: 13),
                  Text(
                    context.l10n.migrationAnnouncementBody,
                    textAlign: TextAlign.center,
                    style: AppTypography.bodyMedium.copyWith(
                      color: colors.text.primary,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: AppSpacing.sm,
              top: 290,
              width: _contentWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppButton(
                    key: const ValueKey(
                      'ironwood_migration_start_migration_button',
                    ),
                    onPressed: onStartMigration,
                    height: 44,
                    minWidth: _contentWidth,
                    expand: true,
                    constrainContent: true,
                    trailing: const AppIcon(AppIcons.chevronForward, size: 20),
                    child: Text(context.l10n.migrationAnnouncementStart),
                  ),
                  const SizedBox(height: 20),
                  AppButton(
                    key: const ValueKey(
                      'ironwood_migration_release_notes_button',
                    ),
                    onPressed: onOpenReleaseNotes,
                    variant: AppButtonVariant.ghost,
                    height: 36,
                    minWidth: _contentWidth,
                    expand: true,
                    constrainContent: true,
                    child: Text(context.l10n.migrationAnnouncementReleaseNote),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
