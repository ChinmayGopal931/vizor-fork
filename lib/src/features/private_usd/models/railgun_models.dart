import 'dart:convert';

import 'package:flutter/foundation.dart';

// The Railgun page's typed requests, results and events. The Kotlin and
// Swift hosts forward params, results and events as raw JSON text; these
// models are the only place they are read.
//
// Token amounts travel as decimal strings and EVM addresses as `0x` hex;
// addresses are kept lowercase here so they compare by value.

/// A page result or event this build cannot read. A page that answers a
/// method with the wrong shape fails that call.
class RailgunProtocolException implements Exception {
  const RailgunProtocolException(this.message);

  final String message;

  @override
  String toString() => 'RailgunProtocolException: $message';
}

/// Where a note stands with Railgun's screening: only [spendable] can be sent
/// or unshielded.
enum RailgunBalanceBucket {
  spendable('Spendable'),
  shieldPending('ShieldPending'),
  shieldBlocked('ShieldBlocked'),
  proofSubmitted('ProofSubmitted'),
  missingInternalPoi('MissingInternalPOI'),
  missingExternalPoi('MissingExternalPOI'),
  spent('Spent');

  const RailgunBalanceBucket(this.wireName);

  final String wireName;

  static RailgunBalanceBucket? fromWire(String name) {
    for (final bucket in values) {
      if (bucket.wireName == name) return bucket;
    }
    return null;
  }
}

class RailgunTokenAmount {
  const RailgunTokenAmount({required this.token, required this.amount});

  /// `0x`, lowercase.
  final String token;

  /// Base units of [token].
  final BigInt amount;

  @override
  bool operator ==(Object other) =>
      other is RailgunTokenAmount &&
      other.token == token &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(token, amount);

  @override
  String toString() => 'RailgunTokenAmount($token, $amount)';
}

/// How the wallet's screening went the last time the engine tried: asking
/// the screening nodes about its notes, and sending them the proofs its own
/// sends need. A send's change stays `MissingInternalPOI` until a node takes
/// those proofs.
enum RailgunScreening {
  ok('ok'),

  /// The check or a proof failed: a node unreachable, or one refusing what
  /// it was sent. The engine tries again after every scan.
  failed('failed');

  const RailgunScreening(this.wireName);

  final String wireName;

  static RailgunScreening? fromWire(Object? name) {
    for (final screening in values) {
      if (screening.wireName == name) return screening;
    }
    return null;
  }
}

/// What `refresh` answers: the balances, the private sends received, and
/// how the screening last went.
class RailgunRefresh {
  const RailgunRefresh({
    required this.balances,
    required this.screening,
    this.received,
  });

  final RailgunBalances balances;
  final RailgunScreening screening;

  /// Null when the page could not read its history.
  final List<RailgunReceipt>? received;

  static RailgunRefresh parse(Object? json) {
    final map = _object(json, 'refresh');
    final screening = RailgunScreening.fromWire(map['screening']);
    if (screening == null) {
      throw const RailgunProtocolException('screening is unreadable');
    }
    return RailgunRefresh(
      balances: RailgunBalances.parse(map['balances']),
      screening: screening,
      received: RailgunReceipt.parseAll(map['received']),
    );
  }
}

/// A private send the wallet received, from the notes its sync decrypted.
@immutable
class RailgunReceipt {
  const RailgunReceipt({
    required this.txid,
    required this.token,
    required this.amount,
    this.bucket,
    this.at,
    this.sender,
  });

  /// The Ethereum transaction that carried it, `0x` hex.
  final String txid;

  /// `0x`, lowercase.
  final String token;
  final BigInt amount;

  /// Where it stands with the screening; null for a bucket this build does
  /// not know.
  final RailgunBalanceBucket? bucket;

  /// When its block was made, where the engine knows.
  final DateTime? at;

  /// The sender's `0zk` address, only where the sender showed it.
  final String? sender;

  /// This receipt, dated [fallback] where the engine had no time for it.
  RailgunReceipt orDated(DateTime fallback) => at != null
      ? this
      : RailgunReceipt(
          txid: txid,
          token: token,
          amount: amount,
          bucket: bucket,
          at: fallback,
          sender: sender,
        );

  /// Screened and spendable, or spent since.
  bool get settled =>
      bucket == RailgunBalanceBucket.spendable ||
      bucket == RailgunBalanceBucket.spent;

  /// Null where the page had no history to give. A receipt it cannot read is
  /// left out: the history never fails the balances.
  static List<RailgunReceipt>? parseAll(Object? json) {
    if (json is! List) return null;
    return List.unmodifiable([for (final item in json) ?_receipt(item)]);
  }

  static RailgunReceipt? _receipt(Object? item) {
    if (item is! Map<String, dynamic>) return null;
    final txid = item['txid'];
    final timestamp = item['timestamp'];
    final bucket = item['bucket'];
    final sender = item['sender'];
    try {
      if (txid is! String || !_txidPattern.hasMatch(txid)) return null;
      return RailgunReceipt(
        txid: txid.toLowerCase(),
        token: _evmAddress(item['token'], 'token'),
        amount: _decimal(item['amount'], 'amount'),
        bucket: bucket is String ? RailgunBalanceBucket.fromWire(bucket) : null,
        at: timestamp is int && timestamp > 0
            ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
            : null,
        sender: sender is String && sender.startsWith('0zk1') ? sender : null,
      );
    } on RailgunProtocolException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RailgunReceipt &&
      other.txid == txid &&
      other.token == token &&
      other.amount == amount &&
      other.bucket == bucket &&
      other.at == at &&
      other.sender == sender;

  @override
  int get hashCode => Object.hash(txid, token, amount, bucket, at, sender);
}

/// Every token in every bucket the SDK lists.
class RailgunBalances {
  const RailgunBalances(this.byBucket);

  final Map<RailgunBalanceBucket, List<RailgunTokenAmount>> byBucket;

  /// Known buckets only; a bucket a newer engine adds is left out. An amount
  /// or token it cannot read fails the whole answer.
  static RailgunBalances parse(Object? json) {
    final map = _object(json, 'balances');
    final byBucket = <RailgunBalanceBucket, List<RailgunTokenAmount>>{};
    for (final entry in map.entries) {
      final bucket = RailgunBalanceBucket.fromWire(entry.key);
      if (bucket == null) continue;
      final amounts = entry.value;
      if (amounts is! List) {
        throw RailgunProtocolException('bucket ${entry.key} is not a list');
      }
      byBucket[bucket] = List.unmodifiable([
        for (final item in amounts.map((item) => _object(item, 'an amount')))
          RailgunTokenAmount(
            token: _evmAddress(item['token'], 'token'),
            amount: _decimal(item['amount'], 'amount'),
          ),
      ]);
    }
    return RailgunBalances(Map.unmodifiable(byBucket));
  }

  @override
  bool operator ==(Object other) {
    if (other is! RailgunBalances) return false;
    if (other.byBucket.length != byBucket.length) return false;
    for (final entry in byBucket.entries) {
      final theirs = other.byBucket[entry.key];
      if (theirs == null || !listEquals(theirs, entry.value)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered(
    byBucket.entries.map((e) => Object.hash(e.key, Object.hashAll(e.value))),
  );
}

/// Railgun's withdrawal fee, in basis points of what is unshielded.
class RailgunFees {
  const RailgunFees({required this.unshieldBasisPoints});

  final int unshieldBasisPoints;

  static final _denominator = BigInt.from(10000);

  /// Rounds down, as the engine does.
  BigInt unshieldFee(BigInt amount) =>
      amount * BigInt.from(unshieldBasisPoints) ~/ _denominator;

  @override
  bool operator ==(Object other) =>
      other is RailgunFees && other.unshieldBasisPoints == unshieldBasisPoints;

  @override
  int get hashCode => unshieldBasisPoints.hashCode;
}

/// `start`'s params. `rpcUrls` may hold a keyed URL: never log them.
class RailgunStartParams {
  const RailgunStartParams({
    required this.network,
    required this.rpcUrls,
    required this.poiNodeUrls,
    this.debug = false,
  });

  /// `mainnet` or `sepolia`.
  final String network;
  final List<String> rpcUrls;
  final List<String> poiNodeUrls;
  final bool debug;

  String toJson() => jsonEncode({
    'network': network,
    'rpcUrls': rpcUrls,
    'poiNodeUrls': poiNodeUrls,
    'debug': debug,
  });

  @override
  String toString() => 'RailgunStartParams($network)';
}

/// `start`'s result.
class RailgunStartResult {
  const RailgunStartResult(this.fees);

  final RailgunFees fees;

  static RailgunStartResult parse(Object? json) {
    final fees = _object(_object(json, 'start')['fees'], 'fees');
    final unshield = fees['unshield'];
    if (unshield is! int || unshield < 0) {
      throw const RailgunProtocolException('fees.unshield is unreadable');
    }
    return RailgunStartResult(RailgunFees(unshieldBasisPoints: unshield));
  }
}

/// `openWallet`'s params: the wallet's mnemonic and its storage key. Drop the
/// object once the call is made; never log it.
class RailgunOpenWalletParams {
  const RailgunOpenWalletParams({
    required this.encryptionKey,
    required this.mnemonic,
  });

  /// 64 hex characters.
  final String encryptionKey;
  final String mnemonic;

  String toJson() =>
      jsonEncode({'encryptionKey': encryptionKey, 'mnemonic': mnemonic});

  @override
  String toString() => 'RailgunOpenWalletParams(<redacted>)';
}

/// `openWallet`'s result: the `0zk` address the engine opened. The caller
/// checks it against the address Rust derives.
class RailgunOpenWalletResult {
  const RailgunOpenWalletResult(this.address);

  final String address;

  static RailgunOpenWalletResult parse(Object? json) {
    final address = _object(json, 'openWallet')['address'];
    if (address is! String || !address.startsWith('0zk1')) {
      throw const RailgunProtocolException('the address is unreadable');
    }
    return RailgunOpenWalletResult(address);
  }
}

/// Where a send goes, written as the address it goes to.
sealed class RailgunDestination {
  const RailgunDestination();

  String get text;
}

/// Another `0zk` address: the amount and both ends stay private.
class RailgunPrivateDestination extends RailgunDestination {
  const RailgunPrivateDestination(this.address);

  final String address;

  @override
  String get text => address;
}

/// An Ethereum address, which then publicly holds the amount.
class RailgunPublicDestination extends RailgunDestination {
  const RailgunPublicDestination(this.address);

  /// `0x`, as the user's checksummed form or lowercase.
  final String address;

  @override
  String get text => address;
}

class RailgunTransfer {
  const RailgunTransfer({
    required this.to,
    required this.token,
    required this.amount,
  });

  final RailgunDestination to;
  final String token;
  final BigInt amount;
}

/// A broadcaster's terms: it sends a Railgun transaction, paying its gas, for
/// a fee note to [railgunAddress].
class RailgunBroadcaster {
  const RailgunBroadcaster({
    required this.chainId,
    required this.railgunProxy,
    required this.railgunAddress,
    required this.feeToken,
    required this.minFee,
    required this.maxGasPrice,
    this.feePerUnitGas,
    this.feeExpiresAt,
  });

  final int chainId;
  final String railgunProxy;
  final String railgunAddress;
  final String feeToken;

  /// The least a fee note carries.
  final BigInt minFee;

  /// The most it pays per gas.
  final BigInt maxGasPrice;

  /// Base units of [feeToken] per 10^18 wei of gas cost.
  final BigInt? feePerUnitGas;

  /// Unix seconds until which a fee worked out at [feePerUnitGas] holds.
  final int? feeExpiresAt;

  Map<String, Object?> toWire() => {
    'chainId': chainId,
    'railgunProxy': railgunProxy,
    'railgunAddress': railgunAddress,
    'token': feeToken,
    'minFee': minFee.toString(),
    'feePerUnitGas': feePerUnitGas?.toString(),
    'maxGasPrice': maxGasPrice.toString(),
  };
}

/// What a broadcaster is asked to send, as proved: the same bytes name the
/// same send until it settles.
class RailgunRelayRequest {
  const RailgunRelayRequest({
    required this.chainId,
    required this.to,
    required this.data,
    required this.value,
  });

  final int chainId;
  final String to;
  final String data;
  final BigInt value;

  @override
  bool operator ==(Object other) =>
      other is RailgunRelayRequest &&
      other.chainId == chainId &&
      other.to == to &&
      other.data == data &&
      other.value == value;

  @override
  int get hashCode => Object.hash(chainId, to, data, value);

  @override
  String toString() =>
      'RailgunRelayRequest(to: $to, ${data.length ~/ 2 - 1} bytes)';
}

/// The nullifiers one Railgun transaction spends in note tree [tree]: all of
/// them land together or none do.
class RailgunNullifiers {
  const RailgunNullifiers({required this.tree, required this.nullifiers});

  final int tree;
  final List<String> nullifiers;

  @override
  bool operator ==(Object other) =>
      other is RailgunNullifiers &&
      other.tree == tree &&
      listEquals(other.nullifiers, nullifiers);

  @override
  int get hashCode => Object.hash(tree, Object.hashAll(nullifiers));
}

/// A proved send for a broadcaster, and what it spends, to settle it by from
/// the chain.
class RailgunRelayedProof {
  const RailgunRelayedProof({
    required this.request,
    required this.spends,
    this.json = '',
  });

  final RailgunRelayRequest request;
  final List<RailgunNullifiers> spends;

  /// The page's result as it came, which Rust keeps before anything is
  /// posted (`private_usd_send_log_put`). Held in memory only: never log it
  /// or store it from Dart.
  final String json;

  /// `transfer` and `unshield`'s result, checked to be a `transact` call for
  /// [broadcaster] that spends notes; anything else is refused, never posted.
  /// [raw] is the result's text, kept as [json].
  static RailgunRelayedProof parse(
    Object? json, {
    required RailgunBroadcaster broadcaster,
    String raw = '',
  }) {
    final result = _object(json, 'proof');
    final chainId = result['chainId'];
    if (chainId is! int) {
      throw const RailgunProtocolException('chainId is unreadable');
    }
    final to = _evmAddress(result['to'], 'to');
    final data = result['data'];
    if (data is! String || !data.startsWith('0x')) {
      throw const RailgunProtocolException('data is unreadable');
    }
    final value = _decimal(result['value'], 'value');
    final spendsJson = result['spends'];
    if (spendsJson is! List) {
      throw const RailgunProtocolException('spends is unreadable');
    }
    final spends = [
      for (final spend in spendsJson) _nullifiers(_object(spend, 'spend')),
    ];
    final isForBroadcaster =
        chainId == broadcaster.chainId &&
        to == broadcaster.railgunProxy.toLowerCase() &&
        value == BigInt.zero;
    final spendsNotes =
        spends.isNotEmpty && spends.every((s) => s.nullifiers.isNotEmpty);
    if (!isForBroadcaster || !spendsNotes) {
      throw const RailgunProtocolException(
        "the page's transaction isn't a transact call for the broadcaster",
      );
    }
    return RailgunRelayedProof(
      request: RailgunRelayRequest(
        chainId: chainId,
        to: to,
        data: data,
        value: value,
      ),
      spends: List.unmodifiable(spends),
      json: raw,
    );
  }

  @override
  String toString() => 'RailgunRelayedProof($request, ${spends.length} trees)';
}

class RailgunReverseCostRequest {
  const RailgunReverseCostRequest({
    required this.amount,
    required this.railgun,
    required this.fee,
  });

  final BigInt amount;
  final String railgun;

  /// Paid to the relayer from what is unshielded, on top of [amount].
  final BigInt fee;

  String toJson() => jsonEncode({
    'amount': amount.toString(),
    'railgun': railgun,
    'fee': fee.toString(),
  });
}

class RailgunContractCall {
  const RailgunContractCall({required this.to, required this.data});

  final String to;
  final String data;
}

class RailgunReverseRequest {
  const RailgunReverseRequest({
    required this.amount,
    required this.railgun,
    required this.token,
    required this.calls,
    required this.relayAdapt,
    required this.fee,
  });

  final BigInt amount;
  final String railgun;
  final String token;
  final List<RailgunContractCall> calls;
  final String relayAdapt;
  final BigInt fee;

  String toJson() => jsonEncode({
    'amount': amount.toString(),
    'railgun': railgun,
    'token': token,
    'calls': [
      for (final call in calls) {'to': call.to, 'data': call.data},
    ],
    'relayAdapt': relayAdapt,
    'fee': fee.toString(),
  });
}

class RailgunReverseCost {
  const RailgunReverseCost({required this.debit, required this.railgunFee});

  final BigInt debit;
  final BigInt railgunFee;

  static RailgunReverseCost parse(Object? json) {
    final cost = _object(json, 'reverseCost');
    return RailgunReverseCost(
      debit: _decimal(cost['debit'], 'debit'),
      railgunFee: _decimal(cost['railgunFee'], 'railgunFee'),
    );
  }
}

class RailgunReverseTransaction {
  const RailgunReverseTransaction({
    required this.to,
    required this.data,
    required this.value,
    required this.cost,
  });

  final String to;
  final String data;
  final BigInt value;
  final RailgunReverseCost cost;

  /// `prepareReverse`'s result, checked to fund through [relayAdapt] with no
  /// ETH attached.
  static RailgunReverseTransaction parse(
    Object? json, {
    required String relayAdapt,
  }) {
    final result = _object(json, 'prepareReverse');
    final to = _evmAddress(result['to'], 'to');
    final data = result['data'];
    if (data is! String || !data.startsWith('0x')) {
      throw const RailgunProtocolException('data is unreadable');
    }
    final value = _decimal(result['value'], 'value');
    if (to != relayAdapt.toLowerCase() || value != BigInt.zero) {
      throw const RailgunProtocolException('unexpected funding destination');
    }
    return RailgunReverseTransaction(
      to: to,
      data: data,
      value: value,
      cost: RailgunReverseCost.parse(result['cost']),
    );
  }

  @override
  String toString() => 'RailgunReverseTransaction(to: $to)';
}

/// The notes tree ([utxo]) or the transaction-id tree screening reads
/// ([txid]).
enum RailgunMerkletree { utxo, txid }

enum RailgunScanStatus {
  started('Started'),
  updated('Updated'),
  complete('Complete'),
  incomplete('Incomplete');

  const RailgunScanStatus(this.wireName);

  final String wireName;
}

/// An event the page sent, decoded; `null` from [RailgunEvent.decode] for
/// what this build does not read.
sealed class RailgunEvent {
  const RailgunEvent();

  /// Decodes one raw `{event, data}` message. Unknown events, and known ones
  /// it cannot read, are dropped.
  static RailgunEvent? decode(String raw) {
    final Object? message;
    try {
      message = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (message is! Map<String, dynamic>) return null;
    final data = message['data'];
    switch (message['event']) {
      case 'scan':
        if (data is! Map<String, dynamic>) return null;
        final tree = switch (data['tree']) {
          'utxo' => RailgunMerkletree.utxo,
          'txid' => RailgunMerkletree.txid,
          _ => null,
        };
        final status = RailgunScanStatus.values
            .where((s) => s.wireName == data['status'])
            .firstOrNull;
        final progress = data['progress'];
        if (tree == null || status == null) return null;
        return RailgunScanEvent(
          tree: tree,
          status: status,
          progress: progress is num ? progress.toDouble() : 0,
        );
      case 'proof':
        if (data is! Map<String, dynamic>) return null;
        final progress = data['progress'];
        if (progress is! num) return null;
        final status = data['status'];
        return RailgunProofEvent(
          progress: progress.toDouble(),
          status: status is String ? status : '',
        );
      case 'screening':
        if (data is! Map<String, dynamic>) return null;
        return RailgunScreeningEvent.decode(data);
      case 'log':
        return data is String ? RailgunLogEvent(data) : null;
      default:
        return null;
    }
  }
}

/// [progress] runs from 0 to 1.
class RailgunScanEvent extends RailgunEvent {
  const RailgunScanEvent({
    required this.tree,
    required this.status,
    required this.progress,
  });

  final RailgunMerkletree tree;
  final RailgunScanStatus status;
  final double progress;

  @override
  bool operator ==(Object other) =>
      other is RailgunScanEvent &&
      other.tree == tree &&
      other.status == status &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(tree, status, progress);
}

/// [progress] runs from 0 to 1.
class RailgunProofEvent extends RailgunEvent {
  const RailgunProofEvent({required this.progress, required this.status});

  final double progress;
  final String status;

  @override
  bool operator ==(Object other) =>
      other is RailgunProofEvent &&
      other.progress == progress &&
      other.status == status;

  @override
  int get hashCode => Object.hash(progress, status);
}

/// What the page's screening work is doing now, each step null while idle:
/// catching up on Railgun's transaction ids ([txids], their share done),
/// downloading proving files ([downloading], with [download] their share
/// when known), and proving POIs ([proving]). The page sends the whole state
/// on every change, so the latest one is all that is running.
class RailgunScreeningEvent extends RailgunEvent {
  const RailgunScreeningEvent({
    this.txids,
    this.downloading = false,
    this.download,
    this.proving,
  });

  final double? txids;
  final bool downloading;
  final double? download;
  final RailgunPoiProving? proving;

  /// Nothing running.
  bool get isIdle => txids == null && !downloading && proving == null;

  /// A step it cannot read is left out rather than failing the rest.
  static RailgunScreeningEvent decode(Map<String, dynamic> data) {
    double? share(Object? step) {
      final progress = step is Map<String, dynamic> ? step['progress'] : null;
      return progress is num
          ? progress.toDouble().clamp(0.0, 1.0).toDouble()
          : null;
    }

    final download = data['download'];
    final proving = data['proving'];
    RailgunPoiProving? proof;
    if (proving is Map<String, dynamic>) {
      final index = proving['index'];
      final count = proving['count'];
      if (index is int && count is int && index >= 1 && count >= index) {
        proof = RailgunPoiProving(
          index: index,
          count: count,
          progress: share(proving) ?? 0,
        );
      }
    }
    return RailgunScreeningEvent(
      txids: share(data['txids']),
      downloading: download is Map<String, dynamic>,
      download: share(download),
      proving: proof,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RailgunScreeningEvent &&
      other.txids == txids &&
      other.downloading == downloading &&
      other.download == download &&
      other.proving == proving;

  @override
  int get hashCode => Object.hash(txids, downloading, download, proving);
}

/// POI proof [index] (from 1) of [count], [progress] 0 to 1.
class RailgunPoiProving {
  const RailgunPoiProving({
    required this.index,
    required this.count,
    required this.progress,
  });

  final int index;
  final int count;
  final double progress;

  @override
  bool operator ==(Object other) =>
      other is RailgunPoiProving &&
      other.index == index &&
      other.count == count &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(index, count, progress);
}

/// An engine or console line, sent only from a page loaded with `debug`. It
/// can quote anything the engine saw: never log it unredacted.
class RailgunLogEvent extends RailgunEvent {
  const RailgunLogEvent(this.message);

  final String message;
}

Map<String, dynamic> _object(Object? json, String what) {
  if (json is Map<String, dynamic>) return json;
  throw RailgunProtocolException('$what is not an object');
}

final _evmAddressPattern = RegExp(r'^0x[0-9a-fA-F]{40}$');
final _txidPattern = RegExp(r'^0x[0-9a-fA-F]{64}$');
final _decimalPattern = RegExp(r'^[0-9]+$');

String _evmAddress(Object? value, String what) {
  if (value is String && _evmAddressPattern.hasMatch(value)) {
    return value.toLowerCase();
  }
  throw RailgunProtocolException('$what is not an address');
}

BigInt _decimal(Object? value, String what) {
  if (value is String && _decimalPattern.hasMatch(value)) {
    return BigInt.parse(value);
  }
  throw RailgunProtocolException('$what is not a decimal amount');
}

RailgunNullifiers _nullifiers(Map<String, dynamic> spend) {
  final tree = spend['tree'];
  final nullifiers = spend['nullifiers'];
  if (tree is! int || nullifiers is! List) {
    throw const RailgunProtocolException('a spend is unreadable');
  }
  return RailgunNullifiers(
    tree: tree,
    nullifiers: List.unmodifiable([
      for (final nullifier in nullifiers)
        if (nullifier is String)
          nullifier
        else
          throw const RailgunProtocolException('a nullifier is unreadable'),
    ]),
  );
}
