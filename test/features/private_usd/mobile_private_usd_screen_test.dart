@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_pending_payment.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_pending_payment_line.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

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
  }) async {
    refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
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
    expect(find.text(PrivateUsdCopy.title.toUpperCase()), findsOneWidget);
    expect(find.text(PrivateUsdCopy.subtitle), findsOneWidget);
    expect(find.text(r'$105.00'), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowAvailable), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowProcessing), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowArriving), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowArrivingInfo(_hour)), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowBlocked), findsNothing);
    // The 0zk address moved into the Receive sheet (owner, 2026-10-19).
    expect(
      find.byKey(const ValueKey('mobile_private_usd_receive')),
      findsNothing,
    );
    expect(find.text(previewPrivateUsdAddress), findsNothing);
    expect(find.text(PrivateUsdCopy.activityEmpty), findsOneWidget);
    expect(find.text(PrivateUsdCopy.emptyTitle), findsNothing);
    // Convert shows only with its action (the screen always gives one);
    // Send and Withdraw arrive with M7.
    expect(find.text(PrivateUsdCopy.actionConvert), findsNothing);
    expect(find.text(PrivateUsdCopy.actionSend), findsNothing);
  });

  testWidgets('processing says so when the screening keeps failing', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 8.8, processing: 29.11),
    );
    expect(find.text(PrivateUsdCopy.rowProcessing), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowProcessingInfo), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowProcessingStalled), findsNothing);

    await pumpScreen(
      tester,
      previewPrivateUsdBalance(
        available: 8.8,
        processing: 29.11,
      ).copyWith(screeningFailed: true),
    );
    expect(find.text(PrivateUsdCopy.rowProcessingStalled), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowProcessingStalledInfo), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowProcessing), findsNothing);
    expect(find.text(PrivateUsdCopy.rowProcessingInfo), findsNothing);
    expect(find.text(r'$29.11'), findsOneWidget);

    // Nothing processing, nothing to say.
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 8.8).copyWith(screeningFailed: true),
    );
    expect(find.text(PrivateUsdCopy.rowProcessingStalled), findsNothing);
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
    expect(status.data, PrivateUsdCopy.screeningProving(1, 3, 40));
    final label = tester.widget<Text>(find.text(PrivateUsdCopy.rowProcessing));
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
      spendNote: PrivateUsdCopy.paymentPending,
    );
    expect(line(), PrivateUsdCopy.paymentProving(42));
    expect(find.text(PrivateUsdCopy.paymentPending), findsOneWidget);

    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100),
      pendingPayment: const PrivateUsdPaymentUpdatingBalance(),
    );
    expect(line(), PrivateUsdCopy.paymentUpdatingBalance);
  });

  testWidgets('the wait for a block counts up from the post', (tester) async {
    var now = DateTime(2026, 10, 17, 12);
    final posted = now.subtract(const Duration(seconds: 65));
    await tester.pumpWidget(
      MaterialApp(
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
    expect(find.text(PrivateUsdCopy.paymentWaitingForBlock('1:05')), findsOne);

    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(PrivateUsdCopy.paymentWaitingForBlock('1:06')), findsOne);
  });

  testWidgets('an empty balance shows the empty state', (tester) async {
    await pumpScreen(tester, previewPrivateUsdBalance());

    expect(find.text(PrivateUsdCopy.emptyTitle), findsOneWidget);
    expect(find.text(PrivateUsdCopy.emptyBody), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowAvailable), findsNothing);
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

    expect(find.text(PrivateUsdCopy.firstLoad), findsOneWidget);
    expect(find.text(PrivateUsdCopy.firstLoadProgress(42)), findsNothing);
    expect(find.text('RAILGUN SYNC 42%'), findsOneWidget);
    expect(find.text(PrivateUsdCopy.unknown), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the last balance and says so', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100, refreshFailed: true),
    );
    expect(find.text(PrivateUsdCopy.refreshFailed), findsOneWidget);

    await pumpScreen(tester, const PrivateUsdBalanceState(refreshFailed: true));
    expect(find.text(PrivateUsdCopy.loadFailed), findsOneWidget);
  });

  testWidgets('refused funds show their row in the danger colour', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 80, blocked: 25),
    );

    final label = tester.widget<Text>(find.text(PrivateUsdCopy.rowBlocked));
    expect(label.style!.color, AppThemeData.dark.colors.text.destructive);
    expect(find.text(PrivateUsdCopy.rowBlockedInfo), findsOneWidget);
  });

  testWidgets('refresh asks again', (tester) async {
    await pumpScreen(tester, previewPrivateUsdBalance(available: 1));

    await tester.tap(find.byKey(const ValueKey('mobile_private_usd_refresh')));
    expect(refreshes, 1);
  });

  testWidgets('the info sheet explains the feature', (tester) async {
    await pumpScreen(tester, previewPrivateUsdBalance(available: 1));

    await tester.tap(find.byKey(const ValueKey('mobile_private_usd_info')));
    await tester.pumpAndSettle();

    expect(find.text(PrivateUsdCopy.infoTitle), findsOneWidget);
    expect(find.text(PrivateUsdCopy.infoReceive), findsOneWidget);
    expect(find.text(PrivateUsdCopy.infoScreening(_hour)), findsOneWidget);
  });
}

final _hour = PrivateUsdCopy.about(const Duration(hours: 1));
