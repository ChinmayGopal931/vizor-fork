@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_shell.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_sheet.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_tab_bar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_top_nav.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_button.dart';
import 'package:zcash_wallet/src/core/widgets/app_icon.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/neon_scramble_text.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/tron_glyph.dart';
import 'package:zcash_wallet/src/core/theme/gotham_fonts.dart';

void main() {
  setUpAll(() async {
    await loadGothamFonts();
  });

  testWidgets('Checking label fits the mobile top nav at 320 pixels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _harness(
        MobileTopNav.account(
          accountName: 'Account1',
          syncLabel: '99% checking',
          syncAnimated: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('99% checking'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'MobileTopNav.account is a portrait that reveals its name on tap',
    (tester) async {
      var switcherOpens = 0;
      await tester.pumpWidget(
        _harness(
          MobileTopNav.account(
            accountName: 'Account1',
            balanceLabel: '140.12 ZEC',
            syncLabel: 'Veylor is synced',
            onAccountTap: () => switcherOpens++,
          ),
        ),
      );
      const account = ValueKey('mobile_top_nav_account');
      const name = ValueKey('mobile_top_nav_account_name');

      // Only the portrait shows; screen readers still get the name.
      expect(find.byKey(name), findsNothing);
      expect(find.text('140.12 ZEC'), findsNothing);
      expect(find.bySemanticsLabel('Account1'), findsOneWidget);
      expect(find.text('Veylor is synced'), findsOneWidget);
      final sync = tester.widget<Text>(find.text('Veylor is synced'));
      expect(sync.style?.color, AppThemeData.dark.colors.sync.text);

      // A tap decrypts the name in beside the portrait, the balance under it.
      await tester.tap(find.byKey(account));
      await tester.pumpAndSettle();
      final revealed = tester.widget<NeonScrambleText>(find.byKey(name));
      expect(revealed.text, 'Account1');
      expect(revealed.style.color, AppThemeData.dark.colors.text.accent);
      expect(find.text('140.12 ZEC'), findsOneWidget);
      expect(switcherOpens, 0);

      // A second tap opens the switcher and folds the name away.
      await tester.tap(find.byKey(account));
      await tester.pumpAndSettle();
      expect(switcherOpens, 1);
      expect(find.byKey(name), findsNothing);

      // A long press opens it straight away.
      await tester.longPress(find.byKey(account));
      await tester.pumpAndSettle();
      expect(switcherOpens, 2);
      expect(find.byKey(name), findsNothing);
    },
  );

  testWidgets('MobileTopNav.account syncing shimmers the label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        MobileTopNav.account(
          accountName: 'Account1',
          syncLabel: '20% Syncing...',
          syncLabelColor: AppThemeData.dark.colors.sync.textSyncing,
          syncIndicatorColor: AppThemeData.dark.colors.text.muted,
          syncHighlightColor: AppThemeData.dark.colors.sync.lightSuccess,
          syncAnimated: true,
        ),
      ),
    );
    // Let the looping controller advance a few frames (never pumpAndSettle:
    // the animation repeats forever and would time out).
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(find.text('20% Syncing...'), findsOneWidget);
    // The label is wrapped in a shimmer ShaderMask over a solid-color Text.
    expect(find.byType(ShaderMask), findsOneWidget);
    final label = tester.widget<Text>(find.text('20% Syncing...'));
    expect(label.style?.color, const Color(0xFFFFFFFF));

    // Unmount so the active ticker is disposed cleanly.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('MobileTopNav.account syncing is static under reduce-motion', (
    tester,
  ) async {
    final mutedGreen = AppThemeData.dark.colors.sync.textSyncing;
    final greyBar = AppThemeData.dark.colors.text.muted;
    await tester.pumpWidget(
      _harness(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: MobileTopNav.account(
              accountName: 'Account1',
              syncLabel: '20% Syncing...',
              syncLabelColor: mutedGreen,
              syncIndicatorColor: greyBar,
              syncHighlightColor: AppThemeData.dark.colors.sync.lightSuccess,
              syncAnimated: true,
            ),
          ),
        ),
      ),
    );

    // No shimmer mask; the label keeps its muted green base and the edge bar
    // is a neutral grey. The brighter shimmer peak only appears in the
    // animated state.
    expect(find.byType(ShaderMask), findsNothing);
    final label = tester.widget<Text>(find.text('20% Syncing...'));
    expect(label.style?.color, mutedGreen);

    final greyBars = tester
        .widgetList<Container>(find.byType(Container))
        .where(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).color == greyBar,
        );
    expect(greyBars, isNotEmpty);
  });

  testWidgets('MobileTopNav.back shows a spaced uppercase Thin title and fires '
      'onBack', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      _harness(MobileTopNav.back(title: 'Activity', onBack: () => backs++)),
    );

    // The title is passed in sentence case and drawn as an uppercase caption.
    expect(find.text('Activity'), findsNothing);
    final title = tester.widget<Text>(find.text('ACTIVITY'));
    expect(title.style?.fontFamily, AppTypography.headlineLarge.fontFamily);
    expect(title.style?.fontWeight, AppTypography.headlineLarge.fontWeight);
    expect(title.style?.letterSpacing, greaterThan(0));

    await tester.tap(find.bySemanticsLabel('Back'));
    expect(backs, 1);
  });

  testWidgets('MobileTopNav.back accepts a title style override', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const MobileTopNav.back(
          // Neutral sample text: a distinct style from the headlineLarge
          // default, purely to prove the override is applied. (Real screens
          // like the swap status header use the headlineLarge default.)
          title: 'Custom title',
          titleStyle: AppTypography.headlineMedium,
        ),
      ),
    );

    final title = tester.widget<Text>(find.text('Custom title'));
    expect(title.style?.fontFamily, AppTypography.headlineMedium.fontFamily);
    expect(title.style?.fontSize, AppTypography.headlineMedium.fontSize);
  });

  testWidgets('MobileTopNav.steps clamps and renders progress', (tester) async {
    await tester.pumpWidget(_harness(const MobileTopNav.steps(progress: 0.5)));

    final fill = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(fill.widthFactor, 0.5);
  });

  testWidgets('AppMobileTabBar slides the light pool and lights the active '
      'glyph', (tester) async {
    final taps = <int>[];
    const items = [
      AppMobileTabItem(iconName: 'home', label: 'Home'),
      AppMobileTabItem(iconName: 'history', label: 'Activity'),
      AppMobileTabItem(iconName: 'cog', label: 'Settings'),
    ];
    Widget bar(int index) => _harness(
      SizedBox(
        width: 361,
        child: AppMobileTabBar(
          items: items,
          currentIndex: index,
          onSelect: taps.add,
        ),
      ),
    );
    Alignment poolAlignment() =>
        tester
                .widget<AnimatedAlign>(
                  find.byKey(AppMobileTabBar.activePillKey),
                )
                .alignment
            as Alignment;
    List<TronGlyph> glyphs() =>
        tester.widgetList<TronGlyph>(find.byType(TronGlyph)).toList();
    final colors = AppThemeData.dark.colors;

    await tester.pumpWidget(bar(0));

    // The app's tabs are drawn as Tron glyphs, never the icon set.
    expect(glyphs().map((glyph) => glyph.kind), [
      TronGlyphKind.home,
      TronGlyphKind.activity,
      TronGlyphKind.settings,
    ]);
    expect(find.byType(AppIcon), findsNothing);

    // One shared pool of the active glyph's light, parked on item 0.
    expect(poolAlignment(), const Alignment(-1, 0));
    final poolBox = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(AppMobileTabBar.activePillKey),
        matching: find.byType(DecoratedBox),
      ),
    );
    final pool = (poolBox.decoration as BoxDecoration).gradient!;
    expect(pool, isA<RadialGradient>());
    expect(
      pool.colors.first.withValues(alpha: 1),
      colors.navPanel.activeIcon.withValues(alpha: 1),
    );
    expect(pool.colors.first.a, greaterThan(0));
    expect(pool.colors.last.a, 0);
    expect(glyphs()[0].color, colors.navPanel.activeIcon);
    expect(glyphs()[0].lit, 1);
    expect(glyphs()[1].color, colors.icon.muted);
    expect(glyphs()[1].lit, 0);

    await tester.tap(find.bySemanticsLabel('Activity'));
    await tester.pumpAndSettle();
    expect(taps, [1]);

    // Selection is owned by the caller — rebuilding with the new index
    // slides the pool there and moves the light to its glyph.
    await tester.pumpWidget(bar(1));
    await tester.pumpAndSettle();
    expect(poolAlignment().x, closeTo(-1 + 2 * 1 / 2, 1e-9));
    expect(glyphs()[0].color, colors.icon.muted);
    expect(glyphs()[0].lit, 0);
    expect(glyphs()[1].color, colors.navPanel.activeIcon);
    expect(glyphs()[1].lit, 1);
  });

  testWidgets('AppMobileShell extends body behind the floating tab bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        AppMobileShell(
          body: const SizedBox.expand(),
          tabBar: AppMobileTabBar(
            items: const [
              AppMobileTabItem(iconName: 'home', label: 'Home'),
              AppMobileTabItem(iconName: 'cog', label: 'Settings'),
            ],
            currentIndex: 0,
            onSelect: (_) {},
          ),
        ),
      ),
    );

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.extendBody, isTrue);
    expect(find.byType(AppMobileTabBar), findsOneWidget);
  });

  testWidgets('showAppMobileSheet presents and dismisses content', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        Builder(
          builder: (context) => GestureDetector(
            onTap: () => showAppMobileSheet<void>(
              context: context,
              builder: (_) => const SizedBox(
                height: 200,
                child: Center(child: Text('Sheet content')),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet content'), findsOneWidget);

    // Dismiss by tapping the barrier above the sheet.
    await tester.tapAt(const Offset(200, 50));
    await tester.pumpAndSettle();
    expect(find.text('Sheet content'), findsNothing);
  });

  testWidgets('MobileModalScaffold preserves tall leading affordances', (
    tester,
  ) async {
    const leadingKey = ValueKey('modal_leading_affordance');
    await tester.pumpWidget(
      _harness(
        SizedBox(
          width: 361,
          child: MobileModalScaffold(
            title: 'Verify address',
            onClose: () {},
            leading: const SizedBox(key: leadingKey, width: 32, height: 32),
            child: const SizedBox(height: 24),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(leadingKey)), const Size(32, 32));
  });

  testWidgets('MobileModalCard uses the Figma modal base in both themes', (
    tester,
  ) async {
    Future<void> pumpCard(AppThemeData theme) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, navigator) =>
              AppTheme(data: theme, child: navigator!),
          home: const Center(
            child: SizedBox(
              width: 393,
              height: 852,
              child: MobileModalCard(
                child: SizedBox(height: 200, child: Text('Modal content')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    for (final theme in [AppThemeData.dark, AppThemeData.light]) {
      await pumpCard(theme);

      final cardFinder = find.byType(MobileModalCard);
      final decoratedBox = tester.widget<DecoratedBox>(
        find.descendant(of: cardFinder, matching: find.byType(DecoratedBox)),
      );
      final decoration = decoratedBox.decoration as BoxDecoration;
      expect(
        decoration.borderRadius,
        const BorderRadius.all(Radius.circular(AppRadii.xLarge)),
      );
      expect(decoration.boxShadow, const [
        BoxShadow(
          color: Color(0x14000000),
          offset: Offset(0, 14),
          blurRadius: 28,
        ),
        BoxShadow(
          color: Color(0x08000000),
          offset: Offset(0, -6),
          blurRadius: 12,
        ),
        BoxShadow(
          color: Color(0x0F000000),
          offset: Offset(0, 2),
          blurRadius: 8,
        ),
      ]);

      final material = tester.widget<Material>(
        find.descendant(of: cardFinder, matching: find.byType(Material)),
      );
      expect(material.color, theme.colors.background.base);
      expect(
        material.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadii.xLarge)),
        ),
      );

      final rim = tester.widget<CustomPaint>(
        find
            .descendant(of: cardFinder, matching: find.byType(CustomPaint))
            .first,
      );
      expect(rim.foregroundPainter, isNotNull);
    }
  });

  testWidgets('MobileModalCard floats Back as a cut-corner glass chevron', (
    tester,
  ) async {
    var backs = 0;
    await tester.pumpWidget(
      _harness(
        SizedBox(
          width: 393,
          height: 852,
          child: MobileModalCard(
            onBack: () => backs++,
            child: const SizedBox(height: 200),
          ),
        ),
      ),
    );

    final back = find.byKey(const ValueKey('mobile_modal_back_button'));
    final button = tester.widget<AppButton>(back);
    expect(button.variant, AppButtonVariant.secondary);
    // Glass, not the card's opaque surface.
    expect(button.enabledBackgroundColor, isNull);
    final plate =
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: back,
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration
            as ShapeDecoration;
    expect(plate.shape, isA<BeveledRectangleBorder>());
    expect(plate.color, AppThemeData.dark.colors.button.secondary.bg);
    expect(
      tester
          .widget<AppIcon>(
            find.descendant(of: back, matching: find.byType(AppIcon)),
          )
          .name,
      AppIcons.chevronBackward,
    );
    expect(tester.getSize(back), const Size(44, 44));
    await tester.tap(back);
    expect(backs, 1);
  });
}

Widget _harness(Widget child) {
  return MaterialApp(
    // AppTheme wraps the navigator (like the real app's AppThemeHost in
    // MaterialApp.builder) so root-navigator overlays — modal sheets shown
    // with useRootNavigator — can resolve it too.
    builder: (context, navigator) =>
        AppTheme(data: AppThemeData.dark, child: navigator!),
    home: Center(child: child),
  );
}
