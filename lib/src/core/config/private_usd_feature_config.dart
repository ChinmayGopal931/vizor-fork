import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, HttpHeaders;

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/network_privacy_provider.dart';
import '../layout/app_process_work_policy.dart';
import '../network/network_http_client.dart';

/// Private USD's build defines (plan reference §7.3), read once here.
///
/// The master switch until launch; release builds turn it on only after the
/// M8 sign-off.
const kVizorPrivateUsdEnabled = bool.fromEnvironment(
  'VIZOR_PRIVATE_USD_ENABLED',
);

/// The kill-switch JSON's URL (D16). Empty: no fetch, and the feature is
/// available.
const kVizorPrivateUsdFlagUrl = String.fromEnvironment(
  'VIZOR_PRIVATE_USD_FLAG_URL',
);

/// Keyed Ethereum RPC URLs (E6). Secrets: never log them or store them.
/// Empty means unset; publicnode serves alone then.
const kVizorEthereumRpcUrlMainnet = String.fromEnvironment(
  'VIZOR_ETHEREUM_RPC_URL_MAINNET',
);
const kVizorEthereumRpcUrlSepolia = String.fromEnvironment(
  'VIZOR_ETHEREUM_RPC_URL_SEPOLIA',
);

/// An optional support link for stuck-funds copy (D17).
const kVizorSupportUrl = String.fromEnvironment('VIZOR_SUPPORT_URL');

/// The keyed RPC URL for a Railgun network (`mainnet` or `sepolia`), when the
/// build has one whose host the page may reach; otherwise null. A URL on
/// another host would be blocked by the page's filters anyway, so it is
/// dropped here rather than started with.
String? privateUsdKeyedRpcUrl(
  String railgunNetwork, {
  required List<String> allowedHosts,
  String mainnet = kVizorEthereumRpcUrlMainnet,
  String sepolia = kVizorEthereumRpcUrlSepolia,
}) {
  final keyed = switch (railgunNetwork) {
    'mainnet' => mainnet,
    'sepolia' => sepolia,
    _ => '',
  }.trim();
  if (keyed.isEmpty) return null;
  final uri = Uri.tryParse(keyed);
  if (uri == null ||
      uri.scheme != 'https' ||
      (uri.hasPort && uri.port != 443) ||
      !allowedHosts.contains(uri.host)) {
    if (kDebugMode) {
      debugPrint('privateUsd: the keyed RPC URL is not on an allowed host');
    }
    return null;
  }
  return keyed;
}

const kPrivateUsdAvailableKey = 'private_usd_available';
const kPrivateUsdAvailableStorageKey = 'vizor_private_usd_available_v1';

/// The kill switch's answer in [body]: `true` or `false` only when the
/// document says so explicitly; `null` for a missing key or anything
/// unreadable.
bool? parsePrivateUsdAvailability(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final value = decoded[kPrivateUsdAvailableKey];
      if (value is bool) return value;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// What the feature does with a fetch's answer: only an explicit `false`
/// hides it. A missing key, an unreadable document or a failed fetch keeps
/// the last known answer, and with none known the feature is available.
bool resolvePrivateUsdAvailability({bool? fetched, bool? lastKnown}) =>
    fetched ?? lastKnown ?? true;

abstract interface class PrivateUsdAvailabilitySource {
  /// The document's answer, or `null` when it has none. Throws when it could
  /// not be read at all (transport failure, non-2xx).
  Future<bool?> fetch();
}

/// Fetches the kill switch through [NetworkHttpClient], which follows the
/// route setting and fails closed while Tor is not usable.
class HttpPrivateUsdAvailabilitySource implements PrivateUsdAvailabilitySource {
  HttpPrivateUsdAvailabilitySource({
    required Uri endpoint,
    NetworkHttpClient? networkClient,
    // Each Tor request builds a fresh circuit, as the swap override measured.
    this.timeout = const Duration(seconds: 20),
  }) : _endpoint = endpoint,
       _client = networkClient ?? NetworkHttpClient();

  final Uri _endpoint;
  final NetworkHttpClient _client;
  final Duration timeout;

  @override
  Future<bool?> fetch() async {
    final response = await _client.request(
      'GET',
      _endpoint,
      headers: const {HttpHeaders.acceptHeader: 'application/json'},
      timeout: timeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'The kill switch returned ${response.statusCode}',
        uri: _endpoint,
      );
    }
    return parsePrivateUsdAvailability(utf8.decode(response.bodyBytes));
  }

  void close() => _client.close();
}

abstract interface class PrivateUsdAvailabilityStore {
  Future<bool?> read();

  Future<void> write(bool available);
}

class SharedPreferencesPrivateUsdAvailabilityStore
    implements PrivateUsdAvailabilityStore {
  const SharedPreferencesPrivateUsdAvailabilityStore();

  @override
  Future<bool?> read() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(kPrivateUsdAvailableStorageKey);
  }

  @override
  Future<void> write(bool available) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(kPrivateUsdAvailableStorageKey, available);
  }
}

/// The kill-switch URL; overridable in tests.
final privateUsdFlagUrlProvider = Provider<String>(
  (_) => kVizorPrivateUsdFlagUrl,
);

final privateUsdAvailabilitySourceProvider =
    Provider<PrivateUsdAvailabilitySource>((ref) {
      final source = HttpPrivateUsdAvailabilitySource(
        endpoint: Uri.parse(ref.watch(privateUsdFlagUrlProvider)),
      );
      ref.onDispose(source.close);
      return source;
    });

final privateUsdAvailabilityStoreProvider =
    Provider<PrivateUsdAvailabilityStore>(
      (_) => const SharedPreferencesPrivateUsdAvailabilityStore(),
    );

/// Whether a kill-switch retry may run in the current lifecycle (mobile is
/// foreground-only).
final privateUsdKillSwitchWorkPolicyProvider =
    Provider<bool Function({required bool isInForeground})>(
      (_) => canRunAppProcessWork,
    );

/// Delays before asking again after a failed fetch; the last one repeats.
const _kRetryDelays = <Duration>[
  Duration(seconds: 15),
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(seconds: 120),
  Duration(seconds: 300),
];

/// The kill switch (D16): `false` only after the owner's document said so.
/// `false` hides the entry points; it never stops a conversion under way.
final privateUsdKillSwitchProvider =
    NotifierProvider<PrivateUsdKillSwitchNotifier, bool>(
      PrivateUsdKillSwitchNotifier.new,
    );

class PrivateUsdKillSwitchNotifier extends Notifier<bool> {
  var _started = false;
  var _disposed = false;
  var _fetchInFlight = false;
  var _retryPending = false;
  var _retryAttempt = 0;
  var _isInForeground = true;
  var _retryDeferredToForeground = false;
  Timer? _retryTimer;
  AppLifecycleListener? _lifecycle;
  bool? _lastKnown;

  bool get _mayRunNow => ref.read(privateUsdKillSwitchWorkPolicyProvider)(
    isInForeground: _isInForeground,
  );

  @override
  bool build() {
    if (ref.watch(privateUsdFlagUrlProvider).trim().isEmpty) return true;
    _lifecycle ??= AppLifecycleListener(
      onHide: () {
        _isInForeground = false;
        if (_mayRunNow || _retryTimer == null) return;
        _cancelRetry();
        _retryDeferredToForeground = true;
      },
      onResume: () {
        _isInForeground = true;
        if (!_retryDeferredToForeground) return;
        _retryDeferredToForeground = false;
        if (!_disposed && !_fetchInFlight) unawaited(_fetch());
      },
    );
    ref.onDispose(() {
      _disposed = true;
      _cancelRetry();
      _lifecycle?.dispose();
      _lifecycle = null;
    });
    // A failed fetch is asked again once the route settles, which is better
    // evidence than the timer.
    ref.listen(networkPrivacyProvider, (previous, next) {
      if (next.status == previous?.status) return;
      if (next.status != NetworkPrivacyConnectionStatus.off &&
          next.status != NetworkPrivacyConnectionStatus.connected) {
        return;
      }
      if (!_retryPending || _fetchInFlight) return;
      _cancelRetry();
      if (!_mayRunNow) {
        _retryDeferredToForeground = true;
        return;
      }
      unawaited(_fetch());
    });
    if (!_started) {
      _started = true;
      scheduleMicrotask(() => unawaited(_start()));
    }
    return resolvePrivateUsdAvailability(lastKnown: _lastKnown);
  }

  Future<void> _start() async {
    try {
      _lastKnown = await ref.read(privateUsdAvailabilityStoreProvider).read();
    } catch (_) {
      _lastKnown = null;
    }
    if (_disposed) return;
    state = resolvePrivateUsdAvailability(lastKnown: _lastKnown);
    await _fetch();
  }

  Future<void> _fetch() async {
    final bool? fetched;
    _fetchInFlight = true;
    try {
      fetched = await ref.read(privateUsdAvailabilitySourceProvider).fetch();
    } catch (_) {
      // Unknown, not unavailable: keep the last known answer, ask again.
      _retryPending = true;
      _scheduleRetry();
      return;
    } finally {
      _fetchInFlight = false;
    }
    _retryPending = false;
    _retryAttempt = 0;
    _cancelRetry();
    if (_disposed || fetched == null) return;
    _lastKnown = fetched;
    try {
      await ref.read(privateUsdAvailabilityStoreProvider).write(fetched);
    } catch (_) {
      // The answer still applies for this run.
    }
    if (_disposed) return;
    state = resolvePrivateUsdAvailability(fetched: fetched);
  }

  void _scheduleRetry() {
    if (_disposed) return;
    final delay =
        _kRetryDelays[_retryAttempt < _kRetryDelays.length
            ? _retryAttempt
            : _kRetryDelays.length - 1];
    _retryAttempt++;
    _cancelRetry();
    if (!_mayRunNow) {
      _retryDeferredToForeground = true;
      return;
    }
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_disposed || _fetchInFlight) return;
      if (!_mayRunNow) {
        _retryDeferredToForeground = true;
        return;
      }
      unawaited(_fetch());
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }
}
