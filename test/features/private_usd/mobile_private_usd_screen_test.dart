@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/l10n/app_language.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_pending_payment.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_pending_payment_line.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';
import '../../support/test_l10n.dart';

// The Private USD screen's states (plan reference §9.4 S2).
void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(393, 1400);
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

  Future<void> pumpScreen(
    WidgetTester tester,
    PrivateUsdBalanceState state, {
    PrivateUsdPendingPayment? pendingPayment,
    String? spendNote,
    RailgunScreeningEvent? screeningActivity,
    VoidCallback? onUseDefaultRpc,
    VoidCallback? onChangeRpc,
  }) async {
    refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        home: AppTheme(
          data: AppThemeData.dark,
          child: MobilePrivateUsdView(
            state: state,
            screeningActivity: screeningActivity,
            zecUsdPrice: 50,
            privacyModeEnabled: false,
            screening: const Duration(hours: 1),
            onBack: () {},
            onRefresh: () => refreshes++,
            pendingPayment: pendingPayment,
            spendNote: spendNote,
            onUseDefaultRpc: onUseDefaultRpc,
            onChangeRpc: onChangeRpc,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a balance shows its buckets and activity', (tester) async {
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100, arriving: 20, processing: 5),
    );

    // The page title is drawn uppercase in the top bar.
    expect(find.text(testL10n.privateUsdTitle.toUpperCase()), findsOneWidget);
    expect(find.text(testL10n.privateUsdSubtitle), findsOneWidget);
    expect(find.text(r'$105.00'), findsOneWidget);
    expect(find.text(testL10n.privateUsdRowAvailable), findsOneWidget);
    expect(find.text(testL10n.privateUsdRowProcessing), findsOneWidget);
    expect(find.text(testL10n.privateUsdRowArriving), findsOneWidget);
    expect(
      find.text(testL10n.privateUsdRowArrivingInfo(_hour)),
      findsOneWidget,
    );
    expect(find.text(testL10n.privateUsdRowBlocked), findsNothing);
    // The 0zk address moved into the Receive sheet (owner, 2026-10-19).
    expect(
      find.byKey(const ValueKey('mobile_private_usd_receive')),
      findsNothing,
    );
    expect(find.text(previewPrivateUsdAddress), findsNothing);
    expect(find.text(testL10n.privateUsdActivityEmpty), findsOneWidget);
    expect(find.text(testL10n.privateUsdEmptyTitle), findsNothing);
    // Convert shows only with its action (the screen always gives one);
    // Send and Withdraw arrive with M7.
    expect(find.text(testL10n.privateUsdActionConvert), findsNothing);
    expect(find.text(testL10n.privateUsdActionSend), findsNothing);
  });

  testWidgets('processing says so when the screening keeps failing', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 8.8, processing: 29.11),
    );
    expect(find.text(testL10n.privateUsdRowProcessing), findsOneWidget);
    expect(find.text(testL10n.privateUsdRowProcessingInfo), findsOneWidget);
    expect(find.text(testL10n.privateUsdRowProcessingStalled), findsNothing);

    await pumpScreen(
      tester,
      previewPrivateUsdBalance(
        available: 8.8,
        processing: 29.11,
      ).copyWith(screeningFailed: true),
    );
    expect(find.text(testL10n.privateUsdRowProcessingStalled), findsOneWidget);
    expect(
      find.text(testL10n.privateUsdRowProcessingStalledInfo),
      findsOneWidget,
    );
    expect(find.text(testL10n.privateUsdRowProcessing), findsNothing);
    expect(find.text(testL10n.privateUsdRowProcessingInfo), findsNothing);
    expect(find.text(r'$29.11'), findsOneWidget);

    // Nothing processing, nothing to say.
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 8.8).copyWith(screeningFailed: true),
    );
    expect(find.text(testL10n.privateUsdRowProcessingStalled), findsNothing);
  });

  testWidgets('processing says what the screening work is doing, smaller '
      'and in another colour than its label (owner, 2026-10-19)', (
    tester,
  ) async {
    const statusKey = ValueKey('mobile_private_usd_row_status');
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 8.8, processing: 29.11),
      screeningActivity: const RailgunScreeningEvent(
        proving: RailgunPoiProving(index: 1, count: 3, progress: 0.4),
      ),
    );
    final status = tester.widget<Text>(find.byKey(statusKey));
    expect(status.data, PrivateUsdCopy.screeningProving(testL10n, 1, 3, 40));
    final label = tester.widget<Text>(
      find.text(testL10n.privateUsdRowProcessing),
    );
    expect(status.style!.fontSize!, lessThan(label.style!.fontSize!));
    expect(status.style!.color, isNot(label.style!.color));

    // Nothing running and nothing a node has taken: no line.
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 8.8, processing: 29.11),
      screeningActivity: const RailgunScreeningEvent(),
    );
    expect(find.byKey(statusKey), findsNothing);
  });

  testWidgets('a payment in flight shows its stage, with observed numbers '
      'only (owner, 2026-10-17)', (tester) async {
    String line() => tester
        .widget<Text>(
          find.byKey(const ValueKey('mobile_private_usd_pending_payment')),
        )
        .data!;

    await pumpScreen(tester, previewPrivateUsdBalance(available: 100));
    expect(
      find.byKey(const ValueKey('mobile_private_usd_pending_payment')),
      findsNothing,
    );

    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100),
      pendingPayment: const PrivateUsdPaymentProving(42),
      spendNote: testL10n.privateUsdPaymentPending,
    );
    expect(line(), testL10n.privateUsdPaymentProving(42));
    expect(find.text(testL10n.privateUsdPaymentPending), findsOneWidget);

    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100),
      pendingPayment: const PrivateUsdPaymentUpdatingBalance(),
    );
    expect(line(), testL10n.privateUsdPaymentUpdatingBalance);
  });

  testWidgets('the wait for a block counts up from the post', (tester) async {
    var now = DateTime(2026, 10, 17, 12);
    final posted = now.subtract(const Duration(seconds: 65));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        home: AppTheme(
          data: AppThemeData.dark,
          child: Center(
            child: PrivateUsdPendingPaymentLine(
              payment: PrivateUsdPaymentWaitingForBlock(posted),
              now: () => now,
            ),
          ),
        ),
      ),
    );
    expect(
      find.text(testL10n.privateUsdPaymentWaitingForBlock('1:05')),
      findsOne,
    );

    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text(testL10n.privateUsdPaymentWaitingForBlock('1:06')),
      findsOne,
    );
  });

  testWidgets('an empty balance shows the empty state', (tester) async {
    await pumpScreen(tester, previewPrivateUsdBalance());

    expect(find.text(testL10n.privateUsdEmptyTitle), findsOneWidget);
    expect(find.text(testL10n.privateUsdEmptyBody), findsOneWidget);
    expect(find.text(testL10n.privateUsdRowAvailable), findsNothing);
  });

  // The percentage is on the sync line (iOS progress VI-19, its own test);
  // the card says what a first load takes.
  testWidgets('a first load says what it takes, its percentage on the line', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const PrivateUsdBalanceState(isRefreshing: true, firstSyncPercent: 42),
    );

    expect(find.text(testL10n.privateUsdFirstLoad), findsOneWidget);
    expect(find.text(testL10n.privateUsdFirstLoadProgress(42)), findsNothing);
    expect(find.text('RAILGUN SYNC 42%'), findsOneWidget);
    expect(find.text(PrivateUsdCopy.unknown), findsOneWidget);
  });

  testWidgets("a long sync's balance shows at once, saying its rest runs on "
      'and what waits on it', (tester) async {
    const waitsKey = ValueKey('mobile_private_usd_syncing_waits');
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100, unproved: 12.5, syncing: true),
      screeningActivity: const RailgunScreeningEvent(txids: 0.42),
    );
    expect(find.text(r'$112.50'), findsOneWidget);
    expect(find.text(PrivateUsdCopy.syncingRest(testL10n, 42)), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(waitsKey)).data,
      testL10n.privateUsdSyncingRestWaits(r'$12.50'),
    );

    // Nothing waits on it: the line alone, before the page says how far.
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100, syncing: true),
    );
    expect(
      find.text(PrivateUsdCopy.syncingRest(testL10n, null)),
      findsOneWidget,
    );
    expect(find.byKey(waitsKey), findsNothing);

    // Once it ends, the balance says how old it is again.
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100, unproved: 12.5),
    );
    expect(find.byKey(waitsKey), findsNothing);
    expect(find.textContaining('Updated '), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the last balance and says so', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100, refreshFailed: true),
    );
    expect(find.text(testL10n.privateUsdRefreshFailed), findsOneWidget);

    await pumpScreen(tester, const PrivateUsdBalanceState(refreshFailed: true));
    expect(find.text(testL10n.privateUsdLoadFailed), findsOneWidget);
  });

  testWidgets('a sync the default RPC failed offers another RPC, and the '
      'user\'s own the default', (tester) async {
    var changes = 0;
    await pumpScreen(
      tester,
      const PrivateUsdBalanceState(refreshFailed: true, rpcFailed: true),
      onChangeRpc: () => changes++,
    );
    expect(
      find.text(testL10n.privateUsdRpcDefaultNotAnswering),
      findsOneWidget,
    );
    expect(find.text(testL10n.privateUsdLoadFailed), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('mobile_private_usd_rpc_change')),
    );
    expect(changes, 1);

    // The verdict outlives the retry, which shows as loading.
    await pumpScreen(
      tester,
      const PrivateUsdBalanceState(isRefreshing: true, rpcFailed: true),
      onChangeRpc: () => changes++,
    );
    expect(
      find.text(testL10n.privateUsdRpcDefaultNotAnswering),
      findsOneWidget,
    );
    expect(find.text(testL10n.privateUsdFirstLoad), findsOneWidget);

    await pumpScreen(
      tester,
      const PrivateUsdBalanceState(refreshFailed: true, rpcFailed: true),
      onUseDefaultRpc: () {},
      onChangeRpc: () => changes++,
    );
    expect(find.text(testL10n.privateUsdRpcNotAnswering), findsOneWidget);
    expect(find.text(testL10n.privateUsdRpcDefaultNotAnswering), findsNothing);
    expect(
      find.byKey(const ValueKey('mobile_private_usd_rpc_change')),
      findsNothing,
    );
  });

  testWidgets('refused funds show their row in the danger colour', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 80, blocked: 25),
    );

    final label = tester.widget<Text>(find.text(testL10n.privateUsdRowBlocked));
    expect(label.style!.color, AppThemeData.dark.colors.text.destructive);
    expect(find.text(testL10n.privateUsdRowBlockedInfo), findsOneWidget);
  });

  testWidgets('refresh asks again', (tester) async {
    await pumpScreen(tester, previewPrivateUsdBalance(available: 1));

    await tester.tap(find.byKey(const ValueKey('mobile_private_usd_refresh')));
    expect(refreshes, 1);
  });

  // The progress is the sync line's: a tap during an automatic refresh shows
  // that one's.
  testWidgets('refresh takes a tap while a refresh runs, and its arrow holds '
      'still', (tester) async {
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 1, isRefreshing: true),
    );
    final refresh = find.byKey(const ValueKey('mobile_private_usd_refresh'));

    expect(
      find.descendant(of: refresh, matching: find.byType(RotationTransition)),
      findsNothing,
    );
    await tester.tap(refresh);
    expect(refreshes, 1);
  });

  testWidgets('the info sheet explains the feature', (tester) async {
    await pumpScreen(tester, previewPrivateUsdBalance(available: 1));

    await tester.tap(find.byKey(const ValueKey('mobile_private_usd_info')));
    await tester.pumpAndSettle();

    expect(find.text(testL10n.privateUsdInfoTitle), findsOneWidget);
    expect(find.text(testL10n.privateUsdInfoConvert), findsOneWidget);
    expect(find.text(testL10n.privateUsdInfoReceive), findsOneWidget);
    expect(find.text(testL10n.privateUsdInfoScreening(_hour)), findsOneWidget);
  });

  // Mainnet pins no windows contract yet (`ApiDeployment.bridgeAvailable`).
  testWidgets('with bridging off, nothing on the screen leads to Bridge', (
    tester,
  ) async {
    Future<void> pump({required bool bridgeAvailable}) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          home: AppTheme(
            data: AppThemeData.dark,
            child: MobilePrivateUsdView(
              state: previewPrivateUsdBalance(),
              zecUsdPrice: 50,
              privacyModeEnabled: false,
              screening: const Duration(hours: 1),
              onBack: () {},
              onRefresh: () {},
              onConvert: () {},
              onSend: () {},
              onWithdraw: () {},
              onReceive: () {},
              bridgeAvailable: bridgeAvailable,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    const bridge = ValueKey('mobile_private_usd_convert');
    await pump(bridgeAvailable: true);
    expect(find.byKey(bridge), findsOneWidget);
    expect(find.text(testL10n.privateUsdEmptyBody), findsOneWidget);

    await pump(bridgeAvailable: false);
    expect(find.byKey(bridge), findsNothing);
    expect(find.text(testL10n.privateUsdActionConvert), findsNothing);
    expect(find.text(testL10n.privateUsdEmptyBody), findsNothing);
    expect(find.text(testL10n.privateUsdEmptyBodyReceive), findsOneWidget);
    // Receive, Send and Withdraw stay.
    for (final key in [
      'mobile_private_usd_receive_usdc',
      'mobile_private_usd_send',
      'mobile_private_usd_withdraw',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }

    await tester.tap(find.byKey(const ValueKey('mobile_private_usd_info')));
    await tester.pumpAndSettle();
    expect(find.text(testL10n.privateUsdInfoTitle), findsOneWidget);
    expect(find.text(testL10n.privateUsdInfoConvert), findsNothing);
    expect(find.text(testL10n.privateUsdInfoReceive), findsOneWidget);
  });
}

final _hour = PrivateUsdCopy.about(testL10n, const Duration(hours: 1));
