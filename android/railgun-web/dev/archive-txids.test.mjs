import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  ByteLength,
  ByteUtils,
  RailgunTransactionVersion,
  calculateRailgunTransactionVerificationHash,
  createRailgunTransactionWithHash,
  getRailgunTransactionID,
} from '@railgun-community/engine';
import { archive } from '../src/archive.js';
import { sequenceOf, transaction } from '../src/archive-records.js';
import {
  ARCHIVE_TRIES,
  installArchiveTxids,
  misrecordedTransaction,
  relistIfMisrecorded,
  withHash,
} from '../src/archive-txids.js';
import { ARCHIVE_OFF_MS, archiveOff, localStore } from '../src/tree-recovery.js';
import { CHAIN, TXIDMerkletree, V2 } from './engine-harness.mjs';
import { ARCHIVE_BASE, archiveServer, blockTime, word } from './history-fixture.mjs';
import { memoryDatabase } from './memory-store.mjs';

const FROM = 14_760_000;
// Far past the fixture, so a list from its start reads the archive.
const FAR = { blockNumber: FROM + 100_000, timestamp: blockTime(FROM + 100_000) };
const hex = (value) => BigInt(value).toString(16).padStart(64, '0');

/**
 * `count` transactions, three to a block, each verification hash continuing the chain: as the archive records them,
 * and as rail-squid lists them.
 */
function transactions(count) {
  const archived = [];
  const listed = [];
  let previous;
  for (let sequence = 0; sequence < count; sequence += 1) {
    const blockNumber = FROM + Math.floor(sequence / 3);
    const record = {
      version: 2,
      sequence,
      commitments: [`0x${word(`c-${sequence}`, 31).padStart(64, '0')}`],
      nullifiers: [`0x${word(`n-${sequence}`, 31).padStart(64, '0')}`],
      boundParamsHash: word(`b-${sequence}`, 31).padStart(64, '0'),
      blockNumber,
      txid: word(`tx-${sequence}`),
      utxoTreeIn: 0,
      utxoTreeOut: 0,
      utxoBatchStartPositionOut: sequence,
      timestamp: blockTime(blockNumber) + 86_400,
    };
    record.verificationHash = calculateRailgunTransactionVerificationHash(previous, record.nullifiers[0]);
    previous = record.verificationHash;
    record.railgunTxid = ByteUtils.nToHex(getRailgunTransactionID(record), ByteLength.UINT_256);
    archived.push(record);
    listed.push({ ...transaction(record, blockTime), graphID: `0x${hex(blockNumber)}${hex(sequence % 3)}${hex(0)}` });
  }
  return { archived, listed };
}

/**
 * The txid source over an archive of `archived` (sealed at `sealedAt`) and rail-squid's `listed`, on an engine that
 * keeps what `keep` lets through of each batch. Answers `next()`, the batch for the engine's next ask, what was kept,
 * what rail-squid was asked, and why the archive was left.
 */
function txidSync({
  archived,
  listed,
  sealedAt = [FROM + 10, FROM + 20],
  batch = 25,
  head = FAR,
  kept = [],
  reading = true,
  useArchive = () => true,
}) {
  const lastBlock = Math.max(
    ...listed.map(({ blockNumber }) => blockNumber),
    ...archived.map(({ blockNumber }) => blockNumber),
  );
  const server = archiveServer(
    { from: FROM, to: lastBlock, archive: { commitments: [], nullifiers: [], unshields: [] } },
    { sealedAt, transactions: archived },
  );
  const asked = [];
  const left = [];
  const batches = [];
  const engine = {
    quickSyncRailgunTransactionsV2: async (_chain, idLow) => {
      asked.push(idLow);
      return listed.filter(({ graphID }) => idLow === undefined || graphID > idLow);
    },
    getTXIDMerkletree: () => ({
      getLatestRailgunTransaction: async () => kept.at(-1),
      getTreeLength: async () => kept.length,
    }),
    validateRailgunTxidMerkleroot: async () => true,
  };
  installArchiveTxids(engine, {
    reader: reading ? archive(ARCHIVE_BASE, 1, { fetch: server.fetch, retryMs: 0 }) : undefined,
    txidVersion: V2,
    chain: CHAIN,
    batchSizes: { archive: batch, squid: 1_000 },
    setBatchSize: (size) => batches.push(size),
    time: (block) => blockTime(block),
    head: async () => head,
    useArchive,
    log: (line) => left.push(line),
  });
  return {
    kept,
    asked,
    left,
    server,
    batches,
    /** The engine asks after what it kept, and keeps `take` of the answer (all of it by default). */
    async next(take = Infinity) {
      const answer = await engine.quickSyncRailgunTransactionsV2(CHAIN, kept.at(-1)?.graphID);
      kept.push(...answer.slice(0, take));
      return answer;
    },
  };
}

const verifications = (list) => list.map(({ verificationHash }) => verificationHash);

test('the archive gives its transactions in sequence, across chunks whose index lists none', async () => {
  const { archived, listed } = transactions(60);
  const sync = txidSync({ archived, listed: listed.slice(0, 60) });
  const first = await sync.next();
  const second = await sync.next();
  assert.equal(first.length, 25);
  assert.deepEqual(
    [...first, ...second].map(({ graphID }) => sequenceOf(graphID)),
    Array.from({ length: 50 }, (_, i) => i),
  );
  assert.deepEqual(sync.asked, [], 'rail-squid not asked while the archive has more');
});

test('when the archive runs out partway through a batch, rail-squid fills the rest from the next transaction', async () => {
  const { archived, listed } = transactions(70);
  // The archive has 60; rail-squid already lists 10 more, the first in the block of the archive's last.
  const sync = txidSync({ archived: archived.slice(0, 60), listed });
  await sync.next();
  await sync.next();
  const third = await sync.next();
  assert.deepEqual(verifications(sync.kept), verifications(listed));
  assert.equal(third.length, 20);
  assert.equal(sequenceOf(third[9].graphID), 59);
  assert.equal(sequenceOf(third[10].graphID), undefined, "rail-squid's own ids from there");
});

test(
  'a transaction missing from the archive breaks the verification hashes: what came before stays, and rail-squid ' +
    'gives the rest',
  async () => {
    const { archived, listed } = transactions(60);
    const sync = txidSync({ archived: archived.filter(({ sequence }) => sequence !== 31), listed });
    await sync.next();
    const second = await sync.next();
    await sync.next();
    assert.match(sync.left[0], /transaction 32 breaks the verification hashes/);
    // 25 to 30 from the archive, mid-block, then rail-squid from 31.
    assert.deepEqual(
      second.slice(0, 6).map(({ graphID }) => sequenceOf(graphID)),
      [25, 26, 27, 28, 29, 30],
    );
    assert.equal(sequenceOf(second[6].graphID), undefined);
    assert.deepEqual(verifications(sync.kept), verifications(listed));
  },
);

test("a gap in the archive's sequence alone, every transaction there and the chain whole, stays on the archive", async () => {
  const { archived, listed } = transactions(60);
  const skipping = archived.map((tx) => (tx.sequence >= 31 ? { ...tx, sequence: tx.sequence + 1 } : tx));
  const sync = txidSync({ archived: skipping, listed });
  await sync.next();
  await sync.next();
  assert.deepEqual(sync.left, []);
  assert.deepEqual(sync.asked, [], 'rail-squid not asked while the archive has more');
  assert.deepEqual(verifications(sync.kept), verifications(listed.slice(0, 50)));
});

test("rail-squid not yet at the archive's last transaction answers nothing, rather than fail the sync", async () => {
  const { archived, listed } = transactions(30);
  // Rail-squid lags: it lists only up to 20.
  const sync = txidSync({ archived, listed: listed.slice(0, 20), batch: 30 });
  await sync.next();
  assert.deepEqual(await sync.next(), []);
  assert.equal(sync.kept.length, 30);
});

test(`a batch the engine kept nothing of is given again, and after ${ARCHIVE_TRIES} times the list goes on from rail-squid`, async () => {
  const { archived, listed } = transactions(60);
  const sync = txidSync({ archived, listed });
  await sync.next();
  // The engine refuses the next batch each time (a root it can't check, say) and keeps nothing of it.
  for (let time = 0; time < ARCHIVE_TRIES; time += 1) {
    const again = await sync.next(0);
    assert.equal(sequenceOf(again[0].graphID), 25, 'the archive gives the batch again');
  }
  const after = await sync.next();
  assert.match(sync.left[0], /kept nothing/);
  assert.equal(sequenceOf(after[0].graphID), undefined, "rail-squid's");
  assert.deepEqual(verifications(after.slice(0, 5)), verifications(listed.slice(25, 30)));
});

test('a batch refused once, its root check cut off with the connection, stays on the archive when kept next time', async () => {
  const { archived, listed } = transactions(80);
  const sync = txidSync({ archived, listed });
  await sync.next();
  await sync.next(0);
  await sync.next();
  const third = await sync.next();
  assert.deepEqual(sync.left, []);
  assert.deepEqual(
    third.map(({ graphID }) => sequenceOf(graphID)),
    Array.from({ length: 25 }, (_, i) => 50 + i),
  );
  assert.deepEqual(sync.asked, []);
});

test("a record the page can't read keeps the ones before it, and rail-squid gives the rest without a gap", async () => {
  const { archived, listed } = transactions(60);
  // An unshield without its recipient, say.
  archived[30] = {
    ...archived[30],
    unshield: { tokenData: { tokenType: 0, tokenAddress: `0x${word('t', 20)}`, tokenSubID: '0' }, value: '5' },
  };
  const sync = txidSync({ archived, listed });
  await sync.next();
  const second = await sync.next();
  await sync.next();
  assert.equal(sync.left.length, 1);
  assert.deepEqual(
    second.slice(0, 5).map(({ graphID }) => sequenceOf(graphID)),
    [25, 26, 27, 28, 29],
  );
  assert.equal(sequenceOf(second[5].graphID), undefined);
  assert.deepEqual(verifications(sync.kept), verifications(listed));
});

test('a record that breaks the verification hashes is never handed to the engine: rail-squid gives it', async () => {
  const { archived, listed } = transactions(60);
  archived[33] = { ...archived[33], verificationHash: word('not the chain') };
  const sync = txidSync({ archived, listed });
  await sync.next();
  const second = await sync.next();
  assert.match(sync.left[0], /verification hashes/);
  assert.deepEqual(
    second.slice(0, 8).map(({ graphID }) => sequenceOf(graphID)),
    [25, 26, 27, 28, 29, 30, 31, 32],
  );
  assert.deepEqual(verifications(sync.kept), verifications(listed.slice(0, 50)));
});

test('a record whose fields the archive got wrong, its railgunTxid right, is synced as any other', async () => {
  // Transaction 33's commitments are off but its railgunTxid, which the root check binds, is right. Whose it is shows
  // only when a wallet proves it (relistIfMisrecorded): a sync that left the archive there would tell it and
  // rail-squid.
  const { archived, listed } = transactions(60);
  archived[33] = { ...archived[33], commitments: [`0x${word('not its output', 31).padStart(64, '0')}`] };
  const sync = txidSync({ archived, listed });
  await sync.next();
  await sync.next();
  assert.deepEqual(sync.left, []);
  assert.deepEqual(sync.asked, []);
  assert.deepEqual(sync.kept[33].commitments, archived[33].commitments);
});

test('after the trees were rebuilt, the list leaves the archive alone and comes from rail-squid', async () => {
  const { archived, listed } = transactions(60);
  const sync = txidSync({ archived, listed, useArchive: () => false });
  await sync.next();
  assert.deepEqual(sync.server.asked, []);
  assert.deepEqual(sync.left, []);
  assert.deepEqual(verifications(sync.kept), verifications(listed));
});

test("the engine's txid batch is the archive's for a batch from it, and rail-squid's otherwise", async () => {
  const { archived, listed } = transactions(60);
  const sync = txidSync({ archived: archived.slice(0, 40), listed });
  await sync.next();
  await sync.next();
  // The archive's full batch, then the one rail-squid finished.
  assert.deepEqual(sync.batches, [25, 1_000]);
});

test('with the archive off, a list an archive sync left goes on from rail-squid without skipping a transaction', async () => {
  const { archived, listed } = transactions(30);
  const sync = txidSync({
    archived,
    listed,
    reading: false,
    kept: archived.slice(0, 5).map((record) => transaction(record, blockTime)),
  });
  await sync.next();
  assert.deepEqual(sync.server.asked, []);
  assert.deepEqual(verifications(sync.kept), verifications(listed));
});

test('a page reopened after a kill goes on in the archive from where its list stopped', async () => {
  const { archived, listed } = transactions(60);
  const first = txidSync({ archived, listed });
  await first.next();
  // A new page over the same store.
  const reopened = txidSync({ archived, listed, kept: [...first.kept] });
  const next = await reopened.next();
  assert.deepEqual(
    next.map(({ graphID }) => sequenceOf(graphID)),
    Array.from({ length: 25 }, (_, i) => 25 + i),
  );
  assert.deepEqual(reopened.asked, []);
});

test('a list rail-squid gave goes on from rail-squid', async () => {
  const { archived, listed } = transactions(30);
  const sync = txidSync({ archived, listed, kept: listed.slice(0, 5) });
  await sync.next();
  assert.deepEqual(sync.asked, [listed[4].graphID]);
  assert.deepEqual(sync.server.asked, []);
});

test("a list within the archive tip's reach of the newest block goes on from rail-squid", async () => {
  const { archived, listed } = transactions(30);
  const head = { blockNumber: FROM + 100, timestamp: blockTime(FROM + 100) };
  const sync = txidSync({ archived, listed, head, kept: [transaction(archived[4], blockTime)] });
  await sync.next();
  assert.deepEqual(sync.server.asked, []);
  assert.deepEqual(verifications(sync.kept.slice(1)), verifications(listed.slice(5)));
});

test("a leaf hashed from the archive's railgunTxid is the engine's own", () => {
  const { archived } = transactions(3);
  const tx = transaction(archived[2], blockTime);
  assert.deepEqual(
    withHash(tx, () => assert.fail('worked out again')),
    createRailgunTransactionWithHash(tx),
  );
  assert.equal(Object.keys(tx).includes('railgunTxid'), false, 'kept out of what the engine stores');
});

test('an unshield from before V2 has its railgunTxid worked out, whatever the archive says', () => {
  const { archived } = transactions(1);
  txidSync({ archived, listed: [] });
  const tx = transaction(
    {
      ...archived[0],
      blockNumber: 15_000_000,
      railgunTxid: word('wrong'),
      unshield: {
        tokenData: { tokenType: 0, tokenAddress: `0x${word('t', 20)}`, tokenSubID: '0' },
        toAddress: `0x${word('to', 20)}`,
        value: '5',
      },
    },
    blockTime,
  );
  assert.equal(tx.version, RailgunTransactionVersion.V2);
  assert.deepEqual(withHash(tx, createRailgunTransactionWithHash), createRailgunTransactionWithHash(tx));
});

/** A txid list holding `records`, as the engine stores them. */
async function txidList(records) {
  const list = await TXIDMerkletree.createForWallet(memoryDatabase().db, CHAIN, V2, async () => true);
  await list.queueRailgunTransactions(records, undefined);
  await list.updateTreesFromWriteQueue();
  return list;
}

test("a send whose record doesn't hash to its railgunTxid is found before proving; one listed right, or not listed, isn't", async () => {
  const { archived } = transactions(3);
  const [right, wrong, archivedRight] = archived.map((record) => transaction(record, blockTime));
  // The archive lists the second with another output, under its right railgunTxid.
  const offRecord = { ...archived[1], commitments: [`0x${word('not its output', 31).padStart(64, '0')}`] };
  const misrecorded = withHash(transaction(offRecord, blockTime), assert.fail);
  const fromArchive = withHash(archivedRight, assert.fail);
  const list = await txidList([createRailgunTransactionWithHash(right), misrecorded, fromArchive]);
  const railgunTxidOf = (tx) => ByteUtils.nToHex(getRailgunTransactionID(tx), ByteLength.UINT_256);
  assert.equal(misrecorded.railgunTxid, railgunTxidOf(wrong));
  assert.equal(await misrecordedTransaction(list, [railgunTxidOf(right), fromArchive.railgunTxid]), undefined);
  assert.equal(
    await misrecordedTransaction(list, [railgunTxidOf(right), misrecorded.railgunTxid]),
    misrecorded.railgunTxid,
  );
  assert.equal(await misrecordedTransaction(list, [word('never listed')]), undefined);
});

const NOW = 1_000_000;
let relists = 0;

/** relistIfMisrecorded over stand-ins, with the list's clear failing `clearFails` times: what it did, in order. */
function relist({ misrecorded, clearFails = 0, store = localStore(`relist-test-${(relists += 1)}`) }) {
  const done = [];
  let fails = clearFails;
  const run = () =>
    relistIfMisrecorded({
      misrecorded: async () => {
        done.push('checked');
        return misrecorded;
      },
      clear: async () => {
        if (fails > 0) {
          fails -= 1;
          throw new Error('the list is syncing');
        }
        done.push('cleared');
      },
      catchUp: async () => {
        done.push('caught up');
      },
      store,
      now: () => NOW,
    });
  return { run, done, store };
}

test('a list with every send to prove listed right is left as it is', async () => {
  const r = relist({ misrecorded: false });
  assert.equal(await r.run(), false);
  assert.deepEqual(r.done, ['checked']);
  assert.ok(!archiveOff(r.store, () => NOW));
});

test('a send listed wrong has the whole list synced again from rail-squid, with the archive off for a week', async () => {
  const r = relist({ misrecorded: true });
  assert.equal(await r.run(), true);
  assert.deepEqual(r.done, ['checked', 'cleared', 'caught up']);
  assert.ok(archiveOff(r.store, () => NOW));
  assert.ok(!archiveOff(r.store, () => NOW + ARCHIVE_OFF_MS));
  assert.equal(r.store.read().relist, undefined);
});

test("a list that can't be cleared yet is cleared at the next proving, without the archive", async () => {
  const r = relist({ misrecorded: true, clearFails: 1 });
  await assert.rejects(r.run(), /the list is syncing/);
  assert.equal(r.store.read().relist, true);
  assert.ok(
    archiveOff(r.store, () => NOW),
    'off before the list is cleared, so no sync takes it from the archive again',
  );
  assert.equal(await r.run(), true);
  assert.deepEqual(r.done, ['checked', 'cleared', 'caught up']);
});

test("with the archive off, a send listed wrong isn't the archive's to blame: the list is left as it is", async () => {
  const store = localStore(`relist-test-${(relists += 1)}`);
  store.write({ archiveOffUntil: NOW + 1 });
  const r = relist({ misrecorded: true, store });
  await assert.rejects(r.run(), /doesn't hash to its railgunTxid/);
  assert.deepEqual(r.done, ['checked']);
});
