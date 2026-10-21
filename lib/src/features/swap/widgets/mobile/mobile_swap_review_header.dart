import 'package:flutter/widgets.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/mobile/mobile_address_verify_sheet.dart';
import '../../domain/swap_contract.dart';
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
}

/// Paying/receiving block shared by the mobile swap review, progress, and
/// completed screens — Figma `Review Info` (4731:85563): two 90px rows joined
/// by the flow arrow, each with a 32px asset coin (chain badge on external
/// assets), the small grey label, the Headline L amount (Gotham Thin on
/// mobile), and a bottom strip. The arrow is the neon redesign's: a straight
/// stem with a 45° head, faintly lit.
class MobileSwapReviewHeader extends StatelessWidget {
  const MobileSwapReviewHeader({
    required this.pay,
    required this.receive,
    super.key,
  });

  final MobileSwapReviewHeaderRow pay;
  final MobileSwapReviewHeaderRow receive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeaderRow(row: pay),
          const SizedBox(
            width: 40,
            child: Center(child: MobileSwapFlowArrow()),
          ),
          _HeaderRow(row: receive),
        ],
      ),
    );
  }
}

/// The downward flow arrow between a paying and a receiving row: a straight
/// stem and a 45° head drawn as a faint neon tube.
class MobileSwapFlowArrow extends StatelessWidget {
  const MobileSwapFlowArrow({super.key});

  static const size = AppIconSize.large;

  @override
  Widget build(BuildContext context) {
    final neon = context.colors.neon;
    return CustomPaint(
      size: const Size.square(size),
      painter: _FlowArrowPainter(glow: neon.glow, core: neon.core),
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

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.row});

  final MobileSwapReviewHeaderRow row;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fullAddress = row.fullAddress;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 90),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 40,
            child: Center(
              child:
                  row.icon ??
                  SwapAssetIcon(
                    asset: row.asset,
                    size: 32,
                    showChainBadge: !row.asset.isNativeZec,
                  ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 24,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      row.label,
                      style: AppTypography.labelMedium.copyWith(
                        color: colors.text.secondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  row.amountText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.headlineLarge.copyWith(
                    color: colors.text.accent,
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                SizedBox(
                  height: 24,
                  child: Row(
                    children: [
                      if (row.bottomText != null)
                        Expanded(
                          child: Text(
                            row.bottomText!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.labelMedium.copyWith(
                              color: colors.text.secondary,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      if (fullAddress != null)
                        _FullAddressButton(
                          onTap: () => showMobileAddressVerifySheet(
                            context,
                            title:
                                row.addressNetworkLabel ??
                                (row.asset.isNativeZec
                                    ? 'Zcash address'
                                    : '${row.asset.chainLabel} address'),
                            address: fullAddress,
                            leading:
                                row.icon ??
                                SwapAssetIcon(
                                  asset: row.asset,
                                  size: 32,
                                  showChainBadge: false,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FullAddressButton extends StatelessWidget {
  const _FullAddressButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      child: GestureDetector(
        key: const ValueKey('mobile_swap_full_address'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                AppIcons.eye,
                size: AppIconSize.medium,
                color: colors.button.ghost.label,
              ),
              const SizedBox(width: AppSpacing.xxs),
              Text(
                'Full address',
                style: AppTypography.labelLarge.copyWith(
                  color: colors.button.ghost.label,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
