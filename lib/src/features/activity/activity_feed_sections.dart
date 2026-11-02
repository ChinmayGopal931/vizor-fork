/// Date-grouped section building shared by the desktop activity screen
/// and the mobile activity tab: rows are sorted newest-first and grouped
/// under "This week" / month-year / "Earlier" titles.
library;

import '../../rust/api/sync.dart' as rust_sync;
import 'models/activity_row_data.dart';
import 'widgets/activity_feed.dart';

/// One activity row paired with the timestamp used for sorting and
/// section grouping.
class ActivityEntry {
  const ActivityEntry({required this.timestamp, required this.row});

  final DateTime? timestamp;
  final ActivityRowData row;
}

/// Newest first; entries without a timestamp sort last.
int compareActivityEntries(ActivityEntry a, ActivityEntry b) {
  final aTime = a.timestamp;
  final bTime = b.timestamp;
  if (aTime == null && bTime == null) return 0;
  if (aTime == null) return 1;
  if (bTime == null) return -1;
  return bTime.compareTo(aTime);
}

/// The timestamp an on-chain transaction sorts by: block time when
/// mined, creation time while pending, null when neither is known.
/// An unmined, unexpired tx with no recorded time is treated as
/// happening now — externally received mempool txs carry no block or
/// creation time and must surface at the top, not sink to "Earlier".
DateTime? transactionActivityTimestamp(
  rust_sync.TransactionInfo tx, {
  DateTime? now,
}) {
  final seconds = tx.blockTime > BigInt.zero ? tx.blockTime : tx.createdTime;
  if (seconds > BigInt.zero) {
    return DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
  }
  if (tx.minedHeight == BigInt.zero && !tx.expiredUnmined) {
    return now ?? DateTime.now();
  }
  return null;
}

/// Sorts [entries] newest-first and groups consecutive entries that
/// share a section title. A [limit] ends the feed at its [limit]th paged
/// row: an entry [countsTowardLimit] accepts (every entry when null), or one
/// of [unshownPagedTimes], the times of rows the pager counts that the feed
/// leaves out. Other entries show up to that end, and every entry shows
/// while there are fewer paged rows than [limit].
List<ActivityFeedSectionData> buildActivityFeedSections(
  List<ActivityEntry> entries, {
  int? limit,
  bool Function(ActivityEntry entry)? countsTowardLimit,
  List<DateTime?> unshownPagedTimes = const [],
}) {
  // Dart List.sort is not stable. Preserve native/source order at equal
  // timestamps so a later page cannot reshuffle rows already on screen.
  final sorted = entries.indexed.toList()
    ..sort((a, b) {
      final order = compareActivityEntries(a.$2, b.$2);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
  final visible = limit == null
      ? sorted
      : sorted.take(
          _limitEnd(sorted, limit, countsTowardLimit, unshownPagedTimes),
        );
  final sections = <ActivityFeedSectionData>[];
  List<ActivityRowData>? currentRows;
  String? currentTitle;

  for (final (_, entry) in visible) {
    final title = _activitySectionTitle(entry.timestamp);
    if (title != currentTitle) {
      currentTitle = title;
      currentRows = <ActivityRowData>[];
      sections.add(ActivityFeedSectionData(title: title, rows: currentRows));
    }
    currentRows!.add(entry.row);
  }

  return sections;
}

int _limitEnd(
  List<(int, ActivityEntry)> sorted,
  int limit,
  bool Function(ActivityEntry entry)? counts,
  List<DateTime?> unshown,
) {
  if ((counts == null && unshown.isEmpty) || limit <= 0) return limit;
  // The unshown rows take their places among the entries, after any entry
  // of the same time.
  final unshownSorted = [...unshown]..sort(_compareTimes);
  var counted = 0;
  var next = 0;
  for (var i = 0; i < sorted.length; i++) {
    final entry = sorted[i].$2;
    while (next < unshownSorted.length &&
        _compareTimes(unshownSorted[next], entry.timestamp) < 0) {
      next++;
      if (++counted == limit) return i;
    }
    if (counts?.call(entry) ?? true) {
      if (++counted == limit) return i + 1;
    }
  }
  return sorted.length;
}

/// Newest first; a missing time sorts last, as [compareActivityEntries] does.
int _compareTimes(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

String _activitySectionTitle(DateTime? timestamp) {
  if (timestamp == null) return 'Earlier';

  final local = timestamp.toLocal();
  final now = DateTime.now();
  final weekStart = _startOfWeek(now);
  final nextWeekStart = weekStart.add(const Duration(days: 7));
  if (!local.isBefore(weekStart) && local.isBefore(nextWeekStart)) {
    return 'This week';
  }

  return '${_monthName(local.month)} ${local.year}';
}

DateTime _startOfWeek(DateTime date) {
  final localDate = DateTime(date.year, date.month, date.day);
  return localDate.subtract(Duration(days: date.weekday - DateTime.monday));
}

String _monthName(int month) {
  const months = [
    '',
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return months[month];
}
