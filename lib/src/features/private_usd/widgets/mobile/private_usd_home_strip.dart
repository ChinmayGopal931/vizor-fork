import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/formatting/zec_amount.dart';
import '../../../../core/privacy/privacy_mask.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_icon.dart';
import '../../../../providers/zec_price_change_provider.dart';
import '../../models/private_usd_balances.dart';
import '../../private_usd_copy.dart';
import '../../providers/private_usd_balance_provider.dart';
import '../../services/private_usd_balance_repository.dart';

/// The Private USD icon until the E10 artwork exists.
const kPrivateUsdIcon = AppIcons.moneyBag;

/// Height of the home strip: the transparent-balance strip's.
const kPrivateUsdHomeStripHeight = 57.0;

/// `≈ 0.25 ZEC`, the indicative ZEC worth of [microDollars] at the display
/// price; null without a price.
String? privateUsdZecEquivalentText(
  BigInt microDollars, {
  required double? zecUsdPrice,
}) {
  final zatoshi = privateUsdZecEquivalentZatoshi(
    microDollars,
    zecUsdPrice: zecUsdPrice,
  );
  if (zatoshi == null) return null;
  return PrivateUsdCopy.homeZecEquivalent(
    ZecAmount.fromZatoshi(zatoshi).compactBalance.amountText,
  );
}

/// The home balance card's Private USD row (plan reference §8.3, §9.4 S1):
/// the headline balance, its `≈ ZEC` worth and what is arriving or refused,
/// and a chevron to `/private-usd`. It keeps the balance fresh only once
/// Private USD is in use, so before that it shows "—" and starts nothing.
class PrivateUsdHomeStrip extends ConsumerWidget {
  const PrivateUsdHomeStrip({
    required this.accountUuid,
    required this.privacyModeEnabled,
    required this.onTap,
    super.key,
  });

  final String accountUuid;
  final bool privacyModeEnabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      privateUsdBalanceKeepFreshProvider((
        accountUuid: accountUuid,
        ifUsed: true,
      )),
    );
    return PrivateUsdHomeStripView(
      state: ref.watch(privateUsdBalanceProvider(accountUuid)),
      zecUsdPrice: ref.watch(zecHomeUsdUnitPriceProvider),
      privacyModeEnabled: privacyModeEnabled,
      onTap: onTap,
    );
  }
}

class PrivateUsdHomeStripView extends StatelessWidget {
  const PrivateUsdHomeStripView({
    required this.state,
    required this.zecUsdPrice,
    required this.privacyModeEnabled,
    required this.onTap,
    super.key,
  });

  final PrivateUsdBalanceState state;
  final double? zecUsdPrice;
  final bool privacyModeEnabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final balances = state.balances;
    final blocked = balances?.isBlocked ?? false;
    final amount = balances == null
        ? (state.isRefreshing ? PrivateUsdCopy.loading : PrivateUsdCopy.unknown)
        : _masked(formatPrivateUsd(balances.spendable));
    final zec = balances == null || privacyModeEnabled
        ? null
        : privateUsdZecEquivalentText(
            balances.spendable,
            zecUsdPrice: zecUsdPrice,
          );
    // The one detail that needs saying, refused funds first.
    final String? detail;
    final String? detailSpoken;
    if (balances == null) {
      detail = null;
      detailSpoken = null;
    } else if (blocked) {
      detail = PrivateUsdCopy.homeBlocked(
        _masked(formatPrivateUsd(balances.blocked)),
      );
      detailSpoken = detail;
    } else if (balances.arriving > BigInt.zero) {
      final arriving = _masked(formatPrivateUsd(balances.arriving));
      detail = PrivateUsdCopy.homeArriving(arriving);
      detailSpoken = PrivateUsdCopy.homeArrivingDescription(arriving);
    } else {
      detail = null;
      detailSpoken = null;
    }
    final amountSpoken = blocked
        ? PrivateUsdCopy.homeBlockedDescription(amount)
        : amount;

    return Semantics(
      container: true,
      button: true,
      label: PrivateUsdCopy.homeOpen,
      value: [
        '${PrivateUsdCopy.title} $amountSpoken',
        ?zec,
        ?detailSpoken,
      ].join(', '),
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('mobile_home_private_usd_strip'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kPrivateUsdHomeStripHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                AppIcon(kPrivateUsdIcon, size: 20, color: colors.text.primary),
                const SizedBox(width: AppSpacing.xs),
                // The name and the ZEC worth on the left, the amount and what
                // needs saying about it on the right, which gets more room.
                Expanded(
                  flex: 2,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        PrivateUsdCopy.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.labelMedium.copyWith(
                          color: colors.text.primary,
                        ),
                      ),
                      if (zec != null) ...[
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          zec,
                          key: const ValueKey(
                            'mobile_home_private_usd_zec_equivalent',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyExtraSmall.copyWith(
                            color: colors.text.secondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s),
                Expanded(
                  flex: 3,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        amount,
                        key: const ValueKey('mobile_home_private_usd_amount'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.labelMedium.copyWith(
                          color: blocked
                              ? colors.text.destructive
                              : colors.text.primary,
                        ),
                      ),
                      if (detail != null) ...[
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          detail,
                          key: const ValueKey('mobile_home_private_usd_detail'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyExtraSmall.copyWith(
                            color: blocked
                                ? colors.text.destructive
                                : colors.text.positiveStrong,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.xxs),
                AppIcon(
                  AppIcons.chevronForward,
                  size: 20,
                  color: colors.icon.accent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _masked(String usd) => hideAmountIfPrivacyMode(
    usd,
    privacyModeEnabled: privacyModeEnabled,
    denomination: '',
  );
}
