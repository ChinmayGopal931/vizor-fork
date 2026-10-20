import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/pricing_engine_config.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../portfolio_chart/providers/portfolio_chart_settings_provider.dart';
import 'mobile_tor_control.dart' show MobilePrivacyToggle;

const _rowHeight = 44.0;

/// Settings for the portfolio chart: whether Home shows it, and whether it is
/// valued at market prices.
class MobilePortfolioChartSettingsCard extends ConsumerWidget {
  const MobilePortfolioChartSettingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final settings = ref.watch(portfolioChartSettingsProvider);
    final pricesAvailable = ref.watch(portfolioChartPricesAvailableProvider);

    return MobileSurfaceCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.base,
        AppSpacing.sm,
        AppSpacing.base,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xxs),
            child: Text(
              'Portfolio chart',
              style: AppTypography.labelLarge.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          _ToggleRow(
            rowKey: const ValueKey('mobile_settings_portfolio_chart_row'),
            toggleKey: const ValueKey('mobile_settings_portfolio_chart_toggle'),
            thumbKey: const ValueKey(
              'mobile_settings_portfolio_chart_toggle_thumb',
            ),
            iconName: AppIcons.home,
            label: 'Show on home',
            enabled: settings.enabled,
            onToggle: () => unawaited(
              _apply(
                context,
                ref
                    .read(portfolioChartSettingsProvider.notifier)
                    .setEnabled(!settings.enabled),
              ),
            ),
          ),
          if (pricesAvailable) ...[
            const SizedBox(height: AppSpacing.xxs),
            _ToggleRow(
              rowKey: const ValueKey(
                'mobile_settings_portfolio_chart_prices_row',
              ),
              toggleKey: const ValueKey(
                'mobile_settings_portfolio_chart_prices_toggle',
              ),
              thumbKey: const ValueKey(
                'mobile_settings_portfolio_chart_prices_toggle_thumb',
              ),
              iconName: AppIcons.coins,
              label: 'Use market prices',
              enabled: settings.marketPrices,
              interactive: settings.enabled,
              onToggle: () => unawaited(
                _apply(
                  context,
                  ref
                      .read(portfolioChartSettingsProvider.notifier)
                      .setMarketPrices(!settings.marketPrices),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _apply(BuildContext context, Future<void> change) async {
    try {
      await change;
    } catch (_) {
      if (!context.mounted) return;
      showAppToast(context, "Couldn't update the portfolio chart setting.");
    }
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.rowKey,
    required this.toggleKey,
    required this.thumbKey,
    required this.iconName,
    required this.label,
    required this.enabled,
    required this.onToggle,
    this.interactive = true,
  });

  final Key rowKey;
  final Key toggleKey;
  final Key thumbKey;
  final String iconName;
  final String label;
  final bool enabled;
  final VoidCallback onToggle;

  /// A row that cannot act now still shows its saved value, dimmed.
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      toggled: enabled,
      enabled: interactive,
      label: label,
      onTap: interactive ? onToggle : null,
      excludeSemantics: true,
      child: GestureDetector(
        key: rowKey,
        behavior: HitTestBehavior.opaque,
        onTap: interactive ? onToggle : null,
        child: SizedBox(
          height: _rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 32,
                  child: Center(
                    child: AppIcon(
                      iconName,
                      size: 20,
                      color: colors.icon.muted,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.s),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.labelLarge.copyWith(
                      color: interactive
                          ? colors.text.accent
                          : colors.text.disabled,
                    ),
                  ),
                ),
                MobilePrivacyToggle(
                  key: toggleKey,
                  enabled: enabled,
                  interactive: interactive,
                  thumbKey: thumbKey,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
