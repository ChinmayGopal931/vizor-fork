import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../models/portfolio_chart_models.dart';

/// The range chips, shared by the Home chart and its Settings.
///
/// Each chip is a [keyPrefix]`_<label>` key, for example
/// `portfolio_chart_range_1w`.
class PortfolioChartRangeSelector extends StatelessWidget {
  const PortfolioChartRangeSelector({
    required this.selected,
    required this.onSelected,
    this.keyPrefix = 'portfolio_chart_range',
    super.key,
  });

  final PortfolioChartRange selected;
  final ValueChanged<PortfolioChartRange> onSelected;
  final String keyPrefix;

  /// The visible pill. The touch target around it is taller.
  static const pillHeight = 32.0;
  static const targetHeight = 44.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Row(
        children: [
          for (final range in PortfolioChartRange.values) ...[
            if (range != PortfolioChartRange.values.first)
              const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Semantics(
                button: true,
                selected: range == selected,
                label: range.description,
                excludeSemantics: true,
                onTap: () => onSelected(range),
                child: GestureDetector(
                  key: ValueKey('${keyPrefix}_${range.label}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelected(range),
                  child: SizedBox(
                    height: targetHeight,
                    child: Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: range == selected
                              ? colors.background.raised
                              : const Color(0x00000000),
                          borderRadius: BorderRadius.circular(AppRadii.full),
                        ),
                        child: SizedBox(
                          height: pillHeight,
                          width: double.infinity,
                          child: Center(
                            child: Text(
                              range.label,
                              maxLines: 1,
                              style: AppTypography.labelMedium.copyWith(
                                color: range == selected
                                    ? colors.text.accent
                                    : colors.text.secondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
