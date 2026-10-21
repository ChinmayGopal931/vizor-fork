import 'dart:async';
import 'dart:math';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/storage/wallet_paths.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_messages.dart';
import '../models/private_usd_send.dart';
import '../models/railgun_models.dart';
import '../private_usd_copy.dart';
import 'private_usd_engine.dart';
import 'private_usd_spend_guard.dart';
import 'private_usd_swap_backend.dart';
import 'railgun_engine.dart';

/// The relayer's fee is above the deployment's cap: nothing is proved.
class PrivateUsdSendFeeCapException implements Exception {
  const PrivateUsdSendFeeCapException();

  @override
  String toString() => "The relayer's fee is above the cap.";
}

/// The Rust send calls for this wallet; tests fake them. Nothing here takes
/// a key: the page proves with the wallet it opened, and Rust posts only
/// bytes it kept.
abstract interface class PrivateUsdSendBackend {
  /// The relayer's `railgunSends` terms, held to the pins and the cap.
  Future<rust.ApiRailgunSendsTerms> terms();

  /// Keeps a proved send before anything is posted. [stillCurrent] is asked
  /// right before the call, after the last await: a proof that finished
  /// after a lock, in the background or after a drain is never kept.
  Future<rust.ApiSendRecord> put(
    String accountUuid,
    rust.ApiProvedSend send, {
    required bool Function() stillCurrent,
  });

  /// The account's sends, newest first; empty for a wallet that never sent.
  Future<List<rust.ApiSendRecord>> list(String accountUuid);

  /// Posts [sendId]'s kept bytes (never bytes from Dart).
  Future<rust.ApiTransactResult> transact(String accountUuid, String sendId);

  /// One settlement pass; the rows after it.
  Future<List<rust.ApiSendRecord>> settleAll(String accountUuid);
}

/// [PrivateUsdSendBackend] over the FRB calls, with this wallet's context.
class RustPrivateUsdSendBackend implements PrivateUsdSendBackend {
  RustPrivateUsdSendBackend(this._context);

  final PrivateUsdSwapContext Function() _context;

  @override
  Future<rust.ApiRailgunSendsTerms> terms() =>
      rust.privateUsdRailgunSendsTerms(network: _context().network);

  @override
  Future<rust.ApiSendRecord> put(
    String accountUuid,
    rust.ApiProvedSend send, {
    required bool Function() stillCurrent,
  }) async {
    final network = _context().network;
    final storeDir = await getPrivateUsdDirPath(network);
    // Asked after the last await: nothing can lock between it and the call.
    if (!stillCurrent()) throw const PrivateUsdStaleStepException();
    return rust.privateUsdSendLogPut(
      storeDir: storeDir,
      network: network,
      accountUuid: accountUuid,
      send: send,
    );
  }

  @override
  Future<List<rust.ApiSendRecord>> list(String accountUuid) async {
    final storeDir = await getExistingPrivateUsdDirPath(_context().network);
    if (storeDir == null) return const [];
    return rust.privateUsdSendLogList(
      storeDir: storeDir,
      accountUuid: accountUuid,
    );
  }

  @override
  Future<rust.ApiTransactResult> transact(
    String accountUuid,
    String sendId,
  ) async {
    final network = _context().network;
    final storeDir = await getPrivateUsdDirPath(network);
    return rust.privateUsdRelayerTransact(
      storeDir: storeDir,
      network: network,
      accountUuid: accountUuid,
      sendId: sendId,
    );
  }

  @override
  Future<List<rust.ApiSendRecord>> settleAll(String accountUuid) async {
    final context = _context();
    final storeDir = await getExistingPrivateUsdDirPath(context.network);
    if (storeDir == null) return const [];
    return rust.privateUsdSendSettleAll(
      storeDir: storeDir,
      network: context.network,
      // A secret: never log it.
      ethRpcUrl: await context.ethRpcUrl(),
      accountUuid: accountUuid,
    );
  }
}

/// The Railgun page's calls a send needs: Railgun's fees, the relayer's fee
/// for a transfer, the proof, and a sync. Tests fake it.
abstract interface class PrivateUsdSendPage {
  Future<RailgunFees> fees(String accountUuid);

  /// What [broadcaster] charges to send [transfer]; nothing is proved.
  Future<BigInt> broadcasterFee(
    String accountUuid,
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
  );

  /// Proves [transfer] (`transfer` to a `0zk`, `unshield` to a `0x`) for
  /// [broadcaster] with a fee note of [fee]; up to 10 minutes, `proof`
  /// events meanwhile. Nothing is sent.
  Future<RailgunRelayedProof> prove(
    String accountUuid,
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
    BigInt fee,
  );

  /// Syncs the wallet, so the balance follows the send.
  Future<void> sync(String accountUuid);
}

/// [PrivateUsdSendPage] over the app's [RailgunEngine].
class RailgunSendPage implements PrivateUsdSendPage {
  const RailgunSendPage(this._railgun);

  final RailgunEngine _railgun;

  @override
  Future<RailgunFees> fees(String accountUuid) =>
      _railgun.withSession(accountUuid, (session) async => session.fees);

  @override
  Future<BigInt> broadcasterFee(
    String accountUuid,
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
  ) => _railgun.withSession(
    accountUuid,
    (session) => session.broadcasterFee(transfer, broadcaster),
  );

  @override
  Future<RailgunRelayedProof> prove(
    String accountUuid,
    RailgunTransfer transfer,
    RailgunBroadcaster broadcaster,
    BigInt fee,
  ) => _railgun.withSession(
    accountUuid,
    (session) => session.prove(transfer, broadcaster, fee),
  );

  @override
  Future<void> sync(String accountUuid) => _railgun.sync(accountUuid);
}

/// A fee the relayer asks now, and the terms it was worked out from, which
/// a proof paying it is made for.
class _Quote {
  const _Quote(this.broadcaster, this.cost);

  final RailgunBroadcaster broadcaster;
  final PrivateUsdSendCost cost;

  BigInt get fee => cost.networkFee;
}

/// Sends from the private balance through the deployment's relayer: price,
/// prove, keep, then post.
///
/// - Nothing is proved for a fee above the one the user confirmed, or above
///   the deployment's cap (any fee, without one).
/// - Keep before post: the page's proof goes to Rust (`send_log_put`) only
///   while the app is still unlocked, in the foreground and at the engine's
///   epoch of the tap ([PrivateUsdEngine.isCurrent], asked right before the
///   call); a proof that lands later is dropped and nothing was sent. Rust
///   then posts the kept bytes (`relayer_transact`), never bytes from Dart.
/// - Once a proof is kept it is never proved again: after a crash,
///   settlement posts the same bytes.
/// - After a `sent` answer it settles every [landingPoll] for up to
///   [landingWait], only while the app may run.
///
/// It never logs a request, a proof, an amount, an address or the RPC URL.
class PrivateUsdSender {
  PrivateUsdSender({
    required PrivateUsdEngine engine,
    required PrivateUsdSendPage page,
    required PrivateUsdSendBackend backend,
    required PrivateUsdSpendGuard guard,
    required BigInt? maxRelayerFee,
    DateTime Function()? now,
    this.landingPoll = const Duration(seconds: 4),
    this.landingWait = const Duration(minutes: 2),
    String Function()? newSendId,
  }) : _engine = engine,
       _page = page,
       _backend = backend,
       _guard = guard,
       _maxRelayerFee = maxRelayerFee,
       _now = now ?? DateTime.now,
       _newSendId = newSendId ?? _uuidV4;

  final PrivateUsdEngine _engine;
  final PrivateUsdSendPage _page;
  final PrivateUsdSendBackend _backend;
  final PrivateUsdSpendGuard _guard;
  final BigInt? _maxRelayerFee;
  final DateTime Function() _now;
  final String Function() _newSendId;
  final Duration landingPoll;
  final Duration landingWait;

  /// A proof is held this long before the relayer must still hold its fee.
  static const provingTime = Duration(minutes: 2);

  final _running = <Future<void>>{};
  bool _quiesced = false;

  bool get _canRun => !_quiesced && _engine.canRun;

  // Without a cap from the deployment, no fee is within it.
  bool _aboveCap(BigInt fee) {
    final cap = _maxRelayerFee;
    return cap == null || fee > cap;
  }

  /// The relayer's terms as the page's broadcaster `B`.
  Future<RailgunBroadcaster> broadcaster() async {
    final terms = await _backend.terms();
    return RailgunBroadcaster(
      chainId: terms.chainId,
      railgunProxy: terms.railgunProxy,
      railgunAddress: terms.railgunAddress,
      feeToken: terms.token.toLowerCase(),
      minFee: BigInt.parse(terms.feeFloor),
      maxGasPrice: BigInt.parse(terms.maxGasPriceWei),
      feePerUnitGas: switch (terms.feePerUnitGas) {
        final rate? => BigInt.parse(rate),
        null => null,
      },
      feeExpiresAt: terms.feeExpiresAt,
    );
  }

  /// The least a send leaves for the relayer ("Use it all"'s reserve).
  Future<BigInt> minNetworkFee() async => (await broadcaster()).minFee;

  /// What [request] costs at the relayer's fee now, for review. A fee above
  /// the cap is refused ([PrivateUsdSendFeeCapException]): it is never
  /// offered, let alone proved.
  Future<PrivateUsdSendCost> cost(
    String accountUuid,
    PrivateUsdSendRequest request,
  ) async {
    final quote = await _quote(accountUuid, request, await broadcaster());
    if (_aboveCap(quote.fee)) throw const PrivateUsdSendFeeCapException();
    return quote.cost;
  }

  /// Sends [request] paying [confirmed]'s network fee, or a lower one the
  /// relayer asks now; a higher one comes back to be confirmed. One payment
  /// at a time per account (the spend guard). Never throws.
  /// [onStep] follows it for the status screen.
  Future<PrivateUsdSendOutcome> send(
    String accountUuid,
    PrivateUsdSendRequest request,
    PrivateUsdSendCost confirmed, {
    void Function(PrivateUsdSendStep step)? onStep,
  }) {
    if (!_canRun) return Future.value(const PrivateUsdSendNotSent());
    final ticket = _engine.ticket();
    return _track(() async {
      try {
        return await _guard.send(
          accountUuid,
          () => _sendNow(
            accountUuid,
            request,
            confirmed,
            ticket,
            onStep ?? (_) {},
          ),
        );
      } on PrivateUsdSpendBusyException catch (busy) {
        return busy.status == PrivateUsdSpendStatus.unreadable
            ? const PrivateUsdSendNotSent(PrivateUsdCopy.sendErrorStore)
            : PrivateUsdSendBusy(busy.status);
      }
    }());
  }

  /// One settlement pass over [accountUuid]'s unconfirmed sends (the rows
  /// after it), only in the foreground while unlocked; null when it did
  /// not run. A send the pass finds in a block syncs the wallet, so the
  /// balance follows it ([syncOnLanding]; the landing wait syncs once it
  /// returns instead).
  Future<List<rust.ApiSendRecord>?> settle(
    String accountUuid, {
    bool syncOnLanding = true,
  }) {
    if (!_canRun) return Future.value();
    return _track(() async {
      try {
        final before = _guard.recordsFor(accountUuid);
        final rows = await _backend.settleAll(accountUuid);
        _guard.noteSends(accountUuid, rows);
        if (syncOnLanding && privateUsdSendsLanded(before, rows)) {
          unawaited(_syncQuietly(accountUuid));
        }
        return rows;
      } on rust.ApiPrivateUsdError catch (error) {
        if (error.code == rust.ApiPrivateUsdErrorCode.storeUnreadable) {
          _guard.noteUnreadable(accountUuid);
        }
        return null;
      } catch (error) {
        privateUsdLog('a settlement pass failed (${error.runtimeType})');
        return null;
      }
    }());
  }

  /// Settles [accountUuid]'s log if it holds a send not seen in a block (on
  /// unlock, and on an account switch).
  Future<void> settleIfUnsettled(String accountUuid) async {
    if (!_canRun) return;
    await _guard.check(accountUuid);
    if (_guard.hasUnsettled(accountUuid)) await settle(accountUuid);
  }

  /// Refuses new sends and settlements and waits (at most [timeout]) for
  /// the running ones: before an account deletion or a reset. Pair with
  /// [resume].
  Future<void> quiesceAndDrain({
    Duration timeout = PrivateUsdEngineTiming.quiesceDrain,
  }) async {
    _quiesced = true;
    try {
      await Future.wait(_running.toList()).timeout(timeout);
    } catch (_) {
      // A Rust call that outlives the drain finishes on its own; the
      // deletion's Rust side serializes with it.
    }
  }

  void resume() => _quiesced = false;

  Future<PrivateUsdSendOutcome> _sendNow(
    String accountUuid,
    PrivateUsdSendRequest request,
    PrivateUsdSendCost confirmed,
    PrivateUsdEngineTicket ticket,
    void Function(PrivateUsdSendStep step) onStep,
  ) async {
    onStep(PrivateUsdSendStep.pricing);
    final _Quote quote;
    try {
      quote = await _held(accountUuid, request, confirmed);
    } on rust.ApiPrivateUsdError catch (error) {
      return PrivateUsdSendNotSent(privateUsdSendErrorMessage(error.code));
    } catch (error) {
      privateUsdLog('no send cost (${error.runtimeType})');
      return const PrivateUsdSendNotSent();
    }
    // Never proved above the cap, nor above the fee the user confirmed.
    if (_aboveCap(quote.fee)) {
      return const PrivateUsdSendNotSent(PrivateUsdCopy.sendErrorFeeCap);
    }
    if (quote.fee > confirmed.networkFee) {
      return PrivateUsdSendRepriced(quote.cost);
    }
    if (!_isCurrent(ticket)) return const PrivateUsdSendNotSent();
    final sendId = _newSendId();
    onStep(PrivateUsdSendStep.proving);
    final RailgunRelayedProof proof;
    try {
      proof = await _page.prove(
        accountUuid,
        request.transfer,
        quote.broadcaster,
        quote.fee,
      );
    } catch (error) {
      privateUsdLog('nothing was proved (${error.runtimeType})');
      return const PrivateUsdSendNotSent();
    }
    try {
      // The proof took up to 10 minutes: keep it only if the app stayed
      // unlocked and in the foreground and the engine did not move on.
      if (!_isCurrent(ticket)) return const PrivateUsdSendNotSent();
      try {
        final kept = await _backend.put(
          accountUuid,
          rust.ApiProvedSend(
            sendId: sendId,
            token: request.token.address,
            amount: request.amount.toString(),
            fee: quote.fee.toString(),
            to: request.to.text,
            proofJson: proof.json,
          ),
          stillCurrent: () => _isCurrent(ticket),
        );
        _guard.noteSends(accountUuid, [
          kept,
          for (final row in _guard.recordsFor(accountUuid))
            if (row.sendId != kept.sendId) row,
        ]);
      } on PrivateUsdStaleStepException {
        return const PrivateUsdSendNotSent();
      } on rust.ApiPrivateUsdError catch (error) {
        switch (error.code) {
          case rust.ApiPrivateUsdErrorCode.busy:
            await _guard.check(accountUuid);
            return PrivateUsdSendBusy(
              _guard.hasUnsettled(accountUuid)
                  ? PrivateUsdSpendStatus.sending
                  : PrivateUsdSpendStatus.converting,
            );
          case rust.ApiPrivateUsdErrorCode.storeUnreadable:
            _guard.noteUnreadable(accountUuid);
            return const PrivateUsdSendNotSent(PrivateUsdCopy.sendErrorStore);
          case rust.ApiPrivateUsdErrorCode.relayerFee:
            return const PrivateUsdSendNotSent(PrivateUsdCopy.sendErrorFeeCap);
          default:
            return const PrivateUsdSendNotSent();
        }
      } catch (error) {
        // Unknown: ask the log whether it was kept before saying anything.
        privateUsdLog('the keep failed (${error.runtimeType})');
        await _guard.check(accountUuid);
        final kept = _guard
            .recordsFor(accountUuid)
            .any((row) => row.sendId == sendId);
        return kept
            ? const PrivateUsdSendUnconfirmed(null)
            : const PrivateUsdSendNotSent();
      }
      // Kept: from here it is never proved again, whatever happens.
      onStep(PrivateUsdSendStep.posting);
      return await _post(accountUuid, sendId, request, quote);
    } finally {
      // The balance follows the send without the send waiting for it.
      unawaited(_syncQuietly(accountUuid));
    }
  }

  /// The first post of a kept send, then the landing wait.
  Future<PrivateUsdSendOutcome> _post(
    String accountUuid,
    String sendId,
    PrivateUsdSendRequest request,
    _Quote quote,
  ) async {
    // Kept and not posted: settlement posts it on the next pass.
    if (!_canRun) return const PrivateUsdSendUnconfirmed(null);
    final rust.ApiTransactResult answer;
    try {
      answer = await _backend.transact(accountUuid, sendId);
    } on rust.ApiPrivateUsdError catch (error) {
      if (error.code == rust.ApiPrivateUsdErrorCode.other) {
        // Not kept after all: nothing went out.
        await _guard.check(accountUuid);
        return const PrivateUsdSendNotSent();
      }
      return const PrivateUsdSendUnconfirmed(null);
    } catch (error) {
      privateUsdLog('the first post failed (${error.runtimeType})');
      return const PrivateUsdSendUnconfirmed(null);
    }
    final named = answer.transactions.firstOrNull;
    switch (answer.kind) {
      case rust.ApiTransactKind.sent:
        return _land(accountUuid, sendId, named);
      case rust.ApiTransactKind.refused:
        // Nothing went and Rust dropped the row: a higher fee the relayer
        // now asks is the user's to confirm.
        await _guard.check(accountUuid);
        return _refused(accountUuid, request, quote.fee);
      case rust.ApiTransactKind.spent:
      case rust.ApiTransactKind.retry:
        return PrivateUsdSendUnconfirmed(named);
    }
  }

  /// Settles until the send is in a block, dropped, or [landingWait] has
  /// passed.
  Future<PrivateUsdSendOutcome> _land(
    String accountUuid,
    String sendId,
    String? named,
  ) async {
    var txHash = named;
    final until = _now().add(landingWait);
    while (true) {
      await Future<void>.delayed(landingPoll);
      if (!_canRun) return PrivateUsdSendUnconfirmed(txHash);
      // The send syncs the wallet once this returns.
      final rows = await settle(accountUuid, syncOnLanding: false);
      if (rows != null) {
        final row = rows.where((r) => r.sendId == sendId).firstOrNull;
        // Gone: it reverted, or another proof took part of its notes.
        if (row == null) return const PrivateUsdSendNotSent();
        txHash = row.txHash ?? txHash;
        if (row.state == rust.ApiSendState.confirmed) {
          return PrivateUsdSendSent(txHash);
        }
      }
      if (!_now().isBefore(until)) return PrivateUsdSendUnconfirmed(txHash);
    }
  }

  Future<PrivateUsdSendOutcome> _refused(
    String accountUuid,
    PrivateUsdSendRequest request,
    BigInt proved,
  ) async {
    try {
      final quote = await _quote(accountUuid, request, await broadcaster());
      if (quote.fee > proved) {
        return _aboveCap(quote.fee)
            ? const PrivateUsdSendNotSent(PrivateUsdCopy.sendErrorFeeCap)
            : PrivateUsdSendRepriced(quote.cost);
      }
    } catch (error) {
      privateUsdLog('no quote after a refusal (${error.runtimeType})');
    }
    return const PrivateUsdSendNotSent();
  }

  /// [confirmed] while the relayer still holds it once a proof is made and
  /// its floor is not above it; else the fee it asks now.
  Future<_Quote> _held(
    String accountUuid,
    PrivateUsdSendRequest request,
    PrivateUsdSendCost confirmed,
  ) async {
    final broadcaster = await this.broadcaster();
    final expiresAt = confirmed.networkFeeExpiresAt;
    final nowSeconds = _now().millisecondsSinceEpoch ~/ 1000;
    final isHeld = expiresAt == null
        ? broadcaster.feePerUnitGas == null
        : nowSeconds + provingTime.inSeconds < expiresAt;
    if (isHeld && broadcaster.minFee <= confirmed.networkFee) {
      return _Quote(broadcaster, confirmed);
    }
    return _quote(accountUuid, request, broadcaster);
  }

  Future<_Quote> _quote(
    String accountUuid,
    PrivateUsdSendRequest request,
    RailgunBroadcaster broadcaster,
  ) async {
    final fee = await _page.broadcasterFee(
      accountUuid,
      request.transfer,
      broadcaster,
    );
    final fees = request.isWithdrawal ? await _page.fees(accountUuid) : null;
    return _Quote(
      broadcaster,
      PrivateUsdSendCost(
        railgunFee: fees?.unshieldFee(request.amount) ?? BigInt.zero,
        feeBasisPoints: fees?.unshieldBasisPoints ?? 0,
        networkFee: fee,
        networkFeeToken: broadcaster.feeToken,
        networkFeeExpiresAt: broadcaster.feeExpiresAt,
      ),
    );
  }

  bool _isCurrent(PrivateUsdEngineTicket ticket) =>
      !_quiesced && _engine.isCurrent(ticket);

  Future<void> _syncQuietly(String accountUuid) async {
    if (!_canRun) return;
    try {
      await _page.sync(accountUuid);
    } catch (_) {
      // The next balance refresh catches up.
    }
  }

  Future<T> _track<T>(Future<T> work) {
    final done = work.then<void>((_) {}, onError: (Object _) {});
    _running.add(done);
    unawaited(done.whenComplete(() => _running.remove(done)));
    return work;
  }

  static final _random = Random.secure();

  /// A random (version 4) UUID: the send's id in the log.
  static String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = [
      for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
