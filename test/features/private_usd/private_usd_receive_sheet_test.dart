@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_receive_sheet.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// The Receive sheet switches, as ZEC's Receive does its pools, between
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

  Future<List<PrivateUsdReceiveKind>> pumpSheet(
    WidgetTester tester, {
    PrivateUsdReceiveKind kind = PrivateUsdReceiveKind.usdc,
    bool switchable = true,
  }) async {
    final switched = <PrivateUsdReceiveKind>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Scaffold(
            body: PrivateUsdReceiveSheetBody(
              kind: kind,
              onKindChanged: switchable ? switched.add : null,
              symbol: 'USDC',
              chain: 'Ethereum',
              address: previewPrivateUsdEthereumAddress,
              railgunAddress: previewPrivateUsdAddress,
              onClose: () {},
            ),
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
    final switched = await pumpSheet(tester);

    expect(find.text('USDC'), findsOneWidget);
    expect(find.text('0zkUSDC'), findsOneWidget);
    expect(
      find.text(PrivateUsdCopy.depositOnly('USDC', 'Ethereum')),
      findsOneWidget,
    );
    expect(find.text(previewPrivateUsdEthereumAddress), findsOneWidget);
    expect(find.text(previewPrivateUsdAddress), findsNothing);

    await tester.tap(find.byKey(const ValueKey('private_usd_deposit_copy')));
    await tester.pump();
    expect(clipboard, [previewPrivateUsdEthereumAddress]);

    await tester.tap(
      find.byKey(const ValueKey('private_usd_receive_shielded')),
    );
    expect(switched, [PrivateUsdReceiveKind.shielded]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('0zkUSDC shows the 0zk address for a Railgun wallet', (
    tester,
  ) async {
    await pumpSheet(tester, kind: PrivateUsdReceiveKind.shielded);

    expect(find.text(PrivateUsdCopy.receiveShieldedOnly), findsOneWidget);
    expect(find.text(previewPrivateUsdAddress), findsOneWidget);
    expect(find.text(previewPrivateUsdEthereumAddress), findsNothing);
    expect(find.text(PrivateUsdCopy.receiveAddressNote), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mobile_private_usd_copy_address')),
    );
    await tester.pump();
    expect(clipboard, [previewPrivateUsdAddress]);
    expect(find.text(PrivateUsdCopy.addressCopied), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('without deposits there is no switch, only the 0zk address', (
    tester,
  ) async {
    await pumpSheet(
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
