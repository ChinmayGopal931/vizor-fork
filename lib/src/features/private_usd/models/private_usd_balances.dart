import 'package:flutter/foundation.dart';

import '../../../core/formatting/number_format.dart';
import '../../../rust/api/private_usd.dart' show ApiDeployment;
import 'railgun_models.dart';

/// A dollar token the balance counts, from the pinned deployment. Decimals
/// come from the deployment, never from the chain.
class PrivateUsdToken {
  const PrivateUsdToken({
    required this.address,
    required this.symbol,
    required this.decimals,
  });

  /// `0x`, lowercase.
  final String address;

  /// `USDC`, or `tUSD` for the testnet maker's token.
  final String symbol;
  final int decimals;

  /// The deployment's dollar tokens, the swap token first.
  static List<PrivateUsdToken> of(ApiDeployment deployment) => [
    for (final token in deployment.usdTokens)
      PrivateUsdToken(
        address: token.address.toLowerCase(),
        symbol: token.symbol,
        decimals: deployment.tokenDecimals,
      ),
  ];

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdToken &&
      other.address == address &&
      other.symbol == symbol &&
      other.decimals == decimals;

  @override
  int get hashCode => Object.hash(address, symbol, decimals);
}

/// One token's amounts by screening status, in its base units.
class PrivateUsdAsset {
  PrivateUsdAsset(
    this.token, {
    BigInt? available,
    BigInt? arriving,
    BigInt? blocked,
    BigInt? processing,
    BigInt? submitted,
  }) : available = available ?? BigInt.zero,
       arriving = arriving ?? BigInt.zero,
       blocked = blocked ?? BigInt.zero,
       processing = processing ?? BigInt.zero,
       submitted = submitted ?? BigInt.zero;

  final PrivateUsdToken token;

  /// `Spendable`.
  final BigInt available;

  /// `ShieldPending`: screening before it can be spent.
  final BigInt arriving;

  /// `ShieldBlocked`: screening refused it.
  final BigInt blocked;

  /// `ProofSubmitted`, `MissingInternalPOI`, `MissingExternalPOI`: a send's
  /// change, spendable again once the send settles.
  final BigInt processing;

  /// The part of [processing] whose proofs a screening node has taken and
  /// not yet validated (`ProofSubmitted`).
  final BigInt submitted;

  BigInt get total => available + arriving + blocked + processing;

  PrivateUsdAsset _plus(RailgunBalanceBucket bucket, BigInt amount) =>
      switch (bucket) {
        RailgunBalanceBucket.spendable => _copy(available: available + amount),
        RailgunBalanceBucket.shieldPending => _copy(
          arriving: arriving + amount,
        ),
        RailgunBalanceBucket.shieldBlocked => _copy(blocked: blocked + amount),
        RailgunBalanceBucket.proofSubmitted => _copy(
          processing: processing + amount,
          submitted: submitted + amount,
        ),
        RailgunBalanceBucket.missingInternalPoi ||
        RailgunBalanceBucket.missingExternalPoi => _copy(
          processing: processing + amount,
        ),
        RailgunBalanceBucket.spent => this,
      };

  PrivateUsdAsset _copy({
    BigInt? available,
    BigInt? arriving,
    BigInt? blocked,
    BigInt? processing,
    BigInt? submitted,
  }) => PrivateUsdAsset(
    token,
    available: available ?? this.available,
    arriving: arriving ?? this.arriving,
    blocked: blocked ?? this.blocked,
    processing: processing ?? this.processing,
    submitted: submitted ?? this.submitted,
  );

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdAsset &&
      other.token == token &&
      other.available == available &&
      other.arriving == arriving &&
      other.blocked == blocked &&
      other.processing == processing &&
      other.submitted == submitted;

  @override
  int get hashCode =>
      Object.hash(token, available, arriving, blocked, processing, submitted);
}

/// The Railgun balance as private USD. Dollar sums are in micro-dollars
/// (`$0.000001`); 1 USDC is treated as $1. Each asset keeps its token's own
/// base units.
class PrivateUsdBalances {
  PrivateUsdBalances(List<PrivateUsdAsset> assets)
    : assets = List.unmodifiable(assets);

  /// Known dollar tokens the wallet holds, in the deployment's order.
  final List<PrivateUsdAsset> assets;

  static const decimals = 6;

  BigInt get available => _sum((a) => a.available);
  BigInt get arriving => _sum((a) => a.arriving);
  BigInt get blocked => _sum((a) => a.blocked);
  BigInt get processing => _sum((a) => a.processing);
  BigInt get submitted => _sum((a) => a.submitted);
  BigInt get total => available + arriving + blocked + processing;

  /// The headline: what can be spent, plus a send's change still in flight.
  BigInt get spendable => available + processing;

  /// Screening refused some of it.
  bool get isBlocked => blocked > BigInt.zero;

  /// The tokens with anything in them, for the Assets list.
  List<PrivateUsdAsset> get held => [
    for (final asset in assets)
      if (asset.total > BigInt.zero) asset,
  ];

  /// Known tokens only, by screening status. The SDK lists every bucket of
  /// every token it knows, zeros included; other tokens (Sepolia's WETH, for
  /// one) are not dollars and are left out.
  static PrivateUsdBalances of(
    RailgunBalances balances,
    List<PrivateUsdToken> tokens,
  ) {
    final byAddress = <String, PrivateUsdAsset>{};
    for (final entry in balances.byBucket.entries) {
      for (final held in entry.value) {
        final address = held.token.toLowerCase();
        final token = tokens.where((t) => t.address == address).firstOrNull;
        if (token == null) continue;
        final asset = byAddress[address] ?? PrivateUsdAsset(token);
        byAddress[address] = asset._plus(entry.key, held.amount);
      }
    }
    return PrivateUsdBalances([
      for (final token in tokens) ?byAddress[token.address],
    ]);
  }

  // Each token's base units, as micro-dollars.
  BigInt _sum(BigInt Function(PrivateUsdAsset asset) amount) => assets.fold(
    BigInt.zero,
    (sum, asset) => sum + _microDollars(amount(asset), asset.token.decimals),
  );

  static BigInt _microDollars(BigInt amount, int tokenDecimals) {
    final shift = tokenDecimals - decimals;
    if (shift == 0) return amount;
    return shift > 0
        ? amount ~/ BigInt.from(10).pow(shift)
        : amount * BigInt.from(10).pow(-shift);
  }

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdBalances && listEquals(other.assets, assets);

  @override
  int get hashCode => Object.hashAll(assets);
}

/// `$1,234.56` for [microDollars], rounded down to the cent so a balance is
/// never overstated.
String formatPrivateUsd(BigInt microDollars) {
  final cents = microDollars.abs() ~/ BigInt.from(10000);
  final whole = formatGroupedInteger((cents ~/ BigInt.from(100)).toInt());
  final fraction = (cents % BigInt.from(100)).toString().padLeft(2, '0');
  return '${microDollars.isNegative ? '-' : ''}\$$whole.$fraction';
}

/// [microDollars] to the nearest cent, half up: how a payment or a fee
/// shows, so a debit's rows add up to it. A balance shows
/// [formatPrivateUsd], rounded down, never more than it holds.
String formatPrivateUsdNearest(BigInt microDollars) {
  final halfCent = BigInt.from(5000);
  return formatPrivateUsd(
    microDollars.isNegative ? microDollars - halfCent : microDollars + halfCent,
  );
}

/// The indicative zatoshi worth of [microDollars] at [zecUsdPrice], or null
/// without a usable price or with nothing to price (callers then hide the
/// line, as `fiatTextForZatoshi` does). Display only: never an amount to
/// spend.
BigInt? privateUsdZecEquivalentZatoshi(
  BigInt microDollars, {
  required double? zecUsdPrice,
}) {
  if (microDollars <= BigInt.zero ||
      zecUsdPrice == null ||
      !zecUsdPrice.isFinite ||
      zecUsdPrice <= 0) {
    return null;
  }
  final zec = microDollars.toDouble() / 1e6 / zecUsdPrice;
  if (!zec.isFinite || zec < 0) return null;
  return BigInt.from((zec * 1e8).floor());
}
