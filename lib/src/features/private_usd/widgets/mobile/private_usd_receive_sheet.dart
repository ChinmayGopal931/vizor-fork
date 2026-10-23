import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/feedback/app_haptics.dart';
import '../../../../core/layout/mobile/app_mobile_sheet.dart';
import '../../../../core/layout/mobile/mobile_bottom_safe_area.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_toast.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../core/widgets/mobile/neon_switch_tabs.dart';
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

/// How often the open sheet asks for a deposit pass: it is open while money
/// is on its way to the address, so a deposit shows soon after it lands.
const _sheetRefresh = Duration(seconds: 15);

/// The Receive sheet's two ways in, as ZEC's Receive has its pools.
enum PrivateUsdReceiveKind {
  /// Public USDC from an exchange or any wallet, to the deposit address,
  /// shielded on its own.
  usdc,

  /// 0zkUSDC from another Railgun wallet, to the account's 0zk address.
  shielded,
}

/// The Receive sheet: a switch like ZEC's Receive between public USDC (the
/// default) and shielded 0zkUSDC. [deposits] is false where the network
/// pins no Deposits contract: then only the 0zk address shows.
///
/// Public USDC: the account's deposit address, as a QR code of the plain
/// EIP-55 `0x…` string (no `ethereum:` URI, which withdrawal forms refuse),
/// with the one token and network it takes, the minimum and both fees,
/// shown before anything is signed.
Future<void> showPrivateUsdReceiveSheet(
  BuildContext context, {
  required String accountUuid,
  required bool deposits,
}) {
  return showAppMobileSheet<void>(
    context: context,
    builder: (sheetContext) => PrivateUsdReceiveSheet(
      accountUuid: accountUuid,
      deposits: deposits,
      onClose: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

class PrivateUsdReceiveSheet extends ConsumerStatefulWidget {
  const PrivateUsdReceiveSheet({
    required this.accountUuid,
    required this.deposits,
    required this.onClose,
    super.key,
  });

  final String accountUuid;
  final bool deposits;
  final VoidCallback onClose;

  @override
  ConsumerState<PrivateUsdReceiveSheet> createState() =>
      _PrivateUsdReceiveSheetState();
}

class _PrivateUsdReceiveSheetState
    extends ConsumerState<PrivateUsdReceiveSheet> {
  Timer? _timer;
  late var _kind = widget.deposits
      ? PrivateUsdReceiveKind.usdc
      : PrivateUsdReceiveKind.shielded;

  @override
  void initState() {
    super.initState();
    if (!widget.deposits) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(privateUsdDepositActionsProvider).refresh();
    });
    _timer = Timer.periodic(_sheetRefresh, (_) {
      if (mounted) ref.read(privateUsdDepositActionsProvider).refresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final pin = deployment?.deposits;
    final railgunAddress = ref.watch(
      privateUsdReceiveAddressProvider(widget.accountUuid),
    );
    final pass = widget.deposits
        ? ref.watch(privateUsdDepositPassProvider(widget.accountUuid))
        : null;
    // Before a pass has run, the address the last scan kept (no network).
    final fallback = widget.deposits && pass == null
        ? ref.watch(privateUsdDepositAddressProvider(widget.accountUuid))
        : null;
    final screening = Duration(seconds: deployment?.screeningSeconds ?? 0);
    // What the minimum brings, from Rust's own fee and cap.
    final terms = pass?.terms;
    final example = terms == null
        ? null
        : rust.privateUsdDepositQuote(
            fee: terms.fee,
            feeBps: terms.feeBps,
            value: terms.minValue,
          );
    return PrivateUsdReceiveSheetBody(
      kind: _kind,
      onKindChanged: widget.deposits
          ? (kind) => setState(() => _kind = kind)
          : null,
      railgunAddress: railgunAddress.value,
      railgunAddressFailed: railgunAddress.hasError,
      example: example == null || terms == null
          ? null
          : PrivateUsdCopy.depositExample(
              formatPrivateUsd(BigInt.tryParse(terms.minValue) ?? BigInt.zero),
              formatPrivateUsd(BigInt.tryParse(example.arrives) ?? BigInt.zero),
            ),
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
      onClose: widget.onClose,
    );
  }
}

/// The sheet's content for a given way in, addresses, terms and deposits.
class PrivateUsdReceiveSheetBody extends StatelessWidget {
  const PrivateUsdReceiveSheetBody({
    required this.symbol,
    required this.chain,
    required this.address,
    required this.onClose,
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
    this.example,
    super.key,
  });

  /// Which way in shows.
  final PrivateUsdReceiveKind kind;

  /// Switches between the two; null hides the switch (no deposits here).
  final ValueChanged<PrivateUsdReceiveKind>? onKindChanged;

  /// The account's 0zk address; null while it loads.
  final String? railgunAddress;
  final bool railgunAddressFailed;

  /// What a deposit at the minimum brings after both fees.
  final String? example;

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
  final VoidCallback onClose;

  /// The relayer takes no deposits, or not the pinned ones: no address.
  bool get _unavailable =>
      termsError == rust.ApiPrivateUsdErrorCode.unavailable ||
      termsError == rust.ApiPrivateUsdErrorCode.wrongDeployment;

  Future<void> _copy(BuildContext context, String address) async {
    // Neither address is sensitive: the plain clipboard.
    await Clipboard.setData(ClipboardData(text: address));
    unawaited(AppHaptics.copy());
    if (context.mounted) showAppToast(context, PrivateUsdCopy.addressCopied);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final onKindChanged = this.onKindChanged;
    final children = <Widget>[
      Text(
        PrivateUsdCopy.depositTitle(symbol),
        style: AppTypography.headlineSmall.copyWith(color: colors.text.accent),
      ),
      const SizedBox(height: AppSpacing.sm),
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
      // The two ways in differ in height: the sheet eases between them.
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
      const SizedBox(height: AppSpacing.md),
      AppButton(
        variant: AppButtonVariant.secondary,
        expand: true,
        onPressed: onClose,
        child: const Text(PrivateUsdCopy.close),
      ),
    ];
    return MobileBottomSafeArea(
      bottomPadding: AppSpacing.base,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm,
          AppSpacing.base,
          AppSpacing.sm,
          AppSpacing.base,
        ),
        child: Column(
          key: const ValueKey('private_usd_deposit_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
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
      const MobileWarningNotice(message: PrivateUsdCopy.receiveShieldedOnly),
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
          copyLabel: PrivateUsdCopy.receiveShieldedCopy,
        )
      else
        Text(
          railgunAddressFailed
              ? PrivateUsdCopy.depositAddressFailed
              : PrivateUsdCopy.depositAddressLoading,
          style: note,
        ),
      const SizedBox(height: AppSpacing.s),
      Text(PrivateUsdCopy.receiveAddressNote, style: note),
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
          PrivateUsdCopy.depositUnavailable,
          key: const ValueKey('private_usd_deposit_unavailable'),
          style: body,
        ),
      ];
    }
    return [
      MobileWarningNotice(message: PrivateUsdCopy.depositOnly(symbol, chain)),
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
          copyLabel: PrivateUsdCopy.depositCopy,
        )
      else
        Text(
          addressFailed
              ? PrivateUsdCopy.depositAddressFailed
              : PrivateUsdCopy.depositAddressLoading,
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
          PrivateUsdCopy.depositMinimum(
            formatPrivateUsd(BigInt.tryParse(terms.minValue) ?? BigInt.zero),
          ),
          key: const ValueKey('private_usd_deposit_minimum'),
          style: body,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          PrivateUsdCopy.depositRelayerFee(
            formatPrivateUsd(BigInt.tryParse(terms.fee) ?? BigInt.zero),
            privateUsdPercentText(terms.feeBps),
          ),
          key: const ValueKey('private_usd_deposit_relayer_fee'),
          style: body,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          PrivateUsdCopy.depositRailgunFee(
            privateUsdPercentText(terms.railgunFeeBps),
          ),
          style: body,
        ),
        if (example case final example?) ...[
          const SizedBox(height: AppSpacing.xxs),
          Text(example, style: note),
        ],
      ] else
        Text(
          termsError == null
              ? PrivateUsdCopy.depositFeesLoading
              : PrivateUsdCopy.depositFeesFailed,
          key: const ValueKey('private_usd_deposit_fees_status'),
          style: note,
        ),
      const SizedBox(height: AppSpacing.s),
      Text(PrivateUsdCopy.depositHow, style: note),
    ];
  }
}

/// One deposit state as a line of text (the sheet and the screen's card).
class PrivateUsdDepositLineText extends StatelessWidget {
  const PrivateUsdDepositLineText({
    required this.line,
    required this.minimum,
    required this.screening,
    required this.privacyModeEnabled,
    super.key,
  });

  final PrivateUsdDepositLine line;
  final BigInt? minimum;
  final Duration screening;
  final bool privacyModeEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final usd = hideAmountIfPrivacyMode(
      formatPrivateUsd(line.amount),
      privacyModeEnabled: privacyModeEnabled,
      denomination: '',
    );
    final minimum = this.minimum;
    final (text, color) = switch (line.phase) {
      PrivateUsdDepositPhase.received => (
        PrivateUsdCopy.depositReceived(usd),
        colors.text.accent,
      ),
      PrivateUsdDepositPhase.underMinimum => (
        minimum == null
            ? PrivateUsdCopy.depositReceived(usd)
            : PrivateUsdCopy.depositUnderMinimum(
                usd,
                formatPrivateUsd(minimum),
              ),
        colors.text.secondary,
      ),
      PrivateUsdDepositPhase.waiting => (
        PrivateUsdCopy.depositWaitingLine(usd),
        colors.text.secondary,
      ),
      PrivateUsdDepositPhase.shielding => (
        PrivateUsdCopy.depositShieldingLine(usd),
        colors.text.accent,
      ),
      PrivateUsdDepositPhase.shielded => (
        PrivateUsdCopy.depositShieldedLine(
          usd,
          PrivateUsdCopy.about(screening),
        ),
        colors.text.positiveStrong,
      ),
      PrivateUsdDepositPhase.notShielding => (
        PrivateUsdCopy.depositNotShieldingLine(usd),
        colors.text.secondary,
      ),
    };
    return Text(
      text,
      key: ValueKey(
        'private_usd_deposit_line_${line.index}_${line.phase.name}',
      ),
      style: AppTypography.bodySmall.copyWith(color: color),
    );
  }
}
