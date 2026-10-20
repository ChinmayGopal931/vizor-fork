import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../providers/account_provider.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_messages.dart';
import '../../models/private_usd_send.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_send_provider.dart';
import '../../providers/private_usd_spend_status_provider.dart';
import '../../services/private_usd_spend_guard.dart';
import '../../widgets/mobile/private_usd_flow_widgets.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';

/// `/private-usd/send/review` and `/private-usd/withdraw/review`: what goes,
/// what it costs and where, then the button that sends, which opens the
/// status while it proves and posts. Pops with `true` once the send is done,
/// so the form closes too.
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

/// The review's content for a given form.
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
    return PrivateUsdFlowScaffold(
      title: _private
          ? PrivateUsdCopy.sendReviewTitlePrivate
          : PrivateUsdCopy.sendReviewTitleWithdraw,
      onBack: form.isBusy ? null : onBack,
      onInfo: () => _private
          ? showPrivateUsdSendInfoSheet(context)
          : showPrivateUsdWithdrawInfoSheet(
              context,
              railgunPercent: cost == null || cost.feeBasisPoints == 0
                  ? kPrivateUsdRailgunFeePercent
                  : privateUsdPercentText(cost.feeBasisPoints),
            ),
      body: PrivateUsdFlowColumn(
        key: const ValueKey('mobile_private_usd_send_review_scroll'),
        children: [
          if (request != null && cost != null)
            PrivateUsdLedgerCard(
              key: const ValueKey('mobile_private_usd_send_review_ledger'),
              rows: [
                for (final (label, value) in privateUsdSendReviewRows(
                  request,
                  cost,
                  feeToken: form.networkFee?.token,
                ))
                  PrivateUsdLedgerRow(label: label, value: value),
                PrivateUsdLedgerAddress(
                  label: PrivateUsdCopy.sendReviewTo,
                  address: request.to.text,
                ),
              ],
            ),
          if (!_private) ...[
            const SizedBox(height: AppSpacing.s),
            Text(
              PrivateUsdCopy.sendWithdrawPublic,
              key: const ValueKey('mobile_private_usd_send_review_public'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.warning,
              ),
            ),
          ],
          if (message != null) ...[
            const SizedBox(height: AppSpacing.s),
            MobileWarningNotice(
              key: const ValueKey('mobile_private_usd_send_review_message'),
              message: message,
            ),
          ],
        ],
      ),
      action: AppButton(
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
    );
  }
}
