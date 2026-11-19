import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app_bootstrap.dart';
import '../../../../core/formatting/date_format.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../core/layout/mobile/neon_sync_backdrop.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_icon_hover_button.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/network_privacy_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../providers/zec_price_change_provider.dart';
import '../../../../rust/api/private_usd.dart' as rust;
import '../../../activity/activity_feed_sections.dart'
    show compareActivityEntries;
import '../../../activity/models/activity_row_data.dart';
import '../../../activity/widgets/activity_feed.dart' show ActivityFeedRowGroup;
import '../../models/private_usd_arrival.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_deposits.dart';
import '../../models/private_usd_messages.dart';
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_screening_status.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_activity_provider.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_conversion_provider.dart';
import '../../providers/private_usd_custom_rpc_provider.dart';
import '../../providers/private_usd_deposits_provider.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_receive_address_provider.dart';
import '../../providers/private_usd_spend_status_provider.dart';
import '../../providers/railgun_engine_provider.dart';
import '../../services/private_usd_balance_repository.dart';
import '../../widgets/desktop/desktop_private_usd_bridge_widgets.dart';
import '../../widgets/desktop/desktop_private_usd_rpc_dialog.dart';
import '../../widgets/desktop/desktop_private_usd_widgets.dart';
import '../../widgets/mobile/private_usd_activity_rows.dart';
import '../../widgets/mobile/private_usd_deposit_line.dart';
import '../../widgets/mobile/private_usd_home_strip.dart'
    show privateUsdZecEquivalentText;
import '../../widgets/mobile/private_usd_pending_payment_line.dart';
import '../../widgets/mobile/private_usd_sync_line.dart';

/// How often the open page asks for a deposit pass, as the phone's screen
/// does: a pass reads every deposit address on chain.
const _depositRefresh = Duration(seconds: 60);

/// `/private-usd` on desktop, opened from Home's balance and the chart's
/// holdings: the balance and its screening buckets, Send, Withdraw and
/// Receive with the spending note, the way into a bridge (or the bridge under
/// way), the deposits and the activity with Refunds beside it, with Railgun's
/// sync drawn as Home's sync line. The phone's screen in a desktop layout.
class DesktopPrivateUsdScreen extends ConsumerStatefulWidget {
  const DesktopPrivateUsdScreen({super.key});

  @override
  ConsumerState<DesktopPrivateUsdScreen> createState() =>
      _DesktopPrivateUsdScreenState();
}

class _DesktopPrivateUsdScreenState
    extends ConsumerState<DesktopPrivateUsdScreen>
    with PrivateUsdActivityDetailsState {
  Timer? _depositTimer;

  @override
  void initState() {
    super.initState();
    // On open: a balance older than 30 s refreshes and the deposits are read,
    // as on the phone. The user waits on that refresh, so it shows its
    // progress.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(privateUsdDepositActionsProvider).refresh(checkVaults: true);
      final uuid = ref.read(accountProvider).value?.activeAccountUuid;
      if (uuid == null) return;
      ref
          .read(privateUsdBalanceProvider(uuid).notifier)
          .refresh(
            maxAge: PrivateUsdBalanceTiming.openedAge,
            showProgress: true,
          );
    });
    _depositTimer = Timer.periodic(_depositRefresh, (_) {
      if (mounted) ref.read(privateUsdDepositActionsProvider).refresh();
    });
  }

  @override
  void dispose() {
    _depositTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    if (uuid == null) return const SizedBox.shrink();
    ref.watch(
      privateUsdBalanceKeepFreshProvider((accountUuid: uuid, ifUsed: false)),
    );
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final address = ref.watch(privateUsdReceiveAddressProvider(uuid));
    final deposits = ref.watch(privateUsdDepositsAvailableProvider);
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    final underWay = ref.watch(privateUsdUnderWayProvider(uuid));
    void open(PrivateUsdRoutePath path) => context.push(path.location);
    void openRefunds() => context.push('/private-usd/refunds');
    final feed = ref.watch(privateUsdActivityProvider(uuid));
    final screening = Duration(seconds: deployment?.screeningSeconds ?? 0);
    final activity = [
      for (final entry in privateUsdFeedEntries(
        context: context,
        activity: feed,
        privacyModeEnabled: privacyModeEnabled,
        onOpenConversion: open,
        details: privateUsdActivityDetails(),
        onOpenRefunds: openRefunds,
      )..sort(compareActivityEntries))
        entry.row,
    ];
    final depositPass = ref.watch(privateUsdDepositPassProvider(uuid));
    // A refunded bridge, or a deposit Railgun's screening sent back: Refunds
    // shows beside the activity, as on the phone.
    final hasRefunds =
        feed.reverseRecords.any(
          (record) => record.phase == rust.ApiReversePhase.refunded,
        ) ||
        ref.watch(privateUsdDepositRescuesProvider(uuid)).isNotEmpty;
    final bridge = ref.watch(privateUsdBridgeAvailableProvider);
    final banner = ref.watch(privateUsdConversionBannerProvider(uuid));
    final balance = ref.watch(privateUsdBalanceProvider(uuid));
    final screeningActivity = ref.watch(
      railgunEngineStateProvider.select(
        (engine) => engine.accountUuid == uuid ? engine.screening : null,
      ),
    );
    final sends = ref.watch(privateUsdEngineEnabledProvider);
    final spending = ref.watch(privateUsdSpendStatusProvider(uuid));
    final hasDollars =
        balance.balances?.assets.any((a) => a.available > BigInt.zero) ?? false;
    final network = ref.watch(appBootstrapProvider).network;
    final customRpc = ref.watch(privateUsdCustomRpcProvider(network)).value;
    final rpcFailing =
        customRpc != null &&
        (balance.refreshFailed ||
            ref.watch(privateUsdEthereumUnreachableProvider(uuid)));
    final balances = balance.balances;
    final depositLines = depositPass == null
        ? const <PrivateUsdDepositLine>[]
        : privateUsdDepositLines(
            depositPass,
            now: DateTime.now(),
            screening: screening,
          );
    final onReceive = deposits || address.value != null
        ? () => context.push('/private-usd/receive')
        : null;
    final canSend = spending.canSend && hasDollars;
    // The bridge under way opens instead of a new one (one at a time).
    final canConvert = underWay != null || spending.canStartConversion;
    final spendNote = privateUsdSpendMessage(context.l10n, spending);
    final pendingPayment = ref.watch(privateUsdPendingPaymentProvider(uuid));
    final syncLine = privateUsdSyncLine(
      context.l10n,
      balance,
      networkPrivacy: ref.watch(networkPrivacyProvider),
      txidCatchUp: screeningActivity?.txids,
    );
    final arrivingSince = privateUsdArrivingSince(
      arriving: balances?.arriving ?? BigInt.zero,
      shielded: balance.shieldingSince,
      forward: feed.records,
      reverse: feed.reverseRecords,
      deposits: feed.depositRecords,
    );

    return DesktopPrivateUsdPage(
      title: context.l10n.privateUsdTitle,
      contentKey: const ValueKey('desktop_private_usd_content'),
      syncLine: syncLine,
      onInfo: () => unawaited(
        showDesktopPrivateUsdInfo(
          context,
          title: context.l10n.privateUsdInfoTitle,
          steps: [
            if (bridge) context.l10n.privateUsdInfoConvert,
            context.l10n.privateUsdInfoReceive,
            context.l10n.privateUsdInfoSend,
            context.l10n.privateUsdInfoWithdraw,
            if (bridge) context.l10n.privateUsdInfoRefunds,
          ],
          notes: [
            context.l10n.privateUsdInfoScreening(
              PrivateUsdCopy.about(context.l10n, screening),
            ),
            context.l10n.privateUsdInfoPrivate,
            context.l10n.privateUsdInfoKeepOpen,
          ],
        ),
      ),
      children: [
        NeonSyncOcclude(
          child: Text(
            context.l10n.privateUsdSubtitle,
            textAlign: TextAlign.center,
            style: AppTypography.bodyMedium.copyWith(
              color: context.colors.text.secondary,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        NeonSyncOcclude(
          child: _TotalPanel(
            state: balance,
            zecUsdPrice: ref.watch(zecHomeUsdUnitPriceProvider),
            privacyModeEnabled: privacyModeEnabled,
            onRefresh: () => ref
                .read(privateUsdBalanceProvider(uuid).notifier)
                .refresh(showProgress: true),
            onUseDefaultRpc: rpcFailing
                ? () => unawaited(_useDefaultRpc(network, uuid))
                : null,
            onChangeRpc: customRpc == null && balance.rpcFailed
                ? () => unawaited(_changeRpc(uuid))
                : null,
            txidCatchUp: screeningActivity?.txids,
          ),
        ),
        if (sends || onReceive != null) ...[
          const SizedBox(height: AppSpacing.s),
          NeonSyncOcclude(
            child: Row(
              children: [
                if (sends) ...[
                  Expanded(
                    child: AppButton(
                      key: const ValueKey('desktop_private_usd_send'),
                      // With the bridge, Bridge is the page's main action,
                      // as on the phone.
                      variant: bridge
                          ? AppButtonVariant.secondary
                          : AppButtonVariant.primary,
                      expand: true,
                      leading: const AppIcon(AppIcons.plane),
                      onPressed: canSend
                          ? () => context.push('/private-usd/send')
                          : null,
                      child: Text(context.l10n.privateUsdActionSend),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: AppButton(
                      key: const ValueKey('desktop_private_usd_withdraw'),
                      variant: AppButtonVariant.secondary,
                      expand: true,
                      leading: const AppIcon(AppIcons.arrowTopRight),
                      onPressed: canSend
                          ? () => context.push('/private-usd/withdraw')
                          : null,
                      child: Text(context.l10n.privateUsdActionWithdraw),
                    ),
                  ),
                ],
                // Incoming, so the spend guard never holds it.
                if (onReceive != null) ...[
                  if (sends) const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: AppButton(
                      key: const ValueKey('desktop_private_usd_receive'),
                      variant: AppButtonVariant.secondary,
                      expand: true,
                      leading: const AppIcon(AppIcons.arrowDownCircle),
                      onPressed: onReceive,
                      child: Text(context.l10n.privateUsdActionReceive),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (bridge) ...[
          const SizedBox(height: AppSpacing.xs),
          NeonSyncOcclude(
            child: AppButton(
              key: const ValueKey('desktop_private_usd_convert'),
              expand: true,
              leading: const AppIcon(AppIcons.swapArrows),
              onPressed: canConvert
                  ? () => underWay == null
                        ? context.push('/private-usd/convert')
                        : open(underWay.path)
                  : null,
              child: Text(context.l10n.privateUsdActionConvert),
            ),
          ),
        ],
        if (pendingPayment case final payment?) ...[
          const SizedBox(height: AppSpacing.xs),
          NeonSyncOcclude(child: PrivateUsdPendingPaymentLine(payment: payment)),
        ],
        if (spendNote case final note?) ...[
          const SizedBox(height: AppSpacing.xs),
          NeonSyncOcclude(
            child: Text(
              note,
              key: const ValueKey('desktop_private_usd_spend_note'),
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall.copyWith(
                color: context.colors.text.secondary,
              ),
            ),
          ),
        ],
        if (depositLines.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s),
          NeonSyncOcclude(
            child: _DepositsPanel(
              lines: depositLines,
              minimum: BigInt.tryParse(depositPass?.terms?.minValue ?? ''),
              screening: screening,
              privacyModeEnabled: privacyModeEnabled,
              onOpen: onReceive,
            ),
          ),
        ],
        if (banner != null) ...[
          const SizedBox(height: AppSpacing.s),
          NeonSyncOcclude(
            child: DesktopPrivateUsdConversionBanner(
              key: const ValueKey('desktop_private_usd_banner'),
              banner: banner,
              onOpen: open,
            ),
          ),
        ],
        if (balances != null &&
            balances.total == BigInt.zero &&
            banner == null) ...[
          const SizedBox(height: AppSpacing.s),
          NeonSyncOcclude(child: _EmptyPanel(bridgeAvailable: bridge)),
        ] else if (balances != null) ...[
          const SizedBox(height: AppSpacing.s),
          NeonSyncOcclude(
            child: _BucketsPanel(
              balances: balances,
              privacyModeEnabled: privacyModeEnabled,
              screening: screening,
              processingStalled: balance.screeningFailed,
              processingStatus: privateUsdScreeningStatus(
                context.l10n,
                activity: screeningActivity,
                balances: balances,
              ),
              arrivingSince: arrivingSince,
            ),
          ),
          if (balances.held.length > 1) ...[
            const SizedBox(height: AppSpacing.s),
            NeonSyncOcclude(
              child: _AssetsPanel(
                balances: balances,
                privacyModeEnabled: privacyModeEnabled,
              ),
            ),
          ],
        ],
        const SizedBox(height: AppSpacing.md),
        _ActivitySection(
          rows: activity,
          onRefunds: hasRefunds ? openRefunds : null,
        ),
      ],
    );
  }

  /// Clears the user's own Ethereum RPC (which closes the Railgun page) and
  /// syncs again on the default.
  Future<void> _useDefaultRpc(String network, String uuid) async {
    try {
      await ref.read(privateUsdCustomRpcProvider(network).notifier).clear();
    } catch (_) {
      if (mounted) {
        showAppToast(context, context.l10n.privateUsdSettingSaveFailed);
      }
      return;
    }
    if (!mounted) return;
    showAppToast(context, context.l10n.privateUsdRpcCleared);
    ref.read(privateUsdBalanceProvider(uuid).notifier)
      ..clearRpcFailed()
      ..refresh(showProgress: true);
  }

  /// Opens Settings' Ethereum RPC dialog; a URL saved there (which closes the
  /// Railgun page) syncs again on it.
  Future<void> _changeRpc(String uuid) async {
    final done = await showDesktopPrivateUsdRpcDialog(context);
    if (done == null || !mounted) return;
    showAppToast(context, done);
    ref.read(privateUsdBalanceProvider(uuid).notifier)
      ..clearRpcFailed()
      ..refresh(showProgress: true);
  }
}

String _masked(String usd, bool privacyModeEnabled) => hideAmountIfPrivacyMode(
  usd,
  privacyModeEnabled: privacyModeEnabled,
  denomination: '',
);

/// The balance: what can be spent now, its ZEC worth, how old it is or what a
/// first sync takes, and the refresh. The sync's progress is the sync line's,
/// so the arrow holds still and always takes a click: during an automatic
/// refresh, a click shows that refresh's progress rather than starting
/// another.
class _TotalPanel extends StatelessWidget {
  const _TotalPanel({
    required this.state,
    required this.zecUsdPrice,
    required this.privacyModeEnabled,
    required this.onRefresh,
    required this.onUseDefaultRpc,
    required this.onChangeRpc,
    required this.txidCatchUp,
  });

  final PrivateUsdBalanceState state;
  final double? zecUsdPrice;
  final bool privacyModeEnabled;
  final VoidCallback onRefresh;
  final VoidCallback? onUseDefaultRpc;
  final VoidCallback? onChangeRpc;
  final double? txidCatchUp;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final balances = state.balances;
    final headline = balances == null
        ? PrivateUsdCopy.unknown
        : _masked(formatPrivateUsd(balances.spendable), privacyModeEnabled);
    final zec = balances == null || privacyModeEnabled
        ? null
        : privateUsdZecEquivalentText(
            balances.spendable,
            zecUsdPrice: zecUsdPrice,
          );
    final updatedAt = state.updatedAt;
    final syncing = balances != null && state.syncing;
    final txidCatchUp = this.txidCatchUp;
    final status = balances == null
        ? (state.isLoading ? context.l10n.privateUsdFirstLoad : null)
        : syncing
        ? PrivateUsdCopy.syncingRest(
            context.l10n,
            txidCatchUp == null
                ? null
                : privateUsdScreeningPercent(txidCatchUp),
          )
        : updatedAt == null
        ? null
        : context.l10n.privateUsdUpdated(
            formatDayMonthTime(updatedAt, context.l10n.localeName),
          );
    final unproved = syncing && balances.unproved > BigInt.zero
        ? _masked(formatPrivateUsd(balances.unproved), privacyModeEnabled)
        : null;
    final error = !state.refreshFailed
        ? null
        : balances == null
        ? context.l10n.privateUsdLoadFailed
        : context.l10n.privateUsdRefreshFailed;
    final onUseDefaultRpc = this.onUseDefaultRpc;
    final onChangeRpc = this.onChangeRpc;
    final small = AppTypography.bodySmall.copyWith(
      color: colors.text.secondary,
    );
    return DesktopPrivateUsdPanel(
      key: const ValueKey('desktop_private_usd_total'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  headline,
                  key: const ValueKey('desktop_private_usd_headline'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.displayLarge.copyWith(
                    color: balances == null
                        ? colors.text.disabled
                        : colors.text.accent,
                  ),
                ),
              ),
              AppIconHoverButton(
                key: const ValueKey('desktop_private_usd_refresh'),
                icon: AppIcons.renew,
                semanticLabel: context.l10n.privateUsdRefresh,
                tooltip: context.l10n.privateUsdRefresh,
                onTap: onRefresh,
              ),
            ],
          ),
          if (zec != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              zec,
              key: const ValueKey('desktop_private_usd_zec_equivalent'),
              style: AppTypography.bodyMedium.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
          // Screen readers hear these from the sync line, with the progress.
          if (status != null) ...[
            const SizedBox(height: AppSpacing.s),
            ExcludeSemantics(
              child: Text(
                status,
                key: const ValueKey('desktop_private_usd_status'),
                style: small,
              ),
            ),
          ],
          if (unproved != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              context.l10n.privateUsdSyncingRestWaits(unproved),
              key: const ValueKey('desktop_private_usd_syncing_waits'),
              style: small,
            ),
          ],
          if (onUseDefaultRpc != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              context.l10n.privateUsdRpcNotAnswering,
              key: const ValueKey('desktop_private_usd_rpc_error'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.destructive,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            AppButton(
              key: const ValueKey('desktop_private_usd_rpc_default'),
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              onPressed: onUseDefaultRpc,
              child: Text(context.l10n.privateUsdRpcUseDefault),
            ),
          ] else if (onChangeRpc != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              context.l10n.privateUsdRpcDefaultNotAnswering,
              key: const ValueKey('desktop_private_usd_rpc_error'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.destructive,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            AppButton(
              key: const ValueKey('desktop_private_usd_rpc_change'),
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              onPressed: onChangeRpc,
              child: Text(context.l10n.privateUsdRpcChange),
            ),
          ] else if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            ExcludeSemantics(
              child: Text(
                error,
                key: const ValueKey('desktop_private_usd_error'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.destructive,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What can be spent, what is processing (with its live line), what is
/// arriving (with its estimate) and what was refused.
class _BucketsPanel extends StatelessWidget {
  const _BucketsPanel({
    required this.balances,
    required this.privacyModeEnabled,
    required this.screening,
    required this.processingStalled,
    required this.processingStatus,
    required this.arrivingSince,
  });

  final PrivateUsdBalances balances;
  final bool privacyModeEnabled;
  final Duration screening;
  final bool processingStalled;
  final String? processingStatus;
  final DateTime? arrivingSince;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      _BucketRow(
        key: const ValueKey('desktop_private_usd_row_available'),
        label: context.l10n.privateUsdRowAvailable,
        amount: _masked(
          formatPrivateUsd(balances.available),
          privacyModeEnabled,
        ),
      ),
      if (balances.processing > BigInt.zero)
        _BucketRow(
          key: const ValueKey('desktop_private_usd_row_processing'),
          label: processingStalled
              ? context.l10n.privateUsdRowProcessingStalled
              : context.l10n.privateUsdRowProcessing,
          amount: _masked(
            formatPrivateUsd(balances.processing),
            privacyModeEnabled,
          ),
          status: processingStatus,
          info: processingStalled
              ? context.l10n.privateUsdRowProcessingStalledInfo
              : context.l10n.privateUsdRowProcessingInfo,
        ),
      if (balances.arriving > BigInt.zero)
        _ArrivingRow(
          key: const ValueKey('desktop_private_usd_row_arriving'),
          since: arrivingSince,
          screening: screening,
          amount: _masked(
            formatPrivateUsd(balances.arriving),
            privacyModeEnabled,
          ),
        ),
      if (balances.blocked > BigInt.zero)
        _BucketRow(
          key: const ValueKey('desktop_private_usd_row_blocked'),
          label: context.l10n.privateUsdRowBlocked,
          amount: _masked(
            formatPrivateUsd(balances.blocked),
            privacyModeEnabled,
          ),
          info: context.l10n.privateUsdRowBlockedInfo,
          danger: true,
        ),
    ];
    return DesktopPrivateUsdPanel(
      key: const ValueKey('desktop_private_usd_buckets'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.s),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _BucketRow extends StatelessWidget {
  const _BucketRow({
    required this.label,
    required this.amount,
    this.status,
    this.info,
    this.danger = false,
    super.key,
  });

  final String label;
  final String amount;

  /// What the work behind this amount is doing now, under the label.
  final String? status;
  final String? info;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = danger ? colors.text.destructive : colors.text.accent;
    final status = this.status;
    final info = this.info;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: AppTypography.labelLarge.copyWith(color: color),
              ),
            ),
            Text(
              amount,
              style: AppTypography.labelLarge.copyWith(color: color),
            ),
          ],
        ),
        if (status != null) ...[
          const SizedBox(height: AppSpacing.xxs),
          Text(
            status,
            key: const ValueKey('desktop_private_usd_row_status'),
            style: AppTypography.bodyExtraSmall.copyWith(
              color: colors.text.brandCrimson,
            ),
          ),
        ],
        if (info != null) ...[
          const SizedBox(height: AppSpacing.xxs),
          Text(
            info,
            style: AppTypography.bodySmall.copyWith(
              color: danger ? colors.text.destructive : colors.text.secondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// The Arriving row: while its funds are screened, the share of the
/// [screening] time gone by since they landed ([since]), then that it takes
/// longer than usual; no estimate when no landing time is known. The
/// estimate moves every 10 s while the row shows.
class _ArrivingRow extends StatefulWidget {
  const _ArrivingRow({
    required this.since,
    required this.screening,
    required this.amount,
    super.key,
  });

  final DateTime? since;
  final Duration screening;
  final String amount;

  @override
  State<_ArrivingRow> createState() => _ArrivingRowState();
}

class _ArrivingRowState extends State<_ArrivingRow> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTick();
  }

  @override
  void didUpdateWidget(_ArrivingRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTick();
  }

  // Only a known landing has an estimate to move.
  void _syncTick() {
    if (widget.since != null && widget.screening > Duration.zero) {
      _tick ??= Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _BucketRow(
    label: privateUsdArrivingLabel(
      context.l10n,
      since: widget.since,
      screening: widget.screening,
      now: DateTime.now(),
    ),
    amount: widget.amount,
    info: context.l10n.privateUsdRowArrivingInfo(
      PrivateUsdCopy.about(context.l10n, widget.screening),
    ),
  );
}

class _AssetsPanel extends StatelessWidget {
  const _AssetsPanel({required this.balances, required this.privacyModeEnabled});

  final PrivateUsdBalances balances;
  final bool privacyModeEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DesktopPrivateUsdPanel(
      key: const ValueKey('desktop_private_usd_assets'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopPrivateUsdCaption(context.l10n.privateUsdAssetsTitle),
          for (final asset in balances.held) ...[
            const SizedBox(height: AppSpacing.s),
            Row(
              children: [
                Expanded(
                  child: Text(
                    privateUsdTokenName(context.l10n, asset.token.symbol),
                    style: AppTypography.bodyMedium.copyWith(
                      color: colors.text.primary,
                    ),
                  ),
                ),
                Text(
                  _masked(
                    formatPrivateUsd(PrivateUsdBalances([asset]).total),
                    privacyModeEnabled,
                  ),
                  style: AppTypography.bodyMedium.copyWith(
                    color: colors.text.primary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.bridgeAvailable});

  /// Off, Receive is the way in.
  final bool bridgeAvailable;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DesktopPrivateUsdPanel(
      key: const ValueKey('desktop_private_usd_empty'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.privateUsdEmptyTitle,
            style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            bridgeAvailable
                ? context.l10n.privateUsdEmptyBody
                : context.l10n.privateUsdEmptyBodyReceive,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The deposits' state now: what each deposit address received, what is
/// being shielded and what is being screened. Opens Receive.
class _DepositsPanel extends StatelessWidget {
  const _DepositsPanel({
    required this.lines,
    required this.minimum,
    required this.screening,
    required this.privacyModeEnabled,
    required this.onOpen,
  });

  final List<PrivateUsdDepositLine> lines;
  final BigInt? minimum;
  final Duration screening;
  final bool privacyModeEnabled;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final panel = DesktopPrivateUsdPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopPrivateUsdCaption(context.l10n.privateUsdDepositsTitle),
          for (final line in lines) ...[
            const SizedBox(height: AppSpacing.xs),
            PrivateUsdDepositLineText(
              line: line,
              minimum: minimum,
              screening: screening,
              privacyModeEnabled: privacyModeEnabled,
            ),
          ],
        ],
      ),
    );
    final onOpen = this.onOpen;
    if (onOpen == null) {
      return KeyedSubtree(
        key: const ValueKey('desktop_private_usd_deposits'),
        child: panel,
      );
    }
    return MouseRegion(
      key: const ValueKey('desktop_private_usd_deposits'),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpen,
        child: panel,
      ),
    );
  }
}

/// Bridges, deposits, sends, withdrawals and what arrived, newest first, with
/// Refunds beside the heading once a bridge was refunded or a deposit sent
/// back.
class _ActivitySection extends StatelessWidget {
  const _ActivitySection({required this.rows, this.onRefunds});

  final List<ActivityRowData> rows;
  final VoidCallback? onRefunds;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Only what the heading draws is backed, so a synced line crossing
        // its empty stretch stays whole.
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: NeonSyncOcclude(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xxs,
                    ),
                    child: DesktopPrivateUsdCaption(
                      context.l10n.privateUsdActivityTitle,
                    ),
                  ),
                ),
              ),
            ),
            if (onRefunds case final onRefunds?)
              NeonSyncOcclude(
                child: AppButton(
                  key: const ValueKey('desktop_private_usd_refunds'),
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.small,
                  onPressed: onRefunds,
                  child: Text(context.l10n.privateUsdRefundsTitle),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s),
        if (rows.isEmpty)
          NeonSyncOcclude(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
              child: Text(
                context.l10n.privateUsdActivityEmpty,
                key: const ValueKey('desktop_private_usd_activity_empty'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            ),
          )
        else
          NeonSyncOcclude(
            child: DesktopPrivateUsdPanel(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
                vertical: AppSpacing.xs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows.length; i++)
                    KeyedSubtree(
                      key: ValueKey('desktop_private_usd_activity_row_$i'),
                      child: ActivityFeedRowGroup(row: rows[i]),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
