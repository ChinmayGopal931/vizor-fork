import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../models/portfolio_chart_models.dart';
import '../../../core/l10n/l10n.dart';

/// The chart's range chips, each keyed [keyPrefix]`_<label>`.
class PortfolioChartRangeSelector extends StatelessWidget {
  const PortfolioChartRangeSelector({
    required this.selected,
    required this.onSelected,
    required this.keyPrefix,
    this.desktopInput = false,
    super.key,
  });

  final PortfolioChartRange selected;
  final ValueChanged<PortfolioChartRange> onSelected;
  final String keyPrefix;

  /// Desktop's mouse and keyboard: each chip shows a click cursor, takes
  /// keyboard focus (a ring around its pill) and is chosen with Enter or
  /// Space.
  final bool desktopInput;

  /// The visible pill. The touch target around it is taller.
  static const pillHeight = 32.0;
  static const targetHeight = 44.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget chip(PortfolioChartRange range, {bool focused = false}) =>
        GestureDetector(
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
                  border: focused
                      ? Border.all(color: colors.state.focusRing, width: 2)
                      : null,
                  borderRadius: BorderRadius.circular(AppRadii.full),
                ),
                child: SizedBox(
                  height: pillHeight,
                  width: double.infinity,
                  child: Center(
                    child: Text(
                      range.chipLabel(context.l10n),
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
        );
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
                label: range.description(context.l10n),
                excludeSemantics: true,
                onTap: () => onSelected(range),
                child: desktopInput
                    ? _DesktopChipInput(
                        onActivate: () => onSelected(range),
                        builder: (focused) => chip(range, focused: focused),
                      )
                    : chip(range),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A chip's pointer and keyboard on desktop: a click cursor, and focus that
/// Enter or Space activates.
class _DesktopChipInput extends StatefulWidget {
  const _DesktopChipInput({required this.onActivate, required this.builder});

  final VoidCallback onActivate;
  final Widget Function(bool focused) builder;

  @override
  State<_DesktopChipInput> createState() => _DesktopChipInputState();
}

class _DesktopChipInputState extends State<_DesktopChipInput> {
  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      shortcuts: _shortcuts,
      onShowFocusHighlight: (focused) {
        if (focused != _focused) setState(() => _focused = focused);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<Intent>(
          onInvoke: (_) {
            widget.onActivate();
            return null;
          },
        ),
      },
      child: widget.builder(_focused),
    );
  }
}
