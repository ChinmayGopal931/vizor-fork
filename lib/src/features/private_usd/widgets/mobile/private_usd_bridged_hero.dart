import 'package:flutter/widgets.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/mobile/neon_done_sign.dart';
import '../../../../core/widgets/mobile/neon_glyph_badge.dart';
import '../../../../core/widgets/mobile/neon_motion.dart';
import '../../../../core/widgets/mobile/neon_scramble_text.dart';
import '../../../../core/widgets/mobile/tron_glyph.dart';
import '../../private_usd_copy.dart';

/// A finished bridge as a lit sign: the done badge, the title in thin
/// capitals, and what arrived under it.
///
/// [celebrate] is for a bridge that finished in view: the badge switches on
/// as [NeonDoneSign] does, with its shockwave (the send screen's ripple as
/// lit tubes), and the word decrypts in; [onImpact] runs as the badge lights,
/// for the send screen's success haptic. Opened later, it is simply lit.
class PrivateUsdBridgedHero extends StatelessWidget {
  const PrivateUsdBridgedHero({
    required this.body,
    this.celebrate = false,
    this.onImpact,
    super.key,
  });

  final String body;
  final bool celebrate;
  final VoidCallback? onImpact;

  static const _badgeSize = 72.0;
  static const _bodyWidth = 280.0;

  /// The page title's face, a size up: the sign, not the page's name.
  static final _titleStyle = kNeonPageTitleStyle.copyWith(
    fontSize: 28,
    letterSpacing: 8,
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final neon = colors.neon;
    final title = PrivateUsdCopy.bridgedTitle.toUpperCase();
    final lit = _titleStyle.copyWith(
      color: neon.core,
      shadows: Neon.textGlow(neon.glow, intensity: 0.7),
    );
    return Padding(
      key: const ValueKey('mobile_private_usd_bridged'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.xs,
      ),
      child: Column(
        children: [
          if (celebrate)
            NeonDoneSign(
              key: const ValueKey('mobile_private_usd_bridged_sign'),
              glyph: TronGlyphKind.check,
              size: _badgeSize,
              shockwave: true,
              onIgnite: onImpact,
            )
          else
            const NeonGlyphBadge(glyph: TronGlyphKind.check, size: _badgeSize),
          const SizedBox(height: AppSpacing.md),
          Semantics(
            header: true,
            label: PrivateUsdCopy.bridgedTitle,
            excludeSemantics: true,
            child: celebrate
                ? NeonIgnition(
                    delay: const Duration(milliseconds: 1000),
                    builder: (context, light) => light == 0
                        ? Opacity(opacity: 0, child: Text(title, style: lit))
                        : NeonScrambleText(
                            text: title,
                            style: lit,
                            cipherStyle: _titleStyle.copyWith(color: neon.glow),
                            decryptOnAppear: true,
                          ),
                  )
                : Text(title, style: lit),
          ),
          const SizedBox(height: AppSpacing.xs),
          ConstrainedBox(
            // Wraps in even lines under the sign.
            constraints: const BoxConstraints(maxWidth: _bodyWidth),
            child: Text(
              body,
              key: const ValueKey('mobile_private_usd_bridged_body'),
              textAlign: TextAlign.center,
              style: AppTypography.bodyMedium.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
