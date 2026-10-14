import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_record_key.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_engine.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';

/// The Refunds screen's checks (zapp `PrivateUsdRefundsVM`): every refunded
/// row is checked again this often, at most [concurrent] at a time, each
/// given up after [timeout].
abstract final class PrivateUsdRefundsTiming {
  static const checkEvery = Duration(seconds: 15);
  static const concurrent = 4;
  static const timeout = Duration(seconds: 30);
}

/// One refunded conversion on the Refunds screen.
@immutable
class PrivateUsdRefundRow {
  const PrivateUsdRefundRow({
    required this.record,
    this.recoverable,
    this.checkFailed = false,
    this.error,
  });

  final rust.ApiReverseRecord record;

  /// Whether its vault holds more than the relayer's fee; null until
  /// checked.
  final bool? recoverable;
  final bool checkFailed;

  /// Why its last recovery did not go through.
  final String? error;

  PrivateUsdRefundRow copyWith({
    rust.ApiReverseRecord? record,
    bool? recoverable,
    bool? checkFailed,
    String? error,
    bool clearError = false,
  }) => PrivateUsdRefundRow(
    record: record ?? this.record,
    recoverable: recoverable ?? this.recoverable,
    checkFailed: checkFailed ?? this.checkFailed,
    error: clearError ? null : (error ?? this.error),
  );
}

/// The Refunds screen (plan reference §9.4 S7).
@immutable
class PrivateUsdRefundsState {
  const PrivateUsdRefundsState({
    this.rows = const [],
    this.loaded = false,
    this.refreshing = false,
    this.recovering,
    this.error,
  });

  /// Every refunded conversion, newest first.
  final List<PrivateUsdRefundRow> rows;
  final bool loaded;
  final bool refreshing;

  /// The swap index being recovered; one at a time, and back waits for it.
  final int? recovering;

  /// The records could not be read.
  final String? error;

  bool get canGoBack => recovering == null;

  PrivateUsdRefundsState copyWith({
    List<PrivateUsdRefundRow>? rows,
    bool? loaded,
    bool? refreshing,
    int? recovering,
    bool clearRecovering = false,
    String? error,
    bool clearError = false,
  }) => PrivateUsdRefundsState(
    rows: rows ?? this.rows,
    loaded: loaded ?? this.loaded,
    refreshing: refreshing ?? this.refreshing,
    recovering: clearRecovering ? null : (recovering ?? this.recovering),
    error: clearError ? null : (error ?? this.error),
  );
}

/// [accountUuid]'s refunded conversions and whether each can be recovered.
/// The checks are chain reads only; a recovery (`rescue`) needs the seed
/// and is the user's alone, behind a confirmation sheet (D18).
final privateUsdRefundsProvider = NotifierProvider.autoDispose
    .family<PrivateUsdRefundsNotifier, PrivateUsdRefundsState, String>(
      PrivateUsdRefundsNotifier.new,
    );

class PrivateUsdRefundsNotifier extends Notifier<PrivateUsdRefundsState> {
  PrivateUsdRefundsNotifier(this.accountUuid);

  final String accountUuid;
  Timer? _timer;
  int _pass = 0;

  @override
  PrivateUsdRefundsState build() {
    ref.listen(
      privateUsdReverseConversionsProvider.select(
        (all) => _Refunded(_refunded(all)),
      ),
      (_, next) => _withRecords(next.records),
    );
    _timer = Timer.periodic(PrivateUsdRefundsTiming.checkEvery, (_) {
      unawaited(_checkAll());
    });
    ref.onDispose(() {
      _pass++;
      _timer?.cancel();
    });
    scheduleMicrotask(_load);
    return PrivateUsdRefundsState(
      rows: [
        for (final record in _refunded(
          ref.read(privateUsdReverseConversionsProvider),
        ))
          PrivateUsdRefundRow(record: record),
      ],
    );
  }

  PrivateUsdEngine get _engine => ref.read(privateUsdEngineProvider);

  List<rust.ApiReverseRecord> _refunded(
    Map<PrivateUsdRecordKey, PrivateUsdReverseStatus> all,
  ) => [
    for (final entry in all.entries)
      if (entry.key.accountUuid == accountUuid &&
          entry.value.record.phase == rust.ApiReversePhase.refunded)
        entry.value.record,
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  Future<void> _load() async {
    try {
      await _engine.loadReverseRecords(accountUuid);
      if (!ref.mounted) return;
      state = state.copyWith(loaded: true, clearError: true);
    } catch (_) {
      if (!ref.mounted) return;
      state = state.copyWith(
        loaded: true,
        error: PrivateUsdCopy.convertErrorStore,
      );
    }
    await _checkAll();
  }

  void _withRecords(List<rust.ApiReverseRecord> records) {
    final known = {for (final row in state.rows) row.record.index: row};
    state = state.copyWith(
      rows: [
        for (final record in records)
          known[record.index]?.copyWith(record: record) ??
              PrivateUsdRefundRow(record: record),
      ],
    );
  }

  /// The refresh button: checks every row again now.
  Future<void> refresh() async {
    if (state.recovering != null) return;
    await _checkAll();
  }

  /// "Recover refund", once its sheet was confirmed: the relayer's fee
  /// comes out of it (at most 2 USDC, X6). One at a time.
  Future<void> recover(int index) async {
    if (state.recovering != null) return;
    final row = state.rows
        .where((row) => row.record.index == index)
        .firstOrNull;
    if (row == null || row.recoverable != true) return;
    state = state.copyWith(
      recovering: index,
      rows: [
        for (final row in state.rows)
          row.record.index == index ? row.copyWith(clearError: true) : row,
      ],
    );
    String? error;
    try {
      await _engine.reverseRescue(accountUuid, index: index);
    } on rust.ApiPrivateUsdError catch (failure) {
      if (failure.code != rust.ApiPrivateUsdErrorCode.cancelled) {
        error = PrivateUsdCopy.refundsRecoverFailed;
      }
    } catch (failure) {
      if (failure is! PrivateUsdEngineInterruptedException) {
        error = PrivateUsdCopy.refundsRecoverFailed;
      }
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      clearRecovering: true,
      rows: [
        for (final row in state.rows)
          row.record.index == index ? row.copyWith(error: error) : row,
      ],
    );
    await _checkAll();
  }

  Future<void> _checkAll() async {
    if (!ref.mounted || state.rows.isEmpty || state.recovering != null) {
      return;
    }
    // Not while locked or in the background (nothing is at risk here).
    if (!_engine.canRun) return;
    final pass = ++_pass;
    state = state.copyWith(refreshing: true);
    final pending = [for (final row in state.rows) row.record.index];
    Future<void> worker() async {
      while (pending.isNotEmpty) {
        final index = pending.removeAt(0);
        bool? recoverable;
        var failed = false;
        try {
          recoverable = await _engine
              .reverseCanRescue(accountUuid, index: index)
              .timeout(PrivateUsdRefundsTiming.timeout);
        } catch (_) {
          failed = true;
        }
        if (!ref.mounted || pass != _pass) return;
        state = state.copyWith(
          rows: [
            for (final row in state.rows)
              row.record.index == index
                  ? PrivateUsdRefundRow(
                      record: row.record,
                      recoverable: failed ? null : recoverable,
                      checkFailed: failed,
                      error: row.error,
                    )
                  : row,
          ],
        );
      }
    }

    await Future.wait([
      for (var i = 0; i < PrivateUsdRefundsTiming.concurrent; i++) worker(),
    ]);
    if (!ref.mounted || pass != _pass) return;
    state = state.copyWith(refreshing: false);
  }
}

@immutable
class _Refunded {
  const _Refunded(this.records);

  final List<rust.ApiReverseRecord> records;

  @override
  bool operator ==(Object other) =>
      other is _Refunded && listEquals(other.records, records);

  @override
  int get hashCode => Object.hashAll(records);
}
