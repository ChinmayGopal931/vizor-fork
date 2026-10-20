import 'package:flutter/foundation.dart';

import '../../../rust/api/private_usd.dart' as rust;

/// How a deposit address or a deposit shows.
enum PrivateUsdDepositPhase {
  /// The address holds money not yet made private: "Received $X".
  received,

  /// It holds less than the relayer's minimum.
  underMinimum,

  /// The relayer asked to wait over 30 s, or could not be reached.
  waiting,

  /// Posted, until it mines: "Making it private…".
  makingPrivate,

  /// Mined: "Private, available in …" while Railgun screens it.
  private,

  /// Received, but refused, or the relayer's fee is above the cap.
  notShielding,
}

/// One line of the deposits' state, on the Private USD screen and in the
/// Receive USDC sheet.
@immutable
class PrivateUsdDepositLine {
  const PrivateUsdDepositLine({
    required this.index,
    required this.address,
    required this.phase,
    required this.amount,
    this.at,
  });

  /// The deposit address's index, and the address (EIP-55).
  final int index;
  final String address;
  final PrivateUsdDepositPhase phase;

  /// Token base units (6 decimals): what the address holds, what a deposit
  /// under way moves, or what a landed one brings.
  final BigInt amount;

  /// When a landed deposit landed.
  final DateTime? at;

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdDepositLine &&
      other.index == index &&
      other.address == address &&
      other.phase == phase &&
      other.amount == amount &&
      other.at == at;

  @override
  int get hashCode => Object.hash(index, address, phase, amount, at);
}

/// Whether a deposit (or rescue) is under way: kept and not finished.
bool privateUsdDepositUnderWay(rust.ApiDepositRecord record) =>
    record.state == rust.ApiDepositState.signed ||
    record.state == rust.ApiDepositState.sent;

/// When [record] landed, if it did.
DateTime? privateUsdDepositLandedAt(rust.ApiDepositRecord record) {
  final ended = record.endedAt;
  if (record.state != rust.ApiDepositState.landed || ended == null) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(ended * 1000);
}

/// What [pass] shows now, newest first: each deposit under way, each one
/// still being screened ([screening] after it landed), then each address
/// holding money with none under way (received, under the minimum, or not
/// shielding after a refusal or a fee above the cap).
List<PrivateUsdDepositLine> privateUsdDepositLines(
  rust.ApiDepositPass pass, {
  required DateTime now,
  required Duration screening,
}) {
  final lines = <PrivateUsdDepositLine>[];
  final underWay = <int>{};
  for (final record in pass.records) {
    final value = BigInt.tryParse(record.value) ?? BigInt.zero;
    switch (record.state) {
      case rust.ApiDepositState.sent:
        underWay.add(record.index);
        lines.add(
          PrivateUsdDepositLine(
            index: record.index,
            address: record.address,
            phase: PrivateUsdDepositPhase.makingPrivate,
            amount: value,
          ),
        );
      case rust.ApiDepositState.signed:
        underWay.add(record.index);
        lines.add(
          PrivateUsdDepositLine(
            index: record.index,
            address: record.address,
            phase: record.waiting
                ? PrivateUsdDepositPhase.waiting
                : PrivateUsdDepositPhase.received,
            amount: value,
          ),
        );
      case rust.ApiDepositState.landed:
        final at = privateUsdDepositLandedAt(record);
        if (at != null && now.difference(at) < screening) {
          lines.add(
            PrivateUsdDepositLine(
              index: record.index,
              address: record.address,
              phase: PrivateUsdDepositPhase.private,
              amount: BigInt.tryParse(record.arrives) ?? BigInt.zero,
              at: at,
            ),
          );
        }
      case rust.ApiDepositState.refused ||
          rust.ApiDepositState.reverted ||
          rust.ApiDepositState.replaced ||
          rust.ApiDepositState.expired:
        break;
    }
  }
  final minimum = BigInt.tryParse(pass.terms?.minValue ?? '');
  final feeTooHigh = pass.problem == rust.ApiPrivateUsdErrorCode.relayerFee;
  for (final used in pass.used) {
    final balance = BigInt.tryParse(used.balance) ?? BigInt.zero;
    if (balance <= BigInt.zero || underWay.contains(used.index)) continue;
    // Only the address's newest deposit says whether it was refused.
    final newest = pass.records
        .where(
          (record) =>
              record.index == used.index &&
              record.kind == rust.ApiDepositKind.shield,
        )
        .firstOrNull;
    final refused =
        newest?.state == rust.ApiDepositState.refused ||
        newest?.state == rust.ApiDepositState.reverted;
    final PrivateUsdDepositPhase phase;
    if (minimum != null && balance < minimum) {
      phase = PrivateUsdDepositPhase.underMinimum;
    } else if (refused || feeTooHigh) {
      phase = PrivateUsdDepositPhase.notShielding;
    } else {
      phase = PrivateUsdDepositPhase.received;
    }
    lines.add(
      PrivateUsdDepositLine(
        index: used.index,
        address: used.address,
        phase: phase,
        amount: balance,
      ),
    );
  }
  return lines;
}
