import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/config/zcash_explorer.dart';
import '../../../../core/formatting/address_display.dart';
import '../../../../core/formatting/zec_amount.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/rpc_endpoint_provider.dart';
import '../../../../providers/zcash_explorer_provider.dart';
import '../../../../rust/api/private_usd.dart';
import '../../../activity/activity_amount_text.dart';
import '../../../activity/activity_feed_sections.dart';
import '../../../activity/activity_row_mapper.dart';
import '../../../activity/models/activity_row_data.dart';
import '../../models/private_usd_activity_details.dart';
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
import 'private_usd_activity_details.dart';
import 'private_usd_logo.dart';

// Private USD's rows lead with its logo; the glyph stands in only where a
// row cannot draw an image.
const _glyph = AppIcons.moneyBag;
const _logo = PrivateUsdLogo(size: AppAssetSize.size);

/// A forward conversion's activity row, or null when it moved no money
/// (nothing sent). Under way, it shows its stage and opens its progress;
/// paid, the ZEC paid; refunded, that the ZEC came back, with no amount;
/// ended unstarted after its market maker fee was mined, that fee, which
/// isn't refunded. Ended, it unfolds into its [details].
ActivityRowData? buildPrivateUsdActivityRow({
  required BuildContext context,
  required ApiForwardRecord record,
  required int zcashConfirmations,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  VoidCallback? onOpenConversion,
  PrivateUsdActivityDetailsConfig? details,
}) {
  final l10n = context.l10n;
  final colors = context.colors;
  final usd = hideAmountIfPrivacyMode(
    formatPrivateUsd(BigInt.parse(record.receives)),
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
  final timestamp = formatActivityTimestamp(
    l10n,
    privateUsdActivityTime(record),
    dateOnly: dateOnlyTimestamp,
  );
  final base = (
    stableId: 'private-usd:forward:${record.index}',
    leadingBackgroundColor: colors.background.neutralSubtleOpacity,
    leadingIconColor: colors.icon.regular,
  );
  late final unfold = _unfold(
    details,
    base.stableId,
    () => privateUsdForwardDetails(
      l10n,
      record,
      privacyModeEnabled: privacyModeEnabled,
    ),
  );
  switch (record.outcome) {
    case null:
      return ActivityRowData(
        stableId: base.stableId,
        title: context.l10n.privateUsdConvertingToUsd,
        leadingIconName: _glyph,
        leading: _logo,
        leadingBackgroundColor: base.leadingBackgroundColor,
        leadingIconColor: base.leadingIconColor,
        subtitle: privateUsdForwardStageLabel(
          context.l10n,
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
      final zec = privateUsdForwardPaidText(
        record,
        privacyModeEnabled: privacyModeEnabled,
      );
      return ActivityRowData(
        stableId: base.stableId,
        title: context.l10n.privateUsdActivityConverted,
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
        details: unfold.details,
        onTap: unfold.onTap,
      );
    case ApiForwardOutcome.refunded:
      return ActivityRowData(
        stableId: base.stableId,
        title: context.l10n.privateUsdActivityRefunded,
        leadingIconName: AppIcons.uturnUp,
        leadingBackgroundColor: base.leadingBackgroundColor,
        leadingIconColor: base.leadingIconColor,
        subtitle: context.l10n.privateUsdActivityRefundedDetail,
        amountText: '',
        statusText: '',
        timestampText: timestamp,
        details: unfold.details,
        onTap: unfold.onTap,
      );
    case ApiForwardOutcome.nothingSent:
      // The fee is the one thing it moved: its row stands in for the fee's
      // own transaction, which the feeds leave out.
      final fee = record.openFeeZat;
      if (fee == null || !record.openFeeMined) return null;
      final paid = fee + (record.openFeeNetworkZat ?? BigInt.zero);
      final zec = privacyModeEnabled
          ? fixedPrivacyMask()
          : ZecAmount.fromZatoshi(paid).activity.toString();
      final out = PrivateUsdCopy.activityOut(zec);
      // Its payment's own network fee unknown, the amount is approximate:
      // "≈ −0.25 ZEC", the sign kept with the number.
      final approximate =
          record.openFeeNetworkZat == null && !privacyModeEnabled;
      return ActivityRowData(
        stableId: base.stableId,
        title: context.l10n.privateUsdActivityFeeLost,
        leadingIconName: _glyph,
        leading: _logo,
        leadingBackgroundColor: base.leadingBackgroundColor,
        leadingIconColor: base.leadingIconColor,
        subtitle: context.l10n.privateUsdActivityFeeLostDetail,
        amountText: activityAmountTextForFormFactor(
          approximate ? PrivateUsdCopy.approximately(out) : out,
        ),
        amountColor: outgoingAmountColor(colors),
        statusText: '',
        timestampText: timestamp,
        details: unfold.details,
        onTap: unfold.onTap,
      );
  }
}

/// A reverse conversion's activity row, or null when it moved no money (a
/// draft, or cancelled). Under way, it shows its step and opens its
/// progress; complete, the ZEC received, unfolding into its [details];
/// refunded, that the dollars came back, opening Refunds.
ActivityRowData? buildPrivateUsdReverseActivityRow({
  required BuildContext context,
  required ApiReverseRecord record,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  VoidCallback? onOpenConversion,
  PrivateUsdActivityDetailsConfig? details,
  VoidCallback? onOpenRefunds,
}) {
  final l10n = context.l10n;
  final colors = context.colors;
  final usd = hideAmountIfPrivacyMode(
    formatPrivateUsdNearest(privateUsdReverseDebit(record)),
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
  final timestamp = formatActivityTimestamp(
    l10n,
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
      final unfold = _unfold(
        details,
        stableId,
        () => privateUsdReverseDetails(
          l10n,
          record,
          privacyModeEnabled: privacyModeEnabled,
        ),
      );
      return ActivityRowData(
        stableId: stableId,
        title: context.l10n.privateUsdActivityConvertedToZec,
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
        details: unfold.details,
        onTap: unfold.onTap,
      );
    case ApiReversePhase.refunded:
      return ActivityRowData(
        stableId: stableId,
        title: context.l10n.privateUsdActivityRefunded,
        leadingIconName: AppIcons.uturnUp,
        leadingBackgroundColor: background,
        leadingIconColor: icon,
        subtitle: context.l10n.privateUsdActivityRefundedZecDetail,
        amountText: '',
        statusText: '',
        timestampText: timestamp,
        onTap: onOpenRefunds,
      );
    default:
      return ActivityRowData(
        stableId: stableId,
        title: context.l10n.privateUsdConvertingToZec,
        leadingIconName: _glyph,
        leading: _logo,
        leadingBackgroundColor: background,
        leadingIconColor: icon,
        subtitle: privateUsdReverseStageLabel(context.l10n, record),
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
/// a block, else not in a block yet; it unfolds into its [details]. A send
/// still being proved is not in the log, so it has no row.
ActivityRowData buildPrivateUsdSendActivityRow({
  required BuildContext context,
  required ApiSendRecord record,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  PrivateUsdActivityDetailsConfig? details,
}) {
  final l10n = context.l10n;
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
  final stableId = 'private-usd:send:${record.sendId}';
  final unfold = _unfold(
    details,
    stableId,
    () => privateUsdSendDetails(
      l10n,
      record,
      privacyModeEnabled: privacyModeEnabled,
    ),
  );
  return ActivityRowData(
    stableId: stableId,
    title: record.withdraw
        ? context.l10n.privateUsdActivityWithdrew
        : context.l10n.privateUsdActivitySent,
    leadingIconName: _glyph,
    leading: _logo,
    leadingBackgroundColor: colors.background.neutralSubtleOpacity,
    leadingIconColor: colors.icon.regular,
    subtitle: unconfirmed
        ? context.l10n.privateUsdActivityUnconfirmed
        : context.l10n.privateUsdActivityTo(truncatedAddress(record.to)),
    amountText: activityAmountTextForFormFactor(
      PrivateUsdCopy.activityOut(usd),
    ),
    amountColor: outgoingAmountColor(colors),
    statusText: '',
    statusIconName: unconfirmed ? AppIcons.loader : null,
    statusColor: unconfirmed ? colors.text.secondary : null,
    timestampText: formatActivityTimestamp(
      l10n,
      privateUsdSendActivityTime(record),
      dateOnly: dateOnlyTimestamp,
    ),
    details: unfold.details,
    onTap: unfold.onTap,
  );
}

String _receivedStableId(RailgunReceipt receipt, int copy) =>
    'private-usd:received:${receipt.txid}:${receipt.token}:${receipt.amount}' // l10n-ignore: row identifier
    '${copy == 0 ? '' : ':$copy'}';

/// [receipts] each with how many equal receipts come before it.
Iterable<(RailgunReceipt, int)> _receiptCopies(
  List<RailgunReceipt> receipts,
) sync* {
  final seen = <String, int>{};
  for (final receipt in receipts) {
    final id = _receivedStableId(receipt, 0);
    final copy = seen[id] ?? 0;
    seen[id] = copy + 1;
    yield (receipt, copy);
  }
}

/// When a send's row sorts: when it was kept.
DateTime privateUsdSendActivityTime(ApiSendRecord record) =>
    DateTime.fromMillisecondsSinceEpoch(record.sentAt * 1000);

/// A private send this wallet received: in once screened (spendable, or spent
/// since), from its sender's truncated address where the sender showed it;
/// it unfolds into its [details]. [copy] counts the equal receipts listed
/// before it (one transaction's notes of the same token and amount), which
/// keeps their rows apart.
ActivityRowData buildPrivateUsdReceivedActivityRow({
  required BuildContext context,
  required RailgunReceipt receipt,
  int copy = 0,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  PrivateUsdActivityDetailsConfig? details,
}) {
  final l10n = context.l10n;
  final colors = context.colors;
  final settled = receipt.settled;
  final sender = receipt.sender;
  final usd = hideAmountIfPrivacyMode(
    formatPrivateUsdExact(receipt.amount, PrivateUsdBalances.decimals),
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
  final stableId = _receivedStableId(receipt, copy);
  final unfold = _unfold(
    details,
    stableId,
    () => privateUsdReceivedDetails(
      l10n,
      receipt,
      privacyModeEnabled: privacyModeEnabled,
    ),
  );
  return ActivityRowData(
    stableId: stableId,
    title: context.l10n.privateUsdActivityReceived,
    leadingIconName: _glyph,
    leading: _logo,
    leadingBackgroundColor: colors.background.neutralSubtleOpacity,
    leadingIconColor: colors.icon.regular,
    subtitle: !settled
        ? context.l10n.privateUsdActivityReceivedScreening
        : sender == null
        ? context.l10n.privateUsdActivitySenderHidden
        : context.l10n.privateUsdActivityFrom(truncatedAddress(sender)),
    amountText: activityAmountTextForFormFactor(PrivateUsdCopy.activityIn(usd)),
    amountColor: settled
        ? colors.text.positiveStrong
        : outgoingAmountColor(colors),
    statusText: '',
    statusIconName: settled ? null : AppIcons.loader,
    statusColor: settled ? null : colors.text.secondary,
    timestampText: formatActivityTimestamp(
      l10n,
      privateUsdReceivedActivityTime(receipt),
      dateOnly: dateOnlyTimestamp,
    ),
    details: unfold.details,
    onTap: unfold.onTap,
  );
}

/// When a received send's row sorts: when its block was made.
DateTime privateUsdReceivedActivityTime(RailgunReceipt receipt) =>
    receipt.at ?? DateTime.fromMillisecondsSinceEpoch(0);

/// A deposit's activity row, or null for one that moved nothing (it was
/// signed again in its place, ran out, was refused or reverted: the money is
/// still at the deposit address, which the screen shows). Once landed it
/// counts as arrived. It unfolds into its [details].
ActivityRowData? buildPrivateUsdDepositActivityRow({
  required BuildContext context,
  required ApiDepositRecord record,
  required Duration screening,
  DateTime Function() now = DateTime.now,
  bool privacyModeEnabled = false,
  bool dateOnlyTimestamp = false,
  PrivateUsdActivityDetailsConfig? details,
}) {
  final l10n = context.l10n;
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
          ? context.l10n.privateUsdDepositWaiting
          : context.l10n.privateUsdDepositReceived(value);
    case ApiDepositState.sent:
      subtitle = context.l10n.privateUsdDepositShielding;
    case ApiDepositState.landed:
      subtitle = landedAt != null && now().difference(landedAt) < screening
          ? context.l10n.privateUsdDepositShielded(
              PrivateUsdCopy.about(context.l10n, screening),
            )
          : context.l10n.privateUsdActivityDepositShielded;
    case ApiDepositState.refused ||
        ApiDepositState.reverted ||
        ApiDepositState.replaced ||
        ApiDepositState.expired:
      return null;
  }
  final landed = record.state == ApiDepositState.landed;
  final stableId = 'private-usd:deposit:${record.id}';
  final unfold = _unfold(
    details,
    stableId,
    () => privateUsdDepositDetails(
      l10n,
      record,
      privacyModeEnabled: privacyModeEnabled,
    ),
  );
  return ActivityRowData(
    stableId: stableId,
    title: record.kind == ApiDepositKind.rescue
        ? context.l10n.privateUsdActivityDepositRescue
        : context.l10n.privateUsdActivityDeposit,
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
      l10n,
      privateUsdDepositActivityTime(record),
      dateOnly: dateOnlyTimestamp,
    ),
    details: unfold.details,
    onTap: unfold.onTap,
  );
}

/// When a deposit's row sorts: when it landed, else when it was signed.
DateTime privateUsdDepositActivityTime(ApiDepositRecord record) =>
    privateUsdDepositLandedAt(record) ??
    DateTime.fromMillisecondsSinceEpoch(record.createdAt * 1000);

/// A row's details and the tap that unfolds them; neither without [config].
({Widget? details, VoidCallback? onTap}) _unfold(
  PrivateUsdActivityDetailsConfig? config,
  String rowId,
  List<PrivateUsdActivityDetail> Function() lines,
) => config == null
    ? (details: null, onTap: null)
    : (
        details: config.detailsOf(rowId, lines()),
        onTap: () => config.onToggle(rowId),
      );

/// [activity] as feed entries, alike on Home, in Activity and on
/// `/private-usd`. A conversion under way opens its progress, a refunded
/// reverse one Refunds; every other row unfolds into its [details].
List<ActivityEntry> privateUsdFeedEntries({
  required BuildContext context,
  required PrivateUsdActivity activity,
  required bool privacyModeEnabled,
  required ValueChanged<PrivateUsdRoutePath> onOpenConversion,
  required PrivateUsdActivityDetailsConfig details,
  VoidCallback? onOpenRefunds,
  bool dateOnlyTimestamp = false,
}) {
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
            details: details,
          )
          case final row?)
        ActivityEntry(
          timestamp: privateUsdDepositActivityTime(record),
          row: row,
        ),
    for (final record in activity.sends)
      ActivityEntry(
        timestamp: privateUsdSendActivityTime(record),
        row: buildPrivateUsdSendActivityRow(
          context: context,
          record: record,
          privacyModeEnabled: privacyModeEnabled,
          dateOnlyTimestamp: dateOnlyTimestamp,
          details: details,
        ),
      ),
    for (final (receipt, copy) in _receiptCopies(activity.receipts))
      ActivityEntry(
        timestamp: privateUsdReceivedActivityTime(receipt),
        row: buildPrivateUsdReceivedActivityRow(
          context: context,
          receipt: receipt,
          copy: copy,
          privacyModeEnabled: privacyModeEnabled,
          dateOnlyTimestamp: dateOnlyTimestamp,
          details: details,
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
            details: details,
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
            details: details,
          )
          case final row?)
        ActivityEntry(timestamp: privateUsdActivityTime(record), row: row),
  ];
}

/// What a screen with a feed of Private USD rows keeps: the rows unfolded
/// into their details, for the active account (another account's start
/// folded), and their transactions opened outside the app on a tap.
mixin PrivateUsdActivityDetailsState<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  var _unfolded = (account: '', rows: const <String>{});

  Set<String> _unfoldedOf(String account) =>
      _unfolded.account == account ? _unfolded.rows : const {};

  /// How the feed being built unfolds its rows.
  PrivateUsdActivityDetailsConfig privateUsdActivityDetails() {
    final account =
        ref.watch(accountProvider.select((s) => s.value?.activeAccountUuid)) ??
        '';
    return PrivateUsdActivityDetailsConfig(
      open: _unfoldedOf(account),
      onToggle: (rowId) => setState(() {
        final rows = _unfoldedOf(account);
        _unfolded = (
          account: account,
          rows: rows.contains(rowId)
              ? ({...rows}..remove(rowId))
              : {...rows, rowId},
        );
      }),
      zcashExplorerLabel: explorerSettingsLabel(
        context.l10n,
        ref.watch(zcashExplorerProvider),
        networkName: ref.watch(
          rpcEndpointProvider.select((config) => config.networkName),
        ),
      ),
      onOpenTransaction: (hash, explorer) =>
          unawaited(_openTransaction(hash, explorer)),
    );
  }

  // The deployment is read only here, on a tap: a feed without Private USD
  // rows never makes its FRB call.
  Future<void> _openTransaction(
    String hash,
    PrivateUsdExplorer explorer,
  ) async {
    final deployment = ref.read(privateUsdCurrentDeploymentProvider);
    final uri = PrivateUsdExplorers(
      etherscanTxPrefix: deployment?.explorerTxPrefix,
      railscanTxPrefix: deployment?.railscanTxPrefix,
      zcashNetworkName: ref.read(rpcEndpointProvider).networkName,
      zcashExplorerTemplate: ref.read(zcashExplorerProvider),
    ).uri(hash, explorer);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Opening the browser is best effort.
    }
  }
}
