import 'package:flutter/foundation.dart';

import '../../../rust/api/private_usd.dart' as rust;
import '../../address_book/models/address_format_validator.dart';
import '../private_usd_copy.dart';
import '../services/private_usd_spend_guard.dart';
import 'private_usd_balances.dart';
import 'railgun_models.dart';

/// Private USD sends and withdrawals (plan M7; reference §6.7, §9.4 S8):
/// what the form asks for, what a send costs, how it ended, and the form's
/// rules (zapp `PrivateUsdSendForm`). Amounts are token base units
/// ([BigInt]), worked out from the typed digits only.

/// Fixed by the button that opened the screen (reference §9.1 rule 1).
enum PrivateUsdSendMode {
  /// To another Railgun `0zk` address: it stays private.
  private,

  /// To a public `0x` address: it leaves Railgun, and Railgun keeps its
  /// unshield fee.
  withdraw;

  String get path => switch (this) {
    PrivateUsdSendMode.private => '/private-usd/send',
    PrivateUsdSendMode.withdraw => '/private-usd/withdraw',
  };
}

/// Where the send flow is (zapp `PrivateUsdSendPhase`).
enum PrivateUsdSendPhase { form, review, sending, done }

/// What a running send is doing, for its status screen.
enum PrivateUsdSendStep {
  /// Checking the relayer still holds the confirmed fee.
  pricing,

  /// The page proves it (`proof` events).
  proving,

  /// Kept: the relayer is asked to send it, then Vizor waits for a block.
  posting,
}

@immutable
class PrivateUsdSendRequest {
  const PrivateUsdSendRequest({
    required this.token,
    required this.amount,
    required this.to,
  });

  final PrivateUsdToken token;

  /// What the recipient is sent, before Railgun's fee on a withdrawal.
  final BigInt amount;
  final RailgunDestination to;

  bool get isWithdrawal => to is RailgunPublicDestination;

  RailgunTransfer get transfer =>
      RailgunTransfer(to: to, token: token.address, amount: amount);

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdSendRequest &&
      other.token == token &&
      other.amount == amount &&
      other.to.text == to.text &&
      other.isWithdrawal == isWithdrawal;

  @override
  int get hashCode => Object.hash(token, amount, to.text, isWithdrawal);

  @override
  String toString() => 'PrivateUsdSendRequest(withdraw: $isWithdrawal)';
}

@immutable
class PrivateUsdSendCost {
  const PrivateUsdSendCost({
    required this.railgunFee,
    required this.feeBasisPoints,
    required this.networkFee,
    required this.networkFeeToken,
    this.networkFeeExpiresAt,
  });

  /// Railgun's fee on a withdrawal, taken from the amount sent.
  final BigInt railgunFee;
  final int feeBasisPoints;

  /// The relayer's (broadcaster's) fee for sending it, paid from the private
  /// balance on top of the amount, in [networkFeeToken]'s base units.
  final BigInt networkFee;

  /// `0x`, lowercase.
  final String networkFeeToken;

  /// Until when the relayer holds [networkFee]'s gas rate, in unix seconds;
  /// null when it is the relayer's floor.
  final int? networkFeeExpiresAt;

  BigInt received(BigInt amount) => amount - railgunFee;

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdSendCost &&
      other.railgunFee == railgunFee &&
      other.feeBasisPoints == feeBasisPoints &&
      other.networkFee == networkFee &&
      other.networkFeeToken == networkFeeToken &&
      other.networkFeeExpiresAt == networkFeeExpiresAt;

  @override
  int get hashCode => Object.hash(
    railgunFee,
    feeBasisPoints,
    networkFee,
    networkFeeToken,
    networkFeeExpiresAt,
  );
}

/// How one send ended (zapp `PrivateUsdSendOutcome`).
sealed class PrivateUsdSendOutcome {
  const PrivateUsdSendOutcome();
}

/// In a block.
class PrivateUsdSendSent extends PrivateUsdSendOutcome {
  const PrivateUsdSendSent(this.txHash);

  final String? txHash;
}

/// Handed over (or kept to be) but not seen in a block: it may still land,
/// so it is never proved again. Settlement decides.
class PrivateUsdSendUnconfirmed extends PrivateUsdSendOutcome {
  const PrivateUsdSendUnconfirmed(this.txHash);

  /// The relayer's transaction, once it named one.
  final String? txHash;
}

/// Nothing left the wallet. [message] says why when it is not the usual
/// "Nothing was sent. Try again in a moment.".
class PrivateUsdSendNotSent extends PrivateUsdSendOutcome {
  const PrivateUsdSendNotSent([this.message]);

  final String? message;
}

/// Another payment of the account is unsettled, or a conversion is under
/// way: nothing was proved.
class PrivateUsdSendBusy extends PrivateUsdSendOutcome {
  const PrivateUsdSendBusy(this.status);

  final PrivateUsdSpendStatus status;
}

/// Nothing left the wallet: the relayer now asks [cost]'s higher network
/// fee, which the user confirms first.
class PrivateUsdSendRepriced extends PrivateUsdSendOutcome {
  const PrivateUsdSendRepriced(this.cost);

  final PrivateUsdSendCost cost;
}

/// What a send leaves for the relayer's fee in the token it is paid in: the
/// last quote, else the relayer's floor (zapp `PrivateUsdNetworkFee`).
@immutable
class PrivateUsdNetworkFee {
  const PrivateUsdNetworkFee({required this.token, this.minimum, this.quoted});

  final PrivateUsdToken token;
  final BigInt? minimum;
  final BigInt? quoted;

  BigInt get reserve => quoted ?? minimum ?? BigInt.zero;

  /// The most of [asset] a send can take, leaving [reserve] where the fee is
  /// paid in the same token ("Use it all").
  BigInt sendable(PrivateUsdAsset asset) {
    if (asset.token != token) return asset.available;
    final left = asset.available - reserve;
    return left < BigInt.zero ? BigInt.zero : left;
  }

  PrivateUsdNetworkFee copyWith({BigInt? minimum, BigInt? quoted}) =>
      PrivateUsdNetworkFee(
        token: token,
        minimum: minimum ?? this.minimum,
        quoted: quoted ?? this.quoted,
      );

  @override
  bool operator ==(Object other) =>
      other is PrivateUsdNetworkFee &&
      other.token == token &&
      other.minimum == minimum &&
      other.quoted == quoted;

  @override
  int get hashCode => Object.hash(token, minimum, quoted);
}

/// Checks a `0zk` address. The app's is Rust's bech32m check
/// ([privateUsdIsRailgunAddress]); previews and tests pass their own.
typedef PrivateUsdRailgunAddressCheck = bool Function(String address);

/// Rust's `0zk` check (`private_usd_is_valid_railgun_address`: bech32m, hrp
/// `0zk`, 73 bytes, version 1). Synchronous.
bool privateUsdIsRailgunAddress(String address) =>
    rust.privateUsdIsValidRailgunAddress(address: address);

/// Where [input] sends in [mode], or null while it is not a valid recipient:
/// a `0zk` address (lowercased) that Rust accepts, or a `0x` address with a
/// good checksum that is not the zero address.
RailgunDestination? privateUsdSendDestination(
  PrivateUsdSendMode mode,
  String input, {
  PrivateUsdRailgunAddressCheck isRailgunAddress = privateUsdIsRailgunAddress,
}) {
  final recipient = input.trim();
  if (recipient.isEmpty) return null;
  return switch (mode) {
    PrivateUsdSendMode.private =>
      recipient.startsWith('0zk') && isRailgunAddress(recipient)
          ? RailgunPrivateDestination(recipient.toLowerCase())
          : null,
    PrivateUsdSendMode.withdraw =>
      isValidEvmAddress(recipient) ? RailgunPublicDestination(recipient) : null,
  };
}

/// What is wrong with the recipient; an empty field shows nothing.
String? privateUsdRecipientError(
  PrivateUsdSendMode mode,
  String input, {
  PrivateUsdRailgunAddressCheck isRailgunAddress = privateUsdIsRailgunAddress,
}) {
  final recipient = input.trim();
  if (recipient.isEmpty ||
      privateUsdSendDestination(
            mode,
            recipient,
            isRailgunAddress: isRailgunAddress,
          ) !=
          null) {
    return null;
  }
  return switch (mode) {
    PrivateUsdSendMode.private => PrivateUsdCopy.sendInvalid0zk,
    PrivateUsdSendMode.withdraw =>
      isZeroEvmAddress(recipient)
          ? PrivateUsdCopy.sendZeroAddress
          : PrivateUsdCopy.sendInvalid0x,
  };
}

final _decimal = RegExp(r'^(\d*)(?:\.(\d*))?$');

/// [text] in base units of a token with [decimals], or null while nothing
/// is typed, it does not read, or it is finer than the token goes.
BigInt? privateUsdTokenUnits(String text, int decimals) {
  final match = _decimal.firstMatch(text.trim());
  if (match == null) return null;
  final whole = match[1] ?? '';
  final fraction = match[2] ?? '';
  if ((whole.isEmpty && fraction.isEmpty) || fraction.length > decimals) {
    return null;
  }
  return BigInt.parse(
    '${whole.isEmpty ? '0' : whole}${fraction.padRight(decimals, '0')}',
  );
}

/// More decimals were typed than [decimals].
bool privateUsdTooPrecise(String text, int decimals) {
  final match = _decimal.firstMatch(text.trim());
  return match != null && (match[2] ?? '').length > decimals;
}

/// [units] of a token with [decimals] as the amount field shows it: "12.5",
/// "0.123456", "1250".
String privateUsdTokenText(BigInt units, int decimals) {
  final scale = BigInt.from(10).pow(decimals);
  final whole = units ~/ scale;
  var fraction = (units % scale).toString().padLeft(decimals, '0');
  fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '$whole' : '$whole.$fraction';
}

/// [units] of a token with [decimals] as dollars, exactly: "$1,250.40",
/// "$0.123456" (at least cents, never rounded).
String formatPrivateUsdExact(BigInt units, int decimals) {
  final negative = units.isNegative;
  final scale = BigInt.from(10).pow(decimals);
  final whole = (units.abs() ~/ scale).toString();
  var fraction = (units.abs() % scale).toString().padLeft(decimals, '0');
  fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  if (fraction.length < 2) fraction = fraction.padRight(2, '0');
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  return '${negative ? '−' : ''}\$$grouped.$fraction';
}

/// Basis points as a percentage: 25 → "0.25", 100 → "1".
String privateUsdPercentText(int basisPoints) {
  final whole = basisPoints ~/ 100;
  final fraction = (basisPoints % 100)
      .toString()
      .padLeft(2, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '$whole' : '$whole.$fraction';
}

/// "0zk1qy86…l4zu": the first 8 and last 4 characters (reference §9.4 S2).
String privateUsdShortAddress(String address) => address.length <= 14
    ? address
    : '${address.substring(0, 8)}…${address.substring(address.length - 4)}';

/// One send's form, review and outcome (zapp `PrivateUsdSendForm`).
@immutable
class PrivateUsdSendForm {
  const PrivateUsdSendForm({
    required this.mode,
    this.phase = PrivateUsdSendPhase.form,
    this.token,
    this.amountText = '',
    this.recipient = '',
    this.cost,
    this.reviewed,
    this.isBusy = false,
    this.outcome,
    this.error,
    this.networkFee,
    this.step,
  });

  final PrivateUsdSendMode mode;
  final PrivateUsdSendPhase phase;

  /// While [phase] is `sending`.
  final PrivateUsdSendStep? step;

  /// Pinned from the first balance on, so a refresh cannot change what is
  /// sent.
  final PrivateUsdToken? token;
  final String amountText;
  final String recipient;
  final PrivateUsdSendCost? cost;
  final PrivateUsdSendRequest? reviewed;

  /// The cost is being looked up, or the send runs.
  final bool isBusy;
  final PrivateUsdSendOutcome? outcome;
  final String? error;

  /// What a send of the fee's token leaves for the relayer.
  final PrivateUsdNetworkFee? networkFee;

  /// Withdrawals pay out the relayer's fee token only: it refuses any other
  /// (zapp `SwapClientsTest` 382).
  bool _offers(PrivateUsdToken token) =>
      mode == PrivateUsdSendMode.private ||
      networkFee == null ||
      networkFee!.token == token;

  /// The dollars there are to send, and the pinned one even once none of it
  /// is left.
  List<PrivateUsdAsset> assets(PrivateUsdBalances? balances) {
    final pinned = reviewed?.token ?? token;
    return [
      for (final asset in balances?.assets ?? const <PrivateUsdAsset>[])
        if (_offers(asset.token) &&
            (asset.available > BigInt.zero || asset.token == pinned))
          asset,
    ];
  }

  /// The pinned token's asset.
  PrivateUsdAsset? asset(PrivateUsdBalances? balances) {
    final pinned = reviewed?.token ?? token;
    return assets(balances).where((a) => a.token == pinned).firstOrNull;
  }

  /// [amountText] in [token]'s base units; null while none is typed, or it
  /// is finer than the token goes.
  BigInt? units(PrivateUsdToken token) =>
      privateUsdTokenUnits(amountText, token.decimals);

  /// The send this form describes, once complete, valid and more than
  /// nothing.
  PrivateUsdSendRequest? request(
    PrivateUsdAsset asset, {
    PrivateUsdRailgunAddressCheck isRailgunAddress = privateUsdIsRailgunAddress,
  }) {
    final sendable = networkFee?.sendable(asset) ?? asset.available;
    final amount = units(asset.token);
    if (amount == null || amount <= BigInt.zero || amount > sendable) {
      return null;
    }
    final to = privateUsdSendDestination(
      mode,
      recipient,
      isRailgunAddress: isRailgunAddress,
    );
    return to == null
        ? null
        : PrivateUsdSendRequest(token: asset.token, amount: amount, to: to);
  }

  /// Whether [request] still fits [balances] (its token's asset would make
  /// the same request).
  bool canSend(PrivateUsdSendRequest? request, PrivateUsdBalances? balances) {
    if (request == null) return false;
    for (final asset in balances?.assets ?? const <PrivateUsdAsset>[]) {
      if (asset.token != request.token) continue;
      final sendable = networkFee?.sendable(asset) ?? asset.available;
      return request.amount > BigInt.zero && request.amount <= sendable;
    }
    return false;
  }

  /// What is wrong with the amount; a zero still being typed is not
  /// flagged.
  String? amountError(PrivateUsdAsset? asset) {
    if (asset == null || amountText.trim().isEmpty) return null;
    final decimals = asset.token.decimals;
    if (privateUsdTooPrecise(amountText, decimals)) {
      return PrivateUsdCopy.sendTooPrecise(decimals);
    }
    final amount = units(asset.token);
    if (amount == null) return null;
    if (amount > asset.available) return PrivateUsdCopy.sendTooMuch;
    final fee = networkFee;
    if (fee != null &&
        fee.token == asset.token &&
        amount > fee.sendable(asset)) {
      return PrivateUsdCopy.sendLeaveNetworkFee(
        formatPrivateUsdExact(fee.reserve, fee.token.decimals),
      );
    }
    return null;
  }

  String? recipientError({
    PrivateUsdRailgunAddressCheck isRailgunAddress = privateUsdIsRailgunAddress,
  }) => privateUsdRecipientError(
    mode,
    recipient,
    isRailgunAddress: isRailgunAddress,
  );

  /// Why a reviewed send cannot go any more: the balance fell below it.
  String? reviewError(PrivateUsdBalances? balances) =>
      phase == PrivateUsdSendPhase.review &&
          !isBusy &&
          !canSend(reviewed, balances)
      ? PrivateUsdCopy.sendBalanceDropped
      : null;

  /// Back to where it was, since nothing left the wallet.
  PrivateUsdSendForm notSent([String? error]) => copyWith(
    phase: reviewed == null
        ? PrivateUsdSendPhase.form
        : PrivateUsdSendPhase.review,
    error: error ?? PrivateUsdCopy.sendNotSent,
    isBusy: false,
  );

  PrivateUsdSendForm copyWith({
    PrivateUsdSendPhase? phase,
    PrivateUsdToken? token,
    String? amountText,
    String? recipient,
    PrivateUsdSendCost? cost,
    PrivateUsdSendRequest? reviewed,
    bool? isBusy,
    PrivateUsdSendOutcome? outcome,
    String? error,
    PrivateUsdNetworkFee? networkFee,
    PrivateUsdSendStep? step,
    bool clearCost = false,
    bool clearError = false,
  }) => PrivateUsdSendForm(
    mode: mode,
    phase: phase ?? this.phase,
    // A step belongs to the send running now only.
    step: (phase ?? this.phase) == PrivateUsdSendPhase.sending
        ? (step ?? this.step)
        : null,
    token: token ?? this.token,
    amountText: amountText ?? this.amountText,
    recipient: recipient ?? this.recipient,
    cost: clearCost ? null : (cost ?? this.cost),
    reviewed: clearCost ? null : (reviewed ?? this.reviewed),
    isBusy: isBusy ?? this.isBusy,
    outcome: outcome ?? this.outcome,
    error: clearError ? null : (error ?? this.error),
    networkFee: networkFee ?? this.networkFee,
  );
}

/// The review's rows (reference §9.4 S8): asset, amount, Railgun's fee on a
/// withdrawal, the network fee, what they receive and the full address.
List<(String, String)> privateUsdSendReviewRows(
  PrivateUsdSendRequest request,
  PrivateUsdSendCost cost, {
  PrivateUsdToken? feeToken,
}) {
  final decimals = request.token.decimals;
  String amount(BigInt units, [int? tokenDecimals]) =>
      formatPrivateUsdExact(units, tokenDecimals ?? decimals);
  return [
    (PrivateUsdCopy.sendAsset, request.token.symbol),
    (PrivateUsdCopy.sendAmount, amount(request.amount)),
    if (cost.railgunFee > BigInt.zero)
      (
        PrivateUsdCopy.sendReviewRailgunFee(
          privateUsdPercentText(cost.feeBasisPoints),
        ),
        amount(cost.railgunFee),
      ),
    if (cost.networkFee > BigInt.zero)
      (
        PrivateUsdCopy.convertNetworkFee,
        amount(cost.networkFee, feeToken?.decimals),
      ),
    (PrivateUsdCopy.sendReviewReceives, amount(cost.received(request.amount))),
    (PrivateUsdCopy.sendReviewTo, request.to.text),
  ];
}
