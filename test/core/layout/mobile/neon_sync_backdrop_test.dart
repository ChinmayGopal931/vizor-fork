@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/mobile/neon_sync_backdrop.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';

// The floor flows, and a climbing line's pulse runs, only while something
// scans; idle, nothing moves and no frame is drawn (the owner's choice on
// 2026-10-17, iOS progress VI-19).
void main() {
  const synced = NeonSyncLine(
    progress: 1,
    readout: NeonSyncReadout.synced,
    semanticsLabel: 'Synced',
  );
  final climbing = NeonSyncLine(
    progress: 0.4,
    readout: NeonSyncReadout.progress(40),
    semanticsLabel: 'Syncing 40%',
    climbing: true,
  );
  // A synced Private USD wallet refreshing: the floor flows under the line.
  const refreshing = NeonSyncLine(
    progress: 1,
    readout: NeonSyncReadout.synced,
    semanticsLabel: 'Updating…',
    scanning: true,
  );

  Future<void> pumpLayer(
    WidgetTester tester,
    NeonSyncLine line, {
    NeonSyncLayer layer = NeonSyncLayer.back,
    bool disableAnimations = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: disableAnimations),
              child: NeonSyncLineLayer(line: line, layer: layer),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  // Whether the layer keeps asking for frames.
  bool moving(WidgetTester tester) => tester.binding.hasScheduledFrame;

  testWidgets('a synced line stands still in both layers', (tester) async {
    await pumpLayer(tester, synced);
    expect(moving(tester), isFalse);

    await pumpLayer(tester, synced, layer: NeonSyncLayer.front);
    expect(moving(tester), isFalse);
  });

  testWidgets('a climbing line flows the floor and runs its pulse', (
    tester,
  ) async {
    await pumpLayer(tester, climbing);
    expect(moving(tester), isTrue, reason: 'the floor');

    await pumpLayer(tester, climbing, layer: NeonSyncLayer.front);
    expect(moving(tester), isTrue, reason: 'the pulse');
  });

  testWidgets('a refresh of a synced line flows only the floor', (
    tester,
  ) async {
    await pumpLayer(tester, refreshing);
    expect(moving(tester), isTrue);

    // The front layer draws only the readout then.
    await pumpLayer(tester, refreshing, layer: NeonSyncLayer.front);
    expect(moving(tester), isFalse);
  });

  testWidgets('the floor stops once the sync is done', (tester) async {
    await pumpLayer(tester, climbing);
    expect(moving(tester), isTrue);

    await pumpLayer(tester, synced);
    expect(moving(tester), isFalse);

    await pumpLayer(tester, refreshing);
    expect(moving(tester), isTrue, reason: 'and flows again when one starts');
  });

  NeonSyncBackdropView view(WidgetTester tester) =>
      tester.widget<NeonSyncBackdropView>(find.byType(NeonSyncBackdropView));

  testWidgets('a line behind the content keeps its head in front', (
    tester,
  ) async {
    // Synced (or failed), the line runs behind; its head, beside the
    // readout, is the front layer's, so nothing between the layers cuts it
    // there (owner, 2026-10-17).
    await pumpLayer(tester, synced);
    expect(view(tester).linePart, NeonSyncLinePart.belowHead);
    await pumpLayer(tester, synced, layer: NeonSyncLayer.front);
    expect(view(tester).linePart, NeonSyncLinePart.head);

    // Climbing, the whole line is over the content.
    await pumpLayer(tester, climbing);
    expect(view(tester).linePart, NeonSyncLinePart.none);
    await pumpLayer(tester, climbing, layer: NeonSyncLayer.front);
    expect(view(tester).linePart, NeonSyncLinePart.whole);
  });

  testWidgets('the head drawn in front reaches past the readout', (
    tester,
  ) async {
    for (final line in [
      synced,
      NeonSyncLine(
        progress: 1,
        readout: 'Railgun sync failed',
        semanticsLabel: 'Failed',
        failed: true,
      ),
    ]) {
      await pumpLayer(tester, line, layer: NeonSyncLayer.front);
      final readout = tester.getRect(
        find.descendant(
          of: find.byType(NeonSyncBackdropView),
          matching: find.byType(RotatedBox),
        ),
      );
      final length = neonSyncReadoutLength(
        tester.element(find.byType(NeonSyncBackdropView)),
        line.readout,
      );
      // The measure is the readout as drawn, reading bottom to top.
      expect(length, moreOrLessEquals(readout.height, epsilon: 0.5));
      final size = tester.getSize(find.byType(NeonSyncBackdropView));
      final band = neonSyncHeadBand(
        size,
        progress: line.progress,
        topLimit: AppSpacing.xs,
        readoutLength: length,
      );
      expect(band.top, lessThan(readout.top - 10), reason: 'the head');
      expect(band.bottom, greaterThan(readout.bottom), reason: line.readout);
      expect(band.top, band.top.roundToDouble(), reason: 'whole pixels');
      expect(band.bottom, band.bottom.roundToDouble());
    }
  });

  testWidgets('reduced motion holds everything still', (tester) async {
    await pumpLayer(tester, climbing, disableAnimations: true);
    expect(moving(tester), isFalse);

    await pumpLayer(
      tester,
      climbing,
      layer: NeonSyncLayer.front,
      disableAnimations: true,
    );
    expect(moving(tester), isFalse);
  });

  // A finished bridge's banner going away shrank the Private USD page under
  // a scrolled position: the list was clamped back to its top without a
  // scroll notification, and the page kept its readout hidden.
  testWidgets('a list clamped back to its top no longer reads as scrolled', (
    tester,
  ) async {
    final rows = ValueNotifier(40);
    addTearDown(rows.dispose);
    bool? scrolled;
    await tester.pumpWidget(
      MaterialApp(
        home: NeonSyncScrolled(
          builder: (context, value) {
            scrolled = value;
            return ValueListenableBuilder<int>(
              valueListenable: rows,
              builder: (context, count, _) => ListView(
                children: [
                  for (var i = 0; i < count; i++) const SizedBox(height: 50),
                ],
              ),
            );
          },
        ),
      ),
    );
    expect(scrolled, isFalse);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(scrolled, isTrue);

    rows.value = 2;
    await tester.pumpAndSettle();
    expect(scrolled, isFalse);
  });
}
