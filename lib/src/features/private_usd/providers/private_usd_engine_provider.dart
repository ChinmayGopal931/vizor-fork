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
import '../services/private_usd_deposit_backend.dart';
import '../services/private_usd_engine.dart';
import '../services/private_usd_reverse_funding.dart';
import '../services/private_usd_sender.dart';
import '../services/private_usd_spend_guard.dart';
import '../services/private_usd_swap_backend.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_custom_rpc_provider.dart';
import 'private_usd_tokens_provider.dart';
import 'private_usd_unfinished_provider.dart';
import 'railgun_engine_provider.dart';

/// This wallet's swap context now: the network, the lightwalletd endpoint,
/// and for the Ethereum RPC the user's own URL (Settings) or else the
/// deployment's Railgun network for the keyed one.
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
    customRpcUrl: deployment == null
        ? null
        : () => privateUsdCustomRpcUrlOf(ref, endpoint.networkName),
  );
}

/// The swap engine's calls for this wallet.
final privateUsdSwapBackendProvider = Provider<PrivateUsdSwapBackend>(
  (ref) => RustPrivateUsdSwapBackend(() => privateUsdSwapContextOf(ref)),
);

/// The Rust send calls for this wallet; replaced by a fake in tests.
final privateUsdSendBackendProvider = Provider<PrivateUsdSendBackend>(
  (ref) => RustPrivateUsdSendBackend(() => privateUsdSwapContextOf(ref)),
);

/// The Rust deposit calls for this wallet.
final privateUsdDepositBackendProvider = Provider<PrivateUsdDepositBackend>(
  (ref) => PrivateUsdDepositBackend(() => privateUsdSwapContextOf(ref)),
);

/// Whether this build follows deposits at all: the swap engine runs and the
/// network pins a Deposits contract (testnet and mainnet both do). It does
/// not follow the kill switch, which only stops new deposits.
final privateUsdDepositsEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(privateUsdEngineEnabledProvider) &&
      ref.watch(privateUsdCurrentDeploymentProvider)?.deposits != null,
);

/// The account deposits run for: the active one, when it can have them (a
/// software account with a ZIP-32 index).
String? privateUsdDepositAccountOf(Ref ref) {
  final account = ref.read(accountProvider).value?.activeAccount;
  if (account == null ||
      account.isHardware ||
      account.zip32AccountIndex == null) {
    return null;
  }
  return account.uuid;
}

/// [privateUsdEngineEnabledFor] for this build.
final privateUsdEngineEnabledProvider = Provider<bool>((ref) {
  // Const, so desktop builds and builds without the define drop the rest.
  if (!kPrivateUsdBuildEnabled) return false;
  return privateUsdEngineEnabledFor(
    enabled: true,
    formFactor: kAppFormFactor,
    // Which OS hosts the Railgun page is an OS behaviour, not a layout choice.
    platform: defaultTargetPlatform,
    hostSupported: ref.watch(railgunHostSupportedProvider),
    hasDeployment: ref.watch(privateUsdCurrentDeploymentProvider) != null,
  );
});

/// The foreground swap loop, kept alive outside the widget tree once
/// `PrivateUsdEngineHost` builds it. Gift Card's shape: a lock or the
/// background pauses it, unlock and the foreground resume it, and account
/// deletions and resets drain it through [privateUsdLifecycleProvider]. Its
/// snapshot goes to [privateUsdConversionsProvider] and
/// [privateUsdUnfinishedProvider].
final privateUsdEngineProvider = Provider<PrivateUsdEngine>((ref) {
  final lifecycle = ref.watch(privateUsdLifecycleProvider);
  final state = WidgetsBinding.instance.lifecycleState;
  // Stricter than `appInForegroundProvider`: an app that starts inactive
  // runs no key-using step until it is resumed.
  var foreground = state == null || state == AppLifecycleState.resumed;
  final depositsEnabled = ref.read(privateUsdDepositsEnabledProvider);
  final engine = PrivateUsdEngine(
    backend: ref.watch(privateUsdSwapBackendProvider),
    tokens: ref.watch(privateUsdTokensServiceProvider),
    // Any account's seed while unlocked; null while locked.
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
    // Deposits: the active account's only. The kill switch stops new ones,
    // never one under way.
    depositBackend: depositsEnabled
        ? ref.watch(privateUsdDepositBackendProvider)
        : null,
    depositAccount: () => privateUsdDepositAccountOf(ref),
    depositsSignNew: () => ref.read(privateUsdAvailableProvider),
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

  void publishDeposits() => ref
      .read(privateUsdDepositsProvider.notifier)
      .publish(engine.deposits.value);

  engine.conversions.addListener(publish);
  engine.reverseConversions.addListener(publish);
  engine.deposits.addListener(publishDeposits);
  // The deposits follow the active account.
  ref.listen(accountProvider.select((s) => s.value?.activeAccountUuid), (
    previous,
    next,
  ) {
    if (previous != null && previous != next) engine.depositAccountChanged();
  });
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
    engine.deposits.removeListener(publishDeposits);
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
/// conversions alike, across restarts (the send log).
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

/// The reverse funding, kept alive with the engine: a proof outlives the
/// screen that started it.
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
