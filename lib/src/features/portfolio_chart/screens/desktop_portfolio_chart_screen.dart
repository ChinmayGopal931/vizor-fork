import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/layout/app_desktop_shell.dart';
import '../../../core/layout/app_main_sidebar.dart';
import '../../../core/layout/app_pane_scroll_scaffold.dart';
import '../../../core/theme/app_theme.dart';
import '../models/portfolio_chart_models.dart';
import '../providers/portfolio_chart_provider.dart';
import '../providers/portfolio_chart_settings_provider.dart';
import '../widgets/mobile/mobile_holdings_panel.dart';
import '../widgets/mobile/mobile_portfolio_chart_card.dart';
import '../../../core/widgets/neon_page_title.dart';

/// The full chart on desktop, opened from Home's balance sign: the phone's
/// chart card and holdings ([MobilePortfolioChartCard], [MobileHoldingsPanel])
/// in the desktop pane, under the pane's back link to Home. The line is read
/// under the pointer, and the range chips take a click and the keyboard.
///
/// Without Private USD (a phone feature) the holdings are the shielded pools,
/// their total and the transparent ZEC.
class DesktopPortfolioChartScreen extends ConsumerWidget {
  const DesktopPortfolioChartScreen({super.key});

  /// As the phone's full chart.
  static const _plotHeight = 300.0;

  /// Wider than Home's column, so the line has room to read.
  static const _contentWidth = 560.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final state = ref.watch(portfolioChartViewProvider);
    return AppDesktopShell(
      sidebar: const AppMainSidebar(),
      pane: AppDesktopPane(
        padding: EdgeInsets.zero,
        child: AppPaneScrollScaffold(
          toolbar: const AppPaneToolbar(),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s,
            vertical: AppSpacing.sm,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _contentWidth),
              child: Column(
                key: const ValueKey('desktop_portfolio_chart_content'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  NeonPageTitle(
                    context.l10n.portfolioChartScreenTitle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (state is PortfolioChartHidden)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.lg,
                      ),
                      child: Text(
                        context.l10n.portfolioChartScreenHidden,
                        textAlign: TextAlign.center,
                        style: AppTypography.bodyMedium.copyWith(
                          color: colors.text.secondary,
                        ),
                      ),
                    )
                  else
                    MobilePortfolioChartCard(
                      key: const ValueKey('desktop_portfolio_chart_card'),
                      state: state,
                      plotHeight: _plotHeight,
                      desktopInput: true,
                      onRangeSelected: ref
                          .read(portfolioChartRangeProvider.notifier)
                          .select,
                    ),
                  const SizedBox(height: AppSpacing.md),
                  const MobileHoldingsPanel(
                    key: ValueKey('desktop_portfolio_chart_holdings'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
