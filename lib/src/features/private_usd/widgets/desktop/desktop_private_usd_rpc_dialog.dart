import 'dart:async';

import 'package:flutter/material.dart' show Colors, Dialog, showDialog;
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app_bootstrap.dart';
import '../../../../core/config/private_usd_feature_config.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_icon_hover_button.dart';
import '../../../../core/widgets/app_modal_card.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../models/private_usd_messages.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_custom_rpc_provider.dart';
import '../../services/private_usd_rpc_check.dart';
import '../mobile/private_usd_paste_button.dart';

/// Desktop Settings' Ethereum RPC dialog, the phone's RPC sheet in a desktop
/// card: a URL of the user's own on one of the network's RPC providers (all
/// of which the Railgun page reaches), checked with `eth_chainId`, the
/// engine's pinned read and its log window before it is saved, or the default
/// again. Pops the toast to show, or null when nothing changed. The field
/// starts empty and the dialog shows only the saved URL's host: the URL can
/// hold a key.
Future<String?> showDesktopPrivateUsdRpcDialog(BuildContext context) {
  final theme = context.appTheme;
  final container = ProviderScope.containerOf(context, listen: false);
  return showDialog<String>(
    context: context,
    barrierColor: theme.colors.background.neutralScrim,
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: AppTheme(
        data: theme,
        child: const Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: EdgeInsets.all(AppSpacing.md),
          child: _DesktopPrivateUsdRpcCard(),
        ),
      ),
    ),
  );
}

class _DesktopPrivateUsdRpcCard extends ConsumerStatefulWidget {
  const _DesktopPrivateUsdRpcCard();

  @override
  ConsumerState<_DesktopPrivateUsdRpcCard> createState() =>
      _DesktopPrivateUsdRpcCardState();
}

class _DesktopPrivateUsdRpcCardState
    extends ConsumerState<_DesktopPrivateUsdRpcCard> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  var _busy = false;
  var _checking = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  PrivateUsdCustomRpcNotifier get _setting => ref.read(
    privateUsdCustomRpcProvider(
      ref.read(appBootstrapProvider).network,
    ).notifier,
  );

  Future<void> _checkAndSave() async {
    final deployment = ref.read(privateUsdCurrentDeploymentProvider);
    if (deployment == null || _busy) return;
    final chain = privateUsdRpcNetworkName(
      context.l10n,
      deployment.railgunNetwork,
    );
    final url = privateUsdCustomRpcUrl(
      _controller.text,
      rpcHosts: deployment.rpcHosts,
    );
    if (url == null) {
      setState(() => _error = context.l10n.privateUsdRpcErrorUrl(chain));
      return;
    }
    _focus.unfocus();
    setState(() {
      _busy = true;
      _checking = true;
      _error = null;
    });
    final failure = await ref
        .read(privateUsdRpcCheckerProvider)
        .check(
          url,
          chainId: deployment.chainId,
          railgunProxy: deployment.railgunProxy,
          token: deployment.token,
          logsContract: deployment.swapContract,
        );
    // Closed meanwhile: nothing is saved.
    if (!mounted) return;
    setState(() => _checking = false);
    if (failure != null) {
      setState(() {
        _busy = false;
        _error = switch (failure) {
          PrivateUsdRpcCheckFailure.unreachable =>
            context.l10n.privateUsdRpcErrorUnreachable,
          PrivateUsdRpcCheckFailure.wrongChain =>
            context.l10n.privateUsdRpcErrorWrongChain(chain),
          PrivateUsdRpcCheckFailure.callsRefused =>
            context.l10n.privateUsdRpcErrorCalls,
          PrivateUsdRpcCheckFailure.logsLimited =>
            context.l10n.privateUsdRpcErrorLogs,
        };
      });
      return;
    }
    await _change(() => _setting.save(url), context.l10n.privateUsdRpcSaved);
  }

  Future<void> _useDefault() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await _change(_setting.clear, context.l10n.privateUsdRpcCleared);
  }

  Future<void> _change(Future<void> Function() change, String done) async {
    try {
      await change();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = context.l10n.privateUsdSettingSaveFailed;
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(done);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final network = ref.watch(appBootstrapProvider).network;
    final custom = ref.watch(privateUsdCustomRpcProvider(network)).value;
    final chain = privateUsdRpcNetworkName(
      context.l10n,
      deployment?.railgunNetwork ?? 'mainnet',
    );
    final error = _error;
    final small = AppTypography.bodySmall.copyWith(
      color: colors.text.secondary,
    );
    return AppModalCard(
      key: const ValueKey('desktop_private_usd_rpc_dialog'),
      width: 480,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height - AppSpacing.xl * 2,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.privateUsdRpcTitle,
                      style: AppTypography.headlineSmall.copyWith(
                        color: colors.text.accent,
                        fontWeight: AppFontWeight.heading,
                      ),
                    ),
                  ),
                  AppIconHoverButton(
                    icon: AppIcons.cross,
                    semanticLabel: context.l10n.commonClose,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s),
              Text(
                context.l10n.privateUsdRpcBody(chain),
                style: AppTypography.bodyMedium.copyWith(
                  color: colors.text.secondary,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                context.l10n.privateUsdRpcSees,
                key: const ValueKey('private_usd_rpc_sees'),
                style: small,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                context.l10n.privateUsdRpcProviders,
                key: const ValueKey('private_usd_rpc_providers'),
                style: small,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                context.l10n.privateUsdRpcCurrent(
                  custom == null
                      ? context.l10n.commonDefault
                      : privateUsdCustomRpcHost(custom),
                ),
                key: const ValueKey('private_usd_rpc_current'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.labelMedium.copyWith(
                  color: colors.text.accent,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              AppTextField(
                key: const ValueKey('private_usd_rpc_field'),
                label: context.l10n.privateUsdRpcTitle,
                showLabel: false,
                controller: _controller,
                focusNode: _focus,
                enabled: !_busy,
                hintText: PrivateUsdCopy.rpcHint,
                autofocus: true,
                // No suggestions or corrections: the system would learn the
                // key.
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => unawaited(_checkAndSave()),
                trailing: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: PrivateUsdPasteButton(
                    key: const ValueKey('private_usd_rpc_paste'),
                    controller: _controller,
                    enabled: !_busy,
                    onPasted: (_) => setState(() => _error = null),
                  ),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  error,
                  key: const ValueKey('private_usd_rpc_error'),
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.destructive,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      key: const ValueKey('private_usd_rpc_default'),
                      variant: AppButtonVariant.secondary,
                      expand: true,
                      onPressed: _busy || custom == null
                          ? null
                          : () => unawaited(_useDefault()),
                      child: Text(context.l10n.privateUsdRpcUseDefault),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: AppButton(
                      key: const ValueKey('private_usd_rpc_save'),
                      expand: true,
                      onPressed: _busy || deployment == null
                          ? null
                          : () => unawaited(_checkAndSave()),
                      child: Text(
                        _checking
                            ? context.l10n.commonCheckingEllipsis
                            : context.l10n.privateUsdRpcCheckAndSave,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
