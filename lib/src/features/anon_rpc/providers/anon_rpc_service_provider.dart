import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_foreground_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/private_usd_lifecycle_provider.dart';
import '../services/anon_rpc_host_channel.dart';
import '../services/anon_rpc_service.dart';
import 'anon_rpc_network_provider.dart';

/// The platform's anon-rpc page host (Kotlin); replaced by a fake in tests.
final anonRpcHostProvider = Provider<AnonRpcHost>(
  (_) => const AnonRpcHostChannel(),
);

/// The service that answers Rust's anonymous RPC requests, kept alive outside
/// the widget tree by `PrivateUsdEngineHost`. It listens while the app is in
/// the foreground and unlocked (as the swap engine runs), drops the page on a
/// lock, restarts the worker on a network change, and drains with the other
/// Private USD owners before an account deletion or a reset.
final anonRpcServiceProvider = Provider<AnonRpcService>((ref) {
  final service = AnonRpcService(
    host: ref.watch(anonRpcHostProvider),
    networkOf: () => ref.read(anonRpcNetworkProvider.future),
    debug: kDebugMode,
  );
  final lifecycle = ref.watch(privateUsdLifecycleProvider);
  var quiesced = false;

  void apply() {
    if (quiesced) return;
    final foreground = ref.read(appInForegroundProvider);
    final locked = ref.read(appSecurityProvider).requiresUnlock;
    if (foreground && !locked) {
      service.start();
    } else {
      unawaited(service.pause(closePage: locked));
    }
  }

  ref.listen(appInForegroundProvider, (_, _) => apply());
  ref.listen(appSecurityProvider.select((s) => s.requiresUnlock), (_, _) {
    apply();
  });
  ref.listen(anonRpcNetworkProvider, (previous, next) {
    if (previous == null || !previous.hasValue || !next.hasValue) return;
    if (previous.value != next.value) unawaited(service.restart());
  });
  lifecycle.register(
    owner: service,
    quiesceAndDrain: () async {
      quiesced = true;
      await service.pause(closePage: true);
    },
    resume: () {
      quiesced = false;
      apply();
    },
  );
  ref.onDispose(() {
    lifecycle.unregister(service);
    unawaited(service.dispose());
  });
  scheduleMicrotask(apply);
  return service;
});

/// The worker's status, for Settings.
final anonRpcStatusProvider =
    NotifierProvider<AnonRpcStatusNotifier, AnonRpcStatus>(
      AnonRpcStatusNotifier.new,
    );

class AnonRpcStatusNotifier extends Notifier<AnonRpcStatus> {
  @override
  AnonRpcStatus build() {
    final service = ref.watch(anonRpcServiceProvider);
    void listener() => state = service.status.value;
    service.status.addListener(listener);
    ref.onDispose(() => service.status.removeListener(listener));
    return service.status.value;
  }
}
