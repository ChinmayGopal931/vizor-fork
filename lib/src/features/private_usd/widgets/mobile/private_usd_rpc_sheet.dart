import 'dart:async';

import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app_bootstrap.dart';
import '../../../../core/config/private_usd_feature_config.dart';
import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/mobile/mobile_choice_card.dart';
import '../../../../core/widgets/mobile_text_field.dart';
import '../../../anon_rpc/anon_rpc_copy.dart';
import '../../../anon_rpc/anon_rpc_network.dart';
import '../../../anon_rpc/providers/anon_rpc_network_provider.dart';
import '../../../anon_rpc/widgets/mobile/anon_rpc_route_picker.dart';
import '../../models/private_usd_messages.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_custom_rpc_provider.dart';
import '../../services/private_usd_rpc_check.dart';
import 'private_usd_paste_button.dart';

/// Settings' Ethereum RPC sheet. Its route section (where the host runs the
/// anon-rpc page) picks the network Shielded USD's Ethereum requests go
/// through, or Direct, applied on the tap. Its provider section is two
/// cards: Veylor's default, or a URL of the user's own on one of the
/// network's RPC providers (all of which the Railgun page reaches), checked
/// with `eth_chainId` and over the engine's log window before it is saved.
/// Pops the toast to show once a URL is saved, else null. The field starts
/// empty and the sheet shows only the saved URL's host: the URL can hold a
/// key.
Future<String?> showPrivateUsdRpcSheet(BuildContext context) =>
    showAppMobileSheet<String>(
      context: context,
      builder: (_) => const _PrivateUsdRpcSheet(),
    );

class _PrivateUsdRpcSheet extends ConsumerStatefulWidget {
  const _PrivateUsdRpcSheet();

  @override
  ConsumerState<_PrivateUsdRpcSheet> createState() =>
      _PrivateUsdRpcSheetState();
}

class _PrivateUsdRpcSheetState extends ConsumerState<_PrivateUsdRpcSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  // "Your own URL" chosen before one is saved: the field shows.
  var _ownUrl = false;
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
    final chain = privateUsdRpcNetworkName(deployment.railgunNetwork);
    final url = privateUsdCustomRpcUrl(
      _controller.text,
      rpcHosts: deployment.rpcHosts,
    );
    if (url == null) {
      setState(() => _error = PrivateUsdCopy.rpcErrorUrl(chain));
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
            PrivateUsdCopy.rpcErrorUnreachable,
          PrivateUsdRpcCheckFailure.wrongChain =>
            PrivateUsdCopy.rpcErrorWrongChain(chain),
          PrivateUsdRpcCheckFailure.callsRefused =>
            PrivateUsdCopy.rpcErrorCalls,
          PrivateUsdRpcCheckFailure.logsLimited => PrivateUsdCopy.rpcErrorLogs,
        };
      });
      return;
    }
    try {
      await _setting.save(url);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = PrivateUsdCopy.rpcErrorSave;
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(PrivateUsdCopy.rpcSaved);
  }

  /// Back to Veylor's provider: a saved URL is cleared at once.
  Future<void> _chooseDefault(String? custom) async {
    if (_busy) return;
    setState(() {
      _ownUrl = false;
      _error = null;
    });
    if (custom == null) return;
    setState(() => _busy = true);
    try {
      await _setting.clear();
    } catch (_) {
      if (mounted) setState(() => _error = PrivateUsdCopy.rpcErrorSave);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final network = ref.watch(appBootstrapProvider).network;
    final custom = ref.watch(privateUsdCustomRpcProvider(network)).value;
    final chain = privateUsdRpcNetworkName(
      deployment?.railgunNetwork ?? 'mainnet',
    );
    final routeSupported =
        ref.watch(anonRpcHostSupportedProvider).value ?? false;
    final route =
        ref.watch(anonRpcNetworkProvider).value ??
        AnonRpcNetwork.defaultNetwork;
    final ownChosen = custom != null || _ownUrl;
    final canSave =
        ownChosen &&
        !_busy &&
        deployment != null &&
        _controller.text.trim().isNotEmpty;
    final secondary = AppTypography.bodyMedium.copyWith(
      color: colors.text.secondary,
    );
    final small = AppTypography.bodySmall.copyWith(
      color: colors.text.secondary,
    );
    final error = _error;
    return MobileModalScaffold(
      title: PrivateUsdCopy.rpcTitle,
      onClose: () => Navigator.of(context).pop(),
      // The cards scroll above the keyboard; the action stays below it.
      constrainBody: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (routeSupported) ...[
                    const _SectionCaption(AnonRpcCopy.routeHeading),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      AnonRpcCopy.routeBody,
                      key: const ValueKey('private_usd_rpc_route_body'),
                      style: secondary,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    const AnonRpcRoutePicker(),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      PrivateUsdCopy.rpcSees(anonymized: route.anonymizes),
                      key: const ValueKey('private_usd_rpc_sees'),
                      style: small,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    const _SectionCaption(PrivateUsdCopy.rpcProviderHeading),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  MobileChoiceCard(
                    key: const ValueKey('private_usd_rpc_default'),
                    icon: AppIcons.link,
                    label: PrivateUsdCopy.rpcDefault,
                    description: PrivateUsdCopy.rpcDefaultDescription(chain),
                    selected: !ownChosen,
                    enabled: !_busy,
                    onTap: () => unawaited(_chooseDefault(custom)),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  MobileChoiceCard(
                    key: const ValueKey('private_usd_rpc_own'),
                    icon: AppIcons.edit,
                    label: PrivateUsdCopy.rpcOwn,
                    description: custom == null
                        ? PrivateUsdCopy.rpcOwnDescription
                        : PrivateUsdCopy.rpcCurrent(
                            privateUsdCustomRpcHost(custom),
                          ),
                    selected: ownChosen,
                    enabled: !_busy,
                    onTap: () => setState(() {
                      _ownUrl = true;
                      _error = null;
                    }),
                  ),
                  if (ownChosen) ...[
                    const SizedBox(height: AppSpacing.sm),
                    MobileTextField(
                      fieldKey: const ValueKey('private_usd_rpc_field'),
                      controller: _controller,
                      focusNode: _focus,
                      enabled: !_busy,
                      hintText: PrivateUsdCopy.rpcHint,
                      // No suggestions: the keyboard would learn the key.
                      keyboardType: TextInputType.visiblePassword,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() => _error = null),
                      onSubmitted: (_) => unawaited(_checkAndSave()),
                      trailing: PrivateUsdPasteButton(
                        key: const ValueKey('private_usd_rpc_paste'),
                        controller: _controller,
                        enabled: !_busy,
                        onPasted: (_) => setState(() => _error = null),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      PrivateUsdCopy.rpcProviders,
                      key: const ValueKey('private_usd_rpc_providers'),
                      style: small,
                    ),
                  ],
                  if (!routeSupported) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      PrivateUsdCopy.rpcSees(anonymized: false),
                      key: const ValueKey('private_usd_rpc_sees'),
                      style: small,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              error,
              key: const ValueKey('private_usd_rpc_error'),
              style: small.copyWith(color: colors.text.destructive),
            ),
          ],
          if (ownChosen) ...[
            const SizedBox(height: AppSpacing.md),
            AppButton(
              key: const ValueKey('private_usd_rpc_save'),
              expand: true,
              onPressed: canSave ? () => unawaited(_checkAndSave()) : null,
              child: Text(
                _checking
                    ? PrivateUsdCopy.rpcChecking
                    : PrivateUsdCopy.rpcCheckAndSave,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A section's name, as Settings heads its groups: an uppercase red caption.
class _SectionCaption extends StatelessWidget {
  const _SectionCaption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final glow = context.colors.neon.glow;
    return Text(
      text.toUpperCase(),
      style: kNeonHudCaptionStyle.copyWith(
        color: glow,
        shadows: Neon.textGlow(glow, intensity: 0.3),
      ),
    );
  }
}
