import 'package:flutter/widgets.dart';

import '../src/features/private_usd/models/private_usd_record_key.dart';
import '../src/features/private_usd/models/private_usd_reverse_presentation.dart';
import '../src/features/private_usd/private_usd_copy.dart';
import '../src/features/private_usd/providers/private_usd_convert_provider.dart';
import '../src/features/private_usd/providers/private_usd_refunds_provider.dart';
import '../src/features/private_usd/providers/private_usd_reverse_convert_provider.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_refunds_screen.dart';
import '../src/features/private_usd/services/private_usd_engine.dart';
import '../src/features/private_usd/services/private_usd_reverse_funding.dart';
import '../src/features/private_usd/widgets/mobile/private_usd_convert_views.dart';
import '../src/features/private_usd/widgets/mobile/private_usd_progress_views.dart';
import '../src/rust/api/private_usd.dart';
import 'private_usd_use_cases.dart';

// ── Reverse conversion and refunds ───────────────────────────────────────

const _ended = {
  ApiReversePhase.quoted,
  ApiReversePhase.complete,
  ApiReversePhase.refunded,
  ApiReversePhase.cancelled,
};

/// A reverse record of a $25.00 escrow (debit $25.31 with its fees) for
/// about 0.79985 ZEC, accepted [ago] before [previewPrivateUsdNow]. Its
/// flags follow its phase as Rust's would.
ApiReverseRecord previewPrivateUsdReverseRecord({
  int index = 9,
  ApiReversePhase phase = ApiReversePhase.receivingZec,
  bool? funded,
  bool cancelRequested = false,
  bool priced = true,
  int receiveConfirmations = 0,
  Duration ago = const Duration(minutes: 12),
  Duration readyIn = const Duration(minutes: 38),
}) {
  final acceptedAt = previewPrivateUsdNow.subtract(ago);
  final underWay = !_ended.contains(phase);
  final received =
      phase == ApiReversePhase.receiving || phase == ApiReversePhase.complete;
  final settled = received;
  final paid =
      funded ??
      !(phase == ApiReversePhase.quoted ||
          phase == ApiReversePhase.accepting ||
          phase == ApiReversePhase.awaitingFunding ||
          phase == ApiReversePhase.cancelled);
  final estimated =
      received ||
      phase == ApiReversePhase.awaitingReady ||
      phase == ApiReversePhase.settling;
  return ApiReverseRecord(
    index: index,
    swapId:
        '0x3c8e21f04a6d9b7c5e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d',
    phase: phase,
    amount: '25000000',
    networkCost: '30000',
    depositZat: BigInt.from(80000000),
    quoteExpiresAt: previewPrivateUsdUnix(
      acceptedAt.add(const Duration(minutes: 3)),
    ),
    fundingDeadline: previewPrivateUsdUnix(
      acceptedAt.add(const Duration(minutes: 15)),
    ),
    readyDeadline: previewPrivateUsdUnix(previewPrivateUsdNow.add(readyIn)),
    refundAfter: previewPrivateUsdUnix(
      previewPrivateUsdNow.add(const Duration(hours: 6)),
    ),
    cost: priced
        ? ApiReverseCost(
            debit: '25313282',
            railgunFee: '63282',
            broadcasterFee: '250000',
            feeExpiresAt: previewPrivateUsdUnix(
              acceptedAt.add(const Duration(minutes: 5)),
            ),
          )
        : null,
    funded: paid,
    fundingTx: paid
        ? '0x8d4f2a6c1e9b3d5f7a0c2e4b6d8f1a3c5e7b9d0f2a4c6e8b1d3f5a7c9e0b2d4f'
        : null,
    cancelRequested: cancelRequested,
    settled: settled,
    cancellable:
        underWay &&
        !cancelRequested &&
        !settled &&
        phase != ApiReversePhase.refunding &&
        phase != ApiReversePhase.refundPayout,
    awaitingUser:
        underWay &&
        !cancelRequested &&
        (phase == ApiReversePhase.awaitingFunding ||
            phase == ApiReversePhase.awaitingReady),
    receiveEstimateZat: estimated ? BigInt.from(79985000) : null,
    receiveFeeZat: estimated ? BigInt.from(15000) : null,
    receiveTxid: received
        ? '5b7d9f1a3c5e7092b4d6f8a0c2e4b6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c8e0'
        : null,
    receivedZat: received ? BigInt.from(79985000) : null,
    receiveConfirmations: receiveConfirmations,
    acceptedAt: phase == ApiReversePhase.quoted
        ? null
        : previewPrivateUsdUnix(acceptedAt),
    updatedAt: previewPrivateUsdUnix(
      previewPrivateUsdNow.subtract(const Duration(minutes: 1)),
    ),
  );
}

/// The reverse convert flow's state: $25 typed and priced.
PrivateUsdReverseConvertState previewPrivateUsdReverseConvertState({
  PrivateUsdConvertStep step = PrivateUsdConvertStep.amount,
}) => PrivateUsdReverseConvertState(
  now: previewPrivateUsdNow,
  // The total that funds the draft's $25.00 escrow with both fees.
  amountText: '25.32',
  draft: previewPrivateUsdReverseRecord(
    phase: ApiReversePhase.quoted,
    ago: Duration.zero,
  ),
  draftTotal: BigInt.from(25320000),
  step: step,
  available: BigInt.from(1250400000),
);

/// USD → ZEC with a priced quote: the ledger and its countdown.
Widget buildMobilePrivateUsdConvertReverseUseCase(BuildContext context) {
  final state = previewPrivateUsdReverseConvertState();
  return PrivateUsdPreviewFrame(
    child: PrivateUsdPreviewControllers(
      texts: [state.amountText],
      builder: (context, controllers) => MobilePrivateUsdReverseConvertView(
        state: state,
        controller: controllers.single,
        autofocus: false,
        onAmountChanged: (_) {},
        zecUsdPrice: 70,
        onMax: () {},
        onReview: () {},
        onBack: () {},
        onSwitchDirection: () {},
      ),
    ),
  );
}

/// The reverse review: the ledger, the keep-open note and its deadline.
Widget buildMobilePrivateUsdReviewReverseUseCase(BuildContext context) =>
    PrivateUsdPreviewFrame(
      child: MobilePrivateUsdReverseReviewView(
        state: previewPrivateUsdReverseConvertState(
          step: PrivateUsdConvertStep.review,
        ),
        privacyModeEnabled: false,
        onBack: () {},
        onConfirm: () {},
        onRefreshQuote: () {},
      ),
    );

Widget _reverseProgress(
  ApiReverseRecord record, {
  PrivateUsdFundingState? funding,
  double? proofProgress,
  String? message,
}) => PrivateUsdPreviewFrame(
  child: MobilePrivateUsdReverseConversionView(
    presentation: privateUsdReverseProgressPresentation(
      status: PrivateUsdReverseStatus(record: record),
      now: previewPrivateUsdNow,
      funding: funding,
      proofProgress: proofProgress,
      explorerTxPrefix: 'https://sepolia.etherscan.io/tx/',
    ),
    message: message,
    onBack: () {},
    onInfo: () {},
    onRetry: () {},
    onAction: () {},
    onCallOff: () {},
    onViewRefunds: () {},
  ),
);

/// `awaitingFunding` after the fees changed: the new total to pay.
Widget buildMobilePrivateUsdReverseFundingUseCase(BuildContext context) =>
    _reverseProgress(
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.awaitingFunding),
      message: PrivateUsdCopy.reverseErrorCostChanged,
    );

/// The payment proving in the page: its progress and keep-open note.
Widget buildMobilePrivateUsdReverseProvingUseCase(BuildContext context) =>
    _reverseProgress(
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.awaitingFunding),
      funding: const PrivateUsdFundingState(
        stage: PrivateUsdFundingStage.proving,
      ),
      proofProgress: 0.42,
    );

/// The deposit is confirmed: settlement waits for the user.
Widget buildMobilePrivateUsdReverseReadyUseCase(BuildContext context) =>
    _reverseProgress(
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.awaitingReady),
    );

/// Settlement authorized: the refundAfter note.
Widget buildMobilePrivateUsdReverseSettlingUseCase(BuildContext context) =>
    _reverseProgress(
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.settling),
    );

/// The sweep home: its Zcash confirmations.
Widget buildMobilePrivateUsdReverseReceivingUseCase(BuildContext context) =>
    _reverseProgress(
      previewPrivateUsdReverseRecord(
        phase: ApiReversePhase.receiving,
        receiveConfirmations: 1,
      ),
    );

/// ZEC received.
Widget buildMobilePrivateUsdReverseCompleteUseCase(BuildContext context) =>
    _reverseProgress(
      previewPrivateUsdReverseRecord(
        phase: ApiReversePhase.complete,
        receiveConfirmations: 2,
      ),
    );

/// A refund was requested and waits for its turn.
Widget buildMobilePrivateUsdReverseRefundWaitUseCase(BuildContext context) =>
    _reverseProgress(
      previewPrivateUsdReverseRecord(
        phase: ApiReversePhase.refundWait,
        cancelRequested: true,
      ),
    );

/// Refunded, with the way to the refunds.
Widget buildMobilePrivateUsdReverseRefundedUseCase(BuildContext context) =>
    _reverseProgress(
      previewPrivateUsdReverseRecord(phase: ApiReversePhase.refunded),
    );

Widget _refunds(PrivateUsdRefundsState state) => PrivateUsdPreviewFrame(
  child: MobilePrivateUsdRefundsView(
    state: state,
    onBack: () {},
    onRefresh: () {},
    onRecover: (_) {},
  ),
);

/// The Refunds screen's rows: checking, recoverable, none and check failed.
Widget buildMobilePrivateUsdRefundsUseCase(BuildContext context) => _refunds(
  PrivateUsdRefundsState(
    loaded: true,
    refreshing: true,
    rows: [
      for (final (i, row) in const [
        (null, false),
        (true, false),
        (false, false),
        (null, true),
      ].indexed)
        PrivateUsdRefundRow(
          record: previewPrivateUsdReverseRecord(
            index: 20 - i,
            phase: ApiReversePhase.refunded,
            ago: Duration(days: i * 3 + 1),
          ),
          recoverable: row.$1,
          checkFailed: row.$2,
        ),
    ],
  ),
);

/// No refunded conversions yet.
Widget buildMobilePrivateUsdRefundsEmptyUseCase(BuildContext context) =>
    _refunds(const PrivateUsdRefundsState(loaded: true));

/// The home banner's reverse conversion: settlement waits for the user, so
/// it asks for attention.
Map<PrivateUsdRecordKey, PrivateUsdReverseStatus>
previewPrivateUsdReverseAttention(String accountUuid) => {
  PrivateUsdRecordKey(
    accountUuid: accountUuid,
    direction: PrivateUsdDirection.reverse,
    index: 9,
  ): PrivateUsdReverseStatus(
    record: previewPrivateUsdReverseRecord(
      phase: ApiReversePhase.awaitingReady,
    ),
  ),
};
