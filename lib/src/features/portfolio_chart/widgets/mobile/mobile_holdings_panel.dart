import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/network_config.dart';
import '../../../../core/formatting/zec_amount.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../core/widgets/mobile/mobile_surface_card.dart';
import '../../../../providers/account_provider.dart';
import '../../../../providers/privacy_mode_provider.dart';
import '../../../../providers/sync_provider.dart';
import '../../../../providers/zec_price_change_provider.dart';
import '../../../../rust/api/sync.dart' as rust_sync;
import '../../../home/services/transparent_balance_display.dart';
import '../../../private_usd/providers/private_usd_available_provider.dart';
import '../../../private_usd/widgets/mobile/private_usd_home_strip.dart';
import '../../services/portfolio_chart_format.dart';

/// One shielded pool's ZEC as Home's balance counts it: [total] is the
/// spendable and pending notes, of which [pending] still waits for
/// confirmations.
typedef ShieldedPoolHoldings = ({BigInt total, BigInt pending});

/// The active account's ZEC by pool, as Home's balance counts it.
///
/// It reads the fields the Home sign reads: each shielded pool's spendable
/// and pending amounts, and [TransparentBalanceDisplay] for transparent funds.
/// Not the `display*` snapshot that desktop Home and the migration surfaces
/// read: there is none for Sapling or transparent funds, so mixing the two
/// could leave the rows disagreeing with their own total, and with the sign
/// this page was opened from.
@immutable
class ZecPoolHoldings {
  ZecPoolHoldings.of(SyncState sync)
    : hasBalance = sync.hasBalanceData,
      ironwood = (
        total: sync.ironwoodBalance + sync.ironwoodPendingBalance,
        pending: sync.ironwoodPendingBalance,
      ),
      orchard = (
        total: sync.orchardBalance + sync.orchardPendingBalance,
        pending: sync.orchardPendingBalance,
      ),
      sapling = (
        total: sync.saplingBalance + sync.saplingPendingBalance,
        pending: sync.saplingPendingBalance,
      ),
      transparent = TransparentBalanceDisplay.of(sync),
      transparentPending = sync.transparentPendingBalance;

  /// Whether the account's balances have been read. Until then every amount
  /// is unknown, never zero.
  final bool hasBalance;
  final ShieldedPoolHoldings ironwood;
  final ShieldedPoolHoldings orchard;
  final ShieldedPoolHoldings sapling;

  /// Home's transparent row: the amount, or why it is not known.
  final TransparentBalanceDisplay transparent;

  /// The part of a current transparent amount that waits for confirmations.
  final BigInt transparentPending;

  /// Home's shielded balance: the three shielded pools, pending included.
  ShieldedPoolHoldings get shielded => (
    total: ironwood.total + orchard.total + sapling.total,
    pending: ironwood.pending + orchard.pending + sapling.pending,
  );

  @override
  bool operator ==(Object other) =>
      other is ZecPoolHoldings &&
      other.hasBalance == hasBalance &&
      other.ironwood == ironwood &&
      other.orchard == orchard &&
      other.sapling == sapling &&
      other.transparent.amount == transparent.amount &&
      other.transparent.authority == transparent.authority &&
      other.transparent.stop == transparent.stop &&
      other.transparentPending == transparentPending;

  @override
  int get hashCode => Object.hash(
    hasBalance,
    ironwood,
    orchard,
    sapling,
    transparent.amount,
    transparent.authority,
    transparent.stop,
    transparentPending,
  );
}

/// The full chart page's holdings: the active account's ZEC in each pool, the
/// shielded total the Home balance shows, and Private USD where the account
/// has it.
class MobileHoldingsPanel extends ConsumerWidget {
  const MobileHoldingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountUuid = ref.watch(
      accountProvider.select((value) => value.value?.activeAccountUuid),
    );
    // Rebuilds when an amount changes, not on every sync progress event.
    final holdings = ref.watch(
      syncProvider.select(
        (value) => ZecPoolHoldings.of(
          (value.value ?? SyncState()).scopedToAccount(accountUuid),
        ),
      ),
    );
    final privacyModeEnabled = ref.watch(privacyModeProvider);
    return MobileHoldingsPanelView(
      holdings: holdings,
      privacyModeEnabled: privacyModeEnabled,
      zecUsdUnitPrice: ref.watch(zecHomeUsdUnitPriceProvider),
      // Gated as Home gates its strip.
      privateUsd: accountUuid != null && ref.watch(privateUsdAvailableProvider)
          ? PrivateUsdHomeStrip(
              accountUuid: accountUuid,
              privacyModeEnabled: privacyModeEnabled,
              onTap: () => context.push('/private-usd'),
            )
          : null,
    );
  }
}

/// [MobileHoldingsPanel] drawn from given values: a neon glass panel with a
/// row per pool (a zero row dimmed), the shielded total, and the Private USD
/// row when there is one.
///
/// Privacy mode masks every amount and drops what would hint at one: USD
/// worth, pending amounts and dimmed rows. Status words ("Unavailable",
/// "last known") stay, as they carry no amount.
class MobileHoldingsPanelView extends StatelessWidget {
  const MobileHoldingsPanelView({
    required this.holdings,
    required this.privacyModeEnabled,
    this.zecUsdUnitPrice,
    this.privateUsd,
    super.key,
  });

  final ZecPoolHoldings holdings;
  final bool privacyModeEnabled;

  /// Home's ZEC/USD price; without one no USD worth is shown.
  final double? zecUsdUnitPrice;

  /// The Private USD row, present only while Private USD is available.
  final Widget? privateUsd;

  /// Shown for an amount that has not been read yet.
  static const _unknown = '—';

  /// Amounts are known and may be shown as they are.
  bool get _amountsVisible => holdings.hasBalance && !privacyModeEnabled;

  /// `1.2345 ZEC` as the Home balance formats it, masked in privacy mode.
  String _zec(BigInt zatoshi) => hideAmountIfPrivacyMode(
    '${ZecAmount.fromZatoshi(zatoshi).compactBalance.amountText} '
    '$kZcashDefaultCurrencyTicker',
    privacyModeEnabled: privacyModeEnabled,
  );

  String _amount(BigInt zatoshi) =>
      holdings.hasBalance ? _zec(zatoshi) : _unknown;

  String? _pending(BigInt zatoshi) => _amountsVisible && zatoshi > BigInt.zero
      ? 'Includes ${_zec(zatoshi)} pending'
      : null;

  String? _usd(BigInt zatoshi) {
    final price = zecUsdUnitPrice;
    if (!_amountsVisible ||
        zatoshi <= BigInt.zero ||
        price == null ||
        !price.isFinite ||
        price <= 0) {
      return null;
    }
    final value = zatoshi.toDouble() / zatoshiPerZec.toDouble() * price;
    return value.isFinite ? formatPortfolioUsd(value) : null;
  }

  Widget _poolRow(String id, String name, ShieldedPoolHoldings pool) {
    return _HoldingsRow(
      id: id,
      label: name,
      icon: AppIcons.shieldKeyhole,
      shielded: true,
      amount: _amount(pool.total),
      pending: _pending(pool.pending),
      usd: _usd(pool.total),
      dimmed: _amountsVisible && pool.total == BigInt.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    final transparent = holdings.transparent;
    final transparentCurrent =
        transparent.authority == rust_sync.TransparentBalanceAuthority.current;
    final transparentAmount = transparent.amount ?? BigInt.zero;
    final shielded = holdings.shielded;
    final privateUsd = this.privateUsd;

    return MobileSurfaceCard(
      cornerRadius: AppRadii.large,
      // Rows pad themselves, as the Private USD strip does, so all of their
      // icons line up.
      padding: const EdgeInsets.fromLTRB(0, AppSpacing.md, 0, AppSpacing.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _HudHead('Holdings'),
          _poolRow('ironwood', 'Ironwood', holdings.ironwood),
          _poolRow('orchard', 'Orchard', holdings.orchard),
          _poolRow('sapling', 'Sapling', holdings.sapling),
          _HoldingsRow(
            id: 'transparent',
            label: 'Transparent',
            icon: AppIcons.transparentBalance,
            // Home's wording: a last-known amount says so, and an unknown one
            // never reads as 0.
            amount: holdings.hasBalance ? transparent.text(_zec) : _unknown,
            pending: transparentCurrent
                ? _pending(holdings.transparentPending)
                : null,
            usd: transparentCurrent ? _usd(transparentAmount) : null,
            // Why private recovery stopped and what to do; no amount in it.
            note: holdings.hasBalance ? transparent.hint : null,
            dimmed:
                _amountsVisible &&
                transparentCurrent &&
                transparentAmount == BigInt.zero,
          ),
          const _Rule(),
          _HoldingsRow(
            id: 'shielded_total',
            label: 'Total shielded',
            amount: _amount(shielded.total),
            pending: _pending(shielded.pending),
            usd: _usd(shielded.total),
            emphasized: true,
          ),
          if (privateUsd != null) ...[const _Rule(), privateUsd],
        ],
      ),
    );
  }
}

/// The HUD section head the Settings groups use: a red caption with a rule
/// running off it.
class _HudHead extends StatelessWidget {
  const _HudHead(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final glow = context.colors.neon.glow;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm + AppSpacing.xxs,
        0,
        AppSpacing.sm,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Text(
            title.toUpperCase(),
            style: kNeonHudCaptionStyle.copyWith(
              color: glow,
              shadows: Neon.textGlow(glow, intensity: 0.35),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: SizedBox(
              height: 1,
              child: ColoredBox(color: glow.withValues(alpha: 0.25)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A faint rule between the pools, the total and Private USD.
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      child: SizedBox(
        height: 1,
        child: ColoredBox(
          color: context.colors.neon.glow.withValues(alpha: 0.2),
        ),
      ),
    );
  }
}

/// A holdings line: the pool's glyph and name with the amount right-aligned,
/// then what is pending under the name and the USD worth under the amount.
class _HoldingsRow extends StatelessWidget {
  const _HoldingsRow({
    required this.id,
    required this.label,
    required this.amount,
    this.icon,
    this.shielded = false,
    this.pending,
    this.usd,
    this.note,
    this.dimmed = false,
    this.emphasized = false,
  });

  /// Names the row's keys, `mobile_holdings_<id>_amount` and so on.
  final String id;
  final String label;
  final String amount;

  /// The pool's glyph, coloured as the pool badge colours it: crimson when
  /// [shielded], muted when transparent.
  final String? icon;
  final bool shielded;

  /// "Includes … pending", under the name.
  final String? pending;

  /// The amount's USD worth, under it.
  final String? usd;

  /// An explanation under the row, aligned with the name.
  final String? note;

  /// A zero balance: drawn in the disabled colours.
  final bool dimmed;

  /// The total: its amount lit.
  final bool emphasized;

  /// With the vertical padding, the 52 px pitch of the mobile list rows.
  static const _minHeight = 44.0;
  static const _iconSize = 20.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final neon = colors.neon;
    final icon = this.icon;
    final pending = this.pending;
    final usd = this.usd;
    final note = this.note;
    final textColor = dimmed ? colors.text.disabled : colors.text.primary;
    final labelStyle = AppTypography.labelLarge.copyWith(
      color: emphasized ? colors.text.accent : textColor,
    );
    final amountStyle = emphasized
        ? AppTypography.labelLarge.copyWith(
            color: neon.core,
            shadows: Neon.textGlow(neon.glow, intensity: 0.35),
          )
        : AppTypography.labelLarge.copyWith(color: textColor);
    final secondaryStyle = AppTypography.bodyExtraSmall.copyWith(
      color: dimmed ? colors.text.disabled : colors.text.secondary,
    );

    return MergeSemantics(
      child: Padding(
        key: ValueKey('mobile_holdings_${id}_row'),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xxs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _minHeight),
              child: Row(
                children: [
                  if (icon != null) ...[
                    AppIcon(
                      icon,
                      size: _iconSize,
                      color: dimmed
                          ? colors.icon.disabled
                          : shielded
                          ? colors.text.brandCrimson
                          : colors.text.secondary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // The name keeps its width; the amount takes the rest
                        // and wraps rather than being cut short.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, style: labelStyle),
                            const SizedBox(width: AppSpacing.s),
                            Expanded(
                              child: Text(
                                amount,
                                key: ValueKey('mobile_holdings_${id}_amount'),
                                textAlign: TextAlign.end,
                                style: amountStyle,
                              ),
                            ),
                          ],
                        ),
                        if (pending != null || usd != null) ...[
                          const SizedBox(height: AppSpacing.xxs),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: pending == null
                                    ? const SizedBox.shrink()
                                    : Text(
                                        pending,
                                        key: ValueKey(
                                          'mobile_holdings_${id}_pending',
                                        ),
                                        style: secondaryStyle,
                                      ),
                              ),
                              if (usd != null) ...[
                                const SizedBox(width: AppSpacing.s),
                                Text(
                                  usd,
                                  key: ValueKey('mobile_holdings_${id}_usd'),
                                  style: secondaryStyle,
                                ),
                              ],
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (note != null)
              Padding(
                padding: EdgeInsets.only(
                  left: icon == null ? 0 : _iconSize + AppSpacing.xs,
                  bottom: AppSpacing.xs,
                ),
                child: Text(
                  note,
                  key: ValueKey('mobile_holdings_${id}_note'),
                  style: secondaryStyle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
