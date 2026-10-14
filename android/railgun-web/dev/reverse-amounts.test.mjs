import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fundingAmounts } from '../src/reverse-amounts.js';

test('unshield leaves the exact escrow amount, including integer rounding boundaries', () => {
  for (const bps of [0n, 1n, 25n, 50n, 9999n]) {
    for (const escrow of [1n, 2n, 399n, 400n, 401n, 999999n, 1000000n, 20000000n, (1n << 110n)]) {
      const cost = fundingAmounts(escrow, bps);
      const debit = BigInt(cost.debit);
      assert.equal(debit - debit * bps / 10000n, escrow);
      assert.equal(BigInt(cost.railgunFee), debit - escrow);
    }
  }
});

test('invalid amounts and fees are rejected', () => {
  for (const [amount, fee] of [[0n, 25n], [-1n, 25n], [100n, -1n], [100n, 10000n]]) {
    assert.throws(() => fundingAmounts(amount, fee));
  }
});
