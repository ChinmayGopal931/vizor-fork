import assert from 'node:assert/strict';
import test from 'node:test';
import { withKeysDroppedOnRefusal } from '../src/artifacts.js';

test("a proof its verification key refuses drops the kept keys, so the next try fetches its circuit's again", async () => {
  let dropped = 0;
  let valid = false;
  const groth16 = withKeysDroppedOnRefusal(
    { fullProve: async (...args) => ({ proof: args.length }), verify: async () => valid },
    async () => {
      dropped += 1;
    },
  );
  assert.deepEqual(await groth16.fullProve(1, 2, 3, 4), { proof: 4 });
  assert.equal(await groth16.verify({}, [], {}), false, 'the proof still fails');
  assert.equal(dropped, 1);
  valid = true;
  assert.equal(await groth16.verify({}, [], {}), true);
  assert.equal(dropped, 1, 'a proof the key takes drops nothing');
});

test('a drop that fails leaves the refusal as it was', async () => {
  const groth16 = withKeysDroppedOnRefusal({ fullProve: async () => ({}), verify: async () => false }, async () => {
    throw new Error('IndexedDB refused the delete');
  });
  assert.equal(await groth16.verify({}, [], {}), false);
});
