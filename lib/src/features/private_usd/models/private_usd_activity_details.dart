import '../../../core/l10n/l10n.dart';
import '../../../core/formatting/address_display.dart';
import '../../../core/formatting/date_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/privacy/privacy_mask.dart';
import '../../../rust/api/private_usd.dart';
import 'private_usd_balances.dart';
import 'private_usd_explorer.dart';
import 'private_usd_messages.dart';
import 'private_usd_reverse_presentation.dart';
import 'private_usd_send.dart';
import 'private_usd_status_presentation.dart' show privateUsdForwardPaidZat;
import 'railgun_models.dart';

/// One line of a Private USD activity row's details: what the row's record
/// already holds, nothing fetched for it.
sealed class PrivateUsdActivityDetail {
  const PrivateUsdActivityDetail();
}

/// Why the row ended as it did, above the rest.
class PrivateUsdDetailNote extends PrivateUsdActivityDetail {
  const PrivateUsdDetailNote(this.text);

  final String text;
}

/// A [label] and its [value]. A tap copies [copyText], the whole of a value
/// the line shortens (an address, an ID).
class PrivateUsdDetailValue extends PrivateUsdActivityDetail {
  const PrivateUsdDetailValue(this.label, this.value, {this.copyText});

  final String label;
  final String value;
  final String? copyText;
}

/// A transaction, opened on its chain's explorers.
class PrivateUsdDetailTransaction extends PrivateUsdActivityDetail {
  /// On Railscan and Etherscan.
  const PrivateUsdDetailTransaction.ethereum(this.label, this.hash)
    : explorers = const [
        PrivateUsdExplorer.railscan,
        PrivateUsdExplorer.etherscan,
      ];

  /// On the wallet's explorer; [hash] in the wallet's internal byte order,
  /// as records carry it.
  const PrivateUsdDetailTransaction.zcash(this.label, this.hash)
    : explorers = const [PrivateUsdExplorer.zcash];

  final String label;
  final String hash;
  final List<PrivateUsdExplorer> explorers;
}

/// A send's or a withdrawal's details.
List<PrivateUsdActivityDetail> privateUsdSendDetails(
  AppLocalizations l10n,
  ApiSendRecord record, {
  bool privacyModeEnabled = false,
}) {
  final fee = BigInt.tryParse(record.fee) ?? BigInt.zero;
  final txHash = record.txHash;
  return [
    PrivateUsdDetailValue(
      l10n.commonTo,
      truncatedAddress(record.to),
      copyText: record.to,
    ),
    PrivateUsdDetailValue(
      l10n.commonAmount,
      _exact(BigInt.parse(record.amount), privacyModeEnabled),
    ),
    if (fee > BigInt.zero)
      PrivateUsdDetailValue(
        l10n.commonNetworkFee,
        _exact(fee, privacyModeEnabled),
      ),
    PrivateUsdDetailValue(
      l10n.privateUsdDetailsStatus,
      record.state == ApiSendState.confirmed
          ? l10n.privateUsdDetailsConfirmed
          : l10n.privateUsdDetailsUnconfirmed,
    ),
    PrivateUsdDetailValue(
      l10n.privateUsdDetailsSent,
      _time(l10n, record.sentAt),
    ),
    if (txHash != null)
      PrivateUsdDetailTransaction.ethereum(
        l10n.privateUsdDetailsTransaction,
        txHash,
      ),
  ];
}

/// A received private send's details.
List<PrivateUsdActivityDetail> privateUsdReceivedDetails(
  AppLocalizations l10n,
  RailgunReceipt receipt, {
  bool privacyModeEnabled = false,
}) {
  final sender = receipt.sender;
  final at = receipt.at;
  return [
    sender == null
        ? PrivateUsdDetailValue(
            l10n.privateUsdDetailsFrom,
            l10n.privateUsdDetailsSenderHidden,
          )
        : PrivateUsdDetailValue(
            l10n.privateUsdDetailsFrom,
            truncatedAddress(sender),
            copyText: sender,
          ),
    PrivateUsdDetailValue(
      l10n.commonAmount,
      _exact(receipt.amount, privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      l10n.privateUsdDetailsStatus,
      receipt.settled
          ? l10n.privateUsdRowAvailable
          : l10n.privateUsdConvertStepScreen,
    ),
    if (at != null)
      PrivateUsdDetailValue(
        l10n.privateUsdDetailsReceived,
        formatDayMonthTime(at, l10n.localeName),
      ),
    PrivateUsdDetailTransaction.ethereum(
      l10n.privateUsdDetailsTransaction,
      receipt.txid,
    ),
  ];
}

/// A deposit's details: where it was sent, what it moved, the relayer's fee
/// and what reaches the private balance.
List<PrivateUsdActivityDetail> privateUsdDepositDetails(
  AppLocalizations l10n,
  ApiDepositRecord record, {
  bool privacyModeEnabled = false,
}) {
  final txHash = record.txHash;
  return [
    PrivateUsdDetailValue(
      l10n.privateUsdDetailsDepositAddress,
      truncatedAddress(record.address),
      copyText: record.address,
    ),
    PrivateUsdDetailValue(
      l10n.commonAmount,
      _usd(_units(record.value), privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      l10n.privateUsdDetailsRelayerFee,
      _usd(_units(record.fee), privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      record.state == ApiDepositState.landed
          ? l10n.privateUsdBridgedYouReceived
          : l10n.privateUsdConvertYouReceive,
      _usd(_units(record.arrives), privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      l10n.privateUsdDetailStarted,
      _time(l10n, record.createdAt),
    ),
    if (txHash != null)
      PrivateUsdDetailTransaction.ethereum(
        l10n.privateUsdDetailsTransaction,
        txHash,
      ),
  ];
}

/// An ended forward conversion's details: paid, its amounts and fees;
/// refunded, why; ended unstarted after its market maker fee was paid, that
/// the fee isn't refunded. Then its swap and transactions.
List<PrivateUsdActivityDetail> privateUsdForwardDetails(
  AppLocalizations l10n,
  ApiForwardRecord record, {
  bool privacyModeEnabled = false,
}) {
  final openFee = record.openFeeZat;
  final openFeeTxid = record.openFeeTxid;
  final deposit = record.depositTxid;
  final payout = record.payoutTx;
  final sweep = record.sweepTxid;
  final endedAt = record.endedAt;
  final feeLost =
      record.outcome == ApiForwardOutcome.nothingSent && record.openFeeMined;
  return [
    if (record.outcome == ApiForwardOutcome.refunded)
      PrivateUsdDetailNote(privateUsdRefundedMessage(l10n, record.refundCause)),
    if (feeLost)
      PrivateUsdDetailNote(privateUsdForwardNothingSentMessage(l10n, record)),
    if (record.outcome == ApiForwardOutcome.paid) ...[
      PrivateUsdDetailValue(
        l10n.privateUsdBridgedYouPaid,
        _zec(privateUsdForwardPaidZat(record), privacyModeEnabled),
      ),
      PrivateUsdDetailValue(
        l10n.privateUsdBridgedYouReceived,
        _usd(_units(record.receives), privacyModeEnabled),
      ),
      PrivateUsdDetailValue(
        l10n.privateUsdDetailsRelayerFee,
        _usd(_units(record.relayerFee), privacyModeEnabled),
      ),
    ],
    if (openFee != null &&
        (record.outcome == ApiForwardOutcome.paid || feeLost))
      PrivateUsdDetailValue(
        l10n.privateUsdConvertOpenFee,
        l10n.privateUsdConvertOpenFeeValue(_zec(openFee, privacyModeEnabled)),
      ),
    PrivateUsdDetailValue(
      l10n.privateUsdDetailSwapId,
      truncatedTxid(record.swapId),
      copyText: record.swapId,
    ),
    if (openFeeTxid != null)
      PrivateUsdDetailTransaction.zcash(
        l10n.privateUsdDetailOpenFee,
        openFeeTxid,
      ),
    if (deposit != null)
      PrivateUsdDetailTransaction.zcash(l10n.privateUsdDetailDeposit, deposit),
    if (payout != null)
      PrivateUsdDetailTransaction.ethereum(l10n.privateUsdDetailPayout, payout),
    if (sweep != null)
      PrivateUsdDetailTransaction.zcash(l10n.privateUsdDetailRefund, sweep),
    PrivateUsdDetailValue(
      l10n.privateUsdDetailStarted,
      _time(l10n, record.acceptedAt),
    ),
    if (endedAt != null)
      PrivateUsdDetailValue(l10n.privateUsdDetailsEnded, _time(l10n, endedAt)),
  ];
}

/// A completed reverse conversion's details: its amounts and fees, its swap
/// and its transactions.
List<PrivateUsdActivityDetail> privateUsdReverseDetails(
  AppLocalizations l10n,
  ApiReverseRecord record, {
  bool privacyModeEnabled = false,
}) {
  final cost = record.cost;
  final funding = record.fundingTx;
  final receive = record.receiveTxid;
  final acceptedAt = record.acceptedAt;
  return [
    PrivateUsdDetailValue(
      l10n.privateUsdBridgedYouPaid,
      _paid(privateUsdReverseDebit(record), privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      l10n.privateUsdBridgedYouReceived,
      _zec(privateUsdReverseReceivedZat(record), privacyModeEnabled),
    ),
    if (cost != null) ...[
      PrivateUsdDetailValue(
        l10n.privateUsdReverseRailgunFee,
        _paid(_units(cost.railgunFee), privacyModeEnabled),
      ),
      PrivateUsdDetailValue(
        l10n.privateUsdReverseBroadcasterFee,
        _paid(_units(cost.broadcasterFee), privacyModeEnabled),
      ),
    ],
    PrivateUsdDetailValue(
      l10n.privateUsdDetailSwapId,
      truncatedTxid(record.swapId),
      copyText: record.swapId,
    ),
    if (funding != null)
      PrivateUsdDetailTransaction.ethereum(
        l10n.privateUsdDetailFunding,
        funding,
      ),
    if (receive != null)
      PrivateUsdDetailTransaction.zcash(
        l10n.privateUsdDetailZecReceived,
        receive,
      ),
    if (acceptedAt != null)
      PrivateUsdDetailValue(
        l10n.privateUsdDetailStarted,
        _time(l10n, acceptedAt),
      ),
  ];
}

BigInt _units(String value) => BigInt.tryParse(value) ?? BigInt.zero;

String _usd(BigInt microDollars, bool privacyModeEnabled) =>
    hideAmountIfPrivacyMode(
      formatPrivateUsd(microDollars),
      privacyModeEnabled: privacyModeEnabled,
      denomination: '',
    );

// A payment and its fees, to the nearest cent, so its rows add up.
String _paid(BigInt microDollars, bool privacyModeEnabled) =>
    hideAmountIfPrivacyMode(
      formatPrivateUsdNearest(microDollars),
      privacyModeEnabled: privacyModeEnabled,
      denomination: '',
    );

// Sends and receipts state their exact amounts, as their rows do.
String _exact(BigInt units, bool privacyModeEnabled) => hideAmountIfPrivacyMode(
  formatPrivateUsdExact(units, PrivateUsdBalances.decimals),
  privacyModeEnabled: privacyModeEnabled,
  denomination: '',
);

String _zec(BigInt zatoshi, bool privacyModeEnabled) => privacyModeEnabled
    ? fixedPrivacyMask()
    : ZecAmount.fromZatoshi(zatoshi).activity.toString();

String _time(AppLocalizations l10n, int seconds) => formatDayMonthTime(
  DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
  l10n.localeName,
);
