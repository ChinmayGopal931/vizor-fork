import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app_bootstrap.dart';
import '../../../../core/feedback/app_haptics.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../rust/api/anon_rpc.dart' as rust_anon_rpc;
import '../../anon_rpc_copy.dart';
import '../../anon_rpc_network.dart';
import '../../providers/anon_rpc_network_provider.dart';
import '../../providers/anon_rpc_service_provider.dart';
import '../../services/anon_rpc_service.dart';

/// The worker's status, after the network's name.
String anonRpcStatusLabel(AnonRpcPhase phase) => switch (phase) {
  AnonRpcPhase.idle => AnonRpcCopy.statusIdle,
  AnonRpcPhase.starting => AnonRpcCopy.statusConnecting,
  AnonRpcPhase.ready => AnonRpcCopy.statusOn,
  AnonRpcPhase.failed => AnonRpcCopy.statusFailed,
};

/// How many requests Rust has relayed through the worker; 0 where Rust is
/// not loaded (widget tests).
int _relayedCount() {
  try {
    return rust_anon_rpc.anonRpcStats().relayed.toInt();
  } catch (_) {
    return 0;
  }
}

/// The route section of Settings' Ethereum RPC sheet: a card for each
/// network Shielded USD's Ethereum requests can go through, and Direct. A
/// tap applies at once (the Railgun page reopens on the new route), and the
/// line under the cards says where the worker stands.
class AnonRpcRoutePicker extends ConsumerStatefulWidget {
  const AnonRpcRoutePicker({super.key});

  @override
  ConsumerState<AnonRpcRoutePicker> createState() => _AnonRpcRoutePickerState();
}

class _AnonRpcRoutePickerState extends ConsumerState<AnonRpcRoutePicker> {
  var _busy = false;
  String? _error;

  Future<void> _select(AnonRpcNetwork network) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(anonRpcNetworkProvider.notifier).set(network);
    } catch (_) {
      if (mounted) setState(() => _error = AnonRpcCopy.saveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final current =
        ref.watch(anonRpcNetworkProvider).value ??
        AnonRpcNetwork.defaultNetwork;
    final status = ref.watch(anonRpcStatusProvider);
    final walletNetwork = ref.watch(appBootstrapProvider).network;
    final options = [
      for (final network in AnonRpcNetwork.values)
        if (network.availableFor(
          walletNetwork: walletNetwork,
          debug: kDebugMode,
        ))
          network,
    ];
    final statusLine = current.anonymizes
        ? AnonRpcCopy.joined(
            AnonRpcCopy.joined(current.label, anonRpcStatusLabel(status.phase)),
            AnonRpcCopy.relayed(_relayedCount()),
          )
        : null;
    final error = _error;
    final small = AppTypography.bodySmall.copyWith(
      color: colors.text.secondary,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final network in options) ...[
          _AnonRpcOptionCard(
            key: ValueKey('mobile_anon_rpc_option_${network.name}'),
            network: network,
            selected: network == current,
            enabled: !_busy,
            onTap: () => unawaited(_select(network)),
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
        if (statusLine != null)
          Text(
            statusLine,
            key: const ValueKey('mobile_anon_rpc_status'),
            style: small,
          ),
        if (error != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            error,
            key: const ValueKey('mobile_anon_rpc_error'),
            style: small.copyWith(color: colors.text.destructive),
          ),
        ],
      ],
    );
  }
}

class _AnonRpcOptionCard extends StatelessWidget {
  const _AnonRpcOptionCard({
    required this.network,
    required this.selected,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final AnonRpcNetwork network;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: '${network.label}. ${network.description}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!enabled || selected) return;
          unawaited(AppHaptics.selection());
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: colors.background.ground,
            borderRadius: BorderRadius.circular(AppRadii.medium),
            border: Border.all(
              color: selected ? colors.border.strong : colors.border.subtle,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Opacity(
                opacity: selected ? 1 : 0.5,
                child: AppIcon(
                  network.anonymizes ? AppIcons.eyeClosed : AppIcons.eye,
                  size: 20,
                  color: colors.icon.accent,
                ),
              ),
              const SizedBox(width: AppSpacing.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      network.label,
                      style: AppTypography.bodyMediumStrong.copyWith(
                        color: colors.text.accent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Opacity(
                      opacity: 0.7,
                      child: Text(
                        network.description,
                        style: AppTypography.bodySmall.copyWith(
                          color: colors.text.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: AppSpacing.s),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: colors.background.inverse,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: AppIcon(
                      AppIcons.check,
                      size: 14,
                      color: colors.text.inverse,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
