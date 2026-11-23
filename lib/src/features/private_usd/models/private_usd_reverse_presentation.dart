import '../../../core/l10n/l10n.dart';
import '../../../core/formatting/address_display.dart';
import '../../../core/layout/app_form_factor.dart' show kDesktopFormFactor;
import '../../../core/formatting/date_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/privacy/privacy_mask.dart';
import '../../../rust/api/private_usd.dart';
import '../../swap/domain/swap_asset.dart';
import '../../swap/models/swap_activity_status_mapper.dart';
import '../../swap/models/swap_status_presentation.dart';
import '../services/private_usd_engine.dart';
import '../services/private_usd_reverse_funding.dart';
import 'private_usd_balances.dart';
import 'private_usd_desktop_wording.dart';
import 'private_usd_explorer.dart';
import 'private_usd_fees.dart';
import 'private_usd_messages.dart';
import 'private_usd_status_presentation.dart';

/// The reverse progress screen's main button.
enum PrivateUsdReverseAction { pay, authorizeSettlement, newConversion }

/// A signed `ready` holds for 120 s, so "Authorize settlement" stops being
/// offered this long before the ready deadline.
const kPrivateUsdReadyMargin = Duration(seconds: 120);

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
/// deposit less the sweep fee's floor before the maker's ZEC is in: ZIP 317's
/// least fee, [sweepFeeFloorZat] (`privateUsdLeastFeeZatProvider`), which NU7
/// lowers.
BigInt privateUsdReverseReceivedZat(
  ApiReverseRecord record, {
  BigInt? sweepFeeFloorZat,
}) {
  final estimate =
      record.receivedZat ??
      record.receiveEstimateZat ??
      record.depositZat - (sweepFeeFloorZat ?? kPrivateUsdPreNu7LeastFeeZat);
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
String privateUsdReverseStageLabel(
  AppLocalizations l10n,
  ApiReverseRecord record,
) => switch (record.phase) {
  ApiReversePhase.quoted ||
  ApiReversePhase.accepting => l10n.privateUsdReverseAccepting,
  ApiReversePhase.awaitingFunding => l10n.privateUsdReverseReview,
  ApiReversePhase.sendingUsdc => l10n.privateUsdReverseSending,
  ApiReversePhase.confirmingEscrow => l10n.privateUsdReverseConfirming,
  ApiReversePhase.receivingZec => l10n.privateUsdReverseReceiving,
  ApiReversePhase.awaitingReady => l10n.privateUsdReverseReady,
  ApiReversePhase.settling => l10n.privateUsdReverseSettling,
  ApiReversePhase.receiving => l10n.privateUsdReverseSweeping,
  ApiReversePhase.complete => l10n.privateUsdReverseComplete,
  ApiReversePhase.refundWait when record.cancellable =>
    l10n.privateUsdReverseRefundReady,
  ApiReversePhase.refundWait => l10n.privateUsdReverseRefundWait,
  ApiReversePhase.refunding => l10n.privateUsdReverseRefunding,
  ApiReversePhase.refundPayout => l10n.privateUsdReversePayout,
  ApiReversePhase.refunded => l10n.privateUsdReverseRefunded,
  ApiReversePhase.cancelled => l10n.privateUsdReverseCancelled,
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
    required this.title,
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

  /// [AppLocalizations.privateUsdReverseCancel] or
  /// [AppLocalizations.privateUsdReverseRequestRefund] while it can still be
  /// called off; null hides it.
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
PrivateUsdReverseProgressPresentation privateUsdReverseProgressPresentation(
  AppLocalizations l10n, {
  required PrivateUsdReverseStatus status,
  required DateTime now,
  PrivateUsdFundingState? funding,
  double? proofProgress,
  bool busy = false,
  bool privacyModeEnabled = false,
  String? explorerTxPrefix,
  bool bridgeAvailable = true,
  BigInt? sweepFeeFloorZat,
}) {
  final record = status.record;
  final debit = privateUsdReverseDebit(record);
  final zat = privateUsdReverseReceivedZat(
    record,
    sweepFeeFloorZat: sweepFeeFloorZat,
  );
  final usdText = privacyModeEnabled
      ? fixedPrivacyMask()
      : formatPrivateUsdNearest(debit);
  final zecText = privacyModeEnabled
      ? fixedPrivacyMask()
      : ZecAmount.fromZatoshi(zat).activity.toString();
  final details = _details(l10n, record, explorerTxPrefix: explorerTxPrefix);

  SwapActivityStatusPresentation presentation({
    required List<SwapStatusStepData> steps,
    required int progressIndex,
    required SwapStatusBadgeKind badgeKind,
    bool bridged = false,
  }) => privateUsdSwapStatus(
    l10n,
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
    actionLabel: bridgeAvailable ? l10n.privateUsdReverseNew : null,
    actionEnabled: bridgeAvailable,
    showsViewRefunds: viewRefunds,
    title: l10n.privateUsdActionConvert,
    bridged: bridged,
  );

  switch (record.phase) {
    case ApiReversePhase.complete:
      return ended(
        badgeKind: SwapStatusBadgeKind.completed,
        title: l10n.privateUsdReverseResultReceived,
        body: l10n.privateUsdReverseProgressReceived(zecText),
        steps: _reverseSteps(l10n, active: 6),
        progressIndex: 6,
        amounts: l10n.privateUsdReverseProgressAmounts(usdText, zecText),
        bridged: true,
      );
    case ApiReversePhase.refunded:
      return ended(
        badgeKind: SwapStatusBadgeKind.refunded,
        title: l10n.privateUsdReverseResultRefunded,
        body: l10n.privateUsdReverseRefunded,
        viewRefunds: true,
      );
    case ApiReversePhase.cancelled:
      return ended(
        badgeKind: SwapStatusBadgeKind.failed,
        title: l10n.privateUsdReverseResultCancelled,
        body: l10n.privateUsdReverseCancelled,
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
    // Too late to settle: the refund is the user's to request now.
    ApiReversePhase.refundWait when record.cancellable =>
      l10n.privateUsdReverseRefundReady,
    ApiReversePhase.refundWait => l10n.privateUsdReverseRefundWait,
    ApiReversePhase.refunding => l10n.privateUsdReverseRefunding,
    ApiReversePhase.refundPayout => l10n.privateUsdReversePayout,
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
      l10n,
      active: active,
      fundTitle: awaitingPay
          ? l10n.privateUsdReverseStepPay
          : l10n.privateUsdReverseStepFund,
      description: switch (record.phase) {
        ApiReversePhase.awaitingFunding when proving =>
          l10n.privateUsdPaymentProving(
            ((proofProgress ?? 0) * 100).floor().clamp(0, 100),
          ),
        // The Mac's Pay is clicked, not tapped.
        ApiReversePhase.awaitingFunding when awaitingPay =>
          kDesktopFormFactor
              ? l10n.privateUsdReverseStepPayDetailDesktop(usdText)
              : l10n.privateUsdReverseStepPayDetail(usdText),
        ApiReversePhase.sendingUsdc => l10n.privateUsdReverseSending,
        ApiReversePhase.confirmingEscrow => l10n.privateUsdReverseConfirming,
        ApiReversePhase.awaitingReady =>
          l10n.privateUsdReverseStepApprovalDetail,
        ApiReversePhase.settling => l10n.privateUsdReverseSettling,
        ApiReversePhase.receiving => l10n.privateUsdReverseSweepConfirmations(
          record.receiveConfirmations,
        ),
        _ => null,
      },
    );
  }

  final String? note;
  if (status.resuming) {
    note = l10n.privateUsdConvertResuming;
  } else if (record.cancelRequested && refundStep != null) {
    note = l10n.privateUsdReverseRefundRequested;
  } else if (record.phase == ApiReversePhase.refundWait && record.cancellable) {
    // It goes by itself from t0.
    note = l10n.privateUsdReverseRefundAvailable(
      formatDayMonthTime(_at(record.readyDeadline), l10n.localeName),
    );
  } else if (record.phase == ApiReversePhase.awaitingReady) {
    note = l10n.privateUsdReverseReadyExplanation;
  } else if (record.phase == ApiReversePhase.settling) {
    note = l10n.privateUsdReverseSettlementRefundLimit(
      formatDayMonthTime(_at(record.refundAfter), l10n.localeName),
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
    actionLabel = l10n.privateUsdReversePay(usdText);
    actionEnabled = record.cost != null && !running && !busy;
  } else if (record.phase == ApiReversePhase.awaitingReady &&
      !record.cancelRequested) {
    action = PrivateUsdReverseAction.authorizeSettlement;
    actionLabel = l10n.privateUsdReverseReady;
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
        ? l10n.privateUsdReverseProgressEstimate(usdText, zecText)
        : l10n.privateUsdReverseProgressAmounts(usdText, zecText),
    note: note,
    problem: problem == null
        ? null
        : privateUsdReverseProblemMessage(l10n, problem),
    action: action,
    actionLabel: actionLabel,
    actionEnabled: actionEnabled,
    callOffLabel: record.cancellable
        ? (unpaid
              ? l10n.privateUsdReverseCancel
              : l10n.privateUsdReverseRequestRefund)
        : null,
    callOffPaid: !unpaid,
    showsKeepOpen: true,
    // On desktop the window must stay visible: WebKit suspends the page that
    // proves while it is hidden.
    provingNote: proving
        ? (kDesktopFormFactor
              ? (privateUsdComputerWording
                    ? l10n.privateUsdReverseProvingNoteLinux
                    : l10n.privateUsdReverseProvingNoteDesktop)
              : l10n.privateUsdReverseProvingNote)
        : null,
    title: l10n.privateUsdConvertProgressTitle,
  );
}

List<SwapStatusStepData> _reverseSteps(
  AppLocalizations l10n, {
  required int active,
  String? description,
  String? fundTitle,
}) => privateUsdProgressSteps(
  [
    l10n.privateUsdReverseAccepting,
    fundTitle ?? l10n.privateUsdReverseStepFund,
    l10n.privateUsdReverseReceiving,
    l10n.privateUsdReverseReady,
    l10n.privateUsdReverseStepSettle,
    l10n.privateUsdReverseSweeping,
  ],
  active: active,
  description: description,
);

List<SwapStatusDetailRowData> _details(
  AppLocalizations l10n,
  ApiReverseRecord record, {
  String? explorerTxPrefix,
}) {
  final funding = record.fundingTx;
  final receive = record.receiveTxid;
  final acceptedAt = record.acceptedAt;
  return [
    SwapStatusDetailRowData(
      label: l10n.privateUsdDetailSwapId,
      value: truncatedTxid(record.swapId),
      copyable: true,
      copyText: record.swapId,
    ),
    if (funding != null)
      SwapStatusDetailRowData(
        label: l10n.privateUsdDetailFunding,
        value: truncatedTxid(funding),
        copyable: true,
        copyText: funding,
        linkUri: privateUsdExplorerUri(explorerTxPrefix, funding),
      ),
    if (receive != null)
      SwapStatusDetailRowData(
        label: l10n.privateUsdDetailZecReceived,
        value: truncatedTxid(privateUsdDisplayTxid(receive)),
        copyable: true,
        copyText: privateUsdDisplayTxid(receive),
      ),
    if (acceptedAt != null)
      SwapStatusDetailRowData(
        label: l10n.privateUsdDetailStarted,
        value: formatDayMonthTime(_at(acceptedAt), l10n.localeName),
      ),
  ];
}
