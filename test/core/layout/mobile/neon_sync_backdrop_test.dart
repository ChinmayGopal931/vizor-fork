@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/mobile/neon_sync_backdrop.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/providers/network_privacy_provider.dart';
import 'package:zcash_wallet/src/providers/sync_failure.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';

// The floor flows, and a climbing line's pulse runs, only while something
// scans; idle, nothing moves and no frame is drawn.
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

  NeonSyncLineLayer layer(WidgetTester tester) =>
      tester.widget<NeonSyncLineLayer>(find.byType(NeonSyncLineLayer));

  testWidgets('a line behind the content keeps its head in front', (
    tester,
  ) async {
    // Synced (or failed), the line runs behind; its head, beside the
    // readout, is the front layer's, so nothing between the layers cuts it
    // there.
    await pumpLayer(tester, synced);
    expect(layer(tester).linePart, NeonSyncLinePart.belowHead);
    await pumpLayer(tester, synced, layer: NeonSyncLayer.front);
    expect(layer(tester).linePart, NeonSyncLinePart.head);

    // Climbing, the whole line is over the content.
    await pumpLayer(tester, climbing);
    expect(layer(tester).linePart, NeonSyncLinePart.none);
    await pumpLayer(tester, climbing, layer: NeonSyncLayer.front);
    expect(layer(tester).linePart, NeonSyncLinePart.whole);
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
          of: find.byType(NeonSyncLineLayer),
          matching: find.byType(RotatedBox),
        ),
      );
      final length = neonSyncReadoutLength(
        tester.element(find.byType(NeonSyncLineLayer)),
        line.readout,
      );
      // The measure is the readout as drawn, reading bottom to top.
      expect(length, moreOrLessEquals(readout.height, epsilon: 0.5));
      final size = tester.getSize(find.byType(NeonSyncLineLayer));
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

  // Home's line and the wide window's sidebar read the same wallet state, so
  // they must never disagree.
  group('the wallet line', () {
    const off = NetworkPrivacyState.off();

    test(
      'a scan climbs with its display progress and reads its percentage',
      () {
        final line = NeonSyncLine.wallet(
          SyncState(isSyncing: true, percentage: 0.4),
          whole: 42,
          networkPrivacy: off,
          climbProgress: () => 0.42,
        );
        expect(line.readout, NeonSyncReadout.progress(42));
        expect(line.progress, 0.42);
        expect(line.climbing, isTrue);
        expect(line.failed, isFalse);
      },
    );

    test('a synced wallet is full and never reads the climb', () {
      final line = NeonSyncLine.wallet(
        SyncState(percentage: 1),
        whole: 100,
        networkPrivacy: off,
        climbProgress: () => fail('read while synced'),
      );
      expect(line.readout, NeonSyncReadout.synced);
      expect(line.progress, 1);
      expect(line.climbing, isFalse);
    });

    test('a scan a few blocks behind the tip reads as synced', () {
      final line = NeonSyncLine.wallet(
        SyncState(
          isSyncing: true,
          percentage: 0.99,
          scannedHeight: 1000,
          chainTipHeight: 1010,
          lastSyncCompletedAt: DateTime(2026),
        ),
        whole: 99,
        networkPrivacy: off,
        climbProgress: () => fail('read while catching up'),
      );
      expect(line.readout, NeonSyncReadout.synced);
      expect(line.semanticsLabel, 'Veylor is synced');
      expect(line.progress, 1);
      expect(line.climbing, isFalse);
    });

    test('a failed sync holds where it stopped', () {
      final line = NeonSyncLine.wallet(
        SyncState(
          percentage: 0.3,
          failure: const SyncFailure(
            kind: SyncFailureKind.network,
            rawMessage: 'offline',
            userMessage: 'Network error',
          ),
        ),
        whole: 30,
        networkPrivacy: off,
        climbProgress: () => fail('read after a failure'),
      );
      expect(line.readout, NeonSyncReadout.failed);
      expect(line.progress, 0.3);
      expect(line.failed, isTrue);
      expect(line.climbing, isFalse);
    });

    test('Tor reads first: waiting on it, then offline', () {
      final waiting = NeonSyncLine.wallet(
        SyncState(isSyncing: true),
        whole: 1,
        networkPrivacy: const NetworkPrivacyState(
          torEnabled: true,
          status: NetworkPrivacyConnectionStatus.connecting,
        ),
        climbProgress: () => 0.01,
      );
      expect(waiting.readout, NeonSyncReadout.torWaiting);
      expect(waiting.climbing, isTrue);
      final offline = NeonSyncLine.wallet(
        SyncState(percentage: 0.5),
        whole: 50,
        networkPrivacy: const NetworkPrivacyState(
          torEnabled: true,
          status: NetworkPrivacyConnectionStatus.failed,
        ),
        climbProgress: () => fail('read while Tor is offline'),
      );
      expect(offline.readout, NeonSyncReadout.torOffline);
      expect(offline.failed, isTrue);
    });
  });
}
