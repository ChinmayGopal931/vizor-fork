import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../address_scan/widgets/mobile_address_scan_card.dart';
import '../../models/private_usd_scan.dart';
import '../../models/private_usd_send.dart';
import '../../private_usd_copy.dart';

/// The send form's camera scanner, as ZEC Send's: the card-contained back
/// camera over the dimmed form. Send takes a `0zk` address and Withdraw a
/// `0x` one ([privateUsdScanOutcome]); anything else is refused in the card,
/// which keeps scanning. Pops the accepted address, or null once closed.
Future<String?> showPrivateUsdScanSheet(
  BuildContext context, {
  required PrivateUsdSendMode mode,
  required int? chainId,
  MobileScannerController? controller,
}) {
  return showAppMobileSheet<String>(
    context: context,
    builder: (sheetContext) => MobileAddressScanCard(
      controller: controller,
      caption: switch (mode) {
        PrivateUsdSendMode.private => PrivateUsdCopy.scanCaptionPrivate,
        PrivateUsdSendMode.withdraw => PrivateUsdCopy.scanCaptionWithdraw,
      },
      permissionTitle: PrivateUsdCopy.scanPermissionTitle,
      resolve: (raw) async =>
          privateUsdScanOutcome(raw, mode: mode, chainId: chainId),
      onScanned: (address) => Navigator.of(sheetContext).pop(address),
      onClose: () => Navigator.of(sheetContext).pop(),
    ),
  );
}
