import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_balances.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_screening_status.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/private_usd_copy.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/features/private_usd/widgets/mobile/private_usd_sync_line.dart';

// The Processing row's live line and the sync line (owner, 2026-10-19): what
// the page's screening work is doing, and a long txid catch-up shown as one.
void main() {
  test(
    'the step furthest along speaks first: proving, downloading, the list',
    () {
      const all = RailgunScreeningEvent(
        txids: 0.5,
        downloading: true,
        download: 0.25,
        proving: RailgunPoiProving(index: 2, count: 3, progress: 0.704),
      );
      expect(
        privateUsdScreeningStatus(activity: all, balances: _processing()),
        PrivateUsdCopy.screeningProving(2, 3, 70),
      );
      expect(
        privateUsdScreeningStatus(
          activity: const RailgunScreeningEvent(
            txids: 0.5,
            downloading: true,
            download: 0.25,
          ),
          balances: _processing(),
        ),
        PrivateUsdCopy.screeningDownloading(25),
      );
      expect(
        privateUsdScreeningStatus(
          activity: const RailgunScreeningEvent(downloading: true),
          balances: _processing(),
        ),
        'Downloading proving files',
      );
      expect(
        privateUsdScreeningStatus(
          activity: const RailgunScreeningEvent(txids: 0.42),
          balances: _processing(),
        ),
        "Syncing Railgun's transaction list · 42%",
      );
    },
  );

  test('with nothing running, funds a node has taken wait on it, '
      'and otherwise there is nothing to say', () {
    expect(
      privateUsdScreeningStatus(
        activity: const RailgunScreeningEvent(),
        balances: _processing(submitted: true),
      ),
      PrivateUsdCopy.screeningWaiting,
    );
    expect(
      privateUsdScreeningStatus(activity: null, balances: _processing()),
      isNull,
    );
  });

  test('a single proof is not counted, and a share never reads done early', () {
    expect(
      PrivateUsdCopy.screeningProving(1, 1, 30),
      'Building screening proof · 30%',
    );
    expect(privateUsdScreeningPercent(0.999), 99);
    expect(privateUsdScreeningPercent(1), 100);
    expect(privateUsdScreeningPercent(-0.2), 0);
  });

  test('a long txid catch-up climbs the sync line; a refresh without one '
      'stays synced', () {
    final state = PrivateUsdBalanceState(
      balances: _processing(),
      updatedAt: DateTime(2026, 10, 19),
      isRefreshing: true,
    );
    final catchingUp = privateUsdSyncLine(state, txidCatchUp: 0.42);
    expect(catchingUp.readout, PrivateUsdCopy.syncReadoutProgress(42));
    expect(catchingUp.climbing, isTrue);
    expect(catchingUp.progress, closeTo(0.42, 1e-9));

    for (final done in [null, 1.0]) {
      final synced = privateUsdSyncLine(state, txidCatchUp: done);
      expect(synced.readout, PrivateUsdCopy.syncReadoutSynced, reason: '$done');
      expect(synced.climbing, isFalse);
    }
  });
}

const _token = PrivateUsdToken(
  address: '0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c',
  symbol: 'USDC',
  decimals: 6,
);

PrivateUsdBalances _processing({bool submitted = false}) =>
    PrivateUsdBalances.of(
      RailgunBalances({
        submitted
            ? RailgunBalanceBucket.proofSubmitted
            : RailgunBalanceBucket.missingInternalPoi: [
          RailgunTokenAmount(token: _token.address, amount: BigInt.from(5)),
        ],
      }),
      const [_token],
    );
