import '../../../rust/api/private_usd.dart'
    show ApiNothingSentCause, ApiPrivateUsdErrorCode, ApiRefundCause;
import '../private_usd_copy.dart';
import '../services/private_usd_spend_guard.dart' show PrivateUsdSpendStatus;

/// Why Send, Withdraw or a new conversion cannot start now; null when they
/// can.
String? privateUsdSpendMessage(PrivateUsdSpendStatus status) =>
    switch (status) {
      PrivateUsdSpendStatus.available => null,
      PrivateUsdSpendStatus.checking => PrivateUsdCopy.checkingPayments,
      PrivateUsdSpendStatus.sending => PrivateUsdCopy.paymentPending,
      PrivateUsdSpendStatus.converting => PrivateUsdCopy.conversionPending,
      PrivateUsdSpendStatus.unreadable => PrivateUsdCopy.sendErrorStore,
    };

/// What to say when pricing or sending fails before anything was sent.
String privateUsdSendErrorMessage(ApiPrivateUsdErrorCode code) =>
    switch (code) {
      ApiPrivateUsdErrorCode.unavailable => PrivateUsdCopy.sendUnavailable,
      ApiPrivateUsdErrorCode.relayerFee => PrivateUsdCopy.sendErrorFeeCap,
      ApiPrivateUsdErrorCode.routeBlocked => PrivateUsdCopy.routeBlocked,
      ApiPrivateUsdErrorCode.storeUnreadable => PrivateUsdCopy.sendErrorStore,
      ApiPrivateUsdErrorCode.busy => PrivateUsdCopy.paymentPending,
      _ => PrivateUsdCopy.sendNotSent,
    };

/// What to say when a quote or an accept fails before anything was sent;
/// null for a cancelled call, which is never a failure. Dart never branches
/// on an error's message text.
String? privateUsdErrorMessage(ApiPrivateUsdErrorCode code) => switch (code) {
  ApiPrivateUsdErrorCode.cancelled => null,
  // A service serving another deployment reads as the relayer being
  // unreachable.
  ApiPrivateUsdErrorCode.relayerUnreachable ||
  ApiPrivateUsdErrorCode.wrongDeployment => PrivateUsdCopy.convertErrorRelayer,
  ApiPrivateUsdErrorCode.relayerRefused =>
    PrivateUsdCopy.convertErrorRelayerRefused,
  // At quote, Rust refuses a fee above the cap.
  ApiPrivateUsdErrorCode.relayerFee => PrivateUsdCopy.convertErrorFeeCap,
  ApiPrivateUsdErrorCode.ethereumUnreachable ||
  ApiPrivateUsdErrorCode.chainLagging => PrivateUsdCopy.convertErrorEthereum,
  ApiPrivateUsdErrorCode.zcashWallet => PrivateUsdCopy.convertErrorWallet,
  ApiPrivateUsdErrorCode.depositUnpayable =>
    PrivateUsdCopy.convertErrorUnpayable,
  ApiPrivateUsdErrorCode.tokensRefused =>
    PrivateUsdCopy.convertErrorTokensUnavailable,
  ApiPrivateUsdErrorCode.tokensNeeded =>
    PrivateUsdCopy.convertResultMakerUnavailable,
  ApiPrivateUsdErrorCode.quoteExpired => PrivateUsdCopy.convertQuoteRanOut,
  ApiPrivateUsdErrorCode.makerUnavailable => PrivateUsdCopy.convertErrorMaker,
  ApiPrivateUsdErrorCode.makerBusy => PrivateUsdCopy.convertErrorMakerBusy,
  ApiPrivateUsdErrorCode.amountRefused =>
    PrivateUsdCopy.convertErrorAmountRefused,
  ApiPrivateUsdErrorCode.storeUnreadable => PrivateUsdCopy.convertErrorStore,
  ApiPrivateUsdErrorCode.routeBlocked => PrivateUsdCopy.routeBlocked,
  ApiPrivateUsdErrorCode.railgunClosed ||
  ApiPrivateUsdErrorCode.claimTurn ||
  ApiPrivateUsdErrorCode.zcashRejected ||
  ApiPrivateUsdErrorCode.mismatch ||
  ApiPrivateUsdErrorCode.fundingCostChanged ||
  ApiPrivateUsdErrorCode.depositUnconfirmed ||
  ApiPrivateUsdErrorCode.tooLate ||
  ApiPrivateUsdErrorCode.busy ||
  ApiPrivateUsdErrorCode.unavailable ||
  ApiPrivateUsdErrorCode.other => PrivateUsdCopy.convertErrorGeneric,
};

/// The problem card's message for a conversion whose steps have failed for
/// a minute.
String privateUsdProblemMessage(ApiPrivateUsdErrorCode code) => switch (code) {
  ApiPrivateUsdErrorCode.relayerUnreachable =>
    PrivateUsdCopy.convertProblemRelayer,
  ApiPrivateUsdErrorCode.relayerRefused =>
    PrivateUsdCopy.convertProblemRelayerRefused,
  ApiPrivateUsdErrorCode.relayerFee => PrivateUsdCopy.convertProblemRelayerFee,
  ApiPrivateUsdErrorCode.ethereumUnreachable ||
  ApiPrivateUsdErrorCode.chainLagging => PrivateUsdCopy.convertProblemEthereum,
  ApiPrivateUsdErrorCode.railgunClosed => PrivateUsdCopy.convertProblemRailgun,
  ApiPrivateUsdErrorCode.claimTurn => PrivateUsdCopy.convertProblemTurn,
  ApiPrivateUsdErrorCode.zcashWallet => PrivateUsdCopy.convertProblemWallet,
  ApiPrivateUsdErrorCode.depositUnpayable =>
    PrivateUsdCopy.convertProblemUnpayable,
  ApiPrivateUsdErrorCode.zcashRejected => PrivateUsdCopy.convertProblemRejected,
  ApiPrivateUsdErrorCode.mismatch => PrivateUsdCopy.convertProblemMismatch,
  ApiPrivateUsdErrorCode.storeUnreadable => PrivateUsdCopy.convertErrorStore,
  ApiPrivateUsdErrorCode.routeBlocked => PrivateUsdCopy.convertProblemRoute,
  _ => PrivateUsdCopy.convertProblemUnexpected,
};

/// Why a forward conversion ended with nothing sent.
String privateUsdNothingSentMessage(
  ApiNothingSentCause? cause,
) => switch (cause) {
  ApiNothingSentCause.quoteExpired => PrivateUsdCopy.convertResultQuoteExpired,
  ApiNothingSentCause.makerRefused => PrivateUsdCopy.convertResultMakerRefused,
  ApiNothingSentCause.makerUnavailable =>
    PrivateUsdCopy.convertResultMakerUnavailable,
  ApiNothingSentCause.neverOpened ||
  null => PrivateUsdCopy.convertResultNeverOpened,
  ApiNothingSentCause.mismatch => PrivateUsdCopy.convertResultMismatch,
  ApiNothingSentCause.depositWindowMissed =>
    PrivateUsdCopy.convertResultWindowMissed,
  ApiNothingSentCause.makerCancelled =>
    PrivateUsdCopy.convertResultMakerCancelled,
};

/// Why a forward conversion's ZEC came back.
String privateUsdRefundedMessage(ApiRefundCause? cause) => switch (cause) {
  ApiRefundCause.makerCancelled ||
  null => PrivateUsdCopy.convertResultRefundedMaker,
  ApiRefundCause.notClaimedInTime => PrivateUsdCopy.convertResultRefundedLate,
};

/// What to say when a reverse quote fails before anything but a swap index
/// was spent.
String? privateUsdReverseQuoteMessage(ApiPrivateUsdErrorCode code) =>
    switch (code) {
      ApiPrivateUsdErrorCode.unavailable =>
        PrivateUsdCopy.reverseErrorFundingUnavailable,
      _ => privateUsdErrorMessage(code),
    };

/// What to say when a reverse step the user took (pay, authorize settlement,
/// cancel) did not go through.
String privateUsdReverseStepMessage(ApiPrivateUsdErrorCode code) =>
    switch (code) {
      ApiPrivateUsdErrorCode.depositUnconfirmed =>
        PrivateUsdCopy.reverseErrorUnconfirmed,
      ApiPrivateUsdErrorCode.tooLate ||
      ApiPrivateUsdErrorCode.quoteExpired => PrivateUsdCopy.reverseErrorTooLate,
      ApiPrivateUsdErrorCode.fundingCostChanged =>
        PrivateUsdCopy.reverseErrorCostChanged,
      ApiPrivateUsdErrorCode.unavailable =>
        PrivateUsdCopy.reverseErrorFundingUnavailable,
      ApiPrivateUsdErrorCode.relayerFee => PrivateUsdCopy.convertErrorFeeCap,
      ApiPrivateUsdErrorCode.routeBlocked => PrivateUsdCopy.convertProblemRoute,
      ApiPrivateUsdErrorCode.storeUnreadable =>
        PrivateUsdCopy.convertErrorStore,
      _ => PrivateUsdCopy.reverseError,
    };

/// The problem card's message for a reverse conversion whose steps have
/// failed for a minute.
String privateUsdReverseProblemMessage(ApiPrivateUsdErrorCode code) =>
    switch (code) {
      ApiPrivateUsdErrorCode.relayerUnreachable =>
        PrivateUsdCopy.reverseProblemRelayer,
      ApiPrivateUsdErrorCode.relayerRefused ||
      ApiPrivateUsdErrorCode.relayerFee ||
      ApiPrivateUsdErrorCode.ethereumUnreachable ||
      ApiPrivateUsdErrorCode.chainLagging ||
      ApiPrivateUsdErrorCode.zcashWallet ||
      ApiPrivateUsdErrorCode.zcashRejected ||
      ApiPrivateUsdErrorCode.mismatch ||
      ApiPrivateUsdErrorCode.storeUnreadable ||
      ApiPrivateUsdErrorCode.routeBlocked => privateUsdProblemMessage(code),
      _ => PrivateUsdCopy.convertProblemUnexpected,
    };

/// Why confirming did not start a reverse conversion: the maker's answer
/// ended it (`nothingSent`) with nothing paid.
String privateUsdReverseNothingSentMessage(ApiNothingSentCause? cause) =>
    switch (cause) {
      ApiNothingSentCause.makerUnavailable => PrivateUsdCopy.convertErrorMaker,
      ApiNothingSentCause.quoteExpired => PrivateUsdCopy.convertQuoteRanOut,
      _ => PrivateUsdCopy.convertStartFailed,
    };

/// A dollar token's name by its symbol: the testnet maker's token is `tUSD`.
String privateUsdTokenName(String symbol) =>
    symbol == 'tUSD' ? PrivateUsdCopy.tokenTestUsd : PrivateUsdCopy.tokenUsdc;

/// What the chain is called for a Railgun network.
String privateUsdRpcNetworkName(String railgunNetwork) =>
    railgunNetwork == 'sepolia'
    ? PrivateUsdCopy.rpcNetworkSepolia
    : PrivateUsdCopy.rpcNetworkMainnet;
