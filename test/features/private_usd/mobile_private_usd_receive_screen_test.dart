@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/l10n/app_language.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_receive_screen.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';
import '../../support/test_l10n.dart';

// The Receive screen switches, as ZEC's Receive does its pools, between
// public USDC (the default) and 0zkUSDC from another Railgun wallet.
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

  final clipboard = <String>[];
  setUp(() {
    clipboard.clear();
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<List<PrivateUsdReceiveKind>> pumpScreen(
    WidgetTester tester, {
    PrivateUsdReceiveKind kind = PrivateUsdReceiveKind.usdc,
    bool switchable = true,
    ApiDepositTerms? terms,
    VoidCallback? onBack,
  }) async {
    final switched = <PrivateUsdReceiveKind>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        home: AppTheme(
          data: AppThemeData.dark,
          child: MobilePrivateUsdReceiveView(
            kind: kind,
            onKindChanged: switchable ? switched.add : null,
            symbol: 'USDC',
            chain: 'Ethereum',
            address: previewPrivateUsdEthereumAddress,
            railgunAddress: previewPrivateUsdAddress,
            terms: terms,
            onBack: onBack ?? () {},
          ),
        ),
      ),
    );
    await tester.pump();
    return switched;
  }

  testWidgets('public USDC is the default, with its deposit address', (
    tester,
  ) async {
    final switched = await pumpScreen(tester);

    // The page title is drawn uppercase in the top bar.
    expect(
      find.text(testL10n.privateUsdDepositTitle('USDC').toUpperCase()),
      findsOneWidget,
    );
    expect(find.text('USDC'), findsOneWidget);
    expect(find.text('0zkUSDC'), findsOneWidget);
    expect(
      find.text(testL10n.privateUsdDepositOnly('USDC', 'Ethereum')),
      findsOneWidget,
    );
    expect(find.text(previewPrivateUsdEthereumAddress), findsOneWidget);
    expect(find.text(previewPrivateUsdAddress), findsNothing);
    // Back replaces the sheet's Close.
    expect(find.text(testL10n.commonClose), findsNothing);

    await tester.tap(find.byKey(const ValueKey('private_usd_deposit_copy')));
    await tester.pump();
    expect(clipboard, [previewPrivateUsdEthereumAddress]);

    await tester.tap(
      find.byKey(const ValueKey('private_usd_receive_shielded')),
    );
    expect(switched, [PrivateUsdReceiveKind.shielded]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the terms end with the fees, with no worked example', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      terms: const ApiDepositTerms(
        fee: '250000',
        feeBps: 50,
        minValue: '1000000',
        railgunFeeBps: 25,
      ),
    );

    expect(
      find.byKey(const ValueKey('private_usd_deposit_minimum')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('private_usd_deposit_relayer_fee')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('private_usd_deposit_railgun_fee')),
      findsOneWidget,
    );
    expect(find.textContaining('after both fees'), findsNothing);
    expect(find.textContaining('brings'), findsNothing);
  });

  testWidgets('Back leaves the screen', (tester) async {
    var backs = 0;
    await pumpScreen(tester, onBack: () => backs++);

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets('0zkUSDC shows the 0zk address for a Railgun wallet', (
    tester,
  ) async {
    await pumpScreen(tester, kind: PrivateUsdReceiveKind.shielded);

    expect(find.text(testL10n.privateUsdReceiveShieldedOnly), findsOneWidget);
    expect(find.text(previewPrivateUsdAddress), findsOneWidget);
    expect(find.text(previewPrivateUsdEthereumAddress), findsNothing);
    expect(find.text(testL10n.privateUsdReceiveAddressNote), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mobile_private_usd_copy_address')),
    );
    await tester.pump();
    expect(clipboard, [previewPrivateUsdAddress]);
    expect(find.text(testL10n.commonAddressCopied), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('without deposits there is no switch, only the 0zk address', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      kind: PrivateUsdReceiveKind.shielded,
      switchable: false,
    );

    expect(
      find.byKey(const ValueKey('private_usd_receive_switch')),
      findsNothing,
    );
    expect(find.text(previewPrivateUsdAddress), findsOneWidget);
  });
}
