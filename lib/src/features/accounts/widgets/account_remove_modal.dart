import 'package:flutter/widgets.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/input/app_password_input_source.dart';
import '../../../core/security/password_policy.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/app_profile_picture.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/password_text_field.dart';
import '../../../providers/account_provider.dart'
    show UnsharedGiftCardsChangedException;
import '../../../providers/private_usd_lifecycle_provider.dart'
    show PrivateUsdUnfinishedConversionsException;
import '../../payment_links/services/payment_link_recovery_store.dart';
import 'account_modal_card.dart';
import '../../../core/widgets/neon_glass_panel.dart';

enum AccountRemoveProgress { stoppingSync, removingAccount }

typedef AccountRemoveProgressCallback =
    void Function(AccountRemoveProgress progress);

class AccountRemoveModal extends StatefulWidget {
  const AccountRemoveModal({
    required this.accountName,
    required this.profilePictureId,
    required this.isLastAccount,
    required this.pendingSwapCount,
    required this.checkingPendingSwaps,
    required this.pendingSwapCheckFailed,
    this.receivingGiftCardCount = 0,
    this.checkingReceivingGiftCards = false,
    this.receivingGiftCardCheckFailed = false,
    this.unsharedGiftCardCount = 0,
    this.privateUsdUnfinishedCount = 0,
    this.checkingPrivateUsd = false,
    required this.onCancel,
    required this.onConfirmPassword,
    required this.onRemove,
    super.key,
  });

  final String accountName;
  final String profilePictureId;
  final bool isLastAccount;
  final int pendingSwapCount;
  final bool checkingPendingSwaps;
  final bool pendingSwapCheckFailed;
  final int receivingGiftCardCount;
  final bool checkingReceivingGiftCards;
  final bool receivingGiftCardCheckFailed;

  /// Null when the unshared gift card check failed or is still running.
  final int? unsharedGiftCardCount;

  /// Shielded USD bridges under way that only this account (or, for the last
  /// one, this wallet) can finish or refund: warned about, never blocked
  /// (plan §3.5 invariant 15). Null when the check failed.
  final int? privateUsdUnfinishedCount;

  /// The bridge count is still being read: removal waits for it, so it never
  /// goes ahead unwarned.
  final bool checkingPrivateUsd;
  final VoidCallback onCancel;
  final Future<bool> Function(String password) onConfirmPassword;
  final Future<void> Function(AccountRemoveProgressCallback onProgress)
  onRemove;

  @override
  State<AccountRemoveModal> createState() => _AccountRemoveModalState();
}

class _AccountRemoveModalState extends State<AccountRemoveModal> {
  static const _fieldHeight = 66.0;

  final _passwordController = TextEditingController();
  bool _isSubmitting = false;
  _AccountRemoveSubmitPhase? _submitPhase;
  String? _passwordError;
  String? _submitError;

  bool get _canSubmit =>
      !_isSubmitting &&
      !widget.checkingPrivateUsd &&
      _removalBlockMessage == null &&
      isWalletPasswordValid(_passwordController.text);

  /// Bridges under way, or a count that could not be read (not while it is
  /// still being read).
  bool get _warnsOfBridges =>
      !widget.checkingPrivateUsd && widget.privateUsdUnfinishedCount != 0;

  String? get _passwordMessage {
    if (_passwordError != null) return _passwordError;
    return validateWalletPassword(context.l10n, _passwordController.text);
  }

  String? get _removalBlockMessage {
    if (widget.checkingPendingSwaps) {
      return context.l10n.accountsRemoveCheckingSwaps;
    }
    if (widget.pendingSwapCheckFailed) {
      return context.l10n.accountsRemoveSwapsCheckFailed;
    }
    if (widget.pendingSwapCount > 0) {
      return context.l10n.accountsRemoveBlockedBySwaps(widget.pendingSwapCount);
    }
    if (widget.checkingReceivingGiftCards) {
      return context.l10n.accountsRemoveCheckingGiftCards;
    }
    if (widget.receivingGiftCardCheckFailed) {
      return context.l10n.accountsRemoveGiftCardsCheckFailed;
    }
    if (widget.receivingGiftCardCount <= 0) return null;
    return context.l10n.accountsRemoveBlockedByGiftCards(
      widget.receivingGiftCardCount,
    );
  }

  @override
  void dispose() {
    _passwordController.clear();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    if (_removalBlockMessage != null || widget.checkingPrivateUsd) return;
    final passwordError = validateRequiredWalletPassword(
      context.l10n,
      _passwordController.text,
    );
    if (passwordError != null) {
      setState(() {
        _passwordError = passwordError;
        _submitError = null;
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _submitPhase = _AccountRemoveSubmitPhase.checkingPassword;
      _passwordError = null;
      _submitError = null;
    });

    bool isPasswordValid;
    try {
      isPasswordValid = await widget.onConfirmPassword(
        _passwordController.text,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _passwordError = context.l10n.passwordCheckFailed;
        _isSubmitting = false;
        _submitPhase = null;
      });
      return;
    }

    if (!mounted) return;
    if (!isPasswordValid) {
      setState(() {
        _passwordError = context.l10n.passwordIncorrect;
        _isSubmitting = false;
        _submitPhase = null;
      });
      return;
    }

    setState(() {
      _passwordController.clear();
      _submitPhase = _AccountRemoveSubmitPhase.stoppingSync;
    });

    try {
      await widget.onRemove(_setProgress);
    } on UnsharedGiftCardsChangedException catch (error) {
      if (!mounted) return;
      setState(
        () => _submitError = error.count == null
            ? context.l10n.accountsRemoveGiftCardsRecheckFailed
            : context.l10n.accountsRemoveGiftCardsMoreFunded,
      );
    } on PrivateUsdUnfinishedConversionsException catch (error) {
      // More bridges than the user was warned about, or a recheck that
      // failed: nothing was deleted, and the warning above shows the fresh
      // count to confirm again.
      if (!mounted) return;
      setState(
        () => _submitError = error.count == null
            ? context.l10n.privateUsdRemoveRecheckFailed
            : context.l10n.privateUsdRemoveMoreUnfinished,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitError = widget.isLastAccount
            ? context.l10n.accountsResetFailed
            : context.l10n.accountsRemoveFailed;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _submitPhase = null;
        });
      }
    }
  }

  void _handlePasswordChanged() {
    setState(() {
      _passwordError = null;
      _submitError = null;
    });
  }

  void _setProgress(AccountRemoveProgress progress) {
    if (!mounted) return;
    final next = switch (progress) {
      AccountRemoveProgress.stoppingSync =>
        _AccountRemoveSubmitPhase.stoppingSync,
      AccountRemoveProgress.removingAccount =>
        _AccountRemoveSubmitPhase.removingAccount,
    };
    if (_submitPhase == next) return;
    setState(() {
      _submitPhase = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final passwordMessage = _passwordMessage;
    final removalBlockMessage = _removalBlockMessage;
    final unsharedGiftCardWarning = unsharedGiftCardRemovalWarning(
      context.l10n,
      widget.unsharedGiftCardCount,
      walletReset: widget.isLastAccount,
    );
    final privateUsdCount = widget.privateUsdUnfinishedCount;

    return AccountModalCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AccountRemoveModalHeader(
            accountName: widget.accountName,
            profilePictureId: widget.profilePictureId,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            _bodyText,
            textAlign: TextAlign.left,
            style: AppTypography.bodyMedium.copyWith(
              color: context.colors.text.accent,
            ),
          ),
          if (removalBlockMessage != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _AccountRemoveWarningPanel(
              key: const ValueKey('account_remove_pending_swap_warning'),
              message: removalBlockMessage,
            ),
          ],
          if (unsharedGiftCardWarning != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _AccountRemoveWarningPanel(
              key: const ValueKey('account_remove_unshared_gift_card_warning'),
              message: unsharedGiftCardWarning,
            ),
          ],
          // Shielded USD bridges under way: their funds can only be recovered
          // by this account (or, for the last one, this wallet). Warn, then
          // allow, as the phone's removal sheet does.
          if (_warnsOfBridges) ...[
            const SizedBox(height: AppSpacing.sm),
            _AccountRemoveWarningPanel(
              key: const ValueKey('account_remove_private_usd_warning'),
              title: privateUsdCount == null
                  ? null
                  : context.l10n.privateUsdDeleteUnfinishedTitle,
              message: privateUsdCount == null
                  ? (widget.isLastAccount
                        ? context.l10n.privateUsdResetUncheckedBody
                        : context.l10n.privateUsdDeleteUncheckedBody)
                  : (widget.isLastAccount
                        ? context.l10n.privateUsdResetUnfinishedBody(
                            privateUsdCount,
                          )
                        : context.l10n.privateUsdDeleteUnfinishedBody(
                            privateUsdCount,
                          )),
            ),
          ],
          // Leave clearance above the label row for the Caps Lock warning.
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: _fieldHeight,
            child: AppPasswordInput(
              child: PasswordTextField(
                label: context.l10n.passwordLabel,
                hintText: context.l10n.accountsRemovePasswordHint,
                leadingSlotWidth: 32,
                trailingSlotWidth: 40,
                inputHorizontalPadding: AppSpacing.s,
                controller: _passwordController,
                autofocus: true,
                enabled: !_isSubmitting && removalBlockMessage == null,
                tone: passwordMessage == null
                    ? AppTextFieldTone.neutral
                    : AppTextFieldTone.destructive,
                onChanged: (_) => _handlePasswordChanged(),
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
          if (passwordMessage != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              passwordMessage,
              style: AppTypography.labelMedium.copyWith(
                color: context.colors.text.destructive,
              ),
            ),
          ],
          if (_submitError != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _submitError!,
              textAlign: TextAlign.center,
              style: AppTypography.bodyMedium.copyWith(
                color: context.colors.text.destructive,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          AccountModalActions(
            onCancel: _isSubmitting ? null : widget.onCancel,
            actionLabel: _submitButtonLabel,
            onAction: _canSubmit ? _submit : null,
            actionVariant: AppButtonVariant.destructive,
            actionLeading: _isSubmitting || widget.isLastAccount
                ? null
                : const AppIcon(AppIcons.trash, size: AppIconSize.medium),
          ),
        ],
      ),
    );
  }

  String get _bodyText {
    if (widget.isLastAccount) {
      return context.l10n.accountsResetModalBody;
    }
    return context.l10n.accountsRemoveModalBody;
  }

  String get _submitButtonLabel {
    if (!_isSubmitting) {
      return switch ((widget.isLastAccount, _warnsOfBridges)) {
        (true, true) => context.l10n.privateUsdResetAnyway,
        (true, false) => context.l10n.commonResetVizor,
        (false, true) => context.l10n.privateUsdDeleteAnyway,
        (false, false) => context.l10n.commonRemove,
      };
    }

    return switch (_submitPhase) {
      _AccountRemoveSubmitPhase.checkingPassword =>
        context.l10n.accountsRemoveCheckingPassword,
      _AccountRemoveSubmitPhase.stoppingSync =>
        context.l10n.accountsRemoveStoppingSync,
      _AccountRemoveSubmitPhase.removingAccount =>
        widget.isLastAccount
            ? context.l10n.accountsResetting
            : context.l10n.accountsRemoving,
      null =>
        widget.isLastAccount
            ? context.l10n.accountsResetting
            : context.l10n.accountsRemoving,
    };
  }
}

class _AccountRemoveWarningPanel extends StatelessWidget {
  const _AccountRemoveWarningPanel({
    required this.message,
    this.title,
    super.key,
  });

  final String message;

  /// Over the message, for a warning that names what is at stake.
  final String? title;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // A neon glass panel, its cut corners lit.
    return NeonGlassPanel(
      cut: AppChamfer.medium,
      fill: colors.background.raised,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(
            AppIcons.warning,
            size: AppIconSize.medium,
            color: colors.icon.warning,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title case final title?) ...[
                  Text(
                    title,
                    style: AppTypography.labelMedium.copyWith(
                      color: colors.text.warning,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                ],
                Text(
                  message,
                  style: AppTypography.bodySmall.copyWith(
                    color: colors.text.warning,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _AccountRemoveSubmitPhase {
  checkingPassword,
  stoppingSync,
  removingAccount,
}

class _AccountRemoveModalHeader extends StatelessWidget {
  const _AccountRemoveModalHeader({
    required this.accountName,
    required this.profilePictureId,
  });

  final String accountName;
  final String profilePictureId;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AppProfilePicture(
          profilePictureId: profilePictureId,
          size: AppProfilePictureSize.large,
        ),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            accountName,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.bodyLarge.copyWith(
              color: context.colors.text.accent,
              fontWeight: AppFontWeight.medium,
            ),
          ),
        ),
      ],
    );
  }
}
