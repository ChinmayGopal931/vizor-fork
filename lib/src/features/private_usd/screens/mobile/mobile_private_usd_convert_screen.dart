import 'dart:async';

import 'package:flutter/material.dart'
    show InputDecoration, Scaffold, TextField;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/formatting/zec_amount.dart';
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
import '../../../../core/widgets/mobile/neon_scramble_text.dart';
import '../../../../core/widgets/mobile/tron_glyph.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_record_key.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_available_provider.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../providers/private_usd_convert_provider.dart';
import '../../providers/private_usd_engine_provider.dart';
import '../../providers/private_usd_reverse_convert_provider.dart';
import '../../services/private_usd_zec_quote_search.dart';
import '../../widgets/mobile/private_usd_info_sheets.dart';
import 'mobile_private_usd_reverse_convert_view.dart';

/// Railgun's fee for shielding the payout, as the quote ledger says it.
const kPrivateUsdRailgunFeePercent = '0.25';

/// How long a forward conversion usually takes, for the info sheet.
const kPrivateUsdForwardTakes = Duration(minutes: 10);

/// What `/private-usd/convert/review` carries: the quote being reviewed.
/// The review reads the convert flow's state; this only proves the route was
/// opened from it.
class PrivateUsdReviewArgs {
  const PrivateUsdReviewArgs({
    required this.index,
    this.direction = PrivateUsdDirection.forward,
  });

  final int index;
  final PrivateUsdDirection direction;
}

/// `/private-usd/convert` (plan reference §9.4 S3, S4): ZEC → private USD
/// (the total ZEC to spend, its quote, and "Review"), or private USD → ZEC
/// with `?to=zec` or the direction toggle. A conversion found under way
/// shows instead.
class MobilePrivateUsdConvertScreen extends ConsumerStatefulWidget {
  const MobilePrivateUsdConvertScreen({
    this.initialDirection = PrivateUsdDirection.forward,
    super.key,
  });

  final PrivateUsdDirection initialDirection;

  @override
  ConsumerState<MobilePrivateUsdConvertScreen> createState() =>
      _MobilePrivateUsdConvertScreenState();
}

class _MobilePrivateUsdConvertScreenState
    extends ConsumerState<MobilePrivateUsdConvertScreen> {
  final _amount = TextEditingController();
  final _focus = FocusNode();
  late var _direction = widget.initialDirection;

  bool get _reverse => _direction == PrivateUsdDirection.reverse;

  @override
  void initState() {
    super.initState();
    // Opened while a conversion is under way, or after the app died
    // mid-accept: its progress shows instead.
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

  /// The direction toggle: the other flow starts empty.
  void _switchDirection() {
    setState(() {
      _direction = _reverse
          ? PrivateUsdDirection.forward
          : PrivateUsdDirection.reverse;
      _amount.clear();
    });
  }

  void _syncAmount(String text) {
    if (_amount.text != text) {
      _amount.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  Future<void> _reviewReverse() async {
    final notifier = ref.read(privateUsdReverseConvertProvider.notifier);
    if (!notifier.openReview()) return;
    final draft = ref.read(privateUsdReverseConvertProvider).draft!;
    final shown = await context.push<PrivateUsdRoutePath>(
      '/private-usd/convert/review',
      extra: PrivateUsdReviewArgs(
        index: draft.index,
        direction: PrivateUsdDirection.reverse,
      ),
    );
    if (!mounted) return;
    if (shown != null) {
      _showProgress(shown);
      return;
    }
    notifier.leaveReview();
  }

  Widget _buildReverse(BuildContext context) {
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
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    // The balance the amount is checked against stays fresh meanwhile.
    if (uuid != null) {
      ref.watch(
        privateUsdBalanceKeepFreshProvider((accountUuid: uuid, ifUsed: false)),
      );
    }
    final notifier = ref.read(privateUsdReverseConvertProvider.notifier);
    return MobilePrivateUsdReverseConvertView(
      state: state,
      controller: _amount,
      focusNode: _focus,
      privacyModeEnabled: ref.watch(privacyModeProvider),
      onAmountChanged: notifier.onAmountChanged,
      onMax: () => unawaited(notifier.onMax()),
      onReview: _reviewReverse,
      onBack: () => context.pop(),
      onSwitchDirection:
          state.step == PrivateUsdConvertStep.amount && !state.quoting
          ? _switchDirection
          : null,
      onViewRefunds: () => context.push('/private-usd/refunds'),
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _showProgress(PrivateUsdRoutePath path) {
    if (!mounted) return;
    context.pushReplacement(path.location);
  }

  Future<void> _review() async {
    final notifier = ref.read(privateUsdConvertProvider.notifier);
    if (!notifier.openReview()) return;
    final quote = ref.read(privateUsdConvertProvider).quote!;
    final shown = await context.push<PrivateUsdRoutePath>(
      '/private-usd/convert/review',
      extra: PrivateUsdReviewArgs(index: quote.index),
    );
    if (!mounted) return;
    if (shown != null) {
      // Accepted: progress replaces the convert flow, so back from it lands
      // on /private-usd.
      _showProgress(shown);
      return;
    }
    notifier.leaveReview();
  }

  @override
  Widget build(BuildContext context) {
    if (_reverse) return _buildReverse(context);
    ref.listen(privateUsdConvertProvider.select((s) => s.underWay), (_, path) {
      if (path != null) _showProgress(path);
    });
    // A quote can rewrite the amount ("Use it all", then what it pays for).
    ref.listen(
      privateUsdConvertProvider.select((s) => s.amountText),
      (_, text) => _syncAmount(text),
    );
    final state = ref.watch(privateUsdConvertProvider);
    final uuid = ref.watch(
      accountProvider.select((s) => s.value?.activeAccountUuid),
    );
    final balance = uuid == null
        ? null
        : ref.watch(privateUsdBalanceProvider(uuid)).balances;
    final deployment = ref.watch(privateUsdCurrentDeploymentProvider);
    final notifier = ref.read(privateUsdConvertProvider.notifier);
    return MobilePrivateUsdConvertView(
      state: state,
      controller: _amount,
      focusNode: _focus,
      privacyModeEnabled: ref.watch(privacyModeProvider),
      privateUsdAvailable: balance?.spendable,
      maxRelayerFee: BigInt.tryParse(deployment?.maxRelayerFee ?? ''),
      onAmountChanged: notifier.onAmountChanged,
      onMax: notifier.onMax,
      onReview: _review,
      onBack: () => context.pop(),
      onSwitchDirection:
          state.step == PrivateUsdConvertStep.amount && !state.quoting
          ? _switchDirection
          : null,
    );
  }
}

/// The convert screen's content for a given state. Widgetbook, capture
/// scenarios and tests build it directly.
class MobilePrivateUsdConvertView extends StatelessWidget {
  const MobilePrivateUsdConvertView({
    required this.state,
    required this.controller,
    required this.onAmountChanged,
    required this.onMax,
    required this.onReview,
    required this.onBack,
    this.focusNode,
    this.privacyModeEnabled = false,
    this.privateUsdAvailable,
    this.maxRelayerFee,
    this.autofocus = true,
    this.onSwitchDirection,
    super.key,
  });

  final PrivateUsdConvertState state;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool privacyModeEnabled;

  /// The private USD that can be spent, in micro-dollars; null while unknown.
  final BigInt? privateUsdAvailable;
  final BigInt? maxRelayerFee;
  final bool autofocus;
  final ValueChanged<String> onAmountChanged;
  final VoidCallback onMax;
  final VoidCallback onReview;
  final VoidCallback onBack;

  /// The direction toggle (private USD → ZEC); null hides it.
  final VoidCallback? onSwitchDirection;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final message = state.message;
    return Scaffold(
      backgroundColor: colors.background.window,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileTopNav.back(
              title: PrivateUsdCopy.convertTitle,
              onBack: onBack,
              trailing: PrivateUsdInfoButton(
                onTap: () => showPrivateUsdConvertInfoSheet(
                  context,
                  takes: kPrivateUsdForwardTakes,
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('mobile_private_usd_convert_scroll'),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ZecCard(
                      state: state,
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: autofocus,
                      privacyModeEnabled: privacyModeEnabled,
                      onAmountChanged: onAmountChanged,
                      onMax: onMax,
                    ),
                    PrivateUsdDirectionToggle(
                      onTap: onSwitchDirection,
                      busy: state.quoting,
                    ),
                    _EstimateCard(
                      state: state,
                      privacyModeEnabled: privacyModeEnabled,
                      privateUsdAvailable: privateUsdAvailable,
                    ),
                    if (state.quote case final quote? when !state.quoting) ...[
                      const SizedBox(height: AppSpacing.s),
                      PrivateUsdQuoteLedger(
                        quote: quote,
                        privacyModeEnabled: privacyModeEnabled,
                        showsTotal: true,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      PrivateUsdQuoteExpiry(
                        expired: state.isExpired,
                        label: PrivateUsdCopy.convertQuoteExpires(
                          formatMinutesSeconds(state.expiresIn),
                        ),
                      ),
                    ],
                    if (message != null) ...[
                      const SizedBox(height: AppSpacing.s),
                      MobileWarningNotice(
                        key: const ValueKey(
                          'mobile_private_usd_convert_message',
                        ),
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
                key: const ValueKey('mobile_private_usd_convert_review'),
                expand: true,
                onPressed: state.canReview ? onReview : null,
                leading: state.quoting
                    ? const AppLoadingIcon(size: AppIconSize.medium)
                    : null,
                child: Text(
                  state.quoting
                      ? PrivateUsdCopy.convertQuoteLoading
                      : PrivateUsdCopy.review,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZecCard extends StatelessWidget {
  const _ZecCard({
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.autofocus,
    required this.privacyModeEnabled,
    required this.onAmountChanged,
    required this.onMax,
  });

  final PrivateUsdConvertState state;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool privacyModeEnabled;
  final ValueChanged<String> onAmountChanged;
  final VoidCallback onMax;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final amountStyle = AppTypography.displayLarge.copyWith(
      color: state.isAmountInvalid
          ? colors.text.destructive
          : colors.text.accent,
    );
    final spendable = state.holdings.spendable;
    final available = spendable == null
        ? PrivateUsdCopy.unknown
        : hideAmountIfPrivacyMode(
            ZecAmount.fromZatoshi(spendable).activity.toString(),
            privacyModeEnabled: privacyModeEnabled,
            denomination: '',
          );
    final syncPercent = state.holdings.syncPercent;
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_convert_zec'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PrivateUsdPanelCaption(PrivateUsdCopy.convertAssetZec),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            key: const ValueKey('mobile_private_usd_convert_amount'),
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            readOnly: state.step != PrivateUsdConvertStep.amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              const CommaToDotInputFormatter(),
              DecimalAmountInputFormatter(maxFractionDigits: 8),
            ],
            onChanged: onAmountChanged,
            style: amountStyle,
            cursorColor: colors.neon.glow,
            decoration: InputDecoration.collapsed(
              hintText: '0',
              hintStyle: amountStyle.copyWith(color: colors.text.muted),
            ),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            PrivateUsdCopy.convertZecIncludesFee,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${PrivateUsdCopy.rowAvailable}: $available',
                  key: const ValueKey('mobile_private_usd_convert_available'),
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
                  key: const ValueKey('mobile_private_usd_convert_max'),
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.small,
                  onPressed: state.canMax ? onMax : null,
                  child: const Text(PrivateUsdCopy.max),
                ),
              ),
            ],
          ),
          if (state.holdings.catchingUp) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              syncPercent == null
                  ? PrivateUsdCopy.convertZecSyncing
                  : PrivateUsdCopy.convertZecSyncingProgress(syncPercent),
              key: const ValueKey('mobile_private_usd_convert_syncing'),
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EstimateCard extends StatelessWidget {
  const _EstimateCard({
    required this.state,
    required this.privacyModeEnabled,
    required this.privateUsdAvailable,
  });

  final PrivateUsdConvertState state;
  final bool privacyModeEnabled;
  final BigInt? privateUsdAvailable;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final quote = state.quote;
    final estimate = state.quoting || quote == null
        ? PrivateUsdCopy.unknown
        : hideAmountIfPrivacyMode(
            formatPrivateUsd(quote.receives),
            privacyModeEnabled: privacyModeEnabled,
            denomination: '',
          );
    final available = privateUsdAvailable;
    final quoted = quote != null && !state.quoting;
    final cipherStyle = AppTypography.displayLarge.copyWith(
      color: colors.neon.glow.withValues(alpha: 0.7),
    );
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_convert_estimate'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PrivateUsdPanelCaption(PrivateUsdCopy.title),
          const SizedBox(height: AppSpacing.xs),
          // While the quote is on its way the amount churns as cipher; the
          // quote then decrypts in.
          if (state.quoting)
            NeonCipherChurn(
              key: const ValueKey('mobile_private_usd_convert_receive'),
              style: cipherStyle,
              semanticsLabel: PrivateUsdCopy.convertQuoteLoading,
            )
          else
            NeonScrambleText(
              key: const ValueKey('mobile_private_usd_convert_receive'),
              text: estimate,
              decryptOnAppear: quoted,
              cipherStyle: cipherStyle,
              style: AppTypography.displayLarge.copyWith(
                color: quoted ? colors.neon.core : colors.text.disabled,
                shadows: quoted
                    ? Neon.textGlow(colors.neon.glow, intensity: 0.4)
                    : null,
              ),
            ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            PrivateUsdCopy.convertEstimatedAmount,
            style: AppTypography.bodySmall.copyWith(
              color: colors.text.secondary,
            ),
          ),
          if (available != null) ...[
            const SizedBox(height: AppSpacing.s),
            Text(
              '${PrivateUsdCopy.rowAvailable}: '
              '${hideAmountIfPrivacyMode(formatPrivateUsd(available), privacyModeEnabled: privacyModeEnabled, denomination: '')}',
              style: AppTypography.bodySmall.copyWith(
                color: colors.text.secondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A quote's ledger: what is paid, its network fee, what arrives and the
/// fees (plan reference §9.4 S3).
class PrivateUsdQuoteLedger extends StatelessWidget {
  const PrivateUsdQuoteLedger({
    required this.quote,
    required this.privacyModeEnabled,
    this.showsTotal = false,
    super.key,
  });

  final PrivateUsdZecQuote quote;
  final bool privacyModeEnabled;

  /// The amount step repeats what is paid and received; the review's header
  /// already says both.
  final bool showsTotal;

  String _masked(String text) => hideAmountIfPrivacyMode(
    text,
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );

  @override
  Widget build(BuildContext context) {
    final networkCost = quote.networkCost;
    final rows = <(String, String)>[
      if (showsTotal)
        (
          PrivateUsdCopy.convertYouPay,
          _masked(ZecAmount.fromZatoshi(quote.totalZat).activity.toString()),
        ),
      (
        PrivateUsdCopy.convertNetworkFee,
        _masked(ZecAmount.fromZatoshi(quote.feeZat).activity.toString()),
      ),
      if (showsTotal)
        (
          PrivateUsdCopy.convertYouReceive,
          _masked(formatPrivateUsd(quote.receives)),
        ),
      (
        PrivateUsdCopy.convertFees,
        PrivateUsdCopy.convertFeesValue(
          formatPrivateUsd(quote.relayerFee),
          kPrivateUsdRailgunFeePercent,
        ),
      ),
      if (networkCost != null && networkCost > BigInt.zero)
        (PrivateUsdCopy.convertMakerCost, formatPrivateUsd(networkCost)),
    ];
    return PrivateUsdLedgerCard(
      key: const ValueKey('mobile_private_usd_quote_ledger'),
      rows: [
        for (final (label, value) in rows)
          PrivateUsdLedgerRow(label: label, value: value),
      ],
    );
  }
}

/// A quote's ledger panel: its rows between hairlines.
class PrivateUsdLedgerCard extends StatelessWidget {
  const PrivateUsdLedgerCard({required this.rows, super.key});

  final List<PrivateUsdLedgerRow> rows;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MobileSurfaceCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++)
            DecoratedBox(
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(
                        top: BorderSide(color: colors.border.subtleOpacity),
                      ),
              ),
              child: rows[i],
            ),
        ],
      ),
    );
  }
}

/// One line of a ledger: the label on the left, the value on the right,
/// always on one line (a long value shrinks to fit rather than wrap).
class PrivateUsdLedgerRow extends StatelessWidget {
  const PrivateUsdLedgerRow({
    required this.label,
    required this.value,
    this.emphasized = false,
    super.key,
  });

  final String label;
  final String value;

  /// The line that matters most (a total), lit.
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = AppTypography.bodyExtraSmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(color: colors.text.secondary),
              ),
            ),
            const SizedBox(width: AppSpacing.s),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.64,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  value,
                  maxLines: 1,
                  style: style.copyWith(
                    color: emphasized ? colors.neon.core : colors.text.accent,
                    shadows: emphasized
                        ? Neon.textGlow(colors.neon.glow, intensity: 0.3)
                        : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A Private USD panel's caption (the asset it holds), as a red HUD caption.
class PrivateUsdPanelCaption extends StatelessWidget {
  const PrivateUsdPanelCaption(this.text, {super.key});

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

/// "Quote expires in m:ss" (or "Quote holds for m:ss" on the review), or
/// "Quote expired", between two rules (vizor's pay review divider).
class PrivateUsdQuoteExpiry extends StatelessWidget {
  const PrivateUsdQuoteExpiry({
    required this.expired,
    required this.label,
    super.key,
  });

  final bool expired;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final glow = colors.neon.glow;
    // Hairlines that light up toward the label.
    Widget rule({required bool toRight}) {
      final lit = glow.withValues(alpha: expired ? 0.7 : 0.45);
      final dark = glow.withValues(alpha: 0);
      return Expanded(
        child: Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: toRight ? [dark, lit] : [lit, dark],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      key: const ValueKey('mobile_private_usd_quote_expiry'),
      height: 38,
      child: Row(
        children: [
          rule(toRight: true),
          const SizedBox(width: AppSpacing.s),
          Text(
            (expired ? PrivateUsdCopy.quoteExpired : label).toUpperCase(),
            style: kNeonHudCaptionStyle.copyWith(
              color: expired ? colors.text.destructive : colors.text.secondary,
            ),
          ),
          const SizedBox(width: AppSpacing.s),
          rule(toRight: false),
        ],
      ),
    );
  }
}

/// The convert screen's direction switch between its two panels (zapp
/// `canSwitchDirection`), a cut-corner plate on a lit seam joining them. It
/// keeps its place when switching is unavailable ([onTap] null), dimmed, and
/// its edge breathes while a quote is on its way ([busy]).
class PrivateUsdDirectionToggle extends StatefulWidget {
  const PrivateUsdDirectionToggle({this.onTap, this.busy = false, super.key});

  final VoidCallback? onTap;
  final bool busy;

  @override
  State<PrivateUsdDirectionToggle> createState() =>
      _PrivateUsdDirectionToggleState();
}

class _PrivateUsdDirectionToggleState extends State<PrivateUsdDirectionToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBreath();
  }

  @override
  void didUpdateWidget(PrivateUsdDirectionToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBreath();
  }

  void _syncBreath() {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.busy && !reduced) {
      if (!_breath.isAnimating) unawaited(_breath.repeat(reverse: true));
    } else {
      _breath
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final onTap = widget.onTap;
    final enabled = onTap != null;
    final glow = colors.neon.glow;
    return SizedBox(
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The seam joining the two panels.
          Center(
            child: Container(
              width: 1,
              color: glow.withValues(alpha: enabled ? 0.45 : 0.2),
            ),
          ),
          Semantics(
            button: true,
            enabled: enabled,
            label: PrivateUsdCopy.convertSwapDirection,
            excludeSemantics: true,
            child: GestureDetector(
              key: const ValueKey('mobile_private_usd_convert_direction'),
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: AnimatedBuilder(
                animation: _breath,
                builder: (context, child) {
                  final double breath = widget.busy
                      ? 0.25 + 0.75 * _breath.value
                      : 0;
                  final edge = enabled
                      ? glow.withValues(alpha: 0.75)
                      : Color.lerp(
                          colors.border.subtleOpacity,
                          glow.withValues(alpha: 0.6),
                          breath,
                        )!;
                  return Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(
                      color: colors.background.window,
                      shape: Neon.chamferBorder(side: BorderSide(color: edge)),
                      shadows: enabled || breath > 0
                          ? Neon.boxGlow(
                              glow,
                              intensity: enabled ? 0.25 : 0.35 * breath,
                            )
                          : null,
                    ),
                    child: child,
                  );
                },
                child: RotatedBox(
                  quarterTurns: 1,
                  child: TronGlyph(
                    TronGlyphKind.swap,
                    color: enabled ? glow : colors.icon.disabled,
                    core: colors.neon.core,
                    lit: enabled ? 0.6 : 0,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The info button of the Private USD screens' top bars.
class PrivateUsdInfoButton extends StatelessWidget {
  const PrivateUsdInfoButton({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: PrivateUsdCopy.infoButton,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('mobile_private_usd_info'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: AppIcon(
              AppIcons.help,
              size: 20,
              color: context.colors.text.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// `m:ss`, never negative.
String formatMinutesSeconds(Duration duration) {
  final seconds = duration.isNegative ? 0 : duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
