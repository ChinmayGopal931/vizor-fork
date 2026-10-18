import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpHeaders;

import 'package:flutter/foundation.dart';

import '../../../core/network/network_http_client.dart';

/// Why a user's own Ethereum RPC URL failed the check before saving.
enum PrivateUsdRpcCheckFailure {
  /// No answer in time, an HTTP or JSON-RPC error, or no chain id.
  unreachable,

  /// It answered for another chain than the deployment's.
  wrongChain,
}

/// Asks an Ethereum RPC URL for its chain (`eth_chainId`) before Settings
/// saves it, through [NetworkHttpClient]: Tor when Tor is on, a direct
/// connection otherwise, and never a fallback from one to the other. It is
/// bounded by [timeout] per request, [deadline] in all (a wait for Tor's
/// bootstrap included) and [maxBodyBytes] per answer. The client buffers an
/// answer before handing it over, so the size cap refuses a large answer; it
/// does not stop its download.
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

  static final _request = utf8.encode(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'eth_chainId',
      'params': <Object>[],
    }),
  );

  /// Null when [url] answers with [chainId]; otherwise why it failed. Never
  /// throws.
  Future<PrivateUsdRpcCheckFailure?> check(
    String url, {
    required int chainId,
  }) async {
    final cancel = Completer<void>();
    final timer = Timer(deadline, () {
      if (!cancel.isCompleted) cancel.complete();
    });
    try {
      final response = await _client.request(
        'POST',
        Uri.parse(url),
        headers: const {
          HttpHeaders.contentTypeHeader: 'application/json',
          HttpHeaders.acceptHeader: 'application/json',
        },
        bodyBytes: _request,
        timeout: timeout,
        cancelSignal: cancel.future,
      );
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.length > maxBodyBytes) {
        return PrivateUsdRpcCheckFailure.unreachable;
      }
      final answered = _parseEthChainId(utf8.decode(response.bodyBytes));
      if (answered == null) return PrivateUsdRpcCheckFailure.unreachable;
      return answered == BigInt.from(chainId)
          ? null
          : PrivateUsdRpcCheckFailure.wrongChain;
    } catch (error) {
      // The type only: a message can quote the URL.
      if (kDebugMode) {
        debugPrint('privateUsd: the RPC check failed (${error.runtimeType})');
      }
      return PrivateUsdRpcCheckFailure.unreachable;
    } finally {
      timer.cancel();
    }
  }

  void close() => _client.close();
}

/// The chain id in an `eth_chainId` answer (`{"result": "0x1"}`), or null
/// when [body] is not one.
BigInt? _parseEthChainId(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final result = decoded['result'];
  if (result is! String ||
      !result.startsWith('0x') ||
      result.length < 3 ||
      result.length > 66) {
    return null;
  }
  return BigInt.tryParse(result.substring(2), radix: 16);
}
