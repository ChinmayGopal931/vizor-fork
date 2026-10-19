import 'dart:async';

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app_bootstrap.dart';
import '../../../../core/feedback/app_haptics.dart';
import '../../../../core/formatting/date_format.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/layout/mobile/neon_sync_backdrop.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/network_privacy_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../providers/zec_price_change_provider.dart';
import '../../../../rust/api/private_usd.dart' show ApiReversePhase;
import '../../../activity/activity_feed_sections.dart'
    show compareActivityEntries;
import '../../../activity/models/activity_row_data.dart';
import '../../../activity/widgets/activity_feed.dart' show ActivityFeedRowGroup;
import '../../models/private_usd_arrival.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_deposits.dart';
import '../../models/private_usd_pending_payment.dart';
import '../../models/private_usd_record_key.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_activity_provider.dart';
import '../../providers/private_usd_conversion_provider.dart';
import '../../providers/private_usd_custom_rpc_provider.dart';
import '../../providers/private_usd_deposits_provider.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_receive_address_provider.dart';
import '../../providers/private_usd_spend_status_provider.dart';
import '../../services/private_usd_balance_repository.dart';
import '../../widgets/mobile/private_usd_home_strip.dart';
import '../../widgets/mobile/private_usd_activity_rows.dart';
import '../../widgets/mobile/private_usd_banner.dart';
import '../../widgets/mobile/private_usd_deposit_sheet.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import '../../widgets/mobile/private_usd_pending_payment_line.dart';
import '../../widgets/mobile/private_usd_sync_line.dart';

/// `/private-usd` (plan reference §9.4 S2): the balance with its screening
/// buckets, Send and Withdraw with the spending note, the conversion under
/// way, the receive address, the activity, and "Convert". Railgun's sync is
/// Home's sync line (iOS progress VI-19).
class MobilePrivateUsdScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdScreen({super.key});

  @override
  ConsumerState<MobilePrivateUsdScreen> createState() =>
      _MobilePrivateUsdScreenState();
}

/// How often the screen asks for a deposit pass while it is open (plan M9's
/// default cadence).
const _depositRefresh = Duration(seconds: 60);

class _MobilePrivateUsdScreenState
    extends ConsumerState<MobilePrivateUsdScreen> {
  Timer? _depositTimer;

  @override
  void initState() {
    super.initState();
    // On open: a balance older than 30 s refreshes, and the deposits are
    // read (with the vaults, for "Refunds").
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(privateUsdDepositActionsProvider).refresh(checkVaults: true);
      final uuid = ref.read(accountProvider).value?.activeAccountUuid;
      if (uuid == null) return;
      ref
          .read(privateUsdBalanceProvider(uuid).notifier)
          .refresh(maxAge: PrivateUsdBalanceTiming.arrivingPoll);
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
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    final underWay = ref.watch(privateUsdUnderWayProvider(uuid));
    void open(PrivateUsdRoutePath path) => context.push(path.location);
    void openRefunds() => context.push('/private-usd/refunds');
    final records = ref.watch(privateUsdActivityRecordsProvider(uuid));
    final reverseRecords = ref.watch(
      privateUsdReverseActivityRecordsProvider(uuid),
    );
    final depositRecords = ref.watch(privateUsdDepositRecordsProvider(uuid));
    final screening = Duration(seconds: deployment?.screeningSeconds ?? 0);
    final activity = [
      for (final entry in privateUsdActivityEntries(
        context: context,
        records: records,
        reverseRecords: reverseRecords,
        depositRecords: depositRecords,
        screening: screening,
        zcashConfirmations: deployment?.zcashConfirmations ?? 2,
        privacyModeEnabled: privacyModeEnabled,
        onOpenConversion: open,
        onOpenPayout: (payoutTx) => openPrivateUsdPayout(ref, payoutTx),
        onOpenRefunds: openRefunds,
        sendRecords: ref.watch(privateUsdSendRecordsProvider(uuid)),
      )..sort(compareActivityEntries))
        entry.row,
    ];
    // Deposits (M9): their state now, and a vault that can be rescued.
    final depositPass = ref.watch(privateUsdDepositPassProvider(uuid));
    final hasRefunds =
        reverseRecords.any(
          (record) => record.phase == ApiReversePhase.refunded,
        ) ||
        ref.watch(privateUsdDepositRescuesProvider(uuid)).isNotEmpty;
    final balance = ref.watch(privateUsdBalanceProvider(uuid));
    final sends = ref.watch(privateUsdEngineEnabledProvider);
    final spending = ref.watch(privateUsdSpendStatusProvider(uuid));
    final hasDollars =
        balance.balances?.assets.any((a) => a.available > BigInt.zero) ?? false;
    // A sync or a conversion step failing while the user's own Ethereum RPC
    // (Settings) is set is put on it, with the way back to the default.
    final network = ref.watch(appBootstrapProvider).network;
    final customRpc = ref.watch(privateUsdCustomRpcProvider(network)).value;
    final rpcFailing =
        customRpc != null &&
        (balance.refreshFailed ||
            ref.watch(privateUsdEthereumUnreachableProvider(uuid)));
    return MobilePrivateUsdView(
      rpcFailing: rpcFailing,
      onUseDefaultRpc: rpcFailing
          ? () => unawaited(_useDefaultRpc(network, uuid))
          : null,
      state: balance,
      networkPrivacy: ref.watch(networkPrivacyProvider),
      zecUsdPrice: ref.watch(zecHomeUsdUnitPriceProvider),
      privacyModeEnabled: privacyModeEnabled,
      receiveAddress: address.value,
      screening: screening,
      arrivingSince: privateUsdArrivingSince(
        arriving: balance.balances?.arriving ?? BigInt.zero,
        forward: records,
        reverse: reverseRecords,
        deposits: depositRecords,
      ),
      depositLines: depositPass == null
          ? const []
          : privateUsdDepositLines(
              depositPass,
              now: DateTime.now(),
              screening: screening,
            ),
      depositMinimum: BigInt.tryParse(depositPass?.terms?.minValue ?? ''),
      onReceive: ref.watch(privateUsdDepositsAvailableProvider)
          ? () => showPrivateUsdDepositSheet(context, accountUuid: uuid)
          : null,
      tokenNames: {
        for (final token in deployment?.usdTokens ?? const [])
          token.address.toLowerCase(): PrivateUsdCopy.tokenName(token.symbol),
      },
      banner: ref.watch(privateUsdConversionBannerProvider(uuid)),
      activityRows: activity,
      onRefunds: hasRefunds ? openRefunds : null,
      onBack: () => context.pop(),
      onRefresh: () =>
          ref.read(privateUsdBalanceProvider(uuid).notifier).refresh(),
      onOpenConversion: open,
      // The conversion under way opens instead of a new one (one at a time).
      onConvert: () => underWay == null
          ? context.push('/private-usd/convert')
          : open(underWay.path),
      canConvert: underWay != null || spending.canStartConversion,
      onSend: sends ? () => context.push('/private-usd/send') : null,
      onWithdraw: sends ? () => context.push('/private-usd/withdraw') : null,
      canSend: spending.canSend && hasDollars,
      spendNote: privateUsdSpendMessage(spending),
      pendingPayment: ref.watch(privateUsdPendingPaymentProvider(uuid)),
    );
  }

  /// Clears the user's own Ethereum RPC (which closes the Railgun page) and
  /// syncs again on the default.
  Future<void> _useDefaultRpc(String network, String uuid) async {
    try {
      await ref.read(privateUsdCustomRpcProvider(network).notifier).clear();
    } catch (_) {
      if (mounted) showAppToast(context, PrivateUsdCopy.rpcErrorSave);
      return;
    }
    if (!mounted) return;
    showAppToast(context, PrivateUsdCopy.rpcCleared);
    ref.read(privateUsdBalanceProvider(uuid).notifier).refresh();
  }
}

/// The screen's content for a given balance, address and price. Widgetbook,
/// capture scenarios and tests build it directly.
class MobilePrivateUsdView extends StatelessWidget {
  const MobilePrivateUsdView({
    required this.state,
    required this.zecUsdPrice,
    required this.privacyModeEnabled,
    required this.receiveAddress,
    required this.screening,
    required this.onBack,
    required this.onRefresh,
    this.arrivingSince,
    this.now = DateTime.now,
    this.networkPrivacy,
    this.tokenNames = const {},
    this.banner,
    this.activityRows = const [],
    this.onOpenConversion,
    this.onConvert,
    this.canConvert = true,
    this.onSend,
    this.onWithdraw,
    this.canSend = false,
    this.spendNote,
    this.pendingPayment,
    this.onRefunds,
    this.rpcFailing = false,
    this.onUseDefaultRpc,
    this.onReceive,
    this.depositLines = const [],
    this.depositMinimum,
    super.key,
  });

  final PrivateUsdBalanceState state;

  /// Whether the page waits for Tor or Tor failed, for the sync line.
  final NetworkPrivacyState? networkPrivacy;
  final double? zecUsdPrice;
  final bool privacyModeEnabled;

  /// Null until Rust has derived it.
  final String? receiveAddress;

  /// How long Railgun screens new funds, for the explanations and the
  /// Arriving row's estimate.
  final Duration screening;

  /// When the funds arriving now landed (`privateUsdArrivingSince`), for the
  /// Arriving row's estimate; null when unknown, and the row reads as
  /// before.
  final DateTime? arrivingSince;

  /// The clock that estimate reads.
  final DateTime Function() now;

  /// Token names by lowercase address, for the Assets list.
  final Map<String, String> tokenNames;
  final VoidCallback onBack;
  final VoidCallback onRefresh;

  /// The conversion under way, if any.
  final PrivateUsdBannerState? banner;
  final List<ActivityRowData> activityRows;
  final ValueChanged<PrivateUsdRoutePath>? onOpenConversion;

  /// "Convert": the conversion under way, else a new one. Hidden when null.
  final VoidCallback? onConvert;

  /// Whether "Convert" is enabled (the spend guard, reference §9.4 S2).
  final bool canConvert;

  /// "Send" and "Withdraw" (M7); hidden when null.
  final VoidCallback? onSend;
  final VoidCallback? onWithdraw;

  /// Whether they are enabled: the spend guard allows it and some dollars
  /// are available.
  final bool canSend;

  /// Why sending or converting cannot start now (the spending note).
  final String? spendNote;

  /// Where an outgoing payment in flight stands, above the spending note.
  final PrivateUsdPendingPayment? pendingPayment;

  /// "Refunds" beside the Activity heading, once a conversion was refunded.
  final VoidCallback? onRefunds;

  /// A sync or a conversion step fails while the user's own Ethereum RPC is
  /// set: the card says so in place of its error, with [onUseDefaultRpc].
  final bool rpcFailing;
  final VoidCallback? onUseDefaultRpc;

  /// "Receive" (M9): the Receive USDC sheet for public USDC. Hidden when
  /// null (no deposits on this network, or Private USD unavailable).
  final VoidCallback? onReceive;

  /// The deposits' state now (M9), and the relayer's minimum.
  final List<PrivateUsdDepositLine> depositLines;
  final BigInt? depositMinimum;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final balances = state.balances;
    final banner = this.banner;
    final onConvert = this.onConvert;
    final syncLine = privateUsdSyncLine(state, networkPrivacy: networkPrivacy);
    return Scaffold(
      backgroundColor: colors.background.window,
      body: AppToastHost(
        // Laid out as Home: the floor (and the line once synced) behind, the
        // blocks backed solid so that line shows only in the gaps, and the
        // climbing line with its readout in front, ignoring touches.
        child: NeonSyncScrolled(
          builder: (context, scrolled) => Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: NeonSyncLineLayer(
                  key: const ValueKey('mobile_private_usd_sync_back'),
                  line: syncLine,
                  scrolled: scrolled,
                ),
              ),
              SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MobileTopNav.back(
                      title: PrivateUsdCopy.title,
                      onBack: onBack,
                      trailing: _InfoButton(
                        onTap: () => showPrivateUsdInfoSheet(
                          context,
                          screening: screening,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        key: const ValueKey('mobile_private_usd_list'),
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.sm,
                          AppSpacing.xs,
                          AppSpacing.sm,
                          AppSpacing.lg,
                        ),
                        children: [
                          NeonSyncOcclude(
                            child: Text(
                              PrivateUsdCopy.subtitle,
                              style: AppTypography.bodyMedium.copyWith(
                                color: colors.text.secondary,
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          NeonSyncOcclude(
                            child: _TotalCard(
                              state: state,
                              zecUsdPrice: zecUsdPrice,
                              privacyModeEnabled: privacyModeEnabled,
                              onRefresh: onRefresh,
                              rpcFailing: rpcFailing,
                              onUseDefaultRpc: onUseDefaultRpc,
                            ),
                          ),
                          if ((onSend != null && onWithdraw != null) ||
                              onReceive != null) ...[
                            const SizedBox(height: AppSpacing.s),
                            NeonSyncOcclude(
                              child: Row(
                                children: [
                                  if (onSend != null &&
                                      onWithdraw != null) ...[
                                    Expanded(
                                      child: AppButton(
                                        key: const ValueKey(
                                          'mobile_private_usd_send',
                                        ),
                                        variant: AppButtonVariant.secondary,
                                        expand: true,
                                        onPressed: canSend ? onSend : null,
                                        child: const Text(
                                          PrivateUsdCopy.actionSend,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: AppSpacing.s),
                                    Expanded(
                                      child: AppButton(
                                        key: const ValueKey(
                                          'mobile_private_usd_withdraw',
                                        ),
                                        variant: AppButtonVariant.secondary,
                                        expand: true,
                                        onPressed: canSend
                                            ? onWithdraw
                                            : null,
                                        child: const Text(
                                          PrivateUsdCopy.actionWithdraw,
                                        ),
                                      ),
                                    ),
                                  ],
                                  // Incoming, so the spend guard never
                                  // holds it.
                                  if (onReceive case final onReceive?) ...[
                                    if (onSend != null && onWithdraw != null)
                                      const SizedBox(width: AppSpacing.s),
                                    Expanded(
                                      child: AppButton(
                                        key: const ValueKey(
                                          'mobile_private_usd_receive_usdc',
                                        ),
                                        variant: AppButtonVariant.secondary,
                                        expand: true,
                                        onPressed: onReceive,
                                        child: const Text(
                                          PrivateUsdCopy.actionReceive,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                          if (pendingPayment case final payment?) ...[
                            const SizedBox(height: AppSpacing.xs),
                            NeonSyncOcclude(
                              child: PrivateUsdPendingPaymentLine(
                                payment: payment,
                              ),
                            ),
                          ],
                          if (spendNote case final note?) ...[
                            const SizedBox(height: AppSpacing.xs),
                            NeonSyncOcclude(
                              child: Text(
                                note,
                                key: const ValueKey(
                                  'mobile_private_usd_spend_note',
                                ),
                                style: AppTypography.bodySmall.copyWith(
                                  color: colors.text.secondary,
                                ),
                              ),
                            ),
                          ],
                          if (depositLines.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.s),
                            NeonSyncOcclude(
                              child: _DepositsCard(
                                lines: depositLines,
                                minimum: depositMinimum,
                                screening: screening,
                                privacyModeEnabled: privacyModeEnabled,
                                onTap: onReceive,
                              ),
                            ),
                          ],
                          if (banner != null) ...[
                            const SizedBox(height: AppSpacing.s),
                            NeonSyncOcclude(
                              child: PrivateUsdConversionBannerView(
                                banner: banner,
                                onTap: () =>
                                    onOpenConversion?.call(banner.path),
                              ),
                            ),
                          ],
                          if (balances != null &&
                              balances.total == BigInt.zero &&
                              banner == null) ...[
                            const SizedBox(height: AppSpacing.s),
                            const NeonSyncOcclude(child: _EmptyCard()),
                          ] else if (balances != null) ...[
                            const SizedBox(height: AppSpacing.s),
                            NeonSyncOcclude(
                              child: _BucketsCard(
                                balances: balances,
                                privacyModeEnabled: privacyModeEnabled,
                                screening: screening,
                                arrivingSince: arrivingSince,
                                now: now,
                              ),
                            ),
                            if (balances.held.length > 1) ...[
                              const SizedBox(height: AppSpacing.s),
                              NeonSyncOcclude(
                                child: _AssetsCard(
                                  balances: balances,
                                  tokenNames: tokenNames,
                                  privacyModeEnabled: privacyModeEnabled,
                                ),
                              ),
                            ],
                          ],
                          if (receiveAddress case final address?) ...[
                            const SizedBox(height: AppSpacing.s),
                            NeonSyncOcclude(
                              child: _ReceiveAddressCard(address: address),
                            ),
                          ],
                          const SizedBox(height: AppSpacing.md),
                          _ActivitySection(
                            rows: activityRows,
                            onRefunds: onRefunds,
                          ),
                        ],
                      ),
                    ),
                    if (onConvert != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.sm,
                          AppSpacing.s,
                          AppSpacing.sm,
                          AppSpacing.md,
                        ),
                        child: NeonSyncOcclude(
                          child: AppButton(
                            key: const ValueKey('mobile_private_usd_convert'),
                            expand: true,
                            onPressed: canConvert ? onConvert : null,
                            child: const Text(PrivateUsdCopy.actionConvert),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Positioned.fill(
                child: NeonSyncLineLayer(
                  key: const ValueKey('mobile_private_usd_sync_front'),
                  line: syncLine,
                  layer: NeonSyncLayer.front,
                  scrolled: scrolled,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _masked(String usd, bool privacyModeEnabled) => hideAmountIfPrivacyMode(
  usd,
  privacyModeEnabled: privacyModeEnabled,
  denomination: '',
);

class _TotalCard extends StatelessWidget {
  const _TotalCard({
    required this.state,
    required this.zecUsdPrice,
    required this.privacyModeEnabled,
    required this.onRefresh,
    required this.rpcFailing,
    required this.onUseDefaultRpc,
  });

  final PrivateUsdBalanceState state;
  final double? zecUsdPrice;
  final bool privacyModeEnabled;
  final VoidCallback onRefresh;
  final bool rpcFailing;
  final VoidCallback? onUseDefaultRpc;

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
    // The sync's progress is the sync line's (VI-19): its percentage, and a
    // refresh as the floor flowing. What stays here is what to expect of a
    // first sync, and how old the balance is.
    final status = balances == null
        ? (state.isLoading ? PrivateUsdCopy.firstLoad : null)
        : updatedAt == null
        ? null
        : PrivateUsdCopy.updated(formatDayMonthTime(updatedAt));
    final error = !state.refreshFailed
        ? null
        : balances == null
        ? PrivateUsdCopy.loadFailed
        : PrivateUsdCopy.refreshFailed;
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_total'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  headline,
                  key: const ValueKey('mobile_private_usd_headline'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.displayLarge.copyWith(
                    color: balances == null
                        ? colors.text.disabled
                        : colors.text.accent,
                  ),
                ),
              ),
              _RefreshButton(
                busy: state.isRefreshing,
                onTap: state.isRefreshing ? null : onRefresh,
              ),
            ],
          ),
          if (zec != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              zec,
              key: const ValueKey('mobile_private_usd_zec_equivalent'),
              style: AppTypography.bodyMedium.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
          // Screen readers hear both from the sync line, with the progress.
          if (status != null) ...[
            const SizedBox(height: AppSpacing.s),
            ExcludeSemantics(
              child: Text(
                status,
                key: const ValueKey('mobile_private_usd_status'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            ),
          ],
          if (rpcFailing) ...[
            const SizedBox(height: AppSpacing.xs),
            // Read out: the sync line says only that the sync failed.
            Text(
              PrivateUsdCopy.rpcNotAnswering,
              key: const ValueKey('mobile_private_usd_rpc_error'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.destructive,
              ),
            ),
            if (onUseDefaultRpc case final onUseDefault?) ...[
              const SizedBox(height: AppSpacing.xs),
              AppButton(
                key: const ValueKey('mobile_private_usd_rpc_default'),
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.small,
                onPressed: onUseDefault,
                child: const Text(PrivateUsdCopy.rpcUseDefault),
              ),
            ],
          ] else if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            ExcludeSemantics(
              child: Text(
                error,
                key: const ValueKey('mobile_private_usd_error'),
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

/// The total's refresh: its arrow turns while the balance refreshes, and
/// finishes its turn when the refresh ends. Under reduced motion it holds
/// still.
class _RefreshButton extends StatefulWidget {
  const _RefreshButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  State<_RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<_RefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTurn();
  }

  @override
  void didUpdateWidget(_RefreshButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTurn();
  }

  void _syncTurn() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 0;
    } else if (widget.busy) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      // Finish the turn rather than snap back.
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: PrivateUsdCopy.refresh,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('mobile_private_usd_refresh'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: RotationTransition(
              turns: _controller,
              child: AppIcon(
                AppIcons.renew,
                size: 20,
                color: widget.busy ? colors.text.disabled : colors.text.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BucketsCard extends StatelessWidget {
  const _BucketsCard({
    required this.balances,
    required this.privacyModeEnabled,
    required this.screening,
    required this.arrivingSince,
    required this.now,
  });

  final PrivateUsdBalances balances;
  final bool privacyModeEnabled;
  final Duration screening;
  final DateTime? arrivingSince;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      _BucketRow(
        key: const ValueKey('mobile_private_usd_row_available'),
        label: PrivateUsdCopy.rowAvailable,
        amount: _masked(
          formatPrivateUsd(balances.available),
          privacyModeEnabled,
        ),
      ),
      if (balances.processing > BigInt.zero)
        _BucketRow(
          key: const ValueKey('mobile_private_usd_row_processing'),
          label: PrivateUsdCopy.rowProcessing,
          amount: _masked(
            formatPrivateUsd(balances.processing),
            privacyModeEnabled,
          ),
          info: PrivateUsdCopy.rowProcessingInfo,
        ),
      if (balances.arriving > BigInt.zero)
        _ArrivingRow(
          key: const ValueKey('mobile_private_usd_row_arriving'),
          since: arrivingSince,
          screening: screening,
          now: now,
          amount: _masked(
            formatPrivateUsd(balances.arriving),
            privacyModeEnabled,
          ),
        ),
      if (balances.blocked > BigInt.zero)
        _BucketRow(
          key: const ValueKey('mobile_private_usd_row_blocked'),
          label: PrivateUsdCopy.rowBlocked,
          amount: _masked(
            formatPrivateUsd(balances.blocked),
            privacyModeEnabled,
          ),
          info: PrivateUsdCopy.rowBlockedInfo,
          danger: true,
        ),
    ];
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_buckets'),
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
    this.info,
    this.danger = false,
    super.key,
  });

  final String label;
  final String amount;
  final String? info;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = danger ? colors.text.destructive : colors.text.accent;
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
        if (info != null) ...[
          const SizedBox(height: AppSpacing.xxs),
          Text(
            info!,
            style: AppTypography.bodySmall.copyWith(
              color: danger ? colors.text.destructive : colors.text.secondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// The Arriving row (owner, 2026-10-17): "Arriving · 40%" while its funds
/// are screened, from when they landed ([since]) over the [screening]
/// period, then "Arriving · taking longer than usual"; plain "Arriving"
/// when no landing time is known. The estimate moves every 10 s while the
/// row shows.
class _ArrivingRow extends StatefulWidget {
  const _ArrivingRow({
    required this.since,
    required this.screening,
    required this.now,
    required this.amount,
    super.key,
  });

  final DateTime? since;
  final Duration screening;
  final DateTime Function() now;
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
      since: widget.since,
      screening: widget.screening,
      now: widget.now(),
    ),
    amount: widget.amount,
    info: PrivateUsdCopy.rowArrivingInfo(
      PrivateUsdCopy.about(widget.screening),
    ),
  );
}

class _AssetsCard extends StatelessWidget {
  const _AssetsCard({
    required this.balances,
    required this.tokenNames,
    required this.privacyModeEnabled,
  });

  final PrivateUsdBalances balances;
  final Map<String, String> tokenNames;
  final bool privacyModeEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_assets'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            PrivateUsdCopy.assetsTitle,
            style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
          ),
          for (final asset in balances.held) ...[
            const SizedBox(height: AppSpacing.s),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tokenNames[asset.token.address] ??
                        PrivateUsdCopy.tokenName(asset.token.symbol),
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

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_empty'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            PrivateUsdCopy.emptyTitle,
            style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            PrivateUsdCopy.emptyBody,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceiveAddressCard extends StatelessWidget {
  const _ReceiveAddressCard({required this.address});

  final String address;

  Future<void> _copy(BuildContext context) async {
    // A receive address is not sensitive: the plain clipboard.
    await Clipboard.setData(ClipboardData(text: address));
    unawaited(AppHaptics.copy());
    if (context.mounted) showAppToast(context, PrivateUsdCopy.addressCopied);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_receive'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  PrivateUsdCopy.receiveAddress,
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.text.accent,
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: PrivateUsdCopy.copyAddress,
                excludeSemantics: true,
                child: GestureDetector(
                  key: const ValueKey('mobile_private_usd_copy_address'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _copy(context),
                  child: SizedBox.square(
                    dimension: 44,
                    child: Center(
                      child: AppIcon(
                        AppIcons.copy,
                        size: 20,
                        color: colors.text.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Text(
            PrivateUsdCopy.receiveAddressNote,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.s),
            decoration: BoxDecoration(
              color: colors.background.window,
              borderRadius: BorderRadius.circular(AppRadii.medium),
            ),
            child: Text(
              address,
              key: const ValueKey('mobile_private_usd_address'),
              style: AppTypography.codeSmall.copyWith(
                color: colors.text.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The deposits' state now (M9): what each deposit address received, what
/// is being made private, and what is being screened. Opens the Receive
/// USDC sheet.
class _DepositsCard extends StatelessWidget {
  const _DepositsCard({
    required this.lines,
    required this.minimum,
    required this.screening,
    required this.privacyModeEnabled,
    required this.onTap,
  });

  final List<PrivateUsdDepositLine> lines;
  final BigInt? minimum;
  final Duration screening;
  final bool privacyModeEnabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      key: const ValueKey('mobile_private_usd_deposits'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MobileSurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              PrivateUsdCopy.depositsTitle,
              style: AppTypography.labelLarge.copyWith(
                color: colors.text.accent,
              ),
            ),
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
      ),
    );
  }
}

/// Conversions (M5), then sends and withdrawals (M7), newest first.
class _ActivitySection extends StatelessWidget {
  const _ActivitySection({required this.rows, this.onRefunds});

  final List<ActivityRowData> rows;
  final VoidCallback? onRefunds;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NeonSyncOcclude(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    PrivateUsdCopy.activityTitle,
                    style: AppTypography.headlineSmall.copyWith(
                      color: colors.text.accent,
                    ),
                  ),
                ),
                if (onRefunds case final onRefunds?)
                  AppButton(
                    key: const ValueKey('mobile_private_usd_refunds'),
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.small,
                    onPressed: onRefunds,
                    child: const Text(PrivateUsdCopy.refundsTitle),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          if (rows.isEmpty)
            NeonSyncOcclude(
              child: Text(
                PrivateUsdCopy.activityEmpty,
                key: const ValueKey('mobile_private_usd_activity_empty'),
                style: AppTypography.bodySmall.copyWith(
                  color: colors.text.secondary,
                ),
              ),
            )
          else
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: AppSpacing.s),
              KeyedSubtree(
                key: ValueKey('mobile_private_usd_activity_row_$i'),
                child: NeonSyncOcclude(
                  child: ActivityFeedRowGroup(row: rows[i]),
                ),
              ),
            ],
        ],
      ),
    );
  }
}

class _InfoButton extends StatelessWidget {
  const _InfoButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: PrivateUsdCopy.infoButton,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('mobile_private_usd_info'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: AppIcon(
              AppIcons.help,
              size: 20,
              color: context.colors.text.primary,
            ),
          ),
        ),
      ),
    );
  }
}
