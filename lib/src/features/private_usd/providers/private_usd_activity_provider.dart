import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_record_key.dart';
import '../services/private_usd_engine.dart';
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

/// [accountUuid]'s forward conversions for activity rows, newest first
/// (plan reference §9.4 S2). Empty in builds without the swap engine
/// (desktop among them), which never read any.
final privateUsdActivityRecordsProvider = Provider.autoDispose
    .family<List<rust.ApiForwardRecord>, String>((ref, accountUuid) {
      if (!ref.watch(privateUsdEngineEnabledProvider)) return const [];
      ref.watch(_privateUsdHistoryProvider(accountUuid));
      final records = ref.watch(
        privateUsdConversionsProvider.select(
          (all) => _Records([
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

/// [accountUuid]'s reverse conversions for activity rows (M6), newest
/// first: every one that moved money, so no `quoted` draft and nothing
/// `cancelled` (reference §9.4 S2).
final privateUsdReverseActivityRecordsProvider = Provider.autoDispose
    .family<List<rust.ApiReverseRecord>, String>((ref, accountUuid) {
      if (!ref.watch(privateUsdEngineEnabledProvider)) return const [];
      ref.watch(_privateUsdHistoryProvider(accountUuid));
      final records = ref.watch(
        privateUsdReverseConversionsProvider.select(
          (all) => _ReverseRecords([
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
Set<String> privateUsdActivityTxids(
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

@immutable
class _Records {
  const _Records(this.list);

  final List<rust.ApiForwardRecord> list;

  @override
  bool operator ==(Object other) =>
      other is _Records && listEquals(other.list, list);

  @override
  int get hashCode => Object.hashAll(list);
}

@immutable
class _ReverseRecords {
  const _ReverseRecords(this.list);

  final List<rust.ApiReverseRecord> list;

  @override
  bool operator ==(Object other) =>
      other is _ReverseRecords && listEquals(other.list, list);

  @override
  int get hashCode => Object.hashAll(list);
}
