@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_button.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_send.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_send_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_spend_guard.dart';
import 'package:zcash_wallet/widgetbook/private_usd_send_use_cases.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// The send and withdraw screens, built from the Widgetbook fixtures.
void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    // The fixtures' 393 × 852 phone frame, with room around it.
    view.physicalSize = const Size(430, 1000);
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

  Future<void> pump(WidgetTester tester, WidgetBuilder builder) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: Builder(builder: builder),
        ),
      ),
    );
    await tester.pump();
  }

  bool enabled(WidgetTester tester, String key) =>
      tester.widget<AppButton>(find.byKey(ValueKey(key))).onPressed != null;

  testWidgets('the form: a valid send can be reviewed; a bad recipient, an '
      'amount that leaves no fee or a pending payment cannot', (tester) async {
    await pump(tester, buildMobilePrivateUsdSendUseCase);
    // Page titles are drawn uppercase in the top bar.
    expect(find.text(PrivateUsdCopy.sendTitle.toUpperCase()), findsOneWidget);
    expect(enabled(tester, 'mobile_private_usd_send_review'), isTrue);

    await pump(tester, buildMobilePrivateUsdSendInvalidUseCase);
    expect(find.text(PrivateUsdCopy.sendInvalid0zk), findsOneWidget);
    expect(enabled(tester, 'mobile_private_usd_send_review'), isFalse);

    await pump(tester, buildMobilePrivateUsdWithdrawZeroUseCase);
    expect(
      find.text(PrivateUsdCopy.actionWithdraw.toUpperCase()),
      findsOneWidget,
    );
    expect(find.text(PrivateUsdCopy.sendZeroAddress), findsOneWidget);
    expect(enabled(tester, 'mobile_private_usd_send_review'), isFalse);

    await pump(tester, buildMobilePrivateUsdSendLeaveFeeUseCase);
    expect(
      find.text(PrivateUsdCopy.sendLeaveNetworkFee(r'$0.50')),
      findsOneWidget,
    );
    expect(enabled(tester, 'mobile_private_usd_send_review'), isFalse);

    // A valid send while an earlier payment is unsettled: the note, and no
    // review.
    final amount = TextEditingController(text: '25');
    final recipient = TextEditingController(text: previewPrivateUsdRecipient);
    addTearDown(amount.dispose);
    addTearDown(recipient.dispose);
    await pump(
      tester,
      (_) => MobilePrivateUsdSendView(
        form: PrivateUsdSendForm(
          mode: PrivateUsdSendMode.private,
          token: previewPrivateUsdUsdc,
          amountText: '25',
          recipient: previewPrivateUsdRecipient,
        ),
        balances: previewPrivateUsdSendBalances,
        status: PrivateUsdSpendStatus.sending,
        amountController: amount,
        recipientController: recipient,
        onAmountChanged: (_) {},
        onRecipientChanged: (_) {},
        onUseAll: () {},
        onReview: () {},
        onBack: () {},
        isRailgunAddress: previewPrivateUsdIsRailgunAddress,
        autofocus: false,
      ),
    );
    expect(find.text(PrivateUsdCopy.paymentPending), findsOneWidget);
    expect(enabled(tester, 'mobile_private_usd_send_review'), isFalse);
  });

  // As ZEC Send's recipient picker: the Receive sheet shows both kinds of
  // address as a code.
  testWidgets('Send and Withdraw scan their recipient; not while busy', (
    tester,
  ) async {
    var scans = 0;
    Future<void> show(PrivateUsdSendForm form) async {
      final amount = TextEditingController();
      final recipient = TextEditingController();
      addTearDown(amount.dispose);
      addTearDown(recipient.dispose);
      await pump(
        tester,
        (_) => MobilePrivateUsdSendView(
          form: form,
          balances: previewPrivateUsdBalance(available: 100).balances,
          status: PrivateUsdSpendStatus.available,
          amountController: amount,
          recipientController: recipient,
          onAmountChanged: (_) {},
          onRecipientChanged: (_) {},
          onUseAll: () {},
          onScan: () => scans++,
          onReview: () {},
          onBack: () {},
          isRailgunAddress: previewPrivateUsdIsRailgunAddress,
          autofocus: false,
        ),
      );
    }

    final scan = find.byKey(const ValueKey('mobile_private_usd_send_scan'));
    for (final mode in PrivateUsdSendMode.values) {
      await show(PrivateUsdSendForm(mode: mode, token: previewPrivateUsdUsdc));
      expect(scan, findsOneWidget);
      await tester.tap(scan);
      expect(scans, mode.index + 1, reason: mode.name);
    }

    await show(
      PrivateUsdSendForm(
        mode: PrivateUsdSendMode.private,
        token: previewPrivateUsdUsdc,
        isBusy: true,
      ),
    );
    await tester.tap(scan);
    expect(scans, PrivateUsdSendMode.values.length);
  });

  testWidgets('review, proof, outcome, and Send and Withdraw held back by a '
      'pending payment', (tester) async {
    await pump(tester, buildMobilePrivateUsdWithdrawReviewUseCase);
    expect(
      find.text(PrivateUsdCopy.sendReviewTitleWithdraw.toUpperCase()),
      findsOneWidget,
    );
    expect(
      find.text(PrivateUsdCopy.sendReviewRailgunFee('0.25')),
      findsOneWidget,
    );
    expect(find.text(r'$99.75'), findsOneWidget);
    expect(find.text(PrivateUsdCopy.sendWithdrawPublic), findsOneWidget);
    expect(enabled(tester, 'mobile_private_usd_send_confirm'), isTrue);

    await pump(tester, buildMobilePrivateUsdSendReviewUseCase);
    expect(find.text(PrivateUsdCopy.sendWithdrawPublic), findsNothing);
    expect(find.textContaining('Railgun fee'), findsNothing);

    await pump(tester, buildMobilePrivateUsdSendProvingUseCase);
    expect(find.text(PrivateUsdCopy.sendProvingPercent(42)), findsOneWidget);
    expect(find.text(PrivateUsdCopy.sendProvingDetail), findsOneWidget);

    await pump(tester, buildMobilePrivateUsdSendDoneUseCase);
    expect(find.text(PrivateUsdCopy.sendDoneTitlePrivate), findsOneWidget);
    expect(find.text(PrivateUsdCopy.sendViewTx), findsOneWidget);

    await pump(tester, buildMobilePrivateUsdSendUnconfirmedUseCase);
    expect(find.text(PrivateUsdCopy.sendDoneTitleWithdraw), findsOneWidget);
    expect(find.textContaining(PrivateUsdCopy.sendUnconfirmed), findsOneWidget);

    await pump(tester, buildMobilePrivateUsdPaymentPendingUseCase);
    expect(find.text(PrivateUsdCopy.paymentPending), findsOneWidget);
    expect(enabled(tester, 'mobile_private_usd_send'), isFalse);
    expect(enabled(tester, 'mobile_private_usd_withdraw'), isFalse);
    expect(enabled(tester, 'mobile_private_usd_convert'), isFalse);
    await tester.dragUntilVisible(
      find.text(PrivateUsdCopy.activityUnconfirmed),
      find.byKey(const ValueKey('mobile_private_usd_list')),
      const Offset(0, -200),
    );
    expect(find.text(PrivateUsdCopy.activityWithdrew), findsNothing);
    expect(find.text(PrivateUsdCopy.activitySent), findsOneWidget);
  });
}
