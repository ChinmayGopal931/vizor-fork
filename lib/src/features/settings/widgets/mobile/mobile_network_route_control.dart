import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/feedback/app_haptics.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../providers/network_privacy_provider.dart';
import '../../../../providers/nym_broadcast_provider.dart';

/// The network route: off, Tor, or Nym for sends (Free Society Hack,
/// 2026-11-04). Tor keeps its own provider and state machine; Nym is the
/// broadcast-only route in [nymBroadcastProvider]. The two are offered as one
/// choice.
enum NetworkRouteChoice { off, tor, nym }

class MobileNetworkRouteControl extends ConsumerWidget {
  const MobileNetworkRouteControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final tor = ref.watch(networkPrivacyProvider);
    final nym = ref.watch(nymBroadcastProvider);
    final torOn = tor.torRouteRetained;
    final current = nym.enabled
        ? NetworkRouteChoice.nym
        : torOn
        ? NetworkRouteChoice.tor
        : NetworkRouteChoice.off;
    final busy = tor.isBusy || nym.busy;

    Future<void> select(NetworkRouteChoice choice) async {
      final torNotifier = ref.read(networkPrivacyProvider.notifier);
      final nymNotifier = ref.read(nymBroadcastProvider.notifier);
      switch (choice) {
        case NetworkRouteChoice.off:
          // Each step only loosens what the user asked to loosen.
          if (ref.read(nymBroadcastProvider).enabled) {
            await nymNotifier.setEnabled(false);
          }
          if (ref.read(networkPrivacyProvider).torRouteRetained) {
            await torNotifier.setTorEnabled(false);
          }
        case NetworkRouteChoice.tor:
          // Tor first: Nym goes off only once Tor carries the traffic, so no
          // send goes out direct in between.
          await torNotifier.setTorEnabled(true);
          if (ref.read(networkPrivacyProvider).torEnabled &&
              ref.read(nymBroadcastProvider).enabled) {
            await nymNotifier.setEnabled(false);
          }
        case NetworkRouteChoice.nym:
          // Nym first, then Tor off: sends are on Nym before Tor stops.
          final saved = await nymNotifier.setEnabled(true);
          if (saved && ref.read(networkPrivacyProvider).torRouteRetained) {
            await torNotifier.setTorEnabled(false);
          }
      }
      unawaited(AppHaptics.selection());
    }

    final (status, description) = switch (current) {
      NetworkRouteChoice.off => (
        'Off',
        'Wallet sync, sends and in-app requests connect directly, so the '
            'servers Veylor talks to see your IP address.',
      ),
      NetworkRouteChoice.tor => (
        switch (tor.status) {
          NetworkPrivacyConnectionStatus.connecting => 'Connecting…',
          NetworkPrivacyConnectionStatus.connected => 'Connected',
          NetworkPrivacyConnectionStatus.failed => 'Failed',
          NetworkPrivacyConnectionStatus.off => 'Off',
        },
        tor.status == NetworkPrivacyConnectionStatus.failed
            ? 'Veylor could not connect to Tor. Requests stay blocked until it '
                  'connects or you choose another route.'
            : 'Veylor’s network requests go through Tor, so servers see a Tor '
                  'exit, not your IP address.',
      ),
      NetworkRouteChoice.nym => (
        nym.saveFailed ? 'Setting not saved' : 'On for sends',
        'Each send goes through the Nym mixnet on a fresh tunnel, so the '
            'light-wallet server sees a Nym exit, not your IP address. Sends '
            'take longer, from about 30 seconds to a few minutes. Wallet sync '
            'and other requests connect directly. If Nym cannot connect, the '
            'send fails: Veylor never falls back to a direct connection.',
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
          child: Row(
            children: [
              Text(
                'Network route',
                style: AppTypography.labelLarge.copyWith(
                  color: colors.text.accent,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  busy ? 'Switching…' : status,
                  key: const ValueKey('mobile_settings_route_status'),
                  maxLines: 2,
                  textAlign: TextAlign.end,
                  style: AppTypography.labelLarge.copyWith(
                    color: current == NetworkRouteChoice.off
                        ? colors.text.secondary
                        : colors.text.brandCrimson,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s),
        _RouteSegments(
          selected: current,
          enabled: !busy,
          onSelected: (choice) {
            if (choice != current) unawaited(select(choice));
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          description,
          key: const ValueKey('mobile_settings_route_description'),
          style: AppTypography.bodyMedium.copyWith(
            color: colors.text.secondary,
          ),
        ),
        if (current == NetworkRouteChoice.tor &&
            tor.status == NetworkPrivacyConnectionStatus.failed &&
            !busy)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(
              ref.read(networkPrivacyProvider.notifier).setTorEnabled(true),
            ),
            child: SizedBox(
              height: 44,
              child: Center(
                widthFactor: 1,
                child: Text(
                  'Try again',
                  style: AppTypography.labelLarge.copyWith(
                    color: colors.text.brandCrimson,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Three cut-corner plates in one glass track, styled as [NeonSwitchTabs].
class _RouteSegments extends StatelessWidget {
  const _RouteSegments({
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final NetworkRouteChoice selected;
  final bool enabled;
  final ValueChanged<NetworkRouteChoice> onSelected;

  static const _labels = {
    NetworkRouteChoice.off: 'Off',
    NetworkRouteChoice.tor: 'Tor',
    NetworkRouteChoice.nym: 'Nym',
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final glow = colors.neon.glow;
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: Container(
        height: 40,
        decoration: ShapeDecoration(
          color: colors.button.secondary.bg,
          shape: Neon.chamferBorder(
            side: BorderSide(color: colors.border.subtleOpacity),
          ),
        ),
        padding: const EdgeInsets.all(2),
        child: Row(
          children: [
            for (final choice in NetworkRouteChoice.values)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: choice == selected,
                  label: 'Network route: ${_labels[choice]}',
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: ValueKey('mobile_settings_route_${choice.name}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: enabled ? () => onSelected(choice) : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(
                        color: choice == selected
                            ? glow.withValues(alpha: 0.1)
                            : const Color(0x00000000),
                        shape: Neon.chamferBorder(
                          cut: AppChamfer.medium - 1,
                          side: BorderSide(
                            color: choice == selected
                                ? glow.withValues(alpha: 0.85)
                                : const Color(0x00000000),
                          ),
                        ),
                        shadows: choice == selected
                            ? Neon.boxGlow(glow, intensity: 0.3)
                            : null,
                      ),
                      child: Text(
                        _labels[choice]!,
                        style: AppTypography.labelMedium.copyWith(
                          color: choice == selected
                              ? colors.neon.core
                              : colors.text.secondary,
                          shadows: choice == selected
                              ? Neon.textGlow(glow, intensity: 0.4)
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
