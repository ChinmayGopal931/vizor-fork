import 'package:flutter/widgets.dart';

import '../../../swap/domain/swap_asset.dart';

/// Private USD's logo, as zapp draws it: the USDC token with Railgun's badge
/// (a round chrome helix) at its bottom right.
class PrivateUsdLogo extends StatelessWidget {
  const PrivateUsdLogo({this.size = 32, super.key});

  /// The token's side. The badge overhangs it a little, as in zapp.
  final double size;

  /// zapp's `ic_token_usdc`, which is pixel for pixel the swap screens' USDC.
  static const tokenAsset = 'assets/swap/tokens/usdc.webp';

  /// zapp's `ic_private_usd_badge`.
  static const badgeAsset = 'assets/private_usd/railgun_badge.webp';

  @override
  Widget build(BuildContext context) {
    // zapp: a 14 dp badge on a 32 dp token, 2 dp past its bottom right.
    final badge = size * 14 / 32;
    final overhang = size * 2 / 32;
    return SizedBox.square(
      key: const ValueKey('private_usd_logo'),
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Image.asset(tokenAsset, excludeFromSemantics: true),
          ),
          Positioned(
            right: -overhang,
            bottom: -overhang,
            width: badge,
            height: badge,
            child: Image.asset(badgeAsset, excludeFromSemantics: true),
          ),
        ],
      ),
    );
  }
}

/// What a conversion's header draws for [asset]: Private USD's logo for the
/// private dollars (in place of USDC on Ethereum), else the asset's own coin
/// (null).
Widget? privateUsdHeaderIcon(SwapAsset asset) =>
    asset == SwapAsset.usdc ? const PrivateUsdLogo() : null;
