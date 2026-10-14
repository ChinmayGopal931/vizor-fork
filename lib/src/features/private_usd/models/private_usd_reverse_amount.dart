/// Reverse amounts (plan M6 traps, reference §9.4 S4): dollars with at most
/// 2 decimals, worked out from the typed digits only (no floating point),
/// in the swap token's base units. The swap token has 6 decimals on both
/// networks (reference §7.1), so one cent is 10,000 units; Rust refuses
/// `units` that are not whole cents.
library;

final _unitsPerCent = BigInt.from(10000);
final _centsPerDollar = BigInt.from(100);
final _basisPoints = BigInt.from(10000);

/// The most one reverse quote can name: Rust takes `units` as a `u32`
/// (4,294,967,295), in whole cents.
final kPrivateUsdReverseMaxUnits = BigInt.from(4294960000);

final _dollars = RegExp(r'^(\d*)(?:\.(\d*))?$');

/// [text] as base units, or null when it is empty, malformed, has more
/// than 2 decimals, is zero, or is more than one quote can name.
BigInt? privateUsdDollarUnits(String text) {
  final match = _dollars.firstMatch(text.trim());
  if (match == null) return null;
  final whole = match[1] ?? '';
  final fraction = match[2] ?? '';
  if ((whole.isEmpty && fraction.isEmpty) || fraction.length > 2) return null;
  final cents = BigInt.parse(
    '${whole.isEmpty ? '0' : whole}${fraction.padRight(2, '0')}',
  );
  if (cents == BigInt.zero) return null;
  final units = cents * _unitsPerCent;
  return units > kPrivateUsdReverseMaxUnits ? null : units;
}

/// Something more than zero was typed, valid or not: a zero still being
/// typed ("0.0") is not flagged.
bool privateUsdDollarIsPositive(String text) {
  final match = _dollars.firstMatch(text.trim());
  if (match == null) return text.trim().isNotEmpty;
  return '${match[1] ?? ''}${match[2] ?? ''}'.replaceAll('0', '').isNotEmpty;
}

/// More than 2 decimals were typed.
bool privateUsdDollarTooPrecise(String text) {
  final match = _dollars.firstMatch(text.trim());
  return match != null && (match[2] ?? '').length > 2;
}

/// [units] as the amount field shows it, rounded down to the cent: "12.30",
/// "5", "0.05".
String privateUsdDollarText(BigInt units) {
  final cents = units ~/ _unitsPerCent;
  final whole = cents ~/ _centsPerDollar;
  final fraction = (cents % _centsPerDollar).toString().padLeft(2, '0');
  return fraction == '00' ? '$whole' : '$whole.$fraction';
}

/// Max (zapp `PrivateUsdReverseVM.onMax`): [available] less Railgun's
/// unshield fee on it and the relayer's funding fee, rounded down to the
/// cent (and to the most one quote can name); zero when the fees take it
/// all.
BigInt privateUsdReverseMax({
  required BigInt available,
  required int unshieldBasisPoints,
  required BigInt fundingFee,
}) {
  final unshieldFee =
      available * BigInt.from(unshieldBasisPoints) ~/ _basisPoints;
  final left = available - unshieldFee - fundingFee;
  if (left <= BigInt.zero) return BigInt.zero;
  final rounded = left ~/ _unitsPerCent * _unitsPerCent;
  return rounded > kPrivateUsdReverseMaxUnits
      ? kPrivateUsdReverseMaxUnits
      : rounded;
}
