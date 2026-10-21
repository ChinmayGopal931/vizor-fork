import 'package:flutter/widgets.dart';

import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../private_usd_copy.dart';

/// Asks before a reverse conversion is called off: once unlocked there is
/// no app-lock prompt, so a sheet guards it. [action] is the label of the
/// button that asked, cancelling or requesting a refund; [paid] says whether
/// private USD was paid already. True once confirmed.
Future<bool> confirmPrivateUsdReverseCancel(
  BuildContext context, {
  required String action,
  required bool paid,
}) async {
  final confirmed = await showAppMobileSheet<bool>(
    context: context,
    builder: (sheetContext) => PrivateUsdConfirmSheetBody(
      sheetKey: const ValueKey('private_usd_cancel_sheet'),
      title: PrivateUsdCopy.reverseCancelConfirmTitle,
      body: paid
          ? PrivateUsdCopy.reverseCancelConfirmBody
          : PrivateUsdCopy.reverseCancelConfirmUnpaidBody,
      confirmLabel: action,
      destructive: true,
      onConfirm: () => Navigator.of(sheetContext).pop(true),
      onDismiss: () => Navigator.of(sheetContext).pop(false),
    ),
  );
  return confirmed ?? false;
}

/// Asks before a refund is recovered: the relayer's fee, at most [feeCap],
/// comes out of it. True once confirmed.
Future<bool> confirmPrivateUsdRefundRecovery(
  BuildContext context, {
  required String feeCap,
}) async {
  final confirmed = await showAppMobileSheet<bool>(
    context: context,
    builder: (sheetContext) => PrivateUsdConfirmSheetBody(
      sheetKey: const ValueKey('private_usd_rescue_sheet'),
      title: PrivateUsdCopy.refundsRecoverConfirmTitle,
      body: PrivateUsdCopy.refundsRecoverConfirmBody(feeCap),
      confirmLabel: PrivateUsdCopy.refundsRecover,
      onConfirm: () => Navigator.of(sheetContext).pop(true),
      onDismiss: () => Navigator.of(sheetContext).pop(false),
    ),
  );
  return confirmed ?? false;
}

/// Asks before a deposit Railgun's screening sent back is recovered: the
/// relayer's [fee] comes out of it. True once confirmed.
Future<bool> confirmPrivateUsdDepositRescue(
  BuildContext context, {
  required String fee,
}) async {
  final confirmed = await showAppMobileSheet<bool>(
    context: context,
    builder: (sheetContext) => PrivateUsdConfirmSheetBody(
      sheetKey: const ValueKey('private_usd_deposit_rescue_sheet'),
      title: PrivateUsdCopy.refundsDepositConfirmTitle,
      body: PrivateUsdCopy.refundsDepositConfirmBody(fee),
      confirmLabel: PrivateUsdCopy.refundsDepositRecover,
      onConfirm: () => Navigator.of(sheetContext).pop(true),
      onDismiss: () => Navigator.of(sheetContext).pop(false),
    ),
  );
  return confirmed ?? false;
}

/// A confirmation sheet: a title, what follows, the action and a way out.
class PrivateUsdConfirmSheetBody extends StatelessWidget {
  const PrivateUsdConfirmSheetBody({
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onDismiss,
    this.destructive = false,
    this.sheetKey,
    super.key,
  });

  final String title;
  final String body;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;
  final bool destructive;
  final Key? sheetKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MobileBottomSafeArea(
      key: sheetKey,
      bottomPadding: AppSpacing.base,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm,
          AppSpacing.base,
          AppSpacing.sm,
          AppSpacing.base,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: AppTypography.headlineSmall.copyWith(
                color: colors.text.accent,
              ),
            ),
            const SizedBox(height: AppSpacing.s),
            Text(
              body,
              style: AppTypography.bodyMedium.copyWith(
                color: colors.text.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              key: const ValueKey('private_usd_confirm_sheet_confirm'),
              variant: destructive
                  ? AppButtonVariant.destructive
                  : AppButtonVariant.primary,
              expand: true,
              onPressed: onConfirm,
              child: Text(confirmLabel),
            ),
            const SizedBox(height: AppSpacing.xs),
            AppButton(
              key: const ValueKey('private_usd_confirm_sheet_dismiss'),
              variant: AppButtonVariant.secondary,
              expand: true,
              onPressed: onDismiss,
              child: const Text(PrivateUsdCopy.notNow),
            ),
          ],
        ),
      ),
    );
  }
}
