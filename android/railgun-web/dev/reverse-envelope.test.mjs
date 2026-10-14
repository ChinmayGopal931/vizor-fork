import assert from 'node:assert/strict';
import { test } from 'node:test';
import { unsignedFunding } from '../src/reverse-envelope.js';

const ADAPTER = '0x7e3d929EbD5bDC84d02Bd3205c777578f33A214D';
const DATA = '0x12345678';

test('funding sends the exact proof-bound envelope without phone gas fields or signatures', () => {
  assert.deepEqual(unsignedFunding({
    to: ADAPTER, data: DATA, value: 0n, nonce: 9, from: 'phone', gasLimit: 4000000n,
    maxFeePerGas: 20n, signature: 'private',
  }, ADAPTER), { to: ADAPTER, data: DATA, value: '0' });
});

test('changed destinations, ETH value and malformed or oversized calldata fail closed', () => {
  for (const changed of [
    { to: '0x1111111111111111111111111111111111111111' },
    { value: 1n }, { data: '0x123' }, { data: '0xzzzzzzzz' }, { data: `0x${'ab'.repeat(65537)}` },
  ]) {
    assert.throws(() => unsignedFunding({ to: ADAPTER, data: DATA, value: 0n, ...changed }, ADAPTER));
  }
});
