import 'package:flutter/widgets.dart';

import '../../../../core/formatting/countdown_format.dart';
import '../../../../core/formatting/date_format.dart';
import '../../../../core/formatting/zec_amount.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../swap/domain/swap_asset.dart';
import '../../../swap/widgets/mobile/mobile_swap_review_header.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_reverse_presentation.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_convert_provider.dart';
import '../../providers/private_usd_reverse_convert_provider.dart';
import 'private_usd_convert_widgets.dart';
import 'private_usd_flow_widgets.dart';
import 'private_usd_info_sheets.dart';
import 'private_usd_logo.dart';

/// How long a forward conversion usually takes, for the info sheet.
const _forwardTakes = Duration(minutes: 10);

String _masked(String text, bool privacyModeEnabled) => hideAmountIfPrivacyMode(
  text,
  privacyModeEnabled: privacyModeEnabled,
  denomination: '',
);

String _zec(BigInt zatoshi) =>
    ZecAmount.fromZatoshi(zatoshi).activity.toString();

/// The forward amount step, ZEC → private USD: the total ZEC to spend
/// (network fee included), its quote's estimate, ledger and countdown.
class MobilePrivateUsdConvertView extends StatelessWidget {
  const MobilePrivateUsdConvertView({
    required this.state,
    required this.controller,
    required this.onAmountChanged,
    required this.onMax,
    required this.onReview,
    required this.onBack,
    this.focusNode,
    this.privacyModeEnabled = false,
    this.privateUsdAvailable,
    this.autofocus = true,
    this.onSwitchDirection,
    super.key,
  });

  final PrivateUsdConvertState state;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool privacyModeEnabled;

  /// The private USD that can be spent, in micro-dollars; null while unknown.
  final BigInt? privateUsdAvailable;
  final bool autofocus;
  final ValueChanged<String> onAmountChanged;
  final VoidCallback onMax;
  final VoidCallback onReview;
  final VoidCallback onBack;

  /// Null keeps the direction switch dimmed.
  final VoidCallback? onSwitchDirection;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final quote = state.quote;
    final quoted = quote != null && !state.quoting;
    final spendable = state.holdings.spendable;
    final syncPercent = state.holdings.syncPercent;
    final available = privateUsdAvailable;
    return _ConvertLayout(
      onBack: onBack,
      onInfo: () =>
          showPrivateUsdConvertInfoSheet(context, takes: _forwardTakes),
      pay: PrivateUsdAmountPanel(
        key: const ValueKey('mobile_private_usd_convert_zec'),
        caption: const PrivateUsdPanelCaption.zec(),
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        readOnly: state.step != PrivateUsdConvertStep.amount,
        maxFractionDigits: 8,
        invalid: state.isAmountInvalid,
        note: PrivateUsdCopy.convertZecIncludesFee,
        available: spendable == null
            ? PrivateUsdCopy.unknown
            : _masked(_zec(spendable), privacyModeEnabled),
        onMax: state.canMax ? onMax : null,
        onChanged: onAmountChanged,
        footer: state.holdings.catchingUp
            ? Text(
                syncPercent == null
                    ? PrivateUsdCopy.convertZecSyncing
                    : PrivateUsdCopy.convertZecSyncingProgress(syncPercent),
                key: const ValueKey('mobile_private_usd_convert_syncing'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.secondary,
                ),
              )
            : null,
      ),
      receive: PrivateUsdEstimatePanel(
        caption: const PrivateUsdPanelCaption.privateUsd(),
        quoting: state.quoting,
        estimate: quoted
            ? _masked(formatPrivateUsd(quote.receives), privacyModeEnabled)
            : null,
        available: available == null
            ? null
            : _masked(formatPrivateUsd(available), privacyModeEnabled),
      ),
      onSwitchDirection: onSwitchDirection,
      busy: state.quoting,
      quoting: state.quoting,
      ledger: quoted
          ? PrivateUsdQuoteLedger(
              quote: quote,
              privacyModeEnabled: privacyModeEnabled,
              showsTotal: true,
            )
          : null,
      expired: state.isExpired,
      expiresIn: state.expiresIn,
      message: state.message,
      canReview: state.canReview,
      onReview: onReview,
    );
  }
}

/// The reverse amount step, private USD → ZEC: the dollars to bridge, in
/// whole cents, and the priced quote's ZEC estimate, ledger and countdown.
class MobilePrivateUsdReverseConvertView extends StatelessWidget {
  const MobilePrivateUsdReverseConvertView({
    required this.state,
    required this.controller,
    required this.onAmountChanged,
    required this.onMax,
    required this.onReview,
    required this.onBack,
    this.onSwitchDirection,
    this.onViewRefunds,
    this.focusNode,
    this.privacyModeEnabled = false,
    this.autofocus = true,
    super.key,
  });

  final PrivateUsdReverseConvertState state;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool privacyModeEnabled;
  final bool autofocus;
  final ValueChanged<String> onAmountChanged;
  final VoidCallback onMax;
  final VoidCallback onReview;
  final VoidCallback onBack;

  /// Null keeps the direction switch dimmed.
  final VoidCallback? onSwitchDirection;
  final VoidCallback? onViewRefunds;

  @override
  Widget build(BuildContext context) {
    final draft = state.draft;
    final priced = draft != null && state.debit != null;
    final available = state.available;
    return _ConvertLayout(
      onBack: onBack,
      onInfo: () => showPrivateUsdReverseInfoSheet(context),
      pay: PrivateUsdAmountPanel(
        key: const ValueKey('mobile_private_usd_convert_usd'),
        caption: const PrivateUsdPanelCaption.privateUsd(),
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        readOnly: state.step != PrivateUsdConvertStep.amount,
        // Whole cents only: Rust refuses anything finer.
        maxFractionDigits: 2,
        invalid: state.isAmountInvalid || state.isTooPrecise,
        available: available == null
            ? PrivateUsdCopy.unknown
            : _masked(formatPrivateUsd(available), privacyModeEnabled),
        onMax: state.canMax ? onMax : null,
        maxBusy: state.lookingUp,
        onChanged: onAmountChanged,
      ),
      receive: PrivateUsdEstimatePanel(
        caption: const PrivateUsdPanelCaption.zec(),
        quoting: state.quoting,
        estimate: priced && !state.quoting
            ? _masked(
                _zec(privateUsdReverseReceivedZat(draft)),
                privacyModeEnabled,
              )
            : null,
      ),
      onSwitchDirection: onSwitchDirection,
      busy: state.quoting || state.lookingUp,
      quoting: state.quoting,
      ledger: priced && !state.quoting && !state.lookingUp
          ? PrivateUsdReverseLedger(
              record: draft,
              privacyModeEnabled: privacyModeEnabled,
            )
          : null,
      expired: state.isExpired,
      expiresIn: state.expiresIn,
      message: state.message,
      canReview: state.canReview,
      onReview: onReview,
      extra: [
        if (state.showsRefunds && onViewRefunds != null)
          AppButton(
            key: const ValueKey('mobile_private_usd_convert_refunds'),
            variant: AppButtonVariant.secondary,
            expand: true,
            onPressed: onViewRefunds,
            child: const Text(PrivateUsdCopy.refundsView),
          ),
      ],
    );
  }
}

/// What both amount steps lay out: the paying panel, the direction switch,
/// the estimate, the priced quote's [ledger] and countdown, a message, and
/// Review.
class _ConvertLayout extends StatelessWidget {
  const _ConvertLayout({
    required this.onBack,
    required this.onInfo,
    required this.pay,
    required this.receive,
    required this.onSwitchDirection,
    required this.busy,
    required this.quoting,
    required this.ledger,
    required this.expired,
    required this.expiresIn,
    required this.message,
    required this.canReview,
    required this.onReview,
    this.extra = const [],
  });

  final VoidCallback onBack;
  final VoidCallback onInfo;
  final Widget pay;
  final Widget receive;
  final VoidCallback? onSwitchDirection;

  /// A quote or the most that can be bridged is being worked out.
  final bool busy;
  final bool quoting;
  final Widget? ledger;
  final bool expired;
  final Duration expiresIn;
  final String? message;
  final bool canReview;
  final VoidCallback onReview;

  /// Under the message.
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    final ledger = this.ledger;
    final message = this.message;
    return PrivateUsdFlowScaffold(
      title: PrivateUsdCopy.actionConvert,
      onBack: onBack,
      onInfo: onInfo,
      body: PrivateUsdFlowColumn(
        key: const ValueKey('mobile_private_usd_convert_scroll'),
        children: [
          pay,
          PrivateUsdDirectionToggle(onTap: onSwitchDirection, busy: busy),
          receive,
          if (ledger != null) ...[
            const SizedBox(height: AppSpacing.s),
            ledger,
            const SizedBox(height: AppSpacing.xs),
            PrivateUsdQuoteExpiry(
              expired: expired,
              label: PrivateUsdCopy.convertQuoteExpires(
                formatMinutesSeconds(expiresIn),
              ),
            ),
          ],
          if (message != null) ...[
            const SizedBox(height: AppSpacing.s),
            MobileWarningNotice(
              key: const ValueKey('mobile_private_usd_convert_message'),
              message: message,
            ),
          ],
          for (final widget in extra) ...[
            const SizedBox(height: AppSpacing.s),
            widget,
          ],
        ],
      ),
      action: AppButton(
        key: const ValueKey('mobile_private_usd_convert_review'),
        expand: true,
        onPressed: canReview ? onReview : null,
        leading: busy ? const AppLoadingIcon(size: AppIconSize.medium) : null,
        child: Text(
          quoting ? PrivateUsdCopy.convertQuoteLoading : PrivateUsdCopy.review,
        ),
      ),
    );
  }
}

/// The forward review: what is paid and what arrives, the quote's ledger
/// and how long it holds, and the keep-open note.
class MobilePrivateUsdConvertReviewView extends StatelessWidget {
  const MobilePrivateUsdConvertReviewView({
    required this.state,
    required this.privacyModeEnabled,
    required this.onBack,
    required this.onConfirm,
    required this.onRefreshQuote,
    super.key,
  });

  final PrivateUsdConvertState state;
  final bool privacyModeEnabled;
  final VoidCallback onBack;
  final VoidCallback onConfirm;
  final VoidCallback onRefreshQuote;

  @override
  Widget build(BuildContext context) {
    final quote = state.quote;
    return _ReviewLayout(
      onBack: onBack,
      onInfo: () => showPrivateUsdReviewInfoSheet(
        context,
        railgunPercent: kPrivateUsdRailgunFeePercent,
      ),
      pay: quote == null
          ? null
          : MobileSwapReviewHeaderRow(
              label: PrivateUsdCopy.convertYouPay,
              amountText: _masked(_zec(quote.totalZat), privacyModeEnabled),
              asset: SwapAsset.zec,
              bottomText: PrivateUsdCopy.convertZecIncludesFee,
            ),
      receive: quote == null
          ? null
          : MobileSwapReviewHeaderRow(
              label: PrivateUsdCopy.convertYouReceive,
              amountText: _masked(
                formatPrivateUsd(quote.receives),
                privacyModeEnabled,
              ),
              asset: SwapAsset.usdc,
              icon: const PrivateUsdLogo(),
              bottomText: PrivateUsdCopy.title,
            ),
      ledger: quote == null
          ? null
          : PrivateUsdQuoteLedger(
              quote: quote,
              privacyModeEnabled: privacyModeEnabled,
            ),
      note: PrivateUsdCopy.convertBackgroundNote,
      state: state,
      message: state.message,
      onConfirm: onConfirm,
      onRefreshQuote: onRefreshQuote,
    );
  }
}

/// The reverse review: the debit and the ZEC estimate, the ledger and how
/// long the quote holds, and when settlement must be authorized.
class MobilePrivateUsdReverseReviewView extends StatelessWidget {
  const MobilePrivateUsdReverseReviewView({
    required this.state,
    required this.privacyModeEnabled,
    required this.onBack,
    required this.onConfirm,
    required this.onRefreshQuote,
    super.key,
  });

  final PrivateUsdReverseConvertState state;
  final bool privacyModeEnabled;
  final VoidCallback onBack;
  final VoidCallback onConfirm;
  final VoidCallback onRefreshQuote;

  @override
  Widget build(BuildContext context) {
    final draft = state.draft;
    return _ReviewLayout(
      onBack: onBack,
      onInfo: () => showPrivateUsdReverseInfoSheet(context),
      pay: draft == null
          ? null
          : MobileSwapReviewHeaderRow(
              label: PrivateUsdCopy.convertYouPay,
              amountText: _masked(
                formatPrivateUsd(privateUsdReverseDebit(draft)),
                privacyModeEnabled,
              ),
              asset: SwapAsset.usdc,
              icon: const PrivateUsdLogo(),
              bottomText: PrivateUsdCopy.title,
            ),
      receive: draft == null
          ? null
          : MobileSwapReviewHeaderRow(
              label: PrivateUsdCopy.convertYouReceive,
              amountText: _masked(
                _zec(privateUsdReverseReceivedZat(draft)),
                privacyModeEnabled,
              ),
              asset: SwapAsset.zec,
              bottomText: PrivateUsdCopy.shieldedZec,
            ),
      ledger: draft == null
          ? null
          : PrivateUsdReverseLedger(
              record: draft,
              privacyModeEnabled: privacyModeEnabled,
            ),
      note: draft == null
          ? null
          : PrivateUsdCopy.reverseKeepOpen(
              formatDayMonthTime(privateUsdReadyBy(draft)),
            ),
      state: state,
      message: state.message,
      onConfirm: onConfirm,
      onRefreshQuote: onRefreshQuote,
    );
  }
}

/// What both reviews lay out: the header and [ledger] of the quote (none
/// without one), how long it holds, the [note], a message, and the button
/// that bridges, or refreshes the quote once it expired.
class _ReviewLayout extends StatelessWidget {
  const _ReviewLayout({
    required this.onBack,
    required this.onInfo,
    required this.pay,
    required this.receive,
    required this.ledger,
    required this.note,
    required this.state,
    required this.message,
    required this.onConfirm,
    required this.onRefreshQuote,
  });

  final VoidCallback onBack;
  final VoidCallback onInfo;
  final MobileSwapReviewHeaderRow? pay;
  final MobileSwapReviewHeaderRow? receive;
  final Widget? ledger;
  final String? note;
  final PrivateUsdConvertFlowState state;
  final String? message;
  final VoidCallback onConfirm;
  final VoidCallback onRefreshQuote;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pay = this.pay;
    final receive = this.receive;
    final ledger = this.ledger;
    final note = this.note;
    final message = this.message;
    final confirming = state.isConfirming;
    final expired = state.isExpired && !state.quoting;
    return PrivateUsdFlowScaffold(
      title: PrivateUsdCopy.review,
      onBack: confirming ? null : onBack,
      onInfo: onInfo,
      body: PrivateUsdFlowColumn(
        key: const ValueKey('mobile_private_usd_review_scroll'),
        top: 0,
        children: [
          if (pay != null && receive != null && ledger != null) ...[
            MobileSwapReviewHeader(pay: pay, receive: receive),
            ledger,
            const SizedBox(height: AppSpacing.xs),
            PrivateUsdQuoteExpiry(
              expired: expired,
              label: PrivateUsdCopy.convertQuoteHolds(
                formatMinutesSeconds(state.expiresIn),
              ),
            ),
          ],
          if (note != null) ...[
            const SizedBox(height: AppSpacing.s),
            Text(
              note,
              key: const ValueKey('mobile_private_usd_review_keep_open'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
          if (message != null) ...[
            const SizedBox(height: AppSpacing.s),
            MobileWarningNotice(
              key: const ValueKey('mobile_private_usd_review_message'),
              message: message,
            ),
          ],
        ],
      ),
      action: expired
          ? AppButton(
              key: const ValueKey('mobile_private_usd_review_refresh'),
              expand: true,
              onPressed: onRefreshQuote,
              leading: const AppIcon(AppIcons.renew),
              child: const Text(PrivateUsdCopy.convertNewQuote),
            )
          : AppButton(
              key: const ValueKey('mobile_private_usd_review_convert'),
              expand: true,
              onPressed: state.canConfirm ? onConfirm : null,
              leading: confirming || state.quoting
                  ? const AppLoadingIcon(size: AppIconSize.medium)
                  : null,
              child: Text(
                state.quoting
                    ? PrivateUsdCopy.convertQuoteLoading
                    : PrivateUsdCopy.actionConvert,
              ),
            ),
    );
  }
}
