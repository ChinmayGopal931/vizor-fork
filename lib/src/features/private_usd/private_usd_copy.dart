import '../../core/config/private_usd_feature_config.dart';

/// Every user-facing Private USD string (plan reference §9.6), sentence case,
/// in one place so widgets, tests and Widgetbook share it. The comment on
/// each is zapp's key, for provenance. "Private USD" is the feature's name:
/// capitalized at the start of a sentence and as a title, "private USD"
/// mid-sentence.
///
/// M3 holds the Shared, Home, Private USD screen and Activity tables; the
/// convert, refunds, send and account tables arrive with M5–M7.
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
  static const bannerKeepOpen = 'Keep Vizor open to finish';

  // ── Private USD screen ─────────────────────────────────────────────────

  /// `private_usd_subtitle`
  static const subtitle = 'Dollars held privately on Ethereum, in Railgun';

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
      'and can take a while. Keep Vizor open.';

  /// `private_usd_first_load_progress` (F)
  static String firstLoadProgress(int percent) =>
      'Loading your private balance: $percent%. The first time reads '
      "Railgun's history and can take a while. Keep Vizor open.";

  /// `private_usd_refresh_failed`
  static const refreshFailed =
      "Couldn't update the balance. Showing the last known amounts.";

  /// `private_usd_load_failed`
  static const loadFailed = "Couldn't load the balance. Try again in a moment.";

  /// `private_usd_empty_title`
  static const emptyTitle = 'No private dollars yet';

  /// `private_usd_empty_body`
  static const emptyBody =
      'Convert ZEC into dollars nobody else can see: not your balance, and '
      'not who you pay.';

  /// `private_usd_receive_address`
  static const receiveAddress = 'Your receive address';

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

  /// `private_usd_info_receive` (B)
  static const infoReceive =
      'Receive: share your receive address on this screen. Anyone with a '
      'Railgun wallet can send you private USD there.';

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
      'Conversions, sends and refunds run only while Vizor is open and '
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
}
