import '../../core/config/private_usd_feature_config.dart';

/// Every user-facing Private USD string, sentence case, in one place so
/// widgets, tests and Widgetbook share it. "Private USD" is the feature's
/// name: capitalized at the start of a sentence and as a title, "private
/// USD" mid-sentence.
abstract final class PrivateUsdCopy {
  // ── Shared ─────────────────────────────────────────────────────────────

  static const title = 'Private USD';

  static String about(Duration duration) {
    final minutes = duration.inMinutes < 1 ? 1 : duration.inMinutes;
    return minutes < 60 ? 'about $minutes min' : 'about ${minutes ~/ 60} h';
  }

  static const infoButton = 'How this works';
  static const loading = 'Loading…';
  static const unknown = '—';
  static const refresh = 'Refresh';
  static const updating = 'Updating…';
  static String updated(String time) => 'Updated $time';
  static const review = 'Review';
  static const done = 'Done';
  static const close = 'Close';
  static const notNow = 'Not now';
  static const paste = 'Paste';

  /// The semantics label of [max].
  static const useAvailable = 'Use it all';
  static const max = 'Max';
  static String availableAmount(String amount) => '$rowAvailable: $amount';

  static const usdcSymbol = 'USDC';
  static const ethereum = 'Ethereum';

  /// A link to `VIZOR_SUPPORT_URL` when that define is set.
  static const supportSentence = 'Contact support.';

  /// Whether [supportSentence] links somewhere.
  static bool get hasSupportLink => kVizorSupportUrl.isNotEmpty;

  // ── Home ───────────────────────────────────────────────────────────────

  static String homeArriving(String usd) => '+$usd arriving';
  static String homeArrivingDescription(String usd) => '$usd arriving';
  static String homeBlocked(String usd) => '$usd needs attention';
  static String homeBlockedDescription(String usd) => 'Needs attention: $usd';
  static String homeBalanceDescription(String amount) => '$title $amount';
  static const homeOpen = 'Open private USD';
  static String homeZecEquivalent(String zec) => '≈ $zec ZEC';

  static const convertingToUsd = 'Bridging to 0zkUSDC';
  static const convertingToZec = 'Bridging to ZEC';
  static const bannerAttention = 'Bridge needs attention';
  static const bannerKeepOpen = 'Keep Veylor open to finish';
  static String bannerDetail(String detail) => '$detail\n$bannerKeepOpen';

  // ── Private USD screen ─────────────────────────────────────────────────

  static const subtitle = '0zkUSDC held on Ethereum';
  static const rowAvailable = 'Available';
  static const rowProcessing = 'Processing';
  static const rowProcessingInfo =
      'A send is being confirmed. These funds are available again once it '
      'settles.';
  static const rowProcessingStalled = '$rowProcessing · screening delayed';
  static const rowProcessingStalledInfo =
      "Railgun's screening hasn't accepted these funds yet. They're still "
      'yours and become available once it does. Veylor keeps trying while '
      "it's open.";

  static String screeningSyncingList(int percent) =>
      "Syncing Railgun's transaction list · $percent%";

  /// [percent] is null while the files' size is unknown.
  static String screeningDownloading(int? percent) => percent == null
      ? 'Downloading proving files'
      : 'Downloading proving files · $percent%';

  static String screeningProving(int index, int count, int percent) => count > 1
      ? 'Building screening proof $index of $count · $percent%'
      : 'Building screening proof · $percent%';

  static const screeningWaiting = "Waiting for Railgun's screening service";

  static const rowArriving = 'Arriving';

  /// [percent] is the share of the screening time gone by since the funds
  /// landed.
  static String rowArrivingPercent(int percent) => '$rowArriving · $percent%';
  static const rowArrivingLate = '$rowArriving · taking longer than usual';
  static String rowArrivingInfo(String about) =>
      'Railgun screens new funds before they can be spent. This takes $about.';

  static const rowBlocked = 'Screening refused';
  static const rowBlockedInfo =
      "Railgun's screening refused these funds, so they can't be spent or "
      'sent. They can only go back to where they came from, the bridge '
      'contract. $supportSentence';

  static const assetsTitle = 'Assets';
  static const tokenUsdc = 'USD Coin';
  static const tokenTestUsd = 'Test dollar';

  static const actionConvert = 'Bridge';
  static const actionSend = 'Send';
  static const actionWithdraw = 'Withdraw';
  static const actionReceive = 'Receive';

  static const firstLoad =
      "Loading your private balance. The first time reads Railgun's history "
      'and can take a while. Keep Veylor open.';
  static String firstLoadProgress(int percent) =>
      'Loading your private balance: $percent%. The first time reads '
      "Railgun's history and can take a while. Keep Veylor open.";
  static const refreshFailed =
      "Couldn't update the balance. Showing the last known amounts.";
  static const loadFailed = "Couldn't load the balance. Try again in a moment.";

  static String syncReadoutProgress(int percent) => 'Railgun sync $percent%';
  static const syncReadoutSynced = 'Railgun synced';
  static const syncReadoutFailed = 'Railgun sync failed';

  static const emptyTitle = 'No private dollars yet';
  static const emptyBody =
      'Bridge ZEC into dollars nobody else can see: not your balance, and '
      'not who you pay.';

  /// [emptyBody] where bridging is off: Receive is the way in.
  static const emptyBodyReceive =
      'Receive dollars nobody else can see: not your balance, and not who '
      'you pay.';

  static String receiveShieldedTab(String symbol) => '0zk$symbol';
  static const receiveShieldedOnly = 'Only from a Railgun wallet';
  static const receiveAddressNote =
      'Private USD from another Railgun wallet arrives here, with no fee.';
  static const receiveShieldedCopy = 'Copy Railgun address';
  static const addressCopied = 'Address copied';

  static const checkingPayments = 'Checking pending payments…';
  static const paymentPending =
      "A previous payment is still pending. You can send or bridge again "
      "once it's confirmed.";
  static const conversionPending =
      'A bridge is in progress. Sending will be available when it '
      'finishes.';

  static const infoTitle = 'About private USD';
  static const infoConvert = 'Bridge: move between ZEC and private USD.';
  static const infoReceive =
      'Receive: public USDC from an exchange or any wallet goes to your '
      'deposit address (Receive), and Veylor makes it private for a small '
      'fee. Private USD from another Railgun wallet goes to your Railgun '
      'address on this screen, with no fee.';
  static const infoSend =
      'Send: transfer private USD to another Railgun address. The recipient '
      'receives it privately.';
  static const infoWithdraw =
      'Withdraw: move private USD to a public Ethereum address. The '
      'destination and amount are visible on Ethereum.';
  static const infoRefunds =
      "Refunds: recover a refund that couldn't enter your private balance.";
  static String infoScreening(String about) =>
      'Railgun screens new funds for $about before they can be spent.';
  static const infoPrivate =
      'Nobody else can see your balance, or who you pay.';
  static const infoKeepOpen =
      'Bridges, sends and refunds run only while Veylor is open and '
      'unlocked.';

  // ── Activity ───────────────────────────────────────────────────────────

  static const activityTitle = 'Activity';
  static const activityEmpty =
      'Your bridges, sends and withdrawals will show here.';
  static const activityConverted = 'Bridged to 0zkUSDC';
  static const activityConvertedToZec = 'Bridged to ZEC';
  static const activityRefunded = 'Bridge called off';
  static const activityRefundedDetail = 'your ZEC came back';
  static const activityRefundedZecDetail = 'your dollars came back';
  static const activitySent = 'Sent privately';
  static const activityWithdrew = 'Withdrew';
  static const activityReceived = 'Received privately';

  /// Private USD's line among the holdings: shielded, but on Ethereum.
  static const holdingsShieldedOnEthereum = 'Shielded on Ethereum';
  static String activityDetail(String a, String b) => '$a · $b';
  static String activityTo(String address) => 'to $address';
  static String activityFrom(String address) => 'from $address';
  static const activitySenderHidden = 'sender hidden';
  static const activityReceivedScreening = 'available once screened';
  static String activityIn(String usd) => '+$usd';
  static String activityOut(String usd) => '−$usd';
  static const activityUnconfirmed = 'not in a block yet';
  static const refundsView = 'View refunds';

  // ── Convert (both directions): amount and quote ─────────────────────

  static const convertAssetZec = 'ZEC';
  static const convertZecIncludesFee = 'Includes the Zcash network fee';
  static const convertEstimatedAmount = 'Estimated amount';
  static const convertYouPay = 'You pay';
  static const convertNetworkFee = 'Network fee';
  static const convertYouReceive = 'You receive about';
  static const convertFees = 'Bridge fees';
  static String convertFeesValue(String relayerUsd, String railgunPercent) =>
      '$relayerUsd relayer · $railgunPercent% Railgun';
  static const convertMakerCost = "Market maker's network cost";

  static String convertQuoteExpires(String minutesSeconds) =>
      'Quote expires in $minutesSeconds';
  static String convertQuoteHolds(String minutesSeconds) =>
      'Quote holds for $minutesSeconds';
  static const quoteExpired = 'Quote expired';
  static const convertQuoteLoading = 'Getting quote…';
  static const convertNewQuote = 'Refresh quote';
  static const convertQuoteRanOut =
      'This quote expired. Refresh it to continue.';
  static const convertQuoteClockAhead =
      "The quote had expired by the time it arrived. Check that your phone's "
      'clock is right, then try again.';

  static String convertInsufficient(String zec) =>
      'Not enough ZEC. You have $zec available.';
  static const convertZecSyncing =
      'Your wallet is still syncing. The rest of your ZEC is available once '
      'it catches up.';
  static String convertZecSyncingProgress(int percent) =>
      'Your wallet is still syncing ($percent%). The rest of your ZEC is '
      'available once it catches up.';
  static const convertZecNoQuote =
      'No quote fits this amount. Try a different amount, or use it all for '
      'the maximum.';

  // ── Convert: errors before anything is sent ───────────────────────────

  static const convertErrorMaker =
      "The market maker can't be reached right now. Try again in a moment.";
  static const convertErrorMakerBusy =
      'The market maker is busy with other bridges. Try again in a few '
      'minutes.';
  static const convertErrorAmountRefused =
      "The market maker won't bridge this amount. It may be over the limit "
      "for one bridge, or too small to cover the swap's network cost.";
  static const convertErrorBelowFee =
      "This amount doesn't cover the relayer's fee. Try a larger amount.";
  static const convertErrorFeeCap =
      "The relayer's fee is above the 2 USDC limit right now, so nothing was "
      'sent. Try again later.';
  static const convertErrorTokensUnavailable =
      "Couldn't get this bridge's token, so nothing was sent. Try again "
      'in a moment.';
  static const convertErrorRelayer =
      "The relayer that completes bridges can't be reached right now. "
      'Try again in a moment.';
  static const convertErrorRelayerRefused =
      'The relayer that completes bridges turned this down. Try again in '
      'a moment.';
  static const convertErrorEthereum =
      "Veylor can't reach Ethereum right now. Try again in a moment.";
  static const convertErrorWallet =
      "Veylor couldn't complete this step with your Zcash wallet. Try again "
      'in a moment.';
  static const convertErrorUnpayable =
      "Your wallet can't pay this in one transaction right now. Try a smaller "
      'amount.';
  static const convertErrorStore =
      "Veylor can't read its saved bridges. $supportSentence";
  static const convertErrorGeneric =
      "Couldn't get a quote. Try again in a moment.";
  static const convertStartFailed =
      "The bridge couldn't start. Nothing was sent. Try again in a "
      'moment.';
  static const routeBlocked =
      "Tor is starting or unavailable, so nothing was sent. Try again once "
      "it's connected.";

  // ── Convert: review and info ──────────────────────────────────────────

  static const convertInfoTitle = 'How bridging works';
  static const convertInfoStepQuote =
      'Enter the ZEC you want to bridge, including the network fee. The '
      'market maker quotes how much private USD you receive. The quote holds '
      'for a few minutes.';
  static const convertInfoStepDeposit =
      'Your ZEC goes to a deposit address that you and the market maker '
      'control together.';
  static const convertInfoStepClaim =
      'Once the deposit is confirmed, Veylor claims the dollars into your '
      'private balance.';
  static const convertInfoNoteEither =
      'Either the dollars reach your private balance, or your ZEC comes back '
      'to you.';
  static String convertInfoNoteTime(String about) =>
      'Takes $about. Keep Veylor open and unlocked until it\'s done. If you '
      "leave, it pauses; if it can't finish in time, it's called off and "
      'your ZEC comes back, less a network fee.';

  static const convertReviewInfoTitle = 'Before you bridge';
  static const convertReviewInfoPay =
      "You pay the ZEC deposit, which includes the market maker's network "
      'cost, plus the Zcash network fee.';
  static String convertReviewInfoReceive(String railgunPercent) =>
      "You receive the dollars left after the relayer's fee and Railgun's "
      '$railgunPercent% fee for shielding them.';
  static const convertReviewInfoQuote =
      'The quote holds for a few minutes. If it expires, refresh it: nothing '
      'is sent until you bridge.';

  // ── Convert: progress (forward) ───────────────────────────────────────

  static const convertProgressTitle = 'Bridging';
  static const bridgedTitle = 'Bridged';
  static const shieldedZec = 'Shielded ZEC';

  /// A finished bridge's amounts, no longer estimates.
  static const bridgedYouPaid = 'You paid';
  static const bridgedYouReceived = 'You received';

  static String convertProgressAmounts(String zec, String usd) =>
      '$zec for about $usd';

  static const convertStepOpen = 'Opening the swap on Ethereum';
  static const convertStepDeposit = 'Sending your ZEC';
  static const convertStepConfirm = 'Waiting for confirmations';
  static const convertStepClaim = 'Claiming your dollars';
  static String convertStepConfirmCount(int count, int of) => '$count of $of';
  static const convertStepArrive = 'Arriving in your private balance';
  static const convertStepScreen = 'Screening';
  static const convertStepRefund = 'Bringing your ZEC back';
  static const convertStepUnwind = "Waiting for the market maker's refund";
  static const convertEtaSeconds = 'A few seconds';
  static const convertEtaMinute = 'About a minute';
  static const convertWaitSyncing = 'Waiting for your Zcash wallet to sync';

  static String convertMakerSilent(String time) =>
      "The market maker hasn't confirmed your deposit yet. If it still "
      "hasn't by $time, Veylor claims your dollars itself. Keep Veylor open "
      'until then.';
  static const convertOpeningSlow =
      "The market maker hasn't opened the swap yet. Nothing has been sent.";
  static const convertCallOff = 'Call it off';
  static const convertCallOffFailed =
      "Couldn't call it off. Try again in a moment.";
  static const convertCallOffTooLate =
      "The swap opened on Ethereum meanwhile, so it can't be called off. It "
      'carries on.';
  static const convertUnsettled =
      'The market maker called the swap off while your ZEC payment was still '
      'unconfirmed. If it goes through, Veylor brings your ZEC back.';
  static const convertResuming = 'Picking up where it left off.';
  static const convertRefunding =
      'The swap was called off. Veylor is bringing your ZEC back to your '
      'wallet.';
  static const convertUnwinding =
      "The swap couldn't be completed in time, so it unwinds: your ZEC comes "
      "back after the market maker's refund.";

  /// [convertUnwinding], and when Veylor claims instead: [time] is the
  /// record's `lateClaimAt`.
  static String convertUnwindingUntil(String time) =>
      "$convertUnwinding If the market maker hasn't refunded by $time, "
      'Veylor claims your dollars instead.';
  static const convertBackgroundNote =
      "Keep Veylor open until this finishes. If you leave, it pauses and picks "
      "up when you're back.";

  static const convertProgressInfoTitle = "What's happening";
  static const convertProgressInfoOpen =
      'The market maker opens the swap on Ethereum and puts the dollars in '
      'it.';
  static const convertProgressInfoDeposit =
      'Veylor sends your ZEC to the deposit address you and the market maker '
      'share.';
  static String convertProgressInfoConfirm(int confirmations) =>
      'The market maker waits for $confirmations Zcash '
      '${confirmations == 1 ? 'confirmation' : 'confirmations'}.';
  static const convertProgressInfoClaim =
      'Veylor claims the dollars into your private balance. A relayer pays the '
      'Ethereum fees.';
  static String convertProgressInfoScreen(String about) =>
      'Railgun screens them for $about before they can be spent.';
  static const convertProgressInfoRefund =
      "If the swap can't finish in time, it's called off and your ZEC comes "
      'back, less a small network fee.';

  static const progressTab = 'Bridge progress';
  static const detailSwapId = 'Swap ID';
  static const detailDeposit = 'ZEC deposit';
  static const detailPayout = 'Payout';
  static const detailRefund = 'ZEC refund';
  static const detailStarted = 'Started';
  static const detailFunding = 'Escrow payment';
  static const detailZecReceived = 'ZEC received';

  // ── Convert: problems (after a minute of failures) ────────────────────

  static const convertProblemTitle = 'Taking longer than usual';
  static const convertProblemRetry = 'Try now';
  static const convertProblemRelayer =
      "Veylor can't reach the relayer that sends your claim. It keeps trying "
      "while it's open.";
  static const convertProblemRelayerRefused =
      "The relayer keeps turning down this bridge's transaction. Veylor "
      "keeps trying while it's open.";
  static const convertProblemRelayerFee =
      "The relayer's fee is more than this bridge pays out, or above the "
      '2 USDC limit, so Veylor waits for it to come down.';
  static const convertProblemEthereum =
      "Veylor can't reach Ethereum right now. It keeps trying while it's open.";
  static const convertProblemRailgun =
      "Railgun isn't accepting deposits right now, so Veylor holds off "
      "claiming. If it doesn't reopen in time, the swap is called off and "
      'your ZEC comes back.';
  static const convertProblemWallet =
      "Veylor couldn't complete this step with your Zcash wallet. It will "
      'keep trying while open and unlocked.';
  static const convertProblemUnpayable =
      "Your wallet can't pay the deposit right now, for example because the "
      'network fee went up. Veylor keeps trying. If it still can\'t pay in '
      'time, the swap ends and nothing is sent.';
  static const convertProblemRejected =
      'The Zcash network turned down a transaction of this bridge. Veylor '
      'keeps sending it until it goes through or expires.';
  static const convertProblemMismatch =
      "What's on the chain doesn't match this bridge, so Veylor only "
      'brings your funds back.';
  static const convertProblemRoute =
      "Tor is starting or unavailable. Veylor keeps trying while it's open.";
  static const convertProblemUnexpected =
      "Something went wrong. Veylor keeps trying while it's open.";

  // ── Convert: results (forward) ────────────────────────────────────────

  static const convertResultPaidTitle = 'Dollars on their way';
  static String convertResultPaidBody(String usd, String about) =>
      '$usd is in your private balance. Railgun screens new funds for $about '
      'before they can be spent.';
  static String convertResultScreenedBody(String usd) =>
      '$usd is in your private balance, ready to use.';
  static const convertResultRefundedTitle = 'Your ZEC came back';
  static const convertResultRefundedMaker =
      'The market maker called the swap off, so your ZEC came back to your '
      'wallet, less a small network fee.';
  static const convertResultRefundedLate =
      "The swap couldn't be completed in time, so it was called off and your "
      'ZEC came back, less a small network fee.';
  static const convertResultNothingTitle = 'Nothing was sent';
  static const convertResultQuoteExpired =
      'The quote expired before the market maker took it. Your ZEC never '
      'left your wallet.';
  static const convertResultMakerRefused =
      'The market maker turned the bridge down. Your ZEC never left your '
      'wallet.';
  static const convertResultMakerUnavailable =
      "The market maker isn't taking bridges right now. Your ZEC never "
      'left your wallet.';
  static const convertResultNeverOpened =
      'The swap never opened on Ethereum. Your ZEC never left your wallet.';
  static const convertResultMismatch =
      "The swap on Ethereum didn't match its quote, so Veylor didn't send your "
      'ZEC.';
  static const convertResultWindowMissed =
      "The swap opened too late to finish safely, so Veylor didn't send your "
      'ZEC.';
  static const convertResultMakerCancelled =
      'The market maker called the swap off before your ZEC was sent. Your '
      'ZEC never left your wallet.';
  static const convertResultViewBalance = 'View private USD';
  static const convertResultTryAgain = 'Try again';

  // ── Reverse: amount, review and info ──────────────────────────────────

  static const convertSwapDirection = 'Swap bridge direction';
  static const reverseInsufficient =
      'Not enough private USD for this amount and its fees.';
  static const reverseErrorMax =
      "Couldn't work out the most you can bridge. Try again in a moment.";

  /// Whole cents: Rust refuses finer reverse amounts.
  static const reverseAmountCents = 'Use at most 2 decimal places.';
  static const reverseErrorFundingUnavailable =
      'Bridging to ZEC is unavailable right now. Try again later.';
  static const reverseErrorCostChanged =
      'The fees changed, so nothing was paid. Review the new total, then pay '
      'it or cancel.';

  static const reverseTitle = 'Private USD to ZEC';
  static const reverseIntro =
      'Approve sending private USD first. After your wallet confirms the full '
      'ZEC deposit itself, approve settlement to receive shielded ZEC.';
  static const reverseRefundNote =
      'Before you approve settlement, you can cancel. After that, a refund '
      "waits for the contract deadline. A refund pays the relayer's fee and "
      "Railgun's shielding fee. Closing Veylor never approves settlement.";
  static String reverseKeepOpen(String time) =>
      'Keep Veylor open after you pay. Once the ZEC is confirmed, you approve '
      "settlement here by $time. If you don't, your private USD is refunded, "
      'less fees.';

  static const reverseEscrow = 'Escrow value';
  static const reverseRailgunFee = 'Railgun unshield fee';
  static const reverseBroadcasterFee = 'Broadcast fee';
  static const reverseTotal = 'Total paid';
  static const reverseReceiveEstimate = 'Estimated ZEC after sweep fee';
  static const reverseProblemRelayer =
      "Veylor can't reach the relayer that moves your dollars. It keeps trying "
      "while it's open.";

  // ── Reverse: progress, results and actions ────────────────────────────

  static const reverseAccepting = 'Preparing your receiving account';
  static const reverseReview = 'Review and approve your payment';
  static const reverseStepFund = 'Sending private USD to escrow';

  /// [reverseStepFund] while it waits for the user's tap: theirs to take,
  /// not a payment already going.
  static const reverseStepPay = 'Pay private USD to escrow';
  static String reverseStepPayDetail(String debit) =>
      'Tap Pay to send $debit of private USD to escrow.';

  static const reverseSending = 'Sending private USD';
  static const reverseConfirming = 'Confirming escrow';
  static const reverseReceiving = 'Waiting for confirmed ZEC';
  static const reverseReady = 'Authorize settlement';
  static const reverseStepApprovalDetail =
      'Your approval is needed to continue.';
  static const reverseReadyExplanation =
      'The full ZEC deposit is confirmed. Authorize settlement to release '
      'your private USD and move ZEC to your shielded wallet.';
  static const reverseStepSettle = 'Settling your bridge';
  static const reverseSettling = 'Waiting for settlement';
  static const reverseSweeping = 'Moving ZEC to your wallet';
  static String reverseSweepConfirmations(int count) =>
      'Zcash confirmations: $count';
  static const reverseRefundWait =
      "Waiting until a refund can proceed. Veylor retries while it's open.";
  static const reverseRefunding = 'Securing your private refund';
  static const reversePayout = 'Returning your private USD to Railgun';
  static const reverseComplete = 'ZEC received in your shielded wallet';
  static const reverseRefunded =
      'Private refund paid. Railgun screening may delay availability.';
  static const reverseCancelled =
      'Bridge cancelled. No escrow payment remains.';

  static String reverseProgressAmounts(String usd, String zec) =>
      '$usd for $zec after fees';
  static String reverseProgressEstimate(String usd, String zec) =>
      '$usd for about $zec after fees';
  static String reverseProgressReceived(String zec) =>
      '$zec arrived after fees.';

  static const reverseResultReceived = 'ZEC received';
  static const reverseResultRefunded = 'Refund sent';
  static const reverseResultCancelled = 'Bridge cancelled';
  static const reverseNew = 'New bridge';
  static const reverseCancel = 'Cancel bridge';
  static const reverseRequestRefund = 'Request refund';

  static const reverseCancelConfirmTitle = 'Cancel this bridge?';
  static const reverseCancelConfirmBody =
      "Your private USD comes back, less the relayer's and Railgun's fees. "
      "This can't be undone.";
  static const reverseCancelConfirmUnpaidBody =
      "Nothing has been paid yet, so nothing is lost. This can't be undone.";

  static const reverseRefundRequested =
      "Refund requested. Veylor continues when your refund is available, while "
      "it's open.";
  static String reverseSettlementRefundLimit(String time) =>
      'Settlement is authorized. A refund can only proceed after $time if '
      "settlement hasn't completed.";
  static const reverseRefundUnavailable =
      'This bridge has already settled and can no longer be refunded. '
      'Veylor will finish moving your ZEC to your wallet.';
  static const reverseError =
      'Unable to complete this step. Your saved bridge resumes after '
      'Veylor checks both chains. A payment is never repeated because a '
      'request timed out.';
  static const reverseErrorUnconfirmed =
      "The market maker's ZEC isn't confirmed yet. Try again in a few minutes.";
  static const reverseErrorTooLate =
      "It's too late for this step, so the bridge ends by itself. "
      'Anything you paid comes back.';

  static String reversePay(String debit) => 'Pay $debit';
  static const reverseProvingNote =
      'Your phone builds a zero-knowledge proof of the payment. This can take '
      'a few minutes. Keep Veylor open.';

  // An outgoing payment in flight (a send, a withdrawal or an escrow
  // payment), told with observed numbers only.
  static String paymentProving(int percent) =>
      'Proving your payment · $percent%';
  static String paymentWaitingForBlock(String elapsed) =>
      'Waiting for a block · $elapsed';
  static const paymentUpdatingBalance = 'Updating your balance';

  // ── Refunds ────────────────────────────────────────────────────────────

  static const refundsTitle = 'Refunds';
  static const refundsSubtitle = 'Refunds from earlier bridges';
  static const refundsInfo =
      "If a refund couldn't enter your private balance, recover it here. "
      'Railgun screening may delay availability.';
  static const refundsOriginalAmount = 'Original bridge amount';
  static const refundsEmpty = 'No refunded bridges yet.';
  static const refundsChecking = 'Checking refunds…';
  static const refundsAvailable = 'This refund can be recovered.';
  static const refundsNoRecovery =
      'No recovery available right now. Your refund may still be going '
      'through Railgun screening.';
  static const refundsRecover = 'Recover refund';
  static const refundsRecovering = 'Recovering your refund…';
  static const refundsCheckFailed =
      "Couldn't check this refund. Refresh to try again.";
  static const refundsRecoverFailed =
      "Couldn't recover this refund. Try again.";
  static const refundsRecoverConfirmTitle = 'Recover this refund?';

  /// Rust reads the relayer's fee only as it signs, so the sheet names its
  /// cap.
  static String refundsRecoverConfirmBody(String cap) =>
      "The relayer's fee, at most $cap, comes out of the refund.";

  static const refundsDepositTitle = 'Deposit sent back by screening';
  static String refundsDepositBody(String usd) =>
      "Railgun's screening sent $usd back to your deposit address's vault. "
      'Recover it to make it private again.';
  static const refundsDepositRecover = 'Recover deposit';
  static const refundsDepositRecovering = 'Recovering your deposit…';
  static const refundsDepositRecoverFailed =
      "Couldn't recover this deposit. Try again.";
  static const refundsDepositConfirmTitle = 'Recover this deposit?';

  /// A rescue pays the relayer's fee alone, at most the cap.
  static String refundsDepositConfirmBody(String fee) =>
      "The relayer's fee, $fee, comes out of it.";

  // ── Deposits ───────────────────────────────────────────────────────────

  static String depositTitle(String symbol) => 'Receive $symbol';
  static String depositOnly(String symbol, String chain) =>
      'Only $symbol on $chain';
  static const depositHow =
      'Send it from an exchange or any wallet. Veylor makes it private on '
      'its own while it is open and unlocked.';
  static String depositMinimum(String usd) => 'Minimum $usd';
  static String depositRelayerFee(String fixed, String percent) =>
      'Relayer fee: $fixed + $percent%';
  static String depositRailgunFee(String percent) => "Railgun's fee: $percent%";
  static String depositExample(String sent, String arrives) =>
      'Sending $sent brings $arrives after both fees.';
  static const depositFeesLoading = 'Loading the fees…';
  static const depositFeesFailed =
      "Couldn't load the fees. Money sent here waits safely at this address.";
  static const depositUnavailable =
      'Deposits are unavailable right now. Nothing sent to an earlier '
      'deposit address is lost: it waits there.';
  static const depositAddressLoading = 'Loading your deposit address…';
  static const depositAddressFailed =
      "Couldn't load your deposit address. Try again in a moment.";
  static const depositCopy = 'Copy deposit address';

  static String depositReceived(String usd) => 'Received $usd';
  static String depositUnderMinimum(String usd, String minimum) =>
      'Received $usd, under the $minimum minimum. Send more to this address.';
  static const depositMakingPrivate = 'Making it private…';
  static String depositPrivate(String about) => 'Private, available in $about';
  static const depositWaiting =
      'Waiting for the network; your money is safe at your deposit address';
  static const depositNotShielding =
      "Received, but not made private yet. Veylor tries again later; your "
      'money is safe at your deposit address.';
  static String depositWaitingLine(String usd) =>
      '${depositReceived(usd)}. $depositWaiting';
  static String depositMakingPrivateLine(String usd) =>
      '${depositReceived(usd)}. $depositMakingPrivate';
  static String depositPrivateLine(String usd, String about) =>
      '$usd: ${depositPrivate(about)}';
  static String depositNotShieldingLine(String usd) =>
      '${depositReceived(usd)}. $depositNotShielding';

  static const depositsTitle = 'Deposits';
  static const activityDeposit = 'Deposit';
  static const activityDepositRescue = 'Recovered deposit';
  static const activityDepositPrivate = 'Now private';

  // ── Accounts and reset ─────────────────────────────────────────────────

  static const deleteUnfinishedTitle = 'Bridge in progress';
  static String deleteUnfinishedBody(int count) =>
      'This account has $count unfinished private USD '
      '${_conversions(count)}. Only this account can recover their funds, '
      'so deleting it now can lose them. Keep Veylor open until they finish '
      'or are refunded.';
  static String resetUnfinishedBody(int count) =>
      'Your wallet has $count unfinished private USD ${_conversions(count)}. '
      'Only this wallet can recover their funds, so resetting now can lose '
      'them.';
  static const deleteUncheckedBody =
      "Couldn't check for unfinished private USD bridges. Only this account "
      'can recover their funds, so deleting it now can lose them.';
  static const resetUncheckedBody =
      "Couldn't check for unfinished private USD bridges. Only this wallet "
      'can recover their funds, so resetting now can lose them.';
  static const deleteAnyway = 'Delete anyway';
  static const resetAnyway = 'Reset anyway';

  static String _conversions(int count) => count == 1 ? 'bridge' : 'bridges';

  // ── Send and withdraw ──────────────────────────────────────────────────

  static const sendTitle = 'Send privately';
  static const sendAsset = 'Asset';
  static const sendAmount = 'Amount';
  static const sendToPrivate = 'To a Railgun address';
  static const sendToWithdraw = 'To an Ethereum address';
  static const sendHintPrivate = '0zk1…';
  static const sendHintWithdraw = '0x…';
  static const sendInvalid0zk = "That isn't a Railgun 0zk address.";
  static const sendInvalid0x = "That isn't an Ethereum address.";
  static const sendZeroAddress =
      "That's the zero address: anything sent there is lost for good.";

  static const scanCaptionPrivate = 'Scan a Railgun 0zk address';
  static const scanCaptionWithdraw = 'Scan an Ethereum 0x address';
  static const scanPermissionTitle = "Scan the recipient's address";
  static const scanNot0zk = "This QR code isn't a Railgun 0zk address.";
  static const scanNot0x = "This QR code isn't an Ethereum address.";
  static const scanUseWithdraw =
      'This is a public 0x address. To send to it, use Withdraw.';
  static const scanUseSend =
      'This is a private 0zk address. To pay it, use Send.';
  static const scanOtherNetwork = 'This QR code is for another network.';

  static const sendTooMuch = 'More than you have available.';
  static String sendLeaveNetworkFee(String fee) =>
      'Leave $fee for the network fee.';
  static String sendTooPrecise(int decimals) =>
      'Use at most $decimals decimal ${decimals == 1 ? 'place' : 'places'}.';
  static const sendBalanceDropped =
      'Your available balance is now less than this amount.';
  static const sendWithdrawPublic =
      'Anyone on Ethereum can see this amount and address.';

  static const sendReviewTitlePrivate = 'Review send';
  static const sendReviewTitleWithdraw = 'Review withdrawal';
  static String sendReviewRailgunFee(String percent) =>
      'Railgun fee ($percent%)';
  static const sendReviewReceives = 'They receive';
  static const sendReviewTo = 'To';
  static const sendErrorFeeCap =
      'The network fee is above the 2 USDC limit right now, so nothing was '
      'sent. Try again later.';
  static const sendErrorStore =
      "Veylor can't read its saved payments. $supportSentence";

  static const sendProving = 'Proving your transaction';
  static String sendProvingPercent(int percent) =>
      'Proving your transaction · $percent%';
  static const sendProvingDetail =
      'Your phone builds a zero-knowledge proof so nobody can see what you '
      'send. This takes a few seconds. Keep Veylor open.';
  static const sendSending = 'Sending';
  static const sendLanding =
      'The relayer is sending it. Waiting for a block can take a minute. '
      'Keep Veylor open.';

  static const sendDoneTitlePrivate = 'Sent';
  static const sendDoneTitleWithdraw = 'Withdrawn';
  static String sendDoneBody(String amount, String address) =>
      '$amount went to $address.';
  static String sendDoneUnconfirmedBody(String amount, String address) =>
      '${sendDoneBody(amount, address)} $sendUnconfirmed';
  static const sendViewTx = 'View on Etherscan';
  static const sendNotSent = 'Nothing was sent. Try again in a moment.';
  static const sendUnavailable =
      'Private sends are unavailable right now. Nothing was sent. Try again '
      'later.';
  static String sendFeeRose(String fee) =>
      'The network fee went up to $fee. Nothing was sent.';
  static const sendUnconfirmed =
      "It isn't in a block yet. Check your activity before sending again.";

  static const sendInfoTitle = 'Sending privately';
  static const sendInfoStepAddress =
      "Enter the amount and the recipient's Railgun address, which starts "
      'with 0zk.';
  static const sendInfoStepProof =
      'Your phone builds a zero-knowledge proof. This takes a few seconds.';
  static const sendInfoStepPrivate =
      'The dollars move inside Railgun: nobody else sees the amount, or who '
      'sent and received it.';
  static const withdrawInfoTitle = 'Withdrawing makes it public';
  static const withdrawInfoStepAddress =
      'Enter the amount and an Ethereum address, which starts with 0x.';
  static const withdrawInfoStepProof =
      'Your phone builds a proof, and the dollars leave Railgun for that '
      'address.';
  static const withdrawInfoNotePublic =
      'Once withdrawn, the amount and the address are visible to anyone on '
      'Ethereum.';
  static const withdrawInfoNotePrivate =
      "To stay private, don't withdraw the exact amount you just bridged, "
      'wait a while first, and use a fresh address each time.';
  static String withdrawInfoNoteFee(String percent) =>
      'Railgun keeps $percent% of what you withdraw.';

  // ── Settings: the user's own Ethereum RPC ──────────────────────────────

  static const rpcTitle = 'Ethereum RPC';
  static const rpcDefault = 'Default';

  /// [value] is [rpcDefault] or the URL's host, never the URL: it can hold
  /// a key.
  static String rpcCurrent(String value) => 'Current: $value';
  static const rpcNetworkSepolia = 'Sepolia';
  static const rpcNetworkMainnet = 'Ethereum mainnet';
  static String rpcBody(String network) =>
      'Use your own Alchemy, Infura or publicnode URL for $network. Private '
      'USD then uses only it.';
  static const rpcSees =
      "The RPC sees the app's Ethereum requests, and your IP address unless "
      'Tor is on.';
  static const rpcHint = 'https://';
  static const rpcCheckAndSave = 'Check and save';
  static const rpcChecking = 'Checking…';
  static const rpcUseDefault = 'Use the default';
  static String rpcErrorUrl(String network) =>
      'Use an https Alchemy, Infura or publicnode URL for $network.';
  static const rpcErrorUnreachable =
      "That RPC didn't answer. Check the URL, or try again in a moment.";
  static String rpcErrorWrongChain(String network) =>
      'That RPC is for another network. Use one for $network.';
  static const rpcErrorSave = "Couldn't save the setting. Try again.";
  static const rpcSaved = 'Ethereum RPC saved';
  static const rpcCleared = 'Using the default Ethereum RPC';
  static const rpcNotAnswering = "Your Ethereum RPC isn't answering.";
}
