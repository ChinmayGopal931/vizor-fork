import assert from 'node:assert/strict';
import { test } from 'node:test';
import { catchUpTxids } from '../src/txid-catch-up.js';

// No validated index: the catch-up ends at the first sync that adds nothing.
const target = async () => undefined;

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
    target,
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

test('it stops after its passes, and fails if they ran out short of the validated index', async () => {
  const txids = tree({ at: 10_000, adds: Array(10).fill(10_000) });
  await catchUpTxids({ ...txids, before: 0, passes: 3 });
  assert.deepEqual(txids.log, ['sync', 'sync', 'sync']);
  const short = tree({ at: 10_000, adds: Array(10).fill(10_000) });
  await assert.rejects(
    catchUpTxids({ ...short, before: 0, passes: 3, target: async () => 151_000 }),
    /stopped at 40000 of 151000 after 3/,
  );
});

test('a sync that adds nothing short of the validated index is tried again, and the catch-up goes on', async () => {
  // A dropped connection failed the sync after 40,000: the next attempts reach the screening nodes again.
  const txids = tree({ at: 40_000, adds: [0, 5_000, 5_000, 0] });
  const waits = [];
  await catchUpTxids({
    ...txids,
    before: 35_000,
    passes: 50,
    target: async () => 50_000,
    retries: 3,
    retryWait: async (n) => waits.push(n),
  });
  assert.equal(await txids.latest(), 50_000);
  assert.deepEqual(waits, [1]);
});

test('a list that never moves though more is validated fails the catch-up after its retries', async () => {
  const txids = tree({ at: 40_000, adds: [0, 0, 0, 0, 0] });
  const waits = [];
  await assert.rejects(
    catchUpTxids({
      ...txids,
      before: 35_000,
      passes: 50,
      target: async () => 151_000,
      retries: 3,
      retryWait: async (n) => waits.push(n),
    }),
    /stopped at 40000 of 151000/,
  );
  assert.deepEqual(waits, [1, 2, 3]);
  assert.equal(txids.log.filter((entry) => entry === 'sync').length, 4);
});

test('a validated index reached, or none validated, ends the catch-up at the first sync that adds none', async () => {
  for (const goal of [async () => 40_000, async () => undefined]) {
    const txids = tree({ at: 40_000, adds: [0] });
    await catchUpTxids({
      ...txids,
      before: 35_000,
      passes: 50,
      target: goal,
      retries: 3,
      retryWait: async () => assert.fail('no retry'),
    });
    assert.deepEqual(txids.log, ['sync']);
  }
});

test("a validated index that can't be read, the connection down, is tried again like a stall, then fails the catch-up", async () => {
  // The read goes the way the sync's root check went; both are back by the second retry.
  let reads = 0;
  const flaky = async () => {
    reads += 1;
    if (reads <= 2) throw new Error('offline');
    return 50_000;
  };
  const txids = tree({ at: 40_000, adds: [0, 0, 10_000, 0] });
  const waits = [];
  await catchUpTxids({
    ...txids,
    before: 35_000,
    passes: 50,
    target: flaky,
    retries: 3,
    retryWait: async (n) => waits.push(n),
  });
  assert.equal(await txids.latest(), 50_000);
  assert.deepEqual(waits, [1, 2]);
  const down = tree({ at: 40_000, adds: [0, 0, 0, 0] });
  await assert.rejects(
    catchUpTxids({
      ...down,
      before: 35_000,
      passes: 50,
      target: async () => Promise.reject(new Error('offline')),
      retries: 3,
      retryWait: async () => {},
    }),
    /can't be read: offline/,
  );
});

test('it waits out a sync the engine started itself before counting, and never syncs beside it', async () => {
  const txids = tree({ at: 10_000, adds: [0], busy: 2 });
  await catchUpTxids({ ...txids, before: 0, passes: 50 });
  assert.deepEqual(txids.log, ['wait', 'wait', 'sync']);
});
