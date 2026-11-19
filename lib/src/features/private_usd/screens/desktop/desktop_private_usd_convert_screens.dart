import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/formatting/countdown_format.dart';
import '../../../../core/formatting/date_format.dart';
import '../../../../core/formatting/zec_amount.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/app_loading_icon.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/block_spacing_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../providers/sync_provider.dart';
import '../../../../providers/zec_price_change_provider.dart'
    show fiatTextForZatoshi, zecHomeUsdUnitPriceProvider;
import '../../../swap/domain/swap_asset.dart';
import '../../../swap/widgets/mobile/mobile_swap_review_header.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_record_key.dart';
import '../../models/private_usd_reverse_presentation.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_convert_provider.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_least_fee_provider.dart';
import '../../providers/private_usd_relayer_claims_provider.dart';
import '../../providers/private_usd_reverse_convert_provider.dart';
import '../../providers/private_usd_tokens_provider.dart';
import '../../widgets/desktop/desktop_private_usd_bridge_widgets.dart';
import '../../widgets/desktop/desktop_private_usd_widgets.dart';
import '../../widgets/mobile/private_usd_convert_views.dart'
    show privateUsdReviewNote;
import '../../widgets/mobile/private_usd_convert_widgets.dart';
import '../../widgets/mobile/private_usd_flow_widgets.dart'
    show kPrivateUsdRailgunFeePercent;
import '../../widgets/mobile/private_usd_logo.dart';

String _masked(String text, bool privacyModeEnabled) => hideAmountIfPrivacyMode(
  text,
  privacyModeEnabled: privacyModeEnabled,
  denomination: '',
);

String _zec(BigInt zatoshi) =>
    ZecAmount.fromZatoshi(zatoshi).activity.toString();

// What [zatoshi] is worth at [zecUsdPrice], for its panel: none without a
// price or an amount, or in privacy mode.
String? _marketValue(
  BigInt? zatoshi,
  double? zecUsdPrice,
  bool privacyModeEnabled,
) => privacyModeEnabled || zatoshi == null
    ? null
    : fiatTextForZatoshi(zatoshi, zecUsdUnitPrice: zecUsdPrice);

/// `/private-usd/convert` on desktop: ZEC → shielded USD, or shielded USD →
/// ZEC with `?to=zec` or the direction switch between the two panels. The
/// phone's flows and their rules ([privateUsdConvertProvider],
/// [privateUsdReverseConvertProvider]): a quote is asked for only once typing
/// stops, for Max once the balance is Rust's, or to replace one that ran out,
/// never per keystroke or on opening, since every quote spends a swap index. A
/// bridge found under way shows instead, one at a time per account.
class DesktopPrivateUsdConvertScreen extends ConsumerStatefulWidget {
  const DesktopPrivateUsdConvertScreen({
    this.initialDirection = PrivateUsdDirection.forward,
    super.key,
  });

  final PrivateUsdDirection initialDirection;

  @override
  ConsumerState<DesktopPrivateUsdConvertScreen> createState() =>
      _DesktopPrivateUsdConvertScreenState();
}

class _DesktopPrivateUsdConvertScreenState
    extends ConsumerState<DesktopPrivateUsdConvertScreen> {
  final _amount = TextEditingController();
  final _focus = FocusNode();
  late var _direction = widget.initialDirection;

  bool get _reverse => _direction == PrivateUsdDirection.reverse;

  @override
  void initState() {
    super.initState();
    // Opened while a bridge is under way, or after the app died mid-accept:
    // its progress shows instead.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final account = ref.read(accountProvider).value?.activeAccountUuid;
      final underWay = account == null
          ? null
          : ref.read(privateUsdUnderWayProvider(account));
      if (underWay != null) {
        _showProgress(underWay.path);
        return;
      }
      unawaited(
        _reverse
            ? ref.read(privateUsdReverseConvertProvider.notifier).findUnderWay()
            : ref.read(privateUsdConvertProvider.notifier).findUnderWay(),
      );
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The other direction starts empty.
  void _switchDirection() {
    setState(() {
      _direction = _reverse
          ? PrivateUsdDirection.forward
          : PrivateUsdDirection.reverse;
      _amount.clear();
    });
    _focus.requestFocus();
  }

  void _syncAmount(String text) {
    if (_amount.text != text) {
      _amount.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  void _showProgress(PrivateUsdRoutePath path) {
    if (!mounted) return;
    context.pushReplacement(path.location);
  }

  /// Opens the review. Once a bridge is accepted, its progress replaces the
  /// convert screen, so back from it lands on `/private-usd`.
  Future<void> _review<S extends PrivateUsdConvertFlowState<S>>(
    PrivateUsdConvertFlowNotifier<S> notifier,
  ) async {
    if (!notifier.openReview()) return;
    FocusScope.of(context).unfocus();
    final shown = await context.push<PrivateUsdRoutePath>(
      '/private-usd/convert/review',
      extra: _direction,
    );
    if (!mounted) return;
    if (shown != null) {
      _showProgress(shown);
      return;
    }
    notifier.leaveReview();
  }

  VoidCallback? _directionSwitch<S extends PrivateUsdConvertFlowState<S>>(
    S state,
  ) => state.step == PrivateUsdConvertStep.amount && !state.quoting
      ? _switchDirection
      : null;

  @override
  Widget build(BuildContext context) {
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    final zecUsdPrice = ref.watch(zecHomeUsdUnitPriceProvider);
    final l10n = context.l10n;
    if (_reverse) {
      ref.listen(privateUsdReverseConvertProvider.select((s) => s.underWay), (
        _,
        path,
      ) {
        if (path != null) _showProgress(path);
      });
      // Max rewrites the amount.
      ref.listen(
        privateUsdReverseConvertProvider.select((s) => s.amountText),
        (_, text) => _syncAmount(text),
      );
      final state = ref.watch(privateUsdReverseConvertProvider);
      // The balance the amount is checked against stays fresh meanwhile.
      if (uuid != null) {
        ref.watch(
          privateUsdBalanceKeepFreshProvider((
            accountUuid: uuid,
            ifUsed: false,
          )),
        );
      }
      final notifier = ref.read(privateUsdReverseConvertProvider.notifier);
      final sweepFeeFloorZat = ref.watch(privateUsdLeastFeeZatProvider);
      final draft = state.draft;
      final priced = draft != null && state.debit != null && !state.quoting;
      final available = state.available;
      final received = priced
          ? privateUsdReverseReceivedZat(
              draft,
              sweepFeeFloorZat: sweepFeeFloorZat,
            )
          : null;
      return _DesktopConvertLayout(
        onInfo: () => unawaited(showDesktopPrivateUsdReverseInfo(context)),
        pay: PrivateUsdAmountPanel(
          key: const ValueKey('desktop_private_usd_convert_usd'),
          keyPrefix: 'desktop_private_usd_convert',
          caption: const PrivateUsdPanelCaption.privateUsd(),
          controller: _amount,
          focusNode: _focus,
          readOnly: state.step != PrivateUsdConvertStep.amount,
          // Whole cents only: Rust refuses anything finer.
          maxFractionDigits: 2,
          invalid: state.isAmountInvalid || state.isTooPrecise,
          available: available == null
              ? PrivateUsdCopy.unknown
              : _masked(formatPrivateUsd(available), privacyModeEnabled),
          onMax: state.canMax ? notifier.onMax : null,
          onChanged: notifier.onAmountChanged,
        ),
        receive: PrivateUsdEstimatePanel(
          caption: const PrivateUsdPanelCaption.zec(),
          quoting: state.quoting,
          estimate: received == null
              ? null
              : _masked(_zec(received), privacyModeEnabled),
          marketValue: _marketValue(received, zecUsdPrice, privacyModeEnabled),
        ),
        onSwitchDirection: _directionSwitch(state),
        quoting: state.quoting,
        ledger: priced
            ? PrivateUsdReverseLedger(
                record: draft,
                privacyModeEnabled: privacyModeEnabled,
                sweepFeeFloorZat: sweepFeeFloorZat,
              )
            : null,
        expired: state.isExpired,
        expiresIn: state.expiresIn,
        message: state.message(l10n),
        canReview: state.canReview,
        onReview: () => unawaited(_review(notifier)),
        extra: [
          if (state.showsRefunds)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppButton(
                key: const ValueKey('desktop_private_usd_convert_refunds'),
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.small,
                onPressed: () => context.push('/private-usd/refunds'),
                child: Text(l10n.privateUsdRefundsView),
              ),
            ),
        ],
      );
    }
    ref.listen(privateUsdConvertProvider.select((s) => s.underWay), (_, path) {
      if (path != null) _showProgress(path);
    });
    // A quote can rewrite the amount: Max, then what that pays for.
    ref.listen(
      privateUsdConvertProvider.select((s) => s.amountText),
      (_, text) => _syncAmount(text),
    );
    final state = ref.watch(privateUsdConvertProvider);
    final balance = uuid == null
        ? null
        : ref.watch(privateUsdBalanceProvider(uuid)).balances;
    final notifier = ref.read(privateUsdConvertProvider.notifier);
    final relayerClaims =
        ref.watch(privateUsdRelayerClaimsProvider).value ?? true;
    final blockTimes = ref
        .watch(blockSpacingProvider)
        .fromTip(
          ref.watch(
            syncProvider.select((sync) => sync.value?.chainTipHeight ?? 0),
          ),
        );
    final quote = state.quote;
    final quoted = quote != null && !state.quoting;
    final spendable = state.holdings.spendable;
    final syncPercent = state.holdings.syncPercent;
    final privateUsdAvailable = balance?.spendable;
    return _DesktopConvertLayout(
      onInfo: () => unawaited(
        showDesktopPrivateUsdConvertInfo(
          context,
          takes: desktopPrivateUsdForwardTakes(blockTimes),
          relayerClaims: relayerClaims,
        ),
      ),
      pay: PrivateUsdAmountPanel(
        key: const ValueKey('desktop_private_usd_convert_zec'),
        keyPrefix: 'desktop_private_usd_convert',
        caption: const PrivateUsdPanelCaption.zec(),
        controller: _amount,
        focusNode: _focus,
        readOnly: state.step != PrivateUsdConvertStep.amount,
        maxFractionDigits: 8,
        invalid: state.isAmountInvalid,
        note: l10n.privateUsdConvertZecIncludesFee,
        marketValue: _marketValue(
          state.totalZat,
          zecUsdPrice,
          privacyModeEnabled,
        ),
        available: spendable == null
            ? PrivateUsdCopy.unknown
            : _masked(_zec(spendable), privacyModeEnabled),
        onMax: state.canMax ? notifier.onMax : null,
        onChanged: notifier.onAmountChanged,
        footer: state.holdings.catchingUp
            ? Text(
                syncPercent == null
                    ? l10n.privateUsdConvertZecSyncing
                    : l10n.privateUsdConvertZecSyncingProgress(syncPercent),
                key: const ValueKey('desktop_private_usd_convert_syncing'),
                style: AppTypography.bodySmall.copyWith(
                  color: context.colors.text.secondary,
                ),
              )
            : null,
      ),
      receive: PrivateUsdEstimatePanel(
        caption: const PrivateUsdPanelCaption.privateUsd(),
        quoting: state.quoting,
        estimate: quoted
            ? _masked(formatPrivateUsd(quote.receives), privacyModeEnabled)
            : null,
        available: privateUsdAvailable == null
            ? null
            : _masked(
                formatPrivateUsd(privateUsdAvailable),
                privacyModeEnabled,
              ),
      ),
      onSwitchDirection: _directionSwitch(state),
      quoting: state.quoting,
      ledger: quoted
          ? PrivateUsdQuoteLedger(
              quote: quote,
              privacyModeEnabled: privacyModeEnabled,
              showsTotal: true,
            )
          : null,
      expired: state.isExpired,
      expiresIn: state.expiresIn,
      message: state.message(l10n),
      canReview: state.canReview,
      onReview: () => unawaited(_review(notifier)),
    );
  }
}

/// What both amount steps lay out on desktop: the paying panel, the
/// direction switch, the estimate, the priced quote's [ledger] and countdown,
/// a message, then Review pinned at the foot of the pane, as the phone pins
/// it under its screen.
class _DesktopConvertLayout extends StatelessWidget {
  const _DesktopConvertLayout({
    required this.onInfo,
    required this.pay,
    required this.receive,
    required this.onSwitchDirection,
    required this.quoting,
    required this.ledger,
    required this.expired,
    required this.expiresIn,
    required this.message,
    required this.canReview,
    required this.onReview,
    this.extra = const [],
  });

  final VoidCallback onInfo;
  final Widget pay;
  final Widget receive;
  final VoidCallback? onSwitchDirection;

  /// A quote, or the most that can be bridged, is being worked out.
  final bool quoting;
  final Widget? ledger;
  final bool expired;
  final Duration expiresIn;
  final String? message;
  final bool canReview;
  final VoidCallback onReview;

  /// Under the message.
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    final ledger = this.ledger;
    final message = this.message;
    return DesktopPrivateUsdPage(
      title: context.l10n.privateUsdActionConvert,
      contentKey: const ValueKey('desktop_private_usd_convert_content'),
      onInfo: onInfo,
      action: AppButton(
        key: const ValueKey('desktop_private_usd_convert_review'),
        expand: true,
        onPressed: canReview ? onReview : null,
        leading: quoting
            ? const AppLoadingIcon(size: AppIconSize.medium)
            : null,
        child: Text(
          quoting
              ? context.l10n.privateUsdConvertQuoteLoading
              : context.l10n.privateUsdReview,
        ),
      ),
      children: [
        pay,
        PrivateUsdDirectionToggle(
          onTap: onSwitchDirection,
          busy: quoting,
          desktopInput: true,
        ),
        receive,
        if (ledger != null) ...[
          const SizedBox(height: AppSpacing.s),
          ledger,
          const SizedBox(height: AppSpacing.xs),
          PrivateUsdQuoteExpiry(
            expired: expired,
            label: context.l10n.privateUsdConvertQuoteExpires(
              formatMinutesSeconds(expiresIn),
            ),
          ),
        ],
        if (message != null) ...[
          const SizedBox(height: AppSpacing.s),
          DesktopPrivateUsdNotice(
            key: const ValueKey('desktop_private_usd_convert_message'),
            message: message,
          ),
        ],
        for (final widget in extra) ...[
          const SizedBox(height: AppSpacing.s),
          widget,
        ],
      ],
    );
  }
}

/// `/private-usd/convert/review` on desktop (`extra`: the direction): the
/// reviewed quote, how long it holds, how long to keep Veylor open, and the
/// button that bridges, pinned at the foot of the pane. It pops with the
/// bridge's route once accepted, or found under way after an accept that may
/// have opened it, and the convert screen replaces itself with that progress.
/// While it accepts, back is held and the sidebar veiled.
class DesktopPrivateUsdConvertReviewScreen extends ConsumerWidget {
  const DesktopPrivateUsdConvertReviewScreen({
    required this.direction,
    super.key,
  });

  final PrivateUsdDirection direction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    final torOffDisclosure = ref.watch(
      privateUsdTokensTorOffDisclosureProvider,
    );
    final l10n = context.l10n;
    if (direction == PrivateUsdDirection.reverse) {
      final state = ref.watch(privateUsdReverseConvertProvider);
      final notifier = ref.read(privateUsdReverseConvertProvider.notifier);
      final sweepFeeFloorZat = ref.watch(privateUsdLeastFeeZatProvider);
      final draft = state.draft;
      return _DesktopReviewLayout(
        state: state,
        notifier: notifier,
        reviewable: draft != null,
        onInfo: () => unawaited(showDesktopPrivateUsdReverseInfo(context)),
        pay: draft == null
            ? null
            : MobileSwapReviewHeaderRow(
                label: l10n.privateUsdConvertYouPay,
                amountText: _masked(
                  formatPrivateUsdNearest(privateUsdReverseDebit(draft)),
                  privacyModeEnabled,
                ),
                asset: SwapAsset.usdc,
                icon: const PrivateUsdLogo(),
                bottomText: l10n.privateUsdTitle,
              ),
        receive: draft == null
            ? null
            : MobileSwapReviewHeaderRow(
                label: l10n.privateUsdConvertYouReceive,
                amountText: _masked(
                  _zec(
                    privateUsdReverseReceivedZat(
                      draft,
                      sweepFeeFloorZat: sweepFeeFloorZat,
                    ),
                  ),
                  privacyModeEnabled,
                ),
                asset: SwapAsset.zec,
                bottomText: l10n.privateUsdShieldedZec,
              ),
        ledger: draft == null
            ? null
            : PrivateUsdReverseLedger(
                record: draft,
                privacyModeEnabled: privacyModeEnabled,
                sweepFeeFloorZat: sweepFeeFloorZat,
              ),
        note: draft == null
            ? null
            : privateUsdReviewNote(
                l10n,
                l10n.privateUsdReverseKeepOpen(
                  formatDayMonthTime(privateUsdReadyBy(draft), l10n.localeName),
                ),
                torOffDisclosure: torOffDisclosure,
              ),
        message: state.message(l10n),
        onConfirm: () => unawaited(_confirm(context, notifier.confirm)),
        onRefreshQuote: notifier.refreshQuote,
      );
    }
    final state = ref.watch(privateUsdConvertProvider);
    final notifier = ref.read(privateUsdConvertProvider.notifier);
    final relayerClaims =
        ref.watch(privateUsdRelayerClaimsProvider).value ?? true;
    final quote = state.quote;
    return _DesktopReviewLayout(
      state: state,
      notifier: notifier,
      reviewable: quote != null,
      onInfo: () => unawaited(
        showDesktopPrivateUsdReviewInfo(
          context,
          railgunPercent: kPrivateUsdRailgunFeePercent,
          relayerClaims: relayerClaims,
        ),
      ),
      pay: quote == null
          ? null
          : MobileSwapReviewHeaderRow(
              label: l10n.privateUsdConvertYouPay,
              amountText: _masked(_zec(quote.totalZat), privacyModeEnabled),
              asset: SwapAsset.zec,
              bottomText: l10n.privateUsdConvertZecIncludesFee,
            ),
      receive: quote == null
          ? null
          : MobileSwapReviewHeaderRow(
              label: l10n.privateUsdConvertYouReceive,
              amountText: _masked(
                formatPrivateUsd(quote.receives),
                privacyModeEnabled,
              ),
              asset: SwapAsset.usdc,
              icon: const PrivateUsdLogo(),
              bottomText: l10n.privateUsdTitle,
            ),
      ledger: quote == null
          ? null
          : PrivateUsdQuoteLedger(
              quote: quote,
              privacyModeEnabled: privacyModeEnabled,
            ),
      note: privateUsdReviewNote(
        l10n,
        relayerClaims
            ? l10n.privateUsdConvertRelayerReviewNote
            : l10n.privateUsdConvertBackgroundNote,
        torOffDisclosure: torOffDisclosure,
      ),
      message: state.message(l10n),
      onConfirm: () => unawaited(_confirm(context, notifier.confirm)),
      onRefreshQuote: notifier.refreshQuote,
    );
  }

  Future<void> _confirm(
    BuildContext context,
    Future<PrivateUsdRoutePath?> Function() confirm,
  ) async {
    final path = await confirm();
    if (path != null && context.mounted) {
      context.pop<PrivateUsdRoutePath>(path);
    }
  }
}

/// What both reviews lay out: the header and [ledger] of the quote (none
/// without one), how long it holds, the [note], a message, and the button
/// that bridges, or refreshes the quote once it expired. Back leaves the
/// review, never while it accepts; reopened without its flow (a stale stack)
/// there is nothing to review, and back just pops.
class _DesktopReviewLayout<S extends PrivateUsdConvertFlowState<S>>
    extends StatelessWidget {
  const _DesktopReviewLayout({
    required this.state,
    required this.notifier,
    required this.reviewable,
    required this.onInfo,
    required this.pay,
    required this.receive,
    required this.ledger,
    required this.note,
    required this.message,
    required this.onConfirm,
    required this.onRefreshQuote,
  });

  final S state;
  final PrivateUsdConvertFlowNotifier<S> notifier;
  final bool reviewable;
  final VoidCallback onInfo;
  final MobileSwapReviewHeaderRow? pay;
  final MobileSwapReviewHeaderRow? receive;
  final Widget? ledger;
  final String? note;

  /// Why "Bridge" did not start, a refresh that did not come, or a quote that
  /// ran out.
  final String? message;
  final VoidCallback onConfirm;
  final VoidCallback onRefreshQuote;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final pay = this.pay;
    final receive = this.receive;
    final ledger = this.ledger;
    final note = this.note;
    final confirming = state.isConfirming;
    final expired = state.isExpired && !state.quoting;
    final message = this.message;
    final action = expired
        ? AppButton(
            key: const ValueKey('desktop_private_usd_review_refresh'),
            expand: true,
            onPressed: onRefreshQuote,
            leading: const AppIcon(AppIcons.renew),
            child: Text(l10n.privateUsdConvertNewQuote),
          )
        : AppButton(
            key: const ValueKey('desktop_private_usd_review_convert'),
            expand: true,
            onPressed: state.canConfirm ? onConfirm : null,
            leading: confirming || state.quoting
                ? const AppLoadingIcon(size: AppIconSize.medium)
                : null,
            child: Text(
              state.quoting
                  ? l10n.privateUsdConvertQuoteLoading
                  : l10n.privateUsdActionConvert,
            ),
          );
    return PopScope<Object?>(
      canPop: !confirming,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && reviewable) notifier.leaveReview();
      },
      child: DesktopPrivateUsdPage(
        title: l10n.privateUsdReview,
        contentKey: const ValueKey('desktop_private_usd_review_content'),
        canGoBack: !confirming,
        onInfo: onInfo,
        action: action,
        children: [
          if (pay != null && receive != null && ledger != null) ...[
            MobileSwapReviewHeader(pay: pay, receive: receive),
            ledger,
            const SizedBox(height: AppSpacing.xs),
            PrivateUsdQuoteExpiry(
              expired: expired,
              label: l10n.privateUsdConvertQuoteHolds(
                formatMinutesSeconds(state.expiresIn),
              ),
            ),
          ],
          if (note != null) ...[
            const SizedBox(height: AppSpacing.s),
            Text(
              note,
              key: const ValueKey('desktop_private_usd_review_keep_open'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
          if (message != null) ...[
            const SizedBox(height: AppSpacing.s),
            DesktopPrivateUsdNotice(
              key: const ValueKey('desktop_private_usd_review_message'),
              message: message,
            ),
          ],
        ],
      ),
    );
  }
}
