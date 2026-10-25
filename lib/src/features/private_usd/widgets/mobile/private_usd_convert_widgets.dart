import 'dart:async';

import 'package:flutter/material.dart' show InputDecoration, TextField;
import 'package:flutter/widgets.dart';

import '../../../../core/formatting/zec_amount.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/comma_to_dot_input_formatter.dart';
import '../../../../core/widgets/decimal_amount_input_formatter.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../core/widgets/mobile/neon_scramble_text.dart';
import '../../../../core/widgets/mobile/tron_glyph.dart';
import '../../../../rust/api/private_usd.dart' show ApiReverseRecord;
import '../../../swap/domain/swap_asset.dart';
import '../../../swap/widgets/swap_asset_icon.dart';
import '../../models/private_usd_balances.dart';
import '../../models/private_usd_reverse_presentation.dart';
import '../../private_usd_copy.dart';
import '../../services/private_usd_zec_quote_search.dart';
import 'private_usd_flow_widgets.dart';
import 'private_usd_logo.dart';

/// The side of an asset's logo beside a panel's caption.
const _captionLogoSize = 20.0;

/// A panel's caption as a red HUD caption: the asset it holds, after the
/// asset's logo, or what the panel is about.
class PrivateUsdPanelCaption extends StatelessWidget {
  const PrivateUsdPanelCaption(this.text, {this.logo, super.key});

  const PrivateUsdPanelCaption.zec({super.key})
    : text = PrivateUsdCopy.convertAssetZec,
      logo = const SwapAssetIcon(
        asset: SwapAsset.zec,
        size: _captionLogoSize,
        showChainBadge: false,
      );

  const PrivateUsdPanelCaption.privateUsd({super.key})
    : text = PrivateUsdCopy.title,
      logo = const PrivateUsdLogo(size: _captionLogoSize);

  final String text;
  final Widget? logo;

  @override
  Widget build(BuildContext context) {
    final glow = context.colors.neon.glow;
    final caption = Text(
      text.toUpperCase(),
      style: kNeonHudCaptionStyle.copyWith(
        color: glow,
        shadows: Neon.textGlow(glow, intensity: 0.3),
      ),
    );
    final logo = this.logo;
    if (logo == null) return caption;
    return Row(
      children: [
        logo,
        const SizedBox(width: AppSpacing.xs),
        Flexible(child: caption),
      ],
    );
  }
}

/// The panel an amount is typed into: its [caption], the field, what is
/// available and Max. Its parts are keyed `{keyPrefix}_amount`,
/// `{keyPrefix}_amount_error`, `{keyPrefix}_available` and
/// `{keyPrefix}_max`.
class PrivateUsdAmountPanel extends StatelessWidget {
  const PrivateUsdAmountPanel({
    required this.caption,
    required this.controller,
    required this.onChanged,
    required this.maxFractionDigits,
    required this.available,
    required this.onMax,
    this.keyPrefix = 'mobile_private_usd_convert',
    this.focusNode,
    this.autofocus = true,
    this.readOnly = false,
    this.invalid = false,
    this.marketValue,
    this.note,
    this.error,
    this.footer,
    super.key,
  });

  final Widget caption;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// Finer amounts are not typed at all.
  final int maxFractionDigits;
  final String available;

  /// Null disables Max.
  final VoidCallback? onMax;
  final String keyPrefix;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool readOnly;
  final bool invalid;

  /// What the amount is worth at market prices, shown in brackets on the
  /// right of the line under the field; null hides it.
  final String? marketValue;

  /// Under the field, what the amount includes.
  final String? note;

  /// Under the field, why the amount is refused.
  final String? error;

  /// Under Max.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final note = this.note;
    final error = this.error;
    final footer = this.footer;
    final amountStyle = AppTypography.displayLarge.copyWith(
      color: invalid ? colors.text.destructive : colors.text.accent,
    );
    final small = AppTypography.bodySmall;
    return MobileSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          caption,
          const SizedBox(height: AppSpacing.xs),
          TextField(
            key: ValueKey('${keyPrefix}_amount'),
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            readOnly: readOnly,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              const CommaToDotInputFormatter(),
              DecimalAmountInputFormatter(maxFractionDigits: maxFractionDigits),
            ],
            onChanged: onChanged,
            style: amountStyle,
            cursorColor: colors.neon.glow,
            decoration: InputDecoration.collapsed(
              hintText: '0',
              hintStyle: amountStyle.copyWith(color: colors.text.muted),
            ),
          ),
          if (note != null || marketValue != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            _UnderAmountLine(text: note, marketValue: marketValue),
          ],
          if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              error,
              key: ValueKey('${keyPrefix}_amount_error'),
              style: small.copyWith(color: colors.text.destructive),
            ),
          ],
          const SizedBox(height: AppSpacing.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  PrivateUsdCopy.availableAmount(available),
                  key: ValueKey('${keyPrefix}_available'),
                  style: small.copyWith(color: colors.text.secondary),
                ),
              ),
              Semantics(
                label: PrivateUsdCopy.useAvailable,
                button: true,
                excludeSemantics: true,
                child: AppButton(
                  key: ValueKey('${keyPrefix}_max'),
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.small,
                  onPressed: onMax,
                  child: const Text(PrivateUsdCopy.max),
                ),
              ),
            ],
          ),
          if (footer != null) ...[
            const SizedBox(height: AppSpacing.xs),
            footer,
          ],
        ],
      ),
    );
  }
}

/// The panel the quote's estimate shows in. While the quote is on its way
/// the amount churns as cipher; the quote then decrypts in.
class PrivateUsdEstimatePanel extends StatelessWidget {
  const PrivateUsdEstimatePanel({
    required this.caption,
    required this.quoting,
    required this.estimate,
    this.available,
    this.marketValue,
    super.key,
  });

  final Widget caption;
  final bool quoting;

  /// Null while unknown.
  final String? estimate;

  /// What the receiving side holds already.
  final String? available;

  /// What the estimate is worth at market prices, shown in brackets on the
  /// right of the line under it; null hides it.
  final String? marketValue;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final estimate = this.estimate;
    final available = this.available;
    final known = estimate != null;
    final cipherStyle = AppTypography.displayLarge.copyWith(
      color: colors.neon.glow.withValues(alpha: 0.7),
    );
    final small = AppTypography.bodySmall.copyWith(
      color: colors.text.secondary,
    );
    return MobileSurfaceCard(
      key: const ValueKey('mobile_private_usd_convert_estimate'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          caption,
          const SizedBox(height: AppSpacing.xs),
          if (quoting)
            NeonCipherChurn(
              key: const ValueKey('mobile_private_usd_convert_receive'),
              style: cipherStyle,
              semanticsLabel: PrivateUsdCopy.convertQuoteLoading,
            )
          else
            NeonScrambleText(
              key: const ValueKey('mobile_private_usd_convert_receive'),
              text: estimate ?? PrivateUsdCopy.unknown,
              decryptOnAppear: known,
              cipherStyle: cipherStyle,
              style: AppTypography.displayLarge.copyWith(
                color: known ? colors.neon.core : colors.text.disabled,
                shadows: known
                    ? Neon.textGlow(colors.neon.glow, intensity: 0.4)
                    : null,
              ),
            ),
          const SizedBox(height: AppSpacing.xxs),
          _UnderAmountLine(
            text: PrivateUsdCopy.convertEstimatedAmount,
            marketValue: marketValue,
          ),
          if (available != null) ...[
            const SizedBox(height: AppSpacing.s),
            Text(PrivateUsdCopy.availableAmount(available), style: small),
          ],
        ],
      ),
    );
  }
}

/// The line under a panel's amount, with the amount's market value in
/// brackets on its right where there is one.
class _UnderAmountLine extends StatelessWidget {
  const _UnderAmountLine({this.text, this.marketValue});

  final String? text;
  final String? marketValue;

  @override
  Widget build(BuildContext context) {
    final text = this.text;
    final marketValue = this.marketValue;
    final style = AppTypography.bodySmall.copyWith(
      color: context.colors.text.secondary,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: text == null ? const SizedBox() : Text(text, style: style),
        ),
        if (marketValue != null) ...[
          const SizedBox(width: AppSpacing.xs),
          Text(
            PrivateUsdCopy.convertMarketValue(marketValue),
            key: const ValueKey('mobile_private_usd_convert_market_value'),
            style: style,
          ),
        ],
      ],
    );
  }
}

/// The direction switch between the convert screen's two panels, a
/// cut-corner plate on a lit seam joining them. It keeps its place when
/// switching is unavailable ([onTap] null), dimmed, and its edge breathes
/// while a quote is on its way ([busy]).
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
    if (widget.busy && !MediaQuery.disableAnimationsOf(context)) {
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

/// The quote's countdown, or that it expired, between two hairlines that
/// light up toward it.
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

/// A forward quote's ledger: what is paid, its network fee, what arrives
/// and the fees.
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

/// A priced reverse quote's ledger: the escrow value, and Railgun's unshield
/// fee and the broadcast fee to the cent, which together make the total paid
/// (the amount above, and the review's header), then the maker's network
/// cost when it names one, and the ZEC estimate.
class PrivateUsdReverseLedger extends StatelessWidget {
  const PrivateUsdReverseLedger({
    required this.record,
    required this.privacyModeEnabled,
    super.key,
  });

  final ApiReverseRecord record;
  final bool privacyModeEnabled;

  String _masked(String text) => hideAmountIfPrivacyMode(
    text,
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );

  @override
  Widget build(BuildContext context) {
    final cost = record.cost;
    final networkCost = BigInt.tryParse(record.networkCost ?? '');
    final rows = <(String, String)>[
      (
        PrivateUsdCopy.reverseEscrow,
        _masked(formatPrivateUsd(BigInt.parse(record.amount))),
      ),
      if (cost != null) ...[
        (
          PrivateUsdCopy.reverseRailgunFee,
          formatPrivateUsdNearest(BigInt.parse(cost.railgunFee)),
        ),
        (
          PrivateUsdCopy.reverseBroadcasterFee,
          formatPrivateUsdNearest(BigInt.parse(cost.broadcasterFee)),
        ),
      ],
      if (networkCost != null && networkCost > BigInt.zero)
        (PrivateUsdCopy.convertMakerCost, formatPrivateUsd(networkCost)),
      (
        PrivateUsdCopy.reverseReceiveEstimate,
        _masked(
          ZecAmount.fromZatoshi(
            privateUsdReverseReceivedZat(record),
          ).activity.toString(),
        ),
      ),
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
