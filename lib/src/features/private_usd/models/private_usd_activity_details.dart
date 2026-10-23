import '../../../core/formatting/address_display.dart';
import '../../../core/formatting/date_format.dart';
import '../../../core/formatting/zec_amount.dart';
import '../../../core/privacy/privacy_mask.dart';
import '../../../rust/api/private_usd.dart';
import '../private_usd_copy.dart';
import 'private_usd_balances.dart';
import 'private_usd_explorer.dart';
import 'private_usd_messages.dart';
import 'private_usd_reverse_presentation.dart';
import 'private_usd_send.dart';
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
  ApiSendRecord record, {
  bool privacyModeEnabled = false,
}) {
  final fee = BigInt.tryParse(record.fee) ?? BigInt.zero;
  final txHash = record.txHash;
  return [
    PrivateUsdDetailValue(
      PrivateUsdCopy.sendReviewTo,
      truncatedAddress(record.to),
      copyText: record.to,
    ),
    PrivateUsdDetailValue(
      PrivateUsdCopy.sendAmount,
      _exact(BigInt.parse(record.amount), privacyModeEnabled),
    ),
    if (fee > BigInt.zero)
      PrivateUsdDetailValue(
        PrivateUsdCopy.convertNetworkFee,
        _exact(fee, privacyModeEnabled),
      ),
    PrivateUsdDetailValue(
      PrivateUsdCopy.detailsStatus,
      record.state == ApiSendState.confirmed
          ? PrivateUsdCopy.detailsConfirmed
          : PrivateUsdCopy.detailsUnconfirmed,
    ),
    PrivateUsdDetailValue(PrivateUsdCopy.detailsSent, _time(record.sentAt)),
    if (txHash != null)
      PrivateUsdDetailTransaction.ethereum(
        PrivateUsdCopy.detailsTransaction,
        txHash,
      ),
  ];
}

/// A received private send's details.
List<PrivateUsdActivityDetail> privateUsdReceivedDetails(
  RailgunReceipt receipt, {
  bool privacyModeEnabled = false,
}) {
  final sender = receipt.sender;
  final at = receipt.at;
  return [
    sender == null
        ? const PrivateUsdDetailValue(
            PrivateUsdCopy.detailsFrom,
            PrivateUsdCopy.detailsSenderHidden,
          )
        : PrivateUsdDetailValue(
            PrivateUsdCopy.detailsFrom,
            truncatedAddress(sender),
            copyText: sender,
          ),
    PrivateUsdDetailValue(
      PrivateUsdCopy.sendAmount,
      _exact(receipt.amount, privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      PrivateUsdCopy.detailsStatus,
      receipt.settled
          ? PrivateUsdCopy.rowAvailable
          : PrivateUsdCopy.convertStepScreen,
    ),
    if (at != null)
      PrivateUsdDetailValue(
        PrivateUsdCopy.detailsReceived,
        formatDayMonthTime(at),
      ),
    PrivateUsdDetailTransaction.ethereum(
      PrivateUsdCopy.detailsTransaction,
      receipt.txid,
    ),
  ];
}

/// A deposit's details: where it was sent, what it moved, the relayer's fee
/// and what reaches the private balance.
List<PrivateUsdActivityDetail> privateUsdDepositDetails(
  ApiDepositRecord record, {
  bool privacyModeEnabled = false,
}) {
  final txHash = record.txHash;
  return [
    PrivateUsdDetailValue(
      PrivateUsdCopy.detailsDepositAddress,
      truncatedAddress(record.address),
      copyText: record.address,
    ),
    PrivateUsdDetailValue(
      PrivateUsdCopy.sendAmount,
      _usd(_units(record.value), privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      PrivateUsdCopy.detailsRelayerFee,
      _usd(_units(record.fee), privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      record.state == ApiDepositState.landed
          ? PrivateUsdCopy.bridgedYouReceived
          : PrivateUsdCopy.convertYouReceive,
      _usd(_units(record.arrives), privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      PrivateUsdCopy.detailStarted,
      _time(record.createdAt),
    ),
    if (txHash != null)
      PrivateUsdDetailTransaction.ethereum(
        PrivateUsdCopy.detailsTransaction,
        txHash,
      ),
  ];
}

/// An ended forward conversion's details: paid, its amounts and fee;
/// refunded, why. Then its swap and transactions.
List<PrivateUsdActivityDetail> privateUsdForwardDetails(
  ApiForwardRecord record, {
  bool privacyModeEnabled = false,
}) {
  final deposit = record.depositTxid;
  final payout = record.payoutTx;
  final sweep = record.sweepTxid;
  final endedAt = record.endedAt;
  return [
    if (record.outcome == ApiForwardOutcome.refunded)
      PrivateUsdDetailNote(privateUsdRefundedMessage(record.refundCause)),
    if (record.outcome == ApiForwardOutcome.paid) ...[
      PrivateUsdDetailValue(
        PrivateUsdCopy.bridgedYouPaid,
        _zec(record.maxTotalZat ?? record.depositZat, privacyModeEnabled),
      ),
      PrivateUsdDetailValue(
        PrivateUsdCopy.bridgedYouReceived,
        _usd(_units(record.receives), privacyModeEnabled),
      ),
      PrivateUsdDetailValue(
        PrivateUsdCopy.detailsRelayerFee,
        _usd(_units(record.relayerFee), privacyModeEnabled),
      ),
    ],
    PrivateUsdDetailValue(
      PrivateUsdCopy.detailSwapId,
      truncatedTxid(record.swapId),
      copyText: record.swapId,
    ),
    if (deposit != null)
      PrivateUsdDetailTransaction.zcash(PrivateUsdCopy.detailDeposit, deposit),
    if (payout != null)
      PrivateUsdDetailTransaction.ethereum(PrivateUsdCopy.detailPayout, payout),
    if (sweep != null)
      PrivateUsdDetailTransaction.zcash(PrivateUsdCopy.detailRefund, sweep),
    PrivateUsdDetailValue(
      PrivateUsdCopy.detailStarted,
      _time(record.acceptedAt),
    ),
    if (endedAt != null)
      PrivateUsdDetailValue(PrivateUsdCopy.detailsEnded, _time(endedAt)),
  ];
}

/// A completed reverse conversion's details: its amounts and fees, its swap
/// and its transactions.
List<PrivateUsdActivityDetail> privateUsdReverseDetails(
  ApiReverseRecord record, {
  bool privacyModeEnabled = false,
}) {
  final cost = record.cost;
  final funding = record.fundingTx;
  final receive = record.receiveTxid;
  final acceptedAt = record.acceptedAt;
  return [
    PrivateUsdDetailValue(
      PrivateUsdCopy.bridgedYouPaid,
      _usd(privateUsdReverseDebit(record), privacyModeEnabled),
    ),
    PrivateUsdDetailValue(
      PrivateUsdCopy.bridgedYouReceived,
      _zec(privateUsdReverseReceivedZat(record), privacyModeEnabled),
    ),
    if (cost != null) ...[
      PrivateUsdDetailValue(
        PrivateUsdCopy.reverseRailgunFee,
        _usd(_units(cost.railgunFee), privacyModeEnabled),
      ),
      PrivateUsdDetailValue(
        PrivateUsdCopy.reverseBroadcasterFee,
        _usd(_units(cost.broadcasterFee), privacyModeEnabled),
      ),
    ],
    PrivateUsdDetailValue(
      PrivateUsdCopy.detailSwapId,
      truncatedTxid(record.swapId),
      copyText: record.swapId,
    ),
    if (funding != null)
      PrivateUsdDetailTransaction.ethereum(
        PrivateUsdCopy.detailFunding,
        funding,
      ),
    if (receive != null)
      PrivateUsdDetailTransaction.zcash(
        PrivateUsdCopy.detailZecReceived,
        receive,
      ),
    if (acceptedAt != null)
      PrivateUsdDetailValue(PrivateUsdCopy.detailStarted, _time(acceptedAt)),
  ];
}

BigInt _units(String value) => BigInt.tryParse(value) ?? BigInt.zero;

String _usd(BigInt microDollars, bool privacyModeEnabled) =>
    hideAmountIfPrivacyMode(
      formatPrivateUsd(microDollars),
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

String _time(int seconds) =>
    formatDayMonthTime(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
