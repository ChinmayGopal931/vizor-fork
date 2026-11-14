import assert from 'node:assert/strict';
import { test } from 'node:test';
import { RailgunEngine } from '@railgun-community/engine';
import { archive } from '../src/archive.js';
import { installArchiveSync } from '../src/archive-sync.js';
import { formatCommitments, formatNullifiers, formatUnshields, installQuickSync } from '../src/quick-sync.js';
import { CHAIN, V2, contents, engineHarness, poseidon } from './engine-harness.mjs';
import { ARCHIVE_BASE, archiveServer, blockTime, gz, hashOf, history, indexer, treeFile, treeLevels, word } from './history-fixture.mjs';
import { memoryDatabase } from './memory-store.mjs';

const PAGE = 40;
const pages = { pageSize: PAGE, gapMs: 0 };
const fixture = history();
const sealedAt = [14_760_030, 14_760_060, 14_760_090];

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
async function storedByArchive(server, { lists = fixture.squid, store = memoryDatabase(), startingBlock = fixture.from, head, harness } = {}) {
  const { engine, merkletree } = harness ?? (await engineHarness({ store }));
  const squid = indexer(lists, PAGE);
  const left = [];
  installQuickSync(engine, { queries: squid.queries, head: async () => head?.blockNumber, pages });
  installArchiveSync(engine, {
    reader: archive(ARCHIVE_BASE, 1, { fetch: server.fetch }),
    queries: squid.queries,
    chainId: 1,
    time: (block) => blockTime(block),
    head: async () => head,
    log: (line) => left.push(line),
    pages,
  });
  await engine.quickSyncEvents(V2, CHAIN, startingBlock);
  return { stored: contents(store.down), asked: squid.asked, left, merkletree };
}

const squidFrom = (asked, list) => asked.filter(([name]) => name === list).map(([, block]) => block)[0];

test('a first sync from the archive stores exactly what rail-squid alone stores', async () => {
  const server = archiveServer(fixture, { sealedAt });
  const { stored, asked, left } = await storedByArchive(server);
  assert.deepEqual(left, []);
  assert.deepEqual(stored, await storedBySquid());
  // Rail-squid gave the nullifiers from the start, and the rest only after the archive's tip.
  assert.equal(squidFrom(asked, 'nullifiers'), fixture.from);
  assert.equal(squidFrom(asked, 'commitments'), fixture.to + 1);
  assert.ok(server.asked.includes('tip/meta.json'));
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
  const lists = { ...fixture.squid, nullifiers: [...fixture.squid.nullifiers, ...spends].sort((a, b) => a.blockNumber - b.blockNumber) };
  const archived = {
    ...fixture,
    archive: { ...fixture.archive, nullifiers: [...fixture.archive.nullifiers, { nullifier, treeNumber: 1, txid: word('dup-1'), blockNumber: 14_760_011 }] },
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
  killed.engine.commitmentListener = (...args) => {
    if (++pages === 3) throw new Error('killed');
    return own(...args);
  };
  await assert.rejects(storedByArchive(server, { store, harness: killed }), /killed/);

  const resumed = await engineHarness({ store });
  const { tree, index } = await resumed.merkletree.getLatestTreeAndIndex();
  const startingBlock = (await resumed.merkletree.getCommitment(tree, index)).blockNumber;
  const { stored } = await storedByArchive(server, { store, startingBlock, harness: resumed });
  assert.deepEqual(stored, await storedBySquid());
});

test('a sync within a day of the newest block never asks the archive', async () => {
  const server = archiveServer(fixture, { sealedAt });
  const head = { blockNumber: fixture.to + 100, timestamp: blockTime(fixture.to + 100) };
  const { stored } = await storedByArchive(server, { head });
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

/** The archive with a prebuilt tree 0 of every fixture leaf, published as the active tree. */
function serverWithTree() {
  const leaves = fixture.archive.commitments.flatMap(({ commitments }) => commitments.map(({ hash }) => hash.padStart(64, '0')));
  const file = gz(treeFile(leaves));
  const root = treeLevels(leaves)[16][0];
  return archiveServer(fixture, {
    sealedAt,
    trees: {
      snapshot: { active: { utxo: { tree: 0, leafCount: leaves.length, root, checksum: hashOf(file), bytes: file.length } } },
      files: { 'tip/tree-utxo-active.bin.gz': file },
    },
  });
}

async function withRootCheck(accepted, run) {
  const validate = RailgunEngine.validateMerkleroot;
  const hash = poseidon.poseidonHex;
  let hashed = 0;
  RailgunEngine.validateMerkleroot = async () => accepted;
  poseidon.poseidonHex = (inputs) => {
    hashed += 1;
    return hash(inputs);
  };
  try {
    return { ...(await run()), hashed };
  } finally {
    RailgunEngine.validateMerkleroot = validate;
    poseidon.poseidonHex = hash;
  }
}

test("a prebuilt tree whose root Railgun's contract accepts stands in for hashing, to the same tree", async () => {
  const hashing = await withRootCheck(false, () => storedByArchive(serverWithTree()));
  const copied = await withRootCheck(true, () => storedByArchive(serverWithTree()));
  assert.deepEqual(copied.stored, hashing.stored);
  assert.deepEqual(copied.stored, await storedBySquid());
  assert.ok(copied.hashed < hashing.hashed / 4, `${copied.hashed} hashes with the tree, ${hashing.hashed} without`);
});

test('a prebuilt tree that is not the one the manifest names is never used', async () => {
  const server = serverWithTree();
  const leaves = fixture.archive.commitments.flatMap(({ commitments }) => commitments.map(({ hash }) => hash));
  leaves[3] = word('not a leaf', 31);
  const file = gz(treeFile(leaves));
  server.files.set('tip/tree-utxo-active.bin.gz', file);
  server.setManifest((manifest) => ({
    ...manifest,
    treeSnapshot: { ...manifest.treeSnapshot, active: { utxo: { ...manifest.treeSnapshot.active.utxo, checksum: hashOf(file) } } },
  }));
  const hashing = await withRootCheck(false, () => storedByArchive(serverWithTree()));
  const refused = await withRootCheck(true, () => storedByArchive(server));
  assert.equal(refused.hashed, hashing.hashed);
  assert.deepEqual(refused.stored, await storedBySquid());
});
