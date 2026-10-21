import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/config/private_usd_feature_config.dart';
import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_messages.dart';
import '../models/private_usd_record_key.dart';
import '../models/railgun_models.dart';
import '../private_usd_copy.dart';
import 'private_usd_engine.dart';
import 'private_usd_pause.dart';
import 'private_usd_spend_guard.dart';
import 'private_usd_swap_backend.dart';
import 'railgun_engine.dart';
import 'railgun_host_channel.dart';

/// The Railgun page's calls a reverse conversion needs: the open wallet's
/// address, pricing and the funding proof. Tests fake it.
abstract interface class PrivateUsdReversePage {
  /// [accountUuid]'s `0zk` address, opening its wallet if needed.
  Future<String> address(String accountUuid);

  /// Railgun's fees (the unshield fee in basis points).
  Future<RailgunFees> fees(String accountUuid);

  /// What paying [request] debits from the private balance; nothing is
  /// proved.
  Future<RailgunReverseCost> reverseCost(
    String accountUuid,
    RailgunReverseCostRequest request,
  );

  /// Proves the funding (up to 10 minutes; `proof` events meanwhile).
  /// Nothing is sent.
  Future<RailgunReverseTransaction> prepareReverse(
    String accountUuid,
    RailgunReverseRequest request,
  );
}

/// [PrivateUsdReversePage] over the app's [RailgunEngine].
class RailgunReversePage implements PrivateUsdReversePage {
  const RailgunReversePage(this._railgun);

  final RailgunEngine _railgun;

  @override
  Future<String> address(String accountUuid) =>
      _railgun.withSession(accountUuid, (session) async => session.address);

  @override
  Future<RailgunFees> fees(String accountUuid) =>
      _railgun.withSession(accountUuid, (session) async => session.fees);

  @override
  Future<RailgunReverseCost> reverseCost(
    String accountUuid,
    RailgunReverseCostRequest request,
  ) => _railgun.withSession(
    accountUuid,
    (session) => session.reverseCost(request),
  );

  @override
  Future<RailgunReverseTransaction> prepareReverse(
    String accountUuid,
    RailgunReverseRequest request,
  ) => _railgun.withSession(
    accountUuid,
    (session) => session.prepareReverse(request),
  );
}

/// Where a funding is (the progress screen's "Sending private USD" step).
enum PrivateUsdFundingStage { preparing, proving, submitting }

/// How one funding try ended.
enum PrivateUsdFundingResult {
  /// Kept and posted; the loop follows it.
  submitted,

  /// A funding was kept already: the loop follows it, nothing was proved.
  alreadyFunded,

  /// Locked, backgrounded, called off or the page closed meanwhile: the
  /// proof (if any) was dropped and nothing was paid. "Pay" proves again.
  dropped,

  /// The fees changed: the new total shows, nothing was paid.
  costChanged,

  /// It did not go through; [PrivateUsdFundingState.error] says why.
  failed,

  /// One is running already for this conversion.
  running,
}

/// One conversion's funding as the progress screen shows it.
@immutable
class PrivateUsdFundingState {
  const PrivateUsdFundingState({this.stage, this.error});

  /// The step running now; null when none runs.
  final PrivateUsdFundingStage? stage;

  /// Why the last try paid nothing (shown in `awaitingFunding` only).
  final String? error;

  bool get running => stage != null;

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdFundingState &&
      other.stage == stage &&
      other.error == error;

  @override
  int get hashCode => Object.hash(stage, error);
}

/// The reverse funding: the spend guard, `funding_request` (signs
/// `OpenReverse` for the page's own wallet), the page's `prepareReverse` and
/// `submit_funding`.
///
/// - The proof runs outside the account's queue, so a cancel can run
///   meanwhile; Rust then refuses the submit.
/// - A proof that finishes after a lock, after the app went to the
///   background, or once the engine moved on (its epoch) is dropped and
///   never submitted: [PrivateUsdEngine.isCurrent] is asked right up to the
///   call. A lock also drops the request Rust holds, so "Pay" proves again.
/// - It never proves again for a funding Rust kept (`alreadyFunded`): the
///   loop resends those same bytes.
///
/// It never logs a request, a proof, an amount or an address.
class PrivateUsdReverseFunding {
  PrivateUsdReverseFunding({
    required PrivateUsdEngine engine,
    required PrivateUsdReversePage page,
    required PrivateUsdSpendGuard guard,
  }) : _engine = engine,
       _page = page,
       _guard = guard;

  final PrivateUsdEngine _engine;
  final PrivateUsdReversePage _page;
  final PrivateUsdSpendGuard _guard;

  /// Each conversion's funding, while one runs or after one paid nothing.
  final states =
      ValueNotifier<Map<PrivateUsdRecordKey, PrivateUsdFundingState>>(const {});

  // Bumped by [drop]: a running try from before never submits.
  final _generations = <PrivateUsdRecordKey, int>{};
  bool _disposed = false;

  /// Prices swap [request] for review: the page's `reverseCost`, then
  /// `set_cost`. When the relayer's fee moved meanwhile it asks once more at
  /// the new fee.
  Future<rust.ApiReverseRecord> price(
    String accountUuid,
    rust.ApiReverseCostRequest request,
  ) async {
    var current = request;
    for (var attempt = 0; ; attempt++) {
      final cost = await _page.reverseCost(
        accountUuid,
        RailgunReverseCostRequest(
          amount: BigInt.parse(current.amount),
          railgun: current.railgunProxy,
          fee: BigInt.parse(current.fee),
        ),
      );
      try {
        return await _engine.reverseSetCost(
          accountUuid,
          index: current.index,
          debit: cost.debit.toString(),
          railgunFee: cost.railgunFee.toString(),
        );
      } on rust.ApiPrivateUsdError catch (error) {
        if (error.code != rust.ApiPrivateUsdErrorCode.fundingCostChanged ||
            attempt > 0) {
          rethrow;
        }
        current = await _engine.reverseCostRequest(
          accountUuid,
          index: current.index,
        );
      }
    }
  }

  /// Funds [key]'s conversion once. Never throws: the outcome, and [states]
  /// say what happened.
  Future<PrivateUsdFundingResult> fund(PrivateUsdRecordKey key) async {
    if (_disposed) return PrivateUsdFundingResult.dropped;
    if (states.value[key]?.running ?? false) {
      return PrivateUsdFundingResult.running;
    }
    if (!_engine.canRun) return PrivateUsdFundingResult.dropped;
    final ticket = _engine.ticket();
    final generation = _generations[key] ?? 0;
    _set(
      key,
      const PrivateUsdFundingState(stage: PrivateUsdFundingStage.preparing),
    );
    String? error;
    var result = PrivateUsdFundingResult.failed;
    try {
      result = await _guard.startConversion(
        key.accountUuid,
        () => _fund(key, ticket, generation),
      );
    } on rust.ApiPrivateUsdError catch (failure) {
      switch (failure.code) {
        case rust.ApiPrivateUsdErrorCode.cancelled:
          result = PrivateUsdFundingResult.dropped;
        case rust.ApiPrivateUsdErrorCode.fundingCostChanged:
          result = PrivateUsdFundingResult.costChanged;
          error = PrivateUsdCopy.reverseErrorCostChanged;
          await _priceIfCleared(key);
        default:
          error = privateUsdReverseStepMessage(failure.code);
      }
    } on PrivateUsdSpendBusyException catch (busy) {
      // A send not seen in a block yet holds the wallet's notes.
      error = switch (busy.status) {
        PrivateUsdSpendStatus.sending ||
        PrivateUsdSpendStatus.unreadable => privateUsdSpendMessage(busy.status),
        _ => PrivateUsdCopy.reverseError,
      };
    } catch (failure) {
      if (_isDrop(failure)) {
        result = PrivateUsdFundingResult.dropped;
      } else {
        privateUsdLog('a funding failed (${failure.runtimeType})');
        error = PrivateUsdCopy.reverseError;
      }
    } finally {
      _set(key, PrivateUsdFundingState(error: error));
      _engine.nudge();
    }
    return result;
  }

  /// The conversion was called off: a running try never submits.
  void drop(PrivateUsdRecordKey key) {
    _generations[key] = (_generations[key] ?? 0) + 1;
  }

  /// Forgets [key]'s last error (a new try, or the record moved on).
  void clearError(PrivateUsdRecordKey key) {
    final state = states.value[key];
    if (state == null || state.error == null) return;
    _set(key, PrivateUsdFundingState(stage: state.stage));
  }

  void dispose() {
    _disposed = true;
    states.dispose();
  }

  Future<PrivateUsdFundingResult> _fund(
    PrivateUsdRecordKey key,
    PrivateUsdEngineTicket ticket,
    int generation,
  ) async {
    final account = key.accountUuid;
    // The page's open wallet: Rust refuses a funding for any wallet but the
    // account's own.
    final address = await _page.address(account);
    _ensureCurrent(key, ticket, generation);
    final request = await _engine.reverseFundingRequest(
      account,
      index: key.index,
      railgunAddress: address,
      ticket: ticket,
    );
    if (request.alreadyFunded) return PrivateUsdFundingResult.alreadyFunded;
    _ensureCurrent(key, ticket, generation);
    _set(
      key,
      const PrivateUsdFundingState(stage: PrivateUsdFundingStage.proving),
    );
    final transaction = await _page.prepareReverse(
      account,
      RailgunReverseRequest(
        amount: BigInt.parse(request.amount),
        railgun: request.railgunProxy,
        token: request.token,
        calls: [
          for (var i = 0; i < request.callsTo.length; i++)
            RailgunContractCall(
              to: request.callsTo[i],
              data: request.callsData[i],
            ),
        ],
        relayAdapt: request.relayAdapt,
        fee: BigInt.parse(request.fee),
      ),
    );
    // The proof took up to 10 minutes: drop it unless the app stayed
    // unlocked and in the foreground, the engine did not move on, and the
    // conversion was not called off meanwhile.
    _ensureCurrent(key, ticket, generation);
    _set(
      key,
      const PrivateUsdFundingState(stage: PrivateUsdFundingStage.submitting),
    );
    await _engine.reverseSubmitFunding(
      account,
      index: key.index,
      proof: PrivateUsdFundingProof(
        to: transaction.to,
        data: transaction.data,
        value: transaction.value.toString(),
        debit: transaction.cost.debit.toString(),
        railgunFee: transaction.cost.railgunFee.toString(),
      ),
      ticket: ticket,
    );
    return PrivateUsdFundingResult.submitted;
  }

  void _ensureCurrent(
    PrivateUsdRecordKey key,
    PrivateUsdEngineTicket ticket,
    int generation,
  ) {
    if (_disposed ||
        !_engine.isCurrent(ticket) ||
        (_generations[key] ?? 0) != generation) {
      throw const PrivateUsdStaleStepException();
    }
  }

  /// After a refused funding the relayer's new fee cleared the cost: price
  /// it again, so "Pay" shows the new total. Best effort.
  Future<void> _priceIfCleared(PrivateUsdRecordKey key) async {
    try {
      final records = await _engine.loadReverseRecords(key.accountUuid);
      final record = records.where((r) => r.index == key.index).firstOrNull;
      if (record == null || record.cost != null || record.funded) return;
      final request = await _engine.reverseCostRequest(
        key.accountUuid,
        index: key.index,
      );
      await price(key.accountUuid, request);
    } catch (_) {
      // The progress screen prices it when it shows.
    }
  }

  // A page that died under the proof dropped it too: nothing was paid.
  static bool _isDrop(Object failure) =>
      failure is PrivateUsdPause ||
      (failure is RailgunHostException && failure.code.pageGone);

  void _set(PrivateUsdRecordKey key, PrivateUsdFundingState state) {
    if (_disposed) return;
    final next = {...states.value};
    if (state.stage == null && state.error == null) {
      next.remove(key);
    } else {
      next[key] = state;
    }
    states.value = Map.unmodifiable(next);
  }
}
