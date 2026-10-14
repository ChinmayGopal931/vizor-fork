import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/formatting/zec_amount.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../rust/api/private_usd.dart';
import '../../../activity/activity_amount_text.dart';
import '../../../activity/activity_feed_sections.dart';
import '../../../activity/activity_row_mapper.dart';
import '../../../activity/models/activity_row_data.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_status_presentation.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_activity_provider.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../services/private_usd_engine.dart';
import 'private_usd_home_strip.dart';

/// A forward conversion's activity row (plan reference §9.4 S2), or null
/// when it moved no money (nothing sent).
///
/// - Under way: "Converting ZEC", its stage, `+$receives` (neutral); opens
///   its progress.
/// - Paid: "Converted ZEC", the ZEC paid, `+$receives` (positive); opens the
///   payout on Etherscan.
/// - Refunded: "Conversion called off", "your ZEC came back", no amount.
ActivityRowData? buildPrivateUsdActivityRow({
  required BuildContext context,
  required ApiForwardRecord record,
  required int zcashConfirmations,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  VoidCallback? onOpenConversion,
  VoidCallback? onOpenPayout,
}) {
  final colors = context.colors;
  final usd = hideAmountIfPrivacyMode(
    formatPrivateUsd(BigInt.parse(record.receives)),
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
  final timestamp = formatActivityTimestamp(
    privateUsdActivityTime(record),
    dateOnly: dateOnlyTimestamp,
  );
  final base = (
    stableId: 'private-usd:forward:${record.index}',
    leadingBackgroundColor: colors.background.neutralSubtleOpacity,
    leadingIconColor: colors.icon.regular,
  );
  switch (record.outcome) {
    case null:
      return ActivityRowData(
        stableId: base.stableId,
        title: PrivateUsdCopy.activityConverting,
        leadingIconName: kPrivateUsdIcon,
        leadingBackgroundColor: base.leadingBackgroundColor,
        leadingIconColor: base.leadingIconColor,
        subtitle: privateUsdForwardStageLabel(
          PrivateUsdConversionStatus(record: record),
          zcashConfirmations: zcashConfirmations,
        ),
        amountText: activityAmountTextForFormFactor(
          PrivateUsdCopy.activityIn(usd),
        ),
        amountColor: outgoingAmountColor(colors),
        statusText: '',
        statusIconName: AppIcons.loader,
        statusColor: colors.text.secondary,
        timestampText: timestamp,
        onTap: onOpenConversion,
      );
    case ApiForwardOutcome.paid:
      final zec = privacyModeEnabled
          ? fixedPrivacyMask()
          : ZecAmount.fromZatoshi(
              record.maxTotalZat ?? record.depositZat,
            ).activity.toString();
      return ActivityRowData(
        stableId: base.stableId,
        title: PrivateUsdCopy.activityConverted,
        leadingIconName: kPrivateUsdIcon,
        leadingBackgroundColor: base.leadingBackgroundColor,
        leadingIconColor: base.leadingIconColor,
        subtitle: zec,
        amountText: activityAmountTextForFormFactor(
          PrivateUsdCopy.activityIn(usd),
        ),
        amountColor: colors.text.positiveStrong,
        statusText: '',
        timestampText: timestamp,
        onTap: onOpenPayout,
      );
    case ApiForwardOutcome.refunded:
      return ActivityRowData(
        stableId: base.stableId,
        title: PrivateUsdCopy.activityRefunded,
        leadingIconName: AppIcons.uturnUp,
        leadingBackgroundColor: base.leadingBackgroundColor,
        leadingIconColor: base.leadingIconColor,
        subtitle: PrivateUsdCopy.activityRefundedDetail,
        amountText: '',
        statusText: '',
        timestampText: timestamp,
      );
    case ApiForwardOutcome.nothingSent:
      return null;
  }
}

/// [records] as activity entries for the home and Activity feeds.
List<ActivityEntry> privateUsdActivityEntries({
  required BuildContext context,
  required List<ApiForwardRecord> records,
  required int zcashConfirmations,
  required bool privacyModeEnabled,
  required ValueChanged<PrivateUsdRoutePath> onOpenConversion,
  required ValueChanged<String> onOpenPayout,
  bool dateOnlyTimestamp = false,
}) => [
  for (final record in records)
    if (buildPrivateUsdActivityRow(
          context: context,
          record: record,
          zcashConfirmations: zcashConfirmations,
          privacyModeEnabled: privacyModeEnabled,
          dateOnlyTimestamp: dateOnlyTimestamp,
          onOpenConversion: () => onOpenConversion(
            PrivateUsdRoutePath(
              direction: PrivateUsdDirection.forward,
              index: record.index,
            ),
          ),
          onOpenPayout: switch (record.payoutTx) {
            final payout? => () => onOpenPayout(payout),
            null => null,
          },
        )
        case final row?)
      ActivityEntry(timestamp: privateUsdActivityTime(record), row: row),
];

/// Opens a payout on Etherscan (the deployment's explorer), outside Vizor.
Future<void> openPrivateUsdPayout(WidgetRef ref, String payoutTx) async {
  final prefix = ref
      .read(privateUsdCurrentDeploymentProvider)
      ?.explorerTxPrefix;
  final uri = prefix == null ? null : Uri.tryParse('$prefix$payoutTx');
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
