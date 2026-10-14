import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_engine.dart';
import 'package:zcash_wallet/src/features/private_usd/services/railgun_host_channel.dart';

// Plan §3.5 invariant 19 and reference §6.3: a page whose wallet is not the
// account's is refused, and every close takes the bridge down with it.
void main() {
  test('opens in order and syncs the account wallet', () async {
    final log = <String>[];
    final engine = _engine(log, pageAddress: _address);

    final sync = await engine.sync('account');

    expect(sync.address, _address);
    expect(
      sync.balances.byBucket[RailgunBalanceBucket.spendable]!.single.amount,
      BigInt.from(5),
    );
    // The first build closes what an earlier Flutter engine left behind.
    expect(log, [
      'close',
      'stop',
      'start bridge',
      'load 4242',
      'call start',
      'call openWallet',
      'call refresh',
    ]);
    await engine.dispose();
  });

  test('a page that opens another wallet is refused and closed', () async {
    final log = <String>[];
    final engine = _engine(log, pageAddress: '0zk1someoneelse');

    await expectLater(
      engine.sync('account'),
      throwsA(isA<RailgunAddressMismatchException>()),
    );

    expect(log, isNot(contains('call refresh')));
    expect(log.sublist(log.length - 2), ['close', 'stop']);
    await engine.dispose();
  });

  test('closing under a use interrupts it and stops the bridge', () async {
    final log = <String>[];
    final refresh = Completer<String>();
    final engine = _engine(log, pageAddress: _address, refresh: refresh);

    final sync = engine.sync('account');
    await _until(() => log.contains('call refresh'));
    await engine.close();
    refresh.completeError(RailgunHostException(RailgunHostErrorCode.closed));

    await expectLater(sync, throwsA(isA<RailgunEngineInterruptedException>()));
    expect(log.sublist(log.length - 2), ['close', 'stop']);
    await engine.dispose();
  });

  test('a drained engine refuses uses until it resumes', () async {
    final log = <String>[];
    final engine = _engine(log, pageAddress: _address);

    await engine.quiesceAndDrain();
    await expectLater(
      engine.sync('account'),
      throwsA(isA<RailgunEngineUnavailableException>()),
    );
    engine.resume();
    expect((await engine.sync('account')).address, _address);
    await engine.dispose();
  });
}

const _address = '0zk1accountaddress';

RailgunEngine _engine(
  List<String> log, {
  required String pageAddress,
  Completer<String>? refresh,
}) => RailgunEngine(
  host: _FakeHost(log, pageAddress: pageAddress, refresh: refresh),
  wallets: _FakeWallets(),
  startBridge: () async {
    log.add('start bridge');
    return 4242;
  },
  stopBridge: () async => log.add('stop'),
);

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

class _FakeWallets implements RailgunWalletSource {
  @override
  Future<RailgunWalletOpening> prepare(String accountUuid) async =>
      const RailgunWalletOpening(
        start: RailgunStartParams(
          network: 'sepolia',
          rpcUrls: ['https://ethereum-sepolia-rpc.publicnode.com'],
          poiNodeUrls: ['https://ppoi.fdi.network/'],
        ),
        wallet: RailgunOpenWalletParams(
          encryptionKey: 'key',
          mnemonic: 'words',
        ),
        expectedAddress: _address,
      );
}

class _FakeHost implements RailgunHost {
  _FakeHost(this.log, {required this.pageAddress, this.refresh});

  final List<String> log;
  final String pageAddress;
  final Completer<String>? refresh;
  var _open = false;

  @override
  Future<void> load({required int proxyPort, required bool debug}) async {
    log.add('load $proxyPort');
    _open = true;
  }

  @override
  Future<String> call(String method, String paramsJson) async {
    log.add('call $method');
    if (!_open) throw RailgunHostException(RailgunHostErrorCode.closed);
    if (method == 'refresh' && refresh != null) return refresh!.future;
    return switch (method) {
      'start' => '{"fees":{"unshield":25,"shield":25}}',
      'openWallet' => jsonEncode({'address': pageAddress}),
      'refresh' =>
        '{"Spendable":[{"token":"0x5764d0044bef5aa839e0ddafe2073421101b9ed8",'
            '"amount":"5"}]}',
      _ => throw RailgunHostException(RailgunHostErrorCode.badArgs),
    };
  }

  @override
  Future<void> close() async {
    log.add('close');
    _open = false;
  }

  @override
  Future<void> wipe() async {
    log.add('wipe');
    _open = false;
  }

  @override
  Future<bool> isOpen() async => _open;

  @override
  Stream<String> get events => const Stream.empty();
}
