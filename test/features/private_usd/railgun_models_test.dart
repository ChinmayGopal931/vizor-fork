import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';

// The parsing cases of zapp's `RailgunSessionTest` (plan reference §8.7),
// where the typed page models live in Dart, plus the event decoding Kotlin
// no longer does.
void main() {
  test('balances keep known buckets only', () {
    final balances = RailgunBalances.parse(
      jsonDecode(
        '{"Spendable":[{"token":"$_token",'
        '"amount":"123456789012345678901234567890"}],'
        '"ShieldPending":[],"SomeNewBucket":[{"token":"$_token","amount":"1"}]}',
      ),
    );

    expect(
      balances,
      RailgunBalances({
        RailgunBalanceBucket.spendable: [
          RailgunTokenAmount(
            token: _token,
            amount: BigInt.parse('123456789012345678901234567890'),
          ),
        ],
        RailgunBalanceBucket.shieldPending: const [],
      }),
    );
  });

  test('an amount or token it cannot read fails the whole answer', () {
    for (final body in [
      '{"Spendable":[{"token":"$_token","amount":12}]}',
      '{"Spendable":[{"token":"$_token","amount":"-1"}]}',
      '{"Spendable":[{"token":"0x12","amount":"1"}]}',
      '{"Spendable":{"token":"$_token","amount":"1"}}',
      '[]',
    ]) {
      expect(
        () => RailgunBalances.parse(jsonDecode(body)),
        throwsA(isA<RailgunProtocolException>()),
        reason: body,
      );
    }
  });

  test('a transaction that is not a transact call for the broadcaster is '
      'refused', () {
    for (final reply in [
      _relayed(to: _token),
      _relayed(chainId: 1),
      _relayed(value: '1'),
      _relayed(spends: '[]'),
      _relayed(spends: '[{"tree":0,"nullifiers":[]}]'),
    ]) {
      expect(
        () => RailgunRelayedProof.parse(
          jsonDecode(reply),
          broadcaster: _broadcaster,
        ),
        throwsA(isA<RailgunProtocolException>()),
        reason: reply,
      );
    }
  });

  test('a transact call for the broadcaster keeps its request and spends', () {
    final proof = RailgunRelayedProof.parse(
      jsonDecode(_relayed()),
      broadcaster: _broadcaster,
    );

    expect(
      proof.request,
      RailgunRelayRequest(
        chainId: _chainId,
        to: _proxy.toLowerCase(),
        data: _data,
        value: BigInt.zero,
      ),
    );
    expect(proof.spends, [
      RailgunNullifiers(tree: 0, nullifiers: [_nullifier]),
    ]);
  });

  test('a result it cannot read is a protocol failure', () {
    expect(
      () => RailgunRelayedProof.parse(
        jsonDecode('{"chainId":$_chainId,"to":"$_proxy"}'),
        broadcaster: _broadcaster,
      ),
      throwsA(isA<RailgunProtocolException>()),
    );
    expect(
      () => RailgunStartResult.parse(jsonDecode('{"fees":{}}')),
      throwsA(isA<RailgunProtocolException>()),
    );
    expect(
      () => RailgunOpenWalletResult.parse(jsonDecode('{"address":"0x1"}')),
      throwsA(isA<RailgunProtocolException>()),
    );
  });

  test('funding is refused unless it goes through Relay Adapt for no ETH', () {
    const relayAdapt = '0x7e3d929EbD5bDC84d02Bd3205c777578f33A214D';
    String reply({String to = relayAdapt, String value = '0'}) =>
        '{"to":"$to","data":"$_data","value":"$value",'
        '"cost":{"debit":"10","railgunFee":"1"}}';

    expect(
      RailgunReverseTransaction.parse(
        jsonDecode(reply()),
        relayAdapt: relayAdapt,
      ).cost.debit,
      BigInt.from(10),
    );
    for (final wrong in [reply(to: _proxy), reply(value: '1')]) {
      expect(
        () => RailgunReverseTransaction.parse(
          jsonDecode(wrong),
          relayAdapt: relayAdapt,
        ),
        throwsA(isA<RailgunProtocolException>()),
      );
    }
  });

  test('the unshield fee rounds down', () {
    expect(
      const RailgunFees(
        unshieldBasisPoints: 25,
      ).unshieldFee(BigInt.from(999999)),
      BigInt.from(2499),
    );
  });

  test('decodes scan and proof events and drops what it does not read', () {
    expect(
      RailgunEvent.decode(
        '{"event":"scan","data":{"tree":"txid","status":"Updated",'
        '"progress":0.4}}',
      ),
      const RailgunScanEvent(
        tree: RailgunMerkletree.txid,
        status: RailgunScanStatus.updated,
        progress: 0.4,
      ),
    );
    expect(
      RailgunEvent.decode(
        '{"event":"proof","data":{"progress":0.25,"status":"proving"}}',
      ),
      const RailgunProofEvent(progress: 0.25, status: 'proving'),
    );
    for (final raw in [
      'not json',
      '[1]',
      '{"event":"unknown","data":1}',
      '{"event":"scan","data":{"tree":"other","status":"Updated"}}',
      '{"event":"scan","data":{"tree":"utxo","status":"Sideways"}}',
      '{"event":"proof","data":{"status":"proving"}}',
    ]) {
      expect(RailgunEvent.decode(raw), isNull, reason: raw);
    }
  });

  test('openWallet params never print the mnemonic', () {
    const params = RailgunOpenWalletParams(
      encryptionKey: 'ab',
      mnemonic: 'secret words',
    );
    expect(params.toString(), isNot(contains('secret')));
    expect(jsonDecode(params.toJson()), {
      'encryptionKey': 'ab',
      'mnemonic': 'secret words',
    });
  });
}

const _zeroK =
    '0zk1qyrs4qyrd08p6uep0fc2y8njktgcpezts3rpaq6q0ln948ecjkw8prv7j6f'
    'e3z53llz8ursderja0juwv5pgnv8x5klmmwkv8q38h9n704h4d4qjyw7n5qk68nx';
const _token = '0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c';
const _chainId = 11155111;
const _proxy = '0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea';
const _data = '0xd8ae136a00';
final _nullifier = '0x${'ab' * 32}';
final _broadcaster = RailgunBroadcaster(
  chainId: _chainId,
  railgunProxy: _proxy,
  railgunAddress: _zeroK,
  feeToken: _token,
  minFee: BigInt.from(250000),
  maxGasPrice: BigInt.from(20000000000),
);

String _relayed({
  String to = _proxy,
  int chainId = _chainId,
  String value = '0',
  String? spends,
}) =>
    '{"chainId":$chainId,"to":"$to","data":"$_data","value":"$value",'
    '"spends":${spends ?? '[{"tree":0,"nullifiers":["$_nullifier"]}]'},'
    '"proofMs":1200}';
