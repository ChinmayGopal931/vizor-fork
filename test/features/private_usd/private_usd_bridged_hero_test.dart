@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/neon_done_sign.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/neon_horizon.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/neon_motion.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_bridged_hero.dart';

// A bridge that finishes in view lights its "Bridged" sign: the done badge
// drawn by a light cycle, a shockwave, and one success haptic as the badge
// lights (owner, 2026-10-19). Opened later, the sign is simply lit.
void main() {
  Future<List<int>> pumpHero(
    WidgetTester tester, {
    required bool celebrate,
    bool disableAnimations = false,
  }) async {
    final impacts = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: disableAnimations),
              child: Scaffold(
                body: PrivateUsdBridgedHero(
                  body: PrivateUsdCopy.reverseProgressReceived('0.8 ZEC'),
                  celebrate: celebrate,
                  onImpact: () => impacts.add(1),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return impacts;
  }

  testWidgets(
    'finishing in view, it switches on and buzzes once as it lights',
    (tester) async {
      final impacts = await pumpHero(tester, celebrate: true);
      expect(find.byType(NeonDoneSign), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1200));
      expect(impacts, isEmpty, reason: 'the light cycle is still drawing');

      await tester.pump(const Duration(milliseconds: 300));
      expect(impacts, hasLength(1));

      // The shockwave runs out and everything stops: nothing loops.
      await tester.pumpAndSettle();
      expect(impacts, hasLength(1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.text(PrivateUsdCopy.bridgedTitle.toUpperCase()), findsOne);
      expect(NeonMotion.bridged, greaterThan(NeonMotion.syncDone));
    },
  );

  testWidgets('opened later, it is simply lit and silent', (tester) async {
    final impacts = await pumpHero(tester, celebrate: false);
    await tester.pump();

    expect(find.byType(NeonDoneSign), findsNothing);
    expect(find.byType(NeonGlyphBadge), findsOneWidget);
    expect(find.text(PrivateUsdCopy.bridgedTitle.toUpperCase()), findsOne);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(impacts, isEmpty);
  });

  testWidgets('under reduced motion it is lit at once and still buzzes', (
    tester,
  ) async {
    final impacts = await pumpHero(
      tester,
      celebrate: true,
      disableAnimations: true,
    );
    await tester.pump();

    expect(impacts, hasLength(1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.text(PrivateUsdCopy.bridgedTitle.toUpperCase()), findsOne);
  });
}
