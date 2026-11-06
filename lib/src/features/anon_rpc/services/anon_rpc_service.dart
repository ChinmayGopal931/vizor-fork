import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/config/private_usd_feature_config.dart'
    show privateUsdLog;
import '../../../rust/api/anon_rpc.dart' as rust_anon_rpc;
import '../../../rust/api/anon_rpc.dart'
    show ApiAnonRpcHeader, ApiAnonRpcRequest;
import '../../private_usd/services/railgun_host_channel.dart'
    show RailgunHostErrorCode, RailgunHostException;
import '../anon_rpc_network.dart';
import 'anon_rpc_host_channel.dart';

/// Where the worker stands: no worker yet, one starting (the bundle's
/// download and hash check, then Tor's bootstrap or a mixnet's), one ready,
/// or one that failed and is retried at the next request after a pause.
enum AnonRpcPhase { idle, starting, ready, failed }

@immutable
class AnonRpcStatus {
  const AnonRpcStatus({
    this.phase = AnonRpcPhase.idle,
    this.network,
    this.lastError,
    this.bootstrap,
  });

  final AnonRpcPhase phase;
  final AnonRpcNetwork? network;

  /// A code or a redacted reason, never a URL.
  final String? lastError;

  /// How long the worker took to report ready.
  final Duration? bootstrap;

  AnonRpcStatus copyWith({
    AnonRpcPhase? phase,
    AnonRpcNetwork? network,
    String? lastError,
    bool clearError = false,
    Duration? bootstrap,
  }) => AnonRpcStatus(
    phase: phase ?? this.phase,
    network: network ?? this.network,
    lastError: clearError ? null : (lastError ?? this.lastError),
    bootstrap: bootstrap ?? this.bootstrap,
  );
}

/// Rust's side of the gateway (`rust/src/anon_rpc.rs`), behind one object so
/// tests can stand in for it.
class AnonRpcGateway {
  const AnonRpcGateway();

  Stream<ApiAnonRpcRequest> requests() => rust_anon_rpc.anonRpcRequests();

  void disconnect() => rust_anon_rpc.anonRpcDisconnect();

  bool respond({
    required BigInt id,
    required int status,
    required List<ApiAnonRpcHeader> headers,
    required List<int> body,
  }) => rust_anon_rpc.anonRpcRespond(
    id: id,
    status: status,
    headers: headers,
    body: body,
  );

  bool fail({
    required BigInt id,
    required String message,
    required bool blocked,
  }) => rust_anon_rpc.anonRpcFail(id: id, message: message, blocked: blocked);
}

/// Thrown inside the service when no worker can carry a request now.
class _WorkerUnavailable implements Exception {
  const _WorkerUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'anonymous RPC unavailable: $reason';
}

/// Serves Rust's anonymous RPC requests through the anon-rpc page: while the
/// app is in the foreground and unlocked it listens on the request stream,
/// opens the page and starts the worker at the first request, and answers
/// each through the worker's `fetch`. Paused, it disconnects, so Rust fails
/// every request closed at once; nothing here ever makes a request another
/// way.
///
/// Never log a request: its URL may carry an RPC key.
class AnonRpcService {
  AnonRpcService({
    required AnonRpcHost host,
    required Future<AnonRpcNetwork> Function() networkOf,
    AnonRpcGateway gateway = const AnonRpcGateway(),
    this.debug = false,
    this.retryAfter = const Duration(seconds: 15),
    DateTime Function()? now,
  }) : _host = host,
       _networkOf = networkOf,
       _gateway = gateway,
       _now = now ?? DateTime.now {
    _events = _host.events.listen(_onEvent, onError: (Object _) {});
  }

  final AnonRpcHost _host;
  final Future<AnonRpcNetwork> Function() _networkOf;
  final AnonRpcGateway _gateway;

  /// Whether the page may be inspected and send `log` events (debug builds).
  final bool debug;

  /// How long a failed worker rests before a request starts it again.
  final Duration retryAfter;
  final DateTime Function() _now;

  final status = ValueNotifier(const AnonRpcStatus());
  late final StreamSubscription<String> _events;
  StreamSubscription<ApiAnonRpcRequest>? _requests;

  // The worker being started, so concurrent requests share one start.
  Future<void>? _opening;
  bool _workerReady = false;
  DateTime? _retryAt;

  // Bumped by every close; a start from an older epoch is stale.
  int _epoch = 0;
  bool _disposed = false;

  /// Whether requests are being served.
  bool get isListening => _requests != null;

  /// Listens for Rust's requests: the app is in the foreground and unlocked.
  void start() {
    if (_disposed || _requests != null) return;
    try {
      _requests = _gateway.requests().listen(
        (request) => unawaited(_serve(request)),
        onError: (Object error) {
          privateUsdLog(
            'anon rpc: the request stream failed: ${error.runtimeType}',
          );
        },
      );
    } catch (e) {
      // No Rust in this process (a widget test): nothing to serve.
      privateUsdLog('anon rpc: no request stream: ${e.runtimeType}');
    }
  }

  /// Stops listening, so Rust fails every request closed at once. With
  /// [closePage] the page and its worker go too (a lock).
  Future<void> pause({bool closePage = false}) async {
    final requests = _requests;
    _requests = null;
    await requests?.cancel();
    _gateway.disconnect();
    if (closePage) await _closeWorker();
  }

  /// The network changed: the next request starts the new worker.
  Future<void> restart() => _closeWorker();

  /// Starts the worker if none is ready, and waits for it. The Railgun page
  /// opens only once its requests have a path, so its proxy override never
  /// lands on the worker's own bootstrap. Fails as the page host does, so
  /// the engine reports it like any other failure to open.
  Future<void> ensureReady() async {
    try {
      await _ensureWorker();
    } on _WorkerUnavailable catch (e) {
      throw RailgunHostException(
        RailgunHostErrorCode.failed,
        message: 'anonymous RPC: ${e.reason}',
      );
    }
  }

  /// Stops listening; the page closes. [status] stays readable.
  Future<void> dispose() async {
    _disposed = true;
    await pause(closePage: true);
    await _events.cancel();
  }

  Future<void> _serve(ApiAnonRpcRequest request) async {
    final id = request.id;
    try {
      await _ensureWorker();
      final answer = jsonDecode(
        await _host.call(
          'fetch',
          jsonEncode({
            'url': request.url,
            'method': request.method,
            'headers': [
              for (final header in request.headers) [header.name, header.value],
            ],
            'bodyBase64': base64Encode(request.body),
            'isolationKey': request.isolationKey,
            'timeoutMs': request.timeoutMs.toInt(),
          }),
        ),
      );
      if (answer is! Map<String, Object?>) {
        throw const FormatException('the page answered without an object');
      }
      if (answer['ok'] == true) {
        final headers = <ApiAnonRpcHeader>[
          for (final header in answer['headers'] as List<Object?>)
            if (header is List<Object?> && header.length == 2)
              ApiAnonRpcHeader(
                name: header[0].toString(),
                value: header[1].toString(),
              ),
        ];
        _gateway.respond(
          id: id,
          status: answer['status'] as int,
          headers: headers,
          body: base64Decode(answer['bodyBase64'] as String),
        );
        return;
      }
      final code = answer['code'] as String? ?? 'FETCH_FAILED';
      // The worker itself failed, or never started: the path is down until
      // the next start, and Rust waits it out as a route problem.
      final blocked = code == 'NOT_STARTED' || code == 'WORKER_FAILED';
      if (code == 'WORKER_FAILED') _workerFailed(code);
      _gateway.fail(id: id, message: 'anonymous RPC: $code', blocked: blocked);
    } on RailgunHostException catch (e) {
      if (e.code.pageGone || e.code == RailgunHostErrorCode.unavailable) {
        _workerFailed(e.code.name);
      }
      _gateway.fail(
        id: id,
        message: 'anonymous RPC page: ${e.code.name}',
        blocked: true,
      );
    } on _WorkerUnavailable catch (e) {
      _gateway.fail(id: id, message: e.toString(), blocked: true);
    } catch (e) {
      privateUsdLog('anon rpc: a request failed: ${e.runtimeType}');
      _gateway.fail(
        id: id,
        message: 'anonymous RPC: ${e.runtimeType}',
        blocked: !_workerReady,
      );
    }
  }

  Future<void> _ensureWorker() {
    if (_workerReady) return Future.value();
    final retryAt = _retryAt;
    if (retryAt != null && _now().isBefore(retryAt)) {
      return Future.error(
        const _WorkerUnavailable('the worker failed; retrying soon'),
      );
    }
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<void> _open() async {
    final epoch = _epoch;
    final network = await _networkOf();
    final specifier = network.specifier;
    final bootstrapRpcUrl = network.bootstrapRpcUrl;
    if (!network.anonymizes || specifier == null || bootstrapRpcUrl == null) {
      throw const _WorkerUnavailable('anonymous RPC is off');
    }
    _publish(AnonRpcStatus(phase: AnonRpcPhase.starting, network: network));
    final started = _now();
    try {
      await _host.load(debug: debug);
      _ensureCurrent(epoch);
      _step(network, 'page loaded', started);
      await _host.call(
        'start',
        jsonEncode({
          'specifier': specifier,
          'bootstrapRpcUrl': bootstrapRpcUrl,
          'config': network.config,
          'debug': debug,
        }),
      );
      _ensureCurrent(epoch);
      _step(network, 'worker verified and started', started);
      await _host.call('awaitReady', '{}');
      _ensureCurrent(epoch);
      _workerReady = true;
      _retryAt = null;
      final bootstrap = _now().difference(started);
      _publish(
        AnonRpcStatus(
          phase: AnonRpcPhase.ready,
          network: network,
          bootstrap: bootstrap,
        ),
      );
      privateUsdLog(
        'anon rpc: ${network.name} ready in ${bootstrap.inMilliseconds} ms',
      );
    } on RailgunHostException catch (e) {
      // Debug builds only; the page redacts URLs from the worker's lines.
      privateUsdLog(
        'anon rpc: ${network.name} failed to start (${e.code.name}): '
        '${e.debugMessage()}',
      );
      if (epoch == _epoch) {
        _retryAt = _now().add(retryAfter);
        _publish(
          status.value.copyWith(
            phase: AnonRpcPhase.failed,
            lastError: e.code.name,
          ),
        );
      }
      throw _WorkerUnavailable(e.code.name);
    }
  }

  // Debug builds only: a start's progress, with no URL in it.
  void _step(AnonRpcNetwork network, String what, DateTime started) {
    if (!debug) return;
    privateUsdLog(
      'anon rpc: ${network.name} $what in '
      '${_now().difference(started).inMilliseconds} ms',
    );
  }

  void _ensureCurrent(int epoch) {
    if (epoch != _epoch || _disposed) {
      throw const _WorkerUnavailable('the page closed');
    }
  }

  void _workerFailed(String reason) {
    _workerReady = false;
    _retryAt = _now().add(retryAfter);
    _publish(
      status.value.copyWith(phase: AnonRpcPhase.failed, lastError: reason),
    );
  }

  Future<void> _closeWorker() async {
    _epoch++;
    _workerReady = false;
    _retryAt = null;
    try {
      await _host.close();
    } catch (e) {
      privateUsdLog('anon rpc: closing the page failed: ${e.runtimeType}');
    }
    _publish(const AnonRpcStatus());
  }

  void _onEvent(String raw) {
    if (_disposed) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    final data = decoded['data'];
    switch (decoded['event']) {
      case 'status':
        if (data is Map<String, Object?> &&
            data['phase'] == 'failed' &&
            _workerReady) {
          _workerFailed('WORKER_FAILED');
        }
      case 'log':
        if (debug && data is String) privateUsdLog('anon page: $data');
    }
  }

  void _publish(AnonRpcStatus next) {
    if (_disposed) return;
    status.value = next;
  }
}
