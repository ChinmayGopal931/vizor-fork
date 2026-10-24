import '../../../core/formatting/address_display.dart';
import '../../../core/formatting/date_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/privacy/privacy_mask.dart';
import '../../../rust/api/private_usd.dart';
import '../../swap/domain/swap_asset.dart';
import '../../swap/models/swap_activity_status_mapper.dart';
import '../../swap/models/swap_status_presentation.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_engine.dart';
import '../services/private_usd_reverse_funding.dart';
import 'private_usd_balances.dart';
import 'private_usd_explorer.dart';
import 'private_usd_messages.dart';
import 'private_usd_status_presentation.dart';

/// The reverse progress screen's main button.
enum PrivateUsdReverseAction { pay, authorizeSettlement, newConversion }

/// A signed `ready` holds for 120 s, so "Authorize settlement" stops being
/// offered this long before the ready deadline.
const kPrivateUsdReadyMargin = Duration(seconds: 120);

/// The sweep home's fee before the maker's ZEC is in: the estimate's floor.
final _sweepFeeFloor = BigInt.from(10000);

DateTime _at(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

/// "Authorize settlement" is a user action only, enabled in
/// `awaitingReady` (not called off) until `readyDeadline − 120 s` on the
/// device clock; Rust checks the chain's clock again as it signs.
bool privateUsdCanAuthorizeReady(ApiReverseRecord record, DateTime now) =>
    record.phase == ApiReversePhase.awaitingReady &&
    !record.cancelRequested &&
    now.isBefore(_at(record.readyDeadline).subtract(kPrivateUsdReadyMargin));

/// The settlement deadline the review and the keep-open note name.
DateTime privateUsdReadyBy(ApiReverseRecord record) =>
    _at(record.readyDeadline).subtract(kPrivateUsdReadyMargin);

/// What the user pays: the reviewed debit, else the escrow amount.
BigInt privateUsdReverseDebit(ApiReverseRecord record) =>
    BigInt.parse(record.cost?.debit ?? record.amount);

/// The ZEC figure: the sweep's own, else the reviewed estimate, else the
/// deposit less the sweep fee's floor.
BigInt privateUsdReverseReceivedZat(ApiReverseRecord record) {
  final estimate =
      record.receivedZat ??
      record.receiveEstimateZat ??
      record.depositZat - _sweepFeeFloor;
  return estimate.isNegative ? BigInt.zero : estimate;
}

/// The reverse step a conversion under way is on: 0 prepare, 1 fund, 2
/// deposit, 3 approve, 4 settle, 5 receive.
int privateUsdReverseStepIndex(ApiReverseRecord record) =>
    switch (record.phase) {
      ApiReversePhase.quoted || ApiReversePhase.accepting => 0,
      ApiReversePhase.awaitingFunding ||
      ApiReversePhase.sendingUsdc ||
      ApiReversePhase.confirmingEscrow => 1,
      ApiReversePhase.receivingZec => 2,
      ApiReversePhase.awaitingReady => 3,
      ApiReversePhase.settling => 4,
      _ => 5,
    };

/// The banner's and the activity row's detail for a reverse conversion.
String privateUsdReverseStageLabel(ApiReverseRecord record) =>
    switch (record.phase) {
      ApiReversePhase.quoted ||
      ApiReversePhase.accepting => PrivateUsdCopy.reverseAccepting,
      ApiReversePhase.awaitingFunding => PrivateUsdCopy.reverseReview,
      ApiReversePhase.sendingUsdc => PrivateUsdCopy.reverseSending,
      ApiReversePhase.confirmingEscrow => PrivateUsdCopy.reverseConfirming,
      ApiReversePhase.receivingZec => PrivateUsdCopy.reverseReceiving,
      ApiReversePhase.awaitingReady => PrivateUsdCopy.reverseReady,
      ApiReversePhase.settling => PrivateUsdCopy.reverseSettling,
      ApiReversePhase.receiving => PrivateUsdCopy.reverseSweeping,
      ApiReversePhase.complete => PrivateUsdCopy.reverseComplete,
      ApiReversePhase.refundWait => PrivateUsdCopy.reverseRefundWait,
      ApiReversePhase.refunding => PrivateUsdCopy.reverseRefunding,
      ApiReversePhase.refundPayout => PrivateUsdCopy.reversePayout,
      ApiReversePhase.refunded => PrivateUsdCopy.reverseRefunded,
      ApiReversePhase.cancelled => PrivateUsdCopy.reverseCancelled,
    };

/// Everything the reverse progress screen shows for one conversion.
class PrivateUsdReverseProgressPresentation {
  const PrivateUsdReverseProgressPresentation({
    required this.status,
    required this.payAmountText,
    required this.receiveAmountText,
    this.amountsText,
    this.note,
    this.problem,
    this.resultTitle,
    this.resultBody,
    this.action,
    this.actionLabel,
    this.actionEnabled = false,
    this.callOffLabel,
    this.callOffPaid = false,
    this.showsViewRefunds = false,
    this.showsKeepOpen = false,
    this.provingNote,
    this.title = PrivateUsdCopy.convertProgressTitle,
    this.bridged = false,
  });

  final SwapActivityStatusPresentation status;
  final String payAmountText;
  final String receiveAmountText;

  /// "{$} for about {ZEC} after fees"; null once refunded or cancelled.
  final String? amountsText;
  final String? note;

  /// The problem card's message, once steps have failed for a minute.
  final String? problem;
  final String? resultTitle;
  final String? resultBody;
  final PrivateUsdReverseAction? action;
  final String? actionLabel;
  final bool actionEnabled;

  /// [PrivateUsdCopy.reverseCancel] or [PrivateUsdCopy.reverseRequestRefund]
  /// while it can still be called off; null hides it.
  final String? callOffLabel;

  /// Private USD was paid already: the confirmation says a refund follows.
  final bool callOffPaid;
  final bool showsViewRefunds;

  /// The keep-open card shows: a key-using step is still to come.
  final bool showsKeepOpen;

  /// Under the steps while the page proves the payment.
  final String? provingNote;

  /// The top bar's: "Bridging" while it runs, "Bridge" once it ended.
  final String title;

  /// It finished: the "Bridged" sign in place of the result card.
  final bool bridged;
}

/// The reverse progress for [status] at [now]. [funding] is the funding's
/// state and [proofProgress] the page's proof (0..1) while it proves;
/// [busy] disables the actions while one of them runs. With
/// [bridgeAvailable] off, an ended conversion offers no new one.
PrivateUsdReverseProgressPresentation privateUsdReverseProgressPresentation({
  required PrivateUsdReverseStatus status,
  required DateTime now,
  PrivateUsdFundingState? funding,
  double? proofProgress,
  bool busy = false,
  bool privacyModeEnabled = false,
  String? explorerTxPrefix,
  bool bridgeAvailable = true,
}) {
  final record = status.record;
  final debit = privateUsdReverseDebit(record);
  final zat = privateUsdReverseReceivedZat(record);
  final usdText = privacyModeEnabled
      ? fixedPrivacyMask()
      : formatPrivateUsdNearest(debit);
  final zecText = privacyModeEnabled
      ? fixedPrivacyMask()
      : ZecAmount.fromZatoshi(zat).activity.toString();
  final details = _details(record, explorerTxPrefix: explorerTxPrefix);

  SwapActivityStatusPresentation presentation({
    required List<SwapStatusStepData> steps,
    required int progressIndex,
    required SwapStatusBadgeKind badgeKind,
    bool bridged = false,
  }) => privateUsdSwapStatus(
    payAsset: SwapAsset.usdc,
    receiveAsset: SwapAsset.zec,
    payAmountText: usdText,
    receiveAmountText: zecText,
    steps: steps,
    progressIndex: progressIndex,
    badgeKind: badgeKind,
    details: details,
    bridged: bridged,
  );

  PrivateUsdReverseProgressPresentation ended({
    required SwapStatusBadgeKind badgeKind,
    required String title,
    required String body,
    List<SwapStatusStepData> steps = const [],
    int progressIndex = 0,
    String? amounts,
    bool viewRefunds = false,
    bool bridged = false,
  }) => PrivateUsdReverseProgressPresentation(
    status: presentation(
      steps: steps,
      progressIndex: progressIndex,
      badgeKind: badgeKind,
      bridged: bridged,
    ),
    payAmountText: usdText,
    receiveAmountText: zecText,
    amountsText: amounts,
    resultTitle: title,
    resultBody: body,
    action: bridgeAvailable ? PrivateUsdReverseAction.newConversion : null,
    actionLabel: bridgeAvailable ? PrivateUsdCopy.reverseNew : null,
    actionEnabled: bridgeAvailable,
    showsViewRefunds: viewRefunds,
    title: PrivateUsdCopy.actionConvert,
    bridged: bridged,
  );

  switch (record.phase) {
    case ApiReversePhase.complete:
      return ended(
        badgeKind: SwapStatusBadgeKind.completed,
        title: PrivateUsdCopy.reverseResultReceived,
        body: PrivateUsdCopy.reverseProgressReceived(zecText),
        steps: _reverseSteps(active: 6),
        progressIndex: 6,
        amounts: PrivateUsdCopy.reverseProgressAmounts(usdText, zecText),
        bridged: true,
      );
    case ApiReversePhase.refunded:
      return ended(
        badgeKind: SwapStatusBadgeKind.refunded,
        title: PrivateUsdCopy.reverseResultRefunded,
        body: PrivateUsdCopy.reverseRefunded,
        viewRefunds: true,
      );
    case ApiReversePhase.cancelled:
      return ended(
        badgeKind: SwapStatusBadgeKind.failed,
        title: PrivateUsdCopy.reverseResultCancelled,
        body: PrivateUsdCopy.reverseCancelled,
      );
    default:
      break;
  }

  final problem = status.problem;
  final proving = funding?.stage == PrivateUsdFundingStage.proving;
  final running = funding?.running ?? false;
  // "Pay" is offered and not yet tapped: the step is the user's to take, not
  // a payment already going.
  final awaitingPay =
      record.phase == ApiReversePhase.awaitingFunding &&
      !record.cancelRequested &&
      !record.funded &&
      !running;
  final refundStep = switch (record.phase) {
    ApiReversePhase.refundWait => PrivateUsdCopy.reverseRefundWait,
    ApiReversePhase.refunding => PrivateUsdCopy.reverseRefunding,
    ApiReversePhase.refundPayout => PrivateUsdCopy.reversePayout,
    _ => null,
  };

  final List<SwapStatusStepData> steps;
  final int active;
  if (refundStep != null) {
    active = 0;
    steps = [
      SwapStatusStepData(title: refundStep, state: SwapStatusStepState.active),
    ];
  } else {
    active = privateUsdReverseStepIndex(record);
    steps = _reverseSteps(
      active: active,
      fundTitle: awaitingPay
          ? PrivateUsdCopy.reverseStepPay
          : PrivateUsdCopy.reverseStepFund,
      description: switch (record.phase) {
        ApiReversePhase.awaitingFunding when proving =>
          PrivateUsdCopy.paymentProving(
            ((proofProgress ?? 0) * 100).floor().clamp(0, 100),
          ),
        ApiReversePhase.awaitingFunding when awaitingPay =>
          PrivateUsdCopy.reverseStepPayDetail(usdText),
        ApiReversePhase.sendingUsdc => PrivateUsdCopy.reverseSending,
        ApiReversePhase.confirmingEscrow => PrivateUsdCopy.reverseConfirming,
        ApiReversePhase.awaitingReady =>
          PrivateUsdCopy.reverseStepApprovalDetail,
        ApiReversePhase.settling => PrivateUsdCopy.reverseSettling,
        ApiReversePhase.receiving => PrivateUsdCopy.reverseSweepConfirmations(
          record.receiveConfirmations,
        ),
        _ => null,
      },
    );
  }

  final String? note;
  if (status.resuming) {
    note = PrivateUsdCopy.convertResuming;
  } else if (record.cancelRequested && refundStep != null) {
    note = PrivateUsdCopy.reverseRefundRequested;
  } else if (record.phase == ApiReversePhase.awaitingReady) {
    note = PrivateUsdCopy.reverseReadyExplanation;
  } else if (record.phase == ApiReversePhase.settling) {
    note = PrivateUsdCopy.reverseSettlementRefundLimit(
      formatDayMonthTime(_at(record.refundAfter)),
    );
  } else {
    note = null;
  }

  final PrivateUsdReverseAction? action;
  final String? actionLabel;
  final bool actionEnabled;
  if (record.phase == ApiReversePhase.awaitingFunding &&
      !record.cancelRequested &&
      !record.funded) {
    action = PrivateUsdReverseAction.pay;
    actionLabel = PrivateUsdCopy.reversePay(usdText);
    actionEnabled = record.cost != null && !running && !busy;
  } else if (record.phase == ApiReversePhase.awaitingReady &&
      !record.cancelRequested) {
    action = PrivateUsdReverseAction.authorizeSettlement;
    actionLabel = PrivateUsdCopy.reverseReady;
    actionEnabled = privateUsdCanAuthorizeReady(record, now) && !busy;
  } else {
    action = null;
    actionLabel = null;
    actionEnabled = false;
  }

  final unpaid =
      !record.funded &&
      (record.phase == ApiReversePhase.accepting ||
          record.phase == ApiReversePhase.awaitingFunding);

  return PrivateUsdReverseProgressPresentation(
    status: presentation(
      steps: steps,
      progressIndex: active,
      badgeKind: problem == null
          ? SwapStatusBadgeKind.liveQuote
          : SwapStatusBadgeKind.warning,
    ),
    payAmountText: usdText,
    receiveAmountText: zecText,
    amountsText: record.receivedZat == null
        ? PrivateUsdCopy.reverseProgressEstimate(usdText, zecText)
        : PrivateUsdCopy.reverseProgressAmounts(usdText, zecText),
    note: note,
    problem: problem == null ? null : privateUsdReverseProblemMessage(problem),
    action: action,
    actionLabel: actionLabel,
    actionEnabled: actionEnabled,
    callOffLabel: record.cancellable
        ? (unpaid
              ? PrivateUsdCopy.reverseCancel
              : PrivateUsdCopy.reverseRequestRefund)
        : null,
    callOffPaid: !unpaid,
    showsKeepOpen: true,
    provingNote: proving ? PrivateUsdCopy.reverseProvingNote : null,
  );
}

List<SwapStatusStepData> _reverseSteps({
  required int active,
  String? description,
  String fundTitle = PrivateUsdCopy.reverseStepFund,
}) => privateUsdProgressSteps(
  [
    PrivateUsdCopy.reverseAccepting,
    fundTitle,
    PrivateUsdCopy.reverseReceiving,
    PrivateUsdCopy.reverseReady,
    PrivateUsdCopy.reverseStepSettle,
    PrivateUsdCopy.reverseSweeping,
  ],
  active: active,
  description: description,
);

List<SwapStatusDetailRowData> _details(
  ApiReverseRecord record, {
  String? explorerTxPrefix,
}) {
  final funding = record.fundingTx;
  final receive = record.receiveTxid;
  final acceptedAt = record.acceptedAt;
  return [
    SwapStatusDetailRowData(
      label: PrivateUsdCopy.detailSwapId,
      value: truncatedTxid(record.swapId),
      copyable: true,
      copyText: record.swapId,
    ),
    if (funding != null)
      SwapStatusDetailRowData(
        label: PrivateUsdCopy.detailFunding,
        value: truncatedTxid(funding),
        copyable: true,
        copyText: funding,
        linkUri: privateUsdExplorerUri(explorerTxPrefix, funding),
      ),
    if (receive != null)
      SwapStatusDetailRowData(
        label: PrivateUsdCopy.detailZecReceived,
        value: truncatedTxid(privateUsdDisplayTxid(receive)),
        copyable: true,
        copyText: privateUsdDisplayTxid(receive),
      ),
    if (acceptedAt != null)
      SwapStatusDetailRowData(
        label: PrivateUsdCopy.detailStarted,
        value: formatDayMonthTime(_at(acceptedAt)),
      ),
  ];
}
