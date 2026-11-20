import 'dart:async';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../core/widgets/mobile/neon_switch_tabs.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../rust/api/private_usd.dart' as rust;
import '../../../receive/widgets/mobile/receive_qr_frame.dart';
import '../../../receive/widgets/receive_address_widgets.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_deposits.dart';
import '../../models/private_usd_send.dart' show privateUsdPercentText;
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_deposits_provider.dart';
import '../../providers/private_usd_receive_address_provider.dart';
import '../../widgets/desktop/desktop_private_usd_widgets.dart';
import '../../widgets/mobile/private_usd_deposit_line.dart';

/// The page's two ways in, as the phone's Receive has them.
enum _ReceiveKind {
  /// Public USDC from an exchange or any wallet, to the deposit address,
  /// shielded on its own.
  usdc,

  /// 0zkUSDC from another Railgun wallet, to the account's 0zk address.
  shielded,
}

/// How often the open page asks for a deposit pass, as the phone's Receive
/// does: it is open while money is on its way, so a deposit shows soon after
/// it lands.
const _pageRefresh = Duration(seconds: 15);

/// `/private-usd/receive` on desktop: the phone's two ways in behind the same
/// switch, public USDC at the account's deposit address (the default) and
/// 0zkUSDC at its 0zk address, each as a code with its address and a copy
/// button. Where the network pins no Deposits contract only the 0zk address
/// shows. The deposit side states the one token and network it takes, the
/// minimum and both fees, and the deposits so far.
class DesktopPrivateUsdReceiveScreen extends ConsumerStatefulWidget {
  const DesktopPrivateUsdReceiveScreen({super.key});

  @override
  ConsumerState<DesktopPrivateUsdReceiveScreen> createState() =>
      _DesktopPrivateUsdReceiveScreenState();
}

class _DesktopPrivateUsdReceiveScreenState
    extends ConsumerState<DesktopPrivateUsdReceiveScreen> {
  Timer? _timer;

  /// The way in the user switched to; until then, public USDC where the
  /// network takes deposits.
  _ReceiveKind? _chosen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDeposits());
    _timer = Timer.periodic(_pageRefresh, (_) => _refreshDeposits());
  }

  void _refreshDeposits() {
    if (!mounted || !ref.read(privateUsdDepositsAvailableProvider)) return;
    ref.read(privateUsdDepositActionsProvider).refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy(String address) async {
    // Neither address is sensitive: the plain clipboard.
    await Clipboard.setData(ClipboardData(text: address));
    if (mounted) showAppToast(context, context.l10n.commonAddressCopied);
  }

  @override
  Widget build(BuildContext context) {
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    if (uuid == null) return const SizedBox.shrink();
    final deposits = ref.watch(privateUsdDepositsAvailableProvider);
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final pin = deployment?.deposits;
    final railgunAddress = ref.watch(privateUsdReceiveAddressProvider(uuid));
    final pass = deposits
        ? ref.watch(privateUsdDepositPassProvider(uuid))
        : null;
    // Before a pass has run, the address the last scan kept (no network).
    final fallback = deposits && pass == null
        ? ref.watch(privateUsdDepositAddressProvider(uuid))
        : null;
    final screening = Duration(seconds: deployment?.screeningSeconds ?? 0);
    final symbol = pin?.tokenSymbol ?? PrivateUsdCopy.usdcSymbol;
    final chain = pin?.chainName ?? PrivateUsdCopy.ethereum;
    final kind = deposits
        ? _chosen ?? _ReceiveKind.usdc
        : _ReceiveKind.shielded;
    final view = _ReceiveView(
      kind: kind,
      symbol: symbol,
      chain: chain,
      railgunAddress: railgunAddress.value,
      railgunAddressFailed: railgunAddress.hasError,
      address: pass?.address ?? fallback?.value?.address,
      addressFailed: pass == null && (fallback?.hasError ?? false),
      terms: pass?.terms,
      termsError: pass?.termsError,
      lines: pass == null
          ? const []
          : privateUsdDepositLines(
              pass,
              now: DateTime.now(),
              screening: screening,
            ),
      screening: screening,
      privacyModeEnabled: ref.watch(privacyModeProvider),
      onCopy: (address) => unawaited(_copy(address)),
    );
    return DesktopPrivateUsdPage(
      title: context.l10n.privateUsdDepositTitle(symbol),
      contentKey: const ValueKey('desktop_private_usd_receive_content'),
      children: [
        if (deposits) ...[
          Center(
            child: NeonSwitchTabs(
              key: const ValueKey('private_usd_receive_switch'),
              labels: (symbol, PrivateUsdCopy.receiveShieldedTab(symbol)),
              selected: kind == _ReceiveKind.usdc ? 0 : 1,
              onChanged: (index) => setState(
                () => _chosen = index == 0
                    ? _ReceiveKind.usdc
                    : _ReceiveKind.shielded,
              ),
              width: 320,
              height: 40,
              labelStyle: AppTypography.labelLarge,
              tabKeys: (
                const ValueKey('private_usd_receive_usdc'),
                const ValueKey('private_usd_receive_shielded'),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        view,
      ],
    );
  }
}

/// The way in [kind] shows: its notice, its code and address with the copy
/// button, and for public USDC the terms and the deposits so far.
class _ReceiveView extends StatelessWidget {
  const _ReceiveView({
    required this.kind,
    required this.symbol,
    required this.chain,
    required this.railgunAddress,
    required this.railgunAddressFailed,
    required this.address,
    required this.addressFailed,
    required this.terms,
    required this.termsError,
    required this.lines,
    required this.screening,
    required this.privacyModeEnabled,
    required this.onCopy,
  });

  final _ReceiveKind kind;
  final String symbol;
  final String chain;
  final String? railgunAddress;
  final bool railgunAddressFailed;
  final String? address;
  final bool addressFailed;
  final rust.ApiDepositTerms? terms;
  final rust.ApiPrivateUsdErrorCode? termsError;
  final List<PrivateUsdDepositLine> lines;
  final Duration screening;
  final bool privacyModeEnabled;
  final ValueChanged<String> onCopy;

  /// The relayer takes no deposits, or not the pinned ones: no address.
  bool get _unavailable =>
      termsError == rust.ApiPrivateUsdErrorCode.unavailable ||
      termsError == rust.ApiPrivateUsdErrorCode.wrongDeployment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: Column(
        key: ValueKey(kind),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: switch (kind) {
          _ReceiveKind.usdc => _deposit(context),
          _ReceiveKind.shielded => _shielded(context),
        },
      ),
    );
  }

  /// The code's side, as the plate before it drew it.
  static const _qrSize = 230.0;

  /// A code in the phones' lit frame, Veylor's helmet in its middle, as the
  /// phone draws it, the address under it and its copy button.
  Widget _code(
    BuildContext context, {
    required String address,
    required ReceiveAddressType type,
    required Key qrKey,
    required Key addressKey,
    required Key copyKey,
    required String copyLabel,
  }) {
    final colors = context.colors;
    return DesktopPrivateUsdPanel(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: ReceiveQrFrame(
              child: ReceiveQrSurface(
                key: qrKey,
                address: address,
                size: _qrSize,
                paddingX: AppSpacing.sm,
                paddingY: AppSpacing.sm,
                type: type,
                neonFramed: true,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SelectableText(
            address,
            key: addressKey,
            textAlign: TextAlign.center,
            style: AppTypography.codeSmall.copyWith(color: colors.text.accent),
          ),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: AppButton(
              key: copyKey,
              variant: AppButtonVariant.secondary,
              minWidth: 230,
              leading: const AppIcon(AppIcons.copy),
              onPressed: () => onCopy(address),
              child: Text(copyLabel),
            ),
          ),
        ],
      ),
    );
  }

  /// 0zkUSDC: the account's 0zk address, for another Railgun wallet.
  List<Widget> _shielded(BuildContext context) {
    final colors = context.colors;
    final note = AppTypography.bodySmall.copyWith(color: colors.text.secondary);
    final address = railgunAddress;
    return [
      DesktopPrivateUsdNotice(
        message: context.l10n.privateUsdReceiveShieldedOnly,
      ),
      const SizedBox(height: AppSpacing.sm),
      if (address != null)
        _code(
          context,
          address: address,
          type: ReceiveAddressType.shielded,
          qrKey: const ValueKey('private_usd_receive_shielded_qr'),
          addressKey: const ValueKey('desktop_private_usd_address'),
          copyKey: const ValueKey('desktop_private_usd_copy_address'),
          copyLabel: context.l10n.privateUsdReceiveShieldedCopy,
        )
      else
        Text(
          railgunAddressFailed
              ? context.l10n.privateUsdDepositAddressFailed
              : context.l10n.privateUsdDepositAddressLoading,
          textAlign: TextAlign.center,
          style: note,
        ),
      const SizedBox(height: AppSpacing.s),
      Text(context.l10n.privateUsdReceiveAddressNote, style: note),
    ];
  }

  /// Public USDC: the deposit address, its terms and the deposits so far.
  List<Widget> _deposit(BuildContext context) {
    final colors = context.colors;
    final body = AppTypography.bodyMedium.copyWith(color: colors.text.primary);
    final note = AppTypography.bodySmall.copyWith(color: colors.text.secondary);
    final address = this.address;
    final terms = this.terms;
    if (_unavailable) {
      return [
        Text(
          context.l10n.privateUsdDepositUnavailable,
          key: const ValueKey('private_usd_deposit_unavailable'),
          textAlign: TextAlign.center,
          style: body,
        ),
      ];
    }
    return [
      DesktopPrivateUsdNotice(
        message: context.l10n.privateUsdDepositOnly(symbol, chain),
      ),
      const SizedBox(height: AppSpacing.sm),
      if (address != null)
        _code(
          context,
          address: address,
          type: ReceiveAddressType.transparent,
          qrKey: const ValueKey('private_usd_deposit_qr'),
          addressKey: const ValueKey('private_usd_deposit_address'),
          copyKey: const ValueKey('private_usd_deposit_copy'),
          copyLabel: context.l10n.privateUsdDepositCopy,
        )
      else
        Text(
          addressFailed
              ? context.l10n.privateUsdDepositAddressFailed
              : context.l10n.privateUsdDepositAddressLoading,
          textAlign: TextAlign.center,
          style: note,
        ),
      const SizedBox(height: AppSpacing.sm),
      if (lines.isNotEmpty) ...[
        DesktopPrivateUsdPanel(
          key: const ValueKey('desktop_private_usd_receive_deposits'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopPrivateUsdCaption(context.l10n.privateUsdDepositsTitle),
              for (final line in lines) ...[
                const SizedBox(height: AppSpacing.xs),
                PrivateUsdDepositLineText(
                  line: line,
                  minimum: BigInt.tryParse(terms?.minValue ?? ''),
                  screening: screening,
                  privacyModeEnabled: privacyModeEnabled,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
      if (terms != null) ...[
        Text(
          context.l10n.privateUsdDepositMinimum(
            formatPrivateUsd(BigInt.tryParse(terms.minValue) ?? BigInt.zero),
          ),
          key: const ValueKey('private_usd_deposit_minimum'),
          style: body,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          context.l10n.privateUsdDepositRelayerFee(
            formatPrivateUsd(BigInt.tryParse(terms.fee) ?? BigInt.zero),
            privateUsdPercentText(terms.feeBps),
          ),
          key: const ValueKey('private_usd_deposit_relayer_fee'),
          style: body,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          context.l10n.privateUsdDepositRailgunFee(
            privateUsdPercentText(terms.railgunFeeBps),
          ),
          key: const ValueKey('private_usd_deposit_railgun_fee'),
          style: body,
        ),
      ] else
        Text(
          termsError == null
              ? context.l10n.privateUsdDepositFeesLoading
              : context.l10n.privateUsdDepositFeesFailed,
          key: const ValueKey('private_usd_deposit_fees_status'),
          style: note,
        ),
      const SizedBox(height: AppSpacing.s),
      Text(context.l10n.privateUsdDepositHow, style: note),
    ];
  }
}
