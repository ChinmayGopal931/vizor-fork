import 'package:flutter/widgets.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../../portfolio_chart/models/portfolio_chart_models.dart';
import '../../portfolio_chart/widgets/mobile/neon_plot.dart';

// The pieces of Home's balance sign that both form factors draw: its type and
// its light trail. Each Home lays out its own sign around them.

/// The fiat line above the sign's digits.
const kNeonSignCaptionStyle = TextStyle(
  fontFamily: 'Gotham',
  fontWeight: FontWeight.w300,
  fontSize: 13,
  height: 16 / 13,
  letterSpacing: 0.4,
);

/// Neon numerals: Gotham Thin, whose hairline strokes read as tubes.
const kNeonBalanceAmountStyle = TextStyle(
  fontFamily: 'Gotham',
  fontWeight: FontWeight.w100,
  fontSize: 60,
  height: 1.1,
  letterSpacing: -0.5,
);

/// The ticker after the sign's digits.
const kNeonBalanceTickerStyle = TextStyle(
  fontFamily: 'Gotham',
  fontWeight: FontWeight.w300,
  fontSize: 22,
  height: 1.1,
  letterSpacing: 2.4,
);

/// The sign's light trail: the balance history's line when the chart has one,
/// otherwise a steady tail-light bar. Never drawn from data in privacy mode
/// (the chart state is private then).
class NeonBalanceTrail extends StatelessWidget {
  const NeonBalanceTrail({
    required this.chartState,
    required this.light,
    required this.showOpenHint,
    super.key,
  });

  final PortfolioChartViewState chartState;
  final double light;
  final bool showOpenHint;

  static const _height = 72.0;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    final data = switch (chartState) {
      PortfolioChartReady(:final data) when data.points.length > 1 => data,
      _ => null,
    };
    return SizedBox(
      height: _height,
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, _height);
                return CustomPaint(
                  size: size,
                  painter: data == null
                      ? _TailLightPainter(
                          glow: neon.signGlow,
                          core: neon.signCore,
                          light: light,
                        )
                      : NeonPlotPainter(
                          geometry: PortfolioPlotGeometry(data.points, size),
                          glow: neon.signGlow,
                          core: neon.signCore,
                          gridColor: neon.grid,
                          grid: false,
                          light: light,
                        ),
                );
              },
            ),
          ),
          if (showOpenHint) ...[
            const SizedBox(width: AppSpacing.xs),
            AppIcon(
              AppIcons.chevronForward,
              size: 18,
              color: neon.signCore.withValues(alpha: 0.85),
            ),
          ],
        ],
      ),
    );
  }
}

/// The trail without a chart line: a steady lit bar.
class _TailLightPainter extends CustomPainter {
  _TailLightPainter({
    required this.glow,
    required this.core,
    required this.light,
  });

  final Color glow;
  final Color core;
  final double light;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    Neon.strokeTube(
      canvas,
      Path()
        ..moveTo(4, y)
        ..lineTo(size.width - 4, y),
      glow: glow,
      core: core,
      width: 2,
      intensity: light,
    );
  }

  @override
  bool shouldRepaint(_TailLightPainter oldDelegate) =>
      oldDelegate.glow != glow ||
      oldDelegate.core != core ||
      oldDelegate.light != light;
}
