import 'package:flutter/material.dart'
    show InputDecoration, Scaffold, TextField;
import 'package:flutter/widgets.dart';

import '../../../../core/formatting/date_format.dart';
import '../../../../core/formatting/zec_amount.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/comma_to_dot_input_formatter.dart';
import '../../../../core/widgets/decimal_amount_input_formatter.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/neon_scramble_text.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../rust/api/private_usd.dart' show ApiReverseRecord;
import '../../../swap/domain/swap_asset.dart';
import '../../../swap/widgets/mobile/mobile_swap_review_header.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_reverse_presentation.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_convert_provider.dart';
import '../../providers/private_usd_reverse_convert_provider.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import 'mobile_private_usd_convert_screen.dart';

/// The reverse amount step (plan reference §9.4 S4), private USD → ZEC: the
/// dollars to convert (2 decimals), the ZEC estimate, the priced quote's
/// ledger and countdown, and "Review". Widgetbook, capture scenarios and
/// tests build it directly.
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

  /// The direction toggle; null hides it.
  final VoidCallback? onSwitchDirection;
  final VoidCallback? onViewRefunds;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final message = state.message;
    final draft = state.draft;
    final busy = state.quoting || state.lookingUp;
    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileTopNav.back(
              title: PrivateUsdCopy.convertTitle,
              onBack: onBack,
              trailing: PrivateUsdInfoButton(
                onTap: () => showPrivateUsdReverseInfoSheet(context),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('mobile_private_usd_convert_scroll'),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _UsdCard(
                      state: state,
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: autofocus,
                      privacyModeEnabled: privacyModeEnabled,
                      onAmountChanged: onAmountChanged,
                      onMax: onMax,
                    ),
                    PrivateUsdDirectionToggle(
                      onTap: onSwitchDirection,
                      busy: busy,
                    ),
                    _ZecCard(
                      state: state,
                      privacyModeEnabled: privacyModeEnabled,
                    ),
                    if (draft != null && state.debit != null && !busy) ...[
                      const SizedBox(height: AppSpacing.s),
                      PrivateUsdReverseLedger(
                        record: draft,
                        privacyModeEnabled: privacyModeEnabled,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      PrivateUsdQuoteExpiry(
                        expired: state.isExpired,
                        label: PrivateUsdCopy.convertQuoteExpires(
                          formatMinutesSeconds(state.expiresIn),
                        ),
                      ),
                    ],
                    if (message != null) ...[
                      const SizedBox(height: AppSpacing.s),
                      MobileWarningNotice(
                        key: const ValueKey(
                          'mobile_private_usd_convert_message',
                        ),
                        message: message,
                      ),
                    ],
                    if (state.showsRefunds && onViewRefunds != null) ...[
                      const SizedBox(height: AppSpacing.s),
                      AppButton(
                        key: const ValueKey(
                          'mobile_private_usd_convert_refunds',
                        ),
                        variant: AppButtonVariant.secondary,
                        expand: true,
                        onPressed: onViewRefunds,
                        child: const Text(PrivateUsdCopy.refundsView),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                AppSpacing.s,
                AppSpacing.sm,
                AppSpacing.md,
              ),
              child: AppButton(
                key: const ValueKey('mobile_private_usd_convert_review'),
                expand: true,
                onPressed: state.canReview ? onReview : null,
                leading: busy
                    ? const AppLoadingIcon(size: AppIconSize.medium)
                    : null,
                child: Text(
                  state.quoting
                      ? PrivateUsdCopy.convertQuoteLoading
                      : PrivateUsdCopy.review,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UsdCard extends StatelessWidget {
  const _UsdCard({
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.autofocus,
    required this.privacyModeEnabled,
    required this.onAmountChanged,
    required this.onMax,
  });

  final PrivateUsdReverseConvertState state;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool privacyModeEnabled;
  final ValueChanged<String> onAmountChanged;
  final VoidCallback onMax;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final amountStyle = AppTypography.displayLarge.copyWith(
      color: state.isAmountInvalid || state.isTooPrecise
          ? colors.text.destructive
          : colors.text.accent,
    );
    final available = state.available;
    final availableText = available == null
        ? PrivateUsdCopy.unknown
        : hideAmountIfPrivacyMode(
            formatPrivateUsd(available),
            privacyModeEnabled: privacyModeEnabled,
            denomination: '',
          );
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_convert_usd'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PrivateUsdPanelCaption(PrivateUsdCopy.title),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            key: const ValueKey('mobile_private_usd_convert_amount'),
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            readOnly: state.step != PrivateUsdConvertStep.amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            // Whole cents only: Rust refuses anything finer.
            inputFormatters: [
              const CommaToDotInputFormatter(),
              DecimalAmountInputFormatter(maxFractionDigits: 2),
            ],
            onChanged: onAmountChanged,
            style: amountStyle,
            cursorColor: colors.neon.glow,
            decoration: InputDecoration.collapsed(
              hintText: '0',
              hintStyle: amountStyle.copyWith(color: colors.text.muted),
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${PrivateUsdCopy.rowAvailable}: $availableText',
                  key: const ValueKey('mobile_private_usd_convert_available'),
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.secondary,
                  ),
                ),
              ),
              Semantics(
                label: PrivateUsdCopy.useAvailable,
                button: true,
                excludeSemantics: true,
                child: AppButton(
                  key: const ValueKey('mobile_private_usd_convert_max'),
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.small,
                  onPressed: state.canMax ? onMax : null,
                  leading: state.lookingUp
                      ? const AppLoadingIcon(size: AppIconSize.medium)
                      : null,
                  child: const Text(PrivateUsdCopy.max),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ZecCard extends StatelessWidget {
  const _ZecCard({required this.state, required this.privacyModeEnabled});

  final PrivateUsdReverseConvertState state;
  final bool privacyModeEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final draft = state.draft;
    final known = draft != null && state.debit != null && !state.quoting;
    final estimate = known
        ? hideAmountIfPrivacyMode(
            ZecAmount.fromZatoshi(
              privateUsdReverseReceivedZat(draft),
            ).activity.toString(),
            privacyModeEnabled: privacyModeEnabled,
            denomination: '',
          )
        : PrivateUsdCopy.unknown;
    final cipherStyle = AppTypography.displayLarge.copyWith(
      color: colors.neon.glow.withValues(alpha: 0.7),
    );
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_convert_estimate'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PrivateUsdPanelCaption(PrivateUsdCopy.convertAssetZec),
          const SizedBox(height: AppSpacing.xs),
          // While the quote is on its way the amount churns as cipher; the
          // quote then decrypts in.
          if (state.quoting)
            NeonCipherChurn(
              key: const ValueKey('mobile_private_usd_convert_receive'),
              style: cipherStyle,
              semanticsLabel: PrivateUsdCopy.convertQuoteLoading,
            )
          else
            NeonScrambleText(
              key: const ValueKey('mobile_private_usd_convert_receive'),
              text: estimate,
              decryptOnAppear: known,
              cipherStyle: cipherStyle,
              style: AppTypography.displayLarge.copyWith(
                color: known ? colors.neon.core : colors.text.disabled,
                shadows: known
                    ? Neon.textGlow(colors.neon.glow, intensity: 0.4)
                    : null,
              ),
            ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            PrivateUsdCopy.convertEstimatedAmount,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// A priced reverse quote's ledger (zapp `PrivateUsdReverseMapper.review`):
/// the escrow value, Railgun's unshield fee, the broadcast fee, the total
/// paid, the maker's network cost when it names one, and the ZEC estimate.
class PrivateUsdReverseLedger extends StatelessWidget {
  const PrivateUsdReverseLedger({
    required this.record,
    required this.privacyModeEnabled,
    super.key,
  });

  final ApiReverseRecord record;
  final bool privacyModeEnabled;

  String _masked(String text) => hideAmountIfPrivacyMode(
    text,
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );

  @override
  Widget build(BuildContext context) {
    final cost = record.cost;
    final networkCost = BigInt.tryParse(record.networkCost ?? '');
    final rows = <(String, String)>[
      (
        PrivateUsdCopy.reverseEscrow,
        _masked(formatPrivateUsd(BigInt.parse(record.amount))),
      ),
      if (cost != null) ...[
        (
          PrivateUsdCopy.reverseRailgunFee,
          formatPrivateUsd(BigInt.parse(cost.railgunFee)),
        ),
        (
          PrivateUsdCopy.reverseBroadcasterFee,
          formatPrivateUsd(BigInt.parse(cost.broadcasterFee)),
        ),
        (
          PrivateUsdCopy.reverseTotal,
          _masked(formatPrivateUsd(BigInt.parse(cost.debit))),
        ),
      ],
      if (networkCost != null && networkCost > BigInt.zero)
        (PrivateUsdCopy.convertMakerCost, formatPrivateUsd(networkCost)),
      (
        PrivateUsdCopy.reverseReceiveEstimate,
        _masked(
          ZecAmount.fromZatoshi(
            privateUsdReverseReceivedZat(record),
          ).activity.toString(),
        ),
      ),
    ];
    return PrivateUsdLedgerCard(
      key: const ValueKey('mobile_private_usd_quote_ledger'),
      rows: [
        for (final (label, value) in rows)
          PrivateUsdLedgerRow(label: label, value: value),
      ],
    );
  }
}

/// The reverse review (plan reference §9.4 S4): "{$debit} for about {ZEC}",
/// the ledger, the quote's countdown, when settlement must be authorized,
/// and "Convert" (accept, then pay). Widgetbook, capture scenarios and tests
/// build it directly.
class MobilePrivateUsdReverseReviewView extends StatelessWidget {
  const MobilePrivateUsdReverseReviewView({
    required this.state,
    required this.privacyModeEnabled,
    required this.onBack,
    required this.onConfirm,
    required this.onRefreshQuote,
    this.showsTorOffDisclosure = false,
    super.key,
  });

  final PrivateUsdReverseConvertState state;
  final bool privacyModeEnabled;
  final VoidCallback onBack;
  final VoidCallback onConfirm;
  final VoidCallback onRefreshQuote;

  /// The token service's view of the device next to the IP (D10), once
  /// Vizor fetches conversion tokens (M4).
  final bool showsTorOffDisclosure;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final draft = state.draft;
    final message = state.message;
    final confirming = state.isConfirming;
    final expired = state.isExpired && !state.quoting;
    String masked(String text) => hideAmountIfPrivacyMode(
      text,
      privacyModeEnabled: privacyModeEnabled,
      denomination: '',
    );
    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileTopNav.back(
              title: PrivateUsdCopy.convertReviewTitle,
              onBack: confirming ? null : onBack,
              trailing: PrivateUsdInfoButton(
                onTap: () => showPrivateUsdReverseInfoSheet(context),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('mobile_private_usd_review_scroll'),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  0,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (draft != null) ...[
                      MobileSwapReviewHeader(
                        pay: MobileSwapReviewHeaderRow(
                          label: PrivateUsdCopy.convertYouPay,
                          amountText: masked(
                            formatPrivateUsd(privateUsdReverseDebit(draft)),
                          ),
                          asset: SwapAsset.usdc,
                          bottomText: PrivateUsdCopy.title,
                        ),
                        receive: MobileSwapReviewHeaderRow(
                          label: PrivateUsdCopy.convertYouReceive,
                          amountText: masked(
                            ZecAmount.fromZatoshi(
                              privateUsdReverseReceivedZat(draft),
                            ).activity.toString(),
                          ),
                          asset: SwapAsset.zec,
                        ),
                      ),
                      PrivateUsdReverseLedger(
                        record: draft,
                        privacyModeEnabled: privacyModeEnabled,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      PrivateUsdQuoteExpiry(
                        expired: expired,
                        label: PrivateUsdCopy.convertQuoteHolds(
                          formatMinutesSeconds(state.expiresIn),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s),
                      Text(
                        PrivateUsdCopy.reverseKeepOpen(
                          formatDayMonthTime(privateUsdReadyBy(draft)),
                        ),
                        key: const ValueKey(
                          'mobile_private_usd_review_keep_open',
                        ),
                        style: AppTypography.bodySmall.copyWith(
                          color: colors.text.secondary,
                        ),
                      ),
                    ],
                    if (showsTorOffDisclosure) ...[
                      const SizedBox(height: AppSpacing.s),
                      Text(
                        PrivateUsdCopy.torOffDisclosure,
                        key: const ValueKey(
                          'mobile_private_usd_review_tor_off',
                        ),
                        style: AppTypography.bodySmall.copyWith(
                          color: colors.text.warning,
                        ),
                      ),
                    ],
                    if (message != null) ...[
                      const SizedBox(height: AppSpacing.s),
                      MobileWarningNotice(
                        key: const ValueKey(
                          'mobile_private_usd_review_message',
                        ),
                        message: message,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                AppSpacing.s,
                AppSpacing.sm,
                AppSpacing.md,
              ),
              child: expired
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
            ),
          ],
        ),
      ),
    );
  }
}
