import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/block_spacing_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../providers/sync_provider.dart';
import '../../../../rust/api/private_usd.dart' show ApiForwardOutcome;
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_reverse_presentation.dart';
import '../../models/private_usd_status_presentation.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_conversion_provider.dart';
import '../../providers/private_usd_least_fee_provider.dart';
import '../../providers/private_usd_relayer_claims_provider.dart';
import '../../providers/private_usd_reverse_conversion_provider.dart';
import '../../widgets/desktop/desktop_private_usd_bridge_widgets.dart';
import '../../widgets/desktop/desktop_private_usd_widgets.dart';
import '../../widgets/mobile/private_usd_progress_views.dart'
    show PrivateUsdProgressScreenState;

const _loading = Padding(
  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
  child: Center(
    child: AppLoadingIcon(
      key: ValueKey('desktop_private_usd_progress_loading'),
      size: AppIconSize.large,
    ),
  ),
);

/// `/private-usd/conversion/forward/:index` on desktop: one ZEC → shielded USD
/// bridge's progress, driven by the foreground engine as on the phone, with
/// the red timeline and the bridge's details, the keep-open card while it
/// needs Veylor, the "Bridged" sign once it finished, and its main action
/// pinned at the foot of the pane. The route carries its key, so the banner,
/// an activity row and a restart open it alike; it pairs the path with the
/// active account.
class DesktopPrivateUsdConversionScreen extends ConsumerStatefulWidget {
  const DesktopPrivateUsdConversionScreen({required this.path, super.key});

  final PrivateUsdRoutePath path;

  @override
  ConsumerState<DesktopPrivateUsdConversionScreen> createState() =>
      _DesktopPrivateUsdConversionScreenState();
}

class _DesktopPrivateUsdConversionScreenState
    extends ConsumerState<DesktopPrivateUsdConversionScreen>
    with PrivateUsdProgressScreenState {
  void _viewBalance() {
    final router = GoRouter.of(context);
    router.go('/home');
    unawaited(router.push<void>('/private-usd'));
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    if (account == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final key = widget.path.keyFor(account);
    final state = ref.watch(privateUsdConversionProvider(key));
    final status = state.status;
    final bridge = ref.watch(privateUsdBridgeAvailableProvider);
    if (status == null && state.loaded) {
      // No such bridge for this account: start a new one instead, where
      // bridging runs.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.pushReplacement(
            bridge ? '/private-usd/convert' : '/private-usd',
          );
        }
      });
    }
    // A bridge runs only on a deployment, whose numbers it shows.
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final screening = Duration(seconds: deployment?.screeningSeconds ?? 0);
    final paid = status?.record.outcome == ApiForwardOutcome.paid;
    final balance = paid ? ref.watch(privateUsdBalanceProvider(account)) : null;
    if (paid) {
      // A payout arrives in the shielded balance: keep it fresh meanwhile. It
      // shows once Railgun's head moves past it, as every wallet's refresh
      // follows, never at a time set by this bridge.
      ref.watch(
        privateUsdBalanceKeepFreshProvider((
          accountUuid: account,
          ifUsed: false,
        )),
      );
    }
    final presentation = status == null || deployment == null
        ? null
        : privateUsdProgressPresentation(
            l10n,
            status: status,
            now: state.now,
            zcashConfirmations: deployment.zcashConfirmations,
            screening: screening,
            balance: balance,
            privacyModeEnabled: ref.watch(privacyModeProvider),
            explorerTxPrefix: deployment.explorerTxPrefix,
            bridgeAvailable: bridge,
            relayerClaims:
                ref.watch(privateUsdRelayerClaimsProvider).value ?? true,
            blockTimes: ref
                .watch(blockSpacingProvider)
                .fromTip(
                  ref.watch(
                    syncProvider.select(
                      (sync) => sync.value?.chainTipHeight ?? 0,
                    ),
                  ),
                ),
          );
    if (presentation != null) noteBridged(presentation.bridged);
    final notifier = ref.read(privateUsdConversionProvider(key).notifier);
    final callingOff = state.callingOff;
    final callOffError = state.callOffError?.call(l10n);
    final action = presentation?.action;
    return PopScope<Object?>(
      canPop: !callingOff,
      child: DesktopPrivateUsdPage(
        title: presentation?.title ?? l10n.privateUsdConvertProgressTitle,
        contentKey: const ValueKey('desktop_private_usd_progress_content'),
        canGoBack: !callingOff,
        onInfo: deployment == null
            ? null
            : () => unawaited(
                showDesktopPrivateUsdProgressInfo(
                  context,
                  zcashConfirmations: deployment.zcashConfirmations,
                  screening: screening,
                  relayerClaims: status?.claimHandedOver ?? false,
                ),
              ),
        action: action == null
            ? null
            : AppButton(
                key: const ValueKey('desktop_private_usd_progress_action'),
                expand: true,
                onPressed: switch (action) {
                  PrivateUsdProgressAction.viewBalance => _viewBalance,
                  PrivateUsdProgressAction.tryAgain =>
                    () => context.pushReplacement('/private-usd/convert'),
                },
                child: Text(switch (action) {
                  PrivateUsdProgressAction.viewBalance =>
                    l10n.privateUsdConvertResultViewBalance,
                  PrivateUsdProgressAction.tryAgain => l10n.commonTryAgain,
                }),
              ),
        children: [
          if (presentation == null)
            _loading
          else
            DesktopPrivateUsdProgressBody(
              status: presentation.status,
              payAmountText: presentation.payAmountText,
              receiveAmountText: presentation.receiveAmountText,
              bridged: presentation.bridged,
              celebrate: celebrate,
              resultTitle: presentation.resultTitle,
              resultBody: presentation.resultBody,
              note: presentation.note,
              problem: presentation.problem,
              onRetry: notifier.retryNow,
              actions: [
                if (presentation.showsCallOff)
                  AppButton(
                    key: const ValueKey(
                      'desktop_private_usd_progress_call_off',
                    ),
                    variant: AppButtonVariant.secondary,
                    expand: true,
                    onPressed: callingOff
                        ? null
                        : () => unawaited(notifier.callOff()),
                    leading: callingOff
                        ? const AppLoadingIcon(size: AppIconSize.medium)
                        : null,
                    child: Text(l10n.privateUsdConvertCallOff),
                  ),
                if (callOffError != null)
                  DesktopPrivateUsdNotice(
                    key: const ValueKey('desktop_private_usd_progress_error'),
                    message: callOffError,
                  ),
              ],
              showsKeepOpen: presentation.showsKeepOpen,
              keepScreenOn: keepsScreenOn(key),
              onKeepScreenOnChanged: (on) => keepScreenOn(key, on: on),
              activeTab: tab,
              detailsExpanded: detailsExpanded,
              onTabChanged: selectTab,
              onToggleDetails: toggleDetails,
            ),
        ],
      ),
    );
  }
}

/// `/private-usd/conversion/reverse/:index` on desktop: one shielded USD →
/// ZEC bridge's progress, with the user's two approvals as its pinned action
/// (paying, which the Railgun page proves, and "Authorize settlement" once the
/// market maker's ZEC is in), and the call-off behind a confirmation. While
/// settlement is being authorized or the bridge called off, back is held and
/// the sidebar veiled, as the phone holds its screen; and while the payment
/// is proved and posted, as desktop's send is: an account switch or a sign-out
/// would close the Railgun page mid-proof.
class DesktopPrivateUsdReverseConversionScreen extends ConsumerStatefulWidget {
  const DesktopPrivateUsdReverseConversionScreen({
    required this.path,
    super.key,
  });

  final PrivateUsdRoutePath path;

  @override
  ConsumerState<DesktopPrivateUsdReverseConversionScreen> createState() =>
      _DesktopPrivateUsdReverseConversionScreenState();
}

class _DesktopPrivateUsdReverseConversionScreenState
    extends ConsumerState<DesktopPrivateUsdReverseConversionScreen>
    with PrivateUsdProgressScreenState {
  Future<void> _callOff(
    PrivateUsdReverseConversionNotifier notifier,
    PrivateUsdReverseProgressPresentation presentation,
  ) async {
    final action = presentation.callOffLabel;
    if (action == null) return;
    final confirmed = await confirmDesktopPrivateUsdReverseCancel(
      context,
      action: action,
      paid: presentation.callOffPaid,
    );
    if (!confirmed || !mounted) return;
    await notifier.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    if (account == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final key = widget.path.keyFor(account);
    final state = ref.watch(privateUsdReverseConversionProvider(key));
    final status = state.status;
    final bridge = ref.watch(privateUsdBridgeAvailableProvider);
    if (status == null && state.loaded) {
      // No such bridge for this account: start a new one instead, where
      // bridging runs.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.pushReplacement(
            bridge ? '/private-usd/convert?to=zec' : '/private-usd',
          );
        }
      });
    }
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final presentation = status == null
        ? null
        : privateUsdReverseProgressPresentation(
            l10n,
            status: status,
            now: state.now,
            funding: state.funding,
            proofProgress: state.proofProgress,
            busy: state.busy,
            privacyModeEnabled: ref.watch(privacyModeProvider),
            explorerTxPrefix: deployment?.explorerTxPrefix,
            bridgeAvailable: bridge,
            sweepFeeFloorZat: ref.watch(privateUsdLeastFeeZatProvider),
          );
    if (presentation != null) noteBridged(presentation.bridged);
    final notifier = ref.read(
      privateUsdReverseConversionProvider(key).notifier,
    );
    // An authorized step (settlement, the call-off) holds the screen, and so
    // does the payment while the page proves and posts it.
    final holds =
        state.acting == PrivateUsdReverseUserStep.readying ||
        state.acting == PrivateUsdReverseUserStep.cancelling ||
        (state.funding?.running ?? false);
    final message = state.message(l10n);
    final label = presentation?.actionLabel;
    final callOff = presentation?.callOffLabel;
    final cancelling = state.acting == PrivateUsdReverseUserStep.cancelling;
    final working =
        state.acting == PrivateUsdReverseUserStep.readying &&
        presentation?.action == PrivateUsdReverseAction.authorizeSettlement;
    final VoidCallback? onAction = switch (presentation?.action) {
      PrivateUsdReverseAction.pay => notifier.pay,
      PrivateUsdReverseAction.authorizeSettlement => () => unawaited(
        notifier.authorizeReady(),
      ),
      PrivateUsdReverseAction.newConversion => () => context.pushReplacement(
        '/private-usd/convert?to=zec',
      ),
      null => null,
    };
    return PopScope<Object?>(
      canPop: !holds,
      child: DesktopPrivateUsdPage(
        title: presentation?.title ?? l10n.privateUsdConvertProgressTitle,
        contentKey: const ValueKey('desktop_private_usd_progress_content'),
        canGoBack: !holds,
        onInfo: () => unawaited(showDesktopPrivateUsdReverseInfo(context)),
        action: label == null
            ? null
            : AppButton(
                key: const ValueKey('desktop_private_usd_progress_action'),
                expand: true,
                onPressed: presentation!.actionEnabled ? onAction : null,
                leading: working
                    ? const AppLoadingIcon(size: AppIconSize.medium)
                    : null,
                child: Text(label),
              ),
        children: [
          if (presentation == null)
            _loading
          else
            DesktopPrivateUsdProgressBody(
              status: presentation.status,
              payAmountText: presentation.payAmountText,
              receiveAmountText: presentation.receiveAmountText,
              bridged: presentation.bridged,
              celebrate: celebrate,
              resultTitle: presentation.resultTitle,
              resultBody: presentation.resultBody,
              note: presentation.note,
              problem: presentation.problem,
              onRetry: notifier.retryNow,
              actions: [
                if (message != null)
                  DesktopPrivateUsdNotice(
                    key: const ValueKey('desktop_private_usd_progress_error'),
                    message: message,
                  ),
                if (callOff != null)
                  AppButton(
                    key: const ValueKey(
                      'desktop_private_usd_progress_call_off',
                    ),
                    variant: AppButtonVariant.secondary,
                    expand: true,
                    onPressed: state.acting != null
                        ? null
                        : () => unawaited(_callOff(notifier, presentation)),
                    leading: cancelling
                        ? const AppLoadingIcon(size: AppIconSize.medium)
                        : null,
                    child: Text(callOff),
                  ),
                if (presentation.showsViewRefunds)
                  AppButton(
                    key: const ValueKey('desktop_private_usd_progress_refunds'),
                    variant: AppButtonVariant.secondary,
                    expand: true,
                    onPressed: () => context.push('/private-usd/refunds'),
                    child: Text(l10n.privateUsdRefundsView),
                  ),
              ],
              provingNote: presentation.provingNote,
              showsKeepOpen: presentation.showsKeepOpen,
              keepScreenOn: keepsScreenOn(key),
              onKeepScreenOnChanged: (on) => keepScreenOn(key, on: on),
              activeTab: tab,
              detailsExpanded: detailsExpanded,
              onTabChanged: selectTab,
              onToggleDetails: toggleDetails,
            ),
        ],
      ),
    );
  }
}
