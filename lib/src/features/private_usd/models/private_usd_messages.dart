import '../../../rust/api/private_usd.dart'
    show
        ApiForwardRecord,
        ApiNothingSentCause,
        ApiPrivateUsdErrorCode,
        ApiRefundCause;
import '../private_usd_copy.dart';
import '../services/private_usd_spend_guard.dart' show PrivateUsdSpendStatus;
import '../../../core/l10n/l10n.dart';
import '../../../core/layout/app_form_factor.dart';
import 'private_usd_desktop_wording.dart';

/// Why Send, Withdraw or a new conversion cannot start now; null when they
/// can.
String? privateUsdSpendMessage(
  AppLocalizations l10n,
  PrivateUsdSpendStatus status,
) => switch (status) {
  PrivateUsdSpendStatus.available => null,
  PrivateUsdSpendStatus.checking => l10n.privateUsdCheckingPayments,
  PrivateUsdSpendStatus.sending => l10n.privateUsdPaymentPending,
  PrivateUsdSpendStatus.converting => l10n.privateUsdConversionPending,
  PrivateUsdSpendStatus.unreadable => l10n.privateUsdSendErrorStore,
};

/// What to say when pricing or sending fails before anything was sent.
String privateUsdSendErrorMessage(
  AppLocalizations l10n,
  ApiPrivateUsdErrorCode code,
) => switch (code) {
  ApiPrivateUsdErrorCode.unavailable => l10n.privateUsdSendUnavailable,
  ApiPrivateUsdErrorCode.relayerFee => l10n.privateUsdSendErrorFeeCap,
  ApiPrivateUsdErrorCode.routeBlocked => l10n.privateUsdRouteBlocked,
  ApiPrivateUsdErrorCode.storeUnreadable => l10n.privateUsdSendErrorStore,
  ApiPrivateUsdErrorCode.busy => l10n.privateUsdPaymentPending,
  _ => l10n.privateUsdSendNotSent,
};

/// That this device's clock runs ahead of Ethereum's, naming the phone, the
/// Mac or the computer: a step was refused, nothing sent.
String privateUsdClockErrorMessage(AppLocalizations l10n) => kDesktopFormFactor
    ? (privateUsdComputerWording
          ? l10n.privateUsdConvertErrorClockLinux
          : l10n.privateUsdConvertErrorClockDesktop)
    : l10n.privateUsdConvertErrorClock;

/// [privateUsdClockErrorMessage] on the problem card: the bridge's next step
/// waits for the clock.
String privateUsdClockProblemMessage(AppLocalizations l10n) =>
    kDesktopFormFactor
    ? (privateUsdComputerWording
          ? l10n.privateUsdConvertProblemClockLinux
          : l10n.privateUsdConvertProblemClockDesktop)
    : l10n.privateUsdConvertProblemClock;

/// What to say when a quote or an accept fails before anything was sent;
/// null for a cancelled call, which is never a failure. Dart never branches
/// on an error's message text.
String? privateUsdErrorMessage(
  AppLocalizations l10n,
  ApiPrivateUsdErrorCode code,
) => switch (code) {
  ApiPrivateUsdErrorCode.cancelled => null,
  // A service serving another deployment reads as the relayer being
  // unreachable.
  ApiPrivateUsdErrorCode.relayerUnreachable ||
  ApiPrivateUsdErrorCode.wrongDeployment => l10n.privateUsdConvertErrorRelayer,
  ApiPrivateUsdErrorCode.relayerRefused =>
    l10n.privateUsdConvertErrorRelayerRefused,
  // At quote, Rust refuses a fee above the cap.
  ApiPrivateUsdErrorCode.relayerFee => l10n.privateUsdConvertErrorFeeCap,
  ApiPrivateUsdErrorCode.ethereumUnreachable ||
  ApiPrivateUsdErrorCode.chainLagging => l10n.privateUsdConvertErrorEthereum,
  ApiPrivateUsdErrorCode.clockOff => privateUsdClockErrorMessage(l10n),
  ApiPrivateUsdErrorCode.zcashWallet => l10n.privateUsdConvertErrorWallet,
  ApiPrivateUsdErrorCode.depositUnpayable =>
    l10n.privateUsdConvertErrorUnpayable,
  ApiPrivateUsdErrorCode.quoteExpired => l10n.privateUsdConvertQuoteRanOut,
  ApiPrivateUsdErrorCode.makerUnavailable => l10n.privateUsdConvertErrorMaker,
  ApiPrivateUsdErrorCode.makerBusy => l10n.privateUsdConvertErrorMakerBusy,
  ApiPrivateUsdErrorCode.amountRefused =>
    l10n.privateUsdConvertErrorAmountRefused,
  ApiPrivateUsdErrorCode.storeUnreadable => l10n.privateUsdConvertErrorStore,
  ApiPrivateUsdErrorCode.routeBlocked => l10n.privateUsdRouteBlocked,
  // At quote, Rust refuses an open fee over the cap or payable outside
  // Orchard.
  ApiPrivateUsdErrorCode.openFeeRefused => l10n.privateUsdConvertErrorOpenFee,
  // At accept, Rust pays no open fee while the wallet catches up.
  ApiPrivateUsdErrorCode.walletSyncing => l10n.privateUsdConvertFeeWaitsForSync,
  ApiPrivateUsdErrorCode.railgunClosed ||
  ApiPrivateUsdErrorCode.zcashRejected ||
  ApiPrivateUsdErrorCode.mismatch ||
  ApiPrivateUsdErrorCode.fundingCostChanged ||
  ApiPrivateUsdErrorCode.depositUnconfirmed ||
  ApiPrivateUsdErrorCode.tooLate ||
  ApiPrivateUsdErrorCode.busy ||
  ApiPrivateUsdErrorCode.unavailable ||
  ApiPrivateUsdErrorCode.other => l10n.privateUsdConvertErrorGeneric,
};

/// [privateUsdErrorMessage] kept for a widget to show; null for a cancelled
/// call.
PrivateUsdText? privateUsdErrorText(ApiPrivateUsdErrorCode code) =>
    code == ApiPrivateUsdErrorCode.cancelled
    ? null
    : (l10n) =>
          privateUsdErrorMessage(l10n, code) ??
          l10n.privateUsdConvertErrorGeneric;

/// The problem card's message for a conversion whose steps have failed for
/// a minute.
String privateUsdProblemMessage(
  AppLocalizations l10n,
  ApiPrivateUsdErrorCode code,
) => switch (code) {
  ApiPrivateUsdErrorCode.relayerUnreachable =>
    l10n.privateUsdConvertProblemRelayer,
  ApiPrivateUsdErrorCode.relayerRefused =>
    l10n.privateUsdConvertProblemRelayerRefused,
  ApiPrivateUsdErrorCode.relayerFee => l10n.privateUsdConvertProblemRelayerFee,
  ApiPrivateUsdErrorCode.ethereumUnreachable ||
  ApiPrivateUsdErrorCode.chainLagging => l10n.privateUsdConvertProblemEthereum,
  ApiPrivateUsdErrorCode.clockOff => privateUsdClockProblemMessage(l10n),
  ApiPrivateUsdErrorCode.railgunClosed => l10n.privateUsdConvertProblemRailgun,
  ApiPrivateUsdErrorCode.zcashWallet => l10n.privateUsdConvertProblemWallet,
  ApiPrivateUsdErrorCode.depositUnpayable =>
    l10n.privateUsdConvertProblemUnpayable,
  ApiPrivateUsdErrorCode.zcashRejected => l10n.privateUsdConvertProblemRejected,
  ApiPrivateUsdErrorCode.mismatch => l10n.privateUsdConvertProblemMismatch,
  ApiPrivateUsdErrorCode.storeUnreadable => l10n.privateUsdConvertErrorStore,
  ApiPrivateUsdErrorCode.routeBlocked => l10n.privateUsdConvertProblemRoute,
  _ => l10n.privateUsdConvertProblemUnexpected,
};

/// Why a forward conversion ended with nothing sent.
String privateUsdNothingSentMessage(
  AppLocalizations l10n,
  ApiNothingSentCause? cause,
) => switch (cause) {
  ApiNothingSentCause.quoteExpired => l10n.privateUsdConvertResultQuoteExpired,
  ApiNothingSentCause.makerRefused => l10n.privateUsdConvertResultMakerRefused,
  ApiNothingSentCause.makerUnavailable =>
    l10n.privateUsdConvertResultMakerUnavailable,
  ApiNothingSentCause.neverOpened ||
  null => l10n.privateUsdConvertResultNeverOpened,
  ApiNothingSentCause.mismatch => l10n.privateUsdConvertResultMismatch,
  ApiNothingSentCause.depositWindowMissed =>
    l10n.privateUsdConvertResultWindowMissed,
  ApiNothingSentCause.makerCancelled =>
    l10n.privateUsdConvertResultMakerCancelled,
  ApiNothingSentCause.feeNotHonoured =>
    l10n.privateUsdConvertResultFeeNotHonoured,
};

/// Why [record] ended with nothing sent: that the maker keeps its fee, once
/// the wallet shows the fee in a block, else its cause.
String privateUsdForwardNothingSentMessage(
  AppLocalizations l10n,
  ApiForwardRecord record,
) => record.openFeeMined
    ? l10n.privateUsdConvertResultFeeKept
    : privateUsdNothingSentMessage(l10n, record.nothingSentCause);

/// Why a forward conversion's ZEC came back, and with [feeKept] (its quote
/// asked an open fee, paid before the swap opened) that the market maker
/// keeps its fee.
String privateUsdRefundedMessage(
  AppLocalizations l10n,
  ApiRefundCause? cause, {
  bool feeKept = false,
}) => switch ((cause, feeKept)) {
  (ApiRefundCause.notClaimedInTime, false) =>
    l10n.privateUsdConvertResultRefundedLate,
  (ApiRefundCause.notClaimedInTime, true) =>
    l10n.privateUsdConvertResultRefundedLateFeeKept,
  (_, false) => l10n.privateUsdConvertResultRefundedMaker,
  (_, true) => l10n.privateUsdConvertResultRefundedMakerFeeKept,
};

/// What to say when a reverse quote fails before anything but a swap index
/// was spent.
String? privateUsdReverseQuoteMessage(
  AppLocalizations l10n,
  ApiPrivateUsdErrorCode code,
) => switch (code) {
  ApiPrivateUsdErrorCode.unavailable =>
    l10n.privateUsdReverseErrorFundingUnavailable,
  // The fees took all of the total, or the maker refused what is left.
  ApiPrivateUsdErrorCode.amountRefused =>
    l10n.privateUsdReverseErrorAmountRefused,
  _ => privateUsdErrorMessage(l10n, code),
};

/// [privateUsdReverseQuoteMessage] kept for a widget to show; null for a
/// cancelled call.
PrivateUsdText? privateUsdReverseQuoteText(ApiPrivateUsdErrorCode code) =>
    code == ApiPrivateUsdErrorCode.cancelled
    ? null
    : (l10n) =>
          privateUsdReverseQuoteMessage(l10n, code) ??
          l10n.privateUsdConvertErrorGeneric;

/// What to say when a reverse step the user took (pay, authorize settlement,
/// cancel) did not go through.
String privateUsdReverseStepMessage(
  AppLocalizations l10n,
  ApiPrivateUsdErrorCode code,
) => switch (code) {
  ApiPrivateUsdErrorCode.depositUnconfirmed =>
    l10n.privateUsdReverseErrorUnconfirmed,
  ApiPrivateUsdErrorCode.tooLate ||
  ApiPrivateUsdErrorCode.quoteExpired => l10n.privateUsdReverseErrorTooLate,
  ApiPrivateUsdErrorCode.fundingCostChanged =>
    l10n.privateUsdReverseErrorCostChanged,
  ApiPrivateUsdErrorCode.unavailable =>
    l10n.privateUsdReverseErrorFundingUnavailable,
  // Settlement is signed only on a fresh head: a node minutes behind is
  // as good as unreachable, and a clock minutes ahead is the clock's to fix.
  ApiPrivateUsdErrorCode.ethereumUnreachable ||
  ApiPrivateUsdErrorCode.chainLagging => l10n.privateUsdConvertErrorEthereum,
  ApiPrivateUsdErrorCode.clockOff => privateUsdClockErrorMessage(l10n),
  ApiPrivateUsdErrorCode.relayerFee => l10n.privateUsdConvertErrorFeeCap,
  ApiPrivateUsdErrorCode.routeBlocked => l10n.privateUsdConvertProblemRoute,
  ApiPrivateUsdErrorCode.storeUnreadable => l10n.privateUsdConvertErrorStore,
  _ => l10n.privateUsdReverseError,
};

/// The problem card's message for a reverse conversion whose steps have
/// failed for a minute.
String privateUsdReverseProblemMessage(
  AppLocalizations l10n,
  ApiPrivateUsdErrorCode code,
) => switch (code) {
  ApiPrivateUsdErrorCode.relayerUnreachable =>
    l10n.privateUsdReverseProblemRelayer,
  ApiPrivateUsdErrorCode.relayerRefused ||
  ApiPrivateUsdErrorCode.relayerFee ||
  ApiPrivateUsdErrorCode.ethereumUnreachable ||
  ApiPrivateUsdErrorCode.chainLagging ||
  ApiPrivateUsdErrorCode.clockOff ||
  ApiPrivateUsdErrorCode.zcashWallet ||
  ApiPrivateUsdErrorCode.zcashRejected ||
  ApiPrivateUsdErrorCode.mismatch ||
  ApiPrivateUsdErrorCode.storeUnreadable ||
  ApiPrivateUsdErrorCode.routeBlocked => privateUsdProblemMessage(l10n, code),
  _ => l10n.privateUsdConvertProblemUnexpected,
};

/// Why confirming did not start a reverse conversion: the maker's answer
/// ended it (`nothingSent`) with nothing paid.
String privateUsdReverseNothingSentMessage(
  AppLocalizations l10n,
  ApiNothingSentCause? cause,
) => switch (cause) {
  ApiNothingSentCause.makerUnavailable => l10n.privateUsdConvertErrorMaker,
  ApiNothingSentCause.quoteExpired => l10n.privateUsdConvertQuoteRanOut,
  _ => l10n.privateUsdConvertStartFailed,
};

/// A dollar token's name by its symbol: the testnet maker's token is `tUSD`.
String privateUsdTokenName(AppLocalizations l10n, String symbol) =>
    symbol == 'tUSD' ? l10n.privateUsdTokenTestUsd : PrivateUsdCopy.tokenUsdc;

/// What the chain is called for a Railgun network.
String privateUsdRpcNetworkName(AppLocalizations l10n, String railgunNetwork) =>
    railgunNetwork == 'sepolia'
    ? PrivateUsdCopy.rpcNetworkSepolia
    : l10n.privateUsdRpcNetworkMainnet;
