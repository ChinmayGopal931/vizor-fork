import 'package:flutter/services.dart';

import '../../private_usd/services/railgun_host_channel.dart'
    show RailgunHostErrorCode, RailgunHostException;

/// Asks the platform whether it hosts the anon-rpc page: Android does; iOS
/// and desktop have no handler yet, so no. Any failure means no.
Future<bool> queryAnonRpcHostSupported({
  MethodChannel channel = const MethodChannel(
    AnonRpcHostChannel.methodChannelName,
  ),
}) async {
  try {
    return await channel.invokeMethod<bool>('supported') ?? false;
  } catch (_) {
    return false;
  }
}

/// The platform's anon-rpc page host (Kotlin's `AnonRpcHostHandler`): the
/// hidden page that runs the anon-rpc browser harness. One page at a time,
/// process-wide. Its errors are the Railgun host's codes.
abstract interface class AnonRpcHost {
  /// Loads a fresh page (closing any previous one); returns once the page
  /// says it is ready.
  Future<void> load({required bool debug});

  /// Calls [method] with one JSON object of params; returns the raw JSON
  /// result. A `fetch` carries the RPC URL: never log [paramsJson].
  Future<String> call(String method, String paramsJson);

  /// Closes the page. Idempotent.
  Future<void> close();

  Future<bool> isOpen();

  /// The page's raw `{event, data}` messages: `status`, and `log` from a page
  /// loaded with `debug` in a debug build.
  Stream<String> get events;
}

/// [AnonRpcHost] over `com.zcash.wallet/anon_rpc`.
class AnonRpcHostChannel implements AnonRpcHost {
  const AnonRpcHostChannel({
    MethodChannel methods = const MethodChannel(methodChannelName),
    EventChannel eventChannel = const EventChannel(eventChannelName),
  }) : _methods = methods,
       _eventChannel = eventChannel;

  static const methodChannelName = 'com.zcash.wallet/anon_rpc';
  static const eventChannelName = 'com.zcash.wallet/anon_rpc/events';

  final MethodChannel _methods;
  final EventChannel _eventChannel;

  @override
  Future<void> load({required bool debug}) =>
      _hosted(() => _invoke<void>('load', {'debug': debug}));

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

  @override
  Future<void> close() async {
    try {
      await _invoke<void>('close');
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

  // No host on this platform: the page cannot run here.
  Future<T> _hosted<T>(Future<T> Function() invoke) async {
    try {
      return await invoke();
    } on MissingPluginException {
      throw RailgunHostException(RailgunHostErrorCode.unavailable);
    }
  }

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
