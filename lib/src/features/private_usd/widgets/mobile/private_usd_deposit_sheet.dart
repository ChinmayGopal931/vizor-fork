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

/// How often the sheet asks for a deposit pass while it is open (plan M9's
/// default cadence).
const _sheetRefresh = Duration(seconds: 15);

/// "Receive USDC" (plan M9): the account's deposit address for public USDC
/// from an exchange or any wallet, as a QR code of the plain EIP-55 `0x…`
/// string (no `ethereum:` URI, which withdrawal forms refuse), with the one
/// token and network it takes, the minimum and both fees, shown before
/// anything is signed. Deposits are read every 15 s while it is open.
Future<void> showPrivateUsdDepositSheet(
  BuildContext context, {
  required String accountUuid,
}) {
  return showAppMobileSheet<void>(
    context: context,
    builder: (sheetContext) => PrivateUsdDepositSheet(
      accountUuid: accountUuid,
      onClose: () => Navigator.of(sheetContext).pop(),
    ),
  );
}

class PrivateUsdDepositSheet extends ConsumerStatefulWidget {
  const PrivateUsdDepositSheet({
    required this.accountUuid,
    required this.onClose,
    super.key,
  });

  final String accountUuid;
  final VoidCallback onClose;

  @override
  ConsumerState<PrivateUsdDepositSheet> createState() =>
      _PrivateUsdDepositSheetState();
}

class _PrivateUsdDepositSheetState
    extends ConsumerState<PrivateUsdDepositSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
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
    final pin = ref.watch(privateUsdCurrentDeploymentProvider)?.deposits;
    final pass = ref.watch(privateUsdDepositPassProvider(widget.accountUuid));
    // Before a pass has run, the address the last scan kept (no network).
    final fallback = pass == null
        ? ref.watch(privateUsdDepositAddressProvider(widget.accountUuid))
        : null;
    final screening = Duration(
      seconds:
          ref.watch(privateUsdCurrentDeploymentProvider)?.screeningSeconds ?? 0,
    );
    return PrivateUsdDepositSheetBody(
      symbol: pin?.tokenSymbol ?? 'USDC',
      chain: pin?.chainName ?? 'Ethereum',
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

/// The sheet's content for a given address, terms and deposits. Widgetbook
/// and tests build it directly.
class PrivateUsdDepositSheetBody extends StatelessWidget {
  const PrivateUsdDepositSheetBody({
    required this.symbol,
    required this.chain,
    required this.address,
    required this.onClose,
    this.addressFailed = false,
    this.terms,
    this.termsError,
    this.lines = const [],
    this.screening = Duration.zero,
    this.privacyModeEnabled = false,
    super.key,
  });

  /// `USDC`, or `tUSD` on testnet; and `Ethereum`, or `Sepolia`.
  final String symbol;
  final String chain;

  /// EIP-55; null while it loads.
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
    // A deposit address is not sensitive: the plain clipboard.
    await Clipboard.setData(ClipboardData(text: address));
    unawaited(AppHaptics.copy());
    if (context.mounted) showAppToast(context, PrivateUsdCopy.addressCopied);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = AppTypography.bodyMedium.copyWith(color: colors.text.primary);
    final note = AppTypography.bodySmall.copyWith(color: colors.text.secondary);
    final address = this.address;
    final terms = this.terms;
    final children = <Widget>[
      Text(
        PrivateUsdCopy.depositTitle(symbol),
        style: AppTypography.headlineSmall.copyWith(color: colors.text.accent),
      ),
      const SizedBox(height: AppSpacing.s),
    ];
    if (_unavailable) {
      children.add(
        Text(
          PrivateUsdCopy.depositUnavailable,
          key: const ValueKey('private_usd_deposit_unavailable'),
          style: body,
        ),
      );
    } else {
      children.addAll([
        MobileWarningNotice(message: PrivateUsdCopy.depositOnly(symbol, chain)),
        const SizedBox(height: AppSpacing.sm),
        if (address != null) ...[
          // The code keeps its light plate; only the frame around it is lit.
          Center(
            child: ReceiveQrFrame(
              child: ReceiveQrSurface(
                key: const ValueKey('private_usd_deposit_qr'),
                address: address,
                size: 200,
                paddingX: AppSpacing.sm,
                paddingY: AppSpacing.sm,
                // A short address: the code keeps a version the badge
                // cannot spoil.
                type: ReceiveAddressType.transparent,
                badgeSize: 44,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            address,
            key: const ValueKey('private_usd_deposit_address'),
            textAlign: TextAlign.center,
            style: AppTypography.codeSmall.copyWith(color: colors.text.accent),
          ),
          const SizedBox(height: AppSpacing.s),
          AppButton(
            key: const ValueKey('private_usd_deposit_copy'),
            variant: AppButtonVariant.secondary,
            expand: true,
            leading: const AppIcon(AppIcons.copy),
            onPressed: () => unawaited(_copy(context, address)),
            child: const Text(PrivateUsdCopy.depositCopy),
          ),
        ] else
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
      ]);
    }
    children.addAll([
      const SizedBox(height: AppSpacing.md),
      AppButton(
        variant: AppButtonVariant.secondary,
        expand: true,
        onPressed: onClose,
        child: const Text(PrivateUsdCopy.close),
      ),
    ]);
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
        '${PrivateUsdCopy.depositReceived(usd)}. ${PrivateUsdCopy.depositWaiting}',
        colors.text.secondary,
      ),
      PrivateUsdDepositPhase.makingPrivate => (
        '${PrivateUsdCopy.depositReceived(usd)}. ${PrivateUsdCopy.depositMakingPrivate}',
        colors.text.accent,
      ),
      PrivateUsdDepositPhase.private => (
        '$usd: ${PrivateUsdCopy.depositPrivate(PrivateUsdCopy.about(screening))}',
        colors.text.positiveStrong,
      ),
      PrivateUsdDepositPhase.notShielding => (
        '${PrivateUsdCopy.depositReceived(usd)}. ${PrivateUsdCopy.depositNotShielding}',
        colors.text.secondary,
      ),
    };
    return Text(
      text,
      key: ValueKey('private_usd_deposit_line_${line.index}_${line.phase.name}'),
      style: AppTypography.bodySmall.copyWith(color: color),
    );
  }
}
