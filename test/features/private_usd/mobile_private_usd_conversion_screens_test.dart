@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/formatting/date_format.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_status_presentation.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_convert_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_banner.dart';
import 'package:zcash_wallet/src/core/widgets/app_button.dart';
import 'package:zcash_wallet/src/core/widgets/mobile/neon_scramble_text.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_convert_views.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_progress_views.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// The forward conversion's screens, and the banner and activity on
// `/private-usd`, built from the Widgetbook fixtures.
void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(393, 1600);
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

  AppButton button(WidgetTester tester, String key) =>
      tester.widget<AppButton>(find.byKey(ValueKey(key)));

  group('convert', () {
    Future<void> pumpConvert(
      WidgetTester tester,
      PrivateUsdConvertState state,
    ) async {
      final controller = TextEditingController(text: state.amountText);
      addTearDown(controller.dispose);
      await pump(
        tester,
        MobilePrivateUsdConvertView(
          state: state,
          controller: controller,
          autofocus: false,
          onAmountChanged: (_) {},
          onMax: () {},
          onReview: () {},
          onBack: () {},
        ),
      );
    }

    testWidgets('a quote shows its ledger and countdown, and can be reviewed', (
      tester,
    ) async {
      await pumpConvert(
        tester,
        previewPrivateUsdConvertState(quote: previewPrivateUsdQuote()),
      );

      expect(find.text(PrivateUsdCopy.convertZecIncludesFee), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertYouPay), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertNetworkFee), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertYouReceive), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertMakerCost), findsOneWidget);
      // The expiry is a HUD caption, drawn uppercase.
      expect(
        find.text(PrivateUsdCopy.convertQuoteExpires('2:35').toUpperCase()),
        findsOneWidget,
      );
      // The ledger's line, and the estimate above it, which decrypts the
      // quote in.
      expect(find.text(r'$15.50'), findsOneWidget);
      expect(
        tester
            .widget<NeonScrambleText>(
              find.byKey(const ValueKey('mobile_private_usd_convert_receive')),
            )
            .text,
        r'$15.50',
      );
      expect(
        button(tester, 'mobile_private_usd_convert_review').onPressed,
        isNotNull,
      );
    });

    testWidgets('while a quote loads, the button says so and waits', (
      tester,
    ) async {
      await pumpConvert(tester, previewPrivateUsdConvertState(quoting: true));

      expect(find.text(PrivateUsdCopy.convertQuoteLoading), findsOneWidget);
      expect(
        button(tester, 'mobile_private_usd_convert_review').onPressed,
        isNull,
      );
    });

    testWidgets('more than the wallet can spend is said, without a quote', (
      tester,
    ) async {
      await pumpConvert(
        tester,
        previewPrivateUsdConvertState(
          amountText: '2',
          spendable: BigInt.from(143120000),
        ),
      );

      expect(
        find.byKey(const ValueKey('mobile_private_usd_convert_message')),
        findsOneWidget,
      );
      expect(find.textContaining('Not enough ZEC.'), findsOneWidget);
      expect(
        button(tester, 'mobile_private_usd_convert_review').onPressed,
        isNull,
      );
    });

    testWidgets('a wallet catching up says so, and "Max" waits', (
      tester,
    ) async {
      await pumpConvert(
        tester,
        previewPrivateUsdConvertState(
          amountText: '',
          catchingUp: true,
          syncPercent: 42,
        ),
      );

      expect(
        find.text(PrivateUsdCopy.convertZecSyncingProgress(42)),
        findsOneWidget,
      );
      expect(
        button(tester, 'mobile_private_usd_convert_max').onPressed,
        isNull,
      );
    });
  });

  group('review', () {
    Future<void> pumpReview(
      WidgetTester tester,
      PrivateUsdConvertState state,
    ) => pump(
      tester,
      MobilePrivateUsdConvertReviewView(
        state: state,
        privacyModeEnabled: false,
        onBack: () {},
        onConfirm: () {},
        onRefreshQuote: () {},
      ),
    );

    testWidgets('the quote holds: its total, what arrives, and Convert', (
      tester,
    ) async {
      await pumpReview(
        tester,
        previewPrivateUsdConvertState(
          quote: previewPrivateUsdQuote(),
          step: PrivateUsdConvertStep.review,
        ),
      );

      // The page title and the expiry caption are drawn uppercase.
      expect(find.text(PrivateUsdCopy.review.toUpperCase()), findsOneWidget);
      expect(find.text('0.5 ZEC'), findsOneWidget);
      expect(find.text(r'$15.50'), findsOneWidget);
      expect(
        find.text(PrivateUsdCopy.convertQuoteHolds('2:35').toUpperCase()),
        findsOneWidget,
      );
      expect(find.text(PrivateUsdCopy.convertBackgroundNote), findsOneWidget);
      expect(
        button(tester, 'mobile_private_usd_review_convert').onPressed,
        isNotNull,
      );
    });

    testWidgets('an expired quote offers "Refresh quote" instead', (
      tester,
    ) async {
      await pumpReview(
        tester,
        previewPrivateUsdConvertState(
          quote: previewPrivateUsdQuote(holds: Duration.zero),
          step: PrivateUsdConvertStep.review,
        ),
      );

      expect(
        find.text(PrivateUsdCopy.quoteExpired.toUpperCase()),
        findsOneWidget,
      );
      expect(find.text(PrivateUsdCopy.convertQuoteRanOut), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertNewQuote), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mobile_private_usd_review_convert')),
        findsNothing,
      );
    });
  });

  group('progress', () {
    Future<void> pumpProgress(
      WidgetTester tester,
      PrivateUsdConversionStatus status, {
      PrivateUsdBalanceState? balance,
      bool bridgeAvailable = true,
    }) => pump(
      tester,
      MobilePrivateUsdConversionView(
        presentation: privateUsdProgressPresentation(
          status: status,
          now: previewPrivateUsdNow,
          zcashConfirmations: 2,
          screening: const Duration(hours: 1),
          balance: balance,
          bridgeAvailable: bridgeAvailable,
        ),
        onBack: () {},
        onInfo: () {},
        onRetry: () {},
        onCallOff: () {},
        onViewBalance: () {},
        onTryAgain: () {},
      ),
    );

    testWidgets('confirmations count up, and the keep-open note shows', (
      tester,
    ) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(depositConfirmations: 1),
          wait: ApiForwardWait.confirming,
        ),
      );

      expect(find.text(PrivateUsdCopy.convertStepConfirm), findsOneWidget);
      expect(find.text('1 of 2 · about 1 min'), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertBackgroundNote), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mobile_private_usd_progress_action')),
        findsNothing,
      );
      expect(find.text(PrivateUsdCopy.convertCallOff), findsNothing);
    });

    testWidgets('an opening over 90 s says so and offers to call it off', (
      tester,
    ) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(
            phase: ApiForwardPhase.opening,
            deposited: false,
            ago: const Duration(minutes: 2),
          ),
          wait: ApiForwardWait.opening,
        ),
      );

      expect(find.text(PrivateUsdCopy.convertOpeningSlow), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertCallOff), findsOneWidget);
    });

    testWidgets('a held problem shows its card and "Try now"', (tester) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(phase: ApiForwardPhase.claiming),
          problem: ApiPrivateUsdErrorCode.relayerUnreachable,
        ),
      );

      expect(find.text(PrivateUsdCopy.convertProblemTitle), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertProblemRelayer), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertProblemRetry), findsOneWidget);
    });

    testWidgets('picking up after a restart says so', (tester) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(depositConfirmations: 1),
          resuming: true,
        ),
      );

      expect(find.text(PrivateUsdCopy.convertResuming), findsOneWidget);
    });

    testWidgets('paid: the dollars are on their way, and "View private USD"', (
      tester,
    ) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(
            phase: ApiForwardPhase.paid,
            outcome: ApiForwardOutcome.paid,
            ago: const Duration(minutes: 20),
          ),
        ),
        balance: previewPrivateUsdBalance(available: 100, arriving: 15.5),
      );

      expect(find.text(PrivateUsdCopy.convertResultPaidTitle), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertStepScreen), findsOneWidget);
      expect(
        find.text(PrivateUsdCopy.convertResultViewBalance),
        findsOneWidget,
      );
      expect(find.text(PrivateUsdCopy.convertBackgroundNote), findsNothing);
    });

    testWidgets('paid and screened: the "Bridged" sign', (tester) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(
            phase: ApiForwardPhase.paid,
            outcome: ApiForwardOutcome.paid,
            ago: const Duration(minutes: 20),
          ),
        ),
        // Read after the payout settled, nothing left arriving.
        balance: previewPrivateUsdBalance(
          available: 115.5,
        ).copyWith(updatedAt: previewPrivateUsdNow),
      );

      expect(
        find.byKey(const ValueKey('mobile_private_usd_bridged')),
        findsOneWidget,
      );
      expect(
        find.text(PrivateUsdCopy.convertResultScreenedBody(r'$15.50')),
        findsOneWidget,
      );
      expect(find.text(PrivateUsdCopy.convertResultPaidTitle), findsNothing);
      expect(
        find.text(PrivateUsdCopy.actionConvert.toUpperCase()),
        findsOneWidget,
      );
    });

    testWidgets('refunded and nothing sent end with "Try again"', (
      tester,
    ) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(
            phase: ApiForwardPhase.refunded,
            outcome: ApiForwardOutcome.refunded,
            refundCause: ApiRefundCause.notClaimedInTime,
          ),
        ),
      );
      expect(
        find.text(PrivateUsdCopy.convertResultRefundedTitle),
        findsOneWidget,
      );
      expect(
        find.text(PrivateUsdCopy.convertResultRefundedLate),
        findsOneWidget,
      );
      expect(find.text(PrivateUsdCopy.convertResultTryAgain), findsOneWidget);

      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(
            phase: ApiForwardPhase.nothingSent,
            outcome: ApiForwardOutcome.nothingSent,
            nothingSentCause: ApiNothingSentCause.makerUnavailable,
            deposited: false,
          ),
        ),
      );
      expect(
        find.text(PrivateUsdCopy.convertResultNothingTitle),
        findsOneWidget,
      );
      expect(
        find.text(PrivateUsdCopy.convertResultMakerUnavailable),
        findsOneWidget,
      );
      expect(find.text(PrivateUsdCopy.convertResultTryAgain), findsOneWidget);
    });

    testWidgets('a refund in progress shows its one step and note', (
      tester,
    ) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(phase: ApiForwardPhase.refunding),
          wait: ApiForwardWait.refunding,
        ),
      );

      expect(find.text(PrivateUsdCopy.convertStepRefund), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertRefunding), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertStepOpen), findsNothing);
    });

    testWidgets('unwinding waits on the maker\'s refund, then the ZEC home, '
        'and says when Veylor claims instead', (tester) async {
      final status = previewPrivateUsdUnwinding();
      await pumpProgress(tester, status);

      final lateClaimAt = DateTime.fromMillisecondsSinceEpoch(
        status.record.lateClaimAt! * 1000,
      );
      expect(find.text(PrivateUsdCopy.convertStepUnwind), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertStepRefund), findsOneWidget);
      expect(find.text(PrivateUsdCopy.convertStepClaim), findsNothing);
      expect(
        find.text(
          PrivateUsdCopy.convertUnwindingUntil(formatDayMonthTime(lateClaimAt)),
        ),
        findsOneWidget,
      );
      // Its sweep or late claim needs the seed: keep the app open.
      expect(find.text(PrivateUsdCopy.convertBackgroundNote), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mobile_private_usd_progress_action')),
        findsNothing,
      );
      expect(find.text(PrivateUsdCopy.convertCallOff), findsNothing);

      // The banner and the activity row name the wait; a late claim running
      // reads as the claim again.
      expect(
        privateUsdForwardStageLabel(status, zcashConfirmations: 2),
        PrivateUsdCopy.convertStepUnwind,
      );
      expect(
        privateUsdForwardStageLabel(
          status.copyWith(activity: ApiActivity.claiming),
          zcashConfirmations: 2,
        ),
        PrivateUsdCopy.convertStepClaim,
      );
    });

    testWidgets('with bridging off, an ended bridge offers no new one', (
      tester,
    ) async {
      final refunded = PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(
          phase: ApiForwardPhase.refunded,
          outcome: ApiForwardOutcome.refunded,
          refundCause: ApiRefundCause.notClaimedInTime,
        ),
      );
      await pumpProgress(tester, refunded, bridgeAvailable: false);
      expect(
        find.text(PrivateUsdCopy.convertResultRefundedTitle),
        findsOneWidget,
      );
      expect(find.text(PrivateUsdCopy.convertResultTryAgain), findsNothing);
      expect(
        find.byKey(const ValueKey('mobile_private_usd_progress_action')),
        findsNothing,
      );
    });
  });

  testWidgets('the banner names the conversion, its stage, and keep-open', (
    tester,
  ) async {
    var opened = 0;
    await pump(
      tester,
      Scaffold(
        body: PrivateUsdConversionBannerView(
          banner: previewPrivateUsdBanner(),
          onTap: () => opened++,
        ),
      ),
    );

    expect(find.text(PrivateUsdCopy.convertingToUsd), findsOneWidget);
    expect(
      find.text(
        'Waiting for confirmations · 1 of 2\n${PrivateUsdCopy.bannerKeepOpen}',
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('private_usd_conversion_banner')),
    );
    expect(opened, 1);
  });

  testWidgets('/private-usd shows the conversion, its activity and Convert', (
    tester,
  ) async {
    var converts = 0;
    await pump(
      tester,
      Builder(
        builder: (context) => MobilePrivateUsdView(
          state: previewPrivateUsdBalance(),
          zecUsdPrice: 50,
          privacyModeEnabled: false,
          screening: const Duration(hours: 1),
          banner: previewPrivateUsdBanner(),
          activityRows: previewPrivateUsdActivityRows(context, [
            previewPrivateUsdRecord(depositConfirmations: 1),
            previewPrivateUsdRecord(
              index: 4,
              phase: ApiForwardPhase.paid,
              outcome: ApiForwardOutcome.paid,
            ),
            previewPrivateUsdRecord(
              index: 3,
              phase: ApiForwardPhase.nothingSent,
              outcome: ApiForwardOutcome.nothingSent,
            ),
          ]),
          onBack: () {},
          onRefresh: () {},
          onConvert: () => converts++,
        ),
      ),
    );

    // A zero balance with a conversion under way is not "empty".
    expect(find.text(PrivateUsdCopy.emptyTitle), findsNothing);
    // The banner and the bridge's own row read alike, so each is found
    // where it stands.
    expect(
      find.descendant(
        of: find.byType(PrivateUsdConversionBannerView),
        matching: find.text(PrivateUsdCopy.convertingToUsd),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mobile_private_usd_activity_row_0')),
        matching: find.text(PrivateUsdCopy.convertingToUsd),
      ),
      findsOneWidget,
    );
    expect(find.text(PrivateUsdCopy.activityConverted), findsOneWidget);
    // Nothing sent moved no money: no row.
    expect(
      find.byKey(const ValueKey('mobile_private_usd_activity_row_2')),
      findsNothing,
    );
    expect(find.text(PrivateUsdCopy.activityEmpty), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mobile_private_usd_convert')));
    expect(converts, 1);
  });
}
