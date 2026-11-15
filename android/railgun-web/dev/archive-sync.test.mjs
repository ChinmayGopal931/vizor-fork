import assert from 'node:assert/strict';
import { test } from 'node:test';
import { gunzipSync } from 'node:zlib';
import { ArchiveUnavailable, archive } from '../src/archive.js';
import { ARCHIVE_ROUNDS, archiveCommitments, installArchiveSync } from '../src/archive-sync.js';
import { formatCommitments, formatNullifiers, formatUnshields, installQuickSync } from '../src/quick-sync.js';
import { CHAIN, V2, contents, engineHarness } from './engine-harness.mjs';
import { ARCHIVE_BASE, archiveServer, blockTime, gz, hashOf, history, indexer, word } from './history-fixture.mjs';
import { memoryDatabase } from './memory-store.mjs';

const PAGE = 40;
const pages = { pageSize: PAGE, gapMs: 0, retryMs: 0 };
const fixture = history();
const sealedAt = [14_760_030, 14_760_060, 14_760_090];
// Far past the fixture, so a sync from its start reads the archive.
const FAR = { blockNumber: fixture.to + 100_000, timestamp: blockTime(fixture.to + 100_000) };
const newestBlockOf = (list) => Math.max(...list.map(({ blockNumber }) => Number(blockNumber)));

/** The store rail-squid alone leaves: the engine's own quick sync over whole lists. */
async function storedBySquid(lists = fixture.squid) {
  const store = memoryDatabase();
  const { engine, merkletree } = await engineHarness({ store });
  await engine.unshieldListener(V2, CHAIN, formatUnshields(lists.unshields));
  await engine.nullifierListener(V2, CHAIN, formatNullifiers(lists.nullifiers));
  await engine.commitmentListener(V2, CHAIN, formatCommitments(lists.commitments), false, false);
  await merkletree.updateTreesFromWriteQueue(true);
  return contents(store.down);
}

/**
 * A quick sync from `server` (archive.js over its fetch) and rail-squid (`lists`), from `startingBlock`; what it stored,
 * what it asked rail-squid, and why it left the archive.
 */
async function storedByArchive(
  server,
  {
    lists = fixture.squid,
    store = memoryDatabase(),
    startingBlock = fixture.from,
    head = FAR,
    harness,
    useArchive,
    squidQueries = (queries) => queries,
  } = {},
) {
  const { engine, merkletree } = harness ?? (await engineHarness({ store }));
  const squid = indexer(lists, PAGE);
  const queries = squidQueries(squid.queries);
  const left = [];
  installQuickSync(engine, { queries, head: async () => head?.blockNumber, pages });
  installArchiveSync(engine, {
    reader: archive(ARCHIVE_BASE, 1, { fetch: server.fetch, retryMs: 0 }),
    queries,
    chainId: 1,
    time: (block) => blockTime(block),
    head: async () => head ?? undefined,
    log: (line) => left.push(line),
    useArchive,
    pages,
    writeRetryMs: 0,
    roundWaitMs: 0,
  });
  await engine.quickSyncEvents(V2, CHAIN, startingBlock);
  return { stored: contents(store.down), asked: squid.asked, left, merkletree };
}

const squidFrom = (asked, list) => asked.filter(([name]) => name === list).map(([, block]) => block)[0];

/** `queries` with rail-squid's `name` list failing `times` times after its first page, as a dead connection does. */
function squidFailing(name, times) {
  return (queries) => {
    let calls = 0;
    let failures = times;
    return {
      ...queries,
      [name]: (block) => {
        calls += 1;
        if (calls < 2 || failures === 0) return queries[name](block);
        failures -= 1;
        return Promise.reject(new TypeError('Failed to fetch'));
      },
    };
  };
}

test('a first sync from the archive stores exactly what rail-squid alone stores', async () => {
  const server = archiveServer(fixture, { sealedAt });
  const { stored, asked, left } = await storedByArchive(server);
  assert.deepEqual(left, []);
  assert.deepEqual(stored, await storedBySquid());
  // Rail-squid gave the unshields and nullifiers from the start, and commitments only past the blocks its lists showed
  // it has: the newest unshield's, older than the newest nullifier's.
  assert.equal(squidFrom(asked, 'nullifiers'), fixture.from);
  assert.equal(squidFrom(asked, 'unshields'), fixture.from);
  assert.equal(squidFrom(asked, 'commitments'), newestBlockOf(fixture.squid.unshields) + 1);
  assert.ok(server.asked.includes('tip/meta.json'));
  assert.ok(!server.asked.some((path) => path.includes('unshields')), 'the archive is never asked for unshields');
});

test("rail-squid behind the archive leaves no nullifier out: the archive's commitments stop where its lists do", async () => {
  // Rail-squid has indexed only to block 14,760,100, the archive to the fixture's end.
  const behind = 14_760_100;
  const known = (list) => list.filter(({ blockNumber }) => Number(blockNumber) <= behind);
  const lagging = {
    commitments: known(fixture.squid.commitments),
    nullifiers: known(fixture.squid.nullifiers),
    unshields: known(fixture.squid.unshields),
  };
  const store = memoryDatabase();
  const first = await storedByArchive(archiveServer(fixture, { sealedAt }), { lists: lagging, store });
  assert.deepEqual(first.left, []);
  const { tree, index } = await first.merkletree.getLatestTreeAndIndex();
  const newest = (await first.merkletree.getCommitment(tree, index)).blockNumber;
  assert.ok(newest <= behind, `a commitment from block ${newest} is stored, past rail-squid's ${behind}`);
  // The engine's next quick sync starts at its newest stored commitment's block, rail-squid caught up by then.
  const { stored } = await storedByArchive(archiveServer(fixture, { sealedAt }), { store, startingBlock: newest });
  assert.deepEqual(stored, await storedBySquid());
});

test("the archive's times are never stored: each record is dated from its block", async () => {
  const server = archiveServer(fixture, { sealedAt });
  const { merkletree } = await storedByArchive(server);
  const first = fixture.archive.commitments[0].commitments[0];
  const stored = await merkletree.getCommitment(0, first.utxoIndex);
  assert.notEqual(first.timestamp, blockTime(first.blockNumber));
  assert.equal(stored.timestamp, blockTime(first.blockNumber));
});

test('nullifiers come from rail-squid alone: a nullifier spent in two trees keeps both', async () => {
  // Mainnet's case: spent in tree 1, then in tree 3, where the archive keeps only the first.
  const nullifier = '158d6d9b02c92e7f0fa0e815b2575e0ad6c0a03a995e0e490aa18bea7104e429';
  const spends = [
    [1, 14_760_011],
    [3, 14_760_071],
  ].map(([treeNumber, block]) => ({
    id: `dup-${treeNumber}`,
    blockNumber: String(block),
    nullifier,
    transactionHash: word(`dup-${treeNumber}`),
    blockTimestamp: String(blockTime(block)),
    treeNumber,
  }));
  const lists = {
    ...fixture.squid,
    nullifiers: [...fixture.squid.nullifiers, ...spends].sort((a, b) => a.blockNumber - b.blockNumber),
  };
  const archived = {
    ...fixture,
    archive: {
      ...fixture.archive,
      nullifiers: [
        ...fixture.archive.nullifiers,
        { nullifier, treeNumber: 1, txid: word('dup-1'), blockNumber: 14_760_011 },
      ],
    },
  };
  const { merkletree } = await storedByArchive(archiveServer(archived, { sealedAt }), { lists });
  assert.equal(await merkletree.getNullifierTxid(nullifier, 1), word('dup-1'));
  assert.equal(await merkletree.getNullifierTxid(nullifier, 3), word('dup-3'));
});

test('a chunk that fails its checksum hands the rest to rail-squid after the chunk before it', async () => {
  const server = archiveServer(fixture, { sealedAt });
  server.files.set('chunks/2/commitments.json.gz', gz(Buffer.from('[]')));
  const { stored, asked, left } = await storedByArchive(server);
  assert.match(left[0], /checksum/);
  assert.equal(squidFrom(asked, 'commitments'), sealedAt[1]);
  assert.deepEqual(stored, await storedBySquid());
});

test('a missing chunk hands the rest to rail-squid after the chunk before it', async () => {
  const server = archiveServer(fixture, { sealedAt });
  server.files.delete('chunks/1/meta.json');
  const { stored, asked, left } = await storedByArchive(server);
  assert.match(left[0], /404/);
  assert.equal(squidFrom(asked, 'commitments'), sealedAt[0]);
  assert.deepEqual(stored, await storedBySquid());
});

test('an index with a chunk missing leaves the whole sync to rail-squid', async () => {
  const server = archiveServer(fixture, { sealedAt });
  const index = JSON.parse(server.files.get('chunk-index.json'));
  index.chunks.splice(1, 1);
  server.files.set('chunk-index.json', Buffer.from(JSON.stringify(index)));
  const { stored, asked, left } = await storedByArchive(server);
  assert.match(left[0], /index/);
  assert.equal(squidFrom(asked, 'commitments'), fixture.from);
  assert.deepEqual(stored, await storedBySquid());
});

test('a tip replaced after the manifest was read is read again from a fresh manifest', async () => {
  const server = archiveServer(fixture, { sealedAt });
  const tip = server.files.get('tip/meta.json');
  let served = 0;
  // The first read finds the tip already replaced.
  server.files.set('tip/meta.json', () => (served++ === 0 ? Buffer.from('{"formatVersion":3}') : tip));
  const { stored, left } = await storedByArchive(server);
  assert.deepEqual(left, []);
  assert.equal(served, 2);
  assert.deepEqual(stored, await storedBySquid());
});

test('a chunk sealed since the index was read is taken before the tip', async () => {
  const before = archiveServer(fixture, { sealedAt: sealedAt.slice(0, 2) });
  const after = archiveServer(fixture, { sealedAt });
  // The chunk seals right after the first index read.
  let sealed = false;
  const server = {
    fetch: (url) => {
      const now = sealed ? after : before;
      if (url.includes('chunk-index.json')) sealed = true;
      return now.fetch(url);
    },
  };
  const { stored, left } = await storedByArchive(server);
  assert.deepEqual(left, []);
  assert.ok(after.asked.includes('chunks/2/commitments.json.gz'));
  assert.deepEqual(stored, await storedBySquid());
});

test("a tip that doesn't follow the last sealed chunk is refused, and rail-squid goes on from that chunk", async () => {
  const server = archiveServer(fixture, { sealedAt });
  const tip = JSON.parse(server.files.get('tip/meta.json'));
  const moved = Buffer.from(JSON.stringify({ ...tip, startBlock: tip.startBlock + 5 }));
  server.files.set('tip/meta.json', moved);
  server.setManifest((manifest) => ({ ...manifest, tipChecksum: hashOf(moved) }));
  const { stored, asked, left } = await storedByArchive(server);
  assert.match(left[0], /tip/);
  assert.equal(squidFrom(asked, 'commitments'), sealedAt[2]);
  assert.deepEqual(stored, await storedBySquid());
});

test('a quick sync killed partway through the archive resumes from its newest stored commitment', async () => {
  const server = archiveServer(fixture, { sealedAt });
  const store = memoryDatabase();
  const killed = await engineHarness({ store });
  const own = killed.engine.commitmentListener;
  let pages = 0;
  // From its third page on, as a page closed then would.
  killed.engine.commitmentListener = (...args) => {
    if (++pages >= 3) throw new Error('killed');
    return own(...args);
  };
  await assert.rejects(storedByArchive(server, { store, harness: killed }), /killed/);

  const resumed = await engineHarness({ store });
  const { tree, index } = await resumed.merkletree.getLatestTreeAndIndex();
  const startingBlock = (await resumed.merkletree.getCommitment(tree, index)).blockNumber;
  const { stored } = await storedByArchive(server, { store, startingBlock, harness: resumed });
  assert.deepEqual(stored, await storedBySquid());
});

test('a store that ends inside a batch goes on from the archive, which gives that batch whole', async () => {
  // As a rail-squid page, or a write cut off with the connection, leaves a store: one leaf into a batch of several.
  const list = fixture.squid.commitments;
  const first = list.findIndex(
    (c, i) =>
      c.treePosition === c.batchStartTreePosition && list[i + 1]?.batchStartTreePosition === c.batchStartTreePosition,
  );
  const block = Number(list[first].blockNumber);
  const upTo = (rows) => rows.filter(({ blockNumber }) => Number(blockNumber) <= block);
  const store = memoryDatabase();
  const earlier = await engineHarness({ store });
  await earlier.engine.unshieldListener(V2, CHAIN, formatUnshields(upTo(fixture.squid.unshields)));
  await earlier.engine.nullifierListener(V2, CHAIN, formatNullifiers(upTo(fixture.squid.nullifiers)));
  await earlier.engine.commitmentListener(V2, CHAIN, formatCommitments(list.slice(0, first + 1)), false, false);
  await earlier.merkletree.updateTreesFromWriteQueue(true);

  const resumed = await engineHarness({ store });
  const { stored, left } = await storedByArchive(archiveServer(fixture, { sealedAt }), {
    store,
    startingBlock: block,
    harness: resumed,
  });
  assert.deepEqual(left, []);
  assert.deepEqual(stored, await storedBySquid());
});

test('after the trees were rebuilt, a sync far behind leaves the archive alone', async () => {
  const server = archiveServer(fixture, { sealedAt });
  const { stored, left } = await storedByArchive(server, { useArchive: () => false });
  assert.deepEqual(server.asked, []);
  assert.deepEqual(left, []);
  assert.deepEqual(stored, await storedBySquid());
});

test("a sync within the archive tip's reach of the newest block never asks the archive", async () => {
  const server = archiveServer(fixture, { sealedAt });
  const head = { blockNumber: fixture.to + 100, timestamp: blockTime(fixture.to + 100) };
  const { stored } = await storedByArchive(server, { head });
  assert.deepEqual(server.asked, []);
  assert.deepEqual(stored, await storedBySquid());
});

test('a sync that knows no newest block never asks the archive', async () => {
  const server = archiveServer(fixture, { sealedAt });
  const { stored } = await storedByArchive(server, { head: null });
  assert.deepEqual(server.asked, []);
  assert.deepEqual(stored, await storedBySquid());
});

test('the archive and rail-squid hear the same requests whichever wallet syncs', async () => {
  const requests = async () => {
    const server = archiveServer(fixture, { sealedAt });
    const { asked } = await storedByArchive(server);
    return { archive: server.asked, squid: asked };
  };
  // Two wallets' pages: nothing of a wallet reaches the quick sync, so each asks exactly what the other does.
  assert.deepEqual(await requests(), await requests());
});

/** The fixture's archive with chunk `id`'s commitments replaced by `edit(commitments)`, its checksum to match. */
function editedChunk(id, edit) {
  const server = archiveServer(fixture, { sealedAt });
  const path = `chunks/${id}/commitments.json.gz`;
  const body = Buffer.from(JSON.stringify(edit(JSON.parse(gunzipSync(server.files.get(path))))));
  server.files.set(path, gz(body));
  const meta = JSON.parse(server.files.get(`chunks/${id}/meta.json`));
  meta.files.commitments.checksum = hashOf(body);
  server.files.set(`chunks/${id}/meta.json`, Buffer.from(JSON.stringify(meta)));
  return server;
}

test('a batch missing from a chunk, its checksum and all, hands the rest to rail-squid before the gap', async () => {
  const server = editedChunk(1, (commitments) => commitments.filter((_, i) => i !== 5));
  const { stored, asked, left } = await storedByArchive(server);
  assert.match(left[0], /skip/);
  assert.equal(squidFrom(asked, 'commitments'), sealedAt[0]);
  assert.deepEqual(stored, await storedBySquid());
});

/** A reader of one sealed chunk holding `commitments` (archive batches), and an empty tip after it. */
function oneChunk(commitments) {
  const chunk = { id: 0, startBlock: fixture.from, endBlock: fixture.to };
  const manifest = { latestSealedChunk: 0, tipChecksum: 'tip' };
  return {
    manifest: async () => manifest,
    chunks: async () => [chunk],
    chunk: async () => ({ ...chunk, commitments }),
    tip: async () => ({ startBlock: fixture.to + 1, endBlock: fixture.to, commitments: [] }),
  };
}

/** Fixture batch `batch` as the archive would number it from `tree`:`start`. */
const numbered = (batch, tree, start) => ({
  ...batch,
  treeNumber: tree,
  startPosition: start,
  commitments: batch.commitments.map((c, i) => ({ ...c, utxoTree: tree, utxoIndex: start + i })),
});

const TREE_LEAVES = 2 ** 16;
// Where the engine's commitment listener queues a note.
const queuedAt = ({ utxoTree, utxoIndex }) => `${utxoTree + (utxoIndex >> 16)}:${utxoIndex % TREE_LEAVES}`;

/** Where the engine queues the notes of each batch `archiveCommitments` gives from `reader`, `next` on. */
async function placed(reader, next) {
  const out = [];
  for await (const { events } of archiveCommitments(reader, fixture.from, next, { time: blockTime, chainId: 1 })) {
    out.push(...events.map((batch) => batch.commitments.map(queuedAt)));
  }
  return out;
}

const notes = (tree, start, count) => Array.from({ length: count }, (_, i) => `${tree}:${start + i}`);
const several = fixture.archive.commitments.find(({ commitments }) => commitments.length > 1);

test("the archive's note numbered one past a full tree's last goes on in the next tree, where the engine puts it", async () => {
  const [a, b, c] = fixture.archive.commitments;
  const [na, nb, nc] = [a, b, c].map(({ commitments }) => commitments.length);
  const end = TREE_LEAVES - na;
  // As rail-squid and the archive number the start of mainnet's tree 1: its first batch at tree 0's leaf 65,536.
  const reader = oneChunk([numbered(a, 0, end), numbered(b, 0, TREE_LEAVES), numbered(c, 1, nb)]);
  assert.deepEqual(await placed(reader, { tree: 0, position: end }), [
    notes(0, end, na),
    notes(1, 0, nb),
    notes(1, nb, nc),
  ]);
});

test('an archive batch that runs past the end of its tree hands the rest to rail-squid', async () => {
  const reader = oneChunk([numbered(several, 0, TREE_LEAVES - 1)]);
  await assert.rejects(
    placed(reader, { tree: 0, position: TREE_LEAVES - 1 }),
    (error) => error instanceof ArchiveUnavailable && /runs past its tree/.test(error.message),
  );
});

test('an archive batch whose notes are numbered apart from it hands the rest to rail-squid', async () => {
  const reader = oneChunk([{ ...numbered(several, 0, 11), startPosition: 10 }]);
  await assert.rejects(
    placed(reader, { tree: 0, position: 10 }),
    (error) => error instanceof ArchiveUnavailable && /apart from it/.test(error.message),
  );
});

test("a commitment the page can't read hands the rest to rail-squid, as anything unexpected does", async () => {
  const server = editedChunk(2, (commitments) =>
    commitments.map((batch, i) =>
      i === 0 ? { ...batch, commitments: [{ ...batch.commitments[0], commitmentType: 'Unheard' }] } : batch,
    ),
  );
  const { stored, asked, left } = await storedByArchive(server);
  assert.match(left[0], /unknown archive commitment type/);
  assert.equal(squidFrom(asked, 'commitments'), sealedAt[1]);
  assert.deepEqual(stored, await storedBySquid());
});

test('a manifest that is not JSON leaves the whole sync to rail-squid', async () => {
  const server = archiveServer(fixture, { sealedAt });
  server.files.set('meta.json', Buffer.from('<html>busy</html>'));
  const { stored, asked, left } = await storedByArchive(server);
  assert.match(left[0], /not JSON/);
  assert.equal(squidFrom(asked, 'commitments'), fixture.from);
  assert.deepEqual(stored, await storedBySquid());
});

/** The fixture's archive, its first `times` requests for `name` failing on the way. */
function failingFirst(name, times) {
  const server = archiveServer(fixture, { sealedAt });
  let failures = times;
  return {
    fetch: (url) => {
      if (url.replace(/^https:\/\/digest\.test\/v4\/1\//, '').replace(/\?v=.*$/, '') === name && failures > 0) {
        failures -= 1;
        return Promise.reject(new TypeError('Failed to fetch'));
      }
      return server.fetch(url);
    },
  };
}

test(
  'a request is sent five times a round, as a phone can lose DNS for seconds, and the archive out of reach ' +
    'every round is left',
  async () => {
    const kept = await storedByArchive(failingFirst('chunk-index.json', 4));
    assert.deepEqual(kept.left, []);
    assert.deepEqual(kept.stored, await storedBySquid());
    const left = await storedByArchive(failingFirst('chunk-index.json', 5 * ARCHIVE_ROUNDS));
    assert.equal(left.left.length, ARCHIVE_ROUNDS);
    assert.match(
      left.left.at(-1),
      /^the archive was left at block \d+: the archive did not answer for chunk-index\.json/,
    );
    assert.deepEqual(left.stored, await storedBySquid());
  },
);

test('a request that fails on the way is sent again, and the archive is kept', async () => {
  const server = archiveServer(fixture, { sealedAt });
  const failing = new Set(['chunks/1/commitments.json.gz', 'chunk-index.json']);
  const flaky = {
    fetch: (url) => {
      const name = url.replace(/^https:\/\/digest\.test\/v4\/1\//, '').replace(/\?v=.*$/, '');
      if (failing.delete(name))
        return name === 'chunk-index.json'
          ? Promise.reject(new TypeError('Failed to fetch'))
          : new Response('', { status: 502 });
      return server.fetch(url);
    },
  };
  const { stored, left } = await storedByArchive(flaky);
  assert.deepEqual(left, []);
  assert.deepEqual(stored, await storedBySquid());
});

// A page is tried five times (quick-sync.js); on a phone an HTTP/2 connection to rail-squid stopped answering for about
// two minutes, every try sent on it failing, and took the archive out of a whole first sync.
const PAGE_TRIES = 5;

test("rail-squid's list failing beside the archive is asked again from where it was stored, and the archive is kept", async () => {
  const server = archiveServer(fixture, { sealedAt });
  const { stored, asked, left } = await storedByArchive(server, {
    squidQueries: squidFailing('nullifiers', PAGE_TRIES),
  });
  assert.equal(left.length, 1);
  assert.match(left[0], /^rail-squid failed at block \d+, asked again: Failed to fetch$/);
  assert.deepEqual(stored, await storedBySquid());
  // The commitments still came from the archive: rail-squid was asked for them only past its lists' newest block.
  assert.equal(squidFrom(asked, 'commitments'), newestBlockOf(fixture.squid.unshields) + 1);
});

test(`rail-squid failing beside the archive ${ARCHIVE_ROUNDS} times leaves the archive, and goes on alone`, async () => {
  const server = archiveServer(fixture, { sealedAt });
  const { stored, left } = await storedByArchive(server, {
    squidQueries: squidFailing('nullifiers', PAGE_TRIES * ARCHIVE_ROUNDS),
  });
  assert.equal(left.length, ARCHIVE_ROUNDS);
  for (const line of left.slice(0, -1)) assert.match(line, /^rail-squid failed at block \d+, asked again/);
  assert.match(left.at(-1), /^the archive was left at block \d+: Failed to fetch$/);
  assert.deepEqual(stored, await storedBySquid());
});

test('an archive out of reach for a round, as a phone that lost its network for a minute, is asked again and kept', async () => {
  // The host answers 502 for a fetch of its own that failed.
  const server = archiveServer(fixture, { sealedAt });
  let failures = PAGE_TRIES;
  const unreachable = {
    fetch: (url) => {
      if (url.endsWith('/meta.json') && !url.includes('/chunks/') && failures > 0) {
        failures -= 1;
        return Promise.resolve(new Response('', { status: 502 }));
      }
      return server.fetch(url);
    },
  };
  const { stored, asked, left } = await storedByArchive(unreachable);
  assert.equal(left.length, 1);
  assert.match(left[0], /^the archive failed at block \d+, asked again: the archive answered 502 for meta\.json$/);
  assert.deepEqual(stored, await storedBySquid());
  assert.equal(squidFrom(asked, 'commitments'), newestBlockOf(fixture.squid.unshields) + 1);
});

test("the archive's own data failing leaves it at once, never asked again", async () => {
  const server = archiveServer(fixture, { sealedAt });
  server.files.set('meta.json', Buffer.from('<html>busy</html>'));
  const { stored, left } = await storedByArchive(server);
  assert.equal(left.length, 1);
  assert.match(left[0], /^the archive was left at block \d+: meta\.json is not JSON$/);
  assert.deepEqual(stored, await storedBySquid());
});
