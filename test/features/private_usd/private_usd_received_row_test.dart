@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_icon.dart';
import 'package:zcash_wallet/src/features/activity/models/activity_row_data.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_activity_rows.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// A private send another wallet made to this one shows in Private USD's
// activity, as the sender's "Sent privately" does on theirs.
void main() {
  Future<ActivityRowData> row(
    WidgetTester tester,
    ActivityRowData Function(BuildContext context) build,
  ) async {
    late ActivityRowData built;
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Builder(
            builder: (context) {
              built = build(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return built;
  }

  testWidgets('a screened send reads received, in, from a hidden sender', (
    tester,
  ) async {
    var opened = 0;
    final received = await row(
      tester,
      (context) => buildPrivateUsdReceivedActivityRow(
        context: context,
        receipt: previewPrivateUsdReceipt(),
        onOpenTransaction: () => opened++,
      ),
    );

    expect(received.title, PrivateUsdCopy.activityReceived);
    expect(received.subtitle, PrivateUsdCopy.activitySenderHidden);
    expect(received.amountText, endsWith(r'+$25.00'));
    expect(received.statusIconName, isNull);
    received.onTap!();
    expect(opened, 1);
  });

  testWidgets('one still in screening says when it is spendable, with a '
      'spinner', (tester) async {
    final arriving = await row(
      tester,
      (context) => buildPrivateUsdReceivedActivityRow(
        context: context,
        receipt: previewPrivateUsdReceipt(settled: false),
      ),
    );

    expect(arriving.subtitle, PrivateUsdCopy.activityReceivedScreening);
    expect(arriving.statusIconName, AppIcons.loader);
  });

  testWidgets('a sender that showed its address is named, truncated', (
    tester,
  ) async {
    const sender =
        '0zk1qyk9nn28x0u3rwn5pknglda68wrn7gw6anjw8gg94mcj6eq5u48tlrv7j6fe3z53l'
        'aznqgp5cn87jmaqsjm4ykr04ae9c0y8gjfm0cpmylg2wvupg5j7a8aceqe';
    final named = await row(
      tester,
      (context) => buildPrivateUsdReceivedActivityRow(
        context: context,
        receipt: previewPrivateUsdReceipt(sender: sender),
      ),
    );

    expect(named.subtitle, startsWith('from 0zk1'));
    expect(named.subtitle, isNot(contains(sender)));
  });

  testWidgets('privacy mode hides the amount', (tester) async {
    final hidden = await row(
      tester,
      (context) => buildPrivateUsdReceivedActivityRow(
        context: context,
        receipt: previewPrivateUsdReceipt(),
        privacyModeEnabled: true,
      ),
    );

    expect(hidden.amountText, isNot(contains('25.00')));
  });
}
