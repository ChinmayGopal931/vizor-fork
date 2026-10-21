import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, HttpHeaders;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../main.dart' show log;
import '../../providers/network_privacy_provider.dart';
import '../layout/app_form_factor.dart';
import '../layout/app_process_work_policy.dart';
import '../network/network_http_client.dart';

/// Private USD's build defines, read once here.
///
/// The master switch until launch; release builds turn it on only after the
/// owner's sign-off.
const kVizorPrivateUsdEnabled = bool.fromEnvironment(
  'VIZOR_PRIVATE_USD_ENABLED',
);

/// Whether this build can have Private USD at all: the define, in a mobile
/// build. Const, so every other build drops the feature's code.
const kPrivateUsdBuildEnabled =
    kVizorPrivateUsdEnabled && kAppFormFactor == AppFormFactor.mobile;

/// The kill-switch JSON's URL. Empty: no fetch, and the feature is
/// available.
const kVizorPrivateUsdFlagUrl = String.fromEnvironment(
  'VIZOR_PRIVATE_USD_FLAG_URL',
);

/// Keyed Ethereum RPC URLs. Secrets: never log them or store them.
/// Empty means unset; publicnode serves alone then.
const kVizorEthereumRpcUrlMainnet = String.fromEnvironment(
  'VIZOR_ETHEREUM_RPC_URL_MAINNET',
);
const kVizorEthereumRpcUrlSepolia = String.fromEnvironment(
  'VIZOR_ETHEREUM_RPC_URL_SEPOLIA',
);

/// An optional support link for stuck-funds copy.
const kVizorSupportUrl = String.fromEnvironment('VIZOR_SUPPORT_URL');

/// Logs [line] in debug builds. Private USD's lines carry runtime types and
/// error codes only: an error's message can quote a keyed RPC URL or what
/// the Railgun page saw.
void privateUsdLog(String line) {
  if (kDebugMode) log('privateUsd: $line');
}

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
  final allowed = _privateUsdRpcUrlOn(keyed, allowedHosts);
  if (allowed == null) {
    privateUsdLog('the keyed RPC URL is not on an allowed host');
  }
  return allowed;
}

/// The rule every Ethereum RPC URL the page and Rust are given follows:
/// https on port 443, on one of [hosts]. The trimmed URL, or null.
String? _privateUsdRpcUrlOn(String url, List<String> hosts) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (trimmed.isEmpty ||
      uri == null ||
      uri.scheme != 'https' ||
      (uri.hasPort && uri.port != 443) ||
      !hosts.contains(uri.host)) {
    return null;
  }
  return trimmed;
}

/// The hosts a user's own Ethereum RPC URL (Settings) may use, per Railgun
/// network: the RPC providers the page already reaches, so the page's
/// filters (Kotlin, Swift, the Rust bridge and the CSP) stay as they are.
const _kPrivateUsdCustomRpcHosts = <String, List<String>>{
  'mainnet': [
    'eth-mainnet.g.alchemy.com',
    'mainnet.infura.io',
    'ethereum-rpc.publicnode.com',
  ],
  'sepolia': [
    'eth-sepolia.g.alchemy.com',
    'sepolia.infura.io',
    'ethereum-sepolia-rpc.publicnode.com',
  ],
};

/// [input] as a user's own Ethereum RPC URL for [railgunNetwork], or null
/// when it can't be one: the keyed URL's rule, on that network's RPC hosts
/// the page may reach ([allowedHosts], the deployment's). A URL carrying
/// credentials or a fragment is refused too: the page's `fetch` rejects the
/// first, and Rust's URL parser the second. It can hold a key: never log it.
String? privateUsdCustomRpcUrl(
  String input,
  String railgunNetwork, {
  required List<String> allowedHosts,
}) {
  final hosts = [
    for (final host
        in _kPrivateUsdCustomRpcHosts[railgunNetwork] ?? const <String>[])
      if (allowedHosts.contains(host)) host,
  ];
  final url = _privateUsdRpcUrlOn(input, hosts);
  if (url == null) return null;
  final uri = Uri.parse(url);
  return uri.userInfo.isEmpty && !uri.hasFragment ? url : null;
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
    final NetworkHttpResponse response;
    try {
      response = await _client.request(
        'GET',
        _endpoint,
        headers: const {HttpHeaders.acceptHeader: 'application/json'},
        timeout: timeout,
      );
    } catch (e) {
      privateUsdLog('kill switch fetch failed (${e.runtimeType})');
      rethrow;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      privateUsdLog('kill switch returned ${response.statusCode}');
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

/// The kill switch: `false` only after the owner's document said so.
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
    } catch (e) {
      privateUsdLog('kill switch answer unreadable (${e.runtimeType})');
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
    } catch (e) {
      // Unknown, not unavailable: keep the last known answer, ask again.
      privateUsdLog('kill switch fetch unresolved (${e.runtimeType})');
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
    } catch (e) {
      // The answer still applies for this run.
      privateUsdLog('kill switch answer not cached (${e.runtimeType})');
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
