import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/app_toast.dart';
import '../../private_usd/providers/private_usd_relayer_claims_provider.dart';
import 'network_privacy_control.dart' show PrivacyToggle;

/// Desktop Settings' relayer claims switch, as the phone's Settings row has
/// it: whether a new bridge to shielded USD hands its claim to the relayer
/// once the market maker confirms its deposit (on by default). The same
/// setting and storage as the phone ([privateUsdRelayerClaimsProvider]).
class PrivateUsdRelayerClaimsControl extends ConsumerWidget {
  const PrivateUsdRelayerClaimsControl({super.key});

  Future<void> _set(BuildContext context, WidgetRef ref, bool enabled) async {
    try {
      await ref.read(privateUsdRelayerClaimsProvider.notifier).set(enabled);
    } catch (_) {
      if (context.mounted) {
        showAppToast(context, context.l10n.privateUsdSettingSaveFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final enabled = ref.watch(privateUsdRelayerClaimsProvider).value ?? true;
    final label = context.l10n.privateUsdRelayerClaimsSetting;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
      child: Row(
        key: const ValueKey('settings_relayer_claims_row'),
        children: [
          AppIcon(AppIcons.plane, size: 20, color: colors.icon.muted),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              label,
              style: AppTypography.labelMedium.copyWith(
                color: colors.text.accent,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          PrivacyToggle(
            enabled: enabled,
            trackKey: const ValueKey('settings_relayer_claims_toggle'),
            semanticsLabel: label,
            onToggle: () => unawaited(_set(context, ref, !enabled)),
          ),
        ],
      ),
    );
  }
}
