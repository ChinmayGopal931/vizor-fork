import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';

// A first sync's balance shows once its notes are in; Railgun's transaction
// list comes after, on the sync line, so the percentage follows the notes.
void main() {
  RailgunScanEvent notes(double progress) => RailgunScanEvent(
    tree: RailgunMerkletree.utxo,
    status: RailgunScanStatus.updated,
    progress: progress,
  );

  test('nothing reported yet is no percentage', () {
    expect(PrivateUsdFirstSyncProgress().percent(), isNull);
  });

  test('the quick sync, reported by block, carries it most of the way', () {
    final progress = PrivateUsdFirstSyncProgress(elapsed: () => Duration.zero);
    final percents = [
      for (final share in [0.03, 0.1, 0.2, 0.3, 0.4, 0.5, 0.7, 0.85, 0.97])
        progress.percent(notes: notes(share))!,
    ];
    expect(percents, orderedEquals([...percents]..sort()));
    expect(percents.first, 0);
    expect(percents[4], greaterThan(50), reason: 'history stored');
    expect(percents.last, lessThan(100));
  });

  test('complete notes are 99 until the balance shows', () {
    final progress = PrivateUsdFirstSyncProgress(elapsed: () => Duration.zero);
    expect(
      progress.percent(
        notes: const RailgunScanEvent(
          tree: RailgunMerkletree.utxo,
          status: RailgunScanStatus.complete,
          progress: 0,
        ),
      ),
      99,
    );
  });

  test('between two reports it creeps toward the next, never past it', () {
    var elapsed = Duration.zero;
    final progress = PrivateUsdFirstSyncProgress(elapsed: () => elapsed);
    final at = progress.percent(notes: notes(0.5))!;
    elapsed = const Duration(minutes: 30);
    final later = progress.percent(notes: notes(0.5))!;
    expect(later, greaterThan(at));
    expect(later, lessThanOrEqualTo(progress.percent(notes: notes(0.7))!));
  });
}
