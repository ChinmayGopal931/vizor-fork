@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/l10n/app_language.dart';
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
import 'package:zcash_wallet/src/core/zcash/block_spacing.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_convert_views.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_progress_views.dart';
import 'package:zcash_wallet/src/features/settings/widgets/mobile/mobile_tor_control.dart';
import 'package:zcash_wallet/src/providers/zec_price_change_provider.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';
import '../../support/test_l10n.dart';

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
        localizationsDelegates: appLocalizationsDelegates,
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
      PrivateUsdConvertState state, {
      double? zecUsdPrice,
    }) async {
      final controller = TextEditingController(text: state.amountText);
      addTearDown(controller.dispose);
      await pump(
        tester,
        MobilePrivateUsdConvertView(
          state: state,
          controller: controller,
          autofocus: false,
          relayerClaims: true,
          zecUsdPrice: zecUsdPrice,
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

      expect(
        find.text(testL10n.privateUsdConvertZecIncludesFee),
        findsOneWidget,
      );
      expect(find.text(testL10n.privateUsdConvertYouPay), findsOneWidget);
      expect(find.text(testL10n.commonNetworkFee), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertYouReceive), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertMakerCost), findsOneWidget);
      // The expiry is a HUD caption, drawn uppercase.
      expect(
        find.text(testL10n.privateUsdConvertQuoteExpires('2:35').toUpperCase()),
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

    testWidgets('what the ZEC is worth sits right of the fee note', (
      tester,
    ) async {
      final state = previewPrivateUsdConvertState(
        quote: previewPrivateUsdQuote(),
      );
      await pumpConvert(tester, state, zecUsdPrice: 70);

      final marketValue = find.byKey(
        const ValueKey('mobile_private_usd_convert_market_value'),
      );
      expect(
        tester.widget<Text>(marketValue).data,
        PrivateUsdCopy.convertMarketValue(
          fiatTextForZatoshi(state.totalZat!, zecUsdUnitPrice: 70)!,
        ),
      );
      final note = find.text(testL10n.privateUsdConvertZecIncludesFee);
      expect(tester.getTopLeft(marketValue).dy, tester.getTopLeft(note).dy);
      expect(
        tester.getTopLeft(marketValue).dx,
        greaterThan(tester.getTopRight(note).dx),
      );
    });

    testWidgets('while a quote loads, the button says so and waits', (
      tester,
    ) async {
      await pumpConvert(tester, previewPrivateUsdConvertState(quoting: true));

      expect(find.text(testL10n.privateUsdConvertQuoteLoading), findsOneWidget);
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
        find.text(testL10n.privateUsdConvertZecSyncingProgress(42)),
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
      PrivateUsdConvertState state, {
      bool relayerClaims = false,
    }) => pump(
      tester,
      MobilePrivateUsdConvertReviewView(
        state: state,
        privacyModeEnabled: false,
        relayerClaims: relayerClaims,
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
      expect(
        find.text(testL10n.privateUsdReview.toUpperCase()),
        findsOneWidget,
      );
      expect(find.text('0.5 ZEC'), findsOneWidget);
      expect(find.text(r'$15.50'), findsOneWidget);
      expect(
        find.text(testL10n.privateUsdConvertQuoteHolds('2:35').toUpperCase()),
        findsOneWidget,
      );
      expect(
        find.text(testL10n.privateUsdConvertBackgroundNote),
        findsOneWidget,
      );
      expect(
        button(tester, 'mobile_private_usd_review_convert').onPressed,
        isNotNull,
      );
    });

    testWidgets('with the relayer claiming, Veylor stays open only until '
        'the market maker confirms the deposit', (tester) async {
      await pumpReview(
        tester,
        previewPrivateUsdConvertState(
          quote: previewPrivateUsdQuote(),
          step: PrivateUsdConvertStep.review,
        ),
        relayerClaims: true,
      );

      expect(
        find.text(testL10n.privateUsdConvertRelayerReviewNote),
        findsOneWidget,
      );
      expect(find.text(testL10n.privateUsdConvertBackgroundNote), findsNothing);
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
        find.text(testL10n.privateUsdQuoteExpired.toUpperCase()),
        findsOneWidget,
      );
      expect(find.text(testL10n.privateUsdConvertQuoteRanOut), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertNewQuote), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mobile_private_usd_review_convert')),
        findsNothing,
      );
    });
  });

  group('progress', () {
    final keepOpenCard = find.byKey(
      const ValueKey('mobile_private_usd_progress_keep_open'),
    );

    Future<void> pumpProgress(
      WidgetTester tester,
      PrivateUsdConversionStatus status, {
      PrivateUsdBalanceState? balance,
      bool bridgeAvailable = true,
      bool relayerClaims = false,
      bool keepScreenOn = true,
      ValueChanged<bool>? onKeepScreenOnChanged,
      BlockTimeEstimate blockTimes = BlockTimeEstimate.preNu7,
    }) async {
      await pump(
        tester,
        MobilePrivateUsdConversionView(
          presentation: privateUsdProgressPresentation(
            testL10n,
            status: status,
            now: previewPrivateUsdNow,
            zcashConfirmations: 2,
            screening: const Duration(hours: 1),
            balance: balance,
            bridgeAvailable: bridgeAvailable,
            relayerClaims: relayerClaims,
            blockTimes: blockTimes,
          ),
          keepScreenOn: keepScreenOn,
          onKeepScreenOnChanged: onKeepScreenOnChanged,
          onBack: () {},
          onInfo: () {},
          onRetry: () {},
          onCallOff: () {},
          onViewBalance: () {},
          onTryAgain: () {},
        ),
      );
      // The keep-open card slides in a moment after the progress shows.
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('confirmations count up, and the keep-open card shows', (
      tester,
    ) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(depositConfirmations: 1),
          wait: ApiForwardWait.confirming,
        ),
      );

      expect(find.text(testL10n.privateUsdConvertStepConfirm), findsOneWidget);
      expect(find.text('1 of 2 · about 1 min'), findsOneWidget);
      expect(keepOpenCard, findsOneWidget);
      expect(find.text(testL10n.privateUsdKeepOpenBody), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertBackgroundNote), findsNothing);
      expect(
        find.byKey(const ValueKey('mobile_private_usd_progress_action')),
        findsNothing,
      );
      expect(find.text(testL10n.privateUsdConvertCallOff), findsNothing);
    });

    testWidgets('the confirmations estimate follows the block time', (
      tester,
    ) async {
      final status = PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(depositConfirmations: 0),
        wait: ApiForwardWait.confirming,
      );
      await pumpProgress(tester, status);
      expect(find.text('0 of 2 · about 2 min'), findsOneWidget);

      // From NU7 a block takes 25 s, so two take under a minute.
      const nu7 = BlockSpacing(
        preNu7BlockSeconds: 75,
        nu7BlockSeconds: 25,
        nu7ActivationHeight: 100,
      );
      await pumpProgress(tester, status, blockTimes: nu7.fromTip(200));
      expect(find.text('0 of 2 · about 1 min'), findsOneWidget);
    });

    testWidgets('once the relayer holds the claim, the user can leave', (
      tester,
    ) async {
      final status = PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(
          depositConfirmations: 1,
          claimHeld: true,
        ),
        wait: ApiForwardWait.confirming,
      );
      await pumpProgress(tester, status);

      expect(
        find.text(testL10n.privateUsdConvertRelayerClaims),
        findsOneWidget,
      );
      expect(keepOpenCard, findsNothing);
      expect(find.text('1 of 2 · about 1 min'), findsOneWidget);

      // The claim is handed over only once the market maker made the swap
      // ready, so past the deposit's confirmations the maker is never
      // called silent.
      final confirmed = PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(
          depositConfirmations: 2,
          claimHeld: true,
        ),
        wait: ApiForwardWait.confirming,
      );
      await pumpProgress(tester, confirmed);
      final t0 = DateTime.fromMillisecondsSinceEpoch(
        confirmed.record.t0! * 1000,
      );
      expect(
        find.text(testL10n.privateUsdConvertRelayerClaims),
        findsOneWidget,
      );
      expect(
        find.text(
          testL10n.privateUsdConvertMakerSilent(
            formatDayMonthTime(t0, testL10n.localeName),
          ),
        ),
        findsNothing,
      );
      expect(keepOpenCard, findsNothing);
    });

    testWidgets('a refund after the hand-over needs Veylor open again', (
      tester,
    ) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(
            phase: ApiForwardPhase.refunding,
            claimHeld: true,
          ),
          wait: ApiForwardWait.refunding,
        ),
      );

      expect(find.text(testL10n.privateUsdConvertRefunding), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertRelayerClaims), findsNothing);
      expect(keepOpenCard, findsOneWidget);
    });

    testWidgets('"Keep screen on" starts on, and a tap turns it off', (
      tester,
    ) async {
      final changes = <bool>[];
      final status = PrivateUsdConversionStatus(
        record: previewPrivateUsdRecord(depositConfirmations: 1),
        wait: ApiForwardWait.confirming,
      );
      bool toggleOn() => tester
          .widget<MobilePrivacyToggle>(find.byType(MobilePrivacyToggle))
          .enabled;
      final row = find.byKey(
        const ValueKey('mobile_private_usd_keep_screen_on'),
      );

      await pumpProgress(tester, status, onKeepScreenOnChanged: changes.add);
      expect(find.text(testL10n.privateUsdKeepScreenOn), findsOneWidget);
      expect(toggleOn(), isTrue);
      await tester.tap(row);
      expect(changes, [false]);

      await pumpProgress(
        tester,
        status,
        keepScreenOn: false,
        onKeepScreenOnChanged: changes.add,
      );
      expect(toggleOn(), isFalse);
      await tester.tap(row);
      expect(changes, [false, true]);
    });

    testWidgets('with the relayer to claim, the bridge asks for Veylor only '
        'until the market maker confirms the deposit', (tester) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(
            phase: ApiForwardPhase.opening,
            deposited: false,
            ago: const Duration(seconds: 30),
          ),
          wait: ApiForwardWait.opening,
        ),
        relayerClaims: true,
      );
      expect(
        find.text(testL10n.privateUsdConvertRelayerReviewNote),
        findsOneWidget,
      );
      expect(keepOpenCard, findsNothing);

      // The deposit out, waiting for the maker to confirm it: still so.
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(depositConfirmations: 1),
          wait: ApiForwardWait.confirming,
        ),
        relayerClaims: true,
      );
      expect(
        find.text(testL10n.privateUsdConvertRelayerReviewNote),
        findsOneWidget,
      );
      expect(keepOpenCard, findsNothing);

      // The relayer declined the claim: Veylor claims it, so it stays open
      // after all.
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(
            depositConfirmations: 1,
            claimDeclined: true,
          ),
          wait: ApiForwardWait.confirming,
        ),
        relayerClaims: true,
      );
      expect(
        find.text(testL10n.privateUsdConvertRelayerReviewNote),
        findsNothing,
      );
      expect(keepOpenCard, findsOneWidget);
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

      expect(find.text(testL10n.privateUsdConvertOpeningSlow), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertCallOff), findsOneWidget);
    });

    testWidgets('a held problem shows its card and "Try now"', (tester) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(phase: ApiForwardPhase.claiming),
          problem: ApiPrivateUsdErrorCode.relayerUnreachable,
        ),
      );

      expect(find.text(testL10n.privateUsdConvertProblemTitle), findsOneWidget);
      expect(
        find.text(testL10n.privateUsdConvertProblemRelayer),
        findsOneWidget,
      );
      expect(find.text(testL10n.privateUsdConvertProblemRetry), findsOneWidget);
    });

    testWidgets('picking up after a restart says so', (tester) async {
      await pumpProgress(
        tester,
        PrivateUsdConversionStatus(
          record: previewPrivateUsdRecord(depositConfirmations: 1),
          resuming: true,
        ),
      );

      expect(find.text(testL10n.privateUsdConvertResuming), findsOneWidget);
    });

    testWidgets('paid: the 0zkUSDC is on its way, and "View private USD"', (
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

      expect(
        find.text(testL10n.privateUsdConvertResultPaidTitle),
        findsOneWidget,
      );
      expect(find.text(testL10n.privateUsdConvertStepScreen), findsOneWidget);
      expect(
        find.text(testL10n.privateUsdConvertResultViewBalance),
        findsOneWidget,
      );
      expect(keepOpenCard, findsNothing);
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
        find.text(testL10n.privateUsdConvertResultScreenedBody(r'$15.50')),
        findsOneWidget,
      );
      expect(
        find.text(testL10n.privateUsdConvertResultPaidTitle),
        findsNothing,
      );
      expect(
        find.text(testL10n.privateUsdActionConvert.toUpperCase()),
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
        find.text(testL10n.privateUsdConvertResultRefundedTitle),
        findsOneWidget,
      );
      expect(
        find.text(testL10n.privateUsdConvertResultRefundedLate),
        findsOneWidget,
      );
      expect(find.text(testL10n.commonTryAgain), findsOneWidget);

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
        find.text(testL10n.privateUsdConvertResultNothingTitle),
        findsOneWidget,
      );
      expect(
        find.text(testL10n.privateUsdConvertResultMakerUnavailable),
        findsOneWidget,
      );
      expect(find.text(testL10n.commonTryAgain), findsOneWidget);
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

      expect(find.text(testL10n.privateUsdConvertStepRefund), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertRefunding), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertStepOpen), findsNothing);
    });

    testWidgets('unwinding waits on the maker\'s refund, then the ZEC home, '
        'and says when Veylor claims instead', (tester) async {
      final status = previewPrivateUsdUnwinding();
      await pumpProgress(tester, status);

      final lateClaimAt = DateTime.fromMillisecondsSinceEpoch(
        status.record.lateClaimAt! * 1000,
      );
      expect(find.text(testL10n.privateUsdConvertStepUnwind), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertStepRefund), findsOneWidget);
      expect(find.text(testL10n.privateUsdConvertStepClaim), findsNothing);
      expect(
        find.text(
          testL10n.privateUsdConvertUnwindingUntil(
            formatDayMonthTime(lateClaimAt, testL10n.localeName),
          ),
        ),
        findsOneWidget,
      );
      // Its sweep or late claim needs the seed: keep the app open.
      expect(keepOpenCard, findsOneWidget);
      expect(
        find.byKey(const ValueKey('mobile_private_usd_progress_action')),
        findsNothing,
      );
      expect(find.text(testL10n.privateUsdConvertCallOff), findsNothing);

      // The banner and the activity row name the wait; a late claim running
      // reads as the claim again.
      expect(
        privateUsdForwardStageLabel(testL10n, status, zcashConfirmations: 2),
        testL10n.privateUsdConvertStepUnwind,
      );
      expect(
        privateUsdForwardStageLabel(
          testL10n,
          status.copyWith(activity: ApiActivity.claiming),
          zcashConfirmations: 2,
        ),
        testL10n.privateUsdConvertStepClaim,
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
        find.text(testL10n.privateUsdConvertResultRefundedTitle),
        findsOneWidget,
      );
      expect(find.text(testL10n.commonTryAgain), findsNothing);
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

    expect(find.text(testL10n.privateUsdConvertingToUsd), findsOneWidget);
    expect(
      find.text(
        'Waiting for confirmations · 1 of 2\n${testL10n.privateUsdBannerKeepOpen}',
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('private_usd_conversion_banner')),
    );
    expect(opened, 1);
  });

  testWidgets('once the relayer holds the claim, the banner says to leave', (
    tester,
  ) async {
    await pump(
      tester,
      Scaffold(
        body: PrivateUsdConversionBannerView(
          banner: previewPrivateUsdBanner(claimHandedOver: true),
          onTap: () {},
        ),
      ),
    );

    expect(
      find.text(
        'Waiting for confirmations · 1 of 2\n'
        '${testL10n.privateUsdBannerRelayerClaims}',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(testL10n.privateUsdBannerKeepOpen),
      findsNothing,
    );
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
    expect(find.text(testL10n.privateUsdEmptyTitle), findsNothing);
    // The banner and the bridge's own row read alike, so each is found
    // where it stands.
    expect(
      find.descendant(
        of: find.byType(PrivateUsdConversionBannerView),
        matching: find.text(testL10n.privateUsdConvertingToUsd),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mobile_private_usd_activity_row_0')),
        matching: find.text(testL10n.privateUsdConvertingToUsd),
      ),
      findsOneWidget,
    );
    expect(find.text(testL10n.privateUsdActivityConverted), findsOneWidget);
    // Nothing sent moved no money: no row.
    expect(
      find.byKey(const ValueKey('mobile_private_usd_activity_row_2')),
      findsNothing,
    );
    expect(find.text(testL10n.privateUsdActivityEmpty), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mobile_private_usd_convert')));
    expect(converts, 1);
  });
}
