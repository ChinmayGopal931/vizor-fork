@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_sidebar_surface.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_wallet_sidebar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/neon_sidebar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/neon_sync_backdrop.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_surface_card.dart';
import 'package:zcash_wallet/src/services/native_modal_corners.dart';

void main() {
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeModalCorners.channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeModalCorners.channel, null),
  );

  Future<void> pump(
    WidgetTester tester, {
    required Widget panel,
    AppThemeData theme = AppThemeData.dark,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(982, 654);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppTheme(data: theme, child: child!),
        home: Stack(
          children: [
            Positioned(
              left: 16,
              top: 40,
              width: 256,
              height: 540,
              child: panel,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final theme in [AppThemeData.dark, AppThemeData.light]) {
    testWidgets(
      'panel is neon glass cut at two lit corners, its content clipped to '
      'the same outline (${theme == AppThemeData.dark ? 'dark' : 'light'})',
      (tester) async {
        addTearDown(tester.view.reset);
        await pump(
          tester,
          theme: theme,
          panel: const MobileSidebarSurface(child: SizedBox.expand()),
        );
        final colors = theme.colors;
        final painter =
            tester
                    .widget<CustomPaint>(
                      find
                          .descendant(
                            of: find.byType(MobileSidebarSurface),
                            matching: find.byType(CustomPaint),
                          )
                          .first,
                    )
                    .painter!
                as NeonGlassPanelPainter;
        expect(painter.fill, colors.background.window.withValues(alpha: 0.62));
        expect(painter.glow, colors.neon.glow);
        expect(painter.core, colors.neon.core);
        expect(painter.cut, MobileSidebarSurface.cut);
        final clip = tester.widget<ClipPath>(
          find.descendant(
            of: find.byType(MobileSidebarSurface),
            matching: find.byType(ClipPath),
          ),
        );
        expect(
          (clip.clipper! as ShapeBorderClipper).shape,
          Neon.wedgeBorder(cut: MobileSidebarSurface.cut),
        );
        // Cut corners follow no display geometry, so UIKit is never asked.
        expect(calls, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    'sync readout keeps clear of the panel foot, its cut corner and the '
    'safe area',
    (tester) async {
      addTearDown(tester.view.reset);
      Widget sidebar({double bottomInset = 18}) => MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(bottom: bottomInset)),
        child: MobileWalletSidebar(
          accountName: 'Test account',
          avatar: const SizedBox(width: 40, height: 40),
          sync: const NeonSyncLine(
            progress: 1,
            readout: NeonSyncReadout.synced,
            semanticsLabel: 'Veylor is synced',
          ),
          currentPath: '/home',
          swapEnabled: true,
          onSelect: (_) {},
          onAccountTap: () {},
        ),
      );
      void verify(double gap) {
        final panel = tester.getRect(find.byType(MobileSidebarSurface));
        final sync = tester.getRect(find.byType(NeonSidebarSyncReadout));
        expect(panel.bottom - sync.bottom, gap);
        expect(panel.right - sync.right, AppSpacing.sm);
        expect(find.text('SYNCED'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      await pump(tester, panel: sidebar(bottomInset: 0));
      verify(AppSpacing.sm);
      // Safety replaces the gap when larger; it is never added to it.
      await pump(tester, panel: sidebar());
      verify(18);
      await pump(tester, panel: sidebar(bottomInset: 80));
      verify(80);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
