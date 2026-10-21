import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/formatting/address_display.dart';
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
import '../../models/private_usd_deposits.dart';
import '../../models/private_usd_explorer.dart';
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_send.dart';
import '../../models/private_usd_reverse_presentation.dart';
import '../../models/private_usd_status_presentation.dart';
import '../../models/railgun_models.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_activity_provider.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../services/private_usd_engine.dart';
import 'private_usd_logo.dart';

// Private USD's rows lead with its logo; the glyph stands in only where a
// row cannot draw an image.
const _glyph = AppIcons.moneyBag;
const _logo = PrivateUsdLogo(size: AppAssetSize.size);

/// A forward conversion's activity row, or null when it moved no money
/// (nothing sent). Under way, it shows its stage and opens its progress;
/// paid, the ZEC paid, opening the payout; refunded, that the ZEC came
/// back, with no amount.
ActivityRowData? buildPrivateUsdActivityRow({
  required BuildContext context,
  required ApiForwardRecord record,
  required int zcashConfirmations,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  VoidCallback? onOpenConversion,
  VoidCallback? onOpenTransaction,
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
        title: PrivateUsdCopy.convertingToUsd,
        leadingIconName: _glyph,
        leading: _logo,
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
        leadingIconName: _glyph,
        leading: _logo,
        leadingBackgroundColor: base.leadingBackgroundColor,
        leadingIconColor: base.leadingIconColor,
        subtitle: zec,
        amountText: activityAmountTextForFormFactor(
          PrivateUsdCopy.activityIn(usd),
        ),
        amountColor: colors.text.positiveStrong,
        statusText: '',
        timestampText: timestamp,
        onTap: onOpenTransaction,
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

/// A reverse conversion's activity row, or null when it moved no money (a
/// draft, or cancelled). Under way, it shows its step and opens its
/// progress; complete, the ZEC received, opening the funding; refunded,
/// that the dollars came back, opening Refunds.
ActivityRowData? buildPrivateUsdReverseActivityRow({
  required BuildContext context,
  required ApiReverseRecord record,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  VoidCallback? onOpenConversion,
  VoidCallback? onOpenTransaction,
  VoidCallback? onOpenRefunds,
}) {
  final colors = context.colors;
  final usd = hideAmountIfPrivacyMode(
    formatPrivateUsd(privateUsdReverseDebit(record)),
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
  final timestamp = formatActivityTimestamp(
    privateUsdReverseActivityTime(record),
    dateOnly: dateOnlyTimestamp,
  );
  final stableId = 'private-usd:reverse:${record.index}';
  final background = colors.background.neutralSubtleOpacity;
  final icon = colors.icon.regular;
  switch (record.phase) {
    case ApiReversePhase.quoted || ApiReversePhase.cancelled:
      return null;
    case ApiReversePhase.complete:
      final zec = privacyModeEnabled
          ? fixedPrivacyMask()
          : ZecAmount.fromZatoshi(
              privateUsdReverseReceivedZat(record),
            ).activity.toString();
      return ActivityRowData(
        stableId: stableId,
        title: PrivateUsdCopy.activityConvertedToZec,
        leadingIconName: _glyph,
        leading: _logo,
        leadingBackgroundColor: background,
        leadingIconColor: icon,
        subtitle: zec,
        amountText: activityAmountTextForFormFactor(
          PrivateUsdCopy.activityOut(usd),
        ),
        amountColor: outgoingAmountColor(colors),
        statusText: '',
        timestampText: timestamp,
        onTap: onOpenTransaction,
      );
    case ApiReversePhase.refunded:
      return ActivityRowData(
        stableId: stableId,
        title: PrivateUsdCopy.activityRefunded,
        leadingIconName: AppIcons.uturnUp,
        leadingBackgroundColor: background,
        leadingIconColor: icon,
        subtitle: PrivateUsdCopy.activityRefundedZecDetail,
        amountText: '',
        statusText: '',
        timestampText: timestamp,
        onTap: onOpenRefunds,
      );
    default:
      return ActivityRowData(
        stableId: stableId,
        title: PrivateUsdCopy.convertingToZec,
        leadingIconName: _glyph,
        leading: _logo,
        leadingBackgroundColor: background,
        leadingIconColor: icon,
        subtitle: privateUsdReverseStageLabel(record),
        amountText: activityAmountTextForFormFactor(
          PrivateUsdCopy.activityOut(usd),
        ),
        amountColor: outgoingAmountColor(colors),
        statusText: '',
        statusIconName: AppIcons.loader,
        statusColor: colors.text.secondary,
        timestampText: timestamp,
        onTap: onOpenConversion,
      );
  }
}

/// A send or withdrawal's activity row: to its truncated recipient once in
/// a block, else not in a block yet; it opens its transaction once known. A
/// send still being proved is not in the log, so it has no row.
ActivityRowData buildPrivateUsdSendActivityRow({
  required BuildContext context,
  required ApiSendRecord record,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  VoidCallback? onOpenTransaction,
}) {
  final colors = context.colors;
  final unconfirmed = record.state == ApiSendState.unconfirmed;
  final usd = hideAmountIfPrivacyMode(
    formatPrivateUsdExact(
      BigInt.parse(record.amount),
      PrivateUsdBalances.decimals,
    ),
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
  return ActivityRowData(
    stableId: 'private-usd:send:${record.sendId}',
    title: record.withdraw
        ? PrivateUsdCopy.activityWithdrew
        : PrivateUsdCopy.activitySent,
    leadingIconName: _glyph,
    leading: _logo,
    leadingBackgroundColor: colors.background.neutralSubtleOpacity,
    leadingIconColor: colors.icon.regular,
    subtitle: unconfirmed
        ? PrivateUsdCopy.activityUnconfirmed
        : PrivateUsdCopy.activityTo(truncatedAddress(record.to)),
    amountText: activityAmountTextForFormFactor(
      PrivateUsdCopy.activityOut(usd),
    ),
    amountColor: outgoingAmountColor(colors),
    statusText: '',
    statusIconName: unconfirmed ? AppIcons.loader : null,
    statusColor: unconfirmed ? colors.text.secondary : null,
    timestampText: formatActivityTimestamp(
      privateUsdSendActivityTime(record),
      dateOnly: dateOnlyTimestamp,
    ),
    onTap: onOpenTransaction,
  );
}

/// When a send's row sorts: when it was kept.
DateTime privateUsdSendActivityTime(ApiSendRecord record) =>
    DateTime.fromMillisecondsSinceEpoch(record.sentAt * 1000);

/// A private send this wallet received: in once screened (spendable, or spent
/// since), from its sender's truncated address where the sender showed it;
/// it opens its transaction.
ActivityRowData buildPrivateUsdReceivedActivityRow({
  required BuildContext context,
  required RailgunReceipt receipt,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  VoidCallback? onOpenTransaction,
}) {
  final colors = context.colors;
  final settled = receipt.settled;
  final sender = receipt.sender;
  final usd = hideAmountIfPrivacyMode(
    formatPrivateUsdExact(receipt.amount, PrivateUsdBalances.decimals),
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
  return ActivityRowData(
    stableId:
        'private-usd:received:${receipt.txid}:${receipt.token}:'
        '${receipt.amount}',
    title: PrivateUsdCopy.activityReceived,
    leadingIconName: _glyph,
    leading: _logo,
    leadingBackgroundColor: colors.background.neutralSubtleOpacity,
    leadingIconColor: colors.icon.regular,
    subtitle: !settled
        ? PrivateUsdCopy.activityReceivedScreening
        : sender == null
        ? PrivateUsdCopy.activitySenderHidden
        : PrivateUsdCopy.activityFrom(truncatedAddress(sender)),
    amountText: activityAmountTextForFormFactor(PrivateUsdCopy.activityIn(usd)),
    amountColor: settled
        ? colors.text.positiveStrong
        : outgoingAmountColor(colors),
    statusText: '',
    statusIconName: settled ? null : AppIcons.loader,
    statusColor: settled ? null : colors.text.secondary,
    timestampText: formatActivityTimestamp(
      privateUsdReceivedActivityTime(receipt),
      dateOnly: dateOnlyTimestamp,
    ),
    onTap: onOpenTransaction,
  );
}

/// When a received send's row sorts: when its block was made.
DateTime privateUsdReceivedActivityTime(RailgunReceipt receipt) =>
    receipt.at ?? DateTime.fromMillisecondsSinceEpoch(0);

/// A deposit's activity row, or null for one that moved nothing (it was
/// signed again in its place, ran out, was refused or reverted: the money is
/// still at the deposit address, which the screen shows). Once landed it
/// counts as arrived, and opens its transaction.
ActivityRowData? buildPrivateUsdDepositActivityRow({
  required BuildContext context,
  required ApiDepositRecord record,
  required Duration screening,
  DateTime Function() now = DateTime.now,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  VoidCallback? onOpenTransaction,
}) {
  final colors = context.colors;
  final arrives = hideAmountIfPrivacyMode(
    formatPrivateUsd(BigInt.tryParse(record.arrives) ?? BigInt.zero),
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
  final value = hideAmountIfPrivacyMode(
    formatPrivateUsd(BigInt.tryParse(record.value) ?? BigInt.zero),
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
  final landedAt = privateUsdDepositLandedAt(record);
  final String subtitle;
  switch (record.state) {
    case ApiDepositState.signed:
      subtitle = record.waiting
          ? PrivateUsdCopy.depositWaiting
          : PrivateUsdCopy.depositReceived(value);
    case ApiDepositState.sent:
      subtitle = PrivateUsdCopy.depositMakingPrivate;
    case ApiDepositState.landed:
      subtitle = landedAt != null && now().difference(landedAt) < screening
          ? PrivateUsdCopy.depositPrivate(PrivateUsdCopy.about(screening))
          : PrivateUsdCopy.activityDepositPrivate;
    case ApiDepositState.refused ||
        ApiDepositState.reverted ||
        ApiDepositState.replaced ||
        ApiDepositState.expired:
      return null;
  }
  final landed = record.state == ApiDepositState.landed;
  return ActivityRowData(
    stableId: 'private-usd:deposit:${record.id}',
    title: record.kind == ApiDepositKind.rescue
        ? PrivateUsdCopy.activityDepositRescue
        : PrivateUsdCopy.activityDeposit,
    leadingIconName: _glyph,
    leading: _logo,
    leadingBackgroundColor: colors.background.neutralSubtleOpacity,
    leadingIconColor: colors.icon.regular,
    subtitle: subtitle,
    amountText: activityAmountTextForFormFactor(
      PrivateUsdCopy.activityIn(arrives),
    ),
    amountColor: landed
        ? colors.text.positiveStrong
        : outgoingAmountColor(colors),
    statusText: '',
    statusIconName: landed ? null : AppIcons.loader,
    statusColor: landed ? null : colors.text.secondary,
    timestampText: formatActivityTimestamp(
      privateUsdDepositActivityTime(record),
      dateOnly: dateOnlyTimestamp,
    ),
    onTap: landed ? onOpenTransaction : null,
  );
}

/// When a deposit's row sorts: when it landed, else when it was signed.
DateTime privateUsdDepositActivityTime(ApiDepositRecord record) =>
    privateUsdDepositLandedAt(record) ??
    DateTime.fromMillisecondsSinceEpoch(record.createdAt * 1000);

/// [activity] (and on `/private-usd`, [sendRecords] and [receipts]) as feed
/// entries. [onOpenPayout] opens any row's transaction, not only a payout: a
/// deposit's, a send's, a received send's or a funding's too.
List<ActivityEntry> privateUsdFeedEntries({
  required BuildContext context,
  required PrivateUsdActivity activity,
  required bool privacyModeEnabled,
  required ValueChanged<PrivateUsdRoutePath> onOpenConversion,
  required ValueChanged<String> onOpenPayout,
  VoidCallback? onOpenRefunds,
  List<ApiSendRecord> sendRecords = const [],
  List<RailgunReceipt> receipts = const [],
  bool dateOnlyTimestamp = false,
}) {
  VoidCallback? openTransaction(String? tx) =>
      tx == null ? null : () => onOpenPayout(tx);
  void openConversion(PrivateUsdDirection direction, int index) =>
      onOpenConversion(PrivateUsdRoutePath(direction: direction, index: index));
  return [
    for (final record in activity.depositRecords)
      if (buildPrivateUsdDepositActivityRow(
            context: context,
            record: record,
            screening: activity.screening,
            privacyModeEnabled: privacyModeEnabled,
            dateOnlyTimestamp: dateOnlyTimestamp,
            onOpenTransaction: openTransaction(record.txHash),
          )
          case final row?)
        ActivityEntry(
          timestamp: privateUsdDepositActivityTime(record),
          row: row,
        ),
    for (final record in sendRecords)
      ActivityEntry(
        timestamp: privateUsdSendActivityTime(record),
        row: buildPrivateUsdSendActivityRow(
          context: context,
          record: record,
          privacyModeEnabled: privacyModeEnabled,
          dateOnlyTimestamp: dateOnlyTimestamp,
          onOpenTransaction: openTransaction(record.txHash),
        ),
      ),
    for (final receipt in receipts)
      ActivityEntry(
        timestamp: privateUsdReceivedActivityTime(receipt),
        row: buildPrivateUsdReceivedActivityRow(
          context: context,
          receipt: receipt,
          privacyModeEnabled: privacyModeEnabled,
          dateOnlyTimestamp: dateOnlyTimestamp,
          onOpenTransaction: openTransaction(receipt.txid),
        ),
      ),
    for (final record in activity.reverseRecords)
      if (buildPrivateUsdReverseActivityRow(
            context: context,
            record: record,
            privacyModeEnabled: privacyModeEnabled,
            dateOnlyTimestamp: dateOnlyTimestamp,
            onOpenConversion: () =>
                openConversion(PrivateUsdDirection.reverse, record.index),
            onOpenTransaction: openTransaction(record.fundingTx),
            onOpenRefunds: onOpenRefunds,
          )
          case final row?)
        ActivityEntry(
          timestamp: privateUsdReverseActivityTime(record),
          row: row,
        ),
    for (final record in activity.records)
      if (buildPrivateUsdActivityRow(
            context: context,
            record: record,
            zcashConfirmations: activity.zcashConfirmations,
            privacyModeEnabled: privacyModeEnabled,
            dateOnlyTimestamp: dateOnlyTimestamp,
            onOpenConversion: () =>
                openConversion(PrivateUsdDirection.forward, record.index),
            onOpenTransaction: openTransaction(record.payoutTx),
          )
          case final row?)
        ActivityEntry(timestamp: privateUsdActivityTime(record), row: row),
  ];
}

/// Opens [txHash] on the deployment's Ethereum explorer, outside the app.
Future<void> openPrivateUsdPayout(WidgetRef ref, String txHash) async {
  final uri = privateUsdExplorerUri(
    ref.read(privateUsdCurrentDeploymentProvider)?.explorerTxPrefix,
    txHash,
  );
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
