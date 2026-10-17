@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/formatting/date_format.dart';
import 'package:zcash_wallet/src/core/layout/mobile/neon_sync_backdrop.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/providers/network_privacy_provider.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// iOS progress VI-19: Railgun's sync on the Private USD screen is Home's sync
// line, with Home's layers and catch-up rule. Its readouts name Railgun
// (owner, 2026-10-17); the Tor ones are Home's.
void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(393, 852);
    view.devicePixelRatio = 1;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  var refreshes = 0;

  Future<void> pumpView(
    WidgetTester tester,
    PrivateUsdBalanceState state, {
    NetworkPrivacyState? networkPrivacy,
  }) async {
    refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: MobilePrivateUsdView(
            state: state,
            networkPrivacy: networkPrivacy,
            zecUsdPrice: 50,
            privacyModeEnabled: false,
            receiveAddress: state.balances == null
                ? null
                : previewPrivateUsdAddress,
            screening: const Duration(hours: 1),
            onBack: () {},
            onRefresh: () => refreshes++,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  NeonSyncBackdropView layer(WidgetTester tester, NeonSyncLayer which) =>
      tester.widget<NeonSyncBackdropView>(
        find.descendant(
          of: find.byKey(
            ValueKey(
              which == NeonSyncLayer.front
                  ? 'mobile_private_usd_sync_front'
                  : 'mobile_private_usd_sync_back',
            ),
          ),
          matching: find.byType(NeonSyncBackdropView),
        ),
      );

  // The text at the line's head, as drawn.
  String readout(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('mobile_private_usd_sync_front')),
          matching: find.byType(Text),
        ),
      )
      .data!;

  testWidgets('a first sync climbs over the content with its percentage', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpView(
      tester,
      const PrivateUsdBalanceState(isRefreshing: true, firstSyncPercent: 42),
    );

    final front = layer(tester, NeonSyncLayer.front);
    final back = layer(tester, NeonSyncLayer.back);
    expect(readout(tester), 'RAILGUN SYNC 42%');
    expect(front.progress, 0.42);
    expect(front.drawLine, isTrue, reason: 'climbing, over the content');
    expect(front.active, isTrue);
    expect(back.drawLine, isFalse);
    expect(back.drawFloor, isTrue);
    expect(back.floorFlows, isTrue);
    expect(
      find.ancestor(
        of: find.byWidget(front),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
    // The percentage is the line's now; screen readers still hear it all.
    expect(find.text(PrivateUsdCopy.firstLoadProgress(42)), findsNothing);
    expect(find.text(PrivateUsdCopy.firstLoad), findsOneWidget);
    expect(
      find.bySemanticsLabel(PrivateUsdCopy.firstLoadProgress(42)),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('before the first report it reads 0% on a stub', (tester) async {
    await pumpView(tester, previewPrivateUsdLoading);

    expect(readout(tester), 'RAILGUN SYNC 0%');
    expect(layer(tester, NeonSyncLayer.front).progress, 0.03);
  });

  testWidgets('a page waiting for Tor reads TOR …', (tester) async {
    await pumpView(
      tester,
      previewPrivateUsdLoading,
      networkPrivacy: const NetworkPrivacyState(
        torEnabled: true,
        status: NetworkPrivacyConnectionStatus.connecting,
      ),
    );

    expect(readout(tester), 'TOR …');
    expect(layer(tester, NeonSyncLayer.front).drawLine, isTrue);
  });

  testWidgets('a synced balance runs the line behind blocks backed solid', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpView(tester, previewPrivateUsdBalance(available: 100));

    final front = layer(tester, NeonSyncLayer.front);
    final back = layer(tester, NeonSyncLayer.back);
    expect(readout(tester), 'RAILGUN SYNCED');
    expect(back.progress, 1);
    expect(back.drawLine, isTrue, reason: 'behind the content');
    expect(back.active, isFalse);
    expect(back.floorFlows, isFalse);
    expect(front.drawLine, isFalse);
    for (final block in const [
      'mobile_private_usd_total',
      'mobile_private_usd_buckets',
      'mobile_private_usd_receive',
      'mobile_private_usd_activity_empty',
    ]) {
      expect(
        find.ancestor(
          of: find.byKey(ValueKey(block)),
          matching: find.byType(NeonSyncOcclude),
        ),
        findsOneWidget,
        reason: block,
      );
    }
    final updated = PrivateUsdCopy.updated(
      formatDayMonthTime(previewPrivateUsdUpdatedAt),
    );
    expect(find.text(updated), findsOneWidget);
    expect(find.bySemanticsLabel(updated), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a refresh of a synced balance stays synced, with a faster '
      'floor', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpView(
      tester,
      previewPrivateUsdBalance(available: 100, isRefreshing: true),
    );

    final back = layer(tester, NeonSyncLayer.back);
    expect(readout(tester), 'RAILGUN SYNCED');
    expect(back.progress, 1, reason: 'no drop to 0 and climb again');
    expect(back.drawLine, isTrue);
    expect(back.active, isFalse);
    expect(back.floorFlows, isTrue);
    expect(layer(tester, NeonSyncLayer.front).drawLine, isFalse);
    expect(find.text(PrivateUsdCopy.updating), findsNothing);
    expect(find.bySemanticsLabel(PrivateUsdCopy.updating), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a failed refresh reads RAILGUN SYNC FAILED, or TOR OFFLINE '
      'when Tor failed', (tester) async {
    final semantics = tester.ensureSemantics();
    final failed = previewPrivateUsdBalance(
      available: 100,
      refreshFailed: true,
    );
    await pumpView(tester, failed);

    expect(readout(tester), 'RAILGUN SYNC FAILED');
    expect(layer(tester, NeonSyncLayer.back).failed, isTrue);
    expect(find.text(PrivateUsdCopy.refreshFailed), findsOneWidget);
    expect(find.bySemanticsLabel(PrivateUsdCopy.refreshFailed), findsOneWidget);

    await pumpView(
      tester,
      failed,
      networkPrivacy: const NetworkPrivacyState(
        torEnabled: true,
        status: NetworkPrivacyConnectionStatus.failed,
      ),
    );
    expect(readout(tester), 'TOR OFFLINE');
    semantics.dispose();
  });

  testWidgets('a failed first load reads RAILGUN SYNC FAILED', (tester) async {
    await pumpView(tester, const PrivateUsdBalanceState(refreshFailed: true));

    expect(readout(tester), 'RAILGUN SYNC FAILED');
    expect(find.text(PrivateUsdCopy.loadFailed), findsOneWidget);
  });

  testWidgets('the climbing line takes no touches: refresh still works', (
    tester,
  ) async {
    // No balance yet and no refresh running: the line climbs over the card.
    await pumpView(tester, const PrivateUsdBalanceState(firstSyncPercent: 30));
    expect(layer(tester, NeonSyncLayer.front).drawLine, isTrue);

    await tester.tap(find.byKey(const ValueKey('mobile_private_usd_refresh')));
    expect(refreshes, 1);
  });
}
