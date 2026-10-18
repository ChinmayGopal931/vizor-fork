import 'dart:math' as math;
import 'dart:ui' show ClipOp;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/network_privacy_provider.dart';
import '../../../providers/sync_display_progress_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../formatting/sync_status_label.dart';
import '../../theme/app_theme.dart';

/// Which part of the sync line a layer draws.
enum NeonSyncLinePart {
  none,

  /// All of it: the climbing line, over the content.
  whole,

  /// All but its head: a line running behind the content, whose head the
  /// front layer draws.
  belowHead,

  /// Only its head, from just above it down past the readout: a line
  /// running behind keeps this part in front, so nothing that lies between
  /// the two layers (the top bar, a scroll fade) cuts it beside the readout.
  head,
}

/// Which of the two sync layers a [NeonSyncBackdrop] draws.
enum NeonSyncLayer {
  /// Behind the content: the Tron floor, and the sync line once synced.
  back,

  /// Over the content (ignoring touches): the sync line while it climbs, and
  /// the readout at its head.
  front,
}

/// The readouts at the sync line's head, sentence case here and drawn
/// uppercase (a HUD caption), for every screen that draws a sync line.
abstract final class NeonSyncReadout {
  static const synced = 'Synced';
  static const failed = 'Sync failed';
  static const torOffline = 'Tor offline';
  static const torWaiting = 'Tor …';

  /// A scan [percent] of the way, or a check's.
  static String progress(int percent, {bool checking = false}) =>
      '${checking ? 'Check' : 'Sync'} $percent%';
}

/// The type size of a sync line's readout.
typedef NeonSyncReadoutType = ({double fontSize, double letterSpacing});

/// Home's readout type. A screen whose first block sits close under the top
/// sets a smaller one so a long readout ends above it.
const kNeonSyncReadoutType = (fontSize: 9.0, letterSpacing: 2.2);

/// What a sync line shows, whatever is syncing: Home's wallet, or the
/// Railgun wallet on the Private USD screen.
@immutable
class NeonSyncLine {
  const NeonSyncLine({
    required this.progress,
    required this.readout,
    required this.semanticsLabel,
    this.climbing = false,
    this.failed = false,
    bool? scanning,
    this.lineX = _lineXFactor,
    this.readoutType = kNeonSyncReadoutType,
  }) : scanning = scanning ?? climbing;

  /// How far the line has climbed, 0..1.
  final double progress;

  /// A [NeonSyncReadout].
  final String readout;

  /// What a screen reader hears, in a live region.
  final String semanticsLabel;

  /// Climbing: the line is drawn over the content, lit, with a pulse. Once
  /// synced it runs behind the content instead.
  final bool climbing;
  final bool failed;

  /// Something scans: the floor flows. A synced line's refresh scans
  /// without climbing.
  final bool scanning;

  /// Where the line stands, as a fraction of the width.
  final double lineX;

  /// The type size of [readout].
  final NeonSyncReadoutType readoutType;
}

/// One layer of [line], below or above the content as Home layers it: the
/// floor (and the line once synced, all but its head) behind, the climbing
/// line (or the head of the one behind) and the readout in front, where it
/// ignores touches and carries the semantics.
class NeonSyncLineLayer extends StatelessWidget {
  const NeonSyncLineLayer({
    required this.line,
    this.layer = NeonSyncLayer.back,
    this.scrolled = false,
    super.key,
  });

  final NeonSyncLine line;
  final NeonSyncLayer layer;

  /// The page under the line has scrolled away from its top
  /// ([NeonSyncScrolled]). A synced line's head and readout, drawn in front,
  /// then fade out and the whole line runs behind the content, so nothing
  /// fixed is drawn over the blocks scrolling past (owner, 2026-10-17).
  final bool scrolled;

  @override
  Widget build(BuildContext context) {
    final front = layer == NeonSyncLayer.front;
    final view = NeonSyncBackdropView(
      progress: line.progress,
      readout: line.readout,
      active: line.climbing,
      floorFlows: line.scanning,
      failed: line.failed,
      drawFloor: !front,
      linePart: switch ((line.climbing, front)) {
        (true, true) => NeonSyncLinePart.whole,
        (true, false) => NeonSyncLinePart.none,
        (false, true) => NeonSyncLinePart.head,
        (false, false) =>
          scrolled ? NeonSyncLinePart.whole : NeonSyncLinePart.belowHead,
      },
      drawReadout: front,
      lineX: line.lineX,
      readoutType: line.readoutType,
    );
    if (!front) return ExcludeSemantics(child: view);
    return IgnorePointer(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: line.semanticsLabel,
        child: ExcludeSemantics(
          child: AnimatedOpacity(
            opacity: scrolled && !line.climbing ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            // Faded out, the head still reports the sync to screen readers.
            alwaysIncludeSemantics: true,
            child: view,
          ),
        ),
      ),
    );
  }
}

/// Whether the page under a sync line has scrolled away from its top, from
/// the scroll notifications of the content it wraps: its own vertical list,
/// not lists nested inside it.
class NeonSyncScrolled extends StatefulWidget {
  const NeonSyncScrolled({required this.builder, super.key});

  final Widget Function(BuildContext context, bool scrolled) builder;

  @override
  State<NeonSyncScrolled> createState() => _NeonSyncScrolledState();
}

class _NeonSyncScrolledState extends State<NeonSyncScrolled> {
  bool _scrolled = false;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      final scrolled = notification.metrics.extentBefore > 4;
      if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.builder(context, _scrolled),
      );
}

/// A solid backing for a block over a sync line: the synced line, drawn
/// behind the content, shows only in the gaps between blocks, never across
/// one. While it climbs the line is drawn above everything instead.
class NeonSyncOcclude extends StatelessWidget {
  const NeonSyncOcclude({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: context.colors.background.window, child: child);
}

/// Home's backdrop in the neon redesign, in two layers around the content.
///
/// A Tron floor recedes to a red horizon low on the screen and flows toward
/// the viewer while Veylor scans; otherwise it stands still. The sync line, a lit tube in the right part
/// of the screen, rises from the bottom with the scan's progress and reads
/// the percentage at its head. While it climbs it is drawn over the content;
/// once synced it runs the full height behind the content, out of the way,
/// and only its "SYNCED" readout stays on top. It replaces the top bar's
/// "Veylor is synced" status.
class NeonSyncBackdrop extends ConsumerWidget {
  const NeonSyncBackdrop({
    this.layer = NeonSyncLayer.back,
    this.scrolled = false,
    super.key,
  });

  final NeonSyncLayer layer;

  /// See [NeonSyncLineLayer.scrolled].
  final bool scrolled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider).value ?? SyncState();
    final whole = ref.watch(syncDisplayWholePercentageProvider);
    final status = SyncStatusLabel.from(
      sync,
      displayWholePercentage: whole,
      networkPrivacy: ref.watch(networkPrivacyProvider),
    );
    // A wallet a few blocks behind is catching up, not syncing: its line
    // stays full and behind the content instead of dropping and climbing
    // again on every new block.
    final gap = sync.chainTipHeight - sync.scannedHeight;
    final catchingUp =
        status.kind == SyncStatusKind.syncing &&
        status.label != kSyncStatusConnectingToTorLabel &&
        sync.lastSyncCompletedAt != null &&
        sync.chainTipHeight > 0 &&
        gap <= _catchUpBlocks;
    final syncing = status.kind == SyncStatusKind.syncing && !catchingUp;
    final progress = switch (status.kind) {
      _ when catchingUp => 1.0,
      SyncStatusKind.synced => 1.0,
      SyncStatusKind.syncing =>
        ref.watch(syncDisplayPercentageProvider).clamp(0.03, 0.99),
      SyncStatusKind.failed => sync.percentage.clamp(0.03, 0.99),
    };
    final readout = switch (status.kind) {
      _ when catchingUp => NeonSyncReadout.synced,
      SyncStatusKind.synced => NeonSyncReadout.synced,
      SyncStatusKind.failed =>
        status.label == kSyncStatusTorFailedLabel
            ? NeonSyncReadout.torOffline
            : NeonSyncReadout.failed,
      SyncStatusKind.syncing =>
        status.label == kSyncStatusConnectingToTorLabel
            ? NeonSyncReadout.torWaiting
            : NeonSyncReadout.progress(whole, checking: sync.isChecking),
    };
    return NeonSyncLineLayer(
      layer: layer,
      scrolled: scrolled,
      line: NeonSyncLine(
        progress: progress.toDouble(),
        readout: readout,
        semanticsLabel: status.semanticsLabel,
        climbing: syncing,
        failed: status.kind == SyncStatusKind.failed,
      ),
    );
  }
}

/// The backdrop's drawing, free of providers so previews can show any state.
class NeonSyncBackdropView extends StatefulWidget {
  const NeonSyncBackdropView({
    required this.progress,
    required this.readout,
    required this.active,
    bool? floorFlows,
    this.failed = false,
    this.drawFloor = true,
    this.linePart = NeonSyncLinePart.whole,
    this.drawReadout = true,
    this.lineX = _lineXFactor,
    this.readoutType = kNeonSyncReadoutType,
    super.key,
  }) : floorFlows = floorFlows ?? active;

  /// Where the line stands, as a fraction of the width.
  final double lineX;

  /// The type size of [readout].
  final NeonSyncReadoutType readoutType;

  /// Which parts this layer draws.
  final bool drawFloor;
  final NeonSyncLinePart linePart;
  final bool drawReadout;

  /// How far the sync line has climbed, 0..1.
  final double progress;

  /// The text at the line's head, drawn uppercase.
  final String readout;

  /// Scanning: the floor flows and a pulse runs up the line.
  final bool active;

  /// Whether the floor flows; [active] unless set. A synced line's refresh
  /// scans without the line's pulse.
  final bool floorFlows;
  final bool failed;

  @override
  State<NeonSyncBackdropView> createState() => _NeonSyncBackdropViewState();
}

class _NeonSyncBackdropViewState extends State<NeonSyncBackdropView>
    with SingleTickerProviderStateMixin {
  /// One floor cycle while something scans; the line's pulse climbs four
  /// times a cycle.
  static const _period = Duration(milliseconds: 2250);

  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: _period,
  );

  bool get _motion => !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncFlow();
  }

  @override
  void didUpdateWidget(NeonSyncBackdropView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFlow();
  }

  // Something moves only while something scans: the floor, and the climbing
  // line's pulse. Idle, nothing does, so no frame is drawn (the owner's
  // choice on 2026-10-17, iOS progress VI-19): a constant flow would repaint
  // a full-screen layer every frame while Home shows.
  bool get _moves =>
      _motion &&
      ((widget.drawFloor && widget.floorFlows) ||
          (widget.linePart != NeonSyncLinePart.none && widget.active));

  void _syncFlow() {
    if (!_moves) {
      _flow.stop();
    } else if (!_flow.isAnimating) {
      // From where it stopped. Setting `value` would stop it again.
      _flow.repeat();
    }
  }

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    final dark = context.colors.background.window.computeLuminance() < 0.2;
    final padding = MediaQuery.paddingOf(context);
    final split =
        widget.linePart == NeonSyncLinePart.head ||
        widget.linePart == NeonSyncLinePart.belowHead;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _BackdropPainter(
          flow: _flow,
          progress: widget.progress,
          active: widget.active,
          failed: widget.failed,
          drawFloor: widget.drawFloor,
          linePart: widget.linePart,
          // Both layers measure the same readout, so they split the line in
          // the same place.
          readoutLength: split
              ? neonSyncReadoutLength(
                  context,
                  widget.readout,
                  type: widget.readoutType,
                )
              : 0,
          glow: neon.glow,
          core: neon.core,
          floorStrength: dark ? 0.6 : 0.35,
          topLimit: padding.top + AppSpacing.xs,
          lineX: widget.lineX,
        ),
        child: widget.drawReadout
            ? _Readout(
                progress: widget.progress,
                text: widget.readout,
                color: neon.glow,
                core: neon.core,
                topLimit: padding.top + AppSpacing.xs,
                lineX: widget.lineX,
                type: widget.readoutType,
              )
            : null,
      ),
    );
  }
}

/// How far behind the tip a scan may start and still count as caught up.
const _catchUpBlocks = 20;

/// Where the sync line stands: in the right part of the screen, behind the
/// balance and the rows (which are glass), not along the edge.
const _lineXFactor = 0.85;
double _lineX(double width, double factor) =>
    (width * factor).roundToDouble() + 0.5;

/// How far below the head the readout starts.
const _readoutDrop = 10.0;

/// How far past the readout, and above the head (its glow), a head drawn
/// apart from the rest of its line reaches.
const _headMargin = 12.0;
const _headAbove = 32.0;

/// The readout's style; its colours aside, what lays it out.
TextStyle _readoutStyle(
  NeonSyncReadoutType type, {
  Color? color,
  Color? core,
}) => TextStyle(
  fontFamily: 'Gotham',
  fontSize: type.fontSize,
  height: 1,
  fontWeight: FontWeight.w300,
  letterSpacing: type.letterSpacing,
  color: core,
  shadows: color == null ? null : Neon.textGlow(color, intensity: 0.5),
);

/// How far down from its top the drawn [readout] reaches: its text's width,
/// as it reads bottom to top.
@visibleForTesting
double neonSyncReadoutLength(
  BuildContext context,
  String readout, {
  NeonSyncReadoutType type = kNeonSyncReadoutType,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: readout.toUpperCase(),
      style: DefaultTextStyle.of(context).style.merge(_readoutStyle(type)),
    ),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final length = painter.width;
  painter.dispose();
  return length;
}

/// The band of a line whose head is drawn apart from the rest (its front
/// layer's part): from above the head, its glow included, down past a
/// readout [readoutLength] long, on whole pixels so the seam never shows.
@visibleForTesting
Rect neonSyncHeadBand(
  Size size, {
  required double progress,
  required double topLimit,
  required double readoutLength,
}) {
  final headY = _headY(size.height, progress, topLimit);
  return Rect.fromLTRB(
    0,
    (headY - _headAbove).floorToDouble(),
    size.width,
    math.min(
      size.height,
      (headY + _readoutDrop + readoutLength + _headMargin).ceilToDouble(),
    ),
  );
}

class _Readout extends StatelessWidget {
  const _Readout({
    required this.progress,
    required this.text,
    required this.color,
    required this.core,
    required this.topLimit,
    required this.lineX,
    required this.type,
  });

  final double progress;
  final String text;
  final Color color;
  final Color core;
  final double topLimit;
  final double lineX;
  final NeonSyncReadoutType type;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final headY = _headY(height, progress, topLimit);
        // Read bottom to top, hanging just under the head, left of the line.
        return Stack(
          children: [
            Positioned(
              right:
                  constraints.maxWidth -
                  _lineX(constraints.maxWidth, lineX) +
                  7,
              top: headY + _readoutDrop,
              child: RotatedBox(
                quarterTurns: 3,
                child: Text(
                  text.toUpperCase(),
                  maxLines: 1,
                  style: _readoutStyle(type, color: color, core: core),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

double _headY(double height, double progress, double topLimit) {
  final travel = height - topLimit;
  return height - travel * progress.clamp(0.0, 1.0);
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.flow,
    required this.progress,
    required this.active,
    required this.failed,
    required this.drawFloor,
    required this.linePart,
    required this.readoutLength,
    required this.glow,
    required this.core,
    required this.floorStrength,
    required this.topLimit,
    required this.lineX,
  }) : super(repaint: flow);

  final Animation<double> flow;
  final double progress;
  final bool active;
  final bool failed;
  final bool drawFloor;
  final NeonSyncLinePart linePart;

  /// The readout's length, for where a head drawn apart ends.
  final double readoutLength;
  final Color glow;
  final Color core;
  final double floorStrength;
  final double topLimit;
  final double lineX;

  @override
  void paint(Canvas canvas, Size size) {
    if (drawFloor) _paintFloor(canvas, size);
    switch (linePart) {
      case NeonSyncLinePart.none:
        break;
      case NeonSyncLinePart.whole:
        _paintSyncLine(canvas, size);
      case NeonSyncLinePart.head || NeonSyncLinePart.belowHead:
        // The same line in both layers, each clipped to its share.
        final band = neonSyncHeadBand(
          size,
          progress: progress,
          topLimit: topLimit,
          readoutLength: readoutLength,
        );
        canvas
          ..save()
          ..clipRect(
            band,
            clipOp: linePart == NeonSyncLinePart.head
                ? ClipOp.intersect
                : ClipOp.difference,
          );
        _paintSyncLine(canvas, size);
        canvas.restore();
    }
  }

  /// A grid floor in perspective below a red horizon, flowing toward the
  /// viewer.
  void _paintFloor(Canvas canvas, Size size) {
    final horizon = size.height * 0.8;
    final floorHeight = size.height - horizon;
    final k = floorStrength;

    // The horizon: a thin lit seam with a soft bloom over the floor.
    final seam = Rect.fromLTWH(0, horizon - 40, size.width, 80);
    canvas.drawRect(
      seam,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            glow.withValues(alpha: 0),
            glow.withValues(alpha: 0.05 * k),
            glow.withValues(alpha: 0),
          ],
        ).createShader(seam),
    );
    canvas.drawLine(
      Offset(0, horizon),
      Offset(size.width, horizon),
      Paint()
        ..color = glow.withValues(alpha: 0.1 * k)
        ..strokeWidth = 1,
    );

    final fade = Paint()
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          glow.withValues(alpha: 0.02 * k),
          glow.withValues(alpha: 0.20 * k),
        ],
      ).createShader(Rect.fromLTWH(0, horizon, size.width, floorHeight));

    // Rows: squared spacing reads as depth; the phase walks them forward.
    const rows = 9;
    final phase = flow.value;
    for (var i = 0; i < rows + 1; i++) {
      final t = (i + phase) / rows;
      if (t > 1) continue;
      final y = horizon + floorHeight * t * t;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), fade);
    }

    // Columns fan out from a vanishing point on the horizon.
    final vanishing = Offset(size.width / 2, horizon);
    const columns = 14;
    final spread = size.width * 2.6;
    for (var j = 0; j <= columns; j++) {
      final x = size.width / 2 + (j / columns - 0.5) * spread;
      canvas.drawLine(vanishing, Offset(x, size.height), fade);
    }
  }

  /// The rising tube along the right edge, with a pulse while scanning.
  void _paintSyncLine(Canvas canvas, Size size) {
    final x = _lineX(size.width, lineX);
    final headY = _headY(size.height, progress, topLimit);
    final intensity = failed ? 0.4 : 0.8;

    // Synced, the line steps back behind the content: Home's blocks hide it,
    // so it shows only in the gaps between them.
    final quiet = !active && !failed;
    if (quiet) {
      Neon.strokeTube(
        canvas,
        Path()
          ..moveTo(x, size.height)
          ..lineTo(x, headY),
        glow: glow,
        core: core,
        width: 1.4,
        intensity: 0.6,
      );
      _paintHead(canvas, Offset(x, headY), 0.7);
      return;
    }

    // The unlit rest of the track, so the climb has a scale.
    canvas.drawLine(
      Offset(x, topLimit),
      Offset(x, size.height),
      Paint()
        ..color = glow.withValues(alpha: 0.10)
        ..strokeWidth = 1,
    );

    final line = Path()
      ..moveTo(x, size.height)
      ..lineTo(x, headY);
    Neon.strokeTube(
      canvas,
      line,
      glow: glow,
      core: core,
      width: 1.6,
      intensity: intensity,
    );

    if (active) {
      // A bright packet climbing the lit part.
      final travel = size.height - headY;
      final packetY = size.height - travel * ((flow.value * 4) % 1);
      final packet = Path()
        ..moveTo(x, math.min(size.height, packetY + 18))
        ..lineTo(x, math.max(headY, packetY - 18));
      Neon.strokeTube(
        canvas,
        packet,
        glow: glow,
        core: core,
        width: 2.4,
        intensity: 0.85,
      );
    }

    _paintHead(canvas, Offset(x, headY), intensity);
  }

  void _paintHead(Canvas canvas, Offset center, double intensity) {
    final head = Rect.fromCenter(center: center, width: 7, height: 7);
    canvas
      ..drawRect(
        head.inflate(5),
        Paint()
          ..color = glow.withValues(alpha: 0.6 * intensity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      )
      ..drawRect(head, Paint()..color = glow.withValues(alpha: intensity))
      ..drawRect(
        head.deflate(2),
        Paint()..color = core.withValues(alpha: intensity),
      );
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.active != active ||
        oldDelegate.drawFloor != drawFloor ||
        oldDelegate.linePart != linePart ||
        oldDelegate.readoutLength != readoutLength ||
        oldDelegate.failed != failed ||
        oldDelegate.glow != glow ||
        oldDelegate.core != core ||
        oldDelegate.floorStrength != floorStrength ||
        oldDelegate.topLimit != topLimit ||
        oldDelegate.lineX != lineX;
  }
}
