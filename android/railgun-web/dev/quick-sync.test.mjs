import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import {
  NO_EVENTS,
  formatCommitments,
  formatNullifiers,
  formatUnshields,
  installQuickSync,
  quickSyncProgress,
  squidLists,
  squidPages,
  storeEvents,
} from '../src/quick-sync.js';
import { CHAIN, V2, contents, engineHarness } from './engine-harness.mjs';
import { memoryDatabase } from './memory-store.mjs';

const word = (seed, bytes = 32) => createHash('sha256').update(String(seed)).digest('hex').slice(0, bytes * 2);
const timestamp = (block) => String(1_650_000_000 + block * 12);

/**
 * A made-up stretch of Railgun's history from block `from`, as rail-squid lists it (each list ordered by block):
 * every block a few commitment batches, nullifiers and unshields.
 */
function history({ from = 14_700_000, blocks = 120 } = {}) {
  const commitments = [];
  const nullifiers = [];
  const unshields = [];
  let position = 0;
  for (let block = from; block < from + blocks; block += 1) {
    const batches = block % 4;
    for (let batch = 0; batch < batches; batch += 1) {
      const transactionHash = word(`tx-${block}-${batch}`);
      const start = position;
      const size = 1 + ((block + batch) % 4);
      for (let i = 0; i < size; i += 1) {
        commitments.push({
          id: `c-${position}`,
          treeNumber: 0,
          batchStartTreePosition: start,
          treePosition: position,
          blockNumber: String(block),
          transactionHash,
          blockTimestamp: timestamp(block),
          commitmentType: 'TransactCommitment',
          hash: BigInt(`0x${word(`leaf-${position}`, 31)}`).toString(),
          ciphertext: {
            ciphertext: { iv: word(`iv-${position}`, 16), tag: word(`tag-${position}`, 16), data: [word(`d0-${position}`), word(`d1-${position}`)] },
            blindedReceiverViewingKey: word(`r-${position}`),
            blindedSenderViewingKey: word(`s-${position}`),
            memo: '0x',
            annotationData: `0x${word(`a-${position}`, 8)}`,
          },
        });
        position += 1;
      }
    }
    for (let i = 0; i < block % 3; i += 1) {
      nullifiers.push({
        id: `n-${block}-${i}`,
        blockNumber: String(block),
        nullifier: word(`nullifier-${block}-${i}`),
        transactionHash: word(`tx-${block}-0`),
        blockTimestamp: timestamp(block),
        treeNumber: 0,
      });
    }
    if (block % 5 === 0) {
      unshields.push({
        id: `u-${block}`,
        blockNumber: String(block),
        to: `0x${word(`to-${block}`, 20)}`,
        transactionHash: word(`tx-${block}-0`),
        fee: '25',
        blockTimestamp: timestamp(block),
        amount: String(10_000 + block),
        eventLogIndex: block % 7,
        token: { id: 't', tokenType: 'ERC20', tokenSubID: '0x00', tokenAddress: `0x${word('token', 20)}` },
      });
    }
  }
  return { from, commitments, nullifiers, unshields };
}

/** rail-squid answering `pageSize` events of each list from a block on. */
function indexer(lists, pageSize) {
  const asked = [];
  const answer = (name) => async (block) => {
    asked.push([name, block]);
    return lists[name].filter(({ blockNumber }) => Number(blockNumber) >= block).slice(0, pageSize);
  };
  return { asked, queries: { nullifiers: answer('nullifiers'), unshields: answer('unshields'), commitments: answer('commitments') } };
}

/** The store as the engine's own quick sync leaves it: every list read whole, then stored in one go. */
async function storedWhole(lists) {
  const store = memoryDatabase();
  const { engine, merkletree } = await engineHarness({ store });
  await engine.unshieldListener(V2, CHAIN, formatUnshields(lists.unshields));
  await engine.nullifierListener(V2, CHAIN, formatNullifiers(lists.nullifiers));
  await engine.commitmentListener(V2, CHAIN, formatCommitments(lists.commitments), false, false);
  await merkletree.updateTreesFromWriteQueue(true);
  return contents(store.down);
}

async function storedByPages(lists, { pageSize, writeLeaves, store = memoryDatabase(), startingBlock = lists.from, harness } = {}) {
  const { engine } = harness ?? (await engineHarness({ store }));
  const options = { pageSize, gapMs: 0 };
  const left = await storeEvents({
    engine,
    txidVersion: V2,
    chain: CHAIN,
    ...squidLists(indexer(lists, pageSize).queries, startingBlock, options),
    writeLeaves,
  });
  return { left, stored: contents(store.down) };
}

test('a quick sync stored page by page stores exactly what the engine stores from whole lists', async () => {
  const lists = history();
  const { left, stored } = await storedByPages(lists, { pageSize: 40 });
  assert.deepEqual(left, NO_EVENTS);
  assert.deepEqual(stored, await storedWhole(lists));
});

test('the trees take the leaves of several pages at once, so few roots are checked on chain', async () => {
  const lists = history();
  const harness = await engineHarness();
  let writes = 0;
  const own = harness.merkletree.updateTreesFromWriteQueue.bind(harness.merkletree);
  harness.merkletree.updateTreesFromWriteQueue = (...args) => {
    writes += 1;
    return own(...args);
  };
  const pages = Math.ceil(lists.commitments.length / 10);
  const { stored } = await storedByPages(lists, { pageSize: 10, writeLeaves: 100, store: harness, harness });
  assert.deepEqual(stored, await storedWhole(lists));
  // A write each 100 leaves and one at the end, rather than one a page; one root checked per write.
  assert.equal(writes, Math.ceil(lists.commitments.length / 100));
  assert.ok(harness.rootChecks() <= writes, `${harness.rootChecks()} roots checked for ${pages} pages`);
});

test('a list that fails first stores the leaves the pages before it gave, and says through where', async () => {
  const lists = history();
  const harness = await engineHarness();
  const ownCommitments = harness.engine.commitmentListener;
  let calls = 0;
  harness.engine.commitmentListener = (...args) => {
    calls += 1;
    if (calls === 4) throw new Error('broken page');
    return ownCommitments(...args);
  };
  const stored = [];
  const pages = squidLists(indexer(lists, 30).queries, lists.from, { pageSize: 30, gapMs: 0 });
  await assert.rejects(
    storeEvents({ engine: harness.engine, txidVersion: V2, chain: CHAIN, ...pages, stored: (block) => stored.push(block) }),
    /broken page/,
  );
  // The default write size holds every leaf until the end, so the only write is the one the failure makes.
  assert.equal(stored.length, 1);
  const { tree, index } = await harness.merkletree.getLatestTreeAndIndex();
  const newest = (await harness.merkletree.getCommitment(tree, index)).blockNumber;
  assert.ok(newest <= stored[0] + 1, `newest stored commitment at ${newest}, stored through ${stored[0]}`);
  assert.ok(newest > lists.from);
});

test("a page's unshields and nullifiers are stored before its commitments", async () => {
  const lists = history();
  const { engine } = await engineHarness();
  const storedIds = new Set();
  const listen = (name, ids) => {
    const own = engine[name];
    engine[name] = (txidVersion, chain, events, ...rest) => {
      for (const id of ids(events)) storedIds.add(id);
      return own(txidVersion, chain, events, ...rest);
    };
  };
  listen('unshieldListener', (events) => events.map(({ txid, eventLogIndex }) => `u:${txid}:${eventLogIndex}`));
  listen('nullifierListener', (events) => events.map(({ nullifier }) => `n:${nullifier}`));
  const ownCommitments = engine.commitmentListener;
  let checked = 0;
  engine.commitmentListener = (txidVersion, chain, batches, ...rest) => {
    const reached = Math.max(...batches.map(({ blockNumber }) => blockNumber));
    for (const event of formatUnshields(lists.unshields).filter(({ blockNumber }) => blockNumber <= reached)) {
      assert.ok(storedIds.has(`u:${event.txid}:${event.eventLogIndex}`), `unshield in block ${event.blockNumber}`);
    }
    for (const event of formatNullifiers(lists.nullifiers).filter(({ blockNumber }) => blockNumber <= reached)) {
      assert.ok(storedIds.has(`n:${event.nullifier}`), `nullifier in block ${event.blockNumber}`);
    }
    checked += 1;
    return ownCommitments(txidVersion, chain, batches, ...rest);
  };
  await storeEvents({ engine, txidVersion: V2, chain: CHAIN, ...squidLists(indexer(lists, 25).queries, lists.from, { pageSize: 25, gapMs: 0 }) });
  assert.ok(checked > 5, `${checked} pages of commitments`);
});

test('a quick sync killed partway resumes from its newest stored commitment and ends where an unbroken one does', async () => {
  const lists = history();
  const store = memoryDatabase();
  const killed = await engineHarness({ store });
  const ownCommitments = killed.engine.commitmentListener;
  let pages = 0;
  killed.engine.commitmentListener = (...args) => {
    pages += 1;
    if (pages === 4) throw new Error('killed');
    return ownCommitments(...args);
  };
  await assert.rejects(storedByPages(lists, { pageSize: 30, store, harness: killed }), /killed/);

  // As the engine's next quick sync starts: at the newest stored commitment's block.
  const resumed = await engineHarness({ store });
  const { tree, index } = await resumed.merkletree.getLatestTreeAndIndex();
  const startingBlock = (await resumed.merkletree.getCommitment(tree, index)).blockNumber;
  assert.ok(startingBlock > lists.from);
  const { stored } = await storedByPages(lists, { pageSize: 30, store, startingBlock, harness: resumed });
  assert.deepEqual(stored, await storedWhole(lists));
});

test('each list asks for its next page while the last one is stored', async () => {
  const lists = history();
  const { asked, queries } = indexer(lists, 20);
  const pages = squidPages(queries.commitments, formatCommitments, lists.from, { pageSize: 20, gapMs: 0 });
  await pages.next();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(asked.length, 2);
  assert.equal(asked[1][1], Number(lists.commitments[19].blockNumber));
});

test('a page repeats the block the last one ended on, and its events there are given once', async () => {
  const lists = history();
  const given = [];
  for await (const { events } of squidPages(indexer(lists, 7).queries.nullifiers, formatNullifiers, lists.from, { pageSize: 7, gapMs: 0 })) {
    given.push(...events);
  }
  assert.deepEqual(given, formatNullifiers(lists.nullifiers));
});

test('a list says how far it has given every event, and that it ended', async () => {
  const lists = history();
  const throughs = [];
  for await (const { through } of squidPages(indexer(lists, 50).queries.commitments, formatCommitments, lists.from, { pageSize: 50, gapMs: 0 })) {
    throughs.push(through);
  }
  assert.equal(throughs.at(-1), Infinity);
  for (let i = 1; i < throughs.length - 1; i += 1) assert.ok(throughs[i] > throughs[i - 1]);
});

test('an indexer with more than a page in one block fails the quick sync rather than loop', async () => {
  const crowded = Array.from({ length: 6 }, (_, i) => ({
    id: `n-${i}`,
    blockNumber: '100',
    nullifier: word(i),
    transactionHash: word(`t${i}`),
    blockTimestamp: timestamp(100),
    treeNumber: 0,
  }));
  const pages = squidPages(async (block) => crowded.filter(({ blockNumber }) => Number(blockNumber) >= block).slice(0, 5), formatNullifiers, 100, {
    pageSize: 5,
    gapMs: 0,
  });
  await pages.next();
  await assert.rejects(pages.next(), /more than a page/);
});

test('the quick sync reports its progress as the engine scan updates between a tenth and four tenths', async () => {
  const lists = history();
  const { engine, progress } = await engineHarness();
  installQuickSync(engine, {
    queries: indexer(lists, 40).queries,
    head: async () => lists.from + 200,
    pages: { pageSize: 40, gapMs: 0 },
  });
  // A quick sync through the engine's own hook.
  await engine.quickSyncEvents(V2, CHAIN, lists.from);
  assert.ok(progress.length > 3);
  assert.deepEqual([...progress].sort((a, b) => a - b), progress);
  assert.ok(progress[0] >= 0.1 && progress.at(-1) <= 0.4);
  assert.equal(quickSyncProgress(100, 300, 200), 0.25);
  assert.equal(quickSyncProgress(100, 300, 400), 0.4);
});

test('another TXID version keeps the engine\'s own quick sync', async () => {
  const { engine } = await engineHarness();
  engine.quickSyncEvents = async (txidVersion) => ({ own: txidVersion });
  installQuickSync(engine, { queries: indexer(history(), 40).queries, head: async () => 0 });
  assert.deepEqual(await engine.quickSyncEvents('V3_PoseidonMerkle', CHAIN, 0), { own: 'V3_PoseidonMerkle' });
});
