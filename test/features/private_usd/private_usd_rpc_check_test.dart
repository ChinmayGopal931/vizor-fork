import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/network/network_http_client.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_rpc_check.dart';

const _proxy = '0xFA7093CDD9EE6932B4eb2c9e1cde7CE00B1FA4b9';
const _token = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const _windows = '0xeB3A00bcB6c9fF626fE57a5dBbDCf01730e7898f';
final _word = '0x${'0' * 64}';

/// A mainnet RPC that serves every read the check makes, with a head block
/// listing [transactions] hashes.
class _MainnetRpc extends NetworkHttpClient {
  _MainnetRpc({required this.transactions});

  final int transactions;
  final methods = <String>[];

  @override
  Future<NetworkHttpResponse> request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int> bodyBytes = const [],
    Duration? timeout,
    Future<void>? cancelSignal,
    int? maxBodyBytes,
    int maxRedirects = 5,
  }) async {
    final call = jsonDecode(utf8.decode(bodyBytes)) as Map<String, Object?>;
    final rpcMethod = call['method']! as String;
    methods.add(rpcMethod);
    final Object result = switch (rpcMethod) {
      'eth_chainId' => '0x1',
      'eth_getBlockByNumber' => {
        'number': '0x1926bf7',
        'hash': _word,
        'transactions': [for (var i = 0; i < transactions; i++) _word],
      },
      'eth_call' => _word,
      'eth_getLogs' => const <Object>[],
      _ => throw StateError('unexpected $rpcMethod'),
    };
    return NetworkHttpResponse(
      statusCode: 200,
      bodyBytes: utf8.encode(
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}),
      ),
    );
  }
}

Future<PrivateUsdRpcCheckFailure?> _check(_MainnetRpc rpc) =>
    PrivateUsdRpcChecker(networkClient: rpc).check(
      'https://mainnet.infura.io/v3/key',
      chainId: 1,
      railgunProxy: _proxy,
      token: _token,
      logsContract: _windows,
    );

void main() {
  test('a busy mainnet head does not read as no answer', () async {
    // 2,000 hashes: about 140 KiB, a full block of plain transfers.
    final rpc = _MainnetRpc(transactions: 2000);

    expect(await _check(rpc), isNull);
    expect(rpc.methods, [
      'eth_chainId',
      'eth_getBlockByNumber',
      'eth_call',
      'eth_getLogs',
    ]);
  });

  test('an answer over the cap still reads as no answer', () async {
    final rpc = _MainnetRpc(transactions: 2000);
    final checker = PrivateUsdRpcChecker(
      networkClient: rpc,
      maxBodyBytes: 16 * 1024,
    );

    expect(
      await checker.check(
        'https://mainnet.infura.io/v3/key',
        chainId: 1,
        railgunProxy: _proxy,
        token: _token,
        logsContract: _windows,
      ),
      PrivateUsdRpcCheckFailure.unreachable,
    );
  });
}
