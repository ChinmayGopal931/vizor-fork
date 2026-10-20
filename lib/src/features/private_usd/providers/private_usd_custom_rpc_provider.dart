import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_bootstrap.dart';
import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/storage/app_secure_store.dart';
import '../../../rust/api/private_usd.dart' show ApiPrivateUsdErrorCode;
import '../models/private_usd_record_key.dart';
import '../services/private_usd_rpc_check.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';

/// Where a user's own Ethereum RPC URL (Settings) is kept for a Railgun
/// network: one secure-storage key per network, which a full reset's wipe
/// takes with the rest.
class PrivateUsdCustomRpcStore {
  const PrivateUsdCustomRpcStore(this._storage);

  final AppSecureStore _storage;

  static String _storageKey(String railgunNetwork) =>
      'vizor_private_usd_ethereum_rpc_v1_$railgunNetwork';

  Future<String?> read(String railgunNetwork) =>
      _storage.readString(_storageKey(railgunNetwork));

  Future<void> write(String railgunNetwork, String url) =>
      _storage.writeString(_storageKey(railgunNetwork), url);

  Future<void> delete(String railgunNetwork) =>
      _storage.delete(_storageKey(railgunNetwork));
}

final privateUsdCustomRpcStoreProvider = Provider<PrivateUsdCustomRpcStore>(
  (_) => PrivateUsdCustomRpcStore(AppSecureStore.instance),
);

/// The user's own Ethereum RPC URL for a wallet network (`main`, `test`), or
/// null for the default (the build's keyed URL, else publicnode). When set it
/// replaces the default everywhere, alone: the page's `start` and Rust's
/// Ethereum calls, with no fallback. A secret, as it can hold a key: never
/// log it or put it in a record.
final privateUsdCustomRpcProvider =
    AsyncNotifierProvider.family<PrivateUsdCustomRpcNotifier, String?, String>(
      PrivateUsdCustomRpcNotifier.new,
    );

class PrivateUsdCustomRpcNotifier extends AsyncNotifier<String?> {
  PrivateUsdCustomRpcNotifier(this.network);

  final String network;

  @override
  Future<String?> build() async {
    final deployment = ref.watch(privateUsdDeploymentProvider(network));
    if (deployment == null) return null;
    final stored = await ref
        .read(privateUsdCustomRpcStoreProvider)
        .read(deployment.railgunNetwork);
    if (stored == null) return null;
    // Saved checked; a URL this build's page could not reach goes unused.
    return privateUsdCustomRpcUrl(
      stored,
      deployment.railgunNetwork,
      allowedHosts: deployment.allowedHosts,
    );
  }

  /// Keeps [url], which passed [PrivateUsdRpcChecker], and uses it from the
  /// next call on; the Railgun page closes so that its next use starts with
  /// it. Throws [FormatException] for a URL that can't be one.
  Future<void> save(String url) async {
    await _settled();
    final deployment = ref.read(privateUsdDeploymentProvider(network));
    final valid = deployment == null
        ? null
        : privateUsdCustomRpcUrl(
            url,
            deployment.railgunNetwork,
            allowedHosts: deployment.allowedHosts,
          );
    if (deployment == null || valid == null) {
      throw const FormatException('Not an Ethereum RPC URL Private USD takes');
    }
    await ref
        .read(privateUsdCustomRpcStoreProvider)
        .write(deployment.railgunNetwork, valid);
    state = AsyncData(valid);
  }

  /// Goes back to the default; the Railgun page closes as for [save].
  Future<void> clear() async {
    await _settled();
    final deployment = ref.read(privateUsdDeploymentProvider(network));
    if (deployment != null) {
      await ref
          .read(privateUsdCustomRpcStoreProvider)
          .delete(deployment.railgunNetwork);
    }
    state = const AsyncData(null);
  }

  // A build still reading would otherwise land after a change and undo it.
  Future<void> _settled() async {
    try {
      await future;
    } catch (_) {
      // Unreadable: the change replaces it.
    }
  }
}

/// The user's own Ethereum RPC URL for [network], or null for the default,
/// once it has been read. A setting that can't be read fails the call rather
/// than fall back to the default, which the user may have chosen to avoid;
/// the next call reads it again.
Future<String?> privateUsdCustomRpcUrlOf(Ref ref, String network) async {
  final provider = privateUsdCustomRpcProvider(network);
  try {
    return await ref.read(provider.future);
  } catch (_) {
    ref.invalidate(provider);
    rethrow;
  }
}

/// The host a user's own RPC URL shows as: never the whole URL, which can
/// hold a key.
String privateUsdCustomRpcHost(String url) => Uri.parse(url).host;

/// Checks a URL before Settings saves it.
final privateUsdRpcCheckerProvider = Provider<PrivateUsdRpcChecker>((ref) {
  final checker = PrivateUsdRpcChecker();
  ref.onDispose(checker.close);
  return checker;
});

/// Whether Settings offers the Ethereum RPC row: wherever Private USD is
/// available, and wherever the engine runs while a URL of the user's is set,
/// so that it can always be put back to the default.
final privateUsdRpcSettingVisibleProvider = Provider<bool>((ref) {
  if (ref.watch(privateUsdAvailableProvider)) return true;
  if (!ref.watch(privateUsdEngineEnabledProvider)) return false;
  final network = ref.watch(appBootstrapProvider).network;
  return ref.watch(privateUsdCustomRpcProvider(network)).value != null;
});

/// Whether a conversion of an account can't reach Ethereum: a step's problem,
/// which shows once its steps have failed for a minute.
final privateUsdEthereumUnreachableProvider = Provider.family<bool, String>((
  ref,
  accountUuid,
) {
  bool failing(PrivateUsdRecordKey key, ApiPrivateUsdErrorCode? problem) =>
      key.accountUuid == accountUuid &&
      problem == ApiPrivateUsdErrorCode.ethereumUnreachable;
  return ref.watch(
        privateUsdConversionsProvider.select(
          (all) => all.entries.any((e) => failing(e.key, e.value.problem)),
        ),
      ) ||
      ref.watch(
        privateUsdReverseConversionsProvider.select(
          (all) => all.entries.any((e) => failing(e.key, e.value.problem)),
        ),
      );
});
