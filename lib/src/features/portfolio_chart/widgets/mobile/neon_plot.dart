import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../../core/theme/app_theme.dart';
import '../../models/portfolio_chart_models.dart';
import '../../services/portfolio_price_history.dart';

/// Room kept around the line so its head and glow are never clipped.
const _inset = 8.0;

/// Where each point lands in a plot, shared by painting and touch.
class PortfolioPlotGeometry {
  PortfolioPlotGeometry(this.points, this.size) {
    final first = points.first.time.millisecondsSinceEpoch.toDouble();
    final last = points.last.time.millisecondsSinceEpoch.toDouble();
    var low = double.infinity;
    var high = double.negativeInfinity;
    for (final point in points) {
      low = math.min(low, point.value);
      high = math.max(high, point.value);
    }
    final width = size.width - 2 * _inset;
    final height = size.height - 2 * _inset;
    offsets = [
      for (final point in points)
        Offset(
          _inset +
              (last == first
                  ? 0
                  : (point.time.millisecondsSinceEpoch - first) /
                        (last - first) *
                        width),
          _inset +
              (high == low
                  ? height / 2
                  : (high - point.value) / (high - low) * height),
        ),
    ];
  }

  final List<PortfolioChartPoint> points;
  final Size size;
  late final List<Offset> offsets;

  /// The line's own point under [dx] (clamped to the plotted span): the plot
  /// joins points with straight segments, so the value and time there are
  /// those of the segment beneath the finger, not of the nearest data point.
  /// Between two daily prices (UTC midnights) it takes the nearer day, since
  /// a daily price is read and dated by its day.
  ({PortfolioChartPoint point, Offset offset}) pointAt(double dx) {
    if (offsets.length == 1) {
      return (point: points.first, offset: offsets.first);
    }
    final x = dx.clamp(offsets.first.dx, offsets.last.dx);
    var i = 0;
    while (i < offsets.length - 2 && offsets[i + 1].dx < x) {
      i++;
    }
    final a = offsets[i];
    final b = offsets[i + 1];
    final span = b.dx - a.dx;
    final t = span <= 0 ? 1.0 : ((x - a.dx) / span).clamp(0.0, 1.0);
    final from = points[i];
    final to = points[i + 1];
    if (isUtcMidnight(from.time) && isUtcMidnight(to.time)) {
      final day = t < 0.5 ? i : i + 1;
      return (point: points[day], offset: offsets[day]);
    }
    final millis =
        from.time.millisecondsSinceEpoch +
        ((to.time.millisecondsSinceEpoch - from.time.millisecondsSinceEpoch) *
                t)
            .round();
    return (
      point: PortfolioChartPoint(
        DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
        from.value + (to.value - from.value) * t,
      ),
      offset: Offset(x, a.dy + (b.dy - a.dy) * t),
    );
  }
}

/// The balance line as a light trail on a Tron grid: a red wash under a lit
/// tube, and a square head where the trail is now (or under the finger).
class NeonPlotPainter extends CustomPainter {
  NeonPlotPainter({
    required this.geometry,
    required this.glow,
    required this.core,
    required this.gridColor,
    this.scrubX,
    this.grid = true,
    this.light = 1,
  });

  final PortfolioPlotGeometry geometry;

  /// The tube's colour and its white-hot centre.
  final Color glow;
  final Color core;
  final Color gridColor;
  final double? scrubX;

  /// The full chart draws the grid; the trail in the balance sign does not.
  final bool grid;

  /// How lit the trail is, 0..1 (the sign's switch-on).
  final double light;

  @override
  void paint(Canvas canvas, Size size) {
    if (grid) _paintGrid(canvas, size);

    final offsets = geometry.offsets;
    final line = Path()..moveTo(offsets.first.dx, offsets.first.dy);
    for (final offset in offsets.skip(1)) {
      line.lineTo(offset.dx, offset.dy);
    }

    // Light spilling down from the trail onto the floor.
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
            glow.withValues(alpha: 0.24 * light),
            glow.withValues(alpha: 0.02 * light),
          ],
        ).createShader(Offset.zero & size),
    );
    Neon.strokeTube(
      canvas,
      line,
      glow: glow,
      core: core,
      width: grid ? 2 : 1.6,
      intensity: light,
    );

    final scrub = scrubX;
    if (scrub != null) {
      final at = geometry.pointAt(scrub).offset;
      final x = at.dx;
      Neon.strokeTube(
        canvas,
        Path()
          ..moveTo(x, 0)
          ..lineTo(x, size.height),
        glow: glow,
        core: core,
        width: 1,
        intensity: 0.7 * light,
      );
      _paintHead(canvas, at);
    } else {
      _paintHead(canvas, offsets.last);
    }
  }

  void _paintGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    const columns = 6;
    const rows = 4;
    for (var i = 0; i <= columns; i++) {
      final x = (size.width - 1) * i / columns + 0.5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var j = 0; j <= rows; j++) {
      final y = (size.height - 1) * j / rows + 0.5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  /// The light cycle: a lit square with a halo.
  void _paintHead(Canvas canvas, Offset center) {
    final half = grid ? 4.0 : 3.0;
    final rect = Rect.fromCenter(
      center: center,
      width: half * 2,
      height: half * 2,
    );
    canvas
      ..drawRect(
        rect.inflate(4),
        Paint()
          ..color = glow.withValues(alpha: 0.55 * light)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      )
      ..drawRect(rect, Paint()..color = glow.withValues(alpha: light))
      ..drawRect(
        rect.deflate(half * 0.45),
        Paint()..color = core.withValues(alpha: light),
      );
  }

  @override
  bool shouldRepaint(NeonPlotPainter oldDelegate) {
    // Callers build a new geometry with every build; it is the same plot
    // while its points and size are.
    return !identical(oldDelegate.geometry.points, geometry.points) ||
        oldDelegate.geometry.size != geometry.size ||
        oldDelegate.glow != glow ||
        oldDelegate.core != core ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.scrubX != scrubX ||
        oldDelegate.grid != grid ||
        oldDelegate.light != light;
  }
}
