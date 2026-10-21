import 'package:flutter/widgets.dart';

import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../private_usd_copy.dart';

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

/// The convert screen's info sheet.
Future<void> showPrivateUsdConvertInfoSheet(
  BuildContext context, {
  required Duration takes,
}) => _show(
  context,
  title: PrivateUsdCopy.convertInfoTitle,
  steps: const [
    PrivateUsdCopy.convertInfoStepQuote,
    PrivateUsdCopy.convertInfoStepDeposit,
    PrivateUsdCopy.convertInfoStepClaim,
  ],
  notes: [
    PrivateUsdCopy.convertInfoNoteEither,
    PrivateUsdCopy.convertInfoNoteTime(PrivateUsdCopy.about(takes)),
  ],
);

/// The review's info sheet.
Future<void> showPrivateUsdReviewInfoSheet(
  BuildContext context, {
  required String railgunPercent,
}) => _show(
  context,
  title: PrivateUsdCopy.convertReviewInfoTitle,
  steps: [
    PrivateUsdCopy.convertReviewInfoPay,
    PrivateUsdCopy.convertReviewInfoReceive(railgunPercent),
    PrivateUsdCopy.convertReviewInfoQuote,
  ],
  notes: const [PrivateUsdCopy.infoKeepOpen],
);

/// The progress screen's info sheet.
Future<void> showPrivateUsdProgressInfoSheet(
  BuildContext context, {
  required int zcashConfirmations,
  required Duration screening,
}) => _show(
  context,
  title: PrivateUsdCopy.convertProgressInfoTitle,
  steps: [
    PrivateUsdCopy.convertProgressInfoOpen,
    PrivateUsdCopy.convertProgressInfoDeposit,
    PrivateUsdCopy.convertProgressInfoConfirm(zcashConfirmations),
    PrivateUsdCopy.convertProgressInfoClaim,
    PrivateUsdCopy.convertProgressInfoScreen(PrivateUsdCopy.about(screening)),
  ],
  notes: const [
    PrivateUsdCopy.convertProgressInfoRefund,
    PrivateUsdCopy.infoKeepOpen,
  ],
);

/// The reverse screens' info sheet: the two approvals, and when a refund
/// can follow.
Future<void> showPrivateUsdReverseInfoSheet(BuildContext context) => _show(
  context,
  title: PrivateUsdCopy.reverseTitle,
  steps: const [PrivateUsdCopy.reverseIntro],
  notes: const [PrivateUsdCopy.reverseRefundNote, PrivateUsdCopy.infoKeepOpen],
);

/// The send screens' info sheet.
Future<void> showPrivateUsdSendInfoSheet(BuildContext context) => _show(
  context,
  title: PrivateUsdCopy.sendInfoTitle,
  steps: const [
    PrivateUsdCopy.sendInfoStepAddress,
    PrivateUsdCopy.sendInfoStepProof,
    PrivateUsdCopy.sendInfoStepPrivate,
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
  title: PrivateUsdCopy.withdrawInfoTitle,
  steps: const [
    PrivateUsdCopy.withdrawInfoStepAddress,
    PrivateUsdCopy.withdrawInfoStepProof,
  ],
  notes: [
    PrivateUsdCopy.withdrawInfoNotePublic,
    PrivateUsdCopy.withdrawInfoNotePrivate,
    PrivateUsdCopy.withdrawInfoNoteFee(railgunPercent),
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
    title: PrivateUsdCopy.infoTitle,
    steps: [
      if (bridgeAvailable) PrivateUsdCopy.infoConvert,
      PrivateUsdCopy.infoReceive,
      PrivateUsdCopy.infoSend,
      PrivateUsdCopy.infoWithdraw,
      PrivateUsdCopy.infoRefunds,
    ],
    notes: [
      PrivateUsdCopy.infoScreening(PrivateUsdCopy.about(screening)),
      PrivateUsdCopy.infoPrivate,
      PrivateUsdCopy.infoKeepOpen,
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
              child: const Text(PrivateUsdCopy.close),
            ),
          ],
        ),
      ),
    );
  }
}
