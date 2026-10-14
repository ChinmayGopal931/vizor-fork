import 'dart:convert';

/// The Railgun page's typed requests, results and events (plan reference
/// §6.2). Kotlin forwards params, results and events as raw JSON text; these
/// models are the only place they are read, so a Swift host can reuse them.
///
/// Token amounts travel as decimal strings and EVM addresses as `0x` hex;
/// addresses are kept lowercase here so they compare by value.

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

/// What `refresh` answers: every token in every bucket the SDK lists.
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
      if (theirs == null || theirs.length != entry.value.length) return false;
      for (var i = 0; i < theirs.length; i++) {
        if (theirs[i] != entry.value[i]) return false;
      }
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
      _listEquals(other.nullifiers, nullifiers);

  @override
  int get hashCode => Object.hash(tree, Object.hashAll(nullifiers));
}

/// A proved send for a broadcaster, and what it spends, to settle it by from
/// the chain.
class RailgunRelayedProof {
  const RailgunRelayedProof({required this.request, required this.spends});

  final RailgunRelayRequest request;
  final List<RailgunNullifiers> spends;

  /// `transfer` and `unshield`'s result, checked to be a `transact` call for
  /// [broadcaster] that spends notes; anything else is refused, never posted.
  static RailgunRelayedProof parse(
    Object? json, {
    required RailgunBroadcaster broadcaster,
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
    );
  }
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

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
