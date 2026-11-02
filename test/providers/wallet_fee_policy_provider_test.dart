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

  ProviderContainer start({
    required int tip,
    Future<String?> Function()? resolveExistingDbPath,
  }) {
    sync = FakeSyncNotifier(SyncState(chainTipHeight: tip, scannedHeight: tip));
    dbTip = tip;
    reads = 0;
    failReads = false;
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
          if (failReads) throw StateError('database is locked');
          final target = dbTip + 1;
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
