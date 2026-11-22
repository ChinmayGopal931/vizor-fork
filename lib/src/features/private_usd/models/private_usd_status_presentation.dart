import '../../../core/l10n/l10n.dart';
import '../../../core/config/zcash_explorer.dart';
import '../../../core/formatting/address_display.dart';
import '../../../core/formatting/date_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/privacy/privacy_mask.dart';
import '../../../core/zcash/block_spacing.dart';
import '../../../rust/api/private_usd.dart';
import '../../swap/domain/swap_asset.dart';
import '../../swap/models/swap_activity_status_mapper.dart';
import '../../swap/models/swap_status_presentation.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_balance_repository.dart';
import '../services/private_usd_engine.dart';
import 'private_usd_balances.dart';
import 'private_usd_explorer.dart';
import 'private_usd_messages.dart';

/// What the forward progress screen offers once a conversion ended.
enum PrivateUsdProgressAction { viewBalance, tryAgain }

/// An opening that takes longer than this offers "Call it off".
const kPrivateUsdSlowOpening = Duration(seconds: 90);

/// The balance is read this long after a payout before it can show it.
const _payoutSettles = Duration(seconds: 30);

/// Everything the forward progress screen shows for one conversion: the step
/// list (as the swap status presentation, so the timeline UI stays
/// single-sourced), and the note, problem, result and action around it.
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
    required this.title,
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

  /// The keep-open card shows: a key-using step (deposit, claim, sweep) is
  /// still to come, and not the relayer's.
  final bool showsKeepOpen;
  final PrivateUsdProgressAction? action;

  /// The top bar's: "Bridging" while it runs (screening included),
  /// "Bridge" once it ended.
  final String title;

  /// It finished, screened: the "Bridged" sign in place of the result card.
  final bool bridged;
}

/// The forward progress for [status] at [now]. [balance] is the account's
/// private balance (whether a payout arrived and was screened);
/// [zcashConfirmations] and [screening] come from the deployment. With
/// [bridgeAvailable] off, an ended conversion offers no new one.
/// [relayerClaims] is the relayer-claims setting, which a bridge takes as it
/// starts: until its claim is handed over, the only sign that the relayer is
/// to claim it.
PrivateUsdProgressPresentation privateUsdProgressPresentation(
  AppLocalizations l10n, {
  required PrivateUsdConversionStatus status,
  required DateTime now,
  required int zcashConfirmations,
  required Duration screening,
  PrivateUsdBalanceState? balance,
  bool privacyModeEnabled = false,
  String? explorerTxPrefix,
  bool bridgeAvailable = true,
  bool relayerClaims = false,
  BlockTimeEstimate blockTimes = BlockTimeEstimate.preNu7,
}) {
  final record = status.record;
  final zecText = privateUsdForwardPaidText(
    record,
    privacyModeEnabled: privacyModeEnabled,
  );
  final receives = BigInt.parse(record.receives);
  final usdText = privacyModeEnabled
      ? fixedPrivacyMask()
      : formatPrivateUsd(receives);
  final amountsText = l10n.privateUsdConvertProgressAmounts(zecText, usdText);
  final details = _details(l10n, record, explorerTxPrefix: explorerTxPrefix);

  SwapActivityStatusPresentation presentation({
    required List<SwapStatusStepData> steps,
    required int progressIndex,
    required SwapStatusBadgeKind badgeKind,
  }) => privateUsdSwapStatus(
    l10n,
    payAsset: SwapAsset.zec,
    receiveAsset: SwapAsset.usdc,
    payAmountText: zecText,
    receiveAmountText: usdText,
    steps: steps,
    progressIndex: progressIndex,
    badgeKind: badgeKind,
    details: details,
    bridged: badgeKind == SwapStatusBadgeKind.completed,
  );

  PrivateUsdProgressPresentation ended({
    required SwapStatusBadgeKind badgeKind,
    required String title,
    required String body,
    PrivateUsdProgressAction? action,
    List<SwapStatusStepData> steps = const [],
    int progressIndex = 0,
  }) => PrivateUsdProgressPresentation(
    status: presentation(
      steps: steps,
      progressIndex: progressIndex,
      badgeKind: badgeKind,
    ),
    payAmountText: zecText,
    receiveAmountText: usdText,
    amountsText: amountsText,
    resultTitle: title,
    resultBody: body,
    action: action,
    title: badgeKind == SwapStatusBadgeKind.liveQuote
        ? l10n.privateUsdConvertProgressTitle
        : l10n.privateUsdActionConvert,
    bridged: badgeKind == SwapStatusBadgeKind.completed,
  );

  final tryAgain = bridgeAvailable ? PrivateUsdProgressAction.tryAgain : null;
  switch (record.outcome) {
    case ApiForwardOutcome.paid:
      final about = PrivateUsdCopy.about(l10n, screening);
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
          title: l10n.privateUsdConvertResultPaidTitle,
          body: l10n.privateUsdConvertResultScreenedBody(usdText),
          action: PrivateUsdProgressAction.viewBalance,
        );
      }
      final active = synced ? 5 : 4;
      return ended(
        badgeKind: SwapStatusBadgeKind.liveQuote,
        title: l10n.privateUsdConvertResultPaidTitle,
        body: l10n.privateUsdConvertResultPaidBody(usdText, about),
        action: PrivateUsdProgressAction.viewBalance,
        steps: _forwardSteps(
          l10n,
          active: active,
          description: active == 5 ? about : l10n.privateUsdConvertEtaMinute,
        ),
        progressIndex: active,
      );
    case ApiForwardOutcome.refunded:
      return ended(
        badgeKind: SwapStatusBadgeKind.refunded,
        title: l10n.privateUsdConvertResultRefundedTitle,
        body: privateUsdRefundedMessage(l10n, record.refundCause),
        action: tryAgain,
      );
    case ApiForwardOutcome.nothingSent:
      return ended(
        badgeKind: SwapStatusBadgeKind.failed,
        // A fee the maker keeps was sent: not "nothing".
        title: record.openFeeMined
            ? l10n.privateUsdActivityFeeLost
            : l10n.privateUsdConvertResultNothingTitle,
        body: privateUsdForwardNothingSentMessage(l10n, record),
        action: tryAgain,
      );
    case null:
      break;
  }

  final problem = status.problem;
  final syncing = status.wait == ApiForwardWait.zcashSyncing;
  // The fee's own waits, plainly, rather than an opening that looks stuck.
  final waitText = switch (status.wait) {
    ApiForwardWait.feeConfirming => l10n.privateUsdConvertWaitFeeConfirming,
    ApiForwardWait.feeAccepting => l10n.privateUsdConvertWaitFeeSeen,
    ApiForwardWait.fundsPending => l10n.privateUsdConvertWaitFunds,
    _ => null,
  };
  final refunding =
      record.phase == ApiForwardPhase.refunding ||
      status.wait == ApiForwardWait.refunding ||
      status.activity == ApiActivity.sweeping;
  final unwinding = !refunding && privateUsdForwardUnwinding(status);

  final List<SwapStatusStepData> steps;
  final int active;
  if (refunding) {
    active = 0;
    steps = [
      SwapStatusStepData(
        title: l10n.privateUsdConvertStepRefund,
        state: SwapStatusStepState.active,
        description: syncing ? l10n.privateUsdConvertWaitSyncing : null,
      ),
    ];
  } else if (unwinding) {
    // The maker's refund, then the ZEC home.
    active = 0;
    steps = privateUsdProgressSteps([
      l10n.privateUsdConvertStepUnwind,
      l10n.privateUsdConvertStepRefund,
    ], active: active);
  } else {
    active = privateUsdForwardStepIndex(status);
    steps = _forwardSteps(
      l10n,
      active: active,
      description: syncing
          ? l10n.privateUsdConvertWaitSyncing
          : waitText ??
                switch (active) {
                  0 || 3 => l10n.privateUsdConvertEtaMinute,
                  1 => l10n.privateUsdConvertEtaSeconds,
                  2 => _confirmationsDetail(
                    l10n,
                    record.depositConfirmations,
                    zcashConfirmations,
                    blockTimes,
                  ),
                  _ => null,
                },
    );
  }

  // An opening whose fee went out is not "nothing sent", and calling it off
  // would give the fee up: it waits for the maker, or for its quote's end.
  final opening =
      record.openFeeZat == null &&
      (status.wait == ApiForwardWait.opening ||
          (status.wait == null && record.phase == ApiForwardPhase.opening));
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

  final handedOver = status.claimHandedOver;
  // Its claim goes to the relayer once the market maker confirms the
  // deposit, so Veylor is needed only until then; a claim the relayer
  // declined is Veylor's own.
  final relayerToClaim =
      relayerClaims &&
      !handedOver &&
      !record.claimDeclined &&
      !refunding &&
      !unwinding &&
      active <= 2;
  final lateClaimAt = record.lateClaimAt;
  final String? note;
  if (status.resuming) {
    note = l10n.privateUsdConvertResuming;
  } else if (refunding) {
    note = l10n.privateUsdConvertRefunding;
  } else if (unwinding) {
    note = lateClaimAt == null
        ? l10n.privateUsdConvertUnwinding
        : l10n.privateUsdConvertUnwindingUntil(
            formatDayMonthTime(
              DateTime.fromMillisecondsSinceEpoch(lateClaimAt * 1000),
              l10n.localeName,
            ),
          );
  } else if (status.wait == ApiForwardWait.depositUnsettled) {
    note = l10n.privateUsdConvertUnsettled;
  } else if (slowOpening) {
    note = l10n.privateUsdConvertOpeningSlow;
  } else if (handedOver) {
    // Handed over only once the maker made the swap ready: never silent.
    note = l10n.privateUsdConvertRelayerClaims;
  } else if (makerSilent) {
    note = l10n.privateUsdConvertMakerSilent(
      formatDayMonthTime(t0, l10n.localeName),
    );
  } else if (relayerToClaim) {
    note = l10n.privateUsdConvertRelayerReviewNote;
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
    problem: problem == null ? null : privateUsdProblemMessage(l10n, problem),
    showsCallOff: slowOpening && problem == null,
    showsKeepOpen: !handedOver && !relayerToClaim,
    title: l10n.privateUsdConvertProgressTitle,
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
    case ApiForwardWait.opening ||
        ApiForwardWait.feeConfirming ||
        ApiForwardWait.feeAccepting:
      return 0;
    case ApiForwardWait.fundsPending:
      return 1;
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

/// Whether [status] waits as its swap unwinds: too late to claim before
/// `t1`, and from it the maker's to refund until `lateClaimAt`, with no claim
/// running. Its ZEC comes back after the maker's refund.
bool privateUsdForwardUnwinding(PrivateUsdConversionStatus status) =>
    status.wait == ApiForwardWait.unwinding &&
    status.activity != ApiActivity.claiming &&
    status.activity != ApiActivity.payingOut;

/// The banner's detail for a forward conversion under way: its step, with
/// the confirmation count while confirming ("Waiting for confirmations · 1
/// of 2").
String privateUsdForwardStageLabel(
  AppLocalizations l10n,
  PrivateUsdConversionStatus status, {
  required int zcashConfirmations,
}) {
  final record = status.record;
  if (record.phase == ApiForwardPhase.refunding ||
      status.wait == ApiForwardWait.refunding ||
      status.activity == ApiActivity.sweeping) {
    return l10n.privateUsdConvertStepRefund;
  }
  if (privateUsdForwardUnwinding(status)) {
    return l10n.privateUsdConvertStepUnwind;
  }
  switch (status.wait) {
    case ApiForwardWait.feeConfirming:
      return l10n.privateUsdConvertWaitFeeConfirming;
    case ApiForwardWait.feeAccepting:
      return l10n.privateUsdConvertWaitFeeSeen;
    default:
      break;
  }
  return switch (privateUsdForwardStepIndex(status)) {
    0 => l10n.privateUsdConvertStepOpen,
    1 => l10n.privateUsdConvertStepDeposit,
    2 => PrivateUsdCopy.activityDetail(
      l10n.privateUsdConvertStepConfirm,
      l10n.privateUsdConvertStepConfirmCount(
        record.depositConfirmations ?? 0,
        zcashConfirmations,
      ),
    ),
    _ => l10n.privateUsdConvertStepClaim,
  };
}

List<SwapStatusStepData> _forwardSteps(
  AppLocalizations l10n, {
  required int active,
  String? description,
}) => privateUsdProgressSteps(
  [
    l10n.privateUsdConvertStepOpen,
    l10n.privateUsdConvertStepDeposit,
    l10n.privateUsdConvertStepConfirm,
    l10n.privateUsdConvertStepClaim,
    l10n.privateUsdConvertStepArrive,
    l10n.privateUsdConvertStepScreen,
  ],
  active: active,
  description: description,
);

/// [titles] as a conversion's timeline: those before [active] done,
/// [active] running with [description], the rest still to come.
List<SwapStatusStepData> privateUsdProgressSteps(
  List<String> titles, {
  required int active,
  String? description,
}) => [
  for (final (index, title) in titles.indexed)
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

/// A conversion's timeline and details as the swap status screen draws
/// them. Once it [bridged], its amounts are no longer an estimate.
SwapActivityStatusPresentation privateUsdSwapStatus(
  AppLocalizations l10n, {
  required SwapAsset payAsset,
  required SwapAsset receiveAsset,
  required String payAmountText,
  required String receiveAmountText,
  required List<SwapStatusStepData> steps,
  required int progressIndex,
  required SwapStatusBadgeKind badgeKind,
  required List<SwapStatusDetailRowData> details,
  required bool bridged,
}) => SwapActivityStatusPresentation(
  title: l10n.privateUsdConvertProgressTitle,
  payAsset: payAsset,
  receiveAsset: receiveAsset,
  payFiatText: '',
  receiveFiatText: '',
  payAmountText: payAmountText,
  receiveAmountText: receiveAmountText,
  payLabel: bridged
      ? l10n.privateUsdBridgedYouPaid
      : l10n.privateUsdConvertYouPay,
  receiveLabel: bridged
      ? l10n.privateUsdBridgedYouReceived
      : l10n.privateUsdConvertYouReceive,
  badgeKind: badgeKind,
  progressIndex: progressIndex,
  steps: steps,
  details: details,
  progressTabLabel: l10n.privateUsdProgressTab,
  // Every row is one of the conversion's own (swap ID, its transactions,
  // when it started): all of them show while it runs.
  allDetailsInProgress: true,
  showTabs: steps.isNotEmpty,
);

String _confirmationsDetail(
  AppLocalizations l10n,
  int? confirmations,
  int needed,
  BlockTimeEstimate blockTimes,
) {
  final count = (confirmations ?? 0).clamp(0, needed);
  final left = needed - count;
  final countText = l10n.privateUsdConvertStepConfirmCount(count, needed);
  if (left <= 0) return countText;
  return PrivateUsdCopy.activityDetail(
    countText,
    PrivateUsdCopy.about(
      l10n,
      Duration(seconds: blockTimes.secondsForBlocks(left)),
    ),
  );
}

List<SwapStatusDetailRowData> _details(
  AppLocalizations l10n,
  ApiForwardRecord record, {
  String? explorerTxPrefix,
}) {
  final openFee = record.openFeeTxid;
  final deposit = record.depositTxid;
  final sweep = record.sweepTxid;
  final payout = record.payoutTx;
  return [
    SwapStatusDetailRowData(
      label: l10n.privateUsdDetailSwapId,
      value: truncatedTxid(record.swapId),
      copyable: true,
      copyText: record.swapId,
    ),
    if (openFee != null)
      SwapStatusDetailRowData(
        label: l10n.privateUsdDetailOpenFee,
        value: truncatedTxid(privateUsdDisplayTxid(openFee)),
        copyable: true,
        copyText: privateUsdDisplayTxid(openFee),
      ),
    if (deposit != null)
      SwapStatusDetailRowData(
        label: l10n.privateUsdDetailDeposit,
        value: truncatedTxid(privateUsdDisplayTxid(deposit)),
        copyable: true,
        copyText: privateUsdDisplayTxid(deposit),
      ),
    if (payout != null)
      SwapStatusDetailRowData(
        label: l10n.privateUsdDetailPayout,
        value: truncatedTxid(payout),
        copyable: true,
        copyText: payout,
        linkUri: privateUsdExplorerUri(explorerTxPrefix, payout),
      ),
    if (sweep != null)
      SwapStatusDetailRowData(
        label: l10n.privateUsdDetailRefund,
        value: truncatedTxid(privateUsdDisplayTxid(sweep)),
        copyable: true,
        copyText: privateUsdDisplayTxid(sweep),
      ),
    SwapStatusDetailRowData(
      label: l10n.privateUsdDetailStarted,
      value: formatDayMonthTime(
        DateTime.fromMillisecondsSinceEpoch(record.acceptedAt * 1000),
        l10n.localeName,
      ),
    ),
  ];
}

/// The ZEC a forward conversion pays: its deposit with the network fee it
/// cost, or before the wallet shows that its approved total (the most it may
/// cost), and the market maker's fee, with its payment's network fee, where
/// its quote asked one.
BigInt privateUsdForwardPaidZat(ApiForwardRecord record) {
  final depositNetwork = record.depositNetworkZat;
  final deposit = depositNetwork != null && record.depositTxid != null
      ? record.depositZat + depositNetwork
      : (record.maxTotalZat ?? record.depositZat);
  return deposit +
      (record.openFeeZat ?? BigInt.zero) +
      (record.openFeeNetworkZat ?? BigInt.zero);
}

/// [privateUsdForwardPaidZat] as an amount: masked in privacy mode, and
/// approximate ("≈") where the market maker fee's payment's own network fee
/// is not known, as for a payment found again after a restart in a wallet
/// that does not show its fee.
String privateUsdForwardPaidText(
  ApiForwardRecord record, {
  required bool privacyModeEnabled,
}) {
  if (privacyModeEnabled) return fixedPrivacyMask();
  final text = ZecAmount.fromZatoshi(
    privateUsdForwardPaidZat(record),
  ).activity.toString();
  final approximate =
      record.openFeeTxid != null && record.openFeeNetworkZat == null;
  return approximate ? PrivateUsdCopy.approximately(text) : text;
}

/// A txid as explorers show it: records carry the wallet's internal
/// (protocol) byte order, as history rows do.
String privateUsdDisplayTxid(String internalTxid) =>
    zcashDisplayTxidHex(internalTxid, ZcashExplorerTxidOrder.protocol);
