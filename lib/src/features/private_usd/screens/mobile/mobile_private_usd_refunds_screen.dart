import 'dart:async';

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/formatting/date_format.dart';
import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../rust/api/private_usd.dart' as rust;
import '../../models/private_usd_balances.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_deposits_provider.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_refunds_provider.dart';
import '../../services/private_usd_engine.dart';
import '../../widgets/mobile/private_usd_confirm_sheets.dart';

/// `/private-usd/refunds` (plan reference §9.4 S7): every refunded
/// conversion, whether its refund can be recovered, and "Recover refund"
/// behind a confirmation sheet (D18). Since M9, also each deposit that
/// Railgun's screening sent back to its vault, with "Recover deposit".
class MobilePrivateUsdRefundsScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdRefundsScreen({super.key});

  @override
  ConsumerState<MobilePrivateUsdRefundsScreen> createState() =>
      _MobilePrivateUsdRefundsScreenState();
}

class _MobilePrivateUsdRefundsScreenState
    extends ConsumerState<MobilePrivateUsdRefundsScreen> {
  /// The deposit address being recovered, and why a recovery did not go.
  int? _depositRecovering;
  final _depositErrors = <int, String>{};

  @override
  void initState() {
    super.initState();
    // The vaults are read on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(privateUsdDepositActionsProvider).refresh(checkVaults: true);
      }
    });
  }

  Future<void> _recoverDeposit(
    String account,
    rust.ApiDepositRescuable rescue,
  ) async {
    if (_depositRecovering != null) return;
    final confirmed = await confirmPrivateUsdDepositRescue(
      context,
      fee: formatPrivateUsd(BigInt.tryParse(rescue.fee) ?? BigInt.zero),
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _depositRecovering = rescue.index;
      _depositErrors.remove(rescue.index);
    });
    String? error;
    try {
      await ref
          .read(privateUsdEngineProvider)
          .rescueDeposit(account, index: rescue.index);
    } on rust.ApiPrivateUsdError catch (failure) {
      if (failure.code != rust.ApiPrivateUsdErrorCode.cancelled) {
        error = PrivateUsdCopy.refundsDepositRecoverFailed;
      }
    } catch (failure) {
      if (failure is! PrivateUsdEngineInterruptedException) {
        error = PrivateUsdCopy.refundsDepositRecoverFailed;
      }
    }
    if (!mounted) return;
    setState(() {
      _depositRecovering = null;
      if (error != null) _depositErrors[rescue.index] = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    if (account == null) return const SizedBox.shrink();
    final state = ref.watch(privateUsdRefundsProvider(account));
    final notifier = ref.read(privateUsdRefundsProvider(account).notifier);
    final cap = BigInt.tryParse(
      ref.watch(privateUsdCurrentDeploymentProvider)?.maxRelayerFee ?? '',
    );
    Future<void> recover(int index) async {
      final confirmed = await confirmPrivateUsdRefundRecovery(
        context,
        feeCap: formatPrivateUsd(cap ?? BigInt.from(2000000)),
      );
      if (confirmed) await notifier.recover(index);
    }

    final canGoBack = state.canGoBack && _depositRecovering == null;
    return PopScope(
      canPop: canGoBack,
      child: MobilePrivateUsdRefundsView(
        state: state,
        privacyModeEnabled: ref.watch(privacyModeProvider),
        onBack: canGoBack ? () => context.pop() : null,
        onRefresh: () {
          ref.read(privateUsdDepositActionsProvider).refresh(checkVaults: true);
          unawaited(notifier.refresh());
        },
        onRecover: (index) => unawaited(recover(index)),
        depositRescues: ref.watch(privateUsdDepositRescuesProvider(account)),
        depositRecovering: _depositRecovering,
        depositErrors: Map.unmodifiable(_depositErrors),
        onRecoverDeposit: (rescue) =>
            unawaited(_recoverDeposit(account, rescue)),
      ),
    );
  }
}

/// The Refunds screen's content for a given state. Widgetbook, capture
/// scenarios and tests build it directly.
class MobilePrivateUsdRefundsView extends StatelessWidget {
  const MobilePrivateUsdRefundsView({
    required this.state,
    required this.onBack,
    required this.onRefresh,
    required this.onRecover,
    this.privacyModeEnabled = false,
    this.depositRescues = const [],
    this.depositRecovering,
    this.depositErrors = const {},
    this.onRecoverDeposit,
    super.key,
  });

  final PrivateUsdRefundsState state;
  final bool privacyModeEnabled;
  final VoidCallback? onBack;
  final VoidCallback onRefresh;
  final ValueChanged<int> onRecover;

  /// Deposits Railgun's screening sent back to their vaults (M9), the one
  /// being recovered, and why a recovery did not go.
  final List<rust.ApiDepositRescuable> depositRescues;
  final int? depositRecovering;
  final Map<int, String> depositErrors;
  final ValueChanged<rust.ApiDepositRescuable>? onRecoverDeposit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final error = state.error;
    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileTopNav.back(
              title: PrivateUsdCopy.refundsTitle,
              onBack: onBack,
            ),
            Expanded(
              child: ListView(
                key: const ValueKey('mobile_private_usd_refunds_list'),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.lg,
                ),
                children: [
                  Text(
                    PrivateUsdCopy.refundsSubtitle,
                    style: AppTypography.labelLarge.copyWith(
                      color: colors.text.accent,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    PrivateUsdCopy.refundsInfo,
                    style: AppTypography.bodyMedium.copyWith(
                      color: colors.text.secondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AppButton(
                      key: const ValueKey('mobile_private_usd_refunds_refresh'),
                      variant: AppButtonVariant.secondary,
                      size: AppButtonSize.small,
                      onPressed: state.recovering == null && !state.refreshing
                          ? onRefresh
                          : null,
                      leading: state.refreshing
                          ? const AppLoadingIcon(size: AppIconSize.medium)
                          : const AppIcon(AppIcons.renew),
                      child: const Text(PrivateUsdCopy.refundsRefresh),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: AppSpacing.s),
                    MobileWarningNotice(message: error),
                  ],
                  const SizedBox(height: AppSpacing.s),
                  for (final rescue in depositRescues) ...[
                    _DepositRescueCard(
                      key: ValueKey(
                        'mobile_private_usd_deposit_rescue_${rescue.index}',
                      ),
                      rescue: rescue,
                      recovering: depositRecovering == rescue.index,
                      canRecover:
                          depositRecovering == null && state.recovering == null,
                      error: depositErrors[rescue.index],
                      privacyModeEnabled: privacyModeEnabled,
                      onRecover: onRecoverDeposit == null
                          ? null
                          : () => onRecoverDeposit!(rescue),
                    ),
                    const SizedBox(height: AppSpacing.s),
                  ],
                  if (state.rows.isEmpty && depositRescues.isEmpty)
                    Text(
                      state.loaded
                          ? PrivateUsdCopy.refundsEmpty
                          : PrivateUsdCopy.refundsChecking,
                      key: const ValueKey('mobile_private_usd_refunds_empty'),
                      style: AppTypography.bodySmall.copyWith(
                        color: colors.text.secondary,
                      ),
                    )
                  else
                    for (final (i, row) in state.rows.indexed) ...[
                      if (i > 0) const SizedBox(height: AppSpacing.s),
                      _RefundCard(
                        key: ValueKey('mobile_private_usd_refund_$i'),
                        row: row,
                        recovering: state.recovering == row.record.index,
                        canRecover: state.recovering == null,
                        privacyModeEnabled: privacyModeEnabled,
                        onRecover: () => onRecover(row.record.index),
                      ),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RefundCard extends StatelessWidget {
  const _RefundCard({
    required this.row,
    required this.recovering,
    required this.canRecover,
    required this.privacyModeEnabled,
    required this.onRecover,
    super.key,
  });

  final PrivateUsdRefundRow row;
  final bool recovering;
  final bool canRecover;
  final bool privacyModeEnabled;
  final VoidCallback onRecover;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final record = row.record;
    final date = DateTime.fromMillisecondsSinceEpoch(
      (record.acceptedAt ?? record.quoteExpiresAt) * 1000,
    );
    final amount = hideAmountIfPrivacyMode(
      formatPrivateUsd(BigInt.parse(record.amount)),
      privacyModeEnabled: privacyModeEnabled,
      denomination: '',
    );
    final status = recovering
        ? PrivateUsdCopy.refundsRecovering
        : row.otherDeployment
        ? PrivateUsdCopy.refundsOtherDeployment
        : row.checkFailed
        ? PrivateUsdCopy.refundsCheckFailed
        : row.recoverable == null
        ? PrivateUsdCopy.refundsChecking
        : row.recoverable!
        ? PrivateUsdCopy.refundsAvailable
        : PrivateUsdCopy.refundsNoRecovery;
    final error = row.error;
    return MobileSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            formatDayMonthTime(date),
            style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  PrivateUsdCopy.refundsOriginalAmount,
                  style: AppTypography.bodyMedium.copyWith(
                    color: colors.text.secondary,
                  ),
                ),
              ),
              Text(
                amount,
                style: AppTypography.bodyMedium.copyWith(
                  color: colors.text.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            status,
            style: AppTypography.bodySmall.copyWith(
              color: row.checkFailed
                  ? colors.text.destructive
                  : colors.text.secondary,
            ),
          ),
          if (row.recoverable == true || recovering) ...[
            const SizedBox(height: AppSpacing.s),
            AppButton(
              key: const ValueKey('mobile_private_usd_refund_recover'),
              size: AppButtonSize.medium,
              expand: true,
              onPressed: canRecover ? onRecover : null,
              leading: recovering
                  ? const AppLoadingIcon(size: AppIconSize.medium)
                  : null,
              child: const Text(PrivateUsdCopy.refundsRecover),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            MobileWarningNotice(message: error),
          ],
        ],
      ),
    );
  }
}

/// A deposit Railgun's screening sent back to its address's vault (M9):
/// what the vault holds, and "Recover deposit".
class _DepositRescueCard extends StatelessWidget {
  const _DepositRescueCard({
    required this.rescue,
    required this.recovering,
    required this.canRecover,
    required this.error,
    required this.privacyModeEnabled,
    required this.onRecover,
    super.key,
  });

  final rust.ApiDepositRescuable rescue;
  final bool recovering;
  final bool canRecover;
  final String? error;
  final bool privacyModeEnabled;
  final VoidCallback? onRecover;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final held = hideAmountIfPrivacyMode(
      formatPrivateUsd(BigInt.tryParse(rescue.held) ?? BigInt.zero),
      privacyModeEnabled: privacyModeEnabled,
      denomination: '',
    );
    final error = this.error;
    return MobileSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            PrivateUsdCopy.refundsDepositTitle,
            style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            recovering
                ? PrivateUsdCopy.refundsDepositRecovering
                : PrivateUsdCopy.refundsDepositBody(held),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          AppButton(
            key: const ValueKey('mobile_private_usd_deposit_recover'),
            size: AppButtonSize.medium,
            expand: true,
            onPressed: canRecover ? onRecover : null,
            leading: recovering
                ? const AppLoadingIcon(size: AppIconSize.medium)
                : null,
            child: const Text(PrivateUsdCopy.refundsDepositRecover),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            MobileWarningNotice(message: error),
          ],
        ],
      ),
    );
  }
}
