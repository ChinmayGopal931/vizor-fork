import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/app_toast.dart';
import '../../private_usd/providers/private_usd_archive_sync_provider.dart';
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

/// Desktop Settings' archive switch, as the phone's Settings row has it:
/// whether the Railgun page reads Railgun's history from Anon's archive before
/// rail-squid (on by default), where the Mac's host fetches it
/// ([privateUsdArchiveAvailableProvider]). The same setting and storage as the
/// phone ([privateUsdArchiveSyncProvider]); changing it closes the page, and
/// the next one starts with the new choice.
class PrivateUsdArchiveSyncControl extends ConsumerWidget {
  const PrivateUsdArchiveSyncControl({super.key});

  Future<void> _set(BuildContext context, WidgetRef ref, bool enabled) async {
    try {
      await ref.read(privateUsdArchiveSyncProvider.notifier).set(enabled);
    } catch (_) {
      if (context.mounted) {
        showAppToast(context, context.l10n.privateUsdSettingSaveFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final enabled = ref.watch(privateUsdArchiveSyncProvider).value ?? true;
    final label = context.l10n.privateUsdArchiveSyncSetting;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
      child: Row(
        key: const ValueKey('settings_archive_sync_row'),
        children: [
          AppIcon(AppIcons.history, size: 20, color: colors.icon.muted),
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
            trackKey: const ValueKey('settings_archive_sync_toggle'),
            semanticsLabel: label,
            onToggle: () => unawaited(_set(context, ref, !enabled)),
          ),
        ],
      ),
    );
  }
}
