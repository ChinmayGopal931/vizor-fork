import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../models/portfolio_chart_models.dart';
import '../../providers/portfolio_chart_provider.dart';
import '../../providers/portfolio_chart_settings_provider.dart';
import '../../services/portfolio_chart_format.dart';
import '../portfolio_chart_range_selector.dart';
import 'neon_plot.dart';

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
        priceSourceName: portfolioPriceSourceName(
          ref.watch(portfolioPricingEngineBaseUriProvider),
        ),
        onRangeSelected: ref.read(portfolioChartRangeProvider.notifier).select,
      ),
    );
  }
}

/// Plot height. Taller than a sparkline so a week of hourly prices has room to
/// read, short enough that Send and Receive stay on screen.
const kPortfolioChartPlotHeight = 104.0;

/// The chart card: title and where the numbers come from, the value and its
/// change over the range, the line, and the range chips. A drag along the line
/// shows the value and time at that point instead.
class MobilePortfolioChartCard extends StatefulWidget {
  const MobilePortfolioChartCard({
    required this.state,
    required this.onRangeSelected,
    this.priceSourceName = 'the pricing server',
    this.plotHeight = kPortfolioChartPlotHeight,
    super.key,
  });

  final PortfolioChartViewState state;

  /// The plot's height; the full chart screen gives it most of the page.
  final double plotHeight;
  final ValueChanged<PortfolioChartRange> onRangeSelected;

  /// Who the prices come from, as the source line names it.
  final String priceSourceName;

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

    final valueStyle = TextStyle(
      fontFamily: 'Gotham',
      fontWeight: FontWeight.w300,
      fontSize: 30,
      height: 1.15,
      letterSpacing: -0.3,
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
      value = _Skeleton(
        width: 132,
        height: 22,
        radius: AppRadii.xSmall / 2,
        color: colors.background.raised,
      );
    }

    // Top right: where the numbers come from, or the time under the finger.
    // The server's name is part of what the card discloses, so on a narrow
    // phone it shrinks to fit rather than being cut short.
    final Widget source = Text(
      data != null && selected != null
          ? formatPortfolioPointTime(selected.time, data.range, data.mode)
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

    return _NeonChartFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                title.toUpperCase(),
                maxLines: 1,
                style: TextStyle(
                  fontFamily: 'Gotham',
                  fontWeight: FontWeight.w300,
                  fontSize: 11,
                  height: 1.2,
                  letterSpacing: 2.2,
                  color: colors.neon.glow,
                ),
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
            child: _plot(context, state, data),
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
        height: widget.plotHeight,
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
          final size = Size(constraints.maxWidth, widget.plotHeight);
          _plotSize = size;
          final geometry = PortfolioPlotGeometry(data.points, size);
          return GestureDetector(
            key: const ValueKey('mobile_home_portfolio_chart_plot'),
            behavior: HitTestBehavior.opaque,
            // Only horizontal drags: vertical ones keep scrolling Home.
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

  /// What the card says about its numbers: only when prices failed or are
  /// old. The owner asked for the price server not to be named on the card;
  /// Settings, Portfolio chart still names it and what a request carries.
  String _sourceLabel(PortfolioChartViewState state) {
    const fromServer = '';
    final data = _dataOf(state);
    if (data == null) {
      return _mode == PortfolioChartMode.usd ? fromServer : 'On this device';
    }
    return switch (data.notice) {
      PortfolioChartNotice.pricesUnavailable => 'Prices unavailable',
      PortfolioChartNotice.pricesStale => 'Older prices',
      PortfolioChartNotice.none =>
        data.mode == PortfolioChartMode.usd ? fromServer : 'On this device',
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

/// The chart's panel: dark glass inside a dim cut-corner tube.
class _NeonChartFrame extends StatelessWidget {
  const _NeonChartFrame({required this.child});

  final Widget child;

  static const _cut = AppChamfer.large;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    return CustomPaint(
      foregroundPainter: _FramePainter(glow: neon.glow, core: neon.core),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: Neon.wedgeBorder(cut: _cut)),
        child: ColoredBox(
          color: context.colors.background.window.withValues(alpha: 0.55),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.xs,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter({required this.glow, required this.core});

  final Color glow;
  final Color core;

  @override
  void paint(Canvas canvas, Size size) {
    Neon.strokeTube(
      canvas,
      Neon.chamferedRect(
        (Offset.zero & size).deflate(0.75),
        topLeft: _NeonChartFrame._cut,
        bottomRight: _NeonChartFrame._cut,
      ),
      glow: glow,
      core: core,
      width: 1.2,
      intensity: 0.6,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      oldDelegate.glow != glow || oldDelegate.core != core;
}
