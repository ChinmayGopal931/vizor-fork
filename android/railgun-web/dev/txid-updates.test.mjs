import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { RailgunEngine, getEngineTxidSyncBatchSize, setEngineTxidSyncBatchSize } from '@railgun-community/engine';
import { throughArchiveTxids, throughBatchedTxidUpdates } from '../engine-hooks-plugin.mjs';
import * as archiveTxids from '../src/archive-txids.js';
import * as txidUpdates from '../src/txid-updates.js';
import { CHAIN, ENGINE, TXIDMerkletree, V2, builtEngineModule, contents } from './engine-harness.mjs';
import { calculateRailgunTransactionVerificationHash, hex32, history, notesStored, txidSync } from './txid-fixture.mjs';

const pageModule = (file) => fileURLToPath(new URL(`../src/${file}`, import.meta.url));
const { RailgunEngine: BatchedEngine } = builtEngineModule(
  'railgun-engine.js',
  (source) => throughBatchedTxidUpdates(throughArchiveTxids(source)),
  { [pageModule('archive-txids.js')]: archiveTxids, [pageModule('txid-updates.js')]: txidUpdates },
);
const own = RailgunEngine.prototype.handleNewRailgunTransactionsV2;
const batched = BatchedEngine.prototype.handleNewRailgunTransactionsV2;

/** The store each handler leaves after syncing `transactions` over `lists`' notes. */
async function bothSynced(lists, transactions = lists.transactions, options = {}) {
  const ownStore = await notesStored(lists);
  const batchedStore = await notesStored(lists);
  const ownRun = await txidSync(own, ownStore, transactions, options);
  const batchedRun = await txidSync(batched, batchedStore, transactions, options);
  return { ownStore, batchedStore, ownRun, batchedRun };
}

async function withBatchSize(size, run) {
  const before = getEngineTxidSyncBatchSize();
  setEngineTxidSyncBatchSize(size);
  try {
    return await run();
  } finally {
    setEngineTxidSyncBatchSize(before);
  }
}

test("the txid sync's batched updates leave the store exactly as the engine's one at a time do", async () => {
  const lists = history();
  const { ownStore, batchedStore, ownRun, batchedRun } = await bothSynced(lists);
  assert.deepEqual(contents(batchedStore.down), contents(ownStore.down));
  assert.equal(await batchedRun.txidMerkletree.getTreeLength(0), lists.transactions.length);

  // Every transact commitment and unshield event now carries its transaction's railgunTxid.
  const withUnshield = lists.transactions.find(({ unshield }) => unshield !== undefined);
  const [first] = lists.transactions;
  assert.ok((await batchedStore.merkletree.getCommitment(0, first.utxoBatchStartPositionOut)).railgunTxid);
  const [event] = await batchedStore.merkletree.getAllUnshieldEventsForTxid(withUnshield.txid);
  assert.ok(event.railgunTxid);

  // The engine writes each record on its own; the batched sync writes none of them that way.
  const records = lists.commitments.length - lists.transactions.filter(({ unshield }) => unshield).length;
  assert.ok(ownRun.counted.puts >= records, `${ownRun.counted.puts} puts`);
  assert.ok(batchedRun.counted.puts < ownRun.counted.puts - records + 1, `${batchedRun.counted.puts} puts`);
  // Unshield updates still drop the wallets' TXO caches, once their batch is written.
  assert.ok(batchedRun.counted.invalidations > 0);
});

test('with several groups of transactions, each group writes its updates before it goes into the txid tree', async () => {
  const lists = history();
  await withBatchSize(7, async () => {
    const { ownStore, batchedStore, batchedRun } = await bothSynced(lists);
    assert.deepEqual(contents(batchedStore.down), contents(ownStore.down));
    assert.ok(batchedRun.counted.batches >= Math.ceil(lists.transactions.length / 7));
  });
});

test('a transaction whose commitments are not stored yet stops the sync where the engine stops it', async () => {
  const lists = history();
  const missing = {
    ...lists.transactions.at(-1),
    utxoBatchStartPositionOut: lists.commitments.length + 5,
    verificationHash: calculateRailgunTransactionVerificationHash(lists.transactions.at(-1).verificationHash, hex32(1)),
    nullifiers: [hex32(1)],
  };
  const { ownStore, batchedStore, batchedRun } = await bothSynced(lists, [...lists.transactions, missing]);
  assert.deepEqual(contents(batchedStore.down), contents(ownStore.down));
  assert.equal(await batchedRun.txidMerkletree.getTreeLength(0), lists.transactions.length);
});

test('a broken verification hash stops the sync and clears the tree as the engine does, the broken one never written', async () => {
  const lists = history();
  const transactions = lists.transactions.map((transaction, index) =>
    index === 30 ? { ...transaction, verificationHash: hex32(7) } : transaction,
  );
  await withBatchSize(10, async () => {
    const { ownStore, batchedStore, ownRun, batchedRun } = await bothSynced(lists, transactions);
    const length = await batchedRun.txidMerkletree.getTreeLength(0);
    assert.equal(length, await ownRun.txidMerkletree.getTreeLength(0));
    assert.ok(length < 30);
    // The engine's own gave the broken transaction's records its railgunTxid before it checked the chain.
    const broken = transactions[30].utxoBatchStartPositionOut;
    assert.ok((await ownStore.merkletree.getCommitment(0, broken)).railgunTxid);
    assert.equal((await batchedStore.merkletree.getCommitment(0, broken)).railgunTxid, undefined);
    const before = transactions[29].utxoBatchStartPositionOut;
    assert.deepEqual(
      await batchedStore.merkletree.getCommitment(0, before),
      await ownStore.merkletree.getCommitment(0, before),
    );
  });
});

test("a group whose root the screening node refuses leaves its records as they were, where the engine's own wrote them", async () => {
  const lists = history();
  // The node refuses every root: an archive batch with a wrong railgunTxid, say.
  const { ownStore, batchedStore, batchedRun } = await bothSynced(lists, lists.transactions, { accepted: () => false });
  assert.equal(await batchedRun.txidMerkletree.getTreeLength(0), 0);
  const [first] = lists.transactions;
  assert.ok(
    (await ownStore.merkletree.getCommitment(0, first.utxoBatchStartPositionOut)).railgunTxid,
    'the engine wrote it anyway',
  );
  for (let position = 0; position < lists.commitments.length; position += 1) {
    assert.equal(
      (await batchedStore.merkletree.getCommitment(0, position)).railgunTxid,
      undefined,
      `commitment ${position}`,
    );
  }
  const withUnshield = lists.transactions.find(({ unshield }) => unshield !== undefined);
  const [event] = await batchedStore.merkletree.getAllUnshieldEventsForTxid(withUnshield.txid);
  assert.equal(event.railgunTxid, undefined);
});

test('records go in before their transactions do: a sync cut off between the two ends, next time, as an unbroken one', async () => {
  const lists = history();
  const harness = await notesStored(lists);
  const txidMerkletree = await TXIDMerkletree.createForWallet(harness.db, CHAIN, V2, async () => true);
  const write = txidMerkletree.writeTreeToDB.bind(txidMerkletree);
  txidMerkletree.writeTreeToDB = async () => {
    // The page closes as the first group is written, its records already in.
    txidMerkletree.writeTreeToDB = write;
    throw new Error('closed');
  };
  await txidSync(batched, harness, lists.transactions, { txidMerkletree });
  assert.equal(await txidMerkletree.getTreeLength(0), 0);
  // The next sync starts again from the newest transaction stored: none.
  await txidSync(batched, harness, lists.transactions, { txidMerkletree });
  const { ownStore } = await bothSynced(lists);
  assert.deepEqual(contents(harness.down), contents(ownStore.down));
});

test('the rewrite applies to the pinned engine only, and keeps its txid hashing', async () => {
  const source = await import('node:fs').then(({ readFileSync }) =>
    readFileSync(path.join(ENGINE, 'railgun-engine.js'), 'utf8'),
  );
  const rewritten = throughBatchedTxidUpdates(throughArchiveTxids(source));
  const handler = /async handleNewRailgunTransactionsV2[\s\S]*?async handleNewRailgunTransactionsV3/.exec(rewritten)[0];
  assert.ok(!handler.includes('utxoMerkletree.updateData('));
  assert.ok(!handler.includes('utxoMerkletree.updateUnshieldEvent('));
  assert.ok(!handler.includes('utxoMerkletree.addUnshieldEvents('));
  assert.ok(handler.includes('txidUpdates.settle()'));
  assert.ok(handler.includes('archive-txids.js'));
  assert.throws(
    () => throughBatchedTxidUpdates(source.replace('let toQueue = [];', 'let toQueue = [] ;')),
    /no longer applies/,
  );
});
