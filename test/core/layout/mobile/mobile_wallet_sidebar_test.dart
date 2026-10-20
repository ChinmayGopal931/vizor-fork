@Tags(['mobile'])
library;

import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_shell.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_tab_bar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_navigation_scope.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_wallet_sidebar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/neon_sidebar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/neon_sync_backdrop.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_icon.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_sidebar_surface.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/tron_glyph.dart';

final status = NeonSyncLine(
  progress: 0.04,
  readout: NeonSyncReadout.progress(4),
  semanticsLabel: 'Syncing 4 percent',
  climbing: true,
);
const failed = NeonSyncLine(
  progress: 0.04,
  readout: NeonSyncReadout.failed,
  semanticsLabel: 'Syncing failed. Network error',
  failed: true,
);
const synced = NeonSyncLine(
  progress: 1,
  readout: NeonSyncReadout.synced,
  semanticsLabel: 'Veylor is synced',
);
Widget harness(Widget child, {double scale = 1, AppThemeData? theme}) =>
    MaterialApp(
      // Like MaterialApp.router.builder in production: the sidebar is a sibling
      // of the router, outside its Scaffold/Material default text styles.
      builder: (context, navigator) => AppTheme(
        data: theme ?? AppThemeData.light,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: Stack(
            children: [
              navigator!,
              Center(child: child),
            ],
          ),
        ),
      ),
      home: const Scaffold(),
    );

void main() {
  for (final dark in [false, true]) {
    for (final enabled in [false, true]) {
      for (final line in [status, synced, failed]) {
        testWidgets('sidebar resets inherited text decoration '
            '(dark=$dark, enabled=$enabled, sync=${line.readout})', (
          tester,
        ) async {
          final theme = dark ? AppThemeData.dark : AppThemeData.light;
          final label = line.readout.toUpperCase();
          await tester.pumpWidget(
            harness(
              SizedBox(
                width: 200,
                height: 600,
                child: MobileWalletSidebar(
                  accountName: 'Account probe',
                  avatar: const SizedBox(width: 40, height: 40),
                  sync: line,
                  currentPath: '/home',
                  swapEnabled: true,
                  onSelect: enabled ? (_) {} : null,
                  onAccountTap: enabled ? () {} : null,
                ),
              ),
              theme: theme,
            ),
          );
          TextStyle effectiveStyle(String label) =>
              (tester
                          .widget<RichText>(
                            find.descendant(
                              of: find.text(label),
                              matching: find.byType(RichText),
                            ),
                          )
                          .text
                      as TextSpan)
                  .style!;
          for (final text in [
            'Account probe',
            'Home',
            'Activity',
            'Settings',
            label,
          ]) {
            final style = effectiveStyle(text);
            expect(style.decoration, TextDecoration.none, reason: text);
            // The readout is a HUD caption; the rest is the Light body.
            final typography = text == label
                ? kNeonHudCaptionStyle
                : AppTypography.bodyMediumStrong;
            expect(style.fontFamily, typography.fontFamily, reason: text);
            expect(style.fontSize, typography.fontSize, reason: text);
            expect(style.fontWeight, typography.fontWeight, reason: text);
            expect(style.letterSpacing, typography.letterSpacing, reason: text);
          }
          // Red light whatever the state, as Home's readout is.
          expect(effectiveStyle(label).color, theme.colors.neon.glow);
          if (enabled) {
            expect(
              effectiveStyle('Home').color,
              theme.colors.navPanel.activeIcon,
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final theme in [AppThemeData.light, AppThemeData.dark]) {
    testWidgets(
      'full lock veils the panel and preserves sync and disabled input (${theme == AppThemeData.dark ? 'dark' : 'light'})',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final visits = <String>[];
          var accounts = 0;
          Widget subject({
            bool navigation = true,
            bool account = true,
            bool pending = false,
            NeonSyncLine? sync,
          }) => harness(
            SizedBox(
              width: 256,
              height: 600,
              child: MobileWalletSidebar(
                accountName: 'Account probe',
                avatar: const SizedBox.square(dimension: 40),
                sync: sync ?? status,
                currentPath: '/home',
                swapEnabled: true,
                onSelect: navigation ? visits.add : null,
                onAccountTap: account ? () => accounts++ : null,
                inputBlocked: pending,
              ),
            ),
            theme: theme,
          );
          List<Color?> fills() => tester
              .widgetList<AnimatedContainer>(
                find.descendant(
                  of: find.byType(MobileWalletSidebar),
                  matching: find.byType(AnimatedContainer),
                ),
              )
              .map((w) => (w.decoration as ShapeDecoration).color)
              .toList();
          await tester.pumpWidget(subject());
          final restingFills = fills();
          final syncState = tester.state(find.byType(NeonSidebarSyncReadout));
          final syncRect = tester.getRect(find.byType(NeonSidebarSyncReadout));
          final focus = Focus.of(tester.element(find.text('Settings')));
          focus.requestFocus();
          await tester.pump();
          await tester.pumpWidget(subject(navigation: false, account: false));
          expect(fills(), restingFills); // No individual disabled pills.
          expect(focus.hasFocus, isFalse);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.tap(find.text('Settings'));
          await tester.tap(find.text('Account probe'));
          expect(visits, isEmpty);
          expect(accounts, 0);
          for (final label in [
            'Account probe',
            'Home',
            'Activity',
            'Settings',
          ]) {
            expect(
              tester
                  .getSemantics(find.text(label))
                  .getSemanticsData()
                  .hasAction(SemanticsAction.tap),
              isFalse,
            );
          }
          expect(
            tester.state(find.byType(NeonSidebarSyncReadout)),
            same(syncState),
          );
          expect(tester.getRect(find.byType(NeonSidebarSyncReadout)), syncRect);
          expect(
            tester
                .widget<NeonSidebarSyncReadout>(
                  find.byType(NeonSidebarSyncReadout),
                )
                .line,
            same(status),
          );
          final panel = tester.getRect(find.byType(MobileSidebarSurface));
          final top = tester.getRect(
            find.byKey(const ValueKey('mobile_sidebar_controls_veil')),
          );
          final bottom = tester.getRect(
            find.byKey(const ValueKey('mobile_sidebar_footer_veil')),
          );
          expect(top.topLeft, panel.topLeft);
          expect(top.width, panel.width);
          expect(bottom.width, panel.width);
          expect(top.bottom, bottom.top);
          expect(bottom.bottomRight, panel.bottomRight);
          final footerStack = tester.widget<Stack>(
            find
                .ancestor(
                  of: find.byKey(
                    const ValueKey('mobile_sidebar_sync_foreground'),
                  ),
                  matching: find.byType(Stack),
                )
                .first,
          );
          expect(
            footerStack.children.last.key,
            const ValueKey('mobile_sidebar_sync_foreground'),
          );
          expect(
            footerStack.clipBehavior,
            Clip.none,
          ); // Preserve the upper glow.
          await tester.pumpWidget(
            subject(navigation: false, account: false, sync: failed),
          );
          expect(find.text('SYNC FAILED'), findsOneWidget);
          expect(
            tester
                .getSemantics(find.bySemanticsLabel(failed.semanticsLabel))
                .flagsCollection
                .isLiveRegion,
            isTrue,
          );
          expect(
            tester.state(find.byType(NeonSidebarSyncReadout)),
            same(syncState),
          );
          await tester.pumpWidget(subject(account: false));
          expect(
            find.byKey(const ValueKey('mobile_sidebar_controls_veil')),
            findsNothing,
          );
          expect(fills().first, theme.colors.button.disabled.bg);
          await tester.tap(find.text('Settings'));
          expect(visits, ['/settings']);
          await tester.pumpWidget(subject(pending: true));
          expect(
            find.byKey(const ValueKey('mobile_sidebar_controls_veil')),
            findsNothing,
          );
          await tester.pumpWidget(subject());
          await tester.tap(find.text('Account probe'));
          expect(accounts, 1);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'locked short sidebar still scrolls to the readable sync footer',
    (tester) async {
      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 200,
            height: 260,
            child: MobileWalletSidebar(
              accountName: 'Account probe',
              avatar: const SizedBox.square(dimension: 40),
              sync: status,
              currentPath: '/home',
              swapEnabled: true,
              onSelect: null,
              onAccountTap: null,
            ),
          ),
          scale: 2,
        ),
      );
      await tester.ensureVisible(find.text('SYNC 4%'));
      await tester.pump();
      final sync = tester.getRect(find.byType(NeonSidebarSyncReadout));
      final panel = tester.getRect(find.byType(MobileSidebarSurface));
      expect(sync.bottom, lessThanOrEqualTo(panel.bottom));
      expect(sync.top, greaterThanOrEqualTo(panel.top));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'temporary lock keeps paint and labels while blocking all input',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final visits = <String>[];
        var accounts = 0;
        Widget sidebar({required bool blocked}) => SizedBox(
          width: 256,
          height: 600,
          child: MobileWalletSidebar(
            accountName: 'Account probe',
            avatar: const SizedBox(width: 40, height: 40),
            sync: status,
            currentPath: '/home',
            swapEnabled: true,
            inputBlocked: blocked,
            onSelect: visits.add,
            onAccountTap: () => accounts++,
          ),
        );
        Color? textColor(String text) =>
            (tester
                        .widget<RichText>(
                          find.descendant(
                            of: find.text(text),
                            matching: find.byType(RichText),
                          ),
                        )
                        .text
                    as TextSpan)
                .style!
                .color;
        await tester.pumpWidget(harness(sidebar(blocked: false)));
        final labels = ['Account probe', 'Home', 'Activity', 'Settings'];
        final colors = [for (final label in labels) textColor(label)];
        final settingsNode = Focus.of(tester.element(find.text('Settings')));
        settingsNode.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(visits, ['/settings']);
        expect(
          tester
              .getSemantics(find.text('Settings'))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );

        await tester.pumpWidget(harness(sidebar(blocked: true)));
        expect(settingsNode.hasFocus, isFalse);
        settingsNode.requestFocus();
        await tester.pump();
        expect(settingsNode.hasFocus, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.tap(find.text('Settings'), warnIfMissed: false);
        await tester.tap(find.text('Account probe'), warnIfMissed: false);
        expect(visits, ['/settings']);
        expect(accounts, 0);
        for (var i = 0; i < labels.length; i++) {
          expect(textColor(labels[i]), colors[i]);
          expect(find.text(labels[i]), findsOneWidget);
          expect(
            tester
                .getSemantics(find.text(labels[i]))
                .getSemanticsData()
                .hasAction(SemanticsAction.tap),
            isFalse,
          );
        }

        await tester.pumpWidget(harness(sidebar(blocked: false)));
        await tester.tap(find.text('Settings'));
        await tester.tap(find.text('Account probe'));
        expect(visits, ['/settings', '/settings']);
        expect(accounts, 1);
        expect(
          tester
              .getSemantics(find.text('Settings'))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'sidebar shows mobile destinations and sync, respects flag and disabled state',
    (tester) async {
      final visits = <String>[];
      Widget sidebar({bool enabled = true}) => SizedBox(
        width: 200,
        height: 600,
        child: MobileWalletSidebar(
          accountName: 'Windborne Trailguard',
          avatar: const SizedBox(width: 40, height: 40),
          sync: status,
          currentPath: '/activity',
          swapEnabled: false,
          onAccountTap: enabled ? () {} : null,
          onSelect: enabled ? visits.add : null,
        ),
      );
      await tester.pumpWidget(harness(sidebar()));
      expect(find.text('Swap'), findsNothing);
      expect(find.text('SYNC 4%'), findsOneWidget);
      await tester.tap(find.text('Settings'));
      expect(visits, ['/settings']);
      await tester.pumpWidget(harness(sidebar(enabled: false)));
      await tester.tap(find.text('Home'));
      expect(visits, ['/settings']);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Home stays lit on the pages it opens', (tester) async {
    for (final (path, lit) in [
      ('/home', true),
      ('/swap', true),
      ('/swap/review', true),
      ('/private-usd', true),
      ('/private-usd/convert', true),
      ('/portfolio-chart', true),
      ('/activity', false),
    ]) {
      await tester.pumpWidget(
        harness(
          SizedBox(
            key: ValueKey(path),
            width: 200,
            height: 600,
            child: MobileWalletSidebar(
              accountName: 'Account probe',
              avatar: const SizedBox.square(dimension: 40),
              sync: status,
              currentPath: path,
              swapEnabled: true,
              onSelect: (_) {},
              onAccountTap: () {},
            ),
          ),
        ),
      );
      final home =
          (tester
                      .widget<RichText>(
                        find.descendant(
                          of: find.text('Home'),
                          matching: find.byType(RichText),
                        ),
                      )
                      .text
                  as TextSpan)
              .style!
              .color;
      expect(
        home == AppThemeData.light.colors.navPanel.activeIcon,
        lit,
        reason: path,
      );
    }
    expect(find.text('Swap'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'short sidebar scrolls all controls at large accessibility text size',
    (tester) async {
      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 200,
            height: 260,
            child: MobileWalletSidebar(
              accountName: 'A long account name that should wrap',
              avatar: const SizedBox(width: 40, height: 40),
              sync: status,
              currentPath: '/home',
              swapEnabled: true,
              onAccountTap: () {},
              onSelect: (_) {},
            ),
          ),
          scale: 2,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('SYNC 4%'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'side tabs retain upright icons and every destination scrolls into view',
    (tester) async {
      final selected = <int>[];
      var bodyTaps = 0;
      await tester.pumpWidget(
        harness(
          SizedBox(
            width: 492,
            height: 720,
            child: MobileNavigationScope(
              mode: MobileNavigationMode.systemSideTabs,
              navigation: MobileBranchNavigation(),
              railRect: const Rect.fromLTWH(416, 200, 64, 100),
              child: AppMobileShell(
                body: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => bodyTaps++,
                  child: const SizedBox.expand(),
                ),
                tabBar: AppMobileTabBar(
                  axis: Axis.vertical,
                  items: const [
                    AppMobileTabItem(iconName: AppIcons.home, label: 'Home'),
                    AppMobileTabItem(iconName: AppIcons.cog, label: 'Settings'),
                  ],
                  currentIndex: 0,
                  onSelect: selected.add,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // Content fades into the window colour toward the rail's screen edge,
      // without taking touches from it.
      final shell = tester.getRect(find.byType(AppMobileShell));
      final fade = find.descendant(
        of: find.byType(AppMobileShell),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient is LinearGradient,
        ),
      );
      final gradient =
          (tester.widget<DecoratedBox>(fade).decoration as BoxDecoration)
                  .gradient!
              as LinearGradient;
      expect(gradient.begin, Alignment.centerLeft);
      expect(gradient.end, Alignment.centerRight);
      expect(gradient.colors.first.a, 0);
      expect(gradient.colors.last, AppThemeData.light.colors.background.window);
      // Only beside the rail: toward its screen edge and the bottom.
      expect(
        tester.getRect(fade),
        Rect.fromLTRB(
          shell.left + 416 - AppSpacing.md,
          shell.top + 200 - AppSpacing.md,
          shell.right,
          shell.bottom,
        ),
      );
      final mask = tester.widget<ShaderMask>(
        find.ancestor(of: fade, matching: find.byType(ShaderMask)),
      );
      expect(mask.blendMode, BlendMode.dstIn);
      await tester.tapAt(tester.getRect(fade).topLeft + const Offset(10, 40));
      expect(bodyTaps, 1);
      expect(selected, isEmpty);
      await tester.ensureVisible(find.bySemanticsLabel('Settings'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Settings'));
      expect(selected, [1]);
      expect(tester.takeException(), isNull);
    },
  );

  Widget neonSidebar(String path) => harness(
    SizedBox(
      width: 256,
      height: 600,
      child: MobileWalletSidebar(
        accountName: 'Account probe',
        avatar: const SizedBox.square(dimension: 40),
        sync: status,
        currentPath: path,
        swapEnabled: true,
        onSelect: (_) {},
        onAccountTap: () {},
      ),
    ),
    theme: AppThemeData.dark,
  );

  testWidgets(
    'destinations are Tron glyphs, the active one lit in a pool of its light',
    (tester) async {
      final colors = AppThemeData.dark.colors;
      List<TronGlyph> glyphs() => tester
          .widgetList<TronGlyph>(
            find.descendant(
              of: find.byType(MobileWalletSidebar),
              matching: find.byType(TronGlyph),
            ),
          )
          .toList();
      double pool(int index) =>
          ((tester
                              .widget<DecoratedBox>(
                                find.descendant(
                                  of: find.byType(NeonSidebarGlyph).at(index),
                                  matching: find.byType(DecoratedBox),
                                ),
                              )
                              .decoration
                          as BoxDecoration)
                      .gradient!
                  as RadialGradient)
              .colors
              .first
              .a;

      await tester.pumpWidget(neonSidebar('/activity'));
      expect(glyphs().map((glyph) => glyph.kind), [
        TronGlyphKind.home,
        TronGlyphKind.activity,
        TronGlyphKind.settings,
      ]);
      expect(
        find.descendant(
          of: find.byType(MobileWalletSidebar),
          matching: find.byType(AppIcon),
        ),
        findsNothing,
      );
      expect([for (final glyph in glyphs()) glyph.lit], [0, 1, 0]);
      expect(glyphs()[1].color, colors.navPanel.activeIcon);
      expect(glyphs()[1].core, colors.neon.core);
      expect(glyphs()[0].color, colors.icon.muted);
      expect(pool(1), greaterThan(0));
      expect(pool(0), 0);
      expect(pool(2), 0);

      // A page no destination owns leaves every glyph dark.
      await tester.pumpWidget(neonSidebar('/about'));
      expect([for (final glyph in glyphs()) glyph.lit], [0, 0, 0]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the sync readout stands in the glyph column, its caption with the labels',
    (tester) async {
      await tester.pumpWidget(neonSidebar('/home'));
      final glyph = tester.getRect(find.byType(NeonSidebarGlyph).first);
      final line = tester.getRect(
        find
            .descendant(
              of: find.byType(NeonSidebarSyncReadout),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
      expect(line.center.dx, glyph.center.dx);
      expect(
        tester.getRect(find.text('SYNC 4%')).left,
        tester.getRect(find.text('Home')).left,
      );
      expect(find.bySemanticsLabel(status.semanticsLabel), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the sync readout breathes only while its line climbs', (
    tester,
  ) async {
    Future<void> pump(NeonSyncLine line, {bool reduced = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppTheme(
            data: AppThemeData.dark,
            child: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduced),
                child: Center(
                  child: SizedBox(
                    width: 200,
                    child: NeonSidebarSyncReadout(line: line),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
    }

    await pump(status);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await pump(synced);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await pump(failed);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await pump(status, reduced: true);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
