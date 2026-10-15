import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../portfolio_chart/providers/portfolio_chart_settings_provider.dart';
import '../../../portfolio_chart/services/portfolio_chart_format.dart';
import '../../../portfolio_chart/widgets/portfolio_chart_range_selector.dart';
import 'mobile_tor_control.dart' show MobilePrivacyToggle;

const _rowHeight = 44.0;

/// With market prices on: which server the chart asks, what a request carries,
/// and who sees the IP address. The host is named in full so what the chart
/// contacts is never a surprise.
String portfolioChartMarketPricesCopy(String host) =>
    'Charts your balance in USD over time. Your balance history is built on '
    'this device. Daily prices are requested from $host. A request names only '
    'ZEC, USD, daily prices and a date range, and nothing from your wallet. '
    'That server sees your IP address unless Tor is on. Prices are USD only.';

/// With market prices off (the default) on a build that offers them: nothing is
/// requested, and what turning them on would do is said before it is done.
String portfolioChartPricesOffCopy(String host) =>
    'Charts your ZEC balance over time, built on this device. Nothing is '
    'requested from any server. Turning on market prices would request daily '
    'USD prices from $host, which then sees your IP address unless Tor is on.';

/// On a build with no market prices to offer.
const kPortfolioChartLocalCopy =
    'Charts your ZEC balance over time, built on this device. Nothing is '
    'requested from any server.';

const kPortfolioChartHiddenCopy =
    'The chart is hidden. Nothing is requested from any server.';

/// Settings for the Home portfolio chart: show or hide it, whether to value it
/// with market prices (the only thing that contacts a server), and the range it
/// opens on.
class MobilePortfolioChartSettingsCard extends ConsumerWidget {
  const MobilePortfolioChartSettingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final settings = ref.watch(portfolioChartSettingsProvider);
    final pricesAvailable = ref.watch(portfolioChartPricesAvailableProvider);
    final host = portfolioPricingServerHost(
      ref.watch(portfolioPricingEngineBaseUriProvider),
    );
    final description = !settings.enabled
        ? kPortfolioChartHiddenCopy
        : !pricesAvailable
        ? kPortfolioChartLocalCopy
        : settings.marketPrices
        ? portfolioChartMarketPricesCopy(host)
        : portfolioChartPricesOffCopy(host);

    return MobileSurfaceCard(
      cornerRadius: AppRadii.large,
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
          // Only builds that can value the chart at market prices (a Home price
          // and a usable pricing server) offer the switch; on the rest the
          // chart is the ZEC balance and nothing could be requested.
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
          if (settings.enabled) ...[
            const SizedBox(height: AppSpacing.s),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
              child: Text(
                'Default range',
                style: AppTypography.labelLarge.copyWith(
                  color: colors.text.accent,
                ),
              ),
            ),
            PortfolioChartRangeSelector(
              selected: settings.defaultRange,
              keyPrefix: 'mobile_settings_portfolio_chart_range',
              onSelected: (range) => unawaited(
                _apply(
                  context,
                  ref
                      .read(portfolioChartSettingsProvider.notifier)
                      .setDefaultRange(range),
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          Text(
            description,
            key: const ValueKey('mobile_settings_portfolio_chart_description'),
            style: AppTypography.bodyMedium.copyWith(
              color: colors.text.secondary,
            ),
          ),
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
