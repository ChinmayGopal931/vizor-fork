import 'package:flutter/widgets.dart';

import '../../../swap/domain/swap_asset.dart';

/// Private USD's logo: the USDC token with Railgun's badge at its bottom
/// right.
class PrivateUsdLogo extends StatelessWidget {
  const PrivateUsdLogo({this.size = 32, super.key});

  /// The token's side; the badge overhangs it a little.
  final double size;

  static const tokenAsset = 'assets/swap/tokens/usdc.webp';
  static const badgeAsset = 'assets/private_usd/railgun_badge.webp';

  @override
  Widget build(BuildContext context) {
    // A 14 dp badge on a 32 dp token, 2 dp past its bottom right.
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
