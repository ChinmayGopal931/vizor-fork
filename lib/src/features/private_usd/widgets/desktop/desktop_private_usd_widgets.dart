import 'package:flutter/material.dart' show Colors, Dialog, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/layout/app_desktop_shell.dart';
import '../../../../core/layout/app_main_sidebar.dart';
import '../../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../../core/layout/mobile/neon_sync_backdrop.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_icon_hover_button.dart';
import '../../../../core/widgets/app_modal_card.dart';
import '../../../../core/widgets/neon_glass_panel.dart';
import '../../../../core/widgets/neon_page_title.dart';

/// How wide the Shielded USD pages' column runs: the chart page's, wider
/// than Home's, so a ledger row and an address have room.
const kDesktopPrivateUsdContentWidth = 560.0;

/// A desktop Shielded USD page: the main sidebar, and in the pane the back
/// link (with the info button on its right), the page title and [children]
/// in a centred column.
///
/// With a [syncLine], Railgun's sync is drawn as Home's pane draws the
/// wallet's: the floor and the synced line behind the content, the climbing
/// line and its readout in front, ignoring the pointer. Blocks that should
/// hide a synced line behind them wrap themselves in [NeonSyncOcclude].
class DesktopPrivateUsdPage extends StatelessWidget {
  const DesktopPrivateUsdPage({
    required this.title,
    required this.children,
    this.onInfo,
    this.syncLine,
    this.canGoBack = true,
    this.onBeforeBack,
    this.contentKey,
    this.titleKey,
    super.key,
  });

  final String title;
  final List<Widget> children;

  /// Opens the page's info; null hides the button.
  final VoidCallback? onInfo;
  final NeonSyncLine? syncLine;

  /// False while a step holds the page (a send proving): no back link, and
  /// the sidebar is veiled and takes neither the pointer nor the keyboard, as
  /// the phone's wide-window sidebar is through its Private USD flows. An
  /// account switch or a sign-out would close the Railgun page mid-proof.
  final bool canGoBack;

  /// Runs before the back link navigates.
  final VoidCallback? onBeforeBack;
  final Key? contentKey;
  final Key? titleKey;

  @override
  Widget build(BuildContext context) {
    final onInfo = this.onInfo;
    final syncLine = this.syncLine;
    Widget column(bool occlude) {
      Widget title = NeonPageTitle(
        this.title,
        textKey: titleKey,
        textAlign: TextAlign.center,
      );
      if (occlude) title = NeonSyncOcclude(child: title);
      return AppPaneScrollScaffold(
        toolbar: AppPaneToolbar(
          onBeforeNavigate: onBeforeBack,
          leading: canGoBack ? null : const SizedBox.shrink(),
          trailing: onInfo == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.s),
                  child: AppIconHoverButton(
                    key: const ValueKey('desktop_private_usd_info'),
                    icon: AppIcons.help,
                    semanticLabel: context.l10n.privateUsdInfoButton,
                    tooltip: context.l10n.privateUsdInfoButton,
                    onTap: onInfo,
                  ),
                ),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s,
          AppSpacing.sm,
          AppSpacing.s,
          AppSpacing.lg,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kDesktopPrivateUsdContentWidth,
            ),
            child: Column(
              key: contentKey,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [title, const SizedBox(height: AppSpacing.md), ...children],
            ),
          ),
        ),
      );
    }

    final Widget pane = syncLine == null
        ? column(false)
        : NeonSyncScrolled(
            builder: (context, scrolled) => Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: NeonSyncLineLayer(
                    key: const ValueKey('desktop_private_usd_sync_back'),
                    line: syncLine,
                    scrolled: scrolled,
                  ),
                ),
                column(true),
                Positioned.fill(
                  child: NeonSyncLineLayer(
                    key: const ValueKey('desktop_private_usd_sync_front'),
                    line: syncLine,
                    layer: NeonSyncLayer.front,
                    scrolled: scrolled,
                  ),
                ),
              ],
            ),
          );
    return AppDesktopShell(
      // One shape either way, so the sidebar keeps its state as a step
      // starts and ends.
      sidebar: ExcludeFocus(
        excluding: !canGoBack,
        child: IgnorePointer(
          ignoring: !canGoBack,
          child: AnimatedOpacity(
            key: const ValueKey('desktop_private_usd_sidebar'),
            opacity: canGoBack ? 1 : 0.4,
            duration: const Duration(milliseconds: 160),
            child: const AppMainSidebar(),
          ),
        ),
      ),
      pane: AppDesktopPane(padding: EdgeInsets.zero, child: pane),
    );
  }
}

/// A desktop Shielded USD card: the glass panel with its lit cut corners.
class DesktopPrivateUsdPanel extends StatelessWidget {
  const DesktopPrivateUsdPanel({
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.sm),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) =>
      NeonGlassPanel(padding: padding, child: child);
}

/// A panel's caption: the red HUD caption the desktop's headed blocks use.
class DesktopPrivateUsdCaption extends StatelessWidget {
  const DesktopPrivateUsdCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    semanticsLabel: text,
    style: kNeonHudCaptionStyle.copyWith(color: context.colors.neon.glow),
  );
}

/// A ledger panel for desktop: [rows] between hairlines, in the glass panel
/// (the phone's `PrivateUsdLedgerCard` draws its own glass).
class DesktopPrivateUsdLedger extends StatelessWidget {
  const DesktopPrivateUsdLedger({required this.rows, super.key});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DesktopPrivateUsdPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++)
            DecoratedBox(
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(
                        top: BorderSide(color: colors.border.subtleOpacity),
                      ),
              ),
              child: rows[i],
            ),
        ],
      ),
    );
  }
}

/// A line that warns: why an action can't run now, or what a step said.
class DesktopPrivateUsdNotice extends StatelessWidget {
  const DesktopPrivateUsdNotice({
    required this.message,
    this.danger = false,
    super.key,
  });

  final String message;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = danger ? colors.text.destructive : colors.text.warning;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: AppIcon(AppIcons.warning, size: 16, color: color),
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            message,
            style: AppTypography.bodySmall.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// Opens a Shielded USD info card over the window: a [title], what happens
/// in order ([steps]), then [notes], and Close. The phone shows the same
/// text in a sheet.
Future<void> showDesktopPrivateUsdInfo(
  BuildContext context, {
  required String title,
  required List<String> steps,
  List<String> notes = const [],
}) {
  final theme = context.appTheme;
  final container = ProviderScope.containerOf(context, listen: false);
  return showDialog<void>(
    context: context,
    barrierColor: theme.colors.background.neutralScrim,
    builder: (dialogContext) => UncontrolledProviderScope(
      container: container,
      child: AppTheme(
        data: theme,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(AppSpacing.md),
          child: _DesktopPrivateUsdInfoCard(
            title: title,
            steps: steps,
            notes: notes,
            onClose: () => Navigator.of(dialogContext).pop(),
          ),
        ),
      ),
    ),
  );
}

class _DesktopPrivateUsdInfoCard extends StatelessWidget {
  const _DesktopPrivateUsdInfoCard({
    required this.title,
    required this.steps,
    required this.notes,
    required this.onClose,
  });

  final String title;
  final List<String> steps;
  final List<String> notes;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = AppTypography.bodyMedium.copyWith(color: colors.text.primary);
    final note = AppTypography.bodySmall.copyWith(color: colors.text.secondary);
    return AppModalCard(
      key: const ValueKey('desktop_private_usd_info_card'),
      width: 440,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height - AppSpacing.xl * 2,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: AppTypography.headlineSmall.copyWith(
                  color: colors.text.accent,
                  fontWeight: AppFontWeight.heading,
                ),
              ),
              const SizedBox(height: AppSpacing.s),
              for (final step in steps) ...[
                Text(step, style: body),
                const SizedBox(height: AppSpacing.xs),
              ],
              if (notes.isNotEmpty) const SizedBox(height: AppSpacing.xs),
              for (final line in notes) ...[
                Text(line, style: note),
                const SizedBox(height: AppSpacing.xxs),
              ],
              const SizedBox(height: AppSpacing.md),
              AppButton(
                key: const ValueKey('desktop_private_usd_info_close'),
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: onClose,
                child: Text(context.l10n.commonClose),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
