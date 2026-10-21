import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/widgets.dart';

import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/receipt_loading_skeleton.dart';
import '../../models/portfolio_chart_models.dart';
import '../../services/portfolio_chart_format.dart';
import '../portfolio_chart_range_selector.dart';
import 'neon_plot.dart';

/// The plot's default height: a compact chart, with room for a week of daily
/// prices to read.
const kPortfolioChartPlotHeight = 104.0;

/// The chart card: title and a note on its numbers, the value and its change
/// over the range, the line, and the range chips. A drag along the line shows
/// the value and time at that point instead.
class MobilePortfolioChartCard extends StatefulWidget {
  const MobilePortfolioChartCard({
    required this.state,
    required this.onRangeSelected,
    this.plotHeight = kPortfolioChartPlotHeight,
    super.key,
  });

  final PortfolioChartViewState state;

  /// The plot's height; the full chart screen gives it most of the page.
  final double plotHeight;
  final ValueChanged<PortfolioChartRange> onRangeSelected;

  @override
  State<MobilePortfolioChartCard> createState() =>
      _MobilePortfolioChartCardState();
}

class _MobilePortfolioChartCardState extends State<MobilePortfolioChartCard> {
  /// Where the finger is while scrubbing, in plot coordinates.
  double? _scrubX;

  /// The plot's last laid-out size, to read the line under [_scrubX].
  Size? _plotSize;

  @override
  void didUpdateWidget(MobilePortfolioChartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final data = _dataOf(widget.state);
    if (data == null || !identical(data, _dataOf(oldWidget.state))) {
      _scrubX = null;
    }
  }

  static PortfolioChartData? _dataOf(PortfolioChartViewState state) =>
      state is PortfolioChartReady ? state.data : null;

  PortfolioChartRange get _range => switch (widget.state) {
    PortfolioChartPlaceholder(:final range) => range,
    PortfolioChartReady(:final data) => data.range,
    PortfolioChartHidden() => PortfolioChartRange.defaultRange,
  };

  PortfolioChartMode get _mode => switch (widget.state) {
    PortfolioChartPlaceholder(:final mode) => mode,
    PortfolioChartReady(:final data) => data.mode,
    PortfolioChartHidden() => PortfolioChartMode.zec,
  };

  void _scrub(double? x) {
    if (x != _scrubX) setState(() => _scrubX = x);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final state = widget.state;
    final data = _dataOf(state);
    final plotSize = _plotSize;
    final selected = data == null || _scrubX == null || plotSize == null
        ? null
        : PortfolioPlotGeometry(data.points, plotSize).pointAt(_scrubX!).point;
    final change = data == null ? null : describePortfolioChange(data);
    final title = _mode == PortfolioChartMode.usd
        ? 'Portfolio value'
        : 'ZEC balance';

    final valueStyle = AppTypography.headlineLarge.copyWith(
      color: colors.neon.core,
      shadows: Neon.textGlow(colors.neon.glow, intensity: 0.8),
    );
    final Widget value;
    if (data != null) {
      value = Text(
        formatPortfolioValue(data.mode, (selected ?? data.points.last).value),
        key: const ValueKey('mobile_home_portfolio_chart_value'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: valueStyle,
      );
    } else if (state is PortfolioChartPrivate) {
      value = Text(
        fixedPrivacyMask(),
        key: const ValueKey('mobile_home_portfolio_chart_value'),
        style: valueStyle,
      );
    } else if (state is PortfolioChartEmpty) {
      value = const SizedBox(height: 22);
    } else {
      value = const ReceiptValueSkeleton(width: 132, height: 22);
    }

    // Top right: a note on the numbers, or the time under the finger.
    final Widget source = Text(
      data != null && selected != null
          ? formatPortfolioPointTime(selected.time, data.range, data.mode)
          : _sourceLabel(data),
      key: const ValueKey('mobile_home_portfolio_chart_source'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
      style: AppTypography.bodyExtraSmall.copyWith(
        color: colors.text.secondary,
      ),
    );

    // Beside the value: the change over the range, until a finger is down.
    final Widget changeText = change == null || selected != null
        ? const SizedBox.shrink()
        : Text(
            change.text,
            key: const ValueKey('mobile_home_portfolio_chart_change'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: AppTypography.labelMedium.copyWith(
              color: switch (change.trend) {
                PortfolioChartTrend.up => colors.text.positiveStrong,
                PortfolioChartTrend.down => colors.text.destructive,
                PortfolioChartTrend.flat => colors.text.secondary,
              },
            ),
          );

    return MobileSurfaceCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                title.toUpperCase(),
                maxLines: 1,
                style: kNeonHudCaptionStyle.copyWith(color: colors.neon.glow),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: source,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxs),
          // The balance and its change share a line. When both do not fit (a
          // long ZEC amount in a wide font, large text) the line shrinks as
          // one rather than cutting either short.
          LayoutBuilder(
            builder: (context, constraints) => FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    value,
                    const SizedBox(width: AppSpacing.xs),
                    changeText,
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          SizedBox(
            height: widget.plotHeight,
            child: _plot(context, data, title: title, change: change),
          ),
          const SizedBox(height: AppSpacing.xs),
          PortfolioChartRangeSelector(
            selected: _range,
            onSelected: widget.onRangeSelected,
            keyPrefix: 'mobile_home_portfolio_chart_range',
          ),
        ],
      ),
    );
  }

  Widget _plot(
    BuildContext context,
    PortfolioChartData? data, {
    required String title,
    required PortfolioChartChange? change,
  }) {
    final colors = context.colors;
    final message = switch (widget.state) {
      PortfolioChartEmpty() => 'Not enough history for this range yet.',
      PortfolioChartPrivate() => 'Hidden in privacy mode.',
      _ => null,
    };
    if (message != null) {
      return Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: AppTypography.bodySmall.copyWith(color: colors.text.secondary),
        ),
      );
    }
    if (data == null || change == null) {
      return ReceiptValueSkeleton(
        width: double.infinity,
        height: widget.plotHeight,
      );
    }
    return Semantics(
      label:
          '$title, ${data.range.description}, ${change.text}. '
          'Drag to inspect values.',
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, widget.plotHeight);
          _plotSize = size;
          final geometry = PortfolioPlotGeometry(data.points, size);
          return GestureDetector(
            key: const ValueKey('mobile_home_portfolio_chart_plot'),
            behavior: HitTestBehavior.opaque,
            // Only horizontal drags: vertical ones keep scrolling the page.
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (details) =>
                _scrub(details.localPosition.dx),
            onHorizontalDragUpdate: (details) =>
                _scrub(details.localPosition.dx),
            onHorizontalDragEnd: (_) => _scrub(null),
            onHorizontalDragCancel: () => _scrub(null),
            child: CustomPaint(
              size: size,
              painter: NeonPlotPainter(
                geometry: geometry,
                glow: colors.neon.glow,
                core: colors.neon.core,
                gridColor: colors.neon.grid,
                scrubX: _scrubX,
              ),
            ),
          );
        },
      ),
    );
  }

  /// The note beside the title: that the ZEC balance is the device's own, or
  /// that prices failed or are old. Healthy prices get none.
  String _sourceLabel(PortfolioChartData? data) => switch (data?.notice) {
    PortfolioChartNotice.pricesUnavailable => 'Prices unavailable',
    PortfolioChartNotice.pricesStale => 'Older prices',
    _ => _mode == PortfolioChartMode.zec ? 'On this device' : '',
  };
}
