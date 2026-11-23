import 'dart:async';

import 'package:flutter/material.dart' show TextField, InputDecoration;
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/formatting/address_display.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/mobile/neon_glyph_badge.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../core/widgets/comma_to_dot_input_formatter.dart';
import '../../../../core/widgets/decimal_amount_input_formatter.dart';
import '../../../../core/widgets/mobile/tron_glyph.dart' show TronGlyphKind;
import '../../models/private_usd_desktop_wording.dart';
import '../../models/private_usd_explorer.dart';
import '../../models/private_usd_messages.dart';
import '../../models/private_usd_send.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_send_provider.dart';
import '../../providers/private_usd_spend_status_provider.dart';
import '../../providers/railgun_engine_provider.dart';
import '../../services/private_usd_spend_guard.dart';
import '../../services/railgun_engine.dart';
import '../../widgets/desktop/desktop_private_usd_widgets.dart';
import '../../widgets/mobile/private_usd_flow_widgets.dart';
import '../../widgets/mobile/private_usd_paste_button.dart';

/// The send and withdraw screens' info, as the phone's sheets say it.
void _showSendInfo(BuildContext context, PrivateUsdSendMode mode, String fee) {
  final l10n = context.l10n;
  unawaited(
    mode == PrivateUsdSendMode.private
        ? showDesktopPrivateUsdInfo(
            context,
            title: l10n.privateUsdSendInfoTitle,
            steps: [
              l10n.privateUsdSendInfoStepAddress,
              privateUsdComputerWording
                  ? l10n.privateUsdSendInfoStepProofLinux
                  : l10n.privateUsdSendInfoStepProofDesktop,
              l10n.privateUsdSendInfoStepPrivate,
            ],
          )
        : showDesktopPrivateUsdInfo(
            context,
            title: l10n.privateUsdWithdrawInfoTitle,
            steps: [
              l10n.privateUsdWithdrawInfoStepAddress,
              privateUsdComputerWording
                  ? l10n.privateUsdWithdrawInfoStepProofLinux
                  : l10n.privateUsdWithdrawInfoStepProofDesktop,
            ],
            notes: [
              l10n.privateUsdWithdrawInfoNotePublic,
              l10n.privateUsdWithdrawInfoNotePrivate,
              l10n.privateUsdWithdrawInfoNoteFee(fee),
            ],
          ),
  );
}

/// `/private-usd/send` and `/private-usd/withdraw` on desktop: the amount,
/// the recipient (typed or pasted; desktop has no camera scan) and Review,
/// which prices the send and opens its review. The phone's form and its
/// rules ([privateUsdSendProvider]): one outgoing payment at a time, and
/// the relayer's fee capped.
class DesktopPrivateUsdSendScreen extends ConsumerStatefulWidget {
  const DesktopPrivateUsdSendScreen({required this.mode, super.key});

  final PrivateUsdSendMode mode;

  @override
  ConsumerState<DesktopPrivateUsdSendScreen> createState() =>
      _DesktopPrivateUsdSendScreenState();
}

class _DesktopPrivateUsdSendScreenState
    extends ConsumerState<DesktopPrivateUsdSendScreen> {
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

  bool get _private => widget.mode == PrivateUsdSendMode.private;

  void _setText(TextEditingController controller, String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _review() async {
    FocusScope.of(context).unfocus();
    if (!await _notifier.review() || !mounted) return;
    final finished = await context.push<bool>('${widget.mode.path}/review');
    if (!mounted) return;
    final phase = ref.read(privateUsdSendProvider(widget.mode)).phase;
    if (finished == true || phase == PrivateUsdSendPhase.done) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    if (uuid == null) return const SizedBox.shrink();
    final colors = context.colors;
    final form = ref.watch(privateUsdSendProvider(widget.mode));
    final balances = ref.watch(privateUsdBalanceProvider(uuid)).balances;
    final status = ref.watch(privateUsdSpendStatusProvider(uuid));
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    final assets = form.assets(balances);
    final asset = form.asset(balances);
    final amountError = form.amountError(context.l10n, asset);
    final recipientError = form.recipientError(context.l10n);
    final request = asset == null ? null : form.request(asset);
    final message =
        form.error?.call(context.l10n) ??
        (form.isBusy ? null : privateUsdSpendMessage(context.l10n, status));
    final canReview = request != null && status.canSend && !form.isBusy;
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _notifier.cancelPricing();
      },
      child: DesktopPrivateUsdPage(
        title: _private
            ? context.l10n.privateUsdSendTitle
            : context.l10n.privateUsdActionWithdraw,
        contentKey: const ValueKey('desktop_private_usd_send_content'),
        onBeforeBack: _notifier.cancelPricing,
        onInfo: () =>
            _showSendInfo(context, widget.mode, kPrivateUsdRailgunFeePercent),
        children: [
          if (assets.length > 1) ...[
            DesktopPrivateUsdCaption(context.l10n.privateUsdSendAsset),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final option in assets)
                  AppButton(
                    key: ValueKey(
                      'desktop_private_usd_send_asset_${option.token.symbol}',
                    ),
                    variant: option.token == asset?.token
                        ? AppButtonVariant.primary
                        : AppButtonVariant.secondary,
                    size: AppButtonSize.small,
                    onPressed: form.isBusy
                        ? null
                        : () {
                            _setText(_amount, '');
                            _notifier.chooseToken(option.token);
                          },
                    child: Text(option.token.symbol),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.s),
          ],
          _AmountPanel(
            controller: _amount,
            focusNode: _amountFocus,
            readOnly: form.isBusy,
            error: amountError,
            available: asset == null
                ? PrivateUsdCopy.unknown
                : hideAmountIfPrivacyMode(
                    formatPrivateUsdExact(
                      asset.available,
                      asset.token.decimals,
                    ),
                    privacyModeEnabled: privacyModeEnabled,
                    denomination: '',
                  ),
            onMax: asset != null && !form.isBusy
                ? () {
                    final text = _notifier.useAll();
                    if (text != null) _setText(_amount, text);
                  }
                : null,
            onChanged: _notifier.setAmount,
          ),
          const SizedBox(height: AppSpacing.s),
          DesktopPrivateUsdPanel(
            key: const ValueKey('desktop_private_usd_send_recipient_card'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DesktopPrivateUsdCaption(
                  _private
                      ? context.l10n.privateUsdSendToPrivate
                      : context.l10n.privateUsdSendToWithdraw,
                ),
                const SizedBox(height: AppSpacing.xs),
                AppTextField(
                  key: const ValueKey('desktop_private_usd_send_recipient'),
                  label: _private
                      ? context.l10n.privateUsdSendToPrivate
                      : context.l10n.privateUsdSendToWithdraw,
                  showLabel: false,
                  controller: _recipient,
                  focusNode: _recipientFocus,
                  enabled: !form.isBusy,
                  hintText: _private
                      ? PrivateUsdCopy.sendHintPrivate
                      : PrivateUsdCopy.sendHintWithdraw,
                  enableSuggestions: false,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  onChanged: _notifier.setRecipient,
                  onSubmitted: (_) {
                    if (canReview) unawaited(_review());
                  },
                  trailing: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: PrivateUsdPasteButton(
                      key: const ValueKey('desktop_private_usd_send_paste'),
                      controller: _recipient,
                      enabled: !form.isBusy,
                      onPasted: _notifier.setRecipient,
                    ),
                  ),
                ),
                if (recipientError != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    recipientError,
                    key: const ValueKey(
                      'desktop_private_usd_send_recipient_error',
                    ),
                    style: AppTypography.bodySmall.copyWith(
                      color: colors.text.destructive,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.s),
            DesktopPrivateUsdNotice(
              key: const ValueKey('desktop_private_usd_send_message'),
              message: message,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AppButton(
            key: const ValueKey('desktop_private_usd_send_review'),
            expand: true,
            onPressed: canReview ? () => unawaited(_review()) : null,
            leading: form.isBusy
                ? const AppLoadingIcon(size: AppIconSize.medium)
                : null,
            child: Text(context.l10n.privateUsdReview),
          ),
        ],
      ),
    );
  }
}

/// The amount's panel: its caption, the field, what is available and Max.
class _AmountPanel extends StatelessWidget {
  const _AmountPanel({
    required this.controller,
    required this.focusNode,
    required this.readOnly,
    required this.error,
    required this.available,
    required this.onMax,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool readOnly;
  final String? error;
  final String available;
  final VoidCallback? onMax;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final error = this.error;
    final amountStyle = AppTypography.displayLarge.copyWith(
      color: error != null ? colors.text.destructive : colors.text.accent,
    );
    final small = AppTypography.bodySmall;
    return DesktopPrivateUsdPanel(
      key: const ValueKey('desktop_private_usd_send_amount_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopPrivateUsdCaption(context.l10n.commonAmount),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            key: const ValueKey('desktop_private_usd_send_amount'),
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            readOnly: readOnly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              const CommaToDotInputFormatter(),
              // Finer than the token goes is flagged, not swallowed.
              DecimalAmountInputFormatter(maxFractionDigits: 18),
            ],
            onChanged: onChanged,
            style: amountStyle,
            cursorColor: colors.neon.glow,
            decoration: InputDecoration.collapsed(
              hintText: '0',
              hintStyle: amountStyle.copyWith(color: colors.text.muted),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              error,
              key: const ValueKey('desktop_private_usd_send_amount_error'),
              style: small.copyWith(color: colors.text.destructive),
            ),
          ],
          const SizedBox(height: AppSpacing.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.privateUsdAvailableAmount(available),
                  key: const ValueKey('desktop_private_usd_send_available'),
                  style: small.copyWith(color: colors.text.secondary),
                ),
              ),
              Semantics(
                label: context.l10n.privateUsdUseAvailable,
                button: true,
                excludeSemantics: true,
                child: AppButton(
                  key: const ValueKey('desktop_private_usd_send_max'),
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.small,
                  onPressed: onMax,
                  child: Text(context.l10n.privateUsdMax),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `/private-usd/send/review` and `/private-usd/withdraw/review` on desktop:
/// what goes, what it costs and where, then the button that sends, which
/// opens the status while it proves and posts. Pops with `true` once the
/// send is done, so the form closes too.
class DesktopPrivateUsdSendReviewScreen extends ConsumerWidget {
  const DesktopPrivateUsdSendReviewScreen({required this.mode, super.key});

  final PrivateUsdSendMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    final form = ref.watch(privateUsdSendProvider(mode));
    final notifier = ref.read(privateUsdSendProvider(mode).notifier);
    final balances = uuid == null
        ? null
        : ref.watch(privateUsdBalanceProvider(uuid)).balances;
    final status = uuid == null
        ? PrivateUsdSpendStatus.checking
        : ref.watch(privateUsdSpendStatusProvider(uuid));
    final private = mode == PrivateUsdSendMode.private;
    final request = form.reviewed;
    final cost = form.cost;
    final message =
        form.error?.call(context.l10n) ??
        form.reviewError(context.l10n, balances) ??
        (form.isBusy ? null : privateUsdSpendMessage(context.l10n, status));
    final canConfirm = notifier.canConfirm;

    Future<void> confirm() async {
      if (!notifier.canConfirm) return;
      unawaited(notifier.confirm());
      final finished = await context.push<bool>(
        '/private-usd/send/status',
        extra: mode,
      );
      if (!context.mounted) return;
      final phase = ref.read(privateUsdSendProvider(mode)).phase;
      if (finished == true || phase == PrivateUsdSendPhase.done) {
        context.pop(true);
      } else if (phase == PrivateUsdSendPhase.form) {
        // Repriced past what the balance leaves: back to the form.
        context.pop(false);
      }
    }

    return PopScope<Object?>(
      canPop: !form.isBusy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) notifier.leaveReview();
      },
      child: DesktopPrivateUsdPage(
        title: private
            ? context.l10n.privateUsdSendReviewTitlePrivate
            : context.l10n.privateUsdSendReviewTitleWithdraw,
        contentKey: const ValueKey('desktop_private_usd_send_review_content'),
        canGoBack: !form.isBusy,
        onBeforeBack: notifier.leaveReview,
        onInfo: () => _showSendInfo(
          context,
          mode,
          cost == null || cost.feeBasisPoints == 0
              ? kPrivateUsdRailgunFeePercent
              : privateUsdPercentText(cost.feeBasisPoints),
        ),
        children: [
          if (request != null && cost != null)
            DesktopPrivateUsdLedger(
              key: const ValueKey('desktop_private_usd_send_review_ledger'),
              rows: [
                for (final (label, value) in privateUsdSendReviewRows(
                  context.l10n,
                  request,
                  cost,
                  feeToken: form.networkFee?.token,
                ))
                  PrivateUsdLedgerRow(label: label, value: value),
                PrivateUsdLedgerAddress(
                  label: context.l10n.commonTo,
                  address: request.to.text,
                ),
              ],
            ),
          if (!private) ...[
            const SizedBox(height: AppSpacing.s),
            Text(
              context.l10n.privateUsdSendWithdrawPublic,
              key: const ValueKey('desktop_private_usd_send_review_public'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.warning,
              ),
            ),
          ],
          if (message != null) ...[
            const SizedBox(height: AppSpacing.s),
            DesktopPrivateUsdNotice(
              key: const ValueKey('desktop_private_usd_send_review_message'),
              message: message,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AppButton(
            key: const ValueKey('desktop_private_usd_send_confirm'),
            expand: true,
            onPressed: canConfirm ? () => unawaited(confirm()) : null,
            leading: form.isBusy
                ? const AppLoadingIcon(size: AppIconSize.medium)
                : null,
            child: Text(
              form.isBusy
                  ? context.l10n.privateUsdSendSending
                  : private
                  ? context.l10n.privateUsdActionSend
                  : context.l10n.privateUsdActionWithdraw,
            ),
          ),
        ],
      ),
    );
  }
}

/// `/private-usd/send/status` on desktop (`extra`: the mode): the proof's
/// progress while it proves, then the outcome, pending while it is not in a
/// block yet. The back link and the sidebar are held while it runs. When
/// nothing was sent (busy, not sent, repriced) it pops back to the review;
/// Done pops with `true`.
class DesktopPrivateUsdSendStatusScreen extends ConsumerStatefulWidget {
  const DesktopPrivateUsdSendStatusScreen({required this.mode, super.key});

  final PrivateUsdSendMode mode;

  @override
  ConsumerState<DesktopPrivateUsdSendStatusScreen> createState() =>
      _DesktopPrivateUsdSendStatusScreenState();
}

class _DesktopPrivateUsdSendStatusScreenState
    extends ConsumerState<DesktopPrivateUsdSendStatusScreen> {
  var _left = false;

  @override
  void initState() {
    super.initState();
    // An outcome may land before this screen first builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaveIfBack(ref.read(privateUsdSendProvider(widget.mode)));
    });
  }

  void _leaveIfBack(PrivateUsdSendForm form) {
    final back =
        form.phase == PrivateUsdSendPhase.form ||
        form.phase == PrivateUsdSendPhase.review;
    if (!back || _left || !mounted) return;
    _left = true;
    context.pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final form = ref.watch(privateUsdSendProvider(widget.mode));
    ref.listen(
      privateUsdSendProvider(widget.mode),
      (_, next) => _leaveIfBack(next),
    );
    final engine = ref.watch(railgunEngineStateProvider);
    final proving = engine.phase == RailgunEnginePhase.proving;
    final prefix = ref.watch(
      privateUsdCurrentDeploymentProvider.select((d) => d?.explorerTxPrefix),
    );
    final outcome = form.outcome;
    final txHash = switch (outcome) {
      PrivateUsdSendSent(:final txHash) => txHash,
      PrivateUsdSendUnconfirmed(:final txHash) => txHash,
      _ => null,
    };
    final uri = txHash == null ? null : privateUsdExplorerUri(prefix, txHash);
    final request = form.reviewed;
    final running = form.phase != PrivateUsdSendPhase.done || request == null;
    final String title;
    final String body;
    final List<Widget> actions;
    final Widget badge;
    if (running) {
      final posting = form.step == PrivateUsdSendStep.posting;
      final percent = proving && engine.proof != null
          ? (engine.proof!.progress * 100).round().clamp(0, 100)
          : null;
      title = posting
          ? context.l10n.privateUsdSendSending
          : percent == null
          ? context.l10n.privateUsdSendProving
          : context.l10n.privateUsdSendProvingPercent(percent);
      body = posting
          ? context.l10n.privateUsdSendLanding
          : privateUsdComputerWording
          ? context.l10n.privateUsdSendProvingDetailLinux
          : context.l10n.privateUsdSendProvingDetailDesktop;
      actions = const [];
      badge = const SizedBox.square(
        dimension: 72,
        child: Center(child: AppLoadingIcon(size: AppIconSize.large)),
      );
    } else {
      final unconfirmed = outcome is PrivateUsdSendUnconfirmed;
      final amount = formatPrivateUsdExact(
        request.amount,
        request.token.decimals,
      );
      final address = truncatedAddress(request.to.text);
      title = widget.mode == PrivateUsdSendMode.private
          ? context.l10n.privateUsdSendDoneTitlePrivate
          : context.l10n.privateUsdSendDoneTitleWithdraw;
      body = unconfirmed
          ? context.l10n.privateUsdSendDoneUnconfirmedBody(amount, address)
          : context.l10n.privateUsdSendDoneBody(amount, address);
      // Pending until it is in a block; the activity row follows it there.
      badge = NeonGlyphBadge(
        glyph: unconfirmed ? TronGlyphKind.activity : TronGlyphKind.check,
        size: 72,
      );
      actions = [
        AppButton(
          key: const ValueKey('desktop_private_usd_send_status_done'),
          expand: true,
          onPressed: () => context.pop(true),
          child: Text(context.l10n.commonDone),
        ),
        if (uri != null) ...[
          const SizedBox(height: AppSpacing.xs),
          AppButton(
            key: const ValueKey('desktop_private_usd_send_status_tx'),
            variant: AppButtonVariant.secondary,
            expand: true,
            onPressed: () =>
                unawaited(launchUrl(uri, mode: LaunchMode.externalApplication)),
            child: Text(context.l10n.privateUsdSendViewTx),
          ),
        ],
      ];
    }
    return PopScope<Object?>(
      canPop: !running,
      child: DesktopPrivateUsdPage(
        title: widget.mode == PrivateUsdSendMode.private
            ? context.l10n.privateUsdSendTitle
            : context.l10n.privateUsdActionWithdraw,
        contentKey: const ValueKey('desktop_private_usd_send_status_content'),
        canGoBack: !running,
        children: [
          const SizedBox(height: AppSpacing.md),
          Center(child: badge),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            key: const ValueKey('desktop_private_usd_send_status_title'),
            textAlign: TextAlign.center,
            style: AppTypography.headlineSmall.copyWith(
              color: colors.text.accent,
              fontWeight: AppFontWeight.heading,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            body,
            key: const ValueKey('desktop_private_usd_send_status_body'),
            textAlign: TextAlign.center,
            style: AppTypography.bodyMedium.copyWith(
              color: colors.text.secondary,
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            ...actions,
          ],
        ],
      ),
    );
  }
}
