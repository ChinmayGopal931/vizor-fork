@Tags(['mobile'])
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/activity/widgets/activity_feed.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_reverse_presentation.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_status_presentation.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_convert_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_conversion_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_convert_review_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_convert_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_reverse_conversion_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_reverse_convert_view.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_activity_rows.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_banner.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_home_strip.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_logo.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_conversion_provider.dart';
import 'package:zcash_wallet/src/features/swap/domain/swap_asset.dart';
import 'package:zcash_wallet/src/features/swap/widgets/swap_asset_icon.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// Private USD's logo (owner, 2026-10-17): zapp's USDC token with its Railgun
// badge, wherever Private USD shows an image, and ZEC's coin beside it where
// a conversion names both.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(430, 1800);
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

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(data: AppThemeData.dark, child: child),
      ),
    );
    await tester.pump();
  }

  final logo = find.byType(PrivateUsdLogo);
  Finder coin(SwapAsset asset) => find.byWidgetPredicate(
    (widget) => widget is SwapAssetIcon && widget.asset == asset,
  );
  Finder within(String key, Finder finder) =>
      find.descendant(of: find.byKey(ValueKey(key)), matching: finder);

  test('both of its images ship with the app and decode', () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final asset in [
      PrivateUsdLogo.tokenAsset,
      PrivateUsdLogo.badgeAsset,
    ]) {
      expect(manifest.listAssets(), contains(asset));
      final bytes = await rootBundle.load(asset);
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      try {
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 128, reason: asset);
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    }
  });

  testWidgets('the logo is the token with the badge at its bottom right', (
    tester,
  ) async {
    await pump(tester, const Center(child: PrivateUsdLogo(size: 32)));

    final images = tester.widgetList<Image>(
      find.descendant(of: logo, matching: find.byType(Image)),
    );
    expect(
      [for (final image in images) (image.image as AssetImage).assetName],
      [PrivateUsdLogo.tokenAsset, PrivateUsdLogo.badgeAsset],
    );
    final token = tester.getRect(logo);
    final badge = tester.getRect(find.byType(Image).last);
    expect(token.size, const Size.square(32));
    expect(badge.size, const Size.square(14));
    expect(badge.bottomRight, token.bottomRight + const Offset(2, 2));
  });

  testWidgets('the home strip, the banner and the activity rows show it', (
    tester,
  ) async {
    await pump(
      tester,
      Center(
        child: PrivateUsdHomeStripView(
          state: previewPrivateUsdBalance(available: 100),
          zecUsdPrice: 50,
          privacyModeEnabled: false,
          onTap: () {},
        ),
      ),
    );
    expect(within('mobile_home_private_usd_strip', logo), findsOneWidget);

    await pump(
      tester,
      Center(
        child: PrivateUsdConversionBannerView(
          banner: previewPrivateUsdBanner(),
          onTap: () {},
        ),
      ),
    );
    expect(within('private_usd_conversion_banner', logo), findsOneWidget);

    // A banner asking for attention keeps its warning instead.
    final banner = previewPrivateUsdBanner();
    await pump(
      tester,
      Center(
        child: PrivateUsdConversionBannerView(
          banner: PrivateUsdBannerState(
            path: banner.path,
            title: banner.title,
            detail: banner.detail,
            attention: true,
          ),
          onTap: () {},
        ),
      ),
    );
    expect(logo, findsNothing);

    await pump(
      tester,
      Builder(
        builder: (context) => Column(
          children: [
            for (final row in [
              buildPrivateUsdSendActivityRow(
                context: context,
                record: previewPrivateUsdSendRecord(),
              ),
              ?buildPrivateUsdActivityRow(
                context: context,
                record: previewPrivateUsdRecord(),
                zcashConfirmations: 2,
              ),
            ])
              ActivityFeedRowGroup(row: row),
          ],
        ),
      ),
    );
    expect(logo, findsNWidgets(2));
  });

  testWidgets('each convert panel names its asset with its logo, both ways', (
    tester,
  ) async {
    final forward = TextEditingController();
    final reverse = TextEditingController(text: '25');
    addTearDown(forward.dispose);
    addTearDown(reverse.dispose);

    await pump(
      tester,
      MobilePrivateUsdConvertView(
        state: previewPrivateUsdConvertState(quote: previewPrivateUsdQuote()),
        controller: forward,
        autofocus: false,
        onAmountChanged: (_) {},
        onMax: () {},
        onReview: () {},
        onBack: () {},
      ),
    );
    expect(
      within('mobile_private_usd_convert_zec', coin(SwapAsset.zec)),
      findsOneWidget,
    );
    expect(within('mobile_private_usd_convert_estimate', logo), findsOneWidget);

    await pump(
      tester,
      MobilePrivateUsdReverseConvertView(
        state: previewPrivateUsdReverseConvertState(),
        controller: reverse,
        autofocus: false,
        onAmountChanged: (_) {},
        onMax: () {},
        onReview: () {},
        onBack: () {},
      ),
    );
    expect(within('mobile_private_usd_convert_usd', logo), findsOneWidget);
    expect(
      within('mobile_private_usd_convert_estimate', coin(SwapAsset.zec)),
      findsOneWidget,
    );
  });

  testWidgets('the review and progress headers show the logo, not USDC on '
      'Ethereum', (tester) async {
    Future<void> expectHeader(Widget screen) async {
      await pump(tester, screen);
      expect(logo, findsOneWidget);
      expect(coin(SwapAsset.zec), findsOneWidget);
      expect(coin(SwapAsset.usdc), findsNothing);
    }

    await expectHeader(
      MobilePrivateUsdConvertReviewView(
        state: previewPrivateUsdConvertState(
          quote: previewPrivateUsdQuote(),
          step: PrivateUsdConvertStep.review,
        ),
        privacyModeEnabled: false,
        onBack: () {},
        onConfirm: () {},
        onRefreshQuote: () {},
      ),
    );
    await expectHeader(
      MobilePrivateUsdReverseReviewView(
        state: previewPrivateUsdReverseConvertState(
          step: PrivateUsdConvertStep.review,
        ),
        privacyModeEnabled: false,
        onBack: () {},
        onConfirm: () {},
        onRefreshQuote: () {},
      ),
    );
    await expectHeader(
      MobilePrivateUsdConversionView(
        presentation: privateUsdProgressPresentation(
          status: PrivateUsdConversionStatus(
            record: previewPrivateUsdRecord(depositConfirmations: 1),
            wait: ApiForwardWait.confirming,
          ),
          now: previewPrivateUsdNow,
          zcashConfirmations: 2,
          screening: const Duration(hours: 1),
        ),
        onBack: () {},
        onInfo: () {},
        onRetry: () {},
        onCallOff: () {},
        onViewBalance: () {},
        onTryAgain: () {},
      ),
    );
    await expectHeader(
      MobilePrivateUsdReverseConversionView(
        presentation: privateUsdReverseProgressPresentation(
          status: PrivateUsdReverseStatus(
            record: previewPrivateUsdReverseRecord(
              phase: ApiReversePhase.receivingZec,
            ),
          ),
          now: previewPrivateUsdNow,
        ),
        onBack: () {},
        onInfo: () {},
        onRetry: () {},
      ),
    );
  });
}
