@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/privacy/privacy_mask.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_home_strip.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';
import 'package:zcash_wallet/widgetbook/screen_use_cases.dart';

// The home strip's states (plan reference §9.4 S1).
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

  Future<void> pumpStrip(
    WidgetTester tester,
    PrivateUsdBalanceState state, {
    bool privacyModeEnabled = false,
    double? zecUsdPrice = 50,
  }) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Center(
            child: PrivateUsdHomeStripView(
              state: state,
              zecUsdPrice: zecUsdPrice,
              privacyModeEnabled: privacyModeEnabled,
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('mobile_home_private_usd_strip')),
    );
    expect(taps, 1);
  }

  Text textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key)));

  String amount(WidgetTester tester) => tester
      .widget<Text>(
        find.byKey(const ValueKey('mobile_home_private_usd_amount')),
      )
      .data!;

  testWidgets('before first use it shows a dash, while loading "Loading…"', (
    tester,
  ) async {
    await pumpStrip(tester, previewPrivateUsdUnknown);
    expect(amount(tester), PrivateUsdCopy.unknown);
    expect(
      find.byKey(const ValueKey('mobile_home_private_usd_detail')),
      findsNothing,
    );

    await pumpStrip(tester, previewPrivateUsdLoading);
    expect(amount(tester), PrivateUsdCopy.loading);
  });

  testWidgets('the headline is spendable with its ZEC worth', (tester) async {
    await pumpStrip(
      tester,
      previewPrivateUsdBalance(available: 100, processing: 25),
    );

    expect(amount(tester), r'$125.00');
    final zec = textOf(tester, 'mobile_home_private_usd_zec_equivalent').data;
    expect(
      zec,
      privateUsdZecEquivalentText(BigInt.from(125000000), zecUsdPrice: 50),
    );
    expect(zec, startsWith('≈ 2.5'));
  });

  testWidgets('arriving dollars show in the positive colour', (tester) async {
    await pumpStrip(
      tester,
      previewPrivateUsdBalance(available: 10, arriving: 5),
    );

    final arriving = textOf(tester, 'mobile_home_private_usd_detail');
    expect(arriving.data, PrivateUsdCopy.homeArriving(r'$5.00'));
    expect(arriving.style!.color, AppThemeData.dark.colors.text.positiveStrong);
  });

  testWidgets('refused funds turn the amount the danger colour', (
    tester,
  ) async {
    await pumpStrip(
      tester,
      previewPrivateUsdBalance(available: 80, blocked: 25),
    );

    final text = tester.widget<Text>(
      find.byKey(const ValueKey('mobile_home_private_usd_amount')),
    );
    expect(text.style!.color, AppThemeData.dark.colors.text.destructive);
    expect(find.bySemanticsLabel(PrivateUsdCopy.homeOpen), findsOneWidget);
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('mobile_home_private_usd_strip')),
    );
    expect(
      semantics.value,
      contains(PrivateUsdCopy.homeBlockedDescription(r'$80.00')),
    );
  });

  testWidgets('hidden balances mask the amounts and drop the ZEC worth', (
    tester,
  ) async {
    await pumpStrip(
      tester,
      previewPrivateUsdBalance(available: 100, arriving: 5),
      privacyModeEnabled: true,
    );

    expect(amount(tester), fixedPrivacyMask());
    expect(find.textContaining('ZEC'), findsNothing);
    expect(find.textContaining(r'$'), findsNothing);
  });

  testWidgets('home shows the strip in the balance card when available', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Builder(builder: buildMobileHomePrivateUsdArrivingUseCase),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile_home_private_usd_strip')),
      findsOneWidget,
    );
    expect(amount(tester), r'$1,250.40');

    await tester.tap(
      find.byKey(const ValueKey('mobile_home_private_usd_strip')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Navigated to /private-usd'), findsOneWidget);
  });

  testWidgets('home has no strip while Private USD is unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Builder(builder: buildMobileHomeDefaultUseCase),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile_home_private_usd_strip')),
      findsNothing,
    );
  });
}
