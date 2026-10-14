@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
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
    String? address = previewPrivateUsdAddress,
  }) async {
    refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: MobilePrivateUsdView(
            state: state,
            zecUsdPrice: 50,
            privacyModeEnabled: false,
            receiveAddress: address,
            screening: const Duration(hours: 1),
            onBack: () {},
            onRefresh: () => refreshes++,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a balance shows its buckets, receive address and activity', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      previewPrivateUsdBalance(available: 100, arriving: 20, processing: 5),
    );

    expect(find.text(PrivateUsdCopy.title), findsOneWidget);
    expect(find.text(PrivateUsdCopy.subtitle), findsOneWidget);
    expect(find.text(r'$105.00'), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowAvailable), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowProcessing), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowArriving), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowArrivingInfo(_hour)), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowBlocked), findsNothing);
    expect(find.text(PrivateUsdCopy.receiveAddress), findsOneWidget);
    expect(find.text(previewPrivateUsdAddress), findsOneWidget);
    expect(find.text(PrivateUsdCopy.activityEmpty), findsOneWidget);
    expect(find.text(PrivateUsdCopy.emptyTitle), findsNothing);
    // Convert, Send and Withdraw arrive with M5 and M7.
    expect(find.text(PrivateUsdCopy.actionConvert), findsNothing);
    expect(find.text(PrivateUsdCopy.actionSend), findsNothing);
  });

  testWidgets('an empty balance shows the empty state', (tester) async {
    await pumpScreen(tester, previewPrivateUsdBalance());

    expect(find.text(PrivateUsdCopy.emptyTitle), findsOneWidget);
    expect(find.text(PrivateUsdCopy.emptyBody), findsOneWidget);
    expect(find.text(PrivateUsdCopy.rowAvailable), findsNothing);
  });

  testWidgets('a first load shows its percentage', (tester) async {
    await pumpScreen(
      tester,
      const PrivateUsdBalanceState(isRefreshing: true, firstSyncPercent: 42),
      address: null,
    );

    expect(find.text(PrivateUsdCopy.firstLoadProgress(42)), findsOneWidget);
    expect(find.text(PrivateUsdCopy.unknown), findsOneWidget);
    expect(find.text(PrivateUsdCopy.receiveAddress), findsNothing);
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

  testWidgets('refresh asks again; copy puts the address on the clipboard', (
    tester,
  ) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpScreen(tester, previewPrivateUsdBalance(available: 1));

    await tester.tap(find.byKey(const ValueKey('mobile_private_usd_refresh')));
    expect(refreshes, 1);

    await tester.tap(
      find.byKey(const ValueKey('mobile_private_usd_copy_address')),
    );
    await tester.pump();
    expect(clipboard, [previewPrivateUsdAddress]);
    expect(find.text(PrivateUsdCopy.addressCopied), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
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
