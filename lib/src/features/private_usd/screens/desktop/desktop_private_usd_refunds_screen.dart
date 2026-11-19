import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/formatting/date_format.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../rust/api/private_usd.dart' as rust;
import '../../models/private_usd_balances.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_deposits_provider.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_refunds_provider.dart';
import '../../services/private_usd_pause.dart';
import '../../widgets/desktop/desktop_private_usd_widgets.dart';

String _masked(String usd, bool privacyModeEnabled) => hideAmountIfPrivacyMode(
  usd,
  privacyModeEnabled: privacyModeEnabled,
  denomination: '',
);

/// `/private-usd/refunds` on desktop: every refunded bridge and whether its
/// refund can be recovered, and each deposit Railgun's screening sent back to
/// its vault. The phone's screen and its rules ([privateUsdRefundsProvider]):
/// the checks are chain reads only, a recovery needs the seed and is the
/// user's alone, behind a confirmation that names the relayer's fee (at most
/// the 2 USDC cap), and one recovery runs at a time, holding back meanwhile.
class DesktopPrivateUsdRefundsScreen extends ConsumerStatefulWidget {
  const DesktopPrivateUsdRefundsScreen({super.key});

  @override
  ConsumerState<DesktopPrivateUsdRefundsScreen> createState() =>
      _DesktopPrivateUsdRefundsScreenState();
}

class _DesktopPrivateUsdRefundsScreenState
    extends ConsumerState<DesktopPrivateUsdRefundsScreen> {
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
    final l10n = context.l10n;
    final confirmed = await showDesktopPrivateUsdConfirm(
      context,
      title: l10n.privateUsdRefundsDepositConfirmTitle,
      body: l10n.privateUsdRefundsDepositConfirmBody(
        formatPrivateUsd(BigInt.tryParse(rescue.fee) ?? BigInt.zero),
      ),
      confirmLabel: l10n.privateUsdRefundsDepositRecover,
      dismissLabel: l10n.privateUsdNotNow,
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
        error = l10n.privateUsdRefundsDepositRecoverFailed;
      }
    } catch (failure) {
      if (failure is! PrivateUsdPause) {
        error = l10n.privateUsdRefundsDepositRecoverFailed;
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
    final colors = context.colors;
    final l10n = context.l10n;
    final state = ref.watch(privateUsdRefundsProvider(account));
    final notifier = ref.read(privateUsdRefundsProvider(account).notifier);
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    final depositRescues = ref.watch(privateUsdDepositRescuesProvider(account));
    final cap = privateUsdRelayerFeeCap(
      ref.watch(privateUsdCurrentDeploymentProvider),
    );
    Future<void> recover(int index) async {
      // Without a cap no relayer fee is within it, so nothing is signed.
      if (cap == null) return;
      final confirmed = await showDesktopPrivateUsdConfirm(
        context,
        title: l10n.privateUsdRefundsRecoverConfirmTitle,
        body: l10n.privateUsdRefundsRecoverConfirmBody(formatPrivateUsd(cap)),
        confirmLabel: l10n.privateUsdRefundsRecover,
        dismissLabel: l10n.privateUsdNotNow,
      );
      if (confirmed) await notifier.recover(index);
    }

    final canGoBack = state.canGoBack && _depositRecovering == null;
    final error = state.error?.call(l10n);
    final busy = state.recovering != null || _depositRecovering != null;
    return PopScope<Object?>(
      canPop: canGoBack,
      child: DesktopPrivateUsdPage(
        title: l10n.privateUsdRefundsTitle,
        contentKey: const ValueKey('desktop_private_usd_refunds_content'),
        canGoBack: canGoBack,
        children: [
          Text(
            l10n.privateUsdRefundsSubtitle,
            textAlign: TextAlign.center,
            style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            l10n.privateUsdRefundsInfo,
            textAlign: TextAlign.center,
            style: AppTypography.bodyMedium.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          Center(
            child: AppButton(
              key: const ValueKey('desktop_private_usd_refunds_refresh'),
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              onPressed: state.recovering == null && !state.refreshing
                  ? () {
                      ref
                          .read(privateUsdDepositActionsProvider)
                          .refresh(checkVaults: true);
                      unawaited(notifier.refresh());
                    }
                  : null,
              leading: state.refreshing
                  ? const AppLoadingIcon(size: AppIconSize.medium)
                  : const AppIcon(AppIcons.renew),
              child: Text(l10n.privateUsdRefresh),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.s),
            DesktopPrivateUsdNotice(message: error),
          ],
          const SizedBox(height: AppSpacing.md),
          for (final rescue in depositRescues) ...[
            _DepositRescuePanel(
              key: ValueKey(
                'desktop_private_usd_deposit_rescue_${rescue.index}',
              ),
              rescue: rescue,
              recovering: _depositRecovering == rescue.index,
              canRecover: !busy,
              error: _depositErrors[rescue.index],
              privacyModeEnabled: privacyModeEnabled,
              onRecover: () => unawaited(_recoverDeposit(account, rescue)),
            ),
            const SizedBox(height: AppSpacing.s),
          ],
          if (state.rows.isEmpty && depositRescues.isEmpty)
            Text(
              state.loaded
                  ? l10n.privateUsdRefundsEmpty
                  : l10n.privateUsdRefundsChecking,
              key: const ValueKey('desktop_private_usd_refunds_empty'),
              textAlign: TextAlign.center,
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.secondary,
              ),
            )
          else
            for (final (i, row) in state.rows.indexed) ...[
              if (i > 0) const SizedBox(height: AppSpacing.s),
              _RefundPanel(
                key: ValueKey('desktop_private_usd_refund_$i'),
                row: row,
                recovering: state.recovering == row.record.index,
                canRecover: !busy,
                privacyModeEnabled: privacyModeEnabled,
                onRecover: () => unawaited(recover(row.record.index)),
              ),
            ],
        ],
      ),
    );
  }
}

/// A refunded bridge: when it started, what it was for, whether its refund
/// can be recovered, and Recover once it can.
class _RefundPanel extends StatelessWidget {
  const _RefundPanel({
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
    final l10n = context.l10n;
    final record = row.record;
    final date = DateTime.fromMillisecondsSinceEpoch(
      (record.acceptedAt ?? record.quoteExpiresAt) * 1000,
    );
    final amount = _masked(
      formatPrivateUsd(BigInt.parse(record.amount)),
      privacyModeEnabled,
    );
    final status = recovering
        ? l10n.privateUsdRefundsRecovering
        : row.checkFailed
        ? l10n.privateUsdRefundsCheckFailed
        : row.recoverable == null
        ? l10n.privateUsdRefundsChecking
        : row.recoverable!
        ? l10n.privateUsdRefundsAvailable
        : l10n.privateUsdRefundsNoRecovery;
    final error = row.error?.call(l10n);
    return DesktopPrivateUsdPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopPrivateUsdCaption(formatDayMonthTime(date, l10n.localeName)),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.privateUsdRefundsOriginalAmount,
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
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppButton(
                key: const ValueKey('desktop_private_usd_refund_recover'),
                size: AppButtonSize.small,
                onPressed: canRecover ? onRecover : null,
                leading: recovering
                    ? const AppLoadingIcon(size: AppIconSize.medium)
                    : null,
                child: Text(l10n.privateUsdRefundsRecover),
              ),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            DesktopPrivateUsdNotice(message: error, danger: true),
          ],
        ],
      ),
    );
  }
}

/// A deposit Railgun's screening sent back to its address's vault: what the
/// vault holds, and its recovery.
class _DepositRescuePanel extends StatelessWidget {
  const _DepositRescuePanel({
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
  final VoidCallback onRecover;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final held = _masked(
      formatPrivateUsd(BigInt.tryParse(rescue.held) ?? BigInt.zero),
      privacyModeEnabled,
    );
    final error = this.error;
    return DesktopPrivateUsdPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopPrivateUsdCaption(l10n.privateUsdRefundsDepositTitle),
          const SizedBox(height: AppSpacing.xs),
          Text(
            recovering
                ? l10n.privateUsdRefundsDepositRecovering
                : l10n.privateUsdRefundsDepositBody(held),
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              key: const ValueKey('desktop_private_usd_deposit_recover'),
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              onPressed: canRecover ? onRecover : null,
              leading: recovering
                  ? const AppLoadingIcon(size: AppIconSize.medium)
                  : null,
              child: Text(l10n.privateUsdRefundsDepositRecover),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            DesktopPrivateUsdNotice(message: error, danger: true),
          ],
        ],
      ),
    );
  }
}
