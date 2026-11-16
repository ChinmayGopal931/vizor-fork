import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feedback/app_haptics.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
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
import '../../widgets/mobile/private_usd_deposit_line.dart';
import '../../widgets/mobile/private_usd_flow_widgets.dart';
import '../../../../core/l10n/l10n.dart';

/// How often the open screen asks for a deposit pass: it is open while money
/// is on its way to the address, so a deposit shows soon after it lands.
const _screenRefresh = Duration(seconds: 15);

/// The Receive screen's two ways in, as ZEC's Receive has its pools.
enum PrivateUsdReceiveKind {
  /// Public USDC from an exchange or any wallet, to the deposit address,
  /// shielded on its own.
  usdc,

  /// 0zkUSDC from another Railgun wallet, to the account's 0zk address.
  shielded,
}

/// `/private-usd/receive`: a switch like ZEC's Receive between public USDC
/// (the default) and shielded 0zkUSDC. Where the network pins no Deposits
/// contract only the 0zk address shows.
///
/// Public USDC: the account's deposit address, as a QR code of the plain
/// EIP-55 `0x…` string (no `ethereum:` URI, which withdrawal forms refuse),
/// with the one token and network it takes, the minimum and both fees,
/// shown before anything is signed.
class MobilePrivateUsdReceiveScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdReceiveScreen({super.key});

  @override
  ConsumerState<MobilePrivateUsdReceiveScreen> createState() =>
      _MobilePrivateUsdReceiveScreenState();
}

class _MobilePrivateUsdReceiveScreenState
    extends ConsumerState<MobilePrivateUsdReceiveScreen> {
  Timer? _timer;

  /// The way in the user switched to; until then, public USDC where the
  /// network takes deposits.
  PrivateUsdReceiveKind? _chosen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDeposits());
    _timer = Timer.periodic(_screenRefresh, (_) => _refreshDeposits());
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
    return MobilePrivateUsdReceiveView(
      kind: deposits
          ? _chosen ?? PrivateUsdReceiveKind.usdc
          : PrivateUsdReceiveKind.shielded,
      onKindChanged: deposits ? (kind) => setState(() => _chosen = kind) : null,
      railgunAddress: railgunAddress.value,
      railgunAddressFailed: railgunAddress.hasError,
      symbol: pin?.tokenSymbol ?? PrivateUsdCopy.usdcSymbol,
      chain: pin?.chainName ?? PrivateUsdCopy.ethereum,
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
      onBack: () => context.pop(),
    );
  }
}

/// The Receive screen's content for a given way in, addresses, terms and
/// deposits.
class MobilePrivateUsdReceiveView extends StatelessWidget {
  const MobilePrivateUsdReceiveView({
    required this.symbol,
    required this.chain,
    required this.address,
    required this.onBack,
    this.kind = PrivateUsdReceiveKind.usdc,
    this.onKindChanged,
    this.railgunAddress,
    this.railgunAddressFailed = false,
    this.addressFailed = false,
    this.terms,
    this.termsError,
    this.lines = const [],
    this.screening = Duration.zero,
    this.privacyModeEnabled = false,
    super.key,
  });

  /// Which way in shows.
  final PrivateUsdReceiveKind kind;

  /// Switches between the two; null hides the switch (no deposits here).
  final ValueChanged<PrivateUsdReceiveKind>? onKindChanged;

  /// The account's 0zk address; null while it loads.
  final String? railgunAddress;
  final bool railgunAddressFailed;

  /// `USDC`, or `tUSD` on testnet; and `Ethereum`, or `Sepolia`.
  final String symbol;
  final String chain;

  /// The deposit address, EIP-55; null while it loads.
  final String? address;
  final bool addressFailed;

  /// The relayer's terms; null while they load or when they did not read
  /// ([termsError]).
  final rust.ApiDepositTerms? terms;
  final rust.ApiPrivateUsdErrorCode? termsError;
  final List<PrivateUsdDepositLine> lines;
  final Duration screening;
  final bool privacyModeEnabled;
  final VoidCallback onBack;

  /// The relayer takes no deposits, or not the pinned ones: no address.
  bool get _unavailable =>
      termsError == rust.ApiPrivateUsdErrorCode.unavailable ||
      termsError == rust.ApiPrivateUsdErrorCode.wrongDeployment;

  Future<void> _copy(BuildContext context, String address) async {
    // Neither address is sensitive: the plain clipboard.
    await Clipboard.setData(ClipboardData(text: address));
    unawaited(AppHaptics.copy());
    if (context.mounted) {
      showAppToast(context, context.l10n.commonAddressCopied);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onKindChanged = this.onKindChanged;
    return PrivateUsdFlowScaffold(
      title: context.l10n.privateUsdDepositTitle(symbol),
      onBack: onBack,
      body: PrivateUsdFlowColumn(
        top: AppSpacing.md,
        children: [
          if (onKindChanged != null) ...[
            Center(
              child: LayoutBuilder(
                builder: (context, constraints) => NeonSwitchTabs(
                  key: const ValueKey('private_usd_receive_switch'),
                  labels: (symbol, PrivateUsdCopy.receiveShieldedTab(symbol)),
                  selected: kind == PrivateUsdReceiveKind.usdc ? 0 : 1,
                  onChanged: (index) => onKindChanged(
                    index == 0
                        ? PrivateUsdReceiveKind.usdc
                        : PrivateUsdReceiveKind.shielded,
                  ),
                  // As ZEC's Receive sets its pool switch.
                  width: constraints.maxWidth < _switchWidth
                      ? constraints.maxWidth
                      : _switchWidth,
                  height: 44,
                  labelStyle: AppTypography.labelLarge,
                  tabKeys: (
                    const ValueKey('private_usd_receive_usdc'),
                    const ValueKey('private_usd_receive_shielded'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          // The two ways in differ in height: the content eases between
          // them.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: Column(
              key: ValueKey(kind),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: switch (kind) {
                PrivateUsdReceiveKind.usdc => _deposit(context),
                PrivateUsdReceiveKind.shielded => _shielded(context),
              },
            ),
          ),
        ],
      ),
    );
  }

  static const _switchWidth = 320.0;

  /// A code in the lit frame, the address under it and its copy button.
  List<Widget> _code(
    BuildContext context, {
    required String address,
    required ReceiveAddressType type,
    required Key qrKey,
    required Key addressKey,
    required Key copyKey,
    required String copyLabel,
  }) {
    final colors = context.colors;
    return [
      // The code keeps its light plate; only the frame around it is lit.
      Center(
        child: ReceiveQrFrame(
          child: ReceiveQrSurface(
            key: qrKey,
            address: address,
            size: 200,
            paddingX: AppSpacing.sm,
            paddingY: AppSpacing.sm,
            type: type,
            badgeSize: 44,
          ),
        ),
      ),
      const SizedBox(height: AppSpacing.sm),
      if (type == ReceiveAddressType.transparent)
        // A `0x…` address fits one line; the long 0zk one wraps.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            address,
            key: addressKey,
            maxLines: 1,
            style: AppTypography.codeSmall.copyWith(color: colors.text.accent),
          ),
        )
      else
        Text(
          address,
          key: addressKey,
          textAlign: TextAlign.center,
          style: AppTypography.codeSmall.copyWith(color: colors.text.accent),
        ),
      const SizedBox(height: AppSpacing.s),
      AppButton(
        key: copyKey,
        variant: AppButtonVariant.secondary,
        expand: true,
        constrainContent: true,
        leading: const AppIcon(AppIcons.copy),
        onPressed: () => unawaited(_copy(context, address)),
        child: Text(copyLabel),
      ),
    ];
  }

  /// 0zkUSDC: the account's 0zk address, for another Railgun wallet.
  List<Widget> _shielded(BuildContext context) {
    final colors = context.colors;
    final note = AppTypography.bodySmall.copyWith(color: colors.text.secondary);
    final address = railgunAddress;
    return [
      MobileWarningNotice(message: context.l10n.privateUsdReceiveShieldedOnly),
      const SizedBox(height: AppSpacing.sm),
      if (address != null)
        ..._code(
          context,
          address: address,
          type: ReceiveAddressType.shielded,
          qrKey: const ValueKey('private_usd_receive_shielded_qr'),
          // The device rounds read the address shown here.
          addressKey: const ValueKey('mobile_private_usd_address'),
          copyKey: const ValueKey('mobile_private_usd_copy_address'),
          copyLabel: context.l10n.privateUsdReceiveShieldedCopy,
        )
      else
        Text(
          railgunAddressFailed
              ? context.l10n.privateUsdDepositAddressFailed
              : context.l10n.privateUsdDepositAddressLoading,
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
          style: body,
        ),
      ];
    }
    return [
      MobileWarningNotice(
        message: context.l10n.privateUsdDepositOnly(symbol, chain),
      ),
      const SizedBox(height: AppSpacing.sm),
      if (address != null)
        ..._code(
          context,
          address: address,
          // A short address: the code keeps a version the badge cannot
          // spoil.
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
          style: note,
        ),
      const SizedBox(height: AppSpacing.sm),
      for (final line in lines) ...[
        PrivateUsdDepositLineText(
          line: line,
          minimum: BigInt.tryParse(terms?.minValue ?? ''),
          screening: screening,
          privacyModeEnabled: privacyModeEnabled,
        ),
        const SizedBox(height: AppSpacing.xs),
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
