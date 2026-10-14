import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/layout/app_form_factor.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/private_usd_lifecycle_provider.dart';
import '../../../providers/rpc_endpoint_failover_provider.dart';
import '../models/private_usd_record_key.dart';
import '../services/private_usd_engine.dart';
import '../services/private_usd_reverse_funding.dart';
import '../services/private_usd_sender.dart';
import '../services/private_usd_spend_guard.dart';
import '../services/private_usd_swap_backend.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_unfinished_provider.dart';
import 'railgun_engine_provider.dart';

/// This wallet's swap context now: the network, the lightwalletd endpoint
/// and the deployment's Railgun network for the keyed Ethereum RPC.
PrivateUsdSwapContext privateUsdSwapContextOf(Ref ref) {
  final endpoint = ref.read(rpcEndpointFailoverProvider).current;
  final deployment = ref.read(
    privateUsdDeploymentProvider(endpoint.networkName),
  );
  return PrivateUsdSwapContext(
    network: endpoint.networkName,
    lightwalletdUrl: endpoint.normalizedLightwalletdUrl,
    railgunNetwork: deployment?.railgunNetwork,
    allowedHosts: deployment?.allowedHosts ?? const [],
  );
}

/// The swap engine's calls for this wallet; replaced by a fake in tests.
final privateUsdSwapBackendProvider = Provider<PrivateUsdSwapBackend>(
  (ref) => RustPrivateUsdSwapBackend(() => privateUsdSwapContextOf(ref)),
);

/// The Rust send calls for this wallet (M7); replaced by a fake in tests.
final privateUsdSendBackendProvider = Provider<PrivateUsdSendBackend>(
  (ref) => RustPrivateUsdSendBackend(() => privateUsdSwapContextOf(ref)),
);

/// Whether this build runs the swap engine at all: the define, a mobile
/// Android build, and a deployment for the network. It does not follow the
/// active account or the kill switch: conversions under way keep being
/// driven for every account (D14, D16).
bool privateUsdEngineEnabledFor({
  required bool enabled,
  required AppFormFactor formFactor,
  required TargetPlatform platform,
  required bool hasDeployment,
}) =>
    enabled &&
    formFactor == AppFormFactor.mobile &&
    platform == TargetPlatform.android &&
    hasDeployment;

final privateUsdEngineEnabledProvider = Provider<bool>((ref) {
  // Const, so desktop builds and builds without the define drop the rest.
  if (!kVizorPrivateUsdEnabled || kAppFormFactor != AppFormFactor.mobile) {
    return false;
  }
  return privateUsdEngineEnabledFor(
    enabled: true,
    formFactor: kAppFormFactor,
    // The Railgun host and the conversions are Android only for now (an OS
    // behaviour, not a layout choice).
    platform: defaultTargetPlatform,
    hasDeployment: ref.watch(privateUsdCurrentDeploymentProvider) != null,
  );
});

/// The foreground swap loop (plan reference §5.10), kept alive outside the
/// widget tree once `PrivateUsdEngineHost` builds it. Gift Card's shape: a
/// lock or the background pauses it, unlock and the foreground resume it,
/// and account deletions and resets drain it through
/// [privateUsdLifecycleProvider]. Its snapshot goes to
/// [privateUsdConversionsProvider] and [privateUsdUnfinishedProvider].
final privateUsdEngineProvider = Provider<PrivateUsdEngine>((ref) {
  final lifecycle = ref.watch(privateUsdLifecycleProvider);
  final state = WidgetsBinding.instance.lifecycleState;
  var foreground = state == null || state == AppLifecycleState.resumed;
  final engine = PrivateUsdEngine(
    backend: ref.watch(privateUsdSwapBackendProvider),
    // Any account's seed while unlocked (D14); null while locked.
    readMnemonic: (accountUuid) => ref
        .read(accountProvider.notifier)
        .getMnemonicBytesForAccount(accountUuid),
    allowed: () =>
        foreground &&
        !ref.read(appSecurityProvider).requiresUnlock &&
        !lifecycle.isQuiesced,
    // Until the account list loads, every account counts as known.
    isKnownAccount: (accountUuid) {
      final accounts = ref.read(accountProvider).value?.accounts;
      return accounts == null ||
          accounts.any((account) => account.uuid == accountUuid);
    },
  );

  void publish() {
    final snapshot = engine.conversions.value;
    final reverse = engine.reverseConversions.value;
    ref.read(privateUsdConversionsProvider.notifier).publish(snapshot);
    ref.read(privateUsdReverseConversionsProvider.notifier).publish(reverse);
    ref.read(privateUsdUnfinishedProvider.notifier).publish({
      for (final entry in snapshot.entries)
        if (entry.value.isUnderWay) entry.key,
      for (final entry in reverse.entries)
        if (entry.value.isUnderWay) entry.key,
    });
  }

  engine.conversions.addListener(publish);
  engine.reverseConversions.addListener(publish);
  lifecycle.register(
    owner: engine,
    quiesceAndDrain: engine.quiesceAndDrain,
    resume: engine.resumeAfterMutation,
  );
  ref.listen(appSecurityProvider.select((s) => s.requiresUnlock), (
    previous,
    locked,
  ) {
    if (locked) {
      unawaited(engine.pause(PrivateUsdPauseReason.lock));
    } else {
      engine.start(resuming: true);
    }
  });
  // A deleted account's conversions go with it; a reset takes them all.
  ref.listen(
    accountProvider.select(
      (s) => s.value?.accounts.map((account) => account.uuid).toSet(),
    ),
    (previous, next) {
      if (previous == null || next == null) return;
      if (next.isEmpty) {
        engine.forgetAll();
        return;
      }
      for (final uuid in previous.difference(next)) {
        engine.forgetAccount(uuid);
      }
    },
  );
  final listener = AppLifecycleListener(
    onHide: () {
      foreground = false;
      unawaited(engine.pause(PrivateUsdPauseReason.background));
    },
    onPause: () {
      foreground = false;
      unawaited(engine.pause(PrivateUsdPauseReason.background));
    },
    onResume: () {
      foreground = true;
      engine.start(resuming: true);
    },
  );
  ref.onDispose(() {
    listener.dispose();
    lifecycle.unregister(engine);
    engine.conversions.removeListener(publish);
    engine.reverseConversions.removeListener(publish);
    unawaited(engine.dispose());
  });
  // After the provider is built: starting may publish.
  scheduleMicrotask(() => engine.start(resuming: true));
  return engine;
});

/// The key of [accountUuid]'s conversion under way, if the engine knows one.
final privateUsdUnderWayProvider =
    Provider.family<PrivateUsdRecordKey?, String>(
      (ref, accountUuid) => privateUsdUnderWayFor(
        ref.watch(privateUsdUnfinishedProvider),
        accountUuid,
      ),
    );

/// One outgoing Railgun payment at a time per account, sends and
/// conversions alike, across restarts (the send log, M7).
final privateUsdSpendGuardProvider = Provider<PrivateUsdSpendGuard>((ref) {
  final guard = PrivateUsdSpendGuard(
    readLog: (accountUuid) =>
        ref.read(privateUsdSendBackendProvider).list(accountUuid),
    unfinishedCount: (accountUuid) =>
        ref.read(privateUsdSwapBackendProvider).unfinishedCount(accountUuid),
  );
  ref.onDispose(guard.dispose);
  return guard;
});

/// The Railgun page's reverse calls; replaced by a fake in tests.
final privateUsdReversePageProvider = Provider<PrivateUsdReversePage>(
  (ref) => RailgunReversePage(ref.watch(railgunEngineProvider)),
);

/// The reverse funding (§5.11 R4–R6), kept alive with the engine: a proof
/// outlives the screen that started it.
final privateUsdReverseFundingProvider = Provider<PrivateUsdReverseFunding>((
  ref,
) {
  final funding = PrivateUsdReverseFunding(
    engine: ref.watch(privateUsdEngineProvider),
    page: ref.watch(privateUsdReversePageProvider),
    guard: ref.watch(privateUsdSpendGuardProvider),
  );
  void publish() => ref
      .read(privateUsdFundingStatesProvider.notifier)
      .publish(funding.states.value);
  funding.states.addListener(publish);
  ref.onDispose(() {
    funding.states.removeListener(publish);
    funding.dispose();
  });
  return funding;
});

/// Each reverse conversion's funding as [privateUsdReverseFundingProvider]
/// last published it.
final privateUsdFundingStatesProvider =
    NotifierProvider<
      PrivateUsdFundingStatesNotifier,
      Map<PrivateUsdRecordKey, PrivateUsdFundingState>
    >(PrivateUsdFundingStatesNotifier.new);

class PrivateUsdFundingStatesNotifier
    extends Notifier<Map<PrivateUsdRecordKey, PrivateUsdFundingState>> {
  @override
  Map<PrivateUsdRecordKey, PrivateUsdFundingState> build() => const {};

  void publish(Map<PrivateUsdRecordKey, PrivateUsdFundingState> next) =>
      state = next;
}
