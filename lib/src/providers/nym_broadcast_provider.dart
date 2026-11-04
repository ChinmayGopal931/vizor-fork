import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/network_privacy.dart' as rust_network_privacy;

/// The Nym broadcast route (Free Society Hack, 2026-11-04).
///
/// While on, every transaction broadcast goes over a fresh Nym mixnet tunnel
/// and fails closed when none opens. Sync and other requests keep the route
/// the Tor setting chose. The route itself lives in Rust (lwd-nym).
const kNymBroadcastPreferenceKey = 'zcash_nym_broadcast_enabled';

class NymBroadcastState {
  const NymBroadcastState({
    required this.enabled,
    this.busy = false,
    this.saveFailed = false,
  });

  /// Whether broadcasts go over Nym right now (the Rust runtime's value).
  final bool enabled;
  final bool busy;

  /// The last change could not be saved. Turning on aborted before anything
  /// changed; turning off took effect, and Nym comes back on next launch.
  final bool saveFailed;
}

Future<bool> _readSavedNymBroadcast() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(kNymBroadcastPreferenceKey) ?? false;
  } catch (_) {
    // Unreadable: the stricter choice for this launch, not written back.
    return true;
  }
}

/// Applies the saved choice. Startup calls this before anything can
/// broadcast, so the route in force is never laxer than the saved one.
Future<void> initializeNymBroadcastRoute() async {
  rust_network_privacy.setNymBroadcastEnabled(
    enabled: await _readSavedNymBroadcast(),
  );
}

class NymBroadcastNotifier extends Notifier<NymBroadcastState> {
  @override
  NymBroadcastState build() {
    var enabled = false;
    try {
      enabled = rust_network_privacy.isNymBroadcastEnabled();
    } catch (_) {
      // Rust not loaded (previews and tests): off.
    }
    return NymBroadcastState(enabled: enabled);
  }

  /// Turning on saves before the switch (a failed save aborts it); turning
  /// off switches first and saves after (a failed save leaves the stricter
  /// value saved). Returns whether the change was saved.
  Future<bool> setEnabled(bool enabled) async {
    if (state.busy) return false;
    if (enabled == state.enabled && !state.saveFailed) return true;
    state = NymBroadcastState(enabled: state.enabled, busy: true);
    if (enabled) {
      if (!await _write(true)) {
        state = const NymBroadcastState(enabled: false, saveFailed: true);
        return false;
      }
      rust_network_privacy.setNymBroadcastEnabled(enabled: true);
      state = const NymBroadcastState(enabled: true);
      return true;
    }
    rust_network_privacy.setNymBroadcastEnabled(enabled: false);
    final saved = await _write(false);
    state = NymBroadcastState(enabled: false, saveFailed: !saved);
    return saved;
  }

  Future<bool> _write(bool value) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return await preferences.setBool(kNymBroadcastPreferenceKey, value);
    } catch (_) {
      return false;
    }
  }
}

final nymBroadcastProvider =
    NotifierProvider<NymBroadcastNotifier, NymBroadcastState>(
      NymBroadcastNotifier.new,
    );

/// What the light-wallet server saw for one broadcast this process made, or
/// null when it was not recorded (sent before a restart, or by another build).
rust_network_privacy.BroadcastRouteInfo? broadcastRouteForDisplayTxid(
  String displayTxid,
) {
  try {
    return rust_network_privacy.broadcastRouteForTxid(txid: displayTxid);
  } catch (_) {
    return null;
  }
}
