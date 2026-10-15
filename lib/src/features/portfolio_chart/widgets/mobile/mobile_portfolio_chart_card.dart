import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../models/portfolio_chart_models.dart';
import '../../providers/portfolio_chart_provider.dart';
import '../../providers/portfolio_chart_settings_provider.dart';
import '../../services/portfolio_chart_format.dart';
import '../portfolio_chart_range_selector.dart';

/// The Home portfolio chart's place under the balance card: nothing while the
/// chart is off or has no history, otherwise the card with a gap above it.
class MobilePortfolioChartSlot extends ConsumerWidget {
  const MobilePortfolioChartSlot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(portfolioChartViewProvider);
    if (state is PortfolioChartHidden) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s),
      child: MobilePortfolioChartCard(
        key: const ValueKey('mobile_home_portfolio_chart'),
        state: state,
        onRangeSelected: ref.read(portfolioChartRangeProvider.notifier).select,
      ),
    );
  }
}

/// Plot height. Taller than a sparkline so a week of hourly prices has room to
/// read, short enough that Send and Receive stay on screen.
const kPortfolioChartPlotHeight = 104.0;

/// How a point on the line is marked: an 8px dot in a 2px ring of the surface.
const _dotRadius = 4.0;
const _dotRingWidth = 2.0;
const _plotInsetX = _dotRadius + _dotRingWidth;
const _plotInsetY = _dotRadius + _dotRingWidth;

/// The chart card: title and where the numbers come from, the value and its
/// change over the range, the line, and the range chips. A drag along the line
/// shows the value and time at that point instead.
class MobilePortfolioChartCard extends StatefulWidget {
  const MobilePortfolioChartCard({
    required this.state,
    required this.onRangeSelected,
    super.key,
  });

  final PortfolioChartViewState state;
  final ValueChanged<PortfolioChartRange> onRangeSelected;

  @override
  State<MobilePortfolioChartCard> createState() =>
      _MobilePortfolioChartCardState();
}

class _MobilePortfolioChartCardState extends State<MobilePortfolioChartCard> {
  /// The point under the finger while scrubbing.
  int? _selected;

  @override
  void didUpdateWidget(MobilePortfolioChartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final data = _dataOf(widget.state);
    if (data == null || !identical(data, _dataOf(oldWidget.state))) {
      _selected = null;
    }
  }

  static PortfolioChartData? _dataOf(PortfolioChartViewState state) =>
      state is PortfolioChartReady ? state.data : null;

  PortfolioChartRange get _range => switch (widget.state) {
    PortfolioChartLoading(:final range) => range,
    PortfolioChartEmpty(:final range) => range,
    PortfolioChartPrivate(:final range) => range,
    PortfolioChartReady(:final data) => data.range,
    PortfolioChartHidden() => PortfolioChartRange.defaultRange,
  };

  PortfolioChartMode get _mode => switch (widget.state) {
    PortfolioChartLoading(:final mode) => mode,
    PortfolioChartEmpty(:final mode) => mode,
    PortfolioChartPrivate(:final mode) => mode,
    PortfolioChartReady(:final data) => data.mode,
    PortfolioChartHidden() => PortfolioChartMode.zec,
  };

  void _select(int? index) {
    if (index != _selected) setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final state = widget.state;
    final data = _dataOf(state);
    final selected = data == null || _selected == null
        ? null
        : data.points[_selected!.clamp(0, data.points.length - 1)];
    final change = data == null ? null : describePortfolioChange(data);
    final title = _mode == PortfolioChartMode.usd
        ? 'Portfolio value'
        : 'ZEC balance';

    final valueStyle = AppTypography.headlineSmall.copyWith(
      color: colors.text.primary,
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
      value = _Skeleton(
        width: 132,
        height: 22,
        radius: AppRadii.xSmall / 2,
        color: colors.background.raised,
      );
    }

    // Top right: where the numbers come from, or the time under the finger.
    final Widget source = Text(
      data != null && selected != null
          ? formatPortfolioPointTime(selected.time, data.range)
          : _sourceLabel(state),
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
      cornerRadius: AppRadii.large,
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
                title,
                maxLines: 1,
                style: AppTypography.labelLarge.copyWith(
                  color: colors.text.secondary,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(child: source),
            ],
          ),
          const SizedBox(height: AppSpacing.xxs),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Align(alignment: Alignment.centerLeft, child: value),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: changeText,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s),
          SizedBox(
            height: kPortfolioChartPlotHeight,
            child: _plot(context, state, data),
          ),
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
    PortfolioChartViewState state,
    PortfolioChartData? data,
  ) {
    final colors = context.colors;
    final message = switch (state) {
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
    if (data == null) {
      return _Skeleton(
        width: double.infinity,
        height: kPortfolioChartPlotHeight,
        radius: AppRadii.small,
        color: colors.background.raised,
      );
    }
    final change = describePortfolioChange(data);
    return Semantics(
      label:
          '${data.mode == PortfolioChartMode.usd ? 'Portfolio value' : 'ZEC balance'}, '
          '${data.range.description}, ${change.text}. '
          'Drag to inspect values.',
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, kPortfolioChartPlotHeight);
          final geometry = _PlotGeometry(data.points, size);
          return GestureDetector(
            key: const ValueKey('mobile_home_portfolio_chart_plot'),
            behavior: HitTestBehavior.opaque,
            // Only horizontal drags: vertical ones keep scrolling Home.
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (details) =>
                _select(geometry.nearestIndex(details.localPosition.dx)),
            onHorizontalDragUpdate: (details) =>
                _select(geometry.nearestIndex(details.localPosition.dx)),
            onHorizontalDragEnd: (_) => _select(null),
            onHorizontalDragCancel: () => _select(null),
            child: CustomPaint(
              size: size,
              painter: _PlotPainter(
                geometry: geometry,
                lineColor: colors.icon.accent,
                surfaceColor: colors.background.ground,
                guideColor: colors.border.medium,
                selected: _selected,
              ),
            ),
          );
        },
      ),
    );
  }

  /// Names what the chart contacts, or that it contacts nothing. Always on the
  /// card, so the source is never something to look up in Settings.
  String _sourceLabel(PortfolioChartViewState state) {
    final data = _dataOf(state);
    if (data == null) {
      return _mode == PortfolioChartMode.usd
          ? 'Prices from CoinGecko'
          : 'On this device';
    }
    return switch (data.notice) {
      PortfolioChartNotice.pricesUnavailable => 'Prices unavailable',
      PortfolioChartNotice.pricesStale => 'Older prices',
      PortfolioChartNotice.none =>
        data.mode == PortfolioChartMode.usd
            ? 'Prices from CoinGecko'
            : 'On this device',
    };
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({
    required this.width,
    required this.height,
    required this.radius,
    required this.color,
  });

  final double width;
  final double height;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: SizedBox(width: width, height: height),
    );
  }
}

/// Where each point lands in the plot, shared by painting and touch.
class _PlotGeometry {
  _PlotGeometry(this.points, this.size) {
    final first = points.first.time.millisecondsSinceEpoch.toDouble();
    final last = points.last.time.millisecondsSinceEpoch.toDouble();
    var low = double.infinity;
    var high = double.negativeInfinity;
    for (final point in points) {
      low = math.min(low, point.value);
      high = math.max(high, point.value);
    }
    final width = size.width - 2 * _plotInsetX;
    final height = size.height - 2 * _plotInsetY;
    offsets = [
      for (final point in points)
        Offset(
          _plotInsetX +
              (last == first
                  ? 0
                  : (point.time.millisecondsSinceEpoch - first) /
                        (last - first) *
                        width),
          _plotInsetY +
              (high == low
                  ? height / 2
                  : (high - point.value) / (high - low) * height),
        ),
    ];
  }

  final List<PortfolioChartPoint> points;
  final Size size;
  late final List<Offset> offsets;

  /// The point nearest to [dx], so the finger need not be on the line.
  int nearestIndex(double dx) {
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < offsets.length; i++) {
      final distance = (offsets[i].dx - dx).abs();
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
    }
    return best;
  }
}

class _PlotPainter extends CustomPainter {
  _PlotPainter({
    required this.geometry,
    required this.lineColor,
    required this.surfaceColor,
    required this.guideColor,
    required this.selected,
  });

  final _PlotGeometry geometry;
  final Color lineColor;
  final Color surfaceColor;
  final Color guideColor;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final offsets = geometry.offsets;
    final line = Path()..moveTo(offsets.first.dx, offsets.first.dy);
    for (final offset in offsets.skip(1)) {
      line.lineTo(offset.dx, offset.dy);
    }

    // A wash under the line, never a block of colour.
    final area = Path.from(line)
      ..lineTo(offsets.last.dx, size.height)
      ..lineTo(offsets.first.dx, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withValues(alpha: 0.10),
            lineColor.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final index = selected;
    if (index != null && index < offsets.length) {
      final x = offsets[index].dx;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = guideColor
          ..strokeWidth = 1,
      );
      _paintDot(canvas, offsets[index]);
    } else {
      _paintDot(canvas, offsets.last);
    }
  }

  void _paintDot(Canvas canvas, Offset center) {
    canvas.drawCircle(
      center,
      _dotRadius + _dotRingWidth,
      Paint()..color = surfaceColor,
    );
    canvas.drawCircle(center, _dotRadius, Paint()..color = lineColor);
  }

  @override
  bool shouldRepaint(_PlotPainter oldDelegate) {
    return oldDelegate.geometry != geometry ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.surfaceColor != surfaceColor ||
        oldDelegate.guideColor != guideColor ||
        oldDelegate.selected != selected;
  }
}
