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
import { ARCHIVE_TRIES, installArchiveTxids, withHash } from '../src/archive-txids.js';
import { CHAIN, V2 } from './engine-harness.mjs';
import { ARCHIVE_BASE, archiveServer, blockTime, word } from './history-fixture.mjs';

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
  mine = new Set(),
}) {
  const lastBlock = Math.max(...listed.map(({ blockNumber }) => blockNumber), ...archived.map(({ blockNumber }) => blockNumber));
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
    getTXIDMerkletree: () => ({ getLatestRailgunTransaction: async () => kept.at(-1), getTreeLength: async () => kept.length }),
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
    ownNullifiers: async () => mine,
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

test("the archive gives its transactions in sequence, across chunks whose index lists none", async () => {
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

test("a gap in the archive's sequence keeps what came before it, and rail-squid gives the rest", async () => {
  const { archived, listed } = transactions(60);
  const sync = txidSync({ archived: archived.filter(({ sequence }) => sequence !== 31), listed });
  await sync.next();
  const second = await sync.next();
  await sync.next();
  assert.match(sync.left[0], /follows/);
  // 25 to 30 from the archive, mid-block, then rail-squid from 31.
  assert.deepEqual(
    second.slice(0, 6).map(({ graphID }) => sequenceOf(graphID)),
    [25, 26, 27, 28, 29, 30],
  );
  assert.equal(sequenceOf(second[6].graphID), undefined);
  assert.deepEqual(verifications(sync.kept), verifications(listed));
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
  assert.deepEqual(third.map(({ graphID }) => sequenceOf(graphID)), Array.from({ length: 25 }, (_, i) => 50 + i));
  assert.deepEqual(sync.asked, []);
});

test("a record the page can't read keeps the ones before it, and rail-squid gives the rest without a gap", async () => {
  const { archived, listed } = transactions(60);
  // An unshield without its recipient, say.
  archived[30] = { ...archived[30], unshield: { tokenData: { tokenType: 0, tokenAddress: `0x${word('t', 20)}`, tokenSubID: '0' }, value: '5' } };
  const sync = txidSync({ archived, listed });
  await sync.next();
  const second = await sync.next();
  await sync.next();
  assert.equal(sync.left.length, 1);
  assert.deepEqual(second.slice(0, 5).map(({ graphID }) => sequenceOf(graphID)), [25, 26, 27, 28, 29]);
  assert.equal(sequenceOf(second[5].graphID), undefined);
  assert.deepEqual(verifications(sync.kept), verifications(listed));
});

test("a record that breaks the verification hashes is never handed to the engine: rail-squid gives it", async () => {
  const { archived, listed } = transactions(60);
  archived[33] = { ...archived[33], verificationHash: word('not the chain') };
  const sync = txidSync({ archived, listed });
  await sync.next();
  const second = await sync.next();
  assert.match(sync.left[0], /verification hashes/);
  assert.deepEqual(second.slice(0, 8).map(({ graphID }) => sequenceOf(graphID)), [25, 26, 27, 28, 29, 30, 31, 32]);
  assert.deepEqual(verifications(sync.kept), verifications(listed.slice(0, 50)));
});

test("the wallet's own transaction from the archive must hash to its railgunTxid, else rail-squid gives it", async () => {
  // The archive got transaction 33's commitments wrong but kept its railgunTxid, which the root check binds: only its
  // fields, which the wallet's proofs for its own send rebuild the railgunTxid from, are off.
  const { archived, listed } = transactions(60);
  archived[33] = { ...archived[33], commitments: [`0x${word('not its output', 31).padStart(64, '0')}`] };
  const spent = archived[33].nullifiers[0].slice(2);

  const theirs = txidSync({ archived, listed });
  await theirs.next();
  await theirs.next();
  assert.deepEqual(theirs.left, [], "another wallet's transaction is the root check's to judge");

  const ours = txidSync({ archived, listed, mine: new Set([spent]) });
  await ours.next();
  const second = await ours.next();
  assert.match(ours.left[0], /doesn't hash to its railgunTxid/);
  assert.deepEqual(second.slice(0, 8).map(({ graphID }) => sequenceOf(graphID)), [25, 26, 27, 28, 29, 30, 31, 32]);
  assert.deepEqual(verifications(ours.kept), verifications(listed.slice(0, 50)));
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
  const sync = txidSync({ archived, listed, reading: false, kept: archived.slice(0, 5).map((record) => transaction(record, blockTime)) });
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

test("a list rail-squid gave goes on from rail-squid", async () => {
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
  assert.deepEqual(withHash(tx, () => assert.fail('worked out again')), createRailgunTransactionWithHash(tx));
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
      unshield: { tokenData: { tokenType: 0, tokenAddress: `0x${word('t', 20)}`, tokenSubID: '0' }, toAddress: `0x${word('to', 20)}`, value: '5' },
    },
    blockTime,
  );
  assert.equal(tx.version, RailgunTransactionVersion.V2);
  assert.deepEqual(withHash(tx, createRailgunTransactionWithHash), createRailgunTransactionWithHash(tx));
});
