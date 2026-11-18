import 'package:flutter/widgets.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/mobile/mobile_address_verify_sheet.dart';
import '../../../../core/widgets/review_info_row.dart';
import '../../domain/swap_contract.dart';
import '../one_time_address_label.dart';
import '../swap_asset_icon.dart';

/// One serif row of the mobile swap review header.
class MobileSwapReviewHeaderRow {
  const MobileSwapReviewHeaderRow({
    required this.label,
    required this.amountText,
    required this.asset,
    this.icon,
    this.bottomText,
    this.fullAddress,
    this.addressNetworkLabel,
    this.oneTimeAddress,
  });

  /// "You're paying" / "You're receiving".
  final String label;

  /// The Headline L serif value ("1.12 ZEC").
  final String amountText;

  final SwapAsset asset;

  /// Drawn in place of [asset]'s coin: Private USD's logo for the private
  /// dollars, which are USDC but not USDC on Ethereum.
  final Widget? icon;

  /// Small grey line under the amount — the fiat value or
  /// "To: 0x1125 ... 17512".
  final String? bottomText;

  /// When set, the bottom strip gains the eye "Full address" action
  /// opening the chunked verify sheet — Figma `Verify Address`
  /// (4731:96657).
  final String? fullAddress;

  /// Sheet title network label ("Ethereum address"); defaults to the
  /// asset's chain label.
  final String? addressNetworkLabel;

  /// Set when this row's ZEC goes to or comes back to a one-time address,
  /// shown where another row has "Full address".
  final OneTimeAddressRole? oneTimeAddress;
}

/// Paying/receiving block shared by the mobile swap review, progress, and
/// completed screens — Figma `Review Info` (4731:85563), built on the core
/// [ReviewInfoFlow]. The arrow is the neon redesign's: a straight stem with a
/// 45° head, faintly lit.
class MobileSwapReviewHeader extends StatelessWidget {
  const MobileSwapReviewHeader({
    required this.pay,
    required this.receive,
    this.flowConnector,
    super.key,
  });

  final MobileSwapReviewHeaderRow pay;
  final MobileSwapReviewHeaderRow receive;

  /// Optional replacement for the whole flow arrow row.
  final Widget? flowConnector;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: ReviewInfoFlow(
        connector: flowConnector ?? const MobileSwapFlowArrow.row(),
        rows: [_row(context, pay), _row(context, receive)],
      ),
    );
  }

  Widget _row(BuildContext context, MobileSwapReviewHeaderRow row) {
    final fullAddress = row.fullAddress;
    return ReviewInfoRow(
      label: row.label,
      value: row.amountText,
      leading:
          row.icon ??
          SwapAssetIcon(
            asset: row.asset,
            size: 32,
            showChainBadge: !row.asset.isNativeZec,
          ),
      bottomLeftText: row.bottomText,
      trailing: fullAddress == null && row.oneTimeAddress != null
          ? OneTimeAddressLabel(role: row.oneTimeAddress!)
          : null,
      trailingActionLabel: fullAddress == null
          ? null
          : context.l10n.commonFullAddress,
      trailingActionKey: const ValueKey('mobile_swap_full_address'),
      onTrailingAction: fullAddress == null
          ? null
          : () => showMobileAddressVerifySheet(
              context,
              title:
                  row.addressNetworkLabel ??
                  (row.asset.isNativeZec
                      ? context.l10n.commonZcashAddress
                      : context.l10n.commonAddressForChain(
                          row.asset.chainLabel,
                        )),
              address: fullAddress,
              leading: SwapAssetIcon(
                asset: row.asset,
                size: 32,
                showChainBadge: false,
              ),
            ),
    );
  }
}

/// The downward flow arrow between a paying and a receiving row: a straight
/// stem and a 45° head drawn as a faint neon tube.
class MobileSwapFlowArrow extends StatelessWidget {
  const MobileSwapFlowArrow({super.key}) : _row = false;

  /// The arrow as [ReviewInfoFlow]'s connector row: under the rows' leading
  /// icon column.
  const MobileSwapFlowArrow.row({super.key}) : _row = true;

  static const size = AppIconSize.large;

  final bool _row;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    final arrow = CustomPaint(
      size: const Size.square(size),
      painter: _FlowArrowPainter(glow: neon.glow, core: neon.core),
    );
    if (!_row) return arrow;
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: AppAssetSize.size,
        child: Center(child: arrow),
      ),
    );
  }
}

class _FlowArrowPainter extends CustomPainter {
  _FlowArrowPainter({required this.glow, required this.core});

  final Color glow;
  final Color core;

  @override
  void paint(Canvas canvas, Size size) {
    // On a 24-unit grid. The stem stops short of the tip so its square end
    // does not poke through the head.
    final u = size.width / 24;
    final arrow = Path()
      ..moveTo(12 * u, 3 * u)
      ..lineTo(12 * u, 19 * u)
      ..moveTo(6.5 * u, 14.5 * u)
      ..lineTo(12 * u, 20 * u)
      ..lineTo(17.5 * u, 14.5 * u);
    Neon.strokeTube(
      canvas,
      arrow,
      glow: glow,
      core: core,
      width: 1.3 * u,
      intensity: 0.55,
    );
  }

  @override
  bool shouldRepaint(_FlowArrowPainter oldDelegate) =>
      oldDelegate.glow != glow || oldDelegate.core != core;
}

/// "1.1200 ZEC" -> "1.12 ZEC" for the serif header rows, per the
/// Figma amounts (trailing zeros add no information at display size).
String trimSwapAmountText(String text) {
  final parts = text.split(' ');
  if (parts.isEmpty) return text;
  var amount = parts.first;
  if (amount.contains('.')) {
    amount = amount.replaceFirst(RegExp(r'0+$'), '');
    if (amount.endsWith('.')) {
      amount = amount.substring(0, amount.length - 1);
    }
  }
  return [amount, ...parts.skip(1)].join(' ');
}
