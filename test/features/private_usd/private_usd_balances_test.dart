import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/features/private_usd/models/private_usd_balances.dart';
import 'package:zcash_wallet/src/features/private_usd/models/railgun_models.dart';
import 'package:zcash_wallet/src/features/private_usd/services/private_usd_balance_cache.dart';

// Plan reference §6.6: buckets to display amounts, headline = available +
// processing.
void main() {
  test('buckets map to display amounts and the headline is available plus '
      'processing', () {
    final balances = PrivateUsdBalances.of(
      RailgunBalances({
        RailgunBalanceBucket.spendable: [_amount(_testUsd, 1000000)],
        RailgunBalanceBucket.shieldPending: [_amount(_testUsd, 200000)],
        RailgunBalanceBucket.shieldBlocked: [_amount(_testUsd, 30000)],
        RailgunBalanceBucket.proofSubmitted: [_amount(_testUsd, 4000)],
        RailgunBalanceBucket.missingInternalPoi: [_amount(_usdc, 500)],
        RailgunBalanceBucket.missingExternalPoi: [_amount(_usdc, 60)],
        RailgunBalanceBucket.spent: [_amount(_testUsd, 7000000)],
      }),
      _tokens,
    );

    expect(balances.available, BigInt.from(1000000));
    expect(balances.arriving, BigInt.from(200000));
    expect(balances.blocked, BigInt.from(30000));
    expect(balances.processing, BigInt.from(4560));
    expect(balances.spendable, BigInt.from(1004560));
    expect(balances.total, BigInt.from(1234560));
    expect(balances.isBlocked, isTrue);
  });

  test('tokens that are not known dollars are left out', () {
    final balances = PrivateUsdBalances.of(
      RailgunBalances({
        RailgunBalanceBucket.spendable: [
          _amount(_weth, 5000000000000000000),
          _amount(_usdc, 2500000),
        ],
      }),
      _tokens,
    );

    expect(balances.assets.map((a) => a.token.symbol), ['USDC']);
    expect(balances.spendable, BigInt.from(2500000));
    expect(balances.held, hasLength(1));
  });

  test('assets keep the deployment order and sum across buckets', () {
    final balances = PrivateUsdBalances.of(
      RailgunBalances({
        RailgunBalanceBucket.spendable: [
          _amount(_usdc, 1),
          _amount(_testUsd, 2),
        ],
        RailgunBalanceBucket.shieldPending: [
          _amount(_testUsd.toUpperCase(), 3),
        ],
      }),
      _tokens,
    );

    expect(balances.assets.map((a) => a.token.symbol), ['tUSD', 'USDC']);
    expect(balances.assets.first.total, BigInt.from(5));
  });

  test('dollars show to the cent, rounded down, grouped', () {
    expect(formatPrivateUsd(BigInt.zero), r'$0.00');
    expect(formatPrivateUsd(BigInt.from(9999)), r'$0.00');
    expect(formatPrivateUsd(BigInt.from(1234567899)), r'$1,234.56');
    expect(formatPrivateUsd(BigInt.from(1000000000000)), r'$1,000,000.00');
  });

  test('a payment shows to the nearest cent, half up', () {
    // A $19.90 total's debit and Railgun's fee on it.
    expect(formatPrivateUsdNearest(BigInt.from(19899750)), r'$19.90');
    expect(formatPrivateUsdNearest(BigInt.from(49750)), r'$0.05');
    expect(formatPrivateUsdNearest(BigInt.from(19894999)), r'$19.89');
    expect(formatPrivateUsdNearest(BigInt.from(5000)), r'$0.01');
    expect(formatPrivateUsdNearest(BigInt.zero), r'$0.00');
  });

  test('the ZEC equivalent needs a price', () {
    expect(
      privateUsdZecEquivalentZatoshi(BigInt.from(50000000), zecUsdPrice: 50),
      BigInt.from(100000000),
    );
    expect(
      privateUsdZecEquivalentZatoshi(BigInt.from(50000000), zecUsdPrice: null),
      isNull,
    );
    expect(
      privateUsdZecEquivalentZatoshi(BigInt.from(50000000), zecUsdPrice: 0),
      isNull,
    );
    expect(
      privateUsdZecEquivalentZatoshi(BigInt.zero, zecUsdPrice: 50),
      isNull,
    );
  });

  test('the cache keeps positive amounts and drops what it cannot read', () {
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final raw = PrivateUsdBalanceCache.encode(
      address: 'zk',
      updatedAt: at,
      balances: RailgunBalances({
        RailgunBalanceBucket.spendable: [
          _amount(_usdc, 7),
          _amount(_testUsd, 0),
        ],
      }),
    );

    final cached = PrivateUsdBalanceCache.decode(raw);
    expect(cached.address, 'zk');
    expect(cached.updatedAt, at);
    expect(
      cached.balances,
      RailgunBalances({
        RailgunBalanceBucket.spendable: [_amount(_usdc, 7)],
      }),
    );
    expect(
      () => PrivateUsdBalanceCache.decode('{"address":"zk"}'),
      throwsA(anything),
    );
  });
}

const _testUsd = '0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c';
const _usdc = '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238';
const _weth = '0xfff9976782d46cc05630d1f6ebab18b2324d6b14';
const _tokens = [
  PrivateUsdToken(address: _testUsd, symbol: 'tUSD', decimals: 6),
  PrivateUsdToken(address: _usdc, symbol: 'USDC', decimals: 6),
];

RailgunTokenAmount _amount(String token, int amount) =>
    RailgunTokenAmount(token: token, amount: BigInt.from(amount));
