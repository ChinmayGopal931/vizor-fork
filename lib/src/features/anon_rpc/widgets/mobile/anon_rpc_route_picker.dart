import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app_bootstrap.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/mobile/mobile_choice_card.dart';
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
          MobileChoiceCard(
            key: ValueKey('mobile_anon_rpc_option_${network.name}'),
            icon: network.anonymizes ? AppIcons.eyeClosed : AppIcons.eye,
            label: network.label,
            description: network.description,
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
