import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Why a Railgun page call failed. Copy and retries follow the code; the
/// page's own message is never shown or logged.
enum RailgunHostErrorCode {
  /// The page closed, its renderer died, or another replaced it. Reopen on
  /// the next use.
  closed,

  /// No reply in time, so the host closed the page. As [closed].
  timeout,

  /// No WebView package or no proxy override (Android), or below iOS 17.
  /// Do not retry in a loop.
  unavailable,

  /// A request or reply one side could not read: a bug.
  protocol,

  /// The engine, the chain or a screening node failed.
  failed,

  /// The handler refused its arguments: a bug.
  badArgs,

  /// A code this build does not know.
  unknown;

  static RailgunHostErrorCode fromWire(String code) => switch (code) {
    'closed' => closed,
    'timeout' => timeout,
    'unavailable' => unavailable,
    'protocol' => protocol,
    'failed' => failed,
    'bad_args' => badArgs,
    _ => unknown,
  };

  /// The page is gone: its bridge must stop, and the next use reopens it.
  bool get pageGone => this == closed || this == timeout;
}

/// A failed page call. Its message is the engine's own text, which can quote
/// a keyed RPC URL (ethers puts request URLs in its errors), so [toString]
/// carries only the code; [debugMessage] redacts before anything prints it.
class RailgunHostException implements Exception {
  RailgunHostException(this.code, {String? message}) : _message = message;

  final RailgunHostErrorCode code;
  final String? _message;

  /// The page's message with every [secrets] occurrence (and anything shaped
  /// like a provider key) removed, for debug output only.
  String debugMessage({Iterable<String> secrets = const []}) =>
      redactRailgunMessage(_message ?? '', secrets: secrets);

  @override
  String toString() => 'RailgunHostException(${code.name})';
}

final _alchemyKey = RegExp(r'/v2/[A-Za-z0-9_-]{8,}');
final _infuraKey = RegExp(r'/v3/[A-Za-z0-9]{16,}');

/// [message] with the keyed RPC URLs it may quote replaced. Each secret is
/// removed whole, and so is its path (the part that carries the key); Alchemy
/// and Infura key paths are removed even when the URL differs.
String redactRailgunMessage(
  String message, {
  Iterable<String> secrets = const [],
}) {
  var redacted = message;
  for (final secret in secrets) {
    final trimmed = secret.trim();
    if (trimmed.isEmpty) continue;
    redacted = redacted.replaceAll(trimmed, '<keyed RPC>');
    final uri = Uri.tryParse(trimmed);
    final path = uri == null
        ? ''
        : '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    if (path.length > 4) redacted = redacted.replaceAll(path, '/<key>');
  }
  return redacted
      .replaceAll(_alchemyKey, '/v2/<key>')
      .replaceAll(_infuraKey, '/v3/<key>');
}

/// Asks the platform's Railgun host whether the page can run here: Android
/// always can, iOS from iOS 17. No handler means no host (desktop), except
/// on iOS, where it can only mean the handler was not registered yet: the
/// answer is then unknown (`null`), and the caller asks again after the
/// first frame. Any other failure means no.
Future<bool?> queryRailgunHostSupported({
  MethodChannel channel = const MethodChannel(
    RailgunHostChannel.methodChannelName,
  ),
  TargetPlatform? platform,
}) async {
  try {
    return await channel.invokeMethod<bool>('supported') ?? false;
  } on MissingPluginException {
    return (platform ?? defaultTargetPlatform) == TargetPlatform.iOS
        ? null
        : false;
  } catch (_) {
    return false;
  }
}

/// The platform's Railgun host (Kotlin's or Swift's `RailgunHostHandler`):
/// one hidden page at a time, process-wide, proxied through the Rust bridge's
/// loopback port.
abstract interface class RailgunHost {
  /// Loads a fresh page (closing any previous one) whose traffic goes through
  /// the bridge at [proxyPort]; returns once the page says it is ready.
  Future<void> load({required int proxyPort, required bool debug});

  /// Calls [method] with one JSON object of params; returns the raw JSON
  /// result. Never log [paramsJson] or the result.
  Future<String> call(String method, String paramsJson);

  /// Closes the page and lifts the proxy override. Idempotent.
  Future<void> close();

  /// Closes the page and deletes everything the page origin stored.
  Future<void> wipe();

  Future<bool> isOpen();

  /// The page's raw `{event, data}` messages: `scan`, `proof`, and `log`
  /// from a page loaded with `debug` in a debug build.
  Stream<String> get events;
}

/// [RailgunHost] over `com.zcash.wallet/railgun`.
class RailgunHostChannel implements RailgunHost {
  const RailgunHostChannel({
    MethodChannel methods = const MethodChannel(methodChannelName),
    EventChannel eventChannel = const EventChannel(eventChannelName),
  }) : _methods = methods,
       _eventChannel = eventChannel;

  static const methodChannelName = 'com.zcash.wallet/railgun';
  static const eventChannelName = 'com.zcash.wallet/railgun/events';

  final MethodChannel _methods;
  final EventChannel _eventChannel;

  @override
  Future<void> load({required int proxyPort, required bool debug}) => _hosted(
    () => _invoke<void>('load', {'proxyPort': proxyPort, 'debug': debug}),
  );

  @override
  Future<String> call(String method, String paramsJson) async {
    final result = await _hosted(
      () =>
          _invoke<String>('call', {'method': method, 'paramsJson': paramsJson}),
    );
    if (result == null) {
      throw RailgunHostException(RailgunHostErrorCode.protocol);
    }
    return result;
  }

  // No host on this platform: the page cannot run here.
  Future<T> _hosted<T>(Future<T> Function() invoke) async {
    try {
      return await invoke();
    } on MissingPluginException {
      throw RailgunHostException(RailgunHostErrorCode.unavailable);
    }
  }

  // A platform without a host has no page and no page storage, so there is
  // nothing to close or wipe.
  @override
  Future<void> close() async {
    try {
      await _invoke<void>('close');
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<void> wipe() async {
    try {
      await _invoke<void>('wipe');
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<bool> isOpen() async {
    try {
      return await _invoke<bool>('isOpen') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Stream<String> get events => _eventChannel
      .receiveBroadcastStream()
      .where((event) => event is String)
      .cast<String>();

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw RailgunHostException(
        RailgunHostErrorCode.fromWire(e.code),
        message: e.message,
      );
    }
  }
}
