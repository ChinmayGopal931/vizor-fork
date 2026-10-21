import 'dart:ui' show Size;

import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart' show Text, Widget;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zcash_wallet/src/app_bootstrap.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_icon.dart';
import 'package:zcash_wallet/src/features/onboarding/keystone/keystone_how_to_connect_screen.dart';
import 'package:zcash_wallet/src/features/onboarding/keystone/keystone_onboarding_flow.dart';
import 'package:zcash_wallet/src/core/theme/gotham_fonts.dart';

void main() {
  setUpAll(_loadAppFonts);

  testWidgets('renders the Keystone start content', (tester) async {
    await _setDesktopViewport(tester);
    await tester.pumpWidget(_keystoneScreen());

    expect(find.text('Connect Keystone'), findsOneWidget);
    expect(find.text('Prepare your Keystone wallet'), findsOneWidget);
    expect(find.text('1. Check Keystone firmware'), findsOneWidget);
    expect(find.textContaining('Make sure your Keystone'), findsOneWidget);
    expect(find.text('link'), findsOneWidget);
    expect(find.text('Download firmware'), findsNothing);
    expect(find.text('2. Prepare to connect'), findsOneWidget);
    expect(find.text('On your Keystone'), findsOneWidget);
    expect(find.text('Unlock it.'), findsNothing);
    expect(
      find.text('Tap ••• (top right), then Connect software wallet.'),
      findsOneWidget,
    );
    expect(find.text('Select Vizor (or ZODL)'), findsOneWidget);
    expect(find.text('On Vizor'), findsOneWidget);
    expect(
      find.text('Scan the dynamic QR code on your Keystone.'),
      findsOneWidget,
    );
    expect(find.text("I'm ready now"), findsOneWidget);
  });

  testWidgets('ready CTA resets scan state and opens QR scan step', (
    tester,
  ) async {
    await _setDesktopViewport(tester);
    final router = GoRouter(
      initialLocation: KeystoneOnboardingStep.howToConnect.routePath,
      routes: [
        GoRoute(
          path: KeystoneOnboardingStep.howToConnect.routePath,
          builder: (_, _) => const KeystoneHowToConnectScreen(),
        ),
        GoRoute(
          path: KeystoneOnboardingStep.scanQrCode.routePath,
          builder: (_, _) => const Text('Scan QR route'),
        ),
        GoRoute(path: '/welcome', builder: (_, _) => const Text('Welcome')),
      ],
    );

    await tester.pumpWidget(_routerHarness(router));
    await tester.tap(find.text("I'm ready now"));
    await tester.pumpAndSettle();

    expect(find.text('Scan QR route'), findsOneWidget);
  });

  test('sidebar metadata matches the Keystone navigation labels', () {
    expect(KeystoneOnboardingStep.howToConnect.iconName, AppIcons.book);
    expect(KeystoneOnboardingStep.selectAccount.label, 'Select Account');
    expect(KeystoneOnboardingStep.selectAccount.iconName, AppIcons.user);
    expect(KeystoneOnboardingStep.customiseAccount.label, 'Customise wallet');
    expect(KeystoneOnboardingStep.customiseAccount.iconName, AppIcons.user);
    expect(
      KeystoneOnboardingStep.customiseAccount.routePath,
      '/onboarding/keystone/customise-account',
    );
    expect(
      keystoneOnboardingStepFromLocation(
        '/onboarding/keystone/customise-account',
      ),
      KeystoneOnboardingStep.customiseAccount,
    );
  });
}

Future<void> _loadAppFonts() async {
  await loadGothamFonts();
}

Future<void> _setDesktopViewport(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
  });
}

Widget _keystoneScreen() {
  return ProviderScope(
    overrides: [
      appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
    ],
    child: MaterialApp(
      home: AppTheme(
        data: AppThemeData.light,
        child: const KeystoneHowToConnectScreen(),
      ),
    ),
  );
}

Widget _routerHarness(GoRouter router) {
  return ProviderScope(
    overrides: [
      appBootstrapProvider.overrideWithValue(AppBootstrapState.empty),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      builder: (_, child) => AppTheme(data: AppThemeData.light, child: child!),
    ),
  );
}
