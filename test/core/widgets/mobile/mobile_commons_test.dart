@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_shell.dart';
import 'package:zcash_wallet/src/core/layout/mobile/app_mobile_tab_bar.dart';
import 'package:zcash_wallet/src/core/layout/mobile/mobile_top_nav.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_icon.dart';
import 'package:zcash_wallet/src/core/widgets/app_toast.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_list_row.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/mobile_surface_card.dart';

void main() {
  testWidgets('MobileListRow renders label, value, and chevron', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        MobileListRow(
          label: 'Theme',
          value: 'Dark',
          showChevron: true,
          onTap: () => taps++,
        ),
      ),
    );

    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    final chevron = tester.widget<AppIcon>(find.byType(AppIcon));
    expect(chevron.name, AppIcons.chevronForward);

    await tester.tap(find.text('Theme'));
    expect(taps, 1);
  });

  testWidgets('MobileListRow disabled mutes colors and ignores taps', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        MobileListRow(
          label: 'Password',
          value: 'Change',
          enabled: false,
          onTap: () => taps++,
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('Password'));
    expect(label.style?.color, AppThemeData.dark.colors.text.disabled);

    await tester.tap(find.text('Password'), warnIfMissed: false);
    expect(taps, 0);
  });

  testWidgets('MobileSurfaceCard paints a neon glass panel', (tester) async {
    await tester.pumpWidget(
      _harness(const MobileSurfaceCard(child: Text('content'))),
    );

    final panel = tester.widget<CustomPaint>(
      find.ancestor(
        of: find.text('content'),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is NeonGlassPanelPainter,
        ),
      ),
    );
    final painter = panel.painter! as NeonGlassPanelPainter;
    final colors = AppThemeData.dark.colors;
    // A see-through pane of the window colour, with lit cut corners.
    expect(
      painter.fill.withValues(alpha: 1),
      colors.background.window.withValues(alpha: 1),
    );
    expect(painter.fill.a, inExclusiveRange(0, 1));
    expect(painter.glow, colors.neon.glow);
    expect(painter.core, colors.neon.core);
    expect(painter.cut, AppChamfer.large);
  });

  testWidgets('MobileTopNav.account applies sync color overrides', (
    tester,
  ) async {
    const errorColor = Color(0xFFFF0000);
    await tester.pumpWidget(
      _harness(
        const MobileTopNav.account(
          accountName: 'Account1',
          syncLabel: 'Syncing failed. Network error...',
          syncLabelColor: errorColor,
          syncIndicatorColor: errorColor,
        ),
      ),
    );

    final label = tester.widget<Text>(
      find.text('Syncing failed. Network error...'),
    );
    expect(label.style?.color, errorColor);
  });

  testWidgets('AppMobileShell hosts toasts for tab content', (tester) async {
    await tester.pumpWidget(
      _harness(
        AppMobileShell(
          body: Builder(
            builder: (context) => Center(
              child: GestureDetector(
                onTap: () => showAppToast(context, 'Address copied'),
                child: const Text('copy'),
              ),
            ),
          ),
          tabBar: AppMobileTabBar(
            items: const [AppMobileTabItem(iconName: 'home', label: 'Home')],
            currentIndex: 0,
            onSelect: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('copy'));
    await tester.pump();
    expect(find.text('Address copied'), findsOneWidget);
  });
}

Widget _harness(Widget child) {
  return MaterialApp(
    home: AppTheme(
      data: AppThemeData.dark,
      child: Center(child: child),
    ),
  );
}
