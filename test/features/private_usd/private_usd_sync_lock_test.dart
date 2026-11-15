import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_balances.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_balance_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_keep_awake_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/private_usd_sync_lock_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/providers/railgun_engine_provider.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_repository.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_engine.dart';
import 'package:zcash_wallet/src/providers/app_security_provider.dart';

// Railgun's ring on the wallet sync's privacy lock, in the Shielded USD
// screen's figures: a first sync climbs to its balance, then Railgun's
// transaction list climbs again.
void main() {
  group("Railgun's ring", () {
    test(
      "a first sync climbs as the Shielded USD screen's percentage does",
      () {
        final track = privateUsdSyncLockTrack(
          status: PrivateUsdSyncStatus.syncing,
          balance: const PrivateUsdBalanceState(firstSyncPercent: 40),
        );

        expect(track.stage, PrivateUsdSyncLockStage.balance);
        expect(track.progress, closeTo(0.4, 1e-9));
      },
    );

    test("once the balance shows, Railgun's transaction list climbs as far as "
        'the page has caught up on it', () {
      final track = privateUsdSyncLockTrack(
        status: PrivateUsdSyncStatus.syncing,
        balance: _withBalance,
        txids: 0.5,
      );

      expect(track.stage, PrivateUsdSyncLockStage.transactions);
      expect(track.progress, 0.5);
    });

    test('a catch-up the page has not reported yet starts the list at 0', () {
      final track = privateUsdSyncLockTrack(
        status: PrivateUsdSyncStatus.syncing,
        balance: _withBalance,
      );

      expect(track.stage, PrivateUsdSyncLockStage.transactions);
      expect(track.progress, 0);
    });

    test('a synced wallet fills the ring; a paused one stays where it was', () {
      expect(
        privateUsdSyncLockTrack(
          status: PrivateUsdSyncStatus.synced,
          balance: _withBalance,
        ),
        const PrivateUsdSyncLockTrack(
          progress: 1,
          stage: PrivateUsdSyncLockStage.synced,
        ),
      );
      expect(
        privateUsdSyncLockTrack(
          status: PrivateUsdSyncStatus.paused,
          balance: const PrivateUsdBalanceState(firstSyncPercent: 30),
        ),
        const PrivateUsdSyncLockTrack(
          progress: 0.3,
          stage: PrivateUsdSyncLockStage.paused,
        ),
      );
    });
  });

  group("Railgun's sync status", () {
    test('a first sync running is syncing', () {
      final container = _container(engine: true);
      container.read(privateUsdFirstSyncsProvider.notifier).begin(_account);

      expect(
        container.read(privateUsdSyncStatusProvider),
        PrivateUsdSyncStatus.syncing,
      );
    });

    test('without the engine it is paused, and builds no engine', () {
      final container = _container(engine: false);

      expect(
        container.read(privateUsdSyncStatusProvider),
        PrivateUsdSyncStatus.paused,
      );
      expect(container.exists(railgunEngineStateProvider), isFalse);
    });

    test("synced once the page's wallet has a sync; another wallet's is not "
        'it', () {
      final container = _container(engine: true);
      final engine = _engine(container);

      engine.set(const RailgunEngineState(accountUuid: _account));
      expect(
        container.read(privateUsdSyncStatusProvider),
        PrivateUsdSyncStatus.paused,
      );

      engine.set(
        RailgunEngineState(accountUuid: _account, lastSync: _sync('other')),
      );
      expect(
        container.read(privateUsdSyncStatusProvider),
        PrivateUsdSyncStatus.paused,
      );

      engine.set(
        RailgunEngineState(accountUuid: _account, lastSync: _sync(_account)),
      );
      expect(
        container.read(privateUsdSyncStatusProvider),
        PrivateUsdSyncStatus.synced,
      );

      // A closed page names no wallet, and keeps the last sync's.
      engine.set(RailgunEngineState(lastSync: _sync(_account)));
      expect(
        container.read(privateUsdSyncStatusProvider),
        PrivateUsdSyncStatus.synced,
      );
    });

    test('the rest of a sync running in the page is syncing', () {
      final container = _container(engine: true);
      _engine(container).set(
        RailgunEngineState(
          accountUuid: _account,
          lastSync: _sync(_account, syncing: true),
        ),
      );

      expect(
        container.read(privateUsdSyncStatusProvider),
        PrivateUsdSyncStatus.syncing,
      );
    });
  });

  test('the ring never goes back within a climb while the lock shows it, and '
      "the list's climb starts from its own figure", () {
    final balance = _Balance(_account);
    final container = _container(engine: true, balance: balance);
    final engine = _engine(container);
    final firstSync = container
        .read(privateUsdFirstSyncsProvider.notifier)
        .begin(_account);
    engine.set(const RailgunEngineState(accountUuid: _account));
    container.listen(privateUsdSyncLockTrackProvider, (_, _) {});

    balance.set(const PrivateUsdBalanceState(firstSyncPercent: 60));
    expect(
      container.read(privateUsdSyncLockTrackProvider),
      const PrivateUsdSyncLockTrack(
        progress: 0.6,
        stage: PrivateUsdSyncLockStage.balance,
      ),
    );

    // The balance shows; the rest of the sync runs on in the page.
    balance.set(_withBalance);
    engine.set(
      RailgunEngineState(
        accountUuid: _account,
        lastSync: _sync(_account, syncing: true),
        screening: const RailgunScreeningEvent(txids: 0.2),
      ),
    );
    firstSync.end();
    expect(
      container.read(privateUsdSyncLockTrackProvider),
      const PrivateUsdSyncLockTrack(
        progress: 0.2,
        stage: PrivateUsdSyncLockStage.transactions,
      ),
    );

    engine.set(
      RailgunEngineState(
        accountUuid: _account,
        lastSync: _sync(_account, syncing: true),
        screening: const RailgunScreeningEvent(txids: 0.8),
      ),
    );
    expect(container.read(privateUsdSyncLockTrackProvider).progress, 0.8);

    // The list's catch-up ends; the sync proves its sends.
    engine.set(
      RailgunEngineState(
        accountUuid: _account,
        lastSync: _sync(_account, syncing: true),
        screening: const RailgunScreeningEvent(),
      ),
    );
    expect(container.read(privateUsdSyncLockTrackProvider).progress, 0.8);

    engine.set(
      RailgunEngineState(accountUuid: _account, lastSync: _sync(_account)),
    );
    expect(
      container.read(privateUsdSyncLockTrackProvider),
      const PrivateUsdSyncLockTrack(
        progress: 1,
        stage: PrivateUsdSyncLockStage.synced,
      ),
    );
  });
}

const _account = 'account-1';

final _withBalance = PrivateUsdBalanceState(balances: PrivateUsdBalances([]));

RailgunSync _sync(String accountUuid, {bool syncing = false}) => RailgunSync(
  accountUuid: accountUuid,
  address: '0zk1',
  balances: const RailgunBalances({}),
  screening: RailgunScreening.ok,
  at: DateTime.utc(2026, 11, 15),
  syncing: syncing,
);

ProviderContainer _container({required bool engine, _Balance? balance}) {
  final container = ProviderContainer(
    overrides: [
      appSecurityProvider.overrideWith(_Unlocked.new),
      privateUsdEngineEnabledProvider.overrideWithValue(engine),
      railgunEngineStateProvider.overrideWith(_EngineState.new),
      privateUsdBalanceProvider(
        _account,
      ).overrideWith(() => balance ?? _Balance(_account)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _Unlocked extends AppSecurityNotifier {
  @override
  AppSecurityState build() =>
      const AppSecurityState(isPasswordConfigured: true, isUnlocked: true);
}

_EngineState _engine(ProviderContainer container) =>
    container.read(railgunEngineStateProvider.notifier) as _EngineState;

class _EngineState extends RailgunEngineStateNotifier {
  @override
  RailgunEngineState build() => const RailgunEngineState();

  void set(RailgunEngineState next) => state = next;
}

class _Balance extends PrivateUsdBalanceNotifier {
  _Balance(super.accountUuid);

  @override
  PrivateUsdBalanceState build() => const PrivateUsdBalanceState();

  void set(PrivateUsdBalanceState next) => state = next;
}
