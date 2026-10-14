import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../rust/api/private_usd.dart' as rust;
import '../models/private_usd_record_key.dart';
import 'private_usd_engine_provider.dart';
import 'private_usd_unfinished_provider.dart';

/// Reads [accountUuid]'s conversion history into the engine once; the
/// engine keeps it current after.
final _privateUsdHistoryProvider = FutureProvider.autoDispose
    .family<void, String>((ref, accountUuid) async {
      await ref.read(privateUsdEngineProvider).loadRecords(accountUuid);
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

/// When a conversion's row sorts: its end, or its start while under way.
DateTime privateUsdActivityTime(rust.ApiForwardRecord record) =>
    DateTime.fromMillisecondsSinceEpoch(
      (record.endedAt ?? record.acceptedAt) * 1000,
    );

/// The main-wallet transactions conversions made (deposits and refund
/// sweeps), in the internal byte order history rows carry: their own rows
/// stand in for them, so these rows are dropped from the feeds.
Set<String> privateUsdActivityTxids(Iterable<rust.ApiForwardRecord> records) =>
    {
      for (final record in records) ...[
        ?record.depositTxid?.toLowerCase(),
        ?record.sweepTxid?.toLowerCase(),
      ],
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
