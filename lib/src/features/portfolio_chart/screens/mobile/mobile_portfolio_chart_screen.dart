import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../models/portfolio_chart_models.dart';
import '../../providers/portfolio_chart_provider.dart';
import '../../providers/portfolio_chart_settings_provider.dart';
import '../../services/portfolio_chart_format.dart';
import '../../widgets/mobile/mobile_holdings_panel.dart';
import '../../widgets/mobile/mobile_portfolio_chart_card.dart';

/// The full neon chart, opened from the Home balance sign: the same chart the
/// card shows (value, change, source, ranges, scrubbing) given most of the
/// page, and under it what the account holds, pool by pool.
class MobilePortfolioChartScreen extends ConsumerWidget {
  const MobilePortfolioChartScreen({super.key});

  static const _plotHeight = 300.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final state = ref.watch(portfolioChartViewProvider);
    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          children: [
            MobileTopNav.back(title: 'Balance', onBack: () => context.pop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.s,
                  AppSpacing.sm,
                  AppSpacing.lg,
                ),
                children: [
                  if (state is PortfolioChartHidden)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.lg),
                      child: Text(
                        'The chart appears once this account has a balance '
                        'history.',
                        textAlign: TextAlign.center,
                        style: AppTypography.bodyMedium.copyWith(
                          color: colors.text.secondary,
                        ),
                      ),
                    )
                  else
                    MobilePortfolioChartCard(
                      key: const ValueKey('mobile_portfolio_chart_screen_card'),
                      state: state,
                      plotHeight: _plotHeight,
                      priceSourceName: portfolioPriceSourceName(
                        ref.watch(portfolioPricingEngineBaseUriProvider),
                      ),
                      onRangeSelected: ref
                          .read(portfolioChartRangeProvider.notifier)
                          .select,
                    ),
                  const SizedBox(height: AppSpacing.md),
                  const MobileHoldingsPanel(
                    key: ValueKey('mobile_portfolio_chart_screen_holdings'),
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
