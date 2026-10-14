import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EVMGasType } from '@railgun-community/shared-models';
import { gasFee } from '../src/broadcaster-fee.js';

test('a send pays for its gas estimate plus the SDK\'s 20% at the broadcaster\'s rate, or the minimum if more', () => {
  const feeToken = { tokenAddress: '0x5764d0044bef5aa839e0ddafe2073421101b9ed8', feePerUnitGas: 2_726_271_000n };
  const gas = { evmGasType: EVMGasType.Type1, gasEstimate: 1_100_000n, gasPrice: 1_000_000_000n };

  assert.equal(gasFee(feeToken, gas, 500_000n), 3_598_677n);
  assert.equal(gasFee(feeToken, gas, 5_000_000n), 5_000_000n);
});
