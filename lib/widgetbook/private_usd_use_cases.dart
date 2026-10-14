// ignore_for_file: depend_on_referenced_packages
// widgetbook is dev-only; see `widgetbook.dart` for the boundary.

import 'package:flutter/widgets.dart';

import '../src/features/private_usd/models/private_usd_balances.dart';
import '../src/features/private_usd/models/railgun_models.dart';
import '../src/features/private_usd/private_usd_copy.dart';
import '../src/features/private_usd/screens/mobile/mobile_private_usd_screen.dart';
import '../src/features/private_usd/services/private_usd_balance_repository.dart';

/// Deterministic Private USD fixtures (plan reference §9.7): fixed balances,
/// addresses and times; no WebView, Rust, network or clock.

/// Mainnet USDC, the token the home and screen previews hold.
const previewPrivateUsdUsdc = PrivateUsdToken(
  address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
  symbol: 'USDC',
  decimals: 6,
);

/// A real-format `0zk` address (zapp's test vector for 64 bytes of 0x08).
const previewPrivateUsdAddress =
    '0zk1qyrs4qyrd08p6uep0fc2y8njktgcpezts3rpaq6q0ln948ecjkw8prv7j6f'
    'e3z53llz8ursderja0juwv5pgnv8x5klmmwkv8q38h9n704h4d4qjyw7n5qk68nx';

/// 2026-10-13 09:41 local.
final previewPrivateUsdUpdatedAt = DateTime(2026, 10, 13, 9, 41);

/// A balance with [available], [arriving], [blocked] and [processing]
/// dollars of USDC.
PrivateUsdBalanceState previewPrivateUsdBalance({
  double available = 0,
  double arriving = 0,
  double blocked = 0,
  double processing = 0,
  bool isRefreshing = false,
  bool refreshFailed = false,
}) {
  BigInt units(double dollars) => BigInt.from((dollars * 1e6).round());
  final buckets = <RailgunBalanceBucket, List<RailgunTokenAmount>>{
    RailgunBalanceBucket.spendable: [_held(units(available))],
    RailgunBalanceBucket.shieldPending: [_held(units(arriving))],
    RailgunBalanceBucket.shieldBlocked: [_held(units(blocked))],
    RailgunBalanceBucket.missingExternalPoi: [_held(units(processing))],
  };
  return PrivateUsdBalanceState(
    balances: PrivateUsdBalances.of(RailgunBalances(buckets), const [
      previewPrivateUsdUsdc,
    ]),
    updatedAt: previewPrivateUsdUpdatedAt,
    address: previewPrivateUsdAddress,
    isRefreshing: isRefreshing,
    refreshFailed: refreshFailed,
  );
}

RailgunTokenAmount _held(BigInt amount) =>
    RailgunTokenAmount(token: previewPrivateUsdUsdc.address, amount: amount);

/// Not used yet: nothing known and nothing loading, the home strip's "—".
const previewPrivateUsdUnknown = PrivateUsdBalanceState();

/// A first sync under way, nothing shown yet.
const previewPrivateUsdLoading = PrivateUsdBalanceState(isRefreshing: true);

Widget buildMobilePrivateUsdDefaultUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(
        available: 1250.4,
        arriving: 200,
        processing: 12.5,
      ),
    );

Widget buildMobilePrivateUsdEmptyUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(state: previewPrivateUsdBalance());

Widget buildMobilePrivateUsdFirstLoadUseCase(BuildContext context) =>
    const _PrivateUsdScreenPreview(
      state: PrivateUsdBalanceState(isRefreshing: true, firstSyncPercent: 42),
    );

Widget buildMobilePrivateUsdRefreshFailedUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(available: 1250.4, refreshFailed: true),
    );

Widget buildMobilePrivateUsdBlockedUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(available: 80, blocked: 25),
    );

Widget buildMobilePrivateUsdHiddenUseCase(BuildContext context) =>
    _PrivateUsdScreenPreview(
      state: previewPrivateUsdBalance(available: 1250.4, arriving: 200),
      privacyModeEnabled: true,
    );

class _PrivateUsdScreenPreview extends StatelessWidget {
  const _PrivateUsdScreenPreview({
    required this.state,
    this.privacyModeEnabled = false,
  });

  final PrivateUsdBalanceState state;
  final bool privacyModeEnabled;

  static const _size = Size(393, 852);
  static const _safeArea = EdgeInsets.only(top: 55, bottom: 24);

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return Center(
      child: SizedBox.fromSize(
        size: _size,
        child: ClipRect(
          child: MediaQuery(
            data: mediaQuery.copyWith(
              size: _size,
              padding: _safeArea,
              viewPadding: _safeArea,
            ),
            child: MobilePrivateUsdView(
              state: state,
              zecUsdPrice: 70,
              privacyModeEnabled: privacyModeEnabled,
              receiveAddress: previewPrivateUsdAddress,
              screening: const Duration(hours: 1),
              tokenNames: {
                previewPrivateUsdUsdc.address: PrivateUsdCopy.tokenName(
                  previewPrivateUsdUsdc.symbol,
                ),
              },
              onBack: () {},
              onRefresh: () {},
            ),
          ),
        ),
      ),
    );
  }
}
