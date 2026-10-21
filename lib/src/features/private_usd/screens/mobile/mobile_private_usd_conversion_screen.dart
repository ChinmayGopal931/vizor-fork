import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feedback/app_haptics.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../rust/api/private_usd.dart' show ApiForwardOutcome;
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_status_presentation.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_conversion_provider.dart';
import '../../services/private_usd_balance_repository.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import '../../widgets/mobile/private_usd_progress_views.dart';

/// `/private-usd/conversion/:direction/:index`: one forward conversion's
/// progress, driven by the foreground engine. The route carries its key, so
/// a cold start, the banner and a deep link open it alike; it pairs the path
/// with the active account.
class MobilePrivateUsdConversionScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdConversionScreen({required this.path, super.key});

  final PrivateUsdRoutePath path;

  @override
  ConsumerState<MobilePrivateUsdConversionScreen> createState() =>
      _MobilePrivateUsdConversionScreenState();
}

class _MobilePrivateUsdConversionScreenState
    extends ConsumerState<MobilePrivateUsdConversionScreen>
    with PrivateUsdProgressScreenState {
  @override
  PrivateUsdRoutePath get path => widget.path;

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
    final key = widget.path.keyFor(account);
    final state = ref.watch(privateUsdConversionProvider(key));
    final status = state.status;
    final bridge = ref.watch(privateUsdBridgeAvailableProvider);
    if (status == null && state.loaded) {
      // No such conversion for this account: start a new one instead, where
      // bridging runs.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.pushReplacement(
            bridge ? '/private-usd/convert' : '/private-usd',
          );
        }
      });
    }
    // A conversion runs only on a deployment, whose numbers it shows.
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final screening = Duration(seconds: deployment?.screeningSeconds ?? 0);
    final paid = status?.record.outcome == ApiForwardOutcome.paid;
    final balance = paid ? ref.watch(privateUsdBalanceProvider(account)) : null;
    final endedAt = status?.record.endedAt;
    if (paid) {
      // A payout arrives in the private balance: keep it fresh meanwhile,
      // and read it once the payout had time to land.
      ref.watch(
        privateUsdBalanceKeepFreshProvider((
          accountUuid: account,
          ifUsed: false,
        )),
      );
      final updatedAt = balance?.updatedAt;
      final landed = endedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              endedAt * 1000,
            ).add(PrivateUsdBalanceTiming.arrivingPoll);
      if (landed != null &&
          !state.now.isBefore(landed) &&
          (updatedAt == null || updatedAt.isBefore(landed))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref
              .read(privateUsdBalanceProvider(account).notifier)
              .refresh(maxAge: PrivateUsdBalanceTiming.arrivingPoll);
        });
      }
    }
    final presentation = status == null || deployment == null
        ? null
        : privateUsdProgressPresentation(
            status: status,
            now: state.now,
            zcashConfirmations: deployment.zcashConfirmations,
            screening: screening,
            balance: balance,
            privacyModeEnabled: ref.watch(privacyModeProvider),
            explorerTxPrefix: deployment.explorerTxPrefix,
            bridgeAvailable: bridge,
          );
    if (presentation != null) noteBridged(presentation.bridged);
    final notifier = ref.read(privateUsdConversionProvider(key).notifier);
    return PopScope(
      canPop: !state.callingOff,
      child: MobilePrivateUsdConversionView(
        presentation: presentation,
        callingOff: state.callingOff,
        callOffError: state.callOffError,
        celebrate: celebrate,
        onBridgedImpact: () => unawaited(AppHaptics.sendSuccess()),
        activeTab: tab,
        detailsExpanded: detailsExpanded,
        onTabChanged: selectTab,
        onToggleDetails: toggleDetails,
        onBack: state.callingOff ? null : back,
        onInfo: deployment == null
            ? null
            : () => showPrivateUsdProgressInfoSheet(
                context,
                zcashConfirmations: deployment.zcashConfirmations,
                screening: screening,
              ),
        onRetry: notifier.retryNow,
        onCallOff: () => unawaited(notifier.callOff()),
        onViewBalance: _viewBalance,
        onTryAgain: () => context.pushReplacement('/private-usd/convert'),
      ),
    );
  }
}
