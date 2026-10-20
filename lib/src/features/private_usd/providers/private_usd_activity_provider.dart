import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_record_key.dart';
import '../services/private_usd_engine.dart';
import 'private_usd_available_provider.dart';
import 'private_usd_deposits_provider.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';

/// Reads [accountUuid]'s conversion history into the engine once; the
/// engine keeps it current after.
final _privateUsdHistoryProvider = FutureProvider.autoDispose
    .family<void, String>((ref, accountUuid) async {
      final engine = ref.read(privateUsdEngineProvider);
      await engine.loadRecords(accountUuid);
      await engine.loadReverseRecords(accountUuid);
    });

/// [accountUuid]'s forward conversions for activity rows, newest first.
/// Empty in builds without the swap engine (desktop among them), which never
/// read any.
final privateUsdActivityRecordsProvider = Provider.autoDispose
    .family<List<rust.ApiForwardRecord>, String>((ref, accountUuid) {
      if (!ref.watch(privateUsdEngineEnabledProvider)) return const [];
      ref.watch(_privateUsdHistoryProvider(accountUuid));
      final records = ref.watch(
        privateUsdConversionsProvider.select(
          (all) => _SameRecords([
            for (final entry in all.entries)
              if (entry.key.accountUuid == accountUuid &&
                  entry.key.direction == PrivateUsdDirection.forward)
                entry.value.record,
          ]),
        ),
      );
      return [...records.list]..sort(
        (a, b) =>
            privateUsdActivityTime(b).compareTo(privateUsdActivityTime(a)),
      );
    });

/// [accountUuid]'s reverse conversions for activity rows, newest first:
/// every one that moved money, so no `quoted` draft and nothing `cancelled`.
final privateUsdReverseActivityRecordsProvider = Provider.autoDispose
    .family<List<rust.ApiReverseRecord>, String>((ref, accountUuid) {
      if (!ref.watch(privateUsdEngineEnabledProvider)) return const [];
      ref.watch(_privateUsdHistoryProvider(accountUuid));
      final records = ref.watch(
        privateUsdReverseConversionsProvider.select(
          (all) => _SameRecords([
            for (final entry in all.entries)
              if (entry.key.accountUuid == accountUuid &&
                  entry.value.record.phase != rust.ApiReversePhase.quoted &&
                  entry.value.record.phase != rust.ApiReversePhase.cancelled)
                entry.value.record,
          ]),
        ),
      );
      return [...records.list]..sort(
        (a, b) => privateUsdReverseActivityTime(
          b,
        ).compareTo(privateUsdReverseActivityTime(a)),
      );
    });

/// When a reverse conversion's row sorts: its last change once it ended,
/// else its start.
DateTime privateUsdReverseActivityTime(rust.ApiReverseRecord record) {
  final ended = !privateUsdReverseUnderWay(record.phase);
  final seconds = ended
      ? record.updatedAt
      : (record.acceptedAt ?? record.updatedAt);
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}

/// When a conversion's row sorts: its end, or its start while under way.
DateTime privateUsdActivityTime(rust.ApiForwardRecord record) =>
    DateTime.fromMillisecondsSinceEpoch(
      (record.endedAt ?? record.acceptedAt) * 1000,
    );

/// The main-wallet transactions conversions made (deposits and refund
/// sweeps), in the internal byte order history rows carry: their own rows
/// stand in for them, so these rows are dropped from the feeds.
Set<String> _privateUsdActivityTxids(
  Iterable<rust.ApiForwardRecord> records, {
  Iterable<rust.ApiReverseRecord> reverse = const [],
}) => {
  for (final record in records) ...[
    ?record.depositTxid?.toLowerCase(),
    ?record.sweepTxid?.toLowerCase(),
  ],
  // A reverse conversion's sweep home lands in the main wallet.
  for (final record in reverse) ?record.receiveTxid?.toLowerCase(),
};

/// An account's Private USD activity for a feed (Home, Activity and
/// `/private-usd`): its conversions and deposits, the deployment's numbers
/// their rows show, and the main-wallet transactions they stand in for.
@immutable
class PrivateUsdActivity {
  const PrivateUsdActivity({
    this.records = const [],
    this.reverseRecords = const [],
    this.depositRecords = const [],
    this.txids = const {},
    this.zcashConfirmations = 0,
    this.screening = Duration.zero,
  });

  static const empty = PrivateUsdActivity();

  /// Newest first, as the activity providers keep them.
  final List<rust.ApiForwardRecord> records;
  final List<rust.ApiReverseRecord> reverseRecords;
  final List<rust.ApiDepositRecord> depositRecords;

  /// The main-wallet transactions these rows stand in for, in the internal
  /// byte order history rows carry: a feed drops those rows.
  final Set<String> txids;
  final int zcashConfirmations;

  /// How long Railgun screens new funds.
  final Duration screening;
}

/// [accountUuid]'s [PrivateUsdActivity]. With no rows it reads no
/// deployment (an FRB call desktop never makes).
final privateUsdActivityProvider = Provider.autoDispose
    .family<PrivateUsdActivity, String>((ref, accountUuid) {
      final records = ref.watch(privateUsdActivityRecordsProvider(accountUuid));
      final reverse = ref.watch(
        privateUsdReverseActivityRecordsProvider(accountUuid),
      );
      final deposits = ref.watch(privateUsdDepositRecordsProvider(accountUuid));
      if (records.isEmpty && reverse.isEmpty && deposits.isEmpty) {
        return PrivateUsdActivity.empty;
      }
      // Rows come only from a running engine, which runs on a deployment.
      final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
      if (deployment == null) return PrivateUsdActivity.empty;
      return PrivateUsdActivity(
        records: records,
        reverseRecords: reverse,
        depositRecords: deposits,
        txids: _privateUsdActivityTxids(records, reverse: reverse),
        zcashConfirmations: deployment.zcashConfirmations,
        screening: Duration(seconds: deployment.screeningSeconds),
      );
    });

/// Records that compare by their elements, so a `select` of them notifies
/// only when they change rather than on every engine publish.
@immutable
class _SameRecords<T> {
  const _SameRecords(this.list);

  final List<T> list;

  @override
  bool operator ==(Object other) =>
      other is _SameRecords<T> && listEquals(other.list, list);

  @override
  int get hashCode => Object.hashAll(list);
}
