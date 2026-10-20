import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    expect(sync.screening, RailgunScreening.ok);
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

  test("the page's screening state lands in the engine's, and a closed page "
      'forgets it', () async {
    final log = <String>[];
    final host = _FakeHost(log, pageAddress: _address);
    final engine = _engineWith(host, log);
    await engine.sync('account');

    host.pageEvents.add(
      '{"event":"screening","data":{"txids":null,"download":null,'
      '"proving":{"index":1,"count":2,"progress":0.5}}}',
    );
    await pumpEventQueue();
    expect(
      engine.state.value.screening,
      const RailgunScreeningEvent(
        proving: RailgunPoiProving(index: 1, count: 2, progress: 0.5),
      ),
    );

    await engine.close();
    expect(engine.state.value.screening, isNull);
    await engine.dispose();
  });

  test("a sync carries the page's failed screening", () async {
    final log = <String>[];
    final refresh = Completer<String>();
    final engine = _engine(log, pageAddress: _address, refresh: refresh);

    final sync = engine.sync('account');
    await _until(() => log.contains('call refresh'));
    refresh.complete(
      '{"balances":{"MissingInternalPOI":[{"token":'
      '"0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c","amount":"5"}]},'
      '"screening":"failed"}',
    );

    final synced = await sync;
    expect(synced.screening, RailgunScreening.failed);
    expect(engine.state.value.lastSync?.screening, RailgunScreening.failed);
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

  // iOS plan XI14: iOS may reclaim a suspended app's listening socket.
  group('the bridge after the background', () {
    test(
      'a bridge that stopped accepting takes the page down with it',
      () async {
        final log = <String>[];
        final probed = <int>[];
        final engine = _engine(
          log,
          pageAddress: _address,
          bridgeAccepts: (port) async {
            probed.add(port);
            return false;
          },
        );
        await engine.sync('account');
        log.clear();

        await engine.replaceDeadBridge();

        expect(probed, [4242]);
        expect(log, ['close', 'stop']);
        // The next use reopens the page, on a new bridge.
        await engine.sync('account');
        expect(log.sublist(2, 4), ['start bridge', 'load 4242']);
        await engine.dispose();
      },
    );

    test('a bridge that still accepts keeps the page', () async {
      final log = <String>[];
      final engine = _engine(
        log,
        pageAddress: _address,
        bridgeAccepts: (_) async => true,
      );
      await engine.sync('account');
      log.clear();

      await engine.replaceDeadBridge();
      await engine.sync('account');

      expect(log, ['call refresh']);
      await engine.dispose();
    });

    test('without an open page there is nothing to check', () async {
      final log = <String>[];
      var probes = 0;
      final engine = _engine(
        log,
        pageAddress: _address,
        bridgeAccepts: (_) async {
          probes++;
          return false;
        },
      );
      await engine.replaceDeadBridge();
      await engine.sync('account');
      await engine.close();
      await engine.replaceDeadBridge();

      expect(probes, 0);
      await engine.dispose();
    });

    test('the loopback probe tells a listener from a closed port', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen((socket) => socket.destroy());
      expect(await loopbackAccepts(port), isTrue);
      await server.close();
      expect(await loopbackAccepts(port), isFalse);
    });
  });

  // A bridge started while a close is still stopping its own could be the
  // one that close stops (iOS plan invariant 21).
  test(
    'a page reopens only once a close under way stopped its bridge',
    () async {
      final log = <String>[];
      final host = _FakeHost(log, pageAddress: _address);
      final engine = _engineWith(host, log);
      await engine.sync('account');
      log.clear();

      final closeGate = Completer<void>();
      host.closeGate = closeGate;
      final closing = engine.close();
      final sync = engine.sync('account');
      await pumpEventQueue();
      expect(log, ['close']);

      closeGate.complete();
      await closing;
      await sync;
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
    },
  );

  // iOS progress BI-3 and VI-17: an account deletion deletes the account's
  // wallet from the page's storage.
  group('deleting a wallet', () {
    RailgunWalletDeletion deletion() => RailgunWalletDeletion(
      accountUuid: 'gone',
      network: 'sepolia',
      mnemonic: 'railgun words',
    );

    test('happens on a fresh page behind an offline bridge, which both close '
        'after', () async {
      final log = <String>[];
      final host = _FakeHost(log, pageAddress: _address);
      final engine = _engineWith(host, log);
      final gone = deletion();

      await engine.deleteWallet(gone);

      // The first close is the build's, of what an earlier engine left.
      expect(log, [
        'close',
        'stop',
        'close',
        'stop',
        'start offline bridge',
        'load 4343',
        'call deleteWallet',
        'close',
        'stop',
      ]);
      expect(jsonDecode(host.params['deleteWallet']!), {
        'network': 'sepolia',
        'mnemonic': 'railgun words',
      });
      expect(gone.isDiscarded, isTrue);
      await engine.dispose();
    });

    test(
      'closes the open page first and runs while the engine is drained',
      () async {
        final log = <String>[];
        final engine = _engine(log, pageAddress: _address);
        await engine.sync('account');
        await engine.quiesceAndDrain();
        log.clear();

        await engine.deleteWallet(deletion());

        expect(log, [
          'close',
          'stop',
          'start offline bridge',
          'load 4343',
          'call deleteWallet',
          'close',
          'stop',
        ]);
        // Still drained: uses wait for the account deletion to end.
        await expectLater(
          engine.sync('account'),
          throwsA(isA<RailgunEngineUnavailableException>()),
        );
        engine.resume();
        expect((await engine.sync('account')).address, _address);
        await engine.dispose();
      },
    );

    test('a page that fails to delete fails it, and the page and bridge '
        'close', () async {
      final log = <String>[];
      final host = _FakeHost(log, pageAddress: _address)
        ..failing.add('deleteWallet');
      final engine = _engineWith(host, log);
      final gone = deletion();

      await expectLater(
        engine.deleteWallet(gone),
        throwsA(isA<RailgunHostException>()),
      );

      expect(log.sublist(log.length - 2), ['close', 'stop']);
      expect(gone.isDiscarded, isTrue);
      await engine.dispose();
    });

    test(
      'a close meanwhile stops it before the page gets the mnemonic',
      () async {
        final log = <String>[];
        final loaded = Completer<void>();
        final host = _FakeHost(log, pageAddress: _address)..loadGate = loaded;
        final engine = _engineWith(host, log);
        final gone = deletion();

        final deleting = engine.deleteWallet(gone);
        await _until(() => log.contains('load 4343'));
        await engine.close();
        loaded.complete();

        await expectLater(
          deleting,
          throwsA(isA<RailgunEngineInterruptedException>()),
        );
        expect(host.params, isNot(contains('deleteWallet')));
        expect(gone.isDiscarded, isTrue);
        expect(log.sublist(log.length - 2), ['close', 'stop']);
        await engine.dispose();
      },
    );

    test('one that outlives its timeout closes the page and drops the '
        'mnemonic', () async {
      final log = <String>[];
      final loaded = Completer<void>();
      final host = _FakeHost(log, pageAddress: _address)..loadGate = loaded;
      final engine = _engineWith(host, log);
      final gone = deletion();

      await expectLater(
        engine.deleteWallet(gone, timeout: const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
      expect(gone.isDiscarded, isTrue);
      expect(log.sublist(log.length - 2), ['close', 'stop']);

      loaded.complete();
      await pumpEventQueue();
      expect(host.params, isNot(contains('deleteWallet')));
      await engine.dispose();
    });

    test('needs an offline bridge: without one nothing loads', () async {
      final log = <String>[];
      final engine = RailgunEngine(
        host: _FakeHost(log, pageAddress: _address),
        wallets: _FakeWallets(),
        startBridge: () async => 4242,
        stopBridge: () async => log.add('stop'),
      );
      final gone = deletion();

      await expectLater(
        engine.deleteWallet(gone),
        throwsA(isA<RailgunEngineUnavailableException>()),
      );
      expect(log, isNot(contains('load 4343')));
      expect(gone.isDiscarded, isTrue);
      await engine.dispose();
    });

    test('never shows the mnemonic in its description', () {
      expect(deletion().toString(), isNot(contains('railgun words')));
    });
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
  Future<bool> Function(int port)? bridgeAccepts,
}) => _engineWith(
  _FakeHost(log, pageAddress: pageAddress, refresh: refresh),
  log,
  bridgeAccepts: bridgeAccepts,
);

RailgunEngine _engineWith(
  _FakeHost host,
  List<String> log, {
  Future<bool> Function(int port)? bridgeAccepts,
}) => RailgunEngine(
  host: host,
  wallets: _FakeWallets(),
  startBridge: () async {
    log.add('start bridge');
    return 4242;
  },
  stopBridge: () async => log.add('stop'),
  startOfflineBridge: () async {
    log.add('start offline bridge');
    return 4343;
  },
  bridgeAccepts: bridgeAccepts ?? (_) async => true,
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

  @override
  Future<RailgunWalletDeletion?> prepareDeletion(String accountUuid) =>
      throw UnimplementedError('the engine never derives');
}

class _FakeHost implements RailgunHost {
  _FakeHost(this.log, {required this.pageAddress, this.refresh});

  final List<String> log;
  final String pageAddress;
  final Completer<String>? refresh;

  /// The params of each method's last call.
  final params = <String, String>{};

  /// Methods the page fails.
  final failing = <String>{};

  /// Holds `load` until completed.
  Completer<void>? loadGate;

  /// Holds `close` until completed.
  Completer<void>? closeGate;
  var _open = false;

  @override
  Future<void> load({required int proxyPort, required bool debug}) async {
    log.add('load $proxyPort');
    await loadGate?.future;
    _open = true;
  }

  @override
  Future<String> call(String method, String paramsJson) async {
    log.add('call $method');
    if (!_open) throw RailgunHostException(RailgunHostErrorCode.closed);
    params[method] = paramsJson;
    if (failing.contains(method)) {
      throw RailgunHostException(RailgunHostErrorCode.failed);
    }
    if (method == 'refresh' && refresh != null) return refresh!.future;
    return switch (method) {
      'start' => '{"fees":{"unshield":25,"shield":25}}',
      'openWallet' => jsonEncode({'address': pageAddress}),
      'refresh' =>
        '{"balances":{"Spendable":[{"token":'
            '"0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c","amount":"5"}]},'
            '"screening":"ok"}',
      'deleteWallet' => 'null',
      _ => throw RailgunHostException(RailgunHostErrorCode.badArgs),
    };
  }

  @override
  Future<void> close() async {
    log.add('close');
    _open = false;
    await closeGate?.future;
  }

  @override
  Future<void> wipe() async {
    log.add('wipe');
    _open = false;
  }

  @override
  Future<bool> isOpen() async => _open;

  /// What the page sends unasked, as the host forwards it.
  final pageEvents = StreamController<String>.broadcast();

  @override
  Stream<String> get events => pageEvents.stream;
}
