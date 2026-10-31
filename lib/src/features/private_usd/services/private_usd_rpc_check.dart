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
/// saves it, for its head and the engine's pinned read at the head's hash
/// (`eth_getBlockByNumber`, then `eth_call` of `tokenBlocklist(address)` on
/// Railgun's proxy at `{"blockHash"}`, as `read_swap` reads a swap; a
/// transaction RPC may forward no contract reads at all, and a plan may not
/// serve a read by hash) and, where bridging runs, for the swap contract's
/// logs over the engine's window ending at that head (`eth_getLogs`): a
/// provider's plan may cap the range lower, which would leave a bridge
/// waiting on its payout. A rate limit (HTTP 429, or the JSON-RPC limit code)
/// is no verdict on the RPC and reads as unreachable. All through
/// [NetworkHttpClient]: Tor when Tor is on, a direct connection otherwise,
/// and never a fallback from one to the other. It is bounded by [timeout]
/// per request, [deadline] in all (a wait for Tor's bootstrap included, so
/// sized for four requests over Tor) and [maxBodyBytes] per answer. The
/// client buffers an answer before handing it over, so the size cap refuses
/// a large answer; it does not stop its download.
///
/// It never logs the URL, which can hold a key.
class PrivateUsdRpcChecker {
  PrivateUsdRpcChecker({
    NetworkHttpClient? networkClient,
    this.timeout = const Duration(seconds: 20),
    this.deadline = const Duration(seconds: 90),
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
      final (tip, failure) = await _pinnedRead(
        url,
        railgunProxy,
        token,
        cancel.future,
      );
      if (failure != null) return failure;
      if (logsContract == null) return null;
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
      if (logs == null || logs.rateLimited) {
        return PrivateUsdRpcCheckFailure.unreachable;
      }
      if (logs.result is List) return null;
      return logs.error == null
          ? PrivateUsdRpcCheckFailure.unreachable
          : PrivateUsdRpcCheckFailure.logsLimited;
    } finally {
      timer.cancel();
    }
  }

  /// The RPC's head and the engine's pinned read at its hash (`read_swap` in
  /// `evm_rpc.rs`), as the head's number and why it failed. A node behind
  /// its balancer may not know the newest hash yet (the engine reads again
  /// too), so a failed read gets one more try at a fresh head.
  Future<(BigInt?, PrivateUsdRpcCheckFailure?)> _pinnedRead(
    String url,
    String railgunProxy,
    String token,
    Future<void> cancel,
  ) async {
    for (var attempt = 1; ; attempt++) {
      final head = await _call(url, 'eth_getBlockByNumber', const [
        'latest',
        false,
      ], cancel);
      final block = head?.result;
      final hash = block is Map ? block['hash'] : null;
      final tip = block is Map ? _quantity(block['number']) : null;
      if (head == null || head.rateLimited || tip == null || !_isWord(hash)) {
        return (null, PrivateUsdRpcCheckFailure.unreachable);
      }
      final read = await _call(url, 'eth_call', [
        {'to': railgunProxy, 'data': _tokenBlocklistCall(token)},
        {'blockHash': hash},
      ], cancel);
      if (read == null || read.rateLimited) {
        return (null, PrivateUsdRpcCheckFailure.unreachable);
      }
      // A paused proxy reverts every call: still a read served.
      if (_isWord(read.result) || _isRevert(read.error)) return (tip, null);
      if (attempt == 2) return (null, PrivateUsdRpcCheckFailure.callsRefused);
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
    if (error == null && !decoded.containsKey('result')) return null;
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    if (!ok && error == null) return null;
    return _RpcAnswer(
      result: decoded['result'],
      error: error,
      rateLimited:
          response.statusCode == 429 ||
          (error is Map && error['code'] == _limitExceeded),
    );
  }

  void close() => _client.close();
}

/// JSON-RPC's "limit exceeded" (EIP-1474), which providers answer a rate
/// limit with.
const _limitExceeded = -32005;

class _RpcAnswer {
  const _RpcAnswer({
    required this.result,
    required this.error,
    required this.rateLimited,
  });

  final Object? result;
  final Object? error;

  /// A rate limit: the RPC may serve the same request a moment later, so
  /// the answer says nothing about what it serves.
  final bool rateLimited;
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
