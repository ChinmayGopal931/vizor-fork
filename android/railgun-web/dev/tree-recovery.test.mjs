import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  ARCHIVE_OFF_MS,
  REBUILD_AFTER_MS,
  REBUILD_EVERY_MS,
  archiveOff,
  localStore,
  treeRecovery,
} from '../src/tree-recovery.js';

const MINUTE = 60_000;
let stores = 0;

/** A recovery whose tree checks answer `answers` in turn, on a clock the test moves; counts its rebuilds. */
function recovery(answers) {
  let clock = 1_000_000;
  const store = localStore(`tree-recovery-test-${(stores += 1)}`);
  const rebuilds = [];
  const check = treeRecovery({
    firstInvalidTree: async () => {
      const answer = answers.shift();
      if (answer instanceof Error) throw answer;
      return answer;
    },
    rebuild: async () => {
      rebuilds.push(clock);
      assert.ok(archiveOff(store, () => clock), 'the archive is off before the rebuild starts');
    },
    store,
    now: () => clock,
  });
  return {
    store,
    rebuilds,
    /** Checks after a broken scan, `minutes` after the last one. */
    async after(minutes) {
      clock += minutes * MINUTE;
      return check();
    },
    now: () => clock,
  };
}

const wrong = { tree: 3, root: 'aa' };

test('a tree whose root fails three times over ten minutes is rebuilt, with the archive off for a week', async () => {
  const r = recovery([wrong, wrong, wrong]);
  assert.equal(await r.after(0), false);
  assert.equal(await r.after(5), false);
  assert.equal(await r.after(5), true);
  assert.equal(r.rebuilds.length, 1);
  assert.ok(archiveOff(r.store, r.now));
  assert.ok(!archiveOff(r.store, () => r.now() + ARCHIVE_OFF_MS));
});

test('a root an RPC catches up to never rebuilds: a check that finds every root starts the count again', async () => {
  const r = recovery([wrong, wrong, null, wrong, wrong]);
  for (const minutes of [0, 6, 6, 6, 6]) assert.equal(await r.after(minutes), false);
  assert.equal(r.rebuilds.length, 0);
});

test('three quick failures wait out the ten minutes, and a check that can tell nothing counts for nothing', async () => {
  const r = recovery([wrong, new Error('no answer'), wrong, wrong, wrong]);
  for (const minutes of [0, 1, 1, 1]) assert.equal(await r.after(minutes), false);
  assert.equal(await r.after(REBUILD_AFTER_MS / MINUTE), true);
});

test('another tree or root starts the count again', async () => {
  const r = recovery([wrong, { tree: 3, root: 'bb' }, wrong, wrong]);
  for (const minutes of [0, 6, 6, 6]) assert.equal(await r.after(minutes), false);
  assert.equal(r.rebuilds.length, 0);
});

test('the trees are rebuilt at most once a day', async () => {
  const r = recovery([wrong, wrong, wrong, wrong, wrong, wrong, wrong]);
  for (const minutes of [0, 5, 5]) await r.after(minutes);
  assert.equal(r.rebuilds.length, 1);
  for (const minutes of [10, 10, 10]) assert.equal(await r.after(minutes), false);
  assert.equal(r.rebuilds.length, 1);
  assert.equal(await r.after(REBUILD_EVERY_MS / MINUTE), true);
  assert.equal(r.rebuilds.length, 2);
});
