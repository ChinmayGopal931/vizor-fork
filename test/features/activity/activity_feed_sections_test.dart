import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/activity/activity_feed_sections.dart';
import 'package:zcash_wallet/src/features/activity/models/activity_row_data.dart';

ActivityEntry entry(int i, DateTime time) => ActivityEntry(
  timestamp: time,
  row: ActivityRowData(
    stableId: 'row-$i',
    title: 'Received',
    leadingIconName: 'plane',
    leadingBackgroundColor: const Color(0xff000000),
    leadingIconColor: const Color(0xffffffff),
    amountText: '+1 ZEC',
    statusText: '',
    timestampText: '',
  ),
);

void main() {
  test('equal-time prefix is stable across page appends', () {
    for (final count in [20, 40, 60, 100]) {
      final sections = buildActivityFeedSections(
        List.generate(count, (i) => entry(i, DateTime.utc(2026))),
        limit: 20,
      );
      expect(
        sections.expand((s) => s.rows).map((r) => r.stableId),
        List.generate(20, (i) => 'row-$i'),
        reason: '$count loaded rows',
      );
    }
  });

  test('rows that do not count toward the limit show within its span', () {
    final paged = List.generate(
      4,
      (i) => entry(i, DateTime.utc(2026, 1, 10).subtract(Duration(days: i))),
    );
    // Loaded in full: one between the paged rows, one older than the page.
    final within = entry(10, DateTime.utc(2026, 1, 9, 12));
    final older = entry(11, DateTime.utc(2025, 12, 1));
    final sections = buildActivityFeedSections(
      [...paged, within, older],
      limit: 3,
      countsTowardLimit: (e) => !identical(e, within) && !identical(e, older),
    );
    expect(sections.expand((s) => s.rows).map((r) => r.stableId), [
      'row-0',
      'row-10',
      'row-1',
      'row-2',
    ]);
  });

  test('page limit applies after timestamp ordering and date grouping', () {
    final sections = buildActivityFeedSections(
      List.generate(
        40,
        (i) => entry(i, DateTime.utc(2026, 1, 1).add(Duration(days: i))),
      ),
      limit: 20,
    );
    expect(
      sections.expand((s) => s.rows).map((r) => r.stableId),
      List.generate(20, (i) => 'row-${39 - i}'),
    );
  });
}
