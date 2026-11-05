import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../rust/api/anon_rpc.dart' as rust_anon_rpc;
import '../anon_rpc_network.dart';
import '../services/anon_rpc_host_channel.dart';

/// Whether this platform hosts the anon-rpc page (Android). Where it does
/// not, the mode stays off whatever is saved: there is no worker to carry a
/// request, and a mode that is on would fail every request closed.
final anonRpcHostSupportedProvider = FutureProvider<bool>(
  (_) => queryAnonRpcHostSupported(),
);

const kAnonRpcNetworkPreferenceKey = 'vizor_anon_rpc_network_v1';

abstract interface class AnonRpcPreferenceStore {
  Future<String?> read();
  Future<void> write(String name);
}

class SharedPreferencesAnonRpcStore implements AnonRpcPreferenceStore {
  const SharedPreferencesAnonRpcStore();

  @override
  Future<String?> read() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(kAnonRpcNetworkPreferenceKey);
  }

  @override
  Future<void> write(String name) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      kAnonRpcNetworkPreferenceKey,
      name,
    );
    if (!saved) throw StateError('the Anonymous RPC preference was not saved');
  }
}

final anonRpcPreferenceStoreProvider = Provider<AnonRpcPreferenceStore>(
  (_) => const SharedPreferencesAnonRpcStore(),
);

/// The network Shielded USD's Ethereum requests go through, applied to Rust
/// as it loads and on every change. Rust is on by default, so a saved
/// preference can only turn the mode off: an unreadable or missing one reads
/// as the default (on). The saved value may be stricter than the enforced
/// mode, never laxer (the Tor rule): turning on writes before the runtime
/// switch, turning off after it. On a platform without the page host
/// ([anonRpcHostSupportedProvider]) the mode is off whatever is saved.
final anonRpcNetworkProvider =
    AsyncNotifierProvider<AnonRpcNetworkNotifier, AnonRpcNetwork>(
      AnonRpcNetworkNotifier.new,
    );

class AnonRpcNetworkNotifier extends AsyncNotifier<AnonRpcNetwork> {
  @override
  Future<AnonRpcNetwork> build() async {
    AnonRpcNetwork network;
    try {
      network =
          AnonRpcNetwork.fromName(
            await ref.read(anonRpcPreferenceStoreProvider).read(),
          ) ??
          AnonRpcNetwork.defaultNetwork;
    } catch (_) {
      network = AnonRpcNetwork.defaultNetwork;
    }
    final supported = await ref.watch(anonRpcHostSupportedProvider.future);
    rust_anon_rpc.anonRpcSetEnabled(enabled: network.anonymizes && supported);
    return network;
  }

  Future<void> set(AnonRpcNetwork network) async {
    final previous = await future;
    if (network == previous) return;
    final store = ref.read(anonRpcPreferenceStoreProvider);
    final supported = await ref.read(anonRpcHostSupportedProvider.future);
    if (!network.anonymizes) {
      // Off: the runtime first, so a failed write leaves the stricter value
      // saved and the next launch anonymizes again.
      rust_anon_rpc.anonRpcSetEnabled(enabled: false);
      await store.write(network.name);
    } else {
      // On, or another anonymizing network: the saved value first, so a
      // failure in between leaves the laxer runtime no longer than this call.
      await store.write(network.name);
      rust_anon_rpc.anonRpcSetEnabled(enabled: supported);
    }
    state = AsyncData(network);
  }
}
