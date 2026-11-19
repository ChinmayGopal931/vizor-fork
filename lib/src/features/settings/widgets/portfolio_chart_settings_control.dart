import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/pricing_engine_config.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/app_toast.dart';
import '../../portfolio_chart/providers/portfolio_chart_settings_provider.dart';
import 'network_privacy_control.dart' show PrivacyToggle;

/// Desktop Settings' portfolio chart switches, as the phone's chart settings
/// card has them: whether Home shows the chart, and whether it is valued at
/// market prices. The same settings and storage as the phone
/// ([portfolioChartSettingsProvider]), so the same defaults: shown, and the
/// ZEC balance until market prices are turned on. The prices switch shows
/// only where market prices are available, and holds still while the chart
/// is off. No explanatory text, as on the phone.
class PortfolioChartSettingsControl extends ConsumerWidget {
  const PortfolioChartSettingsControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(portfolioChartSettingsProvider);
    final pricesAvailable = ref.watch(portfolioChartPricesAvailableProvider);
    final notifier = ref.read(portfolioChartSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToggleRow(
          rowKey: const ValueKey('settings_portfolio_chart_row'),
          toggleKey: const ValueKey('settings_portfolio_chart_toggle'),
          iconName: AppIcons.home,
          label: context.l10n.portfolioChartSettingsShowOnHome,
          enabled: settings.enabled,
          onToggle: () => unawaited(
            _apply(context, notifier.setEnabled(!settings.enabled)),
          ),
        ),
        if (pricesAvailable) ...[
          const SizedBox(height: AppSpacing.sm),
          _ToggleRow(
            rowKey: const ValueKey('settings_portfolio_chart_prices_row'),
            toggleKey: const ValueKey('settings_portfolio_chart_prices_toggle'),
            iconName: AppIcons.coins,
            label: context.l10n.portfolioChartSettingsMarketPrices,
            enabled: settings.marketPrices,
            onToggle: settings.enabled
                ? () => unawaited(
                    _apply(
                      context,
                      notifier.setMarketPrices(!settings.marketPrices),
                    ),
                  )
                : null,
          ),
        ],
      ],
    );
  }

  Future<void> _apply(BuildContext context, Future<void> change) async {
    try {
      await change;
    } catch (_) {
      if (!context.mounted) return;
      showAppToast(context, context.l10n.portfolioChartSettingsSaveFailed);
    }
  }
}

/// A switch row in desktop Settings' style (the hide-balance switch's): the
/// icon, the label and the toggle. A row that cannot act now keeps its saved
/// value, dimmed.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.rowKey,
    required this.toggleKey,
    required this.iconName,
    required this.label,
    required this.enabled,
    required this.onToggle,
  });

  final Key rowKey;
  final Key toggleKey;
  final String iconName;
  final String label;
  final bool enabled;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final interactive = onToggle != null;
    return Row(
      key: rowKey,
      children: [
        AppIcon(
          iconName,
          size: 20,
          color: interactive ? colors.icon.accent : colors.icon.disabled,
        ),
        const SizedBox(width: AppSpacing.s),
        Expanded(
          child: Text(
            label,
            style: AppTypography.labelLarge.copyWith(
              color: interactive ? colors.text.accent : colors.text.disabled,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        PrivacyToggle(
          enabled: enabled,
          trackKey: toggleKey,
          semanticsLabel: label,
          onToggle: onToggle,
        ),
      ],
    );
  }
}
