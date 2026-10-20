import '../../address_book/models/address_format_validator.dart'
    show isZeroEvmAddress;
import '../../address_scan/domain/address_scan_payload.dart';
import '../../address_scan/widgets/mobile_address_scan_view.dart'
    show MobileScanOutcome;
import '../private_usd_copy.dart';
import 'private_usd_send.dart';

/// What a scanned code has to be for [mode]'s recipient (owner, 2026-10-19):
/// a `0zk` address to send privately, a `0x` one to withdraw, as
/// [privateUsdSendDestination] takes typed ones. The Receive sheet shows
/// both kinds as plain strings.
///
/// An `ethereum:` request gives up its recipient
/// ([normalizeAddressScanPayload]: a token transfer's `address`, not the
/// token), but one for a chain other than [chainId] is refused: an address a
/// Polygon request names is not one to withdraw Ethereum USDC to. The other
/// kind of address is refused by name, pointing to the action that takes it.
MobileScanOutcome privateUsdScanOutcome(
  String raw, {
  required PrivateUsdSendMode mode,
  required int? chainId,
  PrivateUsdRailgunAddressCheck isRailgunAddress = privateUsdIsRailgunAddress,
}) {
  final requestChain = _ethereumRequestChainId(raw);
  if (requestChain != null && chainId != null && requestChain != chainId) {
    return const MobileScanOutcome.rejected(PrivateUsdCopy.scanOtherNetwork);
  }
  final address = _scannedAddress(raw);
  bool takes(PrivateUsdSendMode action) =>
      privateUsdSendDestination(
        action,
        address,
        isRailgunAddress: isRailgunAddress,
      ) !=
      null;
  if (takes(mode)) return MobileScanOutcome.accepted(address);
  return MobileScanOutcome.rejected(switch (mode) {
    PrivateUsdSendMode.private when takes(PrivateUsdSendMode.withdraw) =>
      PrivateUsdCopy.scanUseWithdraw,
    PrivateUsdSendMode.private => PrivateUsdCopy.scanNot0zk,
    PrivateUsdSendMode.withdraw when takes(PrivateUsdSendMode.private) =>
      PrivateUsdCopy.scanUseSend,
    PrivateUsdSendMode.withdraw when isZeroEvmAddress(address) =>
      PrivateUsdCopy.sendZeroAddress,
    PrivateUsdSendMode.withdraw => PrivateUsdCopy.scanNot0x,
  });
}

/// The address [raw] carries, trimmed, or empty when it carries none; a
/// payload whose escapes do not decode carries none. An all-capitals `0ZK`
/// address is lowercased: QR codes often carry bech32 in capitals, which
/// pack tighter. Mixed case stays, for the check to refuse.
String _scannedAddress(String raw) {
  final String address;
  try {
    address = normalizeAddressScanPayload(raw)?.trim() ?? '';
  } on FormatException {
    return '';
  } on ArgumentError {
    return '';
  }
  return address.startsWith('0ZK') && address == address.toUpperCase()
      ? address.toLowerCase()
      : address;
}

/// The EIP-681 `ethereum:[pay-]<target>@<chain>…` request's chain id, or
/// null when [raw] is no such request or names none.
int? _ethereumRequestChainId(String raw) {
  final match = _ethereumRequest.firstMatch(raw.trim());
  return match == null ? null : int.tryParse(match[1]!);
}

final _ethereumRequest = RegExp(
  r'^(?:ethereum|eth):(?:pay-)?[^@/?#]+@(\d+)',
  caseSensitive: false,
);
