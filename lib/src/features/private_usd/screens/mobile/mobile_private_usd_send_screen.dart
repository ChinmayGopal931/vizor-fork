import 'dart:async';

import 'package:flutter/material.dart'
    show InputDecoration, Scaffold, TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/mobile/mobile_top_nav.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/comma_to_dot_input_formatter.dart';
import '../../../../core/widgets/decimal_amount_input_formatter.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/mobile_warning_notice.dart';
import '../../../../core/widgets/mobile_text_field.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../address_scan/widgets/mobile_scan_address_row.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_send.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_send_provider.dart';
import '../../providers/private_usd_spend_status_provider.dart';
import '../../services/private_usd_spend_guard.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import '../../widgets/mobile/private_usd_scan_sheet.dart';
import 'mobile_private_usd_convert_screen.dart';

/// `/private-usd/send` and `/private-usd/withdraw` (plan reference §9.4
/// S8): the amount, the recipient and "Review", which prices the send and
/// opens its review. The mode is fixed by the button that opened it.
class MobilePrivateUsdSendScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdSendScreen({required this.mode, super.key});

  final PrivateUsdSendMode mode;

  @override
  ConsumerState<MobilePrivateUsdSendScreen> createState() =>
      _MobilePrivateUsdSendScreenState();
}

class _MobilePrivateUsdSendScreenState
    extends ConsumerState<MobilePrivateUsdSendScreen> {
  final _amount = TextEditingController();
  final _recipient = TextEditingController();
  final _amountFocus = FocusNode();
  final _recipientFocus = FocusNode();

  @override
  void dispose() {
    _amount.dispose();
    _recipient.dispose();
    _amountFocus.dispose();
    _recipientFocus.dispose();
    super.dispose();
  }

  PrivateUsdSendNotifier get _notifier =>
      ref.read(privateUsdSendProvider(widget.mode).notifier);

  void _setText(TextEditingController controller, String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted || text == null || text.isEmpty) return;
    _setText(_recipient, text);
    _notifier.setRecipient(text);
  }

  Future<void> _scan() async {
    final address = await showPrivateUsdScanSheet(
      context,
      mode: widget.mode,
      chainId: ref.read(privateUsdCurrentDeploymentProvider)?.chainId,
    );
    if (!mounted || address == null) return;
    _setText(_recipient, address);
    _notifier.setRecipient(address);
  }

  Future<void> _review() async {
    FocusScope.of(context).unfocus();
    if (!await _notifier.review() || !mounted) return;
    final finished = await context.push<bool>('${widget.mode.path}/review');
    if (!mounted) return;
    final phase = ref.read(privateUsdSendProvider(widget.mode)).phase;
    if (finished == true || phase == PrivateUsdSendPhase.done) context.pop();
  }

  void _back() {
    _notifier.cancelPricing();
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    if (uuid == null) return const SizedBox.shrink();
    final form = ref.watch(privateUsdSendProvider(widget.mode));
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _notifier.cancelPricing();
      },
      child: MobilePrivateUsdSendView(
        form: form,
        balances: ref.watch(privateUsdBalanceProvider(uuid)).balances,
        status: ref.watch(privateUsdSpendStatusProvider(uuid)),
        privacyModeEnabled: ref.watch(privacyModeProvider),
        amountController: _amount,
        recipientController: _recipient,
        amountFocus: _amountFocus,
        recipientFocus: _recipientFocus,
        onAmountChanged: _notifier.setAmount,
        onRecipientChanged: _notifier.setRecipient,
        onChooseToken: (token) {
          _setText(_amount, '');
          _notifier.chooseToken(token);
        },
        onUseAll: () {
          final text = _notifier.useAll();
          if (text != null) _setText(_amount, text);
        },
        onPaste: _paste,
        onScan: _scan,
        onReview: _review,
        onBack: _back,
      ),
    );
  }
}

/// The send form's content for a given form, balance and spend status.
/// Widgetbook, capture scenarios and tests build it directly; they pass
/// their own `0zk` check, as there is no Rust there.
class MobilePrivateUsdSendView extends StatelessWidget {
  const MobilePrivateUsdSendView({
    required this.form,
    required this.balances,
    required this.status,
    required this.amountController,
    required this.recipientController,
    required this.onAmountChanged,
    required this.onRecipientChanged,
    required this.onUseAll,
    required this.onReview,
    required this.onBack,
    this.onChooseToken,
    this.onPaste,
    this.onScan,
    this.amountFocus,
    this.recipientFocus,
    this.isRailgunAddress = privateUsdIsRailgunAddress,
    this.privacyModeEnabled = false,
    this.autofocus = true,
    super.key,
  });

  final PrivateUsdSendForm form;
  final PrivateUsdBalances? balances;
  final PrivateUsdSpendStatus status;
  final TextEditingController amountController;
  final TextEditingController recipientController;
  final FocusNode? amountFocus;
  final FocusNode? recipientFocus;
  final ValueChanged<String> onAmountChanged;
  final ValueChanged<String> onRecipientChanged;
  final ValueChanged<PrivateUsdToken>? onChooseToken;
  final VoidCallback onUseAll;
  final VoidCallback? onPaste;

  /// Opens the camera scanner for the recipient; null hides its row.
  final VoidCallback? onScan;
  final VoidCallback onReview;
  final VoidCallback onBack;
  final PrivateUsdRailgunAddressCheck isRailgunAddress;
  final bool privacyModeEnabled;
  final bool autofocus;

  bool get _private => form.mode == PrivateUsdSendMode.private;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final assets = form.assets(balances);
    final asset = form.asset(balances);
    final amountError = form.amountError(asset);
    final recipientError = form.recipientError(
      isRailgunAddress: isRailgunAddress,
    );
    final request = asset == null
        ? null
        : form.request(asset, isRailgunAddress: isRailgunAddress);
    final message =
        form.error ?? (form.isBusy ? null : privateUsdSpendMessage(status));
    final canReview = request != null && status.canSend && !form.isBusy;
    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileTopNav.back(
              title: _private
                  ? PrivateUsdCopy.sendTitle
                  : PrivateUsdCopy.withdrawTitle,
              onBack: onBack,
              trailing: PrivateUsdInfoButton(
                onTap: () => _private
                    ? showPrivateUsdSendInfoSheet(context)
                    : showPrivateUsdWithdrawInfoSheet(
                        context,
                        railgunPercent: kPrivateUsdRailgunFeePercent,
                      ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('mobile_private_usd_send_scroll'),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (assets.length > 1) ...[
                      _AssetChooser(
                        assets: assets,
                        selected: asset?.token,
                        enabled: !form.isBusy,
                        onChoose: onChooseToken,
                      ),
                      const SizedBox(height: AppSpacing.s),
                    ],
                    _AmountCard(
                      form: form,
                      asset: asset,
                      error: amountError,
                      controller: amountController,
                      focusNode: amountFocus,
                      autofocus: autofocus,
                      privacyModeEnabled: privacyModeEnabled,
                      onChanged: onAmountChanged,
                      onUseAll: onUseAll,
                    ),
                    const SizedBox(height: AppSpacing.s),
                    _RecipientCard(
                      private: _private,
                      error: recipientError,
                      enabled: !form.isBusy,
                      controller: recipientController,
                      focusNode: recipientFocus,
                      onChanged: onRecipientChanged,
                      onPaste: onPaste,
                      onScan: onScan,
                    ),
                    if (message != null) ...[
                      const SizedBox(height: AppSpacing.s),
                      MobileWarningNotice(
                        key: const ValueKey('mobile_private_usd_send_message'),
                        message: message,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                AppSpacing.s,
                AppSpacing.sm,
                AppSpacing.md,
              ),
              child: AppButton(
                key: const ValueKey('mobile_private_usd_send_review'),
                expand: true,
                onPressed: canReview ? onReview : null,
                leading: form.isBusy
                    ? const AppLoadingIcon(size: AppIconSize.medium)
                    : null,
                child: const Text(PrivateUsdCopy.review),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssetChooser extends StatelessWidget {
  const _AssetChooser({
    required this.assets,
    required this.selected,
    required this.enabled,
    required this.onChoose,
  });

  final List<PrivateUsdAsset> assets;
  final PrivateUsdToken? selected;
  final bool enabled;
  final ValueChanged<PrivateUsdToken>? onChoose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          PrivateUsdCopy.sendAsset,
          style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            for (final asset in assets)
              AppButton(
                key: ValueKey(
                  'mobile_private_usd_send_asset_${asset.token.symbol}',
                ),
                variant: asset.token == selected
                    ? AppButtonVariant.primary
                    : AppButtonVariant.secondary,
                size: AppButtonSize.small,
                onPressed: enabled && onChoose != null
                    ? () => onChoose!(asset.token)
                    : null,
                child: Text(asset.token.symbol),
              ),
          ],
        ),
      ],
    );
  }
}

class _AmountCard extends StatelessWidget {
  const _AmountCard({
    required this.form,
    required this.asset,
    required this.error,
    required this.controller,
    required this.focusNode,
    required this.autofocus,
    required this.privacyModeEnabled,
    required this.onChanged,
    required this.onUseAll,
  });

  final PrivateUsdSendForm form;
  final PrivateUsdAsset? asset;
  final String? error;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool privacyModeEnabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onUseAll;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final asset = this.asset;
    final error = this.error;
    final amountStyle = AppTypography.displayLarge.copyWith(
      color: error != null ? colors.text.destructive : colors.text.accent,
    );
    final available = asset == null
        ? PrivateUsdCopy.unknown
        : hideAmountIfPrivacyMode(
            formatPrivateUsdExact(asset.available, asset.token.decimals),
            privacyModeEnabled: privacyModeEnabled,
            denomination: '',
          );
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_send_amount_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            PrivateUsdCopy.sendAmount,
            style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
          ),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            key: const ValueKey('mobile_private_usd_send_amount'),
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            readOnly: form.isBusy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            // Finer than the token goes is flagged, not swallowed.
            inputFormatters: const [
              CommaToDotInputFormatter(),
              DecimalAmountInputFormatter(maxFractionDigits: 18),
            ],
            onChanged: onChanged,
            style: amountStyle,
            cursorColor: colors.text.accent,
            decoration: InputDecoration.collapsed(
              hintText: '0',
              hintStyle: amountStyle.copyWith(color: colors.text.muted),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              error,
              key: const ValueKey('mobile_private_usd_send_amount_error'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.destructive,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${PrivateUsdCopy.rowAvailable}: $available',
                  key: const ValueKey('mobile_private_usd_send_available'),
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.secondary,
                  ),
                ),
              ),
              Semantics(
                label: PrivateUsdCopy.useAvailable,
                button: true,
                excludeSemantics: true,
                child: AppButton(
                  key: const ValueKey('mobile_private_usd_send_max'),
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.small,
                  onPressed: asset != null && !form.isBusy ? onUseAll : null,
                  child: const Text(PrivateUsdCopy.max),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecipientCard extends StatelessWidget {
  const _RecipientCard({
    required this.private,
    required this.error,
    required this.enabled,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onPaste,
    required this.onScan,
  });

  final bool private;
  final String? error;
  final bool enabled;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback? onPaste;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final error = this.error;
    final onPaste = this.onPaste;
    final onScan = this.onScan;
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_send_recipient_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            private
                ? PrivateUsdCopy.sendToPrivate
                : PrivateUsdCopy.sendToWithdraw,
            style: AppTypography.labelLarge.copyWith(color: colors.text.accent),
          ),
          const SizedBox(height: AppSpacing.xs),
          _RecipientField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            hint: private
                ? PrivateUsdCopy.sendHintPrivate
                : PrivateUsdCopy.sendHintWithdraw,
            onChanged: onChanged,
            trailing: onPaste == null
                ? null
                : Semantics(
                    button: true,
                    label: PrivateUsdCopy.sendPaste,
                    excludeSemantics: true,
                    child: GestureDetector(
                      key: const ValueKey('mobile_private_usd_send_paste'),
                      behavior: HitTestBehavior.opaque,
                      onTap: enabled ? onPaste : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.s,
                        ),
                        child: AppIcon(
                          AppIcons.paste,
                          size: 20,
                          color: colors.text.primary,
                        ),
                      ),
                    ),
                  ),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              error,
              key: const ValueKey('mobile_private_usd_send_recipient_error'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.destructive,
              ),
            ),
          ],
          // As ZEC Send's recipient picker: the Receive sheet shows both
          // kinds of address as a code.
          if (onScan != null) ...[
            const SizedBox(height: AppSpacing.s),
            MobileScanAddressRow(
              key: const ValueKey('mobile_private_usd_send_scan'),
              onTap: enabled ? onScan : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// The address field: [MobileTextField] needs a focus node, so it owns one
/// when the caller has none (previews).
class _RecipientField extends StatefulWidget {
  const _RecipientField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.hint,
    required this.onChanged,
    required this.trailing,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool enabled;
  final String hint;
  final ValueChanged<String> onChanged;
  final Widget? trailing;

  @override
  State<_RecipientField> createState() => _RecipientFieldState();
}

class _RecipientFieldState extends State<_RecipientField> {
  FocusNode? _own;

  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobileTextField(
    fieldKey: const ValueKey('mobile_private_usd_send_recipient'),
    controller: widget.controller,
    focusNode: _focus,
    enabled: widget.enabled,
    hintText: widget.hint,
    keyboardType: TextInputType.visiblePassword,
    textInputAction: TextInputAction.done,
    onChanged: widget.onChanged,
    trailing: widget.trailing,
  );
}
