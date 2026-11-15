import assert from 'node:assert/strict';
import { test } from 'node:test';
import { RailgunEngine } from '@railgun-community/engine';
import { throughBatchedTxidReads } from '../engine-hooks-plugin.mjs';
import { txidReads } from '../src/txid-reads.js';
import { BuiltEngine, ENGINE, contents } from './engine-harness.mjs';
import { history, notesStored, txidSync } from './txid-fixture.mjs';

const own = RailgunEngine.prototype.handleNewRailgunTransactionsV2;
const built = BuiltEngine.prototype.handleNewRailgunTransactionsV2;

/** The reads of commitments `merkletree` hears: one at a time, and ranges. */
function countingReads(merkletree) {
  const counted = { one: 0, ranges: 0 };
  const getCommitmentSafe = merkletree.getCommitmentSafe.bind(merkletree);
  const getCommitmentRange = merkletree.getCommitmentRange.bind(merkletree);
  merkletree.getCommitmentSafe = (...args) => {
    counted.one += 1;
    return getCommitmentSafe(...args);
  };
  merkletree.getCommitmentRange = (...args) => {
    counted.ranges += 1;
    return getCommitmentRange(...args);
  };
  return counted;
}

test("the build's txid sync leaves the store exactly as the engine's own, reading commitments a window at a time", async () => {
  const lists = history();
  const ownStore = await notesStored(lists);
  const builtStore = await notesStored(lists);
  const ownReads = countingReads(ownStore.merkletree);
  const builtReads = countingReads(builtStore.merkletree);
  await txidSync(own, ownStore, lists.transactions);
  await txidSync(built, builtStore, lists.transactions);
  assert.deepEqual(contents(builtStore.down), contents(ownStore.down));
  assert.ok(ownReads.one > 100, `${ownReads.one} reads one at a time`);
  assert.deepEqual(builtReads, { one: 0, ranges: 1 });
});

test('a window answers each commitment as a read of its own does, past the end of the tree too', async () => {
  const { merkletree } = await notesStored(history());
  const reads = txidReads(merkletree, [], { window: 7 });
  const length = await merkletree.getTreeLength(0);
  for (let position = 0; position < length + 3; position += 1) {
    assert.deepEqual(
      await reads.commitment(0, position),
      await merkletree.getCommitmentSafe(0, position),
      `commitment ${position}`,
    );
  }
});

test('a commitment the sync changed is read again from the store, never served twice', async () => {
  const { merkletree } = await notesStored(history());
  const reads = txidReads(merkletree, []);
  const first = await reads.commitment(0, 3);
  first.railgunTxid = 'held until its group is taken';
  const again = await reads.commitment(0, 3);
  assert.notEqual(again, first);
  assert.equal(again.railgunTxid, undefined);
});

/**
 * `merkletree`'s store as IndexedDB answers the build's reads: its object store, a transaction each time it is asked
 * for, counted, and the key ranges it takes.
 */
function asIndexedDB(merkletree, down) {
  const transactions = { count: 0 };
  const decoder = new TextDecoder();
  const within = ({ lower, upper }) =>
    [...down.store.keys()].sort().filter((key) => key >= decoder.decode(lower) && key <= decoder.decode(upper));
  const answer = (result) => {
    const request = {};
    setTimeout(() => request.onsuccess?.({ target: request }));
    return Object.assign(request, { result });
  };
  const store = {
    getAllKeys: (range) => answer(within(range).map((key) => new TextEncoder().encode(key))),
    getAll: (range) => answer(within(range).map((key) => down.store.get(key))),
  };
  const db = Object.create(merkletree.db, {
    usesIndexedDB: { value: () => true },
    getIndexedDBStore: {
      value: () => {
        transactions.count += 1;
        return store;
      },
    },
    decode: { value: (value) => JSON.parse(value) },
  });
  const reading = Object.create(merkletree, { db: { value: db } });
  return { reading, transactions };
}

test("a batch's unshield events are read in one IndexedDB transaction, each as the engine reads it", async (t) => {
  // Node has no IndexedDB: its key ranges as the store above reads them.
  globalThis.IDBKeyRange = { bound: (lower, upper) => ({ lower, upper }) };
  t.after(() => delete globalThis.IDBKeyRange);
  const lists = history();
  const { merkletree, down } = await notesStored(lists);
  const { reading, transactions } = asIndexedDB(merkletree, down);
  const unshielding = lists.transactions.filter(({ unshield }) => unshield !== undefined);
  assert.ok(unshielding.length > 5);
  const reads = txidReads(reading, lists.transactions, { batch: 5 });
  for (const { txid } of unshielding) {
    const events = await reads.unshieldEvents(txid);
    assert.ok(events.length > 0);
    assert.deepEqual(events, await merkletree.getAllUnshieldEventsForTxid(txid), txid);
  }
  assert.equal(transactions.count, Math.ceil(unshielding.length / 5));
  // A txid asked again, or one the batch didn't hold, is read as the engine reads it: a transaction of its own.
  const [{ txid }] = unshielding;
  assert.deepEqual(await reads.unshieldEvents(txid), await merkletree.getAllUnshieldEventsForTxid(txid));
  assert.deepEqual(await reads.unshieldEvents(`0x${'ab'.repeat(32)}`), []);
});

test('where the store is not IndexedDB, unshield events are read one transaction at a time, as the engine does', async () => {
  const lists = history();
  const { merkletree } = await notesStored(lists);
  const reads = txidReads(merkletree, lists.transactions);
  const { txid } = lists.transactions.find(({ unshield }) => unshield !== undefined);
  assert.deepEqual(await reads.unshieldEvents(txid), await merkletree.getAllUnshieldEventsForTxid(txid));
});

test('the reads rewrite applies to the pinned engine only', async () => {
  const { readFileSync } = await import('node:fs');
  const path = await import('node:path');
  const source = readFileSync(path.join(ENGINE, 'railgun-engine.js'), 'utf8');
  const handler = /async handleNewRailgunTransactionsV2[\s\S]*?async handleNewRailgunTransactionsV3/.exec(
    throughBatchedTxidReads(source),
  )[0];
  assert.ok(!handler.includes('utxoMerkletree.getCommitmentSafe('));
  assert.ok(!handler.includes('utxoMerkletree.getAllUnshieldEventsForTxid('));
  assert.throws(
    () =>
      throughBatchedTxidReads(source.replace('getCommitmentSafe(tree, position)', 'getCommitmentSafe(tree,position)')),
    /no longer applies/,
  );
});
