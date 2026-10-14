import 'dart:async';

import 'package:flutter/material.dart' show Scaffold, SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../providers/account_provider.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_send.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_send_provider.dart';
import '../../providers/private_usd_spend_status_provider.dart';
import '../../services/private_usd_spend_guard.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import 'mobile_private_usd_convert_screen.dart';

/// `/private-usd/send/review` and `/private-usd/withdraw/review` (plan
/// reference §9.4 S8): what goes, what it costs and where, then "Send" or
/// "Withdraw", which opens the status while it proves and posts. Pops with
/// `true` once the send is done, so the form closes too.
class MobilePrivateUsdSendReviewScreen extends ConsumerWidget {
  const MobilePrivateUsdSendReviewScreen({required this.mode, super.key});

  final PrivateUsdSendMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    final form = ref.watch(privateUsdSendProvider(mode));
    final notifier = ref.read(privateUsdSendProvider(mode).notifier);
    final balances = uuid == null
        ? null
        : ref.watch(privateUsdBalanceProvider(uuid)).balances;
    final status = uuid == null
        ? PrivateUsdSpendStatus.checking
        : ref.watch(privateUsdSpendStatusProvider(uuid));

    Future<void> confirm() async {
      if (!notifier.canConfirm) return;
      unawaited(notifier.confirm());
      final finished = await context.push<bool>(
        '/private-usd/send/status',
        extra: mode,
      );
      if (!context.mounted) return;
      final phase = ref.read(privateUsdSendProvider(mode)).phase;
      if (finished == true || phase == PrivateUsdSendPhase.done) {
        context.pop(true);
      } else if (phase == PrivateUsdSendPhase.form) {
        // Repriced past what the balance leaves: back to the form.
        context.pop(false);
      }
    }

    return PopScope<Object?>(
      canPop: !form.isBusy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) notifier.leaveReview();
      },
      child: MobilePrivateUsdSendReviewView(
        form: form,
        balances: balances,
        status: status,
        canConfirm: notifier.canConfirm,
        onBack: () {
          if (notifier.leaveReview()) context.pop(false);
        },
        onConfirm: confirm,
      ),
    );
  }
}

/// The review's content for a given form. Widgetbook, capture scenarios
/// and tests build it directly.
class MobilePrivateUsdSendReviewView extends StatelessWidget {
  const MobilePrivateUsdSendReviewView({
    required this.form,
    required this.balances,
    required this.status,
    required this.canConfirm,
    required this.onBack,
    required this.onConfirm,
    super.key,
  });

  final PrivateUsdSendForm form;
  final PrivateUsdBalances? balances;
  final PrivateUsdSpendStatus status;
  final bool canConfirm;
  final VoidCallback onBack;
  final VoidCallback onConfirm;

  bool get _private => form.mode == PrivateUsdSendMode.private;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final request = form.reviewed;
    final cost = form.cost;
    final message =
        form.error ??
        form.reviewError(balances) ??
        (form.isBusy ? null : privateUsdSpendMessage(status));
    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileTopNav.back(
              title: _private
                  ? PrivateUsdCopy.sendReviewTitlePrivate
                  : PrivateUsdCopy.sendReviewTitleWithdraw,
              onBack: form.isBusy ? null : onBack,
              trailing: PrivateUsdInfoButton(
                onTap: () => _private
                    ? showPrivateUsdSendInfoSheet(context)
                    : showPrivateUsdWithdrawInfoSheet(
                        context,
                        railgunPercent: cost == null || cost.feeBasisPoints == 0
                            ? kPrivateUsdRailgunFeePercent
                            : privateUsdPercentText(cost.feeBasisPoints),
                      ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('mobile_private_usd_send_review_scroll'),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (request != null && cost != null)
                      _ReviewLedger(
                        rows: privateUsdSendReviewRows(
                          request,
                          cost,
                          feeToken: form.networkFee?.token,
                        ),
                      ),
                    if (!_private) ...[
                      const SizedBox(height: AppSpacing.s),
                      Text(
                        PrivateUsdCopy.sendWithdrawPublic,
                        key: const ValueKey(
                          'mobile_private_usd_send_review_public',
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
                          'mobile_private_usd_send_review_message',
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
              child: AppButton(
                key: const ValueKey('mobile_private_usd_send_confirm'),
                expand: true,
                onPressed: canConfirm ? onConfirm : null,
                leading: form.isBusy
                    ? const AppLoadingIcon(size: AppIconSize.medium)
                    : null,
                child: Text(
                  form.isBusy
                      ? PrivateUsdCopy.sendSending
                      : _private
                      ? PrivateUsdCopy.actionSend
                      : PrivateUsdCopy.actionWithdraw,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Label and value rows; a long value (the address) wraps under its label.
class _ReviewLedger extends StatelessWidget {
  const _ReviewLedger({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = AppTypography.bodyMedium.copyWith(
      color: colors.text.secondary,
    );
    final value = AppTypography.bodyMedium.copyWith(color: colors.text.accent);
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_send_review_ledger'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.xs),
            if (rows[i].$2.length > 24) ...[
              Text(rows[i].$1, style: label),
              const SizedBox(height: AppSpacing.xxs),
              SelectableText(rows[i].$2, style: value),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(rows[i].$1, style: label)),
                  const SizedBox(width: AppSpacing.s),
                  Text(rows[i].$2, textAlign: TextAlign.end, style: value),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
