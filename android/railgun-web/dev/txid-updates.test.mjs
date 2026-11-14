import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  RailgunEngine,
  RailgunTransactionVersion,
  getEngineTxidSyncBatchSize,
  setEngineTxidSyncBatchSize,
} from '@railgun-community/engine';
import { throughArchiveTxids, throughBatchedTxidUpdates } from '../engine-hooks-plugin.mjs';
import * as archiveTxids from '../src/archive-txids.js';
import { formatCommitments, formatUnshields } from '../src/quick-sync.js';
import * as txidUpdates from '../src/txid-updates.js';
import { CHAIN, ENGINE, V2, builtEngineModule, contents, engineHarness } from './engine-harness.mjs';

const require = createRequire(import.meta.url);
const { TXIDMerkletree } = require(path.join(ENGINE, 'merkletree/txid-merkletree'));
const { calculateRailgunTransactionVerificationHash } = require(path.join(ENGINE, 'transaction/railgun-txid'));

const pageModule = (file) => fileURLToPath(new URL(`../src/${file}`, import.meta.url));
const { RailgunEngine: BatchedEngine } = builtEngineModule(
  'railgun-engine.js',
  (source) => throughBatchedTxidUpdates(throughArchiveTxids(source)),
  { [pageModule('archive-txids.js')]: archiveTxids, [pageModule('txid-updates.js')]: txidUpdates },
);
const own = RailgunEngine.prototype.handleNewRailgunTransactionsV2;
const batched = BatchedEngine.prototype.handleNewRailgunTransactionsV2;

const word = (seed, bytes = 32) => createHash('sha256').update(String(seed)).digest('hex').slice(0, bytes * 2);
const hex32 = (value) => `0x${BigInt(value).toString(16).padStart(64, '0')}`;

/**
 * Railgun V2 history from block `from`, as rail-squid lists it, and the transactions of Railgun's txid list for it:
 * one per commitment batch, the first batch of a block that unshields carrying that unshield as its last commitment.
 */
function history({ from = 16_100_000, blocks = 60 } = {}) {
  const commitments = [];
  const unshields = [];
  const batches = [];
  let position = 0;
  for (let block = from; block < from + blocks; block += 1) {
    if (block % 5 === 0) {
      unshields.push({
        id: `u-${block}`,
        blockNumber: String(block),
        to: `0x${word(`to-${block}`, 20)}`,
        transactionHash: word(`tx-${block}-0`),
        fee: '25',
        blockTimestamp: String(1_670_000_000 + block * 12),
        amount: String(10_000 + block),
        eventLogIndex: block % 7,
        token: { id: 't', tokenType: 'ERC20', tokenSubID: '0x00', tokenAddress: `0x${word('token', 20)}` },
      });
    }
    for (let batch = 0; batch < 1 + (block % 3); batch += 1) {
      const transactionHash = word(`tx-${block}-${batch}`);
      const start = position;
      const hashes = [];
      for (let i = 0; i < 1 + ((block + batch) % 3); i += 1) {
        const hash = BigInt(`0x${word(`leaf-${position}`, 31)}`).toString();
        hashes.push(hash);
        commitments.push({
          id: `c-${position}`,
          treeNumber: 0,
          batchStartTreePosition: start,
          treePosition: position,
          blockNumber: String(block),
          transactionHash,
          blockTimestamp: String(1_670_000_000 + block * 12),
          commitmentType: 'TransactCommitment',
          hash,
          ciphertext: {
            ciphertext: { iv: word(`iv-${position}`, 16), tag: word(`tag-${position}`, 16), data: [word(`d0-${position}`)] },
            blindedReceiverViewingKey: word(`r-${position}`),
            blindedSenderViewingKey: word(`s-${position}`),
            memo: '0x',
            annotationData: `0x${word(`a-${position}`, 8)}`,
          },
        });
        position += 1;
      }
      batches.push({ block, batch, transactionHash, start, hashes });
    }
  }
  const stored = formatUnshields(unshields);
  const transactions = [];
  let previous;
  for (const { block, batch, transactionHash, start, hashes } of batches) {
    const nullifiers = [hex32(`0x${word(`nullifier-${start}`, 31)}`)];
    const event = batch === 0 ? stored.find(({ txid }) => txid.endsWith(transactionHash)) : undefined;
    const verificationHash = calculateRailgunTransactionVerificationHash(previous, nullifiers[0]);
    previous = verificationHash;
    transactions.push({
      version: RailgunTransactionVersion.V2,
      graphID: `0x${word(`g-${start}`)}`,
      commitments: hashes.map(hex32),
      nullifiers,
      boundParamsHash: hex32(`0x${word(`bp-${start}`, 31)}`),
      blockNumber: block,
      timestamp: 1_670_000_000 + block * 12,
      txid: transactionHash,
      utxoTreeIn: 0,
      utxoTreeOut: 0,
      utxoBatchStartPositionOut: start,
      unshield: event && {
        tokenData: { tokenType: event.tokenType, tokenAddress: event.tokenAddress, tokenSubID: event.tokenSubID },
        toAddress: event.toAddress,
        value: (BigInt(event.amount) + BigInt(event.fee)).toString(),
      },
      verificationHash,
    });
  }
  return { commitments, unshields, transactions };
}

/** A store holding `lists`' notes as the engine's quick sync stores them, with no railgunTxid on any record. */
async function notesStored(lists) {
  const harness = await engineHarness();
  await harness.engine.unshieldListener(V2, CHAIN, formatUnshields(lists.unshields));
  await harness.engine.commitmentListener(V2, CHAIN, formatCommitments(lists.commitments), false, false);
  await harness.merkletree.updateTreesFromWriteQueue(true);
  return harness;
}

/** Runs the engine's V2 txid sync (`handler`) over `transactions` on `harness`'s store, counting its writes. */
async function txidSync(handler, harness, transactions) {
  const txidMerkletree = await TXIDMerkletree.createForWallet(harness.db, CHAIN, V2, async () => true);
  const counted = { puts: 0, batches: 0, invalidations: 0 };
  const { db } = harness;
  const put = db.put.bind(db);
  const batch = db.batch.bind(db);
  db.put = (...args) => {
    counted.puts += 1;
    return put(...args);
  };
  db.batch = (...args) => {
    counted.batches += 1;
    return batch(...args);
  };
  const engine = {
    isPOINode: false,
    getUTXOMerkletree: () => harness.merkletree,
    getTXIDMerkletree: () => txidMerkletree,
    getLatestValidatedTxidIndex: async () => undefined,
    shouldAddNewRailgunTransactions: async () => true,
    emitTXIDMerkletreeScanUpdateEvent() {},
    invalidateTXOsCacheAllWallets() {
      counted.invalidations += 1;
    },
  };
  try {
    await handler.call(engine, V2, CHAIN, transactions, undefined, 0, 1);
  } finally {
    db.put = put;
    db.batch = batch;
  }
  return { counted, txidMerkletree };
}

/** The store each handler leaves after syncing `transactions` over `lists`' notes. */
async function bothSynced(lists, transactions = lists.transactions) {
  const ownStore = await notesStored(lists);
  const batchedStore = await notesStored(lists);
  const ownRun = await txidSync(own, ownStore, transactions);
  const batchedRun = await txidSync(batched, batchedStore, transactions);
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

test('a broken verification hash stops the sync and clears the tree as the engine does', async () => {
  const lists = history();
  const transactions = lists.transactions.map((transaction, index) =>
    index === 30 ? { ...transaction, verificationHash: hex32(7) } : transaction,
  );
  await withBatchSize(10, async () => {
    const { ownStore, batchedStore, batchedRun } = await bothSynced(lists, transactions);
    assert.deepEqual(contents(batchedStore.down), contents(ownStore.down));
    assert.ok((await batchedRun.txidMerkletree.getTreeLength(0)) < 30);
  });
});

test('the rewrite applies to the pinned engine only, and keeps its txid hashing', async () => {
  const source = await import('node:fs').then(({ readFileSync }) => readFileSync(path.join(ENGINE, 'railgun-engine.js'), 'utf8'));
  const rewritten = throughBatchedTxidUpdates(throughArchiveTxids(source));
  const handler = /async handleNewRailgunTransactionsV2[\s\S]*?async handleNewRailgunTransactionsV3/.exec(rewritten)[0];
  assert.ok(!handler.includes('utxoMerkletree.updateData('));
  assert.ok(!handler.includes('utxoMerkletree.updateUnshieldEvent('));
  assert.ok(handler.includes('archive-txids.js'));
  assert.throws(() => throughBatchedTxidUpdates(source.replace('let toQueue = [];', 'let toQueue = [] ;')), /no longer applies/);
});
