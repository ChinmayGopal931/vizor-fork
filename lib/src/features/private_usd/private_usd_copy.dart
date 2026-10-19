import '../../core/config/private_usd_feature_config.dart';
import '../../rust/api/private_usd.dart'
    show ApiNothingSentCause, ApiPrivateUsdErrorCode, ApiRefundCause;
import 'services/private_usd_spend_guard.dart' show PrivateUsdSpendStatus;

/// Every user-facing Private USD string (plan reference §9.6), sentence case,
/// in one place so widgets, tests and Widgetbook share it. The comment on
/// each is zapp's key, for provenance. "Private USD" is the feature's name:
/// capitalized at the start of a sentence and as a title, "private USD"
/// mid-sentence.
///
/// M3 holds the Shared, Home, Private USD screen and Activity tables, M5 the
/// Convert and Accounts tables, M6 the Reverse and Refunds tables, M7 the
/// Send and withdraw table.
abstract final class PrivateUsdCopy {
  // ── Shared ─────────────────────────────────────────────────────────────

  /// `private_usd_title`
  static const title = 'Private USD';

  /// `private_usd_about_minutes` / `_hours`
  static String about(Duration duration) {
    final minutes = duration.inMinutes < 1 ? 1 : duration.inMinutes;
    return minutes < 60 ? 'about $minutes min' : 'about ${minutes ~/ 60} h';
  }

  /// `private_usd_info_content_description`
  static const infoButton = 'How this works';

  /// `private_usd_worth`: now the ZEC equivalent.
  static String worth(String zec) => '≈ $zec';

  /// `private_usd_home_loading`
  static const loading = 'Loading…';

  /// `private_usd_home_unknown`
  static const unknown = '—';

  /// `private_usd_refresh`
  static const refresh = 'Refresh';

  /// `private_usd_updating`
  static const updating = 'Updating…';

  /// `private_usd_updated`
  static String updated(String time) => 'Updated $time';

  /// `convert_review`
  static const review = 'Review';

  /// `convert_result_done`
  static const done = 'Done';

  /// `private_usd_use_available` (accessibility label)
  static const useAvailable = 'Use it all';

  /// New: vizor's visible label for using it all (as send has it).
  static const max = 'Max';

  /// New (D17): a link to `VIZOR_SUPPORT_URL` when that define is set.
  static const supportSentence = 'Contact support.';

  /// Whether [supportSentence] links somewhere.
  static bool get hasSupportLink => kVizorSupportUrl.isNotEmpty;

  // ── Home ───────────────────────────────────────────────────────────────

  /// `private_usd_home_arriving`
  static String homeArriving(String usd) => '+$usd arriving';

  /// `private_usd_home_arriving_description`
  static String homeArrivingDescription(String usd) => '$usd arriving';

  /// `private_usd_home_blocked`
  static String homeBlocked(String usd) => '$usd needs attention';

  /// `private_usd_home_blocked_description`
  static String homeBlockedDescription(String usd) => 'Needs attention: $usd';

  /// `private_usd_home_content_description`
  static const homeOpen = 'Open private USD';

  /// `private_usd_banner_title`
  static const bannerToUsd = 'Converting to private USD';

  /// `private_usd_converting_zec`
  static const bannerToZec = 'Converting to ZEC';

  /// `private_usd_banner_attention_title`
  static const bannerAttention = 'Conversion needs attention';

  /// `private_usd_banner_view`
  static const bannerView = 'View';

  /// New: the indicative ZEC equivalent of the balance.
  static String homeZecEquivalent(String zec) => '≈ $zec ZEC';

  /// New (F): the banner detail's suffix while a key step is pending.
  static const bannerKeepOpen = 'Keep Veylor open to finish';

  // ── Private USD screen ─────────────────────────────────────────────────

  /// `private_usd_subtitle`
  static const subtitle = '0zkUSDC held on Ethereum';

  /// `private_usd_breakdown_note`
  static const breakdownNote =
      'Held separately and privately, on Ethereum through Railgun.';

  /// `private_usd_row_available`
  static const rowAvailable = 'Available';

  /// `private_usd_row_processing`
  static const rowProcessing = 'Processing';

  /// `private_usd_row_processing_info`
  static const rowProcessingInfo =
      'A send is being confirmed. These funds are available again once it '
      'settles.';

  /// `private_usd_row_arriving`
  static const rowArriving = 'Arriving';

  /// New (owner, 2026-10-17): the row while its funds are screened, with
  /// the share of the screening time gone by since they landed.
  static String rowArrivingPercent(int percent) => '$rowArriving · $percent%';

  /// New (owner, 2026-10-17): the row once the screening time has passed
  /// and the funds are still arriving.
  static const rowArrivingLate = '$rowArriving · taking longer than usual';

  /// `private_usd_row_arriving_info`
  static String rowArrivingInfo(String about) =>
      'Railgun screens new funds before they can be spent. This takes $about.';

  /// `private_usd_row_blocked`
  static const rowBlocked = 'Screening refused';

  /// `private_usd_row_blocked_info` (B, D17)
  static const rowBlockedInfo =
      "Railgun's screening refused these funds, so they can't be spent or "
      'sent. They can only go back to where they came from, the conversion '
      'contract. $supportSentence';

  /// `private_usd_assets_title`
  static const assetsTitle = 'Assets';

  /// `private_usd_token_usdc`
  static const tokenUsdc = 'USD Coin';

  /// `private_usd_token_test_usd`
  static const tokenTestUsd = 'Test dollar';

  /// A dollar token's name by its symbol.
  static String tokenName(String symbol) =>
      symbol == 'tUSD' ? tokenTestUsd : tokenUsdc;

  /// `private_usd_action_convert`
  static const actionConvert = 'Convert';

  /// `private_usd_action_send`
  static const actionSend = 'Send';

  /// `private_usd_action_withdraw`
  static const actionWithdraw = 'Withdraw';

  /// `private_usd_first_load` (F)
  static const firstLoad =
      "Loading your private balance. The first time reads Railgun's history "
      'and can take a while. Keep Veylor open.';

  /// `private_usd_first_load_progress` (F)
  static String firstLoadProgress(int percent) =>
      'Loading your private balance: $percent%. The first time reads '
      "Railgun's history and can take a while. Keep Veylor open.";

  /// `private_usd_refresh_failed`
  static const refreshFailed =
      "Couldn't update the balance. Showing the last known amounts.";

  /// `private_usd_load_failed`
  static const loadFailed = "Couldn't load the balance. Try again in a moment.";

  /// New (owner, 2026-10-17): the sync line's readouts on this screen, drawn
  /// uppercase. The line is Railgun's, so it says so; Home's and the Tor
  /// readouts are unchanged.
  static String syncReadoutProgress(int percent) => 'Railgun sync $percent%';

  static const syncReadoutSynced = 'Railgun synced';
  static const syncReadoutFailed = 'Railgun sync failed';

  /// `private_usd_empty_title`
  static const emptyTitle = 'No private dollars yet';

  /// `private_usd_empty_body`
  static const emptyBody =
      'Convert ZEC into dollars nobody else can see: not your balance, and '
      'not who you pay.';

  /// `private_usd_receive_address`: since M9 the `0zk` card is the way to
  /// receive from another Railgun wallet.
  static const receiveAddress = 'Receive from a Railgun wallet';

  /// New (M9): under that card's title.
  static const receiveAddressNote =
      'Private USD from another Railgun wallet arrives here, with no fee.';

  /// `private_usd_copy_address`
  static const copyAddress = 'Copy your private USD address';

  /// New: the toast after copying the address.
  static const addressCopied = 'Address copied';

  /// `private_usd_checking_payments`
  static const checkingPayments = 'Checking pending payments…';

  /// `private_usd_payment_pending`
  static const paymentPending =
      "A previous payment is still pending. You can send or convert again "
      "once it's confirmed.";

  /// `private_usd_conversion_pending`
  static const conversionPending =
      'A conversion is in progress. Sending will be available when it '
      'finishes.';

  /// `private_usd_info_title`
  static const infoTitle = 'About private USD';

  /// `private_usd_info_step_convert` (S)
  static const infoConvert = 'Convert: exchange ZEC and private USD.';

  /// `private_usd_info_receive` (B; M9: both ways money comes in)
  static const infoReceive =
      'Receive: public USDC from an exchange or any wallet goes to your '
      'deposit address (Receive), and Veylor makes it private for a small '
      'fee. Private USD from another Railgun wallet goes to your Railgun '
      'address on this screen, with no fee.';

  /// `private_usd_info_send`
  static const infoSend =
      'Send: transfer private USD to another Railgun address. The recipient '
      'receives it privately.';

  /// `private_usd_info_withdraw`
  static const infoWithdraw =
      'Withdraw: move private USD to a public Ethereum address. The '
      'destination and amount are visible on Ethereum.';

  /// `private_usd_info_refunds`
  static const infoRefunds =
      "Refunds: recover a refund that couldn't enter your private balance.";

  /// `private_usd_info_step_screen`
  static String infoScreening(String about) =>
      'Railgun screens new funds for $about before they can be spent.';

  /// `private_usd_info_note_private`
  static const infoPrivate =
      'Nobody else can see your balance, or who you pay.';

  /// New (F)
  static const infoKeepOpen =
      'Conversions, sends and refunds run only while Veylor is open and '
      'unlocked.';

  /// New (T): only if the D4 bridge had failed. It did not (M0.3), so
  /// nothing shows it today.
  static const torUnavailable =
      'Private USD is unavailable while Tor is on. Turn off Tor in Settings '
      'to use it. Conversions already under way continue.';

  /// New: the close button of the info sheet.
  static const close = 'Close';

  // ── Activity ───────────────────────────────────────────────────────────

  /// `private_usd_activity_title`
  static const activityTitle = 'Activity';

  /// `private_usd_activity_empty`
  static const activityEmpty =
      'Your conversions, sends and withdrawals will show here.';

  /// `private_usd_activity_converting`
  static const activityConverting = 'Converting ZEC';

  /// `private_usd_activity_converted`
  static const activityConverted = 'Converted ZEC';

  /// `private_usd_activity_converted_zec`
  static const activityConvertedToZec = 'Converted to ZEC';

  /// Reverse under way (reference §9.4 S2).
  static const activityConvertingToZec = 'Converting to ZEC';

  /// `private_usd_activity_refunded`
  static const activityRefunded = 'Conversion called off';

  /// `private_usd_activity_refunded_detail`
  static const activityRefundedDetail = 'your ZEC came back';

  /// `private_usd_activity_refunded_zec_detail`
  static const activityRefundedZecDetail = 'your dollars came back';

  /// `private_usd_activity_sent`
  static const activitySent = 'Sent privately';

  /// `private_usd_activity_withdrew`
  static const activityWithdrew = 'Withdrew';

  /// `private_usd_activity_detail`
  static String activityDetail(String a, String b) => '$a · $b';

  /// `private_usd_activity_to`
  static String activityTo(String address) => 'to $address';

  /// `private_usd_activity_in`
  static String activityIn(String usd) => '+$usd';

  /// `private_usd_activity_out`
  static String activityOut(String usd) => '−$usd';

  /// `private_usd_activity_sending`
  static const activitySending = 'sending…';

  /// `private_usd_activity_unconfirmed`
  static const activityUnconfirmed = 'not in a block yet';

  /// `private_usd_activity_open_conversion`
  static const activityOpenConversion = 'Open conversion';

  /// `private_usd_activity_open_transaction`
  static const activityOpenTransaction = 'View transaction';

  /// `refunds_view`
  static const refundsView = 'View refunds';

  // ── Convert (both directions): amount and quote ─────────────────────

  /// `convert_title`
  static const convertTitle = 'Convert';

  /// `convert_asset_zec`
  static const convertAssetZec = 'ZEC';

  /// `convert_zec_includes_fee`
  static const convertZecIncludesFee = 'Includes the Zcash network fee';

  /// `convert_estimated_amount`
  static const convertEstimatedAmount = 'Estimated amount';

  /// `convert_you_pay`
  static const convertYouPay = 'You pay';

  /// `convert_network_fee`
  static const convertNetworkFee = 'Network fee';

  /// `convert_you_receive`
  static const convertYouReceive = 'You receive about';

  /// `convert_fees`
  static const convertFees = 'Conversion fees';

  /// `convert_fees_value`
  static String convertFeesValue(String relayerUsd, String railgunPercent) =>
      '$relayerUsd relayer · $railgunPercent% Railgun';

  /// `convert_maker_cost`
  static const convertMakerCost = "Market maker's network cost";

  /// `convert_quote_expires` (S): vizor's wording.
  static String convertQuoteExpires(String minutesSeconds) =>
      'Quote expires in $minutesSeconds';

  /// `convert_quote_holds`
  static String convertQuoteHolds(String minutesSeconds) =>
      'Quote holds for $minutesSeconds';

  /// New: vizor's expired-quote label.
  static const quoteExpired = 'Quote expired';

  /// `convert_quote_loading`
  static const convertQuoteLoading = 'Getting quote…';

  /// `convert_new_quote` (S): vizor's label.
  static const convertNewQuote = 'Refresh quote';

  /// `convert_quote_ran_out` (S)
  static const convertQuoteRanOut =
      'This quote expired. Refresh it to continue.';

  /// `convert_quote_clock_ahead`
  static const convertQuoteClockAhead =
      "The quote had expired by the time it arrived. Check that your phone's "
      'clock is right, then try again.';

  /// `convert_insufficient`
  static String convertInsufficient(String zec) =>
      'Not enough ZEC. You have $zec available.';

  /// `convert_zec_syncing`
  static const convertZecSyncing =
      'Your wallet is still syncing. The rest of your ZEC is available once '
      'it catches up.';

  /// `convert_zec_syncing_progress`
  static String convertZecSyncingProgress(int percent) =>
      'Your wallet is still syncing ($percent%). The rest of your ZEC is '
      'available once it catches up.';

  /// `convert_zec_no_quote` (S)
  static const convertZecNoQuote =
      'No quote fits this amount. Try a different amount, or use it all for '
      'the maximum.';

  // ── Convert: errors before anything is sent ───────────────────────────

  /// `convert_error_maker`
  static const convertErrorMaker =
      "The market maker can't be reached right now. Try again in a moment.";

  /// `convert_error_maker_cant_fill`
  static const convertErrorMakerCantFill =
      "The market maker can't convert this much right now. Try a smaller "
      'amount, or try again later.';

  /// `convert_error_maker_busy`
  static const convertErrorMakerBusy =
      'The market maker is busy with other conversions. Try again in a few '
      'minutes.';

  /// `convert_error_amount_refused`
  static const convertErrorAmountRefused =
      "The market maker won't convert this amount. It may be over the limit "
      "for one conversion, or too small to cover the swap's network cost.";

  /// `convert_error_below_fee`
  static const convertErrorBelowFee =
      "This amount doesn't cover the relayer's fee. Try a larger amount.";

  /// New (D11): `convert_error_fee_cap`
  static const convertErrorFeeCap =
      "The relayer's fee is above the 2 USDC limit right now, so nothing was "
      'sent. Try again later.';

  /// `convert_error_no_tokens_today`
  static const convertErrorNoTokensToday =
      "This phone has used today's conversions. More are available after "
      'midnight UTC.';

  /// `convert_error_tokens_unavailable` (B, T)
  static const convertErrorTokensUnavailable =
      "Couldn't get this conversion's token, so nothing was sent. Try again "
      'in a moment.';

  /// `convert_error_device_refused` (B)
  static const convertErrorDeviceRefused =
      "This phone can't get conversion tokens. The token service turns away "
      'emulators, phones with an unlocked bootloader or a modified system, '
      "and app builds it doesn't recognize.";

  /// `convert_error_keystore` (B)
  static const convertErrorKeystore =
      "Veylor couldn't use this phone's secure key storage to get a conversion "
      'token, so nothing was sent. Try again in a moment.';

  /// `convert_error_relayer`
  static const convertErrorRelayer =
      "The relayer that completes conversions can't be reached right now. "
      'Try again in a moment.';

  /// `convert_error_relayer_refused`
  static const convertErrorRelayerRefused =
      'The relayer that completes conversions turned this down. Try again in '
      'a moment.';

  /// `convert_error_ethereum` (B)
  static const convertErrorEthereum =
      "Veylor can't reach Ethereum right now. Try again in a moment.";

  /// `convert_error_wallet`
  static const convertErrorWallet =
      "Veylor couldn't complete this step with your Zcash wallet. Try again "
      'in a moment.';

  /// `convert_error_unpayable`
  static const convertErrorUnpayable =
      "Your wallet can't pay this in one transaction right now. Try a smaller "
      'amount.';

  /// `convert_error_store` (B, D17)
  static const convertErrorStore =
      "Veylor can't read its saved conversions. $supportSentence";

  /// `convert_error_generic`
  static const convertErrorGeneric =
      "Couldn't get a quote. Try again in a moment.";

  /// `convert_start_failed`
  static const convertStartFailed =
      "The conversion couldn't start. Nothing was sent. Try again in a "
      'moment.';

  /// New (T): `route_blocked`
  static const routeBlocked =
      "Tor is starting or unavailable, so nothing was sent. Try again once "
      "it's connected.";

  // ── Convert: review and info ──────────────────────────────────────────

  /// `convert_review_title`
  static const convertReviewTitle = 'Review';

  /// `convert_review_arrow`
  static const convertReviewArrow = 'for about';

  /// `convert_info_title`
  static const convertInfoTitle = 'How converting works';

  /// `convert_info_step_quote`
  static const convertInfoStepQuote =
      'Enter the ZEC you want to convert, including the network fee. The '
      'market maker quotes how much private USD you receive. The quote holds '
      'for a few minutes.';

  /// `convert_info_step_deposit`
  static const convertInfoStepDeposit =
      'Your ZEC goes to a deposit address that you and the market maker '
      'control together.';

  /// `convert_info_step_claim` (B)
  static const convertInfoStepClaim =
      'Once the deposit is confirmed, Veylor claims the dollars into your '
      'private balance.';

  /// `convert_info_note_either`
  static const convertInfoNoteEither =
      'Either the dollars reach your private balance, or your ZEC comes back '
      'to you.';

  /// `convert_info_note_time` (B, F)
  static String convertInfoNoteTime(String about) =>
      'Takes $about. Keep Veylor open and unlocked until it\'s done. If you '
      "leave, it pauses; if it can't finish in time, it's called off and "
      'your ZEC comes back, less a network fee.';

  /// `convert_review_info_title`
  static const convertReviewInfoTitle = 'Before you convert';

  /// `convert_review_info_pay`
  static const convertReviewInfoPay =
      "You pay the ZEC deposit, which includes the market maker's network "
      'cost, plus the Zcash network fee.';

  /// `convert_review_info_receive`
  static String convertReviewInfoReceive(String railgunPercent) =>
      "You receive the dollars left after the relayer's fee and Railgun's "
      '$railgunPercent% fee for shielding them.';

  /// `convert_review_info_quote` (S)
  static const convertReviewInfoQuote =
      'The quote holds for a few minutes. If it expires, refresh it: nothing '
      'is sent until you convert.';

  /// New (T, D10): `tor_off_disclosure`. Shown only once Vizor fetches
  /// conversion tokens (M4); M5 converts without them.
  static const torOffDisclosure =
      "Tor is off, so the token service sees this phone's attestation "
      'together with your IP address.';

  // ── Convert: progress (forward) ───────────────────────────────────────

  /// `convert_progress_title`
  static const convertProgressTitle = 'Converting';

  /// `convert_progress_amounts`
  static String convertProgressAmounts(String zec, String usd) =>
      '$zec for about $usd';

  /// `convert_step_open`
  static const convertStepOpen = 'Opening the swap on Ethereum';

  /// `convert_step_deposit`
  static const convertStepDeposit = 'Sending your ZEC';

  /// `convert_step_confirm`
  static const convertStepConfirm = 'Waiting for confirmations';

  /// `convert_step_claim`
  static const convertStepClaim = 'Claiming your dollars';

  /// `convert_step_confirm_count`
  static String convertStepConfirmCount(int count, int of) => '$count of $of';

  /// `convert_step_arrive`
  static const convertStepArrive = 'Arriving in your private balance';

  /// `convert_step_screen`
  static const convertStepScreen = 'Screening';

  /// `convert_step_refund`
  static const convertStepRefund = 'Bringing your ZEC back';

  /// `convert_eta_seconds`
  static const convertEtaSeconds = 'A few seconds';

  /// `convert_eta_minute`
  static const convertEtaMinute = 'About a minute';

  /// `convert_wait_syncing`
  static const convertWaitSyncing = 'Waiting for your Zcash wallet to sync';

  /// `convert_maker_silent` (B, F)
  static String convertMakerSilent(String time) =>
      "The market maker hasn't confirmed your deposit yet. If it still "
      "hasn't by $time, Veylor claims your dollars itself. Keep Veylor open "
      'until then.';

  /// `convert_opening_slow`
  static const convertOpeningSlow =
      "The market maker hasn't opened the swap yet. Nothing has been sent.";

  /// `convert_call_off`
  static const convertCallOff = 'Call it off';

  /// `convert_call_off_failed`
  static const convertCallOffFailed =
      "Couldn't call it off. Try again in a moment.";

  /// `convert_call_off_too_late`
  static const convertCallOffTooLate =
      "The swap opened on Ethereum meanwhile, so it can't be called off. It "
      'carries on.';

  /// `convert_unsettled` (B)
  static const convertUnsettled =
      'The market maker called the swap off while your ZEC payment was still '
      'unconfirmed. If it goes through, Veylor brings your ZEC back.';

  /// `convert_resuming`
  static const convertResuming = 'Picking up where it left off.';

  /// `convert_refunding` (B)
  static const convertRefunding =
      'The swap was called off. Veylor is bringing your ZEC back to your '
      'wallet.';

  /// `convert_background_note` (B, F)
  static const convertBackgroundNote =
      "Keep Veylor open until this finishes. If you leave, it pauses and picks "
      "up when you're back.";

  /// `convert_progress_info_title`
  static const convertProgressInfoTitle = "What's happening";

  /// `convert_progress_info_open`
  static const convertProgressInfoOpen =
      'The market maker opens the swap on Ethereum and locks the dollars in '
      'it.';

  /// `convert_progress_info_deposit` (B)
  static const convertProgressInfoDeposit =
      'Veylor sends your ZEC to the deposit address you and the market maker '
      'share.';

  /// `convert_progress_info_confirm` (plural)
  static String convertProgressInfoConfirm(int confirmations) =>
      'The market maker waits for $confirmations Zcash '
      '${confirmations == 1 ? 'confirmation' : 'confirmations'}.';

  /// `convert_progress_info_claim` (B)
  static const convertProgressInfoClaim =
      'Veylor claims the dollars into your private balance. A relayer pays the '
      'Ethereum fees.';

  /// `convert_progress_info_screen`
  static String convertProgressInfoScreen(String about) =>
      'Railgun screens them for $about before they can be spent.';

  /// `convert_progress_info_refund`
  static const convertProgressInfoRefund =
      "If the swap can't finish in time, it's called off and your ZEC comes "
      'back, less a small network fee.';

  /// New: the progress tab of the step list.
  static const progressTab = 'Conversion progress';

  /// New: the details tab's rows.
  static const detailSwapId = 'Swap ID';
  static const detailDeposit = 'ZEC deposit';
  static const detailPayout = 'Payout';
  static const detailRefund = 'ZEC refund';
  static const detailStarted = 'Started';

  /// New (M6): the reverse details tab's rows.
  static const detailFunding = 'Escrow payment';
  static const detailZecReceived = 'ZEC received';

  // ── Convert: problems (after a minute of failures) ────────────────────

  /// `convert_problem_title`
  static const convertProblemTitle = 'Taking longer than usual';

  /// `convert_problem_retry`
  static const convertProblemRetry = 'Try now';

  /// `convert_problem_relayer` (B, F)
  static const convertProblemRelayer =
      "Veylor can't reach the relayer that sends your claim. It keeps trying "
      "while it's open.";

  /// `convert_problem_relayer_refused` (B, F)
  static const convertProblemRelayerRefused =
      "The relayer keeps turning down this conversion's transaction. Veylor "
      "keeps trying while it's open.";

  /// `convert_problem_relayer_fee` (B, N)
  static const convertProblemRelayerFee =
      "The relayer's fee is more than this conversion pays out, or above the "
      '2 USDC limit, so Veylor waits for it to come down.';

  /// `convert_problem_ethereum` (B, F)
  static const convertProblemEthereum =
      "Veylor can't reach Ethereum right now. It keeps trying while it's open.";

  /// `convert_problem_railgun` (B)
  static const convertProblemRailgun =
      "Railgun isn't accepting deposits right now, so Veylor holds off "
      "claiming. If it doesn't reopen in time, the swap is called off and "
      'your ZEC comes back.';

  /// `convert_problem_turn` (B)
  static const convertProblemTurn =
      'The market maker holds the claim for a few minutes. Veylor claims as '
      "soon as it's your turn.";

  /// `convert_problem_wallet` (B)
  static const convertProblemWallet =
      "Veylor couldn't complete this step with your Zcash wallet. It will "
      'keep trying while open and unlocked.';

  /// `convert_problem_unpayable` (B)
  static const convertProblemUnpayable =
      "Your wallet can't pay the deposit right now, for example because the "
      'network fee went up. Veylor keeps trying. If it still can\'t pay in '
      'time, the swap ends and nothing is sent.';

  /// `convert_problem_tokens` (B, T, F)
  static const convertProblemTokens =
      "Veylor can't get this conversion's token right now. It keeps trying "
      "while it's open.";

  /// `convert_problem_rejected` (B)
  static const convertProblemRejected =
      'The Zcash network turned down a transaction of this conversion. Veylor '
      'keeps sending it until it goes through or expires.';

  /// `convert_problem_mismatch` (B)
  static const convertProblemMismatch =
      "What's on the chain doesn't match this conversion, so Veylor only "
      'brings your funds back.';

  /// New (T): a step held up by the Tor route (`RouteBlocked`).
  static const convertProblemRoute =
      "Tor is starting or unavailable. Veylor keeps trying while it's open.";

  /// `convert_problem_unexpected` (B, F)
  static const convertProblemUnexpected =
      "Something went wrong. Veylor keeps trying while it's open.";

  // ── Convert: results (forward) ────────────────────────────────────────

  /// `convert_result_paid_title`
  static const convertResultPaidTitle = 'Dollars on their way';

  /// `convert_result_paid_body`
  static String convertResultPaidBody(String usd, String about) =>
      '$usd is in your private balance. Railgun screens new funds for $about '
      'before they can be spent.';

  /// `convert_result_screened_body`
  static String convertResultScreenedBody(String usd) =>
      '$usd is in your private balance, ready to use.';

  /// `convert_result_refunded_title`
  static const convertResultRefundedTitle = 'Your ZEC came back';

  /// `convert_result_refunded_maker`
  static const convertResultRefundedMaker =
      'The market maker called the swap off, so your ZEC came back to your '
      'wallet, less a small network fee.';

  /// `convert_result_refunded_late`
  static const convertResultRefundedLate =
      "The swap couldn't be completed in time, so it was called off and your "
      'ZEC came back, less a small network fee.';

  /// `convert_result_nothing_title`
  static const convertResultNothingTitle = 'Nothing was sent';

  /// `convert_result_quote_expired`
  static const convertResultQuoteExpired =
      'The quote expired before the market maker took it. Your ZEC never '
      'left your wallet.';

  /// `convert_result_maker_refused`
  static const convertResultMakerRefused =
      'The market maker turned the conversion down. Your ZEC never left your '
      'wallet.';

  /// `convert_result_maker_unavailable`
  static const convertResultMakerUnavailable =
      "The market maker isn't taking conversions right now. Your ZEC never "
      'left your wallet.';

  /// `convert_result_never_opened`
  static const convertResultNeverOpened =
      'The swap never opened on Ethereum. Your ZEC never left your wallet.';

  /// `convert_result_mismatch` (B)
  static const convertResultMismatch =
      "The swap on Ethereum didn't match its quote, so Veylor didn't send your "
      'ZEC.';

  /// `convert_result_window_missed` (B)
  static const convertResultWindowMissed =
      "The swap opened too late to finish safely, so Veylor didn't send your "
      'ZEC.';

  /// `convert_result_maker_cancelled`
  static const convertResultMakerCancelled =
      'The market maker called the swap off before your ZEC was sent. Your '
      'ZEC never left your wallet.';

  /// `convert_result_view_balance`
  static const convertResultViewBalance = 'View private USD';

  /// `convert_result_try_again`
  static const convertResultTryAgain = 'Try again';

  // ── Reverse (M6): amount, review and info ───────────────────────────

  /// `convert_swap_direction`: the direction toggle's label.
  static const convertSwapDirection = 'Swap conversion direction';

  /// `reverse_insufficient` (S)
  static const reverseInsufficient =
      'Not enough private USD for this amount and its fees.';

  /// `reverse_error_max`
  static const reverseErrorMax =
      "Couldn't work out the most you can convert. Try again in a moment.";

  /// New: a reverse amount takes whole cents (Rust refuses more decimals).
  static const reverseAmountCents = 'Use at most 2 decimal places.';

  /// `reverse_error_funding_unavailable` (S)
  static const reverseErrorFundingUnavailable =
      'Conversion to ZEC is unavailable right now. Try again later.';

  /// `reverse_error_cost_changed`
  static const reverseErrorCostChanged =
      'The fees changed, so nothing was paid. Review the new total, then pay '
      'it or cancel.';

  /// `reverse_title` (S): the reverse info sheet's title.
  static const reverseTitle = 'Private USD to ZEC';

  /// `reverse_intro` (S)
  static const reverseIntro =
      'Approve sending private USD first. After your wallet confirms the full '
      'ZEC deposit itself, approve settlement to receive shielded ZEC.';

  /// `reverse_refund_note` (B)
  static const reverseRefundNote =
      'Before you approve settlement, you can cancel. After that, a refund '
      "waits for the contract deadline. A refund pays the relayer's fee and "
      "Railgun's shielding fee. Closing Veylor never approves settlement.";

  /// New (F): `reverse_keep_open`
  static String reverseKeepOpen(String time) =>
      'Keep Veylor open after you pay. Once the ZEC is confirmed, you approve '
      "settlement here by $time. If you don't, your private USD is refunded, "
      'less fees.';

  /// `reverse_escrow`
  static const reverseEscrow = 'Escrow value';

  /// `reverse_railgun_fee`
  static const reverseRailgunFee = 'Railgun unshield fee';

  /// `reverse_broadcaster_fee`
  static const reverseBroadcasterFee = 'Broadcast fee';

  /// `reverse_total`
  static const reverseTotal = 'Total paid';

  /// `reverse_receive_estimate`
  static const reverseReceiveEstimate = 'Estimated ZEC after sweep fee';

  /// `reverse_problem_relayer` (B, F)
  static const reverseProblemRelayer =
      "Veylor can't reach the relayer that moves your dollars. It keeps trying "
      "while it's open.";

  // ── Reverse (M6): progress, results and actions ───────────────────────

  /// `reverse_accepting`
  static const reverseAccepting = 'Preparing your receiving account';

  /// `reverse_review` (S): the banner's detail while the payment waits.
  static const reverseReview = 'Review and approve your payment';

  /// `reverse_step_fund`: once "Pay" was tapped.
  static const reverseStepFund = 'Sending private USD to escrow';

  /// New (owner, 2026-10-17): the same step while it waits for "Pay", so it
  /// reads as the user's to take rather than a payment already going.
  static const reverseStepPay = 'Pay private USD to escrow';

  /// New (owner, 2026-10-17): under [reverseStepPay].
  static String reverseStepPayDetail(String debit) =>
      'Tap Pay to send $debit of private USD to escrow.';

  /// `reverse_sending` (S)
  static const reverseSending = 'Sending private USD';

  /// `reverse_confirming`
  static const reverseConfirming = 'Confirming escrow';

  /// `reverse_receiving`
  static const reverseReceiving = 'Waiting for confirmed ZEC';

  /// `reverse_ready`
  static const reverseReady = 'Authorize settlement';

  /// `reverse_step_approval_detail`
  static const reverseStepApprovalDetail =
      'Your approval is needed to continue.';

  /// `reverse_ready_explanation` (S)
  static const reverseReadyExplanation =
      'The full ZEC deposit is confirmed. Authorize settlement to release '
      'your private USD and move ZEC to your shielded wallet.';

  /// `reverse_step_settle`
  static const reverseStepSettle = 'Settling your conversion';

  /// `reverse_settling`
  static const reverseSettling = 'Waiting for settlement';

  /// `reverse_sweeping`
  static const reverseSweeping = 'Moving ZEC to your shielded wallet';

  /// `reverse_sweep_confirmations`
  static String reverseSweepConfirmations(int count) =>
      'Zcash confirmations: $count';

  /// `reverse_refund_wait` (B, F)
  static const reverseRefundWait =
      "Waiting until a refund can proceed. Veylor retries while it's open.";

  /// `reverse_refunding`
  static const reverseRefunding = 'Securing your private refund';

  /// `reverse_payout` (S)
  static const reversePayout = 'Returning your private USD to Railgun';

  /// `reverse_complete`
  static const reverseComplete = 'ZEC received in your shielded wallet';

  /// `reverse_refunded`
  static const reverseRefunded =
      'Private refund paid. Railgun screening may delay availability.';

  /// `reverse_cancelled` (S)
  static const reverseCancelled =
      'Conversion cancelled. No escrow payment remains.';

  /// `reverse_progress_amounts`
  static String reverseProgressAmounts(String usd, String zec) =>
      '$usd for $zec after fees';

  /// `reverse_progress_estimate`
  static String reverseProgressEstimate(String usd, String zec) =>
      '$usd for about $zec after fees';

  /// `reverse_progress_received`
  static String reverseProgressReceived(String zec) =>
      '$zec arrived after fees.';

  /// `reverse_result_received`
  static const reverseResultReceived = 'ZEC received';

  /// `reverse_result_refunded`
  static const reverseResultRefunded = 'Refund sent';

  /// `reverse_result_cancelled`
  static const reverseResultCancelled = 'Conversion cancelled';

  /// `reverse_new`
  static const reverseNew = 'New conversion';

  /// `reverse_cancel`
  static const reverseCancel = 'Cancel conversion';

  /// `reverse_request_refund` (S)
  static const reverseRequestRefund = 'Request refund';

  /// New (D18): `reverse_cancel_confirm_title`
  static const reverseCancelConfirmTitle = 'Cancel this conversion?';

  /// New (D18): `reverse_cancel_confirm_body`, once private USD was paid.
  static const reverseCancelConfirmBody =
      "Your private USD comes back, less the relayer's and Railgun's fees. "
      "This can't be undone.";

  /// New (D18): the same sheet before anything was paid.
  static const reverseCancelConfirmUnpaidBody =
      "Nothing has been paid yet, so nothing is lost. This can't be undone.";

  /// New: the confirmation sheets' way out.
  static const notNow = 'Not now';

  /// `reverse_refund_requested` (B, F)
  static const reverseRefundRequested =
      "Refund requested. Veylor continues when your refund is available, while "
      "it's open.";

  /// `reverse_refund_requested_after_ready` (B)
  static String reverseRefundRequestedAfterReady(String time) =>
      "Refund requested. If settlement doesn't finish, Veylor can start "
      'returning your funds after $time. Settlement may still finish before '
      'then.';

  /// `reverse_settlement_refund_limit`
  static String reverseSettlementRefundLimit(String time) =>
      'Settlement is authorized. A refund can only proceed after $time if '
      "settlement hasn't completed.";

  /// `reverse_refund_unavailable` (B)
  static const reverseRefundUnavailable =
      'This conversion has already settled and can no longer be refunded. '
      'Veylor will finish moving your ZEC to your wallet.';

  /// `reverse_error` (B)
  static const reverseError =
      'Unable to complete this step. Your saved conversion resumes after '
      'Veylor checks both chains. A payment is never repeated because a '
      'request timed out.';

  /// `reverse_error_unconfirmed`
  static const reverseErrorUnconfirmed =
      "The market maker's ZEC isn't confirmed yet. Try again in a few minutes.";

  /// `reverse_error_too_late`
  static const reverseErrorTooLate =
      "It's too late for this step, so the conversion ends by itself. "
      'Anything you paid comes back.';

  /// `reverse_error_rescue`
  static const reverseErrorRescue =
      "Couldn't recover the refund. Try again in a moment.";

  /// `reverse_rescue`
  static const reverseRescue = 'Recover refund';

  /// New: "Pay {debit}", the funding payment (`awaitingFunding`).
  static String reversePay(String debit) => 'Pay $debit';

  /// New (F): the funding proof in the page, with its progress.
  static String reverseProving(int percent) =>
      'Proving your payment · $percent%';

  /// New (owner, 2026-10-17): an outgoing payment in flight on the Private
  /// USD screen (a send, a withdrawal or a conversion's escrow payment),
  /// with observed numbers only: the proof's progress, then the time since
  /// the send was posted.
  static String paymentProving(int percent) => reverseProving(percent);

  static String paymentWaitingForBlock(String elapsed) =>
      'Waiting for a block · $elapsed';

  static const paymentUpdatingBalance = 'Updating your balance';

  /// New (F): under the proof.
  static const reverseProvingNote =
      'Your phone builds a zero-knowledge proof of the payment. This can take '
      'a few minutes. Keep Veylor open.';

  // ── Refunds (M6) ──────────────────────────────────────────────────────

  /// `refunds_title`
  static const refundsTitle = 'Refunds';

  /// `refunds_subtitle`
  static const refundsSubtitle = 'Refunds from earlier conversions';

  /// `refunds_info`
  static const refundsInfo =
      "If a refund couldn't enter your private balance, recover it here. "
      'Railgun screening may delay availability.';

  /// `refunds_original_amount`
  static const refundsOriginalAmount = 'Original conversion amount';

  /// `refunds_empty`
  static const refundsEmpty = 'No refunded conversions yet.';

  /// `refunds_checking`
  static const refundsChecking = 'Checking refunds…';

  /// `refunds_available`
  static const refundsAvailable = 'This refund can be recovered.';

  /// `refunds_no_recovery`
  static const refundsNoRecovery =
      'No recovery available right now. Your refund may still be going '
      'through Railgun screening.';

  /// `refunds_recover`
  static const refundsRecover = 'Recover refund';

  /// `refunds_recovering`
  static const refundsRecovering = 'Recovering your refund…';

  /// `refunds_check_failed`
  static const refundsCheckFailed =
      "Couldn't check this refund. Refresh to try again.";

  /// `refunds_recover_failed`
  static const refundsRecoverFailed =
      "Couldn't recover this refund. Try again.";

  /// New (D18): `refunds_recover_confirm_title`
  static const refundsRecoverConfirmTitle = 'Recover this refund?';

  /// New (D18): `refunds_recover_confirm_body`. Rust reads the relayer's fee
  /// only as it signs, so the sheet names its cap (X6, D-84).
  static String refundsRecoverConfirmBody(String cap) =>
      "The relayer's fee, at most $cap, comes out of the refund.";

  /// New: the refresh button's label.
  static const refundsRefresh = 'Refresh';

  /// New (M9): a refund pinned to the retired testnet token, which this
  /// build's relayer no longer serves.
  static const refundsOtherDeployment =
      "This refund is from an earlier test deployment. It can't be "
      'recovered in this version.';

  /// New (M9): a deposit Railgun's screening sent back to its vault.
  static const refundsDepositTitle = 'Deposit sent back by screening';

  /// New (M9)
  static String refundsDepositBody(String usd) =>
      "Railgun's screening sent $usd back to your deposit address's vault. "
      'Recover it to make it private again.';

  /// New (M9)
  static const refundsDepositRecover = 'Recover deposit';

  /// New (M9)
  static const refundsDepositRecovering = 'Recovering your deposit…';

  /// New (M9)
  static const refundsDepositRecoverFailed =
      "Couldn't recover this deposit. Try again.";

  /// New (M9, D18)
  static const refundsDepositConfirmTitle = 'Recover this deposit?';

  /// New (M9, D18): a rescue pays the relayer's fee alone, at most the cap.
  static String refundsDepositConfirmBody(String fee) =>
      "The relayer's fee, $fee, comes out of it.";

  // ── Deposits (M9) ──────────────────────────────────────────────────────

  /// The button beside Send and Withdraw.
  static const actionReceive = 'Receive';

  /// The sheet's title: "Receive USDC", or "Receive tUSD" on testnet.
  static String depositTitle(String symbol) => 'Receive $symbol';

  /// The one token and network the address takes.
  static String depositOnly(String symbol, String chain) =>
      'Only $symbol on $chain';

  /// What happens to it.
  static const depositHow =
      'Send it from an exchange or any wallet. Veylor makes it private on '
      'its own while it is open and unlocked.';

  /// The minimum, from the relayer's terms.
  static String depositMinimum(String usd) => 'Minimum $usd';

  /// The relayer's fee: its fixed part and its percentage.
  static String depositRelayerFee(String fixed, String percent) =>
      'Relayer fee: $fixed + $percent%';

  /// Railgun's shield fee.
  static String depositRailgunFee(String percent) =>
      "Railgun's fee: $percent%";

  /// What a deposit of [sent] brings after both fees.
  static String depositExample(String sent, String arrives) =>
      'Sending $sent brings $arrives after both fees.';

  /// The terms are being read.
  static const depositFeesLoading = 'Loading the fees…';

  /// The terms could not be read (Tor starting, the relayer down).
  static const depositFeesFailed =
      "Couldn't load the fees. Money sent here waits safely at this address.";

  /// The relayer takes no deposits, or not the pinned ones.
  static const depositUnavailable =
      'Deposits are unavailable right now. Nothing sent to an earlier '
      'deposit address is lost: it waits there.';

  /// The address is being derived.
  static const depositAddressLoading = 'Loading your deposit address…';

  /// The address could not be derived (locked, say).
  static const depositAddressFailed =
      "Couldn't load your deposit address. Try again in a moment.";

  /// The copy button's label.
  static const depositCopy = 'Copy deposit address';

  /// The address holds money not yet made private.
  static String depositReceived(String usd) => 'Received $usd';

  /// It holds less than the minimum.
  static String depositUnderMinimum(String usd, String minimum) =>
      'Received $usd, under the $minimum minimum. Send more to this address.';

  /// Posted, until it mines.
  static const depositMakingPrivate = 'Making it private…';

  /// Mined: Railgun screens it before it can be spent.
  static String depositPrivate(String about) => 'Private, available in $about';

  /// The relayer asked to wait long, or could not be reached.
  static const depositWaiting =
      'Waiting for the network; your money is safe at your deposit address';

  /// Refused, or the relayer's fee is above the cap.
  static const depositNotShielding =
      "Received, but not made private yet. Veylor tries again later; your "
      'money is safe at your deposit address.';

  /// The relayer's fee is above what Veylor pays (D23).
  static const depositFeeTooHigh =
      "The relayer's fee is above what Veylor pays. Your money waits safely "
      'at your deposit address.';

  /// The status card's title on the Private USD screen.
  static const depositsTitle = 'Deposits';

  /// Activity: a deposit.
  static const activityDeposit = 'Deposit';

  /// Activity: a rescued deposit.
  static const activityDepositRescue = 'Recovered deposit';

  /// Activity: a deposit that landed.
  static const activityDepositPrivate = 'Now private';

  // ── Accounts and reset (new for vizor; §8.4 refusal) ──────────────────

  /// New: `delete_unfinished_title`
  static const deleteUnfinishedTitle = 'Conversion in progress';

  /// New (F): `delete_unfinished_body`
  static String deleteUnfinishedBody(int count) =>
      'This account has $count unfinished private USD '
      '${_conversions(count)}. Only this account can recover their funds, '
      'so deleting it now can lose them. Keep Veylor open until they finish '
      'or are refunded.';

  /// New: `reset_unfinished_body`
  static String resetUnfinishedBody(int count) =>
      'Your wallet has $count unfinished private USD ${_conversions(count)}. '
      'Only this wallet can recover their funds, so resetting now can lose '
      'them.';

  /// New: `delete_anyway`
  static const deleteAnyway = 'Delete anyway';

  /// New: `reset_anyway`
  static const resetAnyway = 'Reset anyway';

  /// New: `accounts_pending_conversions`
  static String accountsPendingConversions(int count) =>
      '$count ${_conversions(count)} in progress';

  static String _conversions(int count) =>
      count == 1 ? 'conversion' : 'conversions';

  // ── Send and withdraw (M7) ────────────────────────────────────────────

  /// `private_usd_send_title`
  static const sendTitle = 'Send privately';

  /// `private_usd_withdraw_title`
  static const withdrawTitle = 'Withdraw';

  /// `private_usd_send_asset`
  static const sendAsset = 'Asset';

  /// `private_usd_send_amount`
  static const sendAmount = 'Amount';

  /// `private_usd_send_to_private`
  static const sendToPrivate = 'To a Railgun address';

  /// `private_usd_send_to_withdraw`
  static const sendToWithdraw = 'To an Ethereum address';

  /// `private_usd_send_hint_private`
  static const sendHintPrivate = '0zk1…';

  /// `private_usd_send_hint_withdraw`
  static const sendHintWithdraw = '0x…';

  /// New: the paste button's label.
  static const sendPaste = 'Paste';

  /// `private_usd_send_invalid_0zk`
  static const sendInvalid0zk = "That isn't a Railgun 0zk address.";

  /// `private_usd_send_invalid_0x`
  static const sendInvalid0x = "That isn't an Ethereum address.";

  /// `private_usd_send_zero_address`
  static const sendZeroAddress =
      "That's the zero address: anything sent there is lost for good.";

  /// `private_usd_send_too_much`
  static const sendTooMuch = 'More than you have available.';

  /// `private_usd_send_leave_network_fee`
  static String sendLeaveNetworkFee(String fee) =>
      'Leave $fee for the network fee.';

  /// `private_usd_send_too_precise` (plural)
  static String sendTooPrecise(int decimals) =>
      'Use at most $decimals decimal ${decimals == 1 ? 'place' : 'places'}.';

  /// `private_usd_send_balance_dropped`
  static const sendBalanceDropped =
      'Your available balance is now less than this amount.';

  /// `private_usd_send_withdraw_public`
  static const sendWithdrawPublic =
      'Anyone on Ethereum can see this amount and address.';

  /// `private_usd_send_review_title_private`
  static const sendReviewTitlePrivate = 'Review send';

  /// `private_usd_send_review_title_withdraw`
  static const sendReviewTitleWithdraw = 'Review withdrawal';

  /// `private_usd_send_review_railgun_fee`
  static String sendReviewRailgunFee(String percent) =>
      'Railgun fee ($percent%)';

  /// `private_usd_send_review_receives`
  static const sendReviewReceives = 'They receive';

  /// `private_usd_send_review_to`
  static const sendReviewTo = 'To';

  /// New (D11): `send_error_fee_cap`
  static const sendErrorFeeCap =
      'The network fee is above the 2 USDC limit right now, so nothing was '
      'sent. Try again later.';

  /// New: the send log does not read, so spending stays blocked.
  static const sendErrorStore =
      "Veylor can't read its saved payments. $supportSentence";

  /// `private_usd_send_proving`
  static const sendProving = 'Proving your transaction';

  /// New: the proof's progress, from the page's `proof` events.
  static String sendProvingPercent(int percent) =>
      'Proving your transaction · $percent%';

  /// `private_usd_send_proving_detail` (F)
  static const sendProvingDetail =
      'Your phone builds a zero-knowledge proof so nobody can see what you '
      'send. This takes a few seconds. Keep Veylor open.';

  /// `private_usd_send_sending`
  static const sendSending = 'Sending';

  /// New (F): once proved, while the relayer sends it and Vizor waits for a
  /// block.
  static const sendLanding =
      'The relayer is sending it. Waiting for a block can take a minute. '
      'Keep Veylor open.';

  /// `private_usd_send_done_title_private`
  static const sendDoneTitlePrivate = 'Sent';

  /// `private_usd_send_done_title_withdraw`
  static const sendDoneTitleWithdraw = 'Withdrawn';

  /// `private_usd_send_done_body`
  static String sendDoneBody(String amount, String address) =>
      '$amount went to $address.';

  /// `private_usd_send_view_tx`
  static const sendViewTx = 'View on Etherscan';

  /// `private_usd_send_view_railscan`
  static const sendViewRailscan = 'View on Railscan';

  /// `private_usd_send_not_sent`
  static const sendNotSent = 'Nothing was sent. Try again in a moment.';

  /// `private_usd_send_unavailable`
  static const sendUnavailable =
      'Private sends are unavailable right now. Nothing was sent. Try again '
      'later.';

  /// `private_usd_send_fee_rose`
  static String sendFeeRose(String fee) =>
      'The network fee went up to $fee. Nothing was sent.';

  /// `private_usd_send_unconfirmed`
  static const sendUnconfirmed =
      "It isn't in a block yet. Check your activity before sending again.";

  /// `private_usd_send_info_title`
  static const sendInfoTitle = 'Sending privately';

  /// `private_usd_send_info_step_address`
  static const sendInfoStepAddress =
      "Enter the amount and the recipient's Railgun address, which starts "
      'with 0zk.';

  /// `private_usd_send_info_step_proof`
  static const sendInfoStepProof =
      'Your phone builds a zero-knowledge proof. This takes a few seconds.';

  /// `private_usd_send_info_step_private`
  static const sendInfoStepPrivate =
      'The dollars move inside Railgun: nobody else sees the amount, or who '
      'sent and received it.';

  /// `private_usd_withdraw_info_title`
  static const withdrawInfoTitle = 'Withdrawing makes it public';

  /// `private_usd_withdraw_info_step_address`
  static const withdrawInfoStepAddress =
      'Enter the amount and an Ethereum address, which starts with 0x.';

  /// `private_usd_withdraw_info_step_proof`
  static const withdrawInfoStepProof =
      'Your phone builds a proof, and the dollars leave Railgun for that '
      'address.';

  /// `private_usd_withdraw_info_note_public`
  static const withdrawInfoNotePublic =
      'Once withdrawn, the amount and the address are visible to anyone on '
      'Ethereum.';

  /// `private_usd_withdraw_info_note_private`
  static const withdrawInfoNotePrivate =
      "To stay private, don't withdraw the exact amount you just converted, "
      'wait a while first, and use a fresh address each time.';

  /// `private_usd_withdraw_info_note_fee`
  static String withdrawInfoNoteFee(String percent) =>
      'Railgun keeps $percent% of what you withdraw.';

  // ── Settings: the user's own Ethereum RPC (new; owner, 2026-10-17) ────

  static const rpcTitle = 'Ethereum RPC';

  /// The row's value and the sheet's state with no URL of the user's set.
  static const rpcDefault = 'Default';

  /// The sheet's state, as the endpoint settings word it: [value] is
  /// [rpcDefault] or the URL's host.
  static String rpcCurrent(String value) => 'Current: $value';

  /// What the chain is called in the sheet, for a Railgun network.
  static String rpcNetwork(String railgunNetwork) =>
      railgunNetwork == 'sepolia' ? 'Sepolia' : 'Ethereum mainnet';

  static String rpcBody(String network) =>
      'Use your own Alchemy, Infura or publicnode URL for $network. Private '
      'USD then uses only it.';

  static const rpcSees =
      "The RPC sees the app's Ethereum requests, and your IP address unless "
      'Tor is on.';

  static const rpcHint = 'https://';
  static const rpcPaste = 'Paste';
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

  /// The Private USD screen, when a sync or a conversion step fails while
  /// the user's own RPC is set; [rpcUseDefault] clears it.
  static const rpcNotAnswering = "Your Ethereum RPC isn't answering.";
}

/// The spending note on `/private-usd` and the send screens (reference §9.4
/// S2): why Send, Withdraw or a new conversion cannot start now; null when
/// they can.
String? privateUsdSpendMessage(PrivateUsdSpendStatus status) =>
    switch (status) {
      PrivateUsdSpendStatus.available => null,
      PrivateUsdSpendStatus.checking => PrivateUsdCopy.checkingPayments,
      PrivateUsdSpendStatus.sending => PrivateUsdCopy.paymentPending,
      PrivateUsdSpendStatus.converting => PrivateUsdCopy.conversionPending,
      PrivateUsdSpendStatus.unreadable => PrivateUsdCopy.sendErrorStore,
    };

/// What to say when pricing or sending fails before anything was sent
/// (zapp `PrivateUsdSendVM.onReview`, plus the D11 cap).
String privateUsdSendErrorMessage(ApiPrivateUsdErrorCode code) =>
    switch (code) {
      ApiPrivateUsdErrorCode.unavailable => PrivateUsdCopy.sendUnavailable,
      ApiPrivateUsdErrorCode.relayerFee => PrivateUsdCopy.sendErrorFeeCap,
      ApiPrivateUsdErrorCode.routeBlocked => PrivateUsdCopy.routeBlocked,
      ApiPrivateUsdErrorCode.storeUnreadable => PrivateUsdCopy.sendErrorStore,
      ApiPrivateUsdErrorCode.busy => PrivateUsdCopy.paymentPending,
      _ => PrivateUsdCopy.sendNotSent,
    };

/// What to say when a quote or an accept fails before anything was sent
/// (mirrors zapp `PrivateUsdFailure`); null for a cancelled call, which is
/// never a failure. Dart never branches on an error's message text.
String? privateUsdErrorMessage(ApiPrivateUsdErrorCode code) => switch (code) {
  ApiPrivateUsdErrorCode.cancelled => null,
  // A service serving another deployment reads as the relayer being
  // unreachable, as zapp holds it.
  ApiPrivateUsdErrorCode.relayerUnreachable ||
  ApiPrivateUsdErrorCode.wrongDeployment => PrivateUsdCopy.convertErrorRelayer,
  ApiPrivateUsdErrorCode.relayerRefused =>
    PrivateUsdCopy.convertErrorRelayerRefused,
  // At quote, Rust refuses a fee above the 2 USDC cap (D11).
  ApiPrivateUsdErrorCode.relayerFee => PrivateUsdCopy.convertErrorFeeCap,
  ApiPrivateUsdErrorCode.ethereumUnreachable ||
  ApiPrivateUsdErrorCode.chainLagging => PrivateUsdCopy.convertErrorEthereum,
  ApiPrivateUsdErrorCode.zcashWallet => PrivateUsdCopy.convertErrorWallet,
  ApiPrivateUsdErrorCode.depositUnpayable =>
    PrivateUsdCopy.convertErrorUnpayable,
  ApiPrivateUsdErrorCode.tokensUnreachable ||
  ApiPrivateUsdErrorCode.tokensRefused =>
    PrivateUsdCopy.convertErrorTokensUnavailable,
  ApiPrivateUsdErrorCode.tokensDeviceRefused =>
    PrivateUsdCopy.convertErrorDeviceRefused,
  ApiPrivateUsdErrorCode.noTokensToday =>
    PrivateUsdCopy.convertErrorNoTokensToday,
  ApiPrivateUsdErrorCode.keystore => PrivateUsdCopy.convertErrorKeystore,
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
/// a minute (reference §5.8; the forward rows of §9.6).
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
  ApiPrivateUsdErrorCode.tokensUnreachable =>
    PrivateUsdCopy.convertProblemTokens,
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

/// What to say when a reverse quote fails before anything was spent but an
/// index (reference §9.6; zapp `PrivateUsdFailure`).
String? privateUsdReverseQuoteMessage(ApiPrivateUsdErrorCode code) =>
    switch (code) {
      ApiPrivateUsdErrorCode.unavailable =>
        PrivateUsdCopy.reverseErrorFundingUnavailable,
      _ => privateUsdErrorMessage(code),
    };

/// What to say when a reverse step the user took (pay, authorize settlement,
/// cancel) did not go through (reference §9.4 S4, S6).
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
/// failed for a minute (reference §5.8; the reverse rows of §9.6).
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
      ApiPrivateUsdErrorCode.tokensUnreachable ||
      ApiPrivateUsdErrorCode.mismatch ||
      ApiPrivateUsdErrorCode.storeUnreadable ||
      ApiPrivateUsdErrorCode.routeBlocked => privateUsdProblemMessage(code),
      _ => PrivateUsdCopy.convertProblemUnexpected,
    };

/// Why "Convert" did not start a reverse conversion: the maker's answer
/// ended it (`nothingSent`) with nothing paid.
String privateUsdReverseNothingSentMessage(ApiNothingSentCause? cause) =>
    switch (cause) {
      ApiNothingSentCause.makerUnavailable => PrivateUsdCopy.convertErrorMaker,
      ApiNothingSentCause.quoteExpired => PrivateUsdCopy.convertQuoteRanOut,
      _ => PrivateUsdCopy.convertStartFailed,
    };
