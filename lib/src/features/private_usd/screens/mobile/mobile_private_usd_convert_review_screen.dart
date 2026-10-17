import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/formatting/zec_amount.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../swap/domain/swap_asset.dart';
import '../../../swap/widgets/mobile/mobile_swap_review_header.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_record_key.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_convert_provider.dart';
import '../../providers/private_usd_reverse_convert_provider.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import '../../widgets/mobile/private_usd_logo.dart';
import 'mobile_private_usd_convert_screen.dart';
import 'mobile_private_usd_reverse_convert_view.dart';

/// `/private-usd/convert/review` (plan reference §9.4 S3): the reviewed
/// quote and "Convert". It pops with the conversion's route once accepted
/// (or found under way after an accept that may have opened it), and the
/// convert screen replaces itself with that progress.
class MobilePrivateUsdConvertReviewScreen extends ConsumerWidget {
  const MobilePrivateUsdConvertReviewScreen({required this.args, super.key});

  final PrivateUsdReviewArgs args;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (args.direction == PrivateUsdDirection.reverse) {
      return _buildReverse(context, ref);
    }
    final state = ref.watch(privateUsdConvertProvider);
    final notifier = ref.read(privateUsdConvertProvider.notifier);
    if (state.quote == null) {
      // Reopened without its flow (a stale stack): nothing to review.
      return MobilePrivateUsdConvertReviewView(
        state: state,
        privacyModeEnabled: false,
        onBack: () => context.pop(),
        onConfirm: () {},
        onRefreshQuote: () {},
      );
    }
    void back() {
      if (notifier.leaveReview()) context.pop();
    }

    return PopScope(
      canPop: !state.isConfirming,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) notifier.leaveReview();
      },
      child: MobilePrivateUsdConvertReviewView(
        state: state,
        privacyModeEnabled: ref.watch(privacyModeProvider),
        onBack: back,
        onConfirm: () async {
          final path = await notifier.confirm();
          if (path != null && context.mounted) {
            context.pop<PrivateUsdRoutePath>(path);
          }
        },
        onRefreshQuote: notifier.refreshQuote,
      ),
    );
  }

  /// The reverse review (§9.4 S4): "Convert" goes ahead, accepts and pays,
  /// then pops with the conversion's route.
  Widget _buildReverse(BuildContext context, WidgetRef ref) {
    final state = ref.watch(privateUsdReverseConvertProvider);
    final notifier = ref.read(privateUsdReverseConvertProvider.notifier);
    if (state.draft == null) {
      return MobilePrivateUsdReverseReviewView(
        state: state,
        privacyModeEnabled: false,
        onBack: () => context.pop(),
        onConfirm: () {},
        onRefreshQuote: () {},
      );
    }
    void back() {
      if (notifier.leaveReview()) context.pop();
    }

    return PopScope(
      canPop: !state.isConfirming,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) notifier.leaveReview();
      },
      child: MobilePrivateUsdReverseReviewView(
        state: state,
        privacyModeEnabled: ref.watch(privacyModeProvider),
        onBack: back,
        onConfirm: () async {
          final path = await notifier.confirm();
          if (path != null && context.mounted) {
            context.pop<PrivateUsdRoutePath>(path);
          }
        },
        onRefreshQuote: notifier.refreshQuote,
      ),
    );
  }
}

/// The review's content for a given state. Widgetbook, capture scenarios
/// and tests build it directly.
class MobilePrivateUsdConvertReviewView extends StatelessWidget {
  const MobilePrivateUsdConvertReviewView({
    required this.state,
    required this.privacyModeEnabled,
    required this.onBack,
    required this.onConfirm,
    required this.onRefreshQuote,
    this.showsTorOffDisclosure = false,
    super.key,
  });

  final PrivateUsdConvertState state;
  final bool privacyModeEnabled;
  final VoidCallback onBack;
  final VoidCallback onConfirm;
  final VoidCallback onRefreshQuote;

  /// The token service's view of the device next to the IP (D10). Only once
  /// Vizor fetches conversion tokens (M4); M5 converts without them.
  final bool showsTorOffDisclosure;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final quote = state.quote;
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
                onTap: () => showPrivateUsdReviewInfoSheet(
                  context,
                  railgunPercent: kPrivateUsdRailgunFeePercent,
                ),
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
                    if (quote != null) ...[
                      MobileSwapReviewHeader(
                        pay: MobileSwapReviewHeaderRow(
                          label: PrivateUsdCopy.convertYouPay,
                          amountText: masked(
                            ZecAmount.fromZatoshi(
                              quote.totalZat,
                            ).activity.toString(),
                          ),
                          asset: SwapAsset.zec,
                          bottomText: PrivateUsdCopy.convertZecIncludesFee,
                        ),
                        receive: MobileSwapReviewHeaderRow(
                          label: PrivateUsdCopy.convertYouReceive,
                          amountText: masked(formatPrivateUsd(quote.receives)),
                          asset: SwapAsset.usdc,
                          icon: const PrivateUsdLogo(),
                          bottomText: PrivateUsdCopy.title,
                        ),
                      ),
                      PrivateUsdQuoteLedger(
                        quote: quote,
                        privacyModeEnabled: privacyModeEnabled,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      PrivateUsdQuoteExpiry(
                        expired: expired,
                        label: PrivateUsdCopy.convertQuoteHolds(
                          formatMinutesSeconds(state.expiresIn),
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.s),
                    Text(
                      PrivateUsdCopy.convertBackgroundNote,
                      key: const ValueKey(
                        'mobile_private_usd_review_keep_open',
                      ),
                      style: AppTypography.bodySmall.copyWith(
                        color: colors.text.secondary,
                      ),
                    ),
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
