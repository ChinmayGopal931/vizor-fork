import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app_bootstrap.dart';
import '../../../../core/feedback/app_haptics.dart';
import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../rust/api/anon_rpc.dart' as rust_anon_rpc;
import '../../../accounts/widgets/mobile/account_edit_sheets.dart'
    show MobileSheetCancel;
import '../../anon_rpc_copy.dart';
import '../../anon_rpc_network.dart';
import '../../providers/anon_rpc_network_provider.dart';
import '../../providers/anon_rpc_service_provider.dart';
import '../../services/anon_rpc_service.dart';

/// Settings' Anonymous RPC sheet: the network Shielded USD's Ethereum
/// requests go through, or off. Pops the toast to show, or null when nothing
/// changed.
Future<String?> showAnonRpcSheet(BuildContext context) =>
    showAppMobileSheet<String>(
      context: context,
      builder: (_) => const _AnonRpcSheet(),
    );

/// How many requests Rust has relayed through the worker; 0 where Rust is
/// not loaded (widget tests).
int _relayedCount() {
  try {
    return rust_anon_rpc.anonRpcStats().relayed.toInt();
  } catch (_) {
    return 0;
  }
}

/// The row's status, after the network's name.
String anonRpcStatusLabel(AnonRpcPhase phase) => switch (phase) {
  AnonRpcPhase.idle => AnonRpcCopy.statusIdle,
  AnonRpcPhase.starting => AnonRpcCopy.statusConnecting,
  AnonRpcPhase.ready => AnonRpcCopy.statusOn,
  AnonRpcPhase.failed => AnonRpcCopy.statusFailed,
};

class _AnonRpcSheet extends ConsumerStatefulWidget {
  const _AnonRpcSheet();

  @override
  ConsumerState<_AnonRpcSheet> createState() => _AnonRpcSheetState();
}

class _AnonRpcSheetState extends ConsumerState<_AnonRpcSheet> {
  AnonRpcNetwork? _selected;
  var _busy = false;

  Future<void> _save(AnonRpcNetwork current) async {
    final selected = _selected ?? current;
    if (selected == current) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(anonRpcNetworkProvider.notifier).set(selected);
      if (!mounted) return;
      Navigator.of(context).pop(
        selected.anonymizes
            ? AnonRpcCopy.saved(selected.label)
            : AnonRpcCopy.savedOff,
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop(AnonRpcCopy.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final current =
        ref.watch(anonRpcNetworkProvider).value ?? AnonRpcNetwork.defaultNetwork;
    final selected = _selected ?? current;
    final status = ref.watch(anonRpcStatusProvider);
    final walletNetwork = ref.watch(appBootstrapProvider).network;
    final options = [
      for (final network in AnonRpcNetwork.values)
        if (network.availableFor(walletNetwork: walletNetwork, debug: kDebugMode))
          network,
    ];
    final relayed = _relayedCount();
    final statusLine = current.anonymizes
        ? '${AnonRpcCopy.rowValue(current.label, anonRpcStatusLabel(status.phase))}'
              ' · ${AnonRpcCopy.relayed(relayed)}'
        : AnonRpcCopy.rowValue(current.label, AnonRpcCopy.statusOff);
    final bodyStyle = AppTypography.bodyMedium.copyWith(
      color: colors.text.accent,
    );
    return MobileModalScaffold(
      title: AnonRpcCopy.title,
      onClose: () => Navigator.of(context).pop(),
      bodyGap: AppSpacing.md,
      bottomPadding: AppSpacing.base,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(AnonRpcCopy.body, style: bodyStyle),
          const SizedBox(height: AppSpacing.xs),
          Opacity(
            opacity: 0.7,
            child: Text(AnonRpcCopy.excluded, style: bodyStyle),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            key: const ValueKey('mobile_anon_rpc_status'),
            statusLine,
            style: bodyStyle,
          ),
          const SizedBox(height: AppSpacing.md),
          for (final network in options) ...[
            _AnonRpcOptionCard(
              key: ValueKey('mobile_anon_rpc_option_${network.name}'),
              network: network,
              selected: network == selected,
              onTap: () => setState(() => _selected = network),
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            key: const ValueKey('mobile_anon_rpc_update'),
            expand: true,
            onPressed: _busy ? null : () => unawaited(_save(current)),
            child: Text(AnonRpcCopy.update),
          ),
          const SizedBox(height: AppSpacing.xs),
          MobileSheetCancel(onTap: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}

class _AnonRpcOptionCard extends StatelessWidget {
  const _AnonRpcOptionCard({
    required this.network,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final AnonRpcNetwork network;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: '${network.label}. ${network.description}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!selected) unawaited(AppHaptics.selection());
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
