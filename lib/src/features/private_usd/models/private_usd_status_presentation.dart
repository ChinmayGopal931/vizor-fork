import '../../../core/config/zcash_explorer.dart';
import '../../../core/formatting/date_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/privacy/privacy_mask.dart';
import '../../../rust/api/private_usd.dart';
import '../../swap/domain/swap_asset.dart';
import '../../swap/models/swap_activity_status_mapper.dart';
import '../../swap/models/swap_status_presentation.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_balance_repository.dart';
import '../services/private_usd_engine.dart';
import 'private_usd_balances.dart';

/// What the forward progress screen offers once a conversion ended.
enum PrivateUsdProgressAction { viewBalance, tryAgain }

/// A Zcash block every 75 s, for the confirmations estimate.
const _zcashBlock = Duration(seconds: 75);

/// An opening that takes longer than this offers "Call it off".
const kPrivateUsdSlowOpening = Duration(seconds: 90);

/// The balance is read this long after a payout before it can show it.
const _payoutSettles = Duration(seconds: 30);

/// Everything the forward progress screen shows for one conversion (plan
/// reference §9.5): the step list (as vizor's swap status presentation, so
/// the timeline UI stays single-sourced), and the note, problem, result and
/// action around it.
class PrivateUsdProgressPresentation {
  const PrivateUsdProgressPresentation({
    required this.status,
    required this.payAmountText,
    required this.receiveAmountText,
    required this.amountsText,
    this.note,
    this.problem,
    this.resultTitle,
    this.resultBody,
    this.showsCallOff = false,
    this.showsKeepOpen = false,
    this.action,
    this.keyStepPending = false,
    this.title = PrivateUsdCopy.convertProgressTitle,
    this.bridged = false,
  });

  final SwapActivityStatusPresentation status;
  final String payAmountText;
  final String receiveAmountText;

  /// "{ZEC} for about {$}".
  final String amountsText;
  final String? note;

  /// The problem card's message, once steps have failed for a minute.
  final String? problem;
  final String? resultTitle;
  final String? resultBody;

  /// "Call it off": an opening that has taken over 90 s, with no problem.
  final bool showsCallOff;

  /// "Keep Vizor open until this finishes" (D9).
  final bool showsKeepOpen;
  final PrivateUsdProgressAction? action;

  /// A key-using step (deposit, claim, sweep) is still to come: the screen
  /// stays awake while this progress shows (X8).
  final bool keyStepPending;

  /// The top bar's: "Bridging" while it runs (screening included),
  /// "Bridge" once it ended.
  final String title;

  /// It finished, screened: the "Bridged" sign in place of the result card.
  final bool bridged;
}

/// The forward progress for [status] at [now]. [balance] is the account's
/// private balance (whether a payout arrived and was screened);
/// [zcashConfirmations] and [screening] come from the deployment.
PrivateUsdProgressPresentation privateUsdProgressPresentation({
  required PrivateUsdConversionStatus status,
  required DateTime now,
  required int zcashConfirmations,
  required Duration screening,
  PrivateUsdBalanceState? balance,
  bool privacyModeEnabled = false,
  String? explorerTxPrefix,
}) {
  final record = status.record;
  final totalZat = record.maxTotalZat ?? record.depositZat;
  final zecText = privacyModeEnabled
      ? fixedPrivacyMask()
      : ZecAmount.fromZatoshi(totalZat).activity.toString();
  final receives = BigInt.parse(record.receives);
  final usdText = privacyModeEnabled
      ? fixedPrivacyMask()
      : formatPrivateUsd(receives);
  final amountsText = PrivateUsdCopy.convertProgressAmounts(zecText, usdText);
  final details = _details(record, explorerTxPrefix: explorerTxPrefix);

  SwapActivityStatusPresentation presentation({
    required List<SwapStatusStepData> steps,
    required int progressIndex,
    required SwapStatusBadgeKind badgeKind,
    bool showTabs = true,
  }) => SwapActivityStatusPresentation(
    title: PrivateUsdCopy.convertProgressTitle,
    payAsset: SwapAsset.zec,
    receiveAsset: SwapAsset.usdc,
    payFiatText: '',
    receiveFiatText: '',
    payAmountText: zecText,
    receiveAmountText: usdText,
    // A finished bridge's amounts are no longer an estimate.
    payLabel: badgeKind == SwapStatusBadgeKind.completed
        ? PrivateUsdCopy.bridgedYouPaid
        : PrivateUsdCopy.convertYouPay,
    receiveLabel: badgeKind == SwapStatusBadgeKind.completed
        ? PrivateUsdCopy.bridgedYouReceived
        : PrivateUsdCopy.convertYouReceive,
    badgeKind: badgeKind,
    progressIndex: progressIndex,
    steps: steps,
    details: details,
    progressTabLabel: PrivateUsdCopy.progressTab,
    // Every row is one of the conversion's own (swap ID, its transactions,
    // when it started): all of them show while it runs.
    allDetailsInProgress: true,
    showTabs: showTabs,
  );

  PrivateUsdProgressPresentation ended({
    required SwapStatusBadgeKind badgeKind,
    required String title,
    required String body,
    required PrivateUsdProgressAction action,
    List<SwapStatusStepData> steps = const [],
    int progressIndex = 0,
  }) => PrivateUsdProgressPresentation(
    status: presentation(
      steps: steps,
      progressIndex: progressIndex,
      badgeKind: badgeKind,
      showTabs: steps.isNotEmpty,
    ),
    payAmountText: zecText,
    receiveAmountText: usdText,
    amountsText: amountsText,
    resultTitle: title,
    resultBody: body,
    action: action,
    title: badgeKind == SwapStatusBadgeKind.liveQuote
        ? PrivateUsdCopy.convertProgressTitle
        : PrivateUsdCopy.bridgeEndedTitle,
    bridged: badgeKind == SwapStatusBadgeKind.completed,
  );

  switch (record.outcome) {
    case ApiForwardOutcome.paid:
      final about = PrivateUsdCopy.about(screening);
      final endedAt = record.endedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(record.endedAt! * 1000);
      final updatedAt = balance?.updatedAt;
      final synced =
          updatedAt != null &&
          (endedAt == null || !updatedAt.isBefore(endedAt.add(_payoutSettles)));
      final arriving = balance?.balances?.arriving ?? BigInt.zero;
      if (synced && arriving == BigInt.zero) {
        return ended(
          badgeKind: SwapStatusBadgeKind.completed,
          title: PrivateUsdCopy.convertResultPaidTitle,
          body: PrivateUsdCopy.convertResultScreenedBody(usdText),
          action: PrivateUsdProgressAction.viewBalance,
        );
      }
      final active = synced ? 5 : 4;
      return ended(
        badgeKind: SwapStatusBadgeKind.liveQuote,
        title: PrivateUsdCopy.convertResultPaidTitle,
        body: PrivateUsdCopy.convertResultPaidBody(usdText, about),
        action: PrivateUsdProgressAction.viewBalance,
        steps: _forwardSteps(
          active: active,
          description: active == 5 ? about : PrivateUsdCopy.convertEtaMinute,
        ),
        progressIndex: active,
      );
    case ApiForwardOutcome.refunded:
      return ended(
        badgeKind: SwapStatusBadgeKind.refunded,
        title: PrivateUsdCopy.convertResultRefundedTitle,
        body: privateUsdRefundedMessage(record.refundCause),
        action: PrivateUsdProgressAction.tryAgain,
      );
    case ApiForwardOutcome.nothingSent:
      return ended(
        badgeKind: SwapStatusBadgeKind.failed,
        title: PrivateUsdCopy.convertResultNothingTitle,
        body: privateUsdNothingSentMessage(record.nothingSentCause),
        action: PrivateUsdProgressAction.tryAgain,
      );
    case null:
      break;
  }

  final problem = status.problem;
  final syncing = status.wait == ApiForwardWait.zcashSyncing;
  final refunding =
      record.phase == ApiForwardPhase.refunding ||
      status.wait == ApiForwardWait.refunding ||
      status.activity == ApiActivity.sweeping;

  final List<SwapStatusStepData> steps;
  final int active;
  if (refunding) {
    active = 0;
    steps = [
      SwapStatusStepData(
        title: PrivateUsdCopy.convertStepRefund,
        state: SwapStatusStepState.active,
        description: syncing ? PrivateUsdCopy.convertWaitSyncing : null,
      ),
    ];
  } else {
    active = privateUsdForwardStepIndex(status);
    steps = _forwardSteps(
      active: active,
      description: syncing
          ? PrivateUsdCopy.convertWaitSyncing
          : switch (active) {
              0 || 3 => PrivateUsdCopy.convertEtaMinute,
              1 => PrivateUsdCopy.convertEtaSeconds,
              2 => _confirmationsDetail(
                record.depositConfirmations,
                zcashConfirmations,
              ),
              _ => null,
            },
    );
  }

  final opening =
      status.wait == ApiForwardWait.opening ||
      (status.wait == null && record.phase == ApiForwardPhase.opening);
  final acceptedAt = DateTime.fromMillisecondsSinceEpoch(
    record.acceptedAt * 1000,
  );
  final slowOpening =
      opening && now.difference(acceptedAt) > kPrivateUsdSlowOpening;
  final t0 = record.t0 == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(record.t0! * 1000);
  final makerSilent =
      record.phase == ApiForwardPhase.confirming &&
      (record.depositConfirmations ?? 0) >= zcashConfirmations &&
      record.payoutTx == null &&
      t0 != null &&
      t0.isAfter(now);

  final String? note;
  if (status.resuming) {
    note = PrivateUsdCopy.convertResuming;
  } else if (refunding) {
    note = PrivateUsdCopy.convertRefunding;
  } else if (status.wait == ApiForwardWait.depositUnsettled) {
    note = PrivateUsdCopy.convertUnsettled;
  } else if (slowOpening) {
    note = PrivateUsdCopy.convertOpeningSlow;
  } else if (makerSilent) {
    note = PrivateUsdCopy.convertMakerSilent(formatDayMonthTime(t0));
  } else {
    note = null;
  }

  return PrivateUsdProgressPresentation(
    status: presentation(
      steps: steps,
      progressIndex: active,
      badgeKind: problem == null
          ? SwapStatusBadgeKind.liveQuote
          : SwapStatusBadgeKind.warning,
    ),
    payAmountText: zecText,
    receiveAmountText: usdText,
    amountsText: amountsText,
    note: note,
    problem: problem == null ? null : privateUsdProblemMessage(problem),
    showsCallOff: slowOpening && problem == null,
    showsKeepOpen: true,
    keyStepPending: true,
  );
}

/// The forward step a conversion under way is on: 0 opening, 1 sending ZEC,
/// 2 confirmations, 3 claiming (the running step's activity first).
int privateUsdForwardStepIndex(PrivateUsdConversionStatus status) {
  switch (status.activity) {
    case ApiActivity.depositing:
      return 1;
    case ApiActivity.claiming || ApiActivity.payingOut:
      return 3;
    default:
      break;
  }
  switch (status.wait) {
    case ApiForwardWait.opening:
      return 0;
    case ApiForwardWait.confirming || ApiForwardWait.depositUnsettled:
      return 2;
    default:
      break;
  }
  return switch (status.record.phase) {
    ApiForwardPhase.opening => 0,
    ApiForwardPhase.depositing => 1,
    ApiForwardPhase.confirming => 2,
    _ => 3,
  };
}

/// The banner's detail for a forward conversion under way: its step, with
/// the confirmation count while confirming ("Waiting for confirmations · 1
/// of 2").
String privateUsdForwardStageLabel(
  PrivateUsdConversionStatus status, {
  required int zcashConfirmations,
}) {
  final record = status.record;
  if (record.phase == ApiForwardPhase.refunding ||
      status.wait == ApiForwardWait.refunding ||
      status.activity == ApiActivity.sweeping) {
    return PrivateUsdCopy.convertStepRefund;
  }
  return switch (privateUsdForwardStepIndex(status)) {
    0 => PrivateUsdCopy.convertStepOpen,
    1 => PrivateUsdCopy.convertStepDeposit,
    2 => PrivateUsdCopy.activityDetail(
      PrivateUsdCopy.convertStepConfirm,
      PrivateUsdCopy.convertStepConfirmCount(
        record.depositConfirmations ?? 0,
        zcashConfirmations,
      ),
    ),
    _ => PrivateUsdCopy.convertStepClaim,
  };
}

List<SwapStatusStepData> _forwardSteps({
  required int active,
  String? description,
}) => [
  for (final (index, title) in const [
    PrivateUsdCopy.convertStepOpen,
    PrivateUsdCopy.convertStepDeposit,
    PrivateUsdCopy.convertStepConfirm,
    PrivateUsdCopy.convertStepClaim,
    PrivateUsdCopy.convertStepArrive,
    PrivateUsdCopy.convertStepScreen,
  ].indexed)
    SwapStatusStepData(
      title: title,
      state: index < active
          ? SwapStatusStepState.complete
          : index == active
          ? SwapStatusStepState.active
          : SwapStatusStepState.pending,
      description: index == active ? description : null,
    ),
];

String _confirmationsDetail(int? confirmations, int needed) {
  final count = (confirmations ?? 0).clamp(0, needed);
  final left = needed - count;
  final countText = PrivateUsdCopy.convertStepConfirmCount(count, needed);
  if (left <= 0) return countText;
  return PrivateUsdCopy.activityDetail(
    countText,
    PrivateUsdCopy.about(_zcashBlock * left),
  );
}

List<SwapStatusDetailRowData> _details(
  ApiForwardRecord record, {
  String? explorerTxPrefix,
}) {
  final deposit = record.depositTxid;
  final sweep = record.sweepTxid;
  final payout = record.payoutTx;
  return [
    SwapStatusDetailRowData(
      label: PrivateUsdCopy.detailSwapId,
      value: _short(record.swapId),
      copyable: true,
      copyText: record.swapId,
    ),
    if (deposit != null)
      SwapStatusDetailRowData(
        label: PrivateUsdCopy.detailDeposit,
        value: _short(privateUsdDisplayTxid(deposit)),
        copyable: true,
        copyText: privateUsdDisplayTxid(deposit),
      ),
    if (payout != null)
      SwapStatusDetailRowData(
        label: PrivateUsdCopy.detailPayout,
        value: _short(payout),
        copyable: true,
        copyText: payout,
        linkUri: explorerTxPrefix == null
            ? null
            : Uri.tryParse('$explorerTxPrefix$payout'),
      ),
    if (sweep != null)
      SwapStatusDetailRowData(
        label: PrivateUsdCopy.detailRefund,
        value: _short(privateUsdDisplayTxid(sweep)),
        copyable: true,
        copyText: privateUsdDisplayTxid(sweep),
      ),
    SwapStatusDetailRowData(
      label: PrivateUsdCopy.detailStarted,
      value: formatDayMonthTime(
        DateTime.fromMillisecondsSinceEpoch(record.acceptedAt * 1000),
      ),
    ),
  ];
}

/// A txid as explorers show it: records carry the wallet's internal
/// (protocol) byte order, as history rows do.
String privateUsdDisplayTxid(String internalTxid) =>
    zcashDisplayTxidHex(internalTxid, ZcashExplorerTxidOrder.protocol);

String _short(String value) => value.length <= 16
    ? value
    : '${value.substring(0, 8)}…${value.substring(value.length - 6)}';
