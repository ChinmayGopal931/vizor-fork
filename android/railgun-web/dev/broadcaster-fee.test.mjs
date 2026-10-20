import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EVMGasType } from '@railgun-community/shared-models';
import { gasFee } from '../src/broadcaster-fee.js';

test('a send pays for its gas estimate plus the SDK\'s 20% at the broadcaster\'s rate, or the minimum if more', () => {
  const feeToken = { tokenAddress: '0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c', feePerUnitGas: 2_726_271_000n };
  const gas = { evmGasType: EVMGasType.Type1, gasEstimate: 1_100_000n, gasPrice: 1_000_000_000n };

  assert.equal(gasFee(feeToken, gas, 500_000n), 3_598_677n);
  assert.equal(gasFee(feeToken, gas, 5_000_000n), 5_000_000n);
});
