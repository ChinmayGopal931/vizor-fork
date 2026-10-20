import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MerkletreeScanStatus } from '@railgun-community/shared-models';
import { catchUpTxids, txidCompleteHold } from '../src/txid-catch-up.js';

// A txid tree the syncs grow by `adds`, one entry per sync, and that reports scanning for `busy` looks.
function tree({ at, adds = [], busy = 0 }) {
  const log = [];
  let index = at;
  let scanning = busy;
  return {
    log,
    latest: async () => index,
    sync: async () => {
      log.push('sync');
      index += adds.shift() ?? 0;
    },
    isScanning: () => {
      if (scanning === 0) return false;
      scanning -= 1;
      return true;
    },
    wait: async () => log.push('wait'),
  };
}

test('nothing added by the notes scan means no sync of its own', async () => {
  const txids = tree({ at: 143_174 });
  await catchUpTxids({ ...txids, before: 143_174, passes: 50 });
  assert.deepEqual(txids.log, []);
});

test('it syncs again while each sync adds txids, and stops at the first that adds none', async () => {
  // The notes scan's own sync took 130,000 to 140,000; then 3,175 more, then none.
  const txids = tree({ at: 140_000, adds: [3_175, 0, 5] });
  await catchUpTxids({ ...txids, before: 130_000, passes: 50 });
  assert.deepEqual(txids.log, ['sync', 'sync']);
  assert.equal(await txids.latest(), 143_175);
});

test('it stops after its passes, however much is left', async () => {
  const txids = tree({ at: 10_000, adds: Array(10).fill(10_000) });
  await catchUpTxids({ ...txids, before: 0, passes: 3 });
  assert.deepEqual(txids.log, ['sync', 'sync', 'sync']);
});

test("it waits out a sync the engine started itself before counting, and never syncs beside it", async () => {
  const txids = tree({ at: 10_000, adds: [0], busy: 2 });
  await catchUpTxids({ ...txids, before: 0, passes: 50 });
  assert.deepEqual(txids.log, ['wait', 'wait', 'sync']);
});

const scan = (status, progress) => ({ tree: 'txid', status, progress });

test('outside a catch-up every txid report goes out', () => {
  const hold = txidCompleteHold();
  assert.equal(hold.pass(scan(MerkletreeScanStatus.Updated, 0.5)), true);
  assert.equal(hold.pass(scan(MerkletreeScanStatus.Complete)), true);
});

test("a catch-up's Completes wait for its end, and only the last goes out", () => {
  const hold = txidCompleteHold();
  hold.begin();
  assert.equal(hold.pass(scan(MerkletreeScanStatus.Updated, 0.98)), true);
  assert.equal(hold.pass(scan(MerkletreeScanStatus.Complete)), false);
  assert.equal(hold.pass(scan(MerkletreeScanStatus.Updated, 0.03)), true);
  const last = scan(MerkletreeScanStatus.Complete);
  assert.equal(hold.pass(last), false);
  assert.equal(hold.end(), last);
});

test('a report after a held Complete drops it, so a failed last sync is not covered up', () => {
  const hold = txidCompleteHold();
  hold.begin();
  hold.pass(scan(MerkletreeScanStatus.Complete));
  assert.equal(hold.pass(scan(MerkletreeScanStatus.Incomplete)), true);
  assert.equal(hold.end(), undefined);
});

test('with two refreshes at once, the Complete waits for both', () => {
  const hold = txidCompleteHold();
  hold.begin();
  hold.begin();
  const complete = scan(MerkletreeScanStatus.Complete);
  hold.pass(complete);
  assert.equal(hold.end(), undefined);
  assert.equal(hold.end(), complete);
  // Held only once.
  hold.begin();
  assert.equal(hold.end(), undefined);
});
