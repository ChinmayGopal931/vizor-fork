import 'package:flutter/widgets.dart';

import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../private_usd_copy.dart';
import '../../../../core/l10n/l10n.dart';

/// The Private USD screen's info sheet: what each action does, then the
/// notes on screening, privacy and keeping the app open. [screening] is the
/// deployment's screening time; with [bridgeAvailable] off, Bridge is not
/// among the actions.
Future<void> showPrivateUsdInfoSheet(
  BuildContext context, {
  required Duration screening,
  bool bridgeAvailable = true,
}) {
  return showAppMobileSheet<void>(
    context: context,
    builder: (sheetContext) => PrivateUsdInfoSheetBody(
      screening: screening,
      bridgeAvailable: bridgeAvailable,
      onClose: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

/// The convert screen's info sheet; with [relayerClaims] (Settings), the
/// relayer claims.
Future<void> showPrivateUsdConvertInfoSheet(
  BuildContext context, {
  required Duration takes,
  required bool relayerClaims,
}) => _show(
  context,
  title: context.l10n.privateUsdConvertInfoTitle,
  steps: [
    context.l10n.privateUsdConvertInfoStepQuote,
    context.l10n.privateUsdConvertInfoStepDeposit,
    relayerClaims
        ? context.l10n.privateUsdConvertInfoStepClaimRelayer
        : context.l10n.privateUsdConvertInfoStepClaim,
  ],
  notes: [
    context.l10n.privateUsdConvertInfoNoteEither,
    relayerClaims
        ? context.l10n.privateUsdConvertInfoNoteTimeRelayer(
            PrivateUsdCopy.about(context.l10n, takes),
          )
        : context.l10n.privateUsdConvertInfoNoteTime(
            PrivateUsdCopy.about(context.l10n, takes),
          ),
  ],
);

/// The review's info sheet; with [relayerClaims] (Settings), the relayer
/// claims.
Future<void> showPrivateUsdReviewInfoSheet(
  BuildContext context, {
  required String railgunPercent,
  required bool relayerClaims,
}) => _show(
  context,
  title: context.l10n.privateUsdConvertReviewInfoTitle,
  steps: [
    context.l10n.privateUsdConvertReviewInfoPay,
    context.l10n.privateUsdConvertReviewInfoReceive(railgunPercent),
    context.l10n.privateUsdConvertReviewInfoQuote,
  ],
  notes: [
    relayerClaims
        ? context.l10n.privateUsdConvertRelayerInfoKeepOpen
        : context.l10n.privateUsdInfoKeepOpen,
  ],
);

/// The progress screen's info sheet; with [relayerClaims], the relayer holds
/// the claim.
Future<void> showPrivateUsdProgressInfoSheet(
  BuildContext context, {
  required int zcashConfirmations,
  required Duration screening,
  required bool relayerClaims,
}) => _show(
  context,
  title: context.l10n.privateUsdConvertProgressInfoTitle,
  steps: [
    context.l10n.privateUsdConvertProgressInfoOpen,
    context.l10n.privateUsdConvertProgressInfoDeposit,
    context.l10n.privateUsdConvertProgressInfoConfirm(zcashConfirmations),
    relayerClaims
        ? context.l10n.privateUsdConvertProgressInfoClaimRelayer
        : context.l10n.privateUsdConvertProgressInfoClaim,
    context.l10n.privateUsdConvertProgressInfoScreen(
      PrivateUsdCopy.about(context.l10n, screening),
    ),
  ],
  notes: [
    context.l10n.privateUsdConvertProgressInfoRefund,
    relayerClaims
        ? context.l10n.privateUsdConvertRelayerInfoKeepOpen
        : context.l10n.privateUsdInfoKeepOpen,
  ],
);

/// The reverse screens' info sheet: the two approvals, and when a refund
/// can follow.
Future<void> showPrivateUsdReverseInfoSheet(BuildContext context) => _show(
  context,
  title: context.l10n.privateUsdReverseTitle,
  steps: [context.l10n.privateUsdReverseIntro],
  notes: [
    context.l10n.privateUsdReverseRefundNote,
    context.l10n.privateUsdInfoKeepOpen,
  ],
);

/// The send screens' info sheet.
Future<void> showPrivateUsdSendInfoSheet(BuildContext context) => _show(
  context,
  title: context.l10n.privateUsdSendInfoTitle,
  steps: [
    context.l10n.privateUsdSendInfoStepAddress,
    context.l10n.privateUsdSendInfoStepProof,
    context.l10n.privateUsdSendInfoStepPrivate,
  ],
  notes: const [],
);

/// The withdraw screens' info sheet, with Railgun's fee as
/// [railgunPercent].
Future<void> showPrivateUsdWithdrawInfoSheet(
  BuildContext context, {
  required String railgunPercent,
}) => _show(
  context,
  title: context.l10n.privateUsdWithdrawInfoTitle,
  steps: [
    context.l10n.privateUsdWithdrawInfoStepAddress,
    context.l10n.privateUsdWithdrawInfoStepProof,
  ],
  notes: [
    context.l10n.privateUsdWithdrawInfoNotePublic,
    context.l10n.privateUsdWithdrawInfoNotePrivate,
    context.l10n.privateUsdWithdrawInfoNoteFee(railgunPercent),
  ],
);

Future<void> _show(
  BuildContext context, {
  required String title,
  required List<String> steps,
  required List<String> notes,
}) {
  return showAppMobileSheet<void>(
    context: context,
    builder: (sheetContext) => PrivateUsdTextSheetBody(
      title: title,
      steps: steps,
      notes: notes,
      onClose: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

class PrivateUsdInfoSheetBody extends StatelessWidget {
  const PrivateUsdInfoSheetBody({
    required this.screening,
    required this.onClose,
    this.bridgeAvailable = true,
    super.key,
  });

  final Duration screening;
  final bool bridgeAvailable;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => PrivateUsdTextSheetBody(
    title: context.l10n.privateUsdInfoTitle,
    steps: [
      if (bridgeAvailable) context.l10n.privateUsdInfoConvert,
      context.l10n.privateUsdInfoReceive,
      context.l10n.privateUsdInfoSend,
      context.l10n.privateUsdInfoWithdraw,
      context.l10n.privateUsdInfoRefunds,
    ],
    notes: [
      context.l10n.privateUsdInfoScreening(
        PrivateUsdCopy.about(context.l10n, screening),
      ),
      context.l10n.privateUsdInfoPrivate,
      context.l10n.privateUsdInfoKeepOpen,
    ],
    onClose: onClose,
  );
}

/// An info sheet: a title, what happens in order, then notes, and a close
/// button.
class PrivateUsdTextSheetBody extends StatelessWidget {
  const PrivateUsdTextSheetBody({
    required this.title,
    required this.steps,
    required this.notes,
    required this.onClose,
    super.key,
  });

  final String title;
  final List<String> steps;
  final List<String> notes;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = AppTypography.bodyMedium.copyWith(color: colors.text.primary);
    final note = AppTypography.bodySmall.copyWith(color: colors.text.secondary);
    return MobileBottomSafeArea(
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
            for (final step in steps) ...[
              Text(step, style: body),
              const SizedBox(height: AppSpacing.xs),
            ],
            const SizedBox(height: AppSpacing.xs),
            for (final line in notes) ...[
              Text(line, style: note),
              const SizedBox(height: AppSpacing.xxs),
            ],
            const SizedBox(height: AppSpacing.md),
            AppButton(
              variant: AppButtonVariant.secondary,
              expand: true,
              onPressed: onClose,
              child: Text(context.l10n.commonClose),
            ),
          ],
        ),
      ),
    );
  }
}
