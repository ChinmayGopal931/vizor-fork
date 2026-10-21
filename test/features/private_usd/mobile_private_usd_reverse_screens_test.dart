@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/core/widgets/app_button.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_reverse_presentation.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_refunds_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_reverse_convert_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/screens/mobile/mobile_private_usd_refunds_screen.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_reverse_funding.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_convert_views.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_progress_views.dart';
import 'package:zcash_wallet/src/rust/api/private_usd.dart';
import 'package:zcash_wallet/widgetbook/private_usd_reverse_use_cases.dart';
import 'package:zcash_wallet/widgetbook/private_usd_use_cases.dart';

// The reverse conversion's screens, built from the Widgetbook fixtures.
void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    // Wider than a phone: the test font's square glyphs make "Authorize
    // settlement" a pixel wider than the button at 393 (real fonts fit).
    view.physicalSize = const Size(430, 1800);
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

  testWidgets('the amount step: a priced quote can be reviewed; '
      'more than 2 decimals cannot', (tester) async {
    Future<void> amount(PrivateUsdReverseConvertState state) async {
      final controller = TextEditingController(text: state.amountText);
      addTearDown(controller.dispose);
      await pump(
        tester,
        MobilePrivateUsdReverseConvertView(
          state: state,
          controller: controller,
          autofocus: false,
          onAmountChanged: (_) {},
          onMax: () {},
          onReview: () {},
          onBack: () {},
          onSwitchDirection: () {},
        ),
      );
    }

    final priced = previewPrivateUsdReverseConvertState();
    await amount(priced);
    for (final label in [
      PrivateUsdCopy.reverseEscrow,
      PrivateUsdCopy.reverseRailgunFee,
      PrivateUsdCopy.reverseBroadcasterFee,
      PrivateUsdCopy.reverseTotal,
      PrivateUsdCopy.reverseReceiveEstimate,
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text(r'$25.31'), findsOneWidget);
    expect(
      find.bySemanticsLabel(PrivateUsdCopy.convertSwapDirection),
      findsOneWidget,
    );
    expect(
      button(tester, 'mobile_private_usd_convert_review').onPressed,
      isNotNull,
    );

    await amount(
      PrivateUsdReverseConvertState(
        now: previewPrivateUsdNow,
        amountText: '2.501',
        available: BigInt.from(1250400000),
      ),
    );
    expect(find.text(PrivateUsdCopy.reverseAmountCents), findsOneWidget);
    expect(
      button(tester, 'mobile_private_usd_convert_review').onPressed,
      isNull,
    );
  });

  testWidgets('progress offers "Pay" and "Authorize settlement" only in '
      'their window, and the call-off as fits', (tester) async {
    Future<PrivateUsdReverseProgressPresentation> progress(
      ApiReverseRecord record, {
      DateTime? now,
    }) async {
      final presentation = privateUsdReverseProgressPresentation(
        status: PrivateUsdReverseStatus(record: record),
        now: now ?? previewPrivateUsdNow,
      );
      await pump(
        tester,
        MobilePrivateUsdReverseConversionView(
          presentation: presentation,
          onBack: () {},
          onInfo: () {},
          onRetry: () {},
          onAction: () {},
          onCallOff: () {},
        ),
      );
      return presentation;
    }

    // Unpaid: "Pay {debit}" and "Cancel bridge".
    await progress(
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.awaitingFunding),
    );
    expect(find.text(PrivateUsdCopy.reversePay(r'$25.31')), findsOneWidget);
    expect(
      button(tester, 'mobile_private_usd_progress_action').onPressed,
      isNotNull,
    );
    expect(find.text(PrivateUsdCopy.reverseCancel), findsOneWidget);

    // Paid and confirmed: "Authorize settlement", "Request refund".
    final ready = previewPrivateUsdReverseRecord(
      phase: ApiReversePhase.awaitingReady,
    );
    await progress(ready);
    expect(find.text(PrivateUsdCopy.reverseReadyExplanation), findsOneWidget);
    expect(find.text(PrivateUsdCopy.reverseRequestRefund), findsOneWidget);
    expect(
      button(tester, 'mobile_private_usd_progress_action').onPressed,
      isNotNull,
    );

    // Within 120 s of the ready deadline it can no longer be authorized.
    await progress(
      ready,
      now: DateTime.fromMillisecondsSinceEpoch(
        ready.readyDeadline * 1000,
      ).subtract(const Duration(seconds: 100)),
    );
    expect(find.text(PrivateUsdCopy.reverseReady), findsWidgets);
    expect(
      button(tester, 'mobile_private_usd_progress_action').onPressed,
      isNull,
    );

    // Settled: no call-off; ended: "New bridge".
    await progress(
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.receiving),
    );
    expect(
      find.byKey(const ValueKey('mobile_private_usd_progress_call_off')),
      findsNothing,
    );
    await progress(
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.refunded),
    );
    expect(find.text(PrivateUsdCopy.reverseResultRefunded), findsOneWidget);
    expect(find.text(PrivateUsdCopy.reverseNew), findsOneWidget);
    expect(find.text(PrivateUsdCopy.refundsView), findsOneWidget);
  });

  // The timeline once capped a finished bridge's current step at its last
  // row, which kept spinning beside the button for a new one.
  testWidgets('a finished bridge keeps no step current and lights its sign', (
    tester,
  ) async {
    Future<void> show(ApiReversePhase phase, {bool celebrate = false}) => pump(
      tester,
      MobilePrivateUsdReverseConversionView(
        presentation: privateUsdReverseProgressPresentation(
          status: PrivateUsdReverseStatus(
            record: previewPrivateUsdReverseRecord(phase: phase),
          ),
          now: previewPrivateUsdNow,
        ),
        celebrate: celebrate,
        onBack: () {},
        onInfo: () {},
        onRetry: () {},
      ),
    );

    await show(ApiReversePhase.receiving);
    expect(
      find.byKey(const ValueKey('swap_status_active_step_loader')),
      findsOneWidget,
    );
    expect(
      find.text(PrivateUsdCopy.convertProgressTitle.toUpperCase()),
      findsOneWidget,
    );

    await show(ApiReversePhase.complete);
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey('swap_status_active_step_loader')),
      findsNothing,
    );
    expect(find.text(PrivateUsdCopy.reverseSweeping), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile_private_usd_bridged')),
      findsOneWidget,
    );
    expect(
      find.text(PrivateUsdCopy.bridgedTitle.toUpperCase()),
      findsOneWidget,
    );
    expect(
      find.text(PrivateUsdCopy.actionConvert.toUpperCase()),
      findsOneWidget,
    );
    expect(find.text(PrivateUsdCopy.bridgedYouPaid), findsOneWidget);
    expect(find.text(PrivateUsdCopy.bridgedYouReceived), findsOneWidget);
    expect(find.text(PrivateUsdCopy.reverseNew), findsOneWidget);
  });

  testWidgets('the Pay step reads as the user\'s to take until Pay is tapped, '
      'then as the payment going, with the proof\'s percentage', (
    tester,
  ) async {
    final unpaid = previewPrivateUsdReverseRecord(
      phase: ApiReversePhase.awaitingFunding,
    );
    Future<void> show({
      PrivateUsdFundingState? funding,
      double? proofProgress,
    }) => pump(
      tester,
      MobilePrivateUsdReverseConversionView(
        presentation: privateUsdReverseProgressPresentation(
          status: PrivateUsdReverseStatus(record: unpaid),
          now: previewPrivateUsdNow,
          funding: funding,
          proofProgress: proofProgress,
        ),
        onBack: () {},
        onInfo: () {},
        onRetry: () {},
        onAction: () {},
        onCallOff: () {},
      ),
    );

    // Waiting for the tap: nothing is being sent yet.
    await show();
    expect(find.text(PrivateUsdCopy.reverseStepPay), findsOneWidget);
    expect(
      find.text(PrivateUsdCopy.reverseStepPayDetail(r'$25.31')),
      findsOneWidget,
    );
    expect(find.text(PrivateUsdCopy.reverseStepFund), findsNothing);

    // Tapped: the payment is proved, then sent.
    await show(
      funding: const PrivateUsdFundingState(
        stage: PrivateUsdFundingStage.proving,
      ),
      proofProgress: 0.42,
    );
    expect(find.text(PrivateUsdCopy.reverseStepFund), findsOneWidget);
    expect(find.text(PrivateUsdCopy.paymentProving(42)), findsOneWidget);
    expect(find.text(PrivateUsdCopy.reverseStepPay), findsNothing);

    await show(
      funding: const PrivateUsdFundingState(
        stage: PrivateUsdFundingStage.submitting,
      ),
    );
    expect(find.text(PrivateUsdCopy.reverseStepFund), findsOneWidget);
    expect(
      find.text(PrivateUsdCopy.reverseStepPayDetail(r'$25.31')),
      findsNothing,
    );
  });

  testWidgets('with bridging off, an ended bridge offers no new one', (
    tester,
  ) async {
    await pump(
      tester,
      MobilePrivateUsdReverseConversionView(
        presentation: privateUsdReverseProgressPresentation(
          status: PrivateUsdReverseStatus(
            record: previewPrivateUsdReverseRecord(
              phase: ApiReversePhase.refunded,
            ),
          ),
          now: previewPrivateUsdNow,
          bridgeAvailable: false,
        ),
        onBack: () {},
        onInfo: () {},
        onRetry: () {},
        onViewRefunds: () {},
      ),
    );

    expect(find.text(PrivateUsdCopy.reverseResultRefunded), findsOneWidget);
    expect(find.text(PrivateUsdCopy.refundsView), findsOneWidget);
    expect(find.text(PrivateUsdCopy.reverseNew), findsNothing);
  });

  testWidgets('refunds: each row says where its recovery stands, and only a '
      'recoverable one offers it', (tester) async {
    PrivateUsdRefundRow row(
      int index, {
      bool? recoverable,
      bool failed = false,
    }) => PrivateUsdRefundRow(
      record: previewPrivateUsdReverseRecord(
        index: index,
        phase: ApiReversePhase.refunded,
      ),
      recoverable: recoverable,
      checkFailed: failed,
    );
    await pump(
      tester,
      MobilePrivateUsdRefundsView(
        state: PrivateUsdRefundsState(
          loaded: true,
          rows: [
            row(1),
            row(2, recoverable: true),
            row(3, recoverable: false),
            row(4, failed: true),
          ],
        ),
        onBack: () {},
        onRefresh: () {},
        onRecover: (_) {},
      ),
    );
    expect(find.text(PrivateUsdCopy.refundsChecking), findsOneWidget);
    expect(find.text(PrivateUsdCopy.refundsAvailable), findsOneWidget);
    expect(find.text(PrivateUsdCopy.refundsNoRecovery), findsOneWidget);
    expect(find.text(PrivateUsdCopy.refundsCheckFailed), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile_private_usd_refund_recover')),
      findsOneWidget,
    );

    await pump(
      tester,
      MobilePrivateUsdRefundsView(
        state: const PrivateUsdRefundsState(loaded: true),
        onBack: () {},
        onRefresh: () {},
        onRecover: (_) {},
      ),
    );
    expect(find.text(PrivateUsdCopy.refundsEmpty), findsOneWidget);
  });
}
