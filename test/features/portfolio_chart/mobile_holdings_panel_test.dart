@Tags(['mobile'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/models/zec_pool_holdings.dart';
import 'package:zcash_wallet/src/features/portfolio_chart/widgets/mobile/mobile_holdings_panel.dart';
import 'package:zcash_wallet/src/providers/sync_provider.dart';

// Private USD is shielded too, on Ethereum: the holdings list it with the
// shielded pools and count it in their total, with the transparent ZEC under
// that total.
void main() {
  // 1.5 ZEC shielded, 0.5 transparent.
  final holdings = ZecPoolHoldings.of(
    SyncState(
      hasBalanceData: true,
      orchardBalance: BigInt.from(100000000),
      ironwoodBalance: BigInt.from(50000000),
      saplingBalance: BigInt.zero,
      transparentBalance: BigInt.from(50000000),
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    double? price,
    BigInt? dollars,
    bool privacyModeEnabled = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppTheme(
          data: AppThemeData.dark,
          child: SingleChildScrollView(
            child: MobileHoldingsPanelView(
              holdings: holdings,
              privacyModeEnabled: privacyModeEnabled,
              zecUsdUnitPrice: price,
              privateUsd: dollars == null
                  ? null
                  : const SizedBox(
                      key: ValueKey('private_usd_row'),
                      height: 40,
                    ),
              privateUsdDollars: dollars,
            ),
          ),
        ),
      ),
    );
  }

  String text(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  double top(WidgetTester tester, String key) =>
      tester.getTopLeft(find.byKey(ValueKey(key))).dy;

  testWidgets('the total counts Private USD, in dollars at the price', (
    tester,
  ) async {
    await pump(tester, price: 40, dollars: BigInt.from(1250400000));

    // 1.5 ZEC at $40 and $1,250.40.
    expect(text(tester, 'mobile_holdings_shielded_total_amount'), r'$1,310.40');
    expect(
      find.byKey(const ValueKey('mobile_holdings_shielded_total_usd')),
      findsNothing,
    );
    // Private USD sits with the shielded pools, the transparent ZEC under the
    // total.
    expect(
      top(tester, 'private_usd_row'),
      lessThan(top(tester, 'mobile_holdings_shielded_total_row')),
    );
    expect(
      top(tester, 'mobile_holdings_transparent_row'),
      greaterThan(top(tester, 'mobile_holdings_shielded_total_row')),
    );
  });

  testWidgets('without a price it names both amounts', (tester) async {
    await pump(tester, dollars: BigInt.from(1250400000));

    final total = text(tester, 'mobile_holdings_shielded_total_amount');
    expect(total, startsWith('1.5'));
    expect(total, endsWith(r'ZEC + $1,250.40'));
  });

  testWidgets('without Private USD it stays the shielded ZEC with its worth', (
    tester,
  ) async {
    await pump(tester, price: 40);

    expect(
      text(tester, 'mobile_holdings_shielded_total_amount'),
      endsWith('ZEC'),
    );
    expect(text(tester, 'mobile_holdings_shielded_total_usd'), r'$60.00');
  });

  test('the rows add up to the snapshot the Home sign shows', () {
    // A 1 ZEC Orchard receipt mined during a catch-up sync: the sign keeps
    // the last completed 5 ZEC until the sync finishes.
    final catchingUp = ZecPoolHoldings.of(
      SyncState(
        hasBalanceData: true,
        orchardBalance: BigInt.from(300000000),
        orchardPendingBalance: BigInt.from(100000000),
        saplingBalance: BigInt.from(100000000),
        ironwoodBalance: BigInt.from(100000000),
        displayOrchardBalance: BigInt.from(300000000),
        displayOrchardPendingBalance: BigInt.zero,
        displayIronwoodBalance: BigInt.from(100000000),
        displayIronwoodPendingBalance: BigInt.zero,
        displayShieldedBalance: BigInt.from(500000000),
      ),
    );

    expect(catchingUp.shielded.total, BigInt.from(500000000));
    expect(catchingUp.orchard, (
      total: BigInt.from(300000000),
      pending: BigInt.zero,
    ));
    expect(catchingUp.sapling, (
      total: BigInt.from(100000000),
      pending: BigInt.zero,
    ));
  });

  test("Sapling's pending part comes from the snapshot its total does", () {
    // A launch on the saved snapshot, before the first live read: 1 ZEC of
    // Sapling, a quarter of it pending.
    final launch = ZecPoolHoldings.of(
      SyncState(
        hasCachedBalance: true,
        displayShieldedBalance: BigInt.from(100000000),
        displaySaplingPendingBalance: BigInt.from(25000000),
      ),
    );
    expect(launch.sapling, (
      total: BigInt.from(100000000),
      pending: BigInt.from(25000000),
    ));
    expect(launch.shielded.pending, BigInt.from(25000000));

    // A catch-up sync's live reads leave the held row as it was.
    final catchingUp = ZecPoolHoldings.of(
      SyncState(
        hasBalanceData: true,
        saplingBalance: BigInt.from(100000000),
        saplingPendingBalance: BigInt.from(50000000),
        displayShieldedBalance: BigInt.from(100000000),
        displaySaplingPendingBalance: BigInt.from(25000000),
      ),
    );
    expect(catchingUp.sapling.pending, BigInt.from(25000000));
  });

  testWidgets('privacy mode masks the total', (tester) async {
    await pump(
      tester,
      price: 40,
      dollars: BigInt.from(1250400000),
      privacyModeEnabled: true,
    );

    expect(
      text(tester, 'mobile_holdings_shielded_total_amount'),
      isNot(contains('1,310')),
    );
  });
}
