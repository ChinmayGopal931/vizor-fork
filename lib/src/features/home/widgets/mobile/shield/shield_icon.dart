import 'package:flutter/widgets.dart';

import '../../../../../core/widgets/app_icon.dart';
import '../../../../../core/widgets/mobile/neon_done_sign.dart';
import '../../../../../core/widgets/mobile/neon_glyph_badge.dart';
import '../../../../../core/widgets/mobile/tron_glyph.dart';

/// The mark over the amount: the transparent balance on a lit plate, then
/// the done sign switching on once the balance is shielded. The particles
/// still condense into the shield's silhouette at its centre and hand over
/// to the sign.
class ShieldIcon extends StatelessWidget {
  const ShieldIcon.transparent({required this.size, super.key})
    : shielded = false;

  const ShieldIcon.shielded({required this.size, super.key}) : shielded = true;

  final double size;
  final bool shielded;

  @override
  Widget build(BuildContext context) => shielded
      ? NeonDoneSign(glyph: TronGlyphKind.check, size: size)
      : NeonGlyphBadge(iconName: AppIcons.transparentBalance, size: size);
}
