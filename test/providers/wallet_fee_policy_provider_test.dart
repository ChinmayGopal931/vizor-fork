import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/rpc_endpoint_config.dart';
import 'package:zcash_wallet/src/providers/block_spacing_provider.dart';
import 'package:zcash_wallet/src/providers/rpc_endpoint_failover_provider.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';
import 'package:zcash_wallet/src/rust/api/sync.dart' as rust_sync;
import 'package:zcash_wallet/src/rust/api/wallet.dart' as rust_wallet;

import '../fakes/fake_sync_notifier.dart';

const _activation = 1000;

// Rust prices a transaction one past the chain tip its wallet DB recorded,
// which a sync records only as it starts, after the poller saw the tip: the
// fee epoch and the least fee follow the DB.
void main() {
  late FakeSyncNotifier sync;
  var dbTip = 0;
  var reads = 0;
  var failReads = false;
  // Holds the next read until the test completes it.
  Completer<void>? holdNextRead;

  ProviderContainer start({
    required int tip,
    Future<String?> Function()? resolveExistingDbPath,
    Duration readAgainInterval = Duration.zero,
    String? accountUuid,
  }) {
    sync = FakeSyncNotifier(
      SyncState(
        accountUuid: accountUuid,
        chainTipHeight: tip,
        scannedHeight: tip,
      ),
    );
    dbTip = tip;
    reads = 0;
    failReads = false;
    holdNextRead = null;
    final container = ProviderContainer(
      overrides: [
        syncProvider.overrideWith(() => sync),
        rpcEndpointFailoverProvider.overrideWith(_Rpc.new),
        blockSpacingScheduleGetterProvider.overrideWithValue(
          ({required network}) => rust_wallet.BlockSpacingSchedule(
            nu7ActivationHeight: BigInt.from(_activation),
            preNu7BlockSeconds: 75,
            nu7BlockSeconds: 25,
          ),
        ),
        walletFeePolicyGetterProvider.overrideWithValue(({
          required dbPath,
          required network,
        }) async {
          reads++;
          // The DB as it was when the read began.
          final target = dbTip + 1;
          final hold = holdNextRead;
          if (hold != null) {
            holdNextRead = null;
            await hold.future;
          }
          if (failReads) throw StateError('database is locked');
          final marginal = BigInt.from(target >= _activation ? 1000 : 5000);
          return rust_sync.WalletFeePolicy(
            targetHeight: target,
            marginalFeeZatoshi: marginal,
            minimumFeeZatoshi: marginal * BigInt.two,
          );
        }),
        walletFeePolicyProvider.overrideWith(
          () => WalletFeePolicyNotifier(
            resolveExistingDbPath:
                resolveExistingDbPath ?? () async => 'wallet.db',
            readAgainInterval: readAgainInterval,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(walletFeePolicyEpochProvider, (_, _) {});
    return container;
  }

  test('the epoch waits for the wallet DB to record a tip past NU7', () async {
    final c = start(tip: _activation - 10);
    await c.read(walletFeePolicyProvider.future);
    expect(c.read(walletFeePolicyEpochProvider).nu7, isFalse);

    // The poller sees the crossing before the sync records it.
    sync.emit(
      SyncState(chainTipHeight: _activation, scannedHeight: _activation - 10),
    );
    await pumpEventQueue();
    expect(c.read(walletFeePolicyEpochProvider).nu7, isFalse);

    // The sync has recorded the tip; its next update reads the policy again.
    dbTip = _activation;
    sync.emit(
      SyncState(chainTipHeight: _activation, scannedHeight: _activation - 5),
    );
    await pumpEventQueue();
    expect(c.read(walletFeePolicyEpochProvider).nu7, isTrue);
    expect(
      c.read(walletFeePolicyProvider).value!.minimumFeeZatoshi,
      BigInt.from(2000),
    );

    // Once the two agree, later moves read nothing more.
    final settled = reads;
    sync.emit(
      SyncState(chainTipHeight: _activation + 1, scannedHeight: _activation),
    );
    await pumpEventQueue();
    expect(reads, settled);
  });

  test('a failed read keeps the policy last read', () async {
    final c = start(tip: _activation - 10);
    await c.read(walletFeePolicyProvider.future);

    // The sync has recorded the crossing, but reading it fails.
    dbTip = _activation;
    failReads = true;
    sync.emit(
      SyncState(chainTipHeight: _activation, scannedHeight: _activation - 5),
    );
    await pumpEventQueue();
    expect(
      c.read(walletFeePolicyProvider).value!.targetHeight,
      _activation - 9,
    );
    expect(c.read(walletFeePolicyEpochProvider).nu7, isFalse);

    failReads = false;
    sync.emit(
      SyncState(chainTipHeight: _activation, scannedHeight: _activation - 4),
    );
    await pumpEventQueue();
    expect(c.read(walletFeePolicyEpochProvider).nu7, isTrue);
  });

  test(
    'a move during the first read cannot leave that older read last',
    () async {
      final hold = Completer<void>();
      final c = start(tip: _activation - 10);
      holdNextRead = hold;
      final first = c.read(walletFeePolicyProvider.future);
      await pumpEventQueue();
      expect(reads, 1);

      // The sync records the crossing while that first read is out.
      dbTip = _activation;
      sync.emit(
        SyncState(chainTipHeight: _activation, scannedHeight: _activation - 5),
      );
      await pumpEventQueue();
      expect(reads, 1, reason: 'no second read beside the first');

      hold.complete();
      await first;
      await pumpEventQueue();
      expect(reads, 2);
      expect(
        c.read(walletFeePolicyProvider).value!.targetHeight,
        _activation + 1,
      );
      expect(c.read(walletFeePolicyEpochProvider).nu7, isTrue);
    },
  );

  test('moves read the DB again at most once per interval', () async {
    const interval = Duration(milliseconds: 300);
    final c = start(tip: _activation - 10, readAgainInterval: interval);
    await c.read(walletFeePolicyProvider.future);
    // The sync's first state arrives during that read and asks for one more,
    // which pauses in turn.
    await Future<void>.delayed(interval * 3);
    final settled = reads;

    // The poller saw the crossing; the DB lags behind for every batch.
    for (var scanned = _activation - 9; scanned < _activation - 4; scanned++) {
      sync.emit(SyncState(chainTipHeight: _activation, scannedHeight: scanned));
      await pumpEventQueue();
    }
    expect(reads, settled + 1, reason: 'the first move reads, the rest wait');

    // The last move asked during the pause is read once it ends.
    await Future<void>.delayed(interval * 1.5);
    expect(reads, settled + 2);
    await Future<void>.delayed(interval * 1.5);
    expect(reads, settled + 2);

    // A lock clears the sync state: no tip says nothing about the DB.
    sync.emit(SyncState());
    await Future<void>.delayed(interval * 1.5);
    expect(reads, settled + 2);
  });

  test('a reset drops the policy of the wallet it deleted', () async {
    String? dbPath = 'wallet.db';
    final c = start(
      tip: _activation,
      accountUuid: 'account-1',
      resolveExistingDbPath: () async => dbPath,
    );
    await c.read(walletFeePolicyProvider.future);
    await pumpEventQueue();
    expect(
      c.read(walletFeePolicyProvider).value!.targetHeight,
      _activation + 1,
    );

    // The reset deletes the DB and leaves no active account.
    dbPath = null;
    sync.emit(SyncState());
    await pumpEventQueue();
    expect(c.read(walletFeePolicyProvider).value, isNull);
    expect(c.read(walletFeePolicyEpochProvider).nu7, isFalse);

    // A new wallet reads its own DB.
    dbPath = 'wallet-2.db';
    dbTip = _activation - 10;
    sync.emit(
      SyncState(
        accountUuid: 'account-2',
        chainTipHeight: _activation - 10,
        scannedHeight: _activation - 10,
      ),
    );
    await pumpEventQueue();
    expect(
      c.read(walletFeePolicyProvider).value!.targetHeight,
      _activation - 9,
    );
  });

  test('without a wallet the polled tip stands in for its target', () async {
    final c = start(tip: _activation, resolveExistingDbPath: () async => null);
    await c.read(walletFeePolicyProvider.future);
    expect(c.read(walletFeePolicyProvider).value, isNull);
    expect(c.read(walletFeePolicyEpochProvider).nu7, isTrue);
    expect(reads, 0);
  });
}

class _Rpc extends RpcEndpointFailoverNotifier {
  @override
  RpcEndpointFailoverState build() => RpcEndpointFailoverState(
    primary: defaultRpcEndpointConfig('main'),
    current: defaultRpcEndpointConfig('main'),
    fallbackCandidates: const [],
  );
}
