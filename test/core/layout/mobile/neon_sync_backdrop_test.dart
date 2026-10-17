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
}
