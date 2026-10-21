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
import 'private_usd_logo.dart';

/// Height of the home strip: the transparent-balance strip's, a private
/// constant of Home's.
const kPrivateUsdHomeStripHeight = 57.0;

const _logoSize = 20.0;
const _chevronSize = 20.0;

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

/// The home balance card's Private USD row: the headline balance, its ZEC
/// worth and what is arriving or refused, and a chevron to `/private-usd`.
/// It keeps the balance fresh only once Private USD is in use, so before
/// that it shows no amount and starts nothing.
class PrivateUsdHomeStrip extends ConsumerWidget {
  const PrivateUsdHomeStrip({
    required this.accountUuid,
    required this.privacyModeEnabled,
    required this.onTap,
    this.caption,
    super.key,
  });

  final String accountUuid;
  final bool privacyModeEnabled;
  final VoidCallback onTap;

  /// See [PrivateUsdHomeStripView.caption].
  final String? caption;

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
      caption: caption,
    );
  }
}

class PrivateUsdHomeStripView extends StatelessWidget {
  const PrivateUsdHomeStripView({
    required this.state,
    required this.zecUsdPrice,
    required this.privacyModeEnabled,
    required this.onTap,
    this.caption,
    super.key,
  });

  final PrivateUsdBalanceState state;
  final double? zecUsdPrice;
  final bool privacyModeEnabled;
  final VoidCallback onTap;

  /// Said under the name in place of the ZEC worth, as the holdings panel
  /// places Private USD among the shielded pools.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final balances = state.balances;
    final blocked = balances?.isBlocked ?? false;
    final amount = balances == null
        ? (state.isRefreshing ? PrivateUsdCopy.loading : PrivateUsdCopy.unknown)
        : _masked(formatPrivateUsd(balances.spendable));
    final zec = caption != null || balances == null || privacyModeEnabled
        ? null
        : privateUsdZecEquivalentText(
            balances.spendable,
            zecUsdPrice: zecUsdPrice,
          );
    final under = caption ?? zec;
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
        PrivateUsdCopy.homeBalanceDescription(amountSpoken),
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                // What is left once the logo, chevron and gaps are placed.
                final room =
                    constraints.maxWidth -
                    (_logoSize +
                        AppSpacing.xs +
                        AppSpacing.s +
                        AppSpacing.xxs +
                        _chevronSize);
                return Row(
                  children: [
                    const PrivateUsdLogo(size: _logoSize),
                    const SizedBox(width: AppSpacing.xs),
                    // The name and the ZEC worth on the left keep whatever the
                    // right side does not need, so "≈ 0.03613 ZEC" is not cut
                    // short in a wide font.
                    Expanded(
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
                          if (under != null) ...[
                            const SizedBox(height: AppSpacing.xxs),
                            Text(
                              under,
                              key: ValueKey(
                                caption != null
                                    ? 'mobile_home_private_usd_caption'
                                    : 'mobile_home_private_usd_zec_equivalent',
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
                    // The amount and what needs saying about it take their own
                    // width, up to three fifths of the room.
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: room * 0.6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            amount,
                            key: const ValueKey(
                              'mobile_home_private_usd_amount',
                            ),
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
                              key: const ValueKey(
                                'mobile_home_private_usd_detail',
                              ),
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
                      size: _chevronSize,
                      color: colors.icon.accent,
                    ),
                  ],
                );
              },
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
