import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { getEngineTxidSyncBatchSize, setEngineTxidSyncBatchSize } from '@railgun-community/engine';
import { throughTxidRootRefusals, throughTxidStops } from '../engine-hooks-plugin.mjs';
import { archiveOff, localStore } from '../src/tree-recovery.js';
import {
  CLEAR_EVERY_MS,
  REPAIR_AFTER_MS,
  REWIND_STEP,
  changeTxidList,
  forgettingStops,
  listStopped,
  rereadFrom,
  rewindPoint,
  takeListStop,
  txidRepair,
} from '../src/txid-repair.js';
import { BuiltEngine, CHAIN, ENGINE, TXIDMerkletree, V2 } from './engine-harness.mjs';
import { calculateRailgunTransactionVerificationHash, hex32, history, notesStored, txidSync } from './txid-fixture.mjs';

const MINUTE = 60_000;
let stores = 0;

/** A repair on a clock the test moves, its actions logged; idle unless `busy()`, clearing with `clear()`. */
function repairing({
  busy = () => false,
  store = localStore(`txid-repair-test-${(stores += 1)}`),
  clear = async () => {},
} = {}) {
  let clock = 1_000_000;
  const actions = [];
  const repair = txidRepair({
    store,
    now: () => clock,
    idle: () => !busy(),
    rewind: async (point) => actions.push(['rewind', point]),
    clear: async () => {
      actions.push(['clear']);
      await clear();
    },
    reread: async (from, through) => actions.push(['reread', from, through]),
  });
  return {
    store,
    actions,
    repair,
    later: (minutes) => {
      clock += minutes * MINUTE;
    },
    now: () => clock,
    /** The list stopping at `index` for `reason` `minutes` after the last time. */
    stopped(minutes, index, reason, block = 16_234_567) {
      clock += minutes * MINUTE;
      return repair.stopped(index, reason === undefined ? undefined : { reason, block });
    },
  };
}

const STOP = 143_174;

test('a list that stops at one transaction for a refused root three times over ten minutes is rewound', async () => {
  const run = repairing();
  assert.equal(await run.stopped(0, STOP, 'root'), 'counted');
  assert.equal(await run.stopped(5, STOP, 'root'), 'counted');
  assert.equal(await run.stopped(5, STOP, 'root'), 'rewound');
  assert.deepEqual(run.actions, [['rewind', 139_999]]);
  assert.ok(archiveOff(run.store, run.now), 'synced again from rail-squid alone');
});

test('three quick stops wait out the ten minutes, and another transaction or reason starts the count again', async () => {
  const run = repairing();
  for (const minutes of [0, 1, 1, 1]) assert.equal(await run.stopped(minutes, STOP, 'root'), 'counted');
  assert.equal(await run.stopped(REPAIR_AFTER_MS / MINUTE, STOP + 1, 'root'), 'counted');
  assert.equal(await run.stopped(REPAIR_AFTER_MS / MINUTE, STOP + 1, 'verification'), 'counted');
  assert.deepEqual(run.actions, []);
});

test('a stop with no reason, a root check cut off with the connection say, counts for nothing', async () => {
  const run = repairing();
  for (let check = 0; check < 5; check += 1) assert.equal(await run.stopped(5, STOP, undefined), 'left');
  assert.equal(await run.stopped(5, STOP, 'root'), 'counted', 'the count starts with the first stop that says why');
  assert.deepEqual(run.actions, []);
});

test('a list rewound that stops at the same transaction again is cleared, then caught up from the start', async () => {
  const run = repairing();
  for (const minutes of [0, 5, 5]) await run.stopped(minutes, STOP, 'root');
  for (const minutes of [5, 5]) assert.equal(await run.stopped(minutes, STOP, 'root'), 'counted');
  assert.equal(await run.stopped(5, STOP, 'root'), 'cleared');
  assert.deepEqual(run.actions, [['rewind', 139_999], ['clear']]);
  assert.deepEqual(run.store.read().txidClear.cleared, true);
  run.later(15);
  run.repair.passed();
  assert.equal(run.store.read().txidClearedAt, run.now(), "the day between clears counts from the list's catching up");
});

test('a list is cleared at most once a day, counted across page restarts', async () => {
  const store = localStore(`txid-repair-test-${(stores += 1)}`);
  const first = repairing({ store });
  for (let check = 0; check < 6; check += 1) await first.stopped(5, STOP, 'root');
  first.repair.passed();
  assert.deepEqual(first.actions, [['rewind', 139_999], ['clear']]);
  // The same list stops at the same place again: a page that reopened reads the day from the store.
  const reopened = repairing({ store });
  reopened.later((first.now() - reopened.now()) / MINUTE + 60);
  for (let check = 0; check < 6; check += 1) await reopened.stopped(5, STOP, 'root');
  assert.deepEqual(reopened.actions, [['rewind', 139_999]], 'rewound, but not cleared within the day');
  reopened.later(CLEAR_EVERY_MS / MINUTE);
  for (let check = 0; check < 3; check += 1) await reopened.stopped(5, STOP, 'root');
  assert.deepEqual(reopened.actions, [['rewind', 139_999], ['clear']]);
});

test('a clear a closed page left unfinished is done again before the next catch-up', async () => {
  const store = localStore(`txid-repair-test-${(stores += 1)}`);
  const first = repairing({
    store,
    clear: async () => {
      throw new Error('the page closed');
    },
  });
  store.write({ txidRewound: STOP, txidStall: { index: STOP, reason: 'root', since: 0, checks: 9 } });
  await assert.rejects(first.stopped(30, STOP, 'root'), /closed/);
  assert.equal(store.read().txidClear.cleared, false);
  const reopened = repairing({ store });
  await reopened.repair.resume();
  assert.deepEqual(reopened.actions, [['clear']]);
  assert.equal(store.read().txidClear.cleared, true);
  await reopened.repair.resume();
  assert.deepEqual(reopened.actions, [['clear']], 'once');
});

test('nothing is repaired while the notes or the list sync, and the count stands for the next stop', async () => {
  let scanning = true;
  const run = repairing({ busy: () => scanning });
  for (const minutes of [0, 5]) await run.stopped(minutes, STOP, 'root');
  assert.equal(await run.stopped(5, STOP, 'root'), 'busy');
  assert.deepEqual(run.actions, []);
  scanning = false;
  assert.equal(await run.stopped(1, STOP, 'root'), 'rewound');
});

test("an unshield the notes lack has rail-squid's unshields read again from the boundary below it, once", async () => {
  const run = repairing();
  for (const minutes of [0, 5]) await run.stopped(minutes, STOP, 'unshield');
  assert.equal(await run.stopped(5, STOP, 'unshield'), 'reread');
  assert.deepEqual(run.actions, [['reread', 16_200_000, 16_234_567]]);
  for (const minutes of [5, 5, 5]) await run.stopped(minutes, STOP, 'unshield');
  assert.equal(await run.stopped(5, STOP, 'unshield'), 'left');
  assert.equal(run.actions.length, 1);
});

test('a transaction that breaks the verification hashes turns the archive off; with it off, the list is left', async () => {
  const run = repairing();
  for (const minutes of [0, 5]) await run.stopped(minutes, STOP, 'verification');
  assert.equal(await run.stopped(5, STOP, 'verification'), 'archive off');
  assert.ok(archiveOff(run.store, run.now));
  for (const minutes of [5, 5]) await run.stopped(minutes, STOP, 'verification');
  assert.equal(await run.stopped(5, STOP, 'verification'), 'left');
  assert.deepEqual(run.actions, []);
});

test('a commitment the notes lack is left to the next notes scan', async () => {
  const run = repairing();
  for (const minutes of [0, 5, 5, 5]) assert.equal(await run.stopped(minutes, STOP, 'commitment'), 'left');
  assert.deepEqual(run.actions, []);
});

test('a catch-up that reaches the validated index ends the count and the rewind', async () => {
  const run = repairing();
  for (const minutes of [0, 5, 5]) await run.stopped(minutes, STOP, 'root');
  run.repair.passed();
  assert.equal(run.store.read().txidStall, undefined);
  assert.equal(run.store.read().txidRewound, undefined);
  for (const minutes of [5, 5, 5]) await run.stopped(minutes, STOP, 'root');
  assert.deepEqual(
    run.actions,
    [
      ['rewind', 139_999],
      ['rewind', 139_999],
    ],
    'a later stop there is rewound again',
  );
});

test("why the list stopped is its last sync's to say, never an earlier one's", async () => {
  takeListStop();
  let stopsEachTime = true;
  const sync = forgettingStops(async () => {
    if (stopsEachTime) listStopped('root', undefined);
  });
  await sync();
  stopsEachTime = false;
  await sync();
  assert.equal(takeListStop(), undefined, 'the second sync stopped for no reason it gave');
});

test('a rewind or clear that throws leaves the list unmarked, as the engine leaves it marked syncing', async () => {
  const list = { isScanning: false };
  await assert.rejects(
    changeTxidList(list, async () => {
      list.isScanning = true;
      throw new Error('IndexedDB refused the delete');
    }),
    /refused/,
  );
  assert.equal(list.isScanning, false);
  assert.equal(await changeTxidList(list, async () => 'done'), 'done');
  // A list already marked (a clear or a sync under way) keeps its owner's mark when the step refuses to start.
  list.isScanning = true;
  await assert.rejects(
    changeTxidList(list, async () => {
      throw new Error('Full reset of txids already in progress.');
    }),
    /in progress/,
  );
  assert.equal(list.isScanning, true);
});

test('every boundary is fixed: the same for each wallet a list stops for', () => {
  assert.equal(rewindPoint(STOP), 139_999);
  assert.equal(rewindPoint(140_000), 139_999);
  assert.equal(rewindPoint(139_999), 129_999);
  assert.equal(rewindPoint(REWIND_STEP - 1), -1);
  assert.equal(rereadFrom(16_234_567), 16_200_000);
  assert.equal(rereadFrom(16_200_000), 16_200_000);
});

test('a list stopped before the first boundary is cleared rather than rewound', async () => {
  const run = repairing();
  for (const minutes of [0, 5]) await run.stopped(minutes, 1_234, 'root');
  assert.equal(await run.stopped(5, 1_234, 'root'), 'cleared');
  assert.deepEqual(run.actions, [['clear']]);
});

// The engine's own txid sync, as the build bundles it, over the txid fixture.
const handler = BuiltEngine.prototype.handleNewRailgunTransactionsV2;

test('the build has the txid sync say why it stopped, and the block of the transaction it stopped at', async () => {
  const lists = history();
  takeListStop();
  await txidSync(handler, await notesStored(lists), lists.transactions);
  assert.equal(takeListStop(), undefined, 'a list that takes every transaction stops for nothing');

  await txidSync(handler, await notesStored(lists), lists.transactions, { accepted: () => false });
  assert.equal(takeListStop()?.reason, 'root');

  const broken = lists.transactions.map((transaction, index) =>
    index === 30 ? { ...transaction, verificationHash: hex32(7) } : transaction,
  );
  await txidSync(handler, await notesStored(lists), broken);
  assert.deepEqual(takeListStop(), { reason: 'verification', block: broken[30].blockNumber });

  const unstored = lists.transactions.at(-1);
  const missing = {
    ...unstored,
    utxoBatchStartPositionOut: lists.commitments.length + 5,
    verificationHash: calculateRailgunTransactionVerificationHash(unstored.verificationHash, hex32(1)),
    nullifiers: [hex32(1)],
  };
  await txidSync(handler, await notesStored(lists), [...lists.transactions, missing]);
  assert.deepEqual(takeListStop(), { reason: 'commitment', block: missing.blockNumber });

  const withUnshield = lists.transactions.findIndex(({ unshield }) => unshield !== undefined);
  const notesWithoutIt = { ...lists, unshields: lists.unshields.slice(1) };
  await txidSync(handler, await notesStored(notesWithoutIt), lists.transactions);
  assert.deepEqual(takeListStop(), { reason: 'unshield', block: lists.transactions[withUnshield].blockNumber });
});

test("a root check cut off with the connection isn't a refusal: it says nothing of why", async () => {
  const lists = history();
  takeListStop();
  await txidSync(handler, await notesStored(lists), lists.transactions, {
    accepted: () => {
      throw new Error('the screening node did not answer');
    },
  }).catch(() => {});
  assert.equal(takeListStop(), undefined);
});

test('a stored entry the screening node never takes a root with is mended by a rewind and a sync', async () => {
  const lists = history();
  const right = lists.transactions;
  // The node's roots, one after each transaction of the right list.
  const roots = new Map();
  const before = getEngineTxidSyncBatchSize();
  setEngineTxidSyncBatchSize(1);
  try {
    await txidSync(handler, await notesStored(lists), right, {
      accepted: (_version, _chain, _tree, index, root) => roots.set(index, root),
    });
  } finally {
    setEngineTxidSyncBatchSize(before);
  }
  // An entry stored wrong, its group taken when it was written: say the screening node's history moved since.
  const harness = await notesStored(lists);
  let node = () => true;
  const txidMerkletree = await TXIDMerkletree.createForWallet(harness.db, CHAIN, V2, async (...args) => node(...args));
  const wrong = right.map((transaction, index) =>
    index === 50 ? { ...transaction, boundParamsHash: hex32(9) } : transaction,
  );
  await txidSync(handler, harness, wrong.slice(0, 55), { txidMerkletree });
  const stuck = await txidMerkletree.getCurrentTxidIndex();
  assert.equal(stuck, 54);
  node = (_version, _chain, _tree, index, root) => roots.get(index) === root;
  for (let check = 0; check < 3; check += 1) {
    takeListStop();
    const verificationHash = right[54].verificationHash;
    await txidSync(handler, harness, right.slice(55), { txidMerkletree, verificationHash });
    assert.equal(await txidMerkletree.getCurrentTxidIndex(), stuck, 'every sync stops at the same transaction');
    assert.equal(takeListStop()?.reason, 'root');
  }
  // The rewind drops the entry and those after it; the sync takes the right ones.
  await txidMerkletree.clearLeavesAfterTxidIndex(39);
  const verificationHash = right[39].verificationHash;
  await txidSync(handler, harness, right.slice(40), { txidMerkletree, verificationHash });
  assert.equal(await txidMerkletree.getCurrentTxidIndex(), right.length - 1);
  assert.equal(await txidMerkletree.getRoot(0), roots.get(right.length - 1));
});

test("the build's stop reports apply to the pinned engine only", () => {
  const read = (file) => readFileSync(path.join(ENGINE, file), 'utf8');
  const engine = throughTxidStops(read('railgun-engine.js'));
  assert.equal(engine.match(/listStopped\('/g).length, 3);
  assert.equal(throughTxidRootRefusals(read('merkletree/txid-merkletree.js')).match(/listStopped\('/g).length, 1);
  assert.throws(
    () =>
      throughTxidStops(
        read('railgun-engine.js').replace('missingAnyCommitments = true;', 'missingAnyCommitments = 1;'),
      ),
    /no longer applies/,
  );
  assert.throws(() => throughTxidRootRefusals('class TXIDMerkletree {}'), /no longer applies/);
  listStopped('root', undefined);
  assert.deepEqual(takeListStop(), { reason: 'root', block: undefined });
  assert.equal(takeListStop(), undefined);
});

test('the txid merkletree the harness builds reports refusals as the bundle does', () => {
  assert.match(TXIDMerkletree.prototype.invalidRootCallback.toString(), /listStopped\('root'/);
  assert.equal(CHAIN.id, 1);
  assert.equal(V2, 'V2_PoseidonMerkle');
});
