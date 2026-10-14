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
import '../../models/private_usd_balances.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_refunds_provider.dart';
import '../../widgets/mobile/private_usd_confirm_sheets.dart';

/// `/private-usd/refunds` (plan reference §9.4 S7): every refunded
/// conversion, whether its refund can be recovered, and "Recover refund"
/// behind a confirmation sheet (D18).
class MobilePrivateUsdRefundsScreen extends ConsumerWidget {
  const MobilePrivateUsdRefundsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    return PopScope(
      canPop: state.canGoBack,
      child: MobilePrivateUsdRefundsView(
        state: state,
        privacyModeEnabled: ref.watch(privacyModeProvider),
        onBack: state.canGoBack ? () => context.pop() : null,
        onRefresh: () => unawaited(notifier.refresh()),
        onRecover: (index) => unawaited(recover(index)),
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
    super.key,
  });

  final PrivateUsdRefundsState state;
  final bool privacyModeEnabled;
  final VoidCallback? onBack;
  final VoidCallback onRefresh;
  final ValueChanged<int> onRecover;

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
                  if (state.rows.isEmpty)
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
