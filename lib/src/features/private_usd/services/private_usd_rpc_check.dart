import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpHeaders;

import '../../../core/config/private_usd_feature_config.dart';
import '../../../core/network/network_http_client.dart';

/// Why a user's own Ethereum RPC URL failed the check before saving.
enum PrivateUsdRpcCheckFailure {
  /// No answer in time, an HTTP or JSON-RPC error, or no chain id.
  unreachable,

  /// It answered for another chain than the deployment's.
  wrongChain,

  /// It refused `eth_call`, which every contract read is: a transaction
  /// RPC that forwards only some methods.
  callsRefused,

  /// It refused `eth_getLogs` over the window the engine reads swap logs
  /// in: a provider, or a plan, that caps the range lower.
  logsLimited,
}

/// The window the engine reads swap logs in, in blocks (`LOG_WINDOW_BLOCKS`
/// in `evm_rpc.rs`): what an RPC must serve `eth_getLogs` over.
const kPrivateUsdLogWindowBlocks = 5000;

/// Asks an Ethereum RPC URL for its chain (`eth_chainId`) before Settings
/// saves it, for a contract read (`eth_call`: `tokenBlocklist(address)` on
/// Railgun's proxy, the engine's own read; a transaction RPC may forward no
/// contract reads at all) and, where bridging runs, for the swap contract's
/// logs over the engine's window ending at the RPC's own head
/// (`eth_blockNumber`, `eth_getLogs`): a provider's plan may cap the range
/// lower, which would leave a bridge waiting on its payout. All through
/// [NetworkHttpClient]:
/// Tor when Tor is on, a direct connection otherwise, and never a fallback
/// from one to the other. It is bounded by [timeout] per request, [deadline]
/// in all (a wait for Tor's bootstrap included) and [maxBodyBytes] per
/// answer. The client buffers an answer before handing it over, so the size
/// cap refuses a large answer; it does not stop its download.
///
/// It never logs the URL, which can hold a key.
class PrivateUsdRpcChecker {
  PrivateUsdRpcChecker({
    NetworkHttpClient? networkClient,
    this.timeout = const Duration(seconds: 20),
    this.deadline = const Duration(seconds: 40),
    this.maxBodyBytes = 16 * 1024,
  }) : _client = networkClient ?? NetworkHttpClient();

  final NetworkHttpClient _client;
  final Duration timeout;
  final Duration deadline;
  final int maxBodyBytes;

  /// A topic no log carries, so the window's answer is empty: the range is
  /// what is checked, not the logs.
  static final _noTopic = '0x${'0' * 64}';

  /// `tokenBlocklist(address)`, the read the engine makes on Railgun's
  /// proxy (`evm_rpc.rs`).
  static const _tokenBlocklistSelector = '0x815b534f';

  /// The call data of `tokenBlocklist(token)`: the selector, then the
  /// address as a 32-byte word.
  static String _tokenBlocklistCall(String token) =>
      _tokenBlocklistSelector +
      token.toLowerCase().replaceFirst('0x', '').padLeft(64, '0');

  /// Null when [url] answers with [chainId], reads [railgunProxy]'s
  /// blocklist for [token] (`0x` addresses) and, given [logsContract] (the
  /// windows contract, `0x`; null where bridging is off), serves its logs
  /// over the engine's window; otherwise why it failed. Never throws.
  Future<PrivateUsdRpcCheckFailure?> check(
    String url, {
    required int chainId,
    required String railgunProxy,
    required String token,
    String? logsContract,
  }) async {
    final cancel = Completer<void>();
    final timer = Timer(deadline, () {
      if (!cancel.isCompleted) cancel.complete();
    });
    try {
      final chain = await _call(url, 'eth_chainId', const [], cancel.future);
      final answered = chain == null ? null : _quantity(chain.result);
      if (answered == null) return PrivateUsdRpcCheckFailure.unreachable;
      if (answered != BigInt.from(chainId)) {
        return PrivateUsdRpcCheckFailure.wrongChain;
      }
      final read = await _call(url, 'eth_call', [
        {'to': railgunProxy, 'data': _tokenBlocklistCall(token)},
        'latest',
      ], cancel.future);
      if (read == null) return PrivateUsdRpcCheckFailure.unreachable;
      // A paused proxy reverts every call: still a read served.
      if (!_isWord(read.result) && !_isRevert(read.error)) {
        return PrivateUsdRpcCheckFailure.callsRefused;
      }
      if (logsContract == null) return null;
      final head = await _call(url, 'eth_blockNumber', const [], cancel.future);
      final tip = head == null ? null : _quantity(head.result);
      if (tip == null) return PrivateUsdRpcCheckFailure.unreachable;
      var from = tip - BigInt.from(kPrivateUsdLogWindowBlocks - 1);
      if (from.isNegative) from = BigInt.zero;
      final logs = await _call(url, 'eth_getLogs', [
        {
          'address': logsContract,
          'topics': [_noTopic],
          'fromBlock': '0x${from.toRadixString(16)}',
          'toBlock': '0x${tip.toRadixString(16)}',
        },
      ], cancel.future);
      if (logs == null) return PrivateUsdRpcCheckFailure.unreachable;
      if (logs.result is List) return null;
      return logs.error == null
          ? PrivateUsdRpcCheckFailure.unreachable
          : PrivateUsdRpcCheckFailure.logsLimited;
    } finally {
      timer.cancel();
    }
  }

  /// One JSON-RPC call's answer, or null for none usable: a transport
  /// failure, too large an answer, one that is not a JSON object, or an HTTP
  /// error status without a JSON-RPC error (some providers answer 400 to a
  /// range they refuse, which is an answer).
  Future<_RpcAnswer?> _call(
    String url,
    String method,
    List<Object> params,
    Future<void> cancel,
  ) async {
    final NetworkHttpResponse response;
    try {
      response = await _client.request(
        'POST',
        Uri.parse(url),
        headers: const {
          HttpHeaders.contentTypeHeader: 'application/json',
          HttpHeaders.acceptHeader: 'application/json',
        },
        bodyBytes: utf8.encode(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': method,
            'params': params,
          }),
        ),
        timeout: timeout,
        cancelSignal: cancel,
      );
    } catch (error) {
      // The type only: a message can quote the URL.
      privateUsdLog('the RPC check failed (${error.runtimeType})');
      return null;
    }
    if (response.bodyBytes.length > maxBodyBytes) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final error = decoded['error'];
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    if (!ok && error == null) return null;
    return _RpcAnswer(result: decoded['result'], error: error);
  }

  void close() => _client.close();
}

class _RpcAnswer {
  const _RpcAnswer({required this.result, required this.error});

  final Object? result;
  final Object? error;
}

/// Whether [result] is one 32-byte word, as a bool or a number comes back.
bool _isWord(Object? result) =>
    result is String && RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(result);

/// Whether [error] is a revert the way the engine reads one (`evm_rpc.rs`):
/// geth's code 3, or "execution reverted" in the message.
bool _isRevert(Object? error) {
  if (error is! Map) return false;
  final message = error['message'];
  return error['code'] == 3 ||
      (message is String &&
          message.toLowerCase().contains('execution reverted'));
}

/// The number in a JSON-RPC quantity (`"0x1"`), or null when [result] is
/// not one.
BigInt? _quantity(Object? result) {
  if (result is! String ||
      !result.startsWith('0x') ||
      result.length < 3 ||
      result.length > 66) {
    return null;
  }
  return BigInt.tryParse(result.substring(2), radix: 16);
}
