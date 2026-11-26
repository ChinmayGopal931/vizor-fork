import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import {
  EngineEvent,
  MerkletreeScanStatus,
  RailgunEngine,
  createRailgunTransactionWithHash,
} from '@railgun-community/engine';
import { throughRailgunEngineHooks, throughRootRefusals, withoutRescanTxidReset } from '../engine-hooks-plugin.mjs';
import { formatCommitments, guardQuickSync, installQuickSync, takeQuickSyncStop } from '../src/quick-sync.js';
import {
  ARCHIVE_OFF_MS,
  REBUILD_AFTER_MS,
  REBUILD_EVERY_MS,
  RPC_LAG_BLOCKS,
  archiveOff,
  localStore,
  rebuildTrees,
  rpcBehindLeaf,
  takeFailedTree,
  takeRefusedRoot,
  treeRecovery,
} from '../src/tree-recovery.js';
import { CHAIN, ENGINE, V2, contents, engineHarness, wholeEngine } from './engine-harness.mjs';
import { history, indexer, word } from './history-fixture.mjs';
import { shield, someone, withAmount, withNotes } from './notes-fixture.mjs';

const MINUTE = 60_000;
let stores = 0;

/** A recovery on a clock the test moves, whose rebuilds begin unless `busy()`; counts them. */
function recovery({ busy = () => false } = {}) {
  let clock = 1_000_000;
  const store = localStore(`tree-recovery-test-${(stores += 1)}`);
  const rebuilds = [];
  const recovered = treeRecovery({
    rebuild: async ({ started, cleared }) => {
      if (busy()) return false;
      assert.equal(store.read().rebuilding, undefined, 'nothing is kept before the rebuild begins');
      started();
      assert.deepEqual(store.read().rebuilding, { since: clock, cleared: false }, 'kept unfinished as clearing begins');
      assert.ok(
        archiveOff(store, () => clock),
        'the archive is off as the clearing begins',
      );
      cleared();
      assert.equal(store.read().rebuilding.cleared, true);
      rebuilds.push(clock);
      return true;
    },
    store,
    now: () => clock,
  });
  return {
    store,
    rebuilds,
    recovered,
    now: () => clock,
    /** A scan that broke `minutes` after the last one, its end-of-scan check refusing `refused` (none if undefined). */
    async broke(minutes, refused) {
      clock += minutes * MINUTE;
      return recovered.broke(refused);
    },
    /** A scan that completed `minutes` after the last one. */
    passed(minutes) {
      clock += minutes * MINUTE;
      recovered.passed();
    },
  };
}

const wrong = { tree: 3, root: 'aa' };

test('a root the end-of-scan check refuses three times over ten minutes has the trees rebuilt, the archive off a week', async () => {
  const r = recovery();
  assert.equal(await r.broke(0, wrong), false);
  assert.equal(await r.broke(5, wrong), false);
  assert.equal(await r.broke(5, wrong), true);
  assert.equal(r.rebuilds.length, 1);
  assert.ok(archiveOff(r.store, r.now));
  assert.ok(!archiveOff(r.store, () => r.now() + ARCHIVE_OFF_MS));
  // Recorded as done once it completes, the count with it.
  assert.equal(r.store.read().rebuiltAt, r.now());
  assert.equal(r.store.read().rebuilding, undefined);
  assert.equal(r.store.read().failing, undefined);
});

test('a scan that broke before its end-of-scan check counts for nothing, whatever root its store ends at', async () => {
  const r = recovery();
  for (const minutes of [0, 10, 10, 10]) assert.equal(await r.broke(minutes, undefined), false);
  assert.deepEqual(r.store.read(), {});
  // Nor does it start the count again.
  assert.equal(await r.broke(0, wrong), false);
  assert.equal(await r.broke(5, undefined), false);
  assert.equal(await r.broke(1, wrong), false);
  assert.equal(await r.broke(5, wrong), true);
});

test('a scan that completes starts the count again: a root an RPC catches up to never rebuilds', async () => {
  const r = recovery();
  assert.equal(await r.broke(0, wrong), false);
  assert.equal(await r.broke(6, wrong), false);
  r.passed(6);
  assert.equal(await r.broke(6, wrong), false);
  assert.equal(await r.broke(6, wrong), false);
  assert.equal(r.rebuilds.length, 0);
});

test('three quick refusals wait out the ten minutes', async () => {
  const r = recovery();
  for (const minutes of [0, 1, 1]) assert.equal(await r.broke(minutes, wrong), false);
  assert.equal(await r.broke(REBUILD_AFTER_MS / MINUTE, wrong), true);
});

test('a tree whose root moves on with new notes, the leaf stored wrong still under it, counts all the same', async () => {
  const r = recovery();
  assert.equal(await r.broke(0, wrong), false);
  assert.equal(await r.broke(5, { tree: 3, root: 'bb' }), false);
  assert.equal(await r.broke(5, { tree: 3, root: 'cc' }), true);
  assert.equal(r.rebuilds.length, 1);
});

test('a tree short of the contract, or holding a leaf the engine can not read, counts as its refused root does', async () => {
  const r = recovery();
  assert.equal(await r.broke(0, { tree: wrong.tree }), false);
  assert.equal(await r.broke(5, wrong), false);
  assert.equal(await r.broke(5, { tree: wrong.tree }), true);
  assert.equal(r.rebuilds.length, 1);
});

test('another tree starts the count again', async () => {
  const r = recovery();
  const refusals = [wrong, { tree: 2, root: 'bb' }, wrong, wrong];
  for (const [i, refused] of refusals.entries()) assert.equal(await r.broke(i === 0 ? 0 : 6, refused), false);
  assert.equal(r.rebuilds.length, 0);
});

test('the trees are rebuilt at most once a day', async () => {
  const r = recovery();
  for (const minutes of [0, 5, 5]) await r.broke(minutes, wrong);
  assert.equal(r.rebuilds.length, 1);
  for (const minutes of [10, 10, 10]) assert.equal(await r.broke(minutes, wrong), false);
  assert.equal(r.rebuilds.length, 1);
  assert.equal(await r.broke(REBUILD_EVERY_MS / MINUTE, wrong), true);
  assert.equal(r.rebuilds.length, 2);
});

test('a clearing left unfinished goes on at the next refusal too, whatever the count', async () => {
  const clock = 1_000_000;
  const store = localStore(`tree-recovery-test-${(stores += 1)}`);
  store.write({ rebuilding: { since: clock - MINUTE, cleared: false }, archiveOffUntil: clock + ARCHIVE_OFF_MS });
  let rebuilds = 0;
  const reopened = treeRecovery({
    rebuild: async ({ started, cleared }) => {
      started();
      cleared();
      rebuilds += 1;
      return true;
    },
    store,
    now: () => clock,
  });
  assert.equal(await reopened.broke(wrong), true);
  assert.equal(rebuilds, 1);
  assert.equal(store.read().rebuiltAt, clock);
});

test('trees a closed page was building again go on building at the next scan, never cleared again, and the scan that completes ends the rebuild', async () => {
  let clock = 1_000_000;
  const store = localStore(`tree-recovery-test-${(stores += 1)}`);
  let clears = 0;
  const recovered = treeRecovery({
    rebuild: async ({ started, cleared }) => {
      started();
      clears += 1;
      cleared();
      throw new Error('the page closed while the trees were built again');
    },
    store,
    now: () => clock,
  });
  for (const minutes of [0, 5]) {
    clock += minutes * MINUTE;
    await recovered.broke(wrong);
  }
  clock += 5 * MINUTE;
  await assert.rejects(recovered.broke(wrong), /page closed/);
  assert.deepEqual(store.read().rebuilding, { since: clock, cleared: true });

  // Reopened, the page scans on from what it built; a scan cut off before its check changes nothing.
  clock += 60 * MINUTE;
  assert.equal(await recovered.resume(), false);
  assert.equal(await recovered.broke(undefined), false);
  assert.equal(clears, 1);
  recovered.passed();
  assert.equal(store.read().rebuilding, undefined);
  assert.equal(store.read().rebuiltAt, clock);
  assert.ok(
    archiveOff(store, () => clock),
    'the archive stays off for its week',
  );
});

test('trees built again that the end-of-scan check refuses all the same end the rebuild; the count starts there', async () => {
  const clock = 1_000_000;
  const store = localStore(`tree-recovery-test-${(stores += 1)}`);
  store.write({ rebuilding: { since: clock - MINUTE, cleared: true }, archiveOffUntil: clock + ARCHIVE_OFF_MS });
  const recovered = treeRecovery({ rebuild: assert.fail, store, now: () => clock });
  assert.equal(await recovered.broke(wrong), false);
  assert.equal(store.read().rebuilding, undefined);
  assert.equal(store.read().rebuiltAt, clock);
  assert.deepEqual(store.read().failing, { ...wrong, since: clock, checks: 1 });
});

test('with no rebuild left unfinished, resuming does nothing', async () => {
  const r = recovery();
  assert.equal(await r.recovered.resume(), false);
  assert.deepEqual(r.store.read(), {});
});

test("a rebuild that can't begin yet is kept nowhere, and the next refusal tries it again", async () => {
  let busy = true;
  const r = recovery({ busy: () => busy });
  for (const minutes of [0, 5]) await r.broke(minutes, wrong);
  assert.equal(await r.broke(5, wrong), false);
  assert.equal(r.store.read().rebuiltAt, undefined);
  assert.equal(r.store.read().rebuilding, undefined);
  assert.ok(!archiveOff(r.store, r.now));
  busy = false;
  assert.equal(await r.broke(1, wrong), true);
  assert.equal(r.rebuilds.length, 1);
});

// The engine itself, as the build has it, over a short history from rail-squid.

const fixture = history();
const PAGE = 40;
const pages = { pageSize: PAGE, gapMs: 0, retryMs: 0 };

/** The roots the contract records for the fixture (or for `commitments`), one after each batch, as `tree:root`. */
async function contractRoots(commitments = fixture.squid.commitments) {
  const { engine, merkletree } = await engineHarness();
  const roots = new Set();
  for (const batch of formatCommitments(commitments)) {
    await engine.commitmentListener(V2, CHAIN, [batch], false, false);
    await merkletree.updateTreesFromWriteQueue(true);
    roots.add(`${batch.treeNumber}:${await merkletree.getRoot(batch.treeNumber)}`);
  }
  return roots;
}
const ROOTS = await contractRoots();

/**
 * The contract as a scan reads it: the roots it has had (`roots`, as `tree:root`), its logs past the quick sync, none
 * unless `logs(commitments)` throws or hands the engine's commitments listener some, and the leaves it held in tree 0
 * at a block (`leaves(block)`), none unless a test is about them.
 */
const contract = ({ roots = ROOTS, logs = () => {}, leaves = () => 0 } = {}) => ({
  contract: {
    runner: { provider: { getBlockNumber: async () => fixture.to } },
    treeNumber: async () => 0n,
    nextLeafIndex: async ({ blockTag }) => BigInt(await leaves(blockTag)),
  },
  validateMerkleroot: async (tree, root) => roots.has(`${tree}:${root}`),
  getHistoricalEvents: async (_from, to, _next, commitments, _nullifiers, _unshields, synced) => {
    await logs(commitments);
    await synced(to);
  },
});

/** A whole engine quick syncing from rail-squid (`queries`, paged by `pageSize`), and how each of its scans ended. */
async function engineOn({
  Engine,
  queries = indexer(fixture.squid, PAGE).queries,
  pageSize = PAGE,
  roots,
  logs,
  leaves,
} = {}) {
  const stub = contract({ roots, logs, leaves });
  const built = await wholeEngine({ Engine, contract: stub, deploymentBlock: fixture.from });
  installQuickSync(built.engine, { queries, head: async () => fixture.to, pages: { ...pages, pageSize } });
  const ends = [];
  built.engine.on(EngineEvent.UTXOScanDecryptBalancesComplete, () => ends.push('complete'));
  built.engine.on(EngineEvent.UTXOMerkletreeHistoryScanUpdate, ({ scanStatus }) => {
    if (scanStatus === MerkletreeScanStatus.Incomplete) ends.push('incomplete');
  });
  return { ...built, ends, scan: () => built.engine.scanUTXOHistory(V2, CHAIN, undefined) };
}

test("the engine's end-of-scan check reports the root it refuses, and still fails the scan", async () => {
  const roots = new Set(ROOTS);
  const { utxo, ends, scan } = await engineOn({ roots });
  takeRefusedRoot();
  await scan();
  assert.deepEqual(ends, ['complete']);
  assert.equal(takeRefusedRoot(), undefined);
  // What a leaf stored wrong leaves: a root the contract never had.
  const root = await utxo.getRoot(0);
  roots.delete(`0:${root}`);
  await scan();
  assert.deepEqual(ends, ['complete', 'incomplete']);
  assert.deepEqual(takeRefusedRoot(), { tree: 0, root, index: await utxo.getLatestIndexForTree(0) });
});

test('a tree the engine keeps refusing as new notes move its root on is rebuilt in ten minutes all the same', async () => {
  // A quick sync stored a leaf wrong; later pages give the right history, one more stretch of it each scan.
  let newest = fixture.from + 19;
  const { engine } = await wholeEngine({
    contract: {
      contract: { runner: { provider: { getBlockNumber: async () => newest } } },
      validateMerkleroot: async (tree, root) => ROOTS.has(`${tree}:${root}`),
      getHistoricalEvents: async (_from, to, _next, _commitments, _nullifiers, _unshields, synced) => synced(to),
    },
    deploymentBlock: fixture.from,
  });
  const wrongLeaf = structuredClone(fixture.squid);
  wrongLeaf.commitments[0].hash = BigInt(`0x${word('a leaf stored wrong', 31)}`).toString();
  let clock = 1_000_000;
  let rebuilds = 0;
  const recovered = treeRecovery({
    rebuild: async ({ started, cleared }) => {
      started();
      cleared();
      rebuilds += 1;
      return true;
    },
    store: localStore(`tree-recovery-test-${(stores += 1)}`),
    now: () => clock,
  });
  const refused = [];
  for (let scan = 0; scan < 3; scan += 1) {
    newest = fixture.from + (scan + 1) * 20 - 1;
    const lists = Object.fromEntries(
      Object.entries(scan === 0 ? wrongLeaf : fixture.squid).map(([name, events]) => [
        name,
        events.filter(({ blockNumber }) => Number(blockNumber) <= newest),
      ]),
    );
    installQuickSync(engine, { queries: indexer(lists, PAGE).queries, head: async () => newest, pages });
    takeRefusedRoot();
    await engine.scanUTXOHistory(V2, CHAIN, undefined);
    const root = takeRefusedRoot();
    assert.equal(root?.tree, 0, 'the engine refuses the tree with the leaf stored wrong');
    refused.push(root.root);
    assert.equal(await recovered.broke(root), scan === 2);
    clock += 5 * MINUTE;
  }
  assert.equal(new Set(refused).size, 3, 'every scan refused another root of the tree');
  assert.equal(rebuilds, 1);
});

test('a scan that breaks before its end-of-scan check reports no root, though its store ends at one never recorded', async () => {
  // Rail-squid's first page of commitments ends inside a batch, then it goes down, and the RPC refuses log queries.
  const commitments = fixture.squid.commitments;
  const sameBatch = (i) => commitments[i + 1]?.batchStartTreePosition === commitments[i].batchStartTreePosition;
  const cut = commitments.findIndex((_, i) => i >= PAGE / 2 && sameBatch(i)) + 1;
  const lists = indexer(fixture.squid, cut);
  let pagesGiven = 0;
  const queries = {
    ...lists.queries,
    commitments: async (block) => {
      pagesGiven += 1;
      if (pagesGiven > 1) throw new Error('rail-squid is down');
      return lists.queries.commitments(block);
    },
  };
  const logs = () => {
    throw new Error('the RPC refuses log queries');
  };
  const { utxo, ends, scan } = await engineOn({ queries, pageSize: cut, logs });
  takeRefusedRoot();
  await scan();
  assert.deepEqual(ends, ['incomplete']);
  assert.equal(await utxo.getTreeLength(0), cut, 'the store ends inside a batch');
  assert.ok(!ROOTS.has(`0:${await utxo.getRoot(0)}`));
  assert.equal(takeRefusedRoot(), undefined);
});

/** A transaction for the txid list, as the engine stores one. */
const listed = () =>
  createRailgunTransactionWithHash({
    version: 2,
    graphID: `0x${word('g')}`,
    commitments: [`0x${word('c', 31).padStart(64, '0')}`],
    nullifiers: [`0x${word('n', 31).padStart(64, '0')}`],
    boundParamsHash: word('b', 31).padStart(64, '0'),
    blockNumber: fixture.from,
    timestamp: 0,
    txid: word('tx'),
    utxoTreeIn: 0,
    utxoTreeOut: 0,
    utxoBatchStartPositionOut: 0,
    verificationHash: word('v'),
  });

/** An engine that has scanned the fixture and stored a transaction in its txid list, as a page that synced it has. */
async function synced(options) {
  const built = await engineOn(options);
  await built.scan();
  await built.txids.queueRailgunTransactions([listed()], undefined);
  await built.txids.updateTreesFromWriteQueue();
  return built;
}

test("the engine's own full rescan fails at its end in a page that never synced the transaction list", async () => {
  // What the trees' rebuild ran before: the trees came back, then the list's reset threw, and the list stood.
  const { engine, txids } = await synced({ Engine: RailgunEngine });
  await assert.rejects(engine.fullRescanUTXOMerkletreesAndWallets(CHAIN, undefined), /Must get UTXO history first/);
  assert.notEqual(await txids.getLatestRailgunTransaction(), undefined);
});

test('a rebuild clears the transaction list, then the trees, and builds them as a first sync does', async () => {
  const fresh = await engineOn();
  await fresh.scan();
  const { engine, txids, down, ends } = await synced();
  const order = [];
  const steps = [
    'clearTXIDMerkletreeData',
    'clearUTXOMerkletreeAndLoadedWalletsAllTXIDVersions',
    'clearSyncedUnshieldEvents',
    'scanUTXOHistory',
  ];
  for (const step of steps) {
    const own = engine[step].bind(engine);
    engine[step] = (...args) => {
      order.push(step);
      return own(...args);
    };
  }
  const marks = { started: () => order.push('started'), cleared: () => order.push('cleared') };
  assert.equal(await rebuildTrees(engine, { txidVersion: V2, chain: CHAIN, walletIds: undefined, ...marks }), true);
  assert.deepEqual(order, ['started', ...steps.slice(0, 3), 'cleared', 'scanUTXOHistory']);
  assert.deepEqual(ends, ['complete', 'complete']);
  assert.equal(await txids.getLatestRailgunTransaction(), undefined);
  assert.deepEqual(contents(down), contents(fresh.down));
});

test("a rebuild doesn't begin while the rest of a sync runs, which reads the balances it would clear", async () => {
  const built = await synced();
  const before = contents(built.down);
  let started = false;
  const began = await rebuildTrees(built.engine, {
    txidVersion: V2,
    chain: CHAIN,
    walletIds: undefined,
    busy: () => true,
    started: () => {
      started = true;
    },
  });
  assert.equal(began, false);
  assert.equal(started, false);
  assert.deepEqual(contents(built.down), before);
});

test("a rebuild doesn't begin while the engine syncs the notes or the list, and clears nothing", async () => {
  for (const syncing of ['utxo', 'txids']) {
    const built = await synced();
    const before = contents(built.down);
    built[syncing].isScanning = true;
    let started = false;
    const began = await rebuildTrees(built.engine, {
      txidVersion: V2,
      chain: CHAIN,
      walletIds: undefined,
      started: () => {
        started = true;
      },
    });
    assert.equal(began, false, syncing);
    assert.equal(started, false);
    assert.deepEqual(contents(built.down), before);
  }
});

test('the build rewrites the end-of-scan check and the full rescan, and refuses an engine where either changed', () => {
  const source = readFileSync(path.join(ENGINE, 'railgun-engine.js'), 'utf8');
  const rewritten = throughRailgunEngineHooks(source);
  assert.ok(rewritten.includes('.rootRefused(treeIndex, root, new Error(`Invalid merkleroot: ${root}.'));
  assert.ok(rewritten.includes('Index: ${index}.`), index);'), 'the refusal says which leaf the root follows');
  assert.ok(!rewritten.includes('await this.fullResetTXIDMerkletreesV2(chain);'));
  assert.ok(rewritten.includes('async fullResetTXIDMerkletreesV2(chain) {'), "the engine's reset itself stays");
  assert.throws(
    () => throughRootRefusals(source.replace('Invalid merkleroot: ${root}', 'Invalid merkleroot ${root}')),
    /no longer applies/,
  );
  assert.throws(
    () => withoutRescanTxidReset(source.replace('Must reset txid merkletree', 'Must reset the txid merkletree')),
    /no longer applies/,
  );
});

test("a refusal by an RPC that hasn't reached the tree's newest leaf counts for nothing", () => {
  assert.equal(rpcBehindLeaf(1_000, 999), true, 'the leaf is past the newest block');
  assert.equal(rpcBehindLeaf(1_000, 1_000 + RPC_LAG_BLOCKS - 1), true, 'too close to the newest block to tell');
  assert.equal(rpcBehindLeaf(1_000, 1_000 + RPC_LAG_BLOCKS), false);
  assert.equal(rpcBehindLeaf(undefined, 1_000), false, 'an unread leaf counts the refusal, as before');
  assert.equal(rpcBehindLeaf(1_000, undefined), false, 'an unread newest block counts it too');
});

/**
 * `engineOn`'s engine, its quick sync guarded as the page's is, with `newest` the chain's newest block; its read of the
 * chain hands over `chainCommitments`.
 */
async function guardedEngineOn({ newest, maxChainScanBlocks, chainCommitments = [], ...options }) {
  let reads = 0;
  const logs = async (commitments) => {
    reads += 1;
    if (chainCommitments.length > 0) await commitments(V2, chainCommitments);
  };
  const built = await engineOn({ ...options, logs });
  const head = async () => newest;
  guardQuickSync(built.engine, { txidVersion: V2, chain: CHAIN, head, maxChainScanBlocks, writeRetryMs: 0 });
  takeQuickSyncStop();
  return { ...built, reads: () => reads };
}

const unanswered = {
  nullifiers: async () => Promise.reject(new Error('the indexer did not answer in time')),
  unshields: async () => Promise.reject(new Error('the indexer did not answer in time')),
  commitments: async () => Promise.reject(new Error('the indexer did not answer in time')),
};

test('rail-squid out of reach far behind the newest block stops the scan rather than read the history from the RPC', async () => {
  const { ends, scan, reads } = await guardedEngineOn({
    queries: unanswered,
    newest: fixture.from + 100_001,
    maxChainScanBlocks: 100_000,
  });
  await scan();
  assert.deepEqual(ends, ['incomplete']);
  assert.equal(reads(), 0, "the engine read none of Railgun's events from the RPC");
  assert.match(takeQuickSyncStop(), /indexer did not answer/);
});

test('rail-squid out of reach close to the newest block leaves the gap to the RPC, as before', async () => {
  const { scan, reads } = await guardedEngineOn({
    queries: unanswered,
    newest: fixture.from + 100_000,
    maxChainScanBlocks: 100_000,
  });
  await scan();
  assert.equal(reads(), 1, 'the engine read the gap from the RPC');
  assert.equal(takeQuickSyncStop(), undefined);
});

test('a quick sync whose trees did not take every leaf stops the scan, which would pass the trees short', async () => {
  // A batch rail-squid's commitments skip: the trees stop at it, and the leaves after stay queued.
  const dropped = formatCommitments(fixture.squid.commitments)[3];
  const commitments = fixture.squid.commitments.filter(
    ({ batchStartTreePosition }) => Number(batchStartTreePosition) !== dropped.startPosition,
  );
  const { ends, scan } = await guardedEngineOn({
    queries: indexer({ ...fixture.squid, commitments }, PAGE).queries,
    newest: fixture.to,
  });
  await scan();
  assert.deepEqual(ends, ['incomplete']);
  assert.match(takeQuickSyncStop(), /trees stopped short/);
});

test("a stretch rail-squid left out that the engine's own read fills passes, as it did", async () => {
  // Rail-squid behind the RPC: the leaves after a stretch it hasn't listed wait in the queue until the engine reads it.
  const dropped = formatCommitments(fixture.squid.commitments)[3];
  const commitments = fixture.squid.commitments.filter(
    ({ batchStartTreePosition }) => Number(batchStartTreePosition) !== dropped.startPosition,
  );
  const { ends, scan } = await guardedEngineOn({
    queries: indexer({ ...fixture.squid, commitments }, PAGE).queries,
    newest: fixture.to,
    chainCommitments: [dropped],
  });
  await scan();
  assert.deepEqual(ends, ['complete']);
  assert.equal(takeQuickSyncStop(), undefined);
});

/** The leaves the fixture's chain held at `block`. */
const leavesAt = (block) => fixture.squid.commitments.filter(({ blockNumber }) => Number(blockNumber) <= block).length;

/** Rail-squid's lists as an indexer that has come to `block` gives them, its newest commitment dated `dated` if set. */
function listsThrough(block, dated) {
  const lists = Object.fromEntries(
    Object.entries(fixture.squid).map(([name, events]) => [name, events.filter((e) => Number(e.blockNumber) <= block)]),
  );
  if (dated === undefined) return lists;
  const newest = lists.commitments.at(-1);
  const commitments = lists.commitments.map((c) => (c === newest ? { ...c, blockNumber: String(dated) } : c));
  return { ...lists, commitments };
}

test('a source that dates its newest leaf past leaves it left out stops the scan short of the contract, its tree counted', async () => {
  // Rail-squid half way through the history, its newest commitment dated a million blocks ahead: the engine starts its
  // own read of the chain there, past the chain's newest block, and every later quick sync would too.
  const half = fixture.from + 59;
  const { utxo, ends, scan } = await guardedEngineOn({
    queries: indexer(listsThrough(half, half + 1_000_000), PAGE).queries,
    newest: fixture.to,
    leaves: leavesAt,
  });
  takeFailedTree();
  await scan();
  assert.equal(await utxo.getTreeLength(0), leavesAt(half));
  assert.deepEqual(ends, ['incomplete']);
  const has = `tree 0 has ${leavesAt(half)} leaves`;
  const held = `Railgun's contract ${leavesAt(fixture.to - RPC_LAG_BLOCKS)} in tree 0`;
  assert.equal(takeQuickSyncStop(), `the trees stopped short of the chain: ${has}, and ${held}`);
  assert.deepEqual(takeFailedTree(), { tree: 0 });

  // Dated as the chain has it, the engine reads the rest from the chain itself, and the trees hold every leaf.
  const rest = fixture.squid.commitments.filter(({ blockNumber }) => Number(blockNumber) > half);
  const honest = await guardedEngineOn({
    queries: indexer(listsThrough(half), PAGE).queries,
    newest: fixture.to,
    leaves: leavesAt,
    chainCommitments: formatCommitments(rest),
  });
  await honest.scan();
  assert.equal(await honest.utxo.getTreeLength(0), fixture.leaves);
  assert.deepEqual(honest.ends, ['complete']);
  assert.equal(takeQuickSyncStop(), undefined);
  assert.equal(takeFailedTree(), undefined);
});

test("the contract's leaves are counted a few blocks behind the newest: an RPC's log read can trail its calls", async () => {
  // Trees that end RPC_LAG_BLOCKS before the newest block pass, the last blocks' leaves the next scan's. A block
  // sooner, they fail.
  const behind = (blocks) =>
    guardedEngineOn({
      queries: indexer(listsThrough(fixture.to - blocks), PAGE).queries,
      newest: fixture.to,
      leaves: leavesAt,
    });
  const within = await behind(RPC_LAG_BLOCKS);
  await within.scan();
  assert.deepEqual(within.ends, ['complete']);
  assert.equal(takeQuickSyncStop(), undefined);
  const past = await behind(RPC_LAG_BLOCKS + 1);
  await past.scan();
  assert.deepEqual(past.ends, ['incomplete']);
  assert.match(takeQuickSyncStop(), /^the trees stopped short of the chain/);
  assert.deepEqual(takeFailedTree(), { tree: 0 });
});

test("an RPC that doesn't answer for the contract's leaves stops the scan, and counts nothing against the trees", async () => {
  const { ends, scan } = await guardedEngineOn({
    newest: fixture.to,
    leaves: async () => {
      throw new Error('could not reach https://rpc.example/a-key');
    },
  });
  takeFailedTree();
  await scan();
  assert.deepEqual(ends, ['incomplete']);
  // What the RPC's error says, its address among it, is in no message.
  assert.equal(takeQuickSyncStop(), "the Ethereum RPC does not answer for the leaves Railgun's contract holds");
  assert.equal(takeFailedTree(), undefined);
});

/**
 * Rail-squid listing a shield of 0.001 USDC, three pages in, as a million: `listed`, its lists; `chain`, the
 * commitments as their events have them; and `roots`, the contract's.
 */
async function raisedShield() {
  const at = 3 * PAGE + 5;
  const real = await shield(await someone('a receiver'), 1_000n);
  const honest = withNotes(fixture, [at], [real]).squid;
  const listed = withNotes(fixture, [at], [withAmount(real, 1_000_000_000_000n)]).squid;
  return { at, listed, chain: formatCommitments(honest.commitments), roots: await contractRoots(honest.commitments) };
}

test("a record of rail-squid's that is not the chain's stores nothing of its page, and far behind the newest block stops the scan", async () => {
  const { at, listed, roots } = await raisedShield();
  const { utxo, ends, scan, reads } = await guardedEngineOn({
    queries: indexer(listed, PAGE).queries,
    roots,
    newest: fixture.to + 100_001,
    maxChainScanBlocks: 100_000,
  });
  await scan();
  assert.deepEqual(ends, ['incomplete']);
  assert.equal(reads(), 0, "the engine read none of Railgun's events from the RPC");
  assert.match(
    takeQuickSyncStop(),
    new RegExp(`^the indexer's record at 0:${at} does not hash to its leaf, and \\d+ blocks are too many to read`),
  );
  // The pages before it are in, as after any list that fails; the shield's page is not, a leaf of it.
  const stored = await utxo.getTreeLength(0);
  assert.ok(stored > 0 && stored <= at - 5, `${stored} leaves stored, the shield at ${at}`);
});

test("close to the newest block, the engine reads the blocks of rail-squid's refused record from the chain itself", async () => {
  const { at, listed, chain, roots } = await raisedShield();
  const { utxo, ends, scan, reads } = await guardedEngineOn({
    queries: indexer(listed, PAGE).queries,
    roots,
    newest: fixture.to,
    chainCommitments: chain,
  });
  await scan();
  assert.equal(reads(), 1, 'the engine read the gap from the RPC');
  assert.deepEqual(ends, ['complete']);
  assert.equal(takeQuickSyncStop(), undefined);
  assert.equal(await utxo.getTreeLength(0), fixture.leaves);
  // The leaf holds the amount its event has, which the engine hashed it from.
  assert.equal(BigInt(`0x${(await utxo.getCommitment(0, at)).preImage.value}`), 1_000n);
});
