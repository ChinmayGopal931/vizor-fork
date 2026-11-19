import 'package:flutter/material.dart' show Colors, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/layout/app_desktop_shell.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import '../../support/localized_test_scope.dart';

void main() {
  testWidgets('desktop shell owns the default macOS window backing', (
    tester,
  ) async {
    await tester.pumpWidget(
      AppTheme(
        data: AppThemeData.light,
        child: const LocalizedTestScope(
          child: AppDesktopShell(
            sidebar: SizedBox(width: 256),
            pane: AppDesktopPane(child: SizedBox.expand()),
          ),
        ),
      ),
    );

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(
      scaffold.backgroundColor,
      AppThemeData.light.colors.macosUtility.window,
    );
  });

  testWidgets('desktop pane lets the shell window backing show through', (
    tester,
  ) async {
    await tester.pumpWidget(
      AppTheme(
        data: AppThemeData.light,
        child: const LocalizedTestScope(
          child: AppDesktopPane(child: SizedBox.expand()),
        ),
      ),
    );

    final container = tester.widget<Container>(find.byType(Container));
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);
  });

  testWidgets(
    'desktop shell background can be transparent for image-backed pages',
    (tester) async {
      await tester.pumpWidget(
        AppTheme(
          data: AppThemeData.light,
          child: const LocalizedTestScope(
            child: AppDesktopShell(
              backgroundColor: Colors.transparent,
              sidebar: SizedBox(width: 256),
              pane: AppDesktopPane(child: SizedBox.expand()),
            ),
          ),
        ),
      );

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, Colors.transparent);
    },
  );
}
