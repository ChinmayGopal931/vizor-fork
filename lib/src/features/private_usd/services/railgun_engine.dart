import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/railgun_models.dart';
import 'railgun_host_channel.dart';

/// What opening one account's Railgun wallet needs: the page's `start`, the
/// wallet's `openWallet` (its mnemonic), and the `0zk` address Rust derives
/// for it. Drop it as soon as `openWallet` is sent.
class RailgunWalletOpening {
  const RailgunWalletOpening({
    required this.start,
    required this.wallet,
    required this.expectedAddress,
    this.secrets = const [],
  });

  final RailgunStartParams start;
  final RailgunOpenWalletParams wallet;
  final String expectedAddress;

  /// The keyed RPC URLs in [start], to redact from debug output.
  final List<String> secrets;

  @override
  String toString() => 'RailgunWalletOpening(${start.network})';
}

/// Derives what [RailgunEngine] opens for an account. Throws while the
/// wallet is locked, or when the account cannot use Private USD.
abstract interface class RailgunWalletSource {
  Future<RailgunWalletOpening> prepare(String accountUuid);
}

/// The engine closed the page under a running use: a lock, an account
/// switch, a route change, the idle close or a wallet change. Nothing
/// failed; the next use reopens the page.
class RailgunEngineInterruptedException implements Exception {
  const RailgunEngineInterruptedException();

  @override
  String toString() => 'The Railgun page closed.';
}

/// Uses are refused while an account deletion or a reset drains the engine.
class RailgunEngineUnavailableException implements Exception {
  const RailgunEngineUnavailableException();

  @override
  String toString() => 'The Railgun engine is not available right now.';
}

/// The page opened a wallet whose address is not the one Rust derives for the
/// account (plan §3.5, invariant 19). The page is closed; nothing is used.
class RailgunAddressMismatchException implements Exception {
  const RailgunAddressMismatchException();

  @override
  String toString() =>
      "The Railgun page opened another wallet than this account's.";
}

enum RailgunEnginePhase { idle, starting, syncing, proving, ready, failed }

/// Balances as one sync of [accountUuid]'s wallet at [address] found them.
class RailgunSync {
  const RailgunSync({
    required this.accountUuid,
    required this.address,
    required this.balances,
    required this.at,
  });

  final String accountUuid;
  final String address;
  final RailgunBalances balances;
  final DateTime at;
}

/// What the engine is doing, for progress lines. It carries no messages: an
/// engine error can quote a keyed RPC URL.
class RailgunEngineState {
  const RailgunEngineState({
    this.phase = RailgunEnginePhase.idle,
    this.accountUuid,
    this.address,
    this.fees,
    this.utxoScan,
    this.txidScan,
    this.proof,
    this.lastSync,
    this.failure,
  });

  final RailgunEnginePhase phase;

  /// Whose wallet the page holds or is opening.
  final String? accountUuid;
  final String? address;
  final RailgunFees? fees;
  final RailgunScanEvent? utxoScan;
  final RailgunScanEvent? txidScan;
  final RailgunProofEvent? proof;

  /// The last sync any use made: balances, conversions or sends.
  final RailgunSync? lastSync;

  /// The host's code when the last use failed in the page.
  final RailgunHostErrorCode? failure;

  RailgunEngineState copyWith({
    RailgunEnginePhase? phase,
    RailgunScanEvent? utxoScan,
    RailgunScanEvent? txidScan,
    RailgunProofEvent? proof,
    RailgunSync? lastSync,
    bool clearScans = false,
    bool clearProof = false,
  }) => RailgunEngineState(
    phase: phase ?? this.phase,
    accountUuid: accountUuid,
    address: address,
    fees: fees,
    utxoScan: clearScans ? null : (utxoScan ?? this.utxoScan),
    txidScan: clearScans ? null : (txidScan ?? this.txidScan),
    proof: clearProof ? null : (proof ?? this.proof),
    lastSync: lastSync ?? this.lastSync,
    failure: failure,
  );
}

/// The Railgun page, one use at a time, for whichever account a use asks
/// for (plan reference §6.3, §8.4). It lives outside the widget tree.
///
/// - Opening is: bridge start, page `load` on its port, `start`,
///   `openWallet`, then the address check against Rust.
/// - Every close is the page's `close`, then the bridge's stop: a running
///   bridge is a no-auth loopback proxy, so it runs only with a page.
/// - [close] interrupts a running use at once (lock, account switch, route
///   change); the next use reopens the page, on a new bridge.
/// - After [idleClose] without a use, the page closes by itself.
/// - Built once per process, it first closes whatever page and bridge an
///   earlier Flutter engine left running.
///
/// Never log a call's params or results, or a page failure's message: `start`
/// can carry keyed RPC URLs and `openWallet` the wallet's mnemonic.
class RailgunEngine {
  RailgunEngine({
    required RailgunHost host,
    required RailgunWalletSource wallets,
    required Future<int> Function() startBridge,
    required Future<void> Function() stopBridge,
    this.debugPage = false,
    this.idleClose = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _host = host,
       _wallets = wallets,
       _startBridge = startBridge,
       _stopBridge = stopBridge,
       _now = now ?? DateTime.now {
    _events = _host.events.listen(_onEvent, onError: (Object _) {});
    // The page and its bridge can outlive a Flutter engine whose Activity
    // Android destroyed without finishing it.
    unawaited(_lock.run(_shutdown));
  }

  final RailgunHost _host;
  final RailgunWalletSource _wallets;
  final Future<int> Function() _startBridge;
  final Future<void> Function() _stopBridge;
  final DateTime Function() _now;

  /// Whether the page may be inspected and send `log` events (debug builds).
  final bool debugPage;
  final Duration idleClose;

  final _lock = _SerialLock();
  final state = ValueNotifier(const RailgunEngineState());
  late final StreamSubscription<String> _events;

  RailgunSession? _session;
  Timer? _idleTimer;

  // Bumped by every close; a use or an open from an older epoch is stale.
  int _epoch = 0;
  int _pauseDepth = 0;
  bool _disposed = false;

  bool get isPaused => _pauseDepth > 0;

  /// Runs [use] on [accountUuid]'s open wallet, opening it first if needed.
  /// Uses run one at a time.
  Future<T> withSession<T>(
    String accountUuid,
    Future<T> Function(RailgunSession session) use,
  ) {
    if (_disposed || isPaused) {
      return Future.error(const RailgunEngineUnavailableException());
    }
    return _lock.run(() async {
      if (_disposed || isPaused) {
        throw const RailgunEngineUnavailableException();
      }
      _idleTimer?.cancel();
      final epoch = _epoch;
      try {
        final session = await _sessionFor(accountUuid);
        return await use(session);
      } on RailgunHostException catch (e) {
        if (epoch != _epoch) throw const RailgunEngineInterruptedException();
        _fail(e.code);
        // The page is gone, so its bridge goes too.
        if (e.code.pageGone || e.code == RailgunHostErrorCode.unavailable) {
          await _forget();
        }
        rethrow;
      } on RailgunEngineInterruptedException {
        rethrow;
      } catch (_) {
        if (epoch != _epoch) throw const RailgunEngineInterruptedException();
        _fail(null);
        rethrow;
      } finally {
        _armIdleClose();
      }
    });
  }

  /// Syncs [accountUuid]'s wallet to the chain's tip and reads its balances.
  Future<RailgunSync> sync(String accountUuid) =>
      withSession(accountUuid, (session) async {
        final balances = await session.refresh();
        final sync = RailgunSync(
          accountUuid: accountUuid,
          address: session.address,
          balances: balances,
          at: _now(),
        );
        _publish(state.value.copyWith(lastSync: sync));
        return sync;
      });

  /// Closes the page and stops its bridge now, interrupting a running use.
  /// The next use reopens it. For lock, an account switch and route changes.
  Future<void> close() async {
    _invalidate();
    await _shutdown();
  }

  /// Closes the page and deletes everything the page origin stored, every
  /// account's wallet included. For a full wallet reset.
  Future<void> wipe() async {
    _invalidate(forget: true);
    try {
      await _host.wipe();
    } finally {
      await _stopBridgeQuietly();
    }
  }

  /// Refuses new uses, closes the page and waits (at most [timeout]) for the
  /// running use to end. Pair with [resume], also when the caller fails.
  Future<void> quiesceAndDrain({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _pauseDepth++;
    await close();
    try {
      await _lock.run(() async {}).timeout(timeout);
    } on TimeoutException {
      _debugLog('drain timed out');
    }
  }

  void resume() {
    if (_pauseDepth > 0) _pauseDepth--;
  }

  /// Stops listening; the page and bridge close. [state] stays readable.
  Future<void> dispose() async {
    _disposed = true;
    await _events.cancel();
    await close();
  }

  Future<RailgunSession> _sessionFor(String accountUuid) async {
    final current = _session;
    if (current != null &&
        current.accountUuid == accountUuid &&
        current._epoch == _epoch) {
      if (await _host.isOpen()) return current;
    }
    if (current != null) {
      // Another account's wallet (one per page), or a page that died.
      await _forget();
    }
    return _open(accountUuid);
  }

  Future<RailgunSession> _open(String accountUuid) async {
    final epoch = _epoch;
    _publish(
      RailgunEngineState(
        phase: RailgunEnginePhase.starting,
        accountUuid: accountUuid,
        lastSync: state.value.lastSync,
      ),
    );
    RailgunSession? opened;
    try {
      RailgunWalletOpening? opening = await _wallets.prepare(accountUuid);
      final expected = opening.expectedAddress;
      final secrets = opening.secrets;
      _ensureCurrent(epoch);
      final port = await _startBridge();
      _ensureCurrent(epoch);
      await _host.load(proxyPort: port, debug: debugPage);
      _ensureCurrent(epoch);
      final started = RailgunStartResult.parse(
        _decode(await _host.call('start', opening.start.toJson())),
      );
      _ensureCurrent(epoch);
      // The mnemonic is a Dart string, which cannot be zeroed: hold it no
      // longer than the call.
      String? walletParams = opening.wallet.toJson();
      opening = null;
      final walletResult = await _host.call('openWallet', walletParams);
      walletParams = null;
      final wallet = RailgunOpenWalletResult.parse(_decode(walletResult));
      _ensureCurrent(epoch);
      if (wallet.address != expected) {
        throw const RailgunAddressMismatchException();
      }
      opened = RailgunSession._(
        this,
        accountUuid: accountUuid,
        address: wallet.address,
        fees: started.fees,
        epoch: epoch,
        secrets: secrets,
      );
      _session = opened;
      _publish(
        RailgunEngineState(
          phase: RailgunEnginePhase.ready,
          accountUuid: accountUuid,
          address: wallet.address,
          fees: started.fees,
          utxoScan: state.value.utxoScan,
          txidScan: state.value.txidScan,
          lastSync: state.value.lastSync,
        ),
      );
      return opened;
    } finally {
      if (opened == null) await _shutdown();
    }
  }

  Future<String> _call(RailgunSession session, String method, String params) {
    if (!identical(_session, session) || session._epoch != _epoch) {
      return Future.error(const RailgunEngineInterruptedException());
    }
    return _host.call(method, params);
  }

  void _ensureCurrent(int epoch) {
    if (epoch != _epoch || _disposed || isPaused) {
      throw const RailgunEngineInterruptedException();
    }
  }

  void _invalidate({bool forget = false}) {
    _epoch++;
    _session = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_disposed) return;
    _publish(
      forget
          ? const RailgunEngineState()
          : RailgunEngineState(lastSync: state.value.lastSync),
    );
  }

  // The page is gone or about to be: drop the session and stop its bridge.
  Future<void> _forget() async {
    _session = null;
    await _shutdown();
  }

  // Every close is the page's, then the bridge's.
  Future<void> _shutdown() async {
    try {
      await _host.close();
    } catch (e) {
      _debugLog('closing the page failed: ${_describe(e)}');
    }
    await _stopBridgeQuietly();
  }

  Future<void> _stopBridgeQuietly() async {
    try {
      await _stopBridge();
    } catch (e) {
      _debugLog('stopping the bridge failed: ${e.runtimeType}');
    }
  }

  void _armIdleClose() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_session == null || _disposed) return;
    final epoch = _epoch;
    _idleTimer = Timer(idleClose, () {
      unawaited(
        _lock.run(() async {
          if (epoch != _epoch || _session == null) return;
          await close();
        }),
      );
    });
  }

  void _onEvent(String raw) {
    if (_disposed || state.value.accountUuid == null) return;
    switch (RailgunEvent.decode(raw)) {
      case final RailgunScanEvent scan:
        _publish(
          scan.tree == RailgunMerkletree.utxo
              ? state.value.copyWith(utxoScan: scan)
              : state.value.copyWith(txidScan: scan),
        );
      case final RailgunProofEvent proof:
        _publish(state.value.copyWith(proof: proof));
      // Page lines can quote anything the engine saw: never printed here.
      case RailgunLogEvent() || null:
        break;
    }
  }

  void _fail(RailgunHostErrorCode? code) {
    final current = state.value;
    _publish(
      RailgunEngineState(
        phase: RailgunEnginePhase.failed,
        accountUuid: current.accountUuid,
        address: current.address,
        fees: current.fees,
        lastSync: current.lastSync,
        failure: code,
      ),
    );
    if (code != null) _debugLog('a page call failed: ${code.name}');
  }

  void _publish(RailgunEngineState next) {
    if (_disposed) return;
    state.value = next;
  }

  Object? _decode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw const RailgunProtocolException('the result is not JSON');
    }
  }

  String _describe(Object error) => switch (error) {
    RailgunHostException(:final code) => code.name,
    _ => '${error.runtimeType}',
  };

  void _debugLog(String line) {
    if (kDebugMode) debugPrint('RailgunEngine: $line');
  }
}

/// One page's open wallet. Every call fails with
/// [RailgunEngineInterruptedException] once the engine closed the page.
class RailgunSession {
  RailgunSession._(
    this._engine, {
    required this.accountUuid,
    required this.address,
    required this.fees,
    required int epoch,
    required List<String> secrets,
  }) : _epoch = epoch,
       _secrets = secrets;

  final RailgunEngine _engine;
  final String accountUuid;

  /// The wallet's `0zk` address, checked against Rust's.
  final String address;
  final RailgunFees fees;
  final int _epoch;
  final List<String> _secrets;

  /// The keyed RPC URLs this page started with, to redact debug output.
  List<String> get secrets => _secrets;

  /// Syncs to the chain's tip, asks the screening nodes about new notes, and
  /// returns the balances. A first sync reads all of Railgun's history.
  Future<RailgunBalances> refresh() async {
    _engine._publish(
      _engine.state.value.copyWith(
        phase: RailgunEnginePhase.syncing,
        clearScans: true,
      ),
    );
    final balances = RailgunBalances.parse(
      _engine._decode(await _engine._call(this, 'refresh', '{}')),
    );
    _engine._publish(
      _engine.state.value.copyWith(phase: RailgunEnginePhase.ready),
    );
    return balances;
  }

  /// What [broadcaster] charges to send [transfer]; nothing is proved.
  Future<BigInt> broadcasterFee(
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
  ) async {
    final result = _engine._decode(
      await _engine._call(
        this,
        'broadcasterFee',
        jsonEncode({
          'to': transfer.to.text,
          'token': transfer.token,
          'amount': transfer.amount.toString(),
          'broadcaster': broadcaster.toWire(),
        }),
      ),
    );
    final fee = result is Map<String, dynamic> ? result['fee'] : null;
    if (fee is! String || BigInt.tryParse(fee) == null || fee.startsWith('-')) {
      throw const RailgunProtocolException('the fee is unreadable');
    }
    return BigInt.parse(fee);
  }

  /// Proves [transfer] for [broadcaster] to send, with a fee note of [fee]
  /// first; nothing is sent. A result that is not a `transact` call for the
  /// broadcaster is refused.
  Future<RailgunRelayedProof> prove(
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
    BigInt fee,
  ) async {
    _engine._publish(
      _engine.state.value.copyWith(
        phase: RailgunEnginePhase.proving,
        clearProof: true,
      ),
    );
    final method = switch (transfer.to) {
      RailgunPrivateDestination() => 'transfer',
      RailgunPublicDestination() => 'unshield',
    };
    final result = await _engine._call(
      this,
      method,
      jsonEncode({
        'to': transfer.to.text,
        'token': transfer.token,
        'amount': transfer.amount.toString(),
        'fee': fee.toString(),
        'broadcaster': broadcaster.toWire(),
      }),
    );
    final proof = RailgunRelayedProof.parse(
      _engine._decode(result),
      broadcaster: broadcaster,
    );
    _engine._publish(
      _engine.state.value.copyWith(phase: RailgunEnginePhase.ready),
    );
    return proof;
  }

  Future<RailgunReverseCost> reverseCost(
    RailgunReverseCostRequest request,
  ) async => RailgunReverseCost.parse(
    _engine._decode(await _engine._call(this, 'reverseCost', request.toJson())),
  );

  Future<RailgunReverseTransaction> prepareReverse(
    RailgunReverseRequest request,
  ) async => RailgunReverseTransaction.parse(
    _engine._decode(
      await _engine._call(this, 'prepareReverse', request.toJson()),
    ),
    relayAdapt: request.relayAdapt,
  );
}

class _SerialLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
