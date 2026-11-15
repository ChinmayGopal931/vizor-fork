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
import { formatCommitments, installQuickSync } from '../src/quick-sync.js';
import {
  ARCHIVE_OFF_MS,
  REBUILD_AFTER_MS,
  REBUILD_EVERY_MS,
  archiveOff,
  localStore,
  rebuildTrees,
  takeRefusedRoot,
  treeRecovery,
} from '../src/tree-recovery.js';
import { CHAIN, ENGINE, V2, contents, engineHarness, wholeEngine } from './engine-harness.mjs';
import { history, indexer, word } from './history-fixture.mjs';

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

/** The roots the contract records for the fixture, one after each batch, as `tree:root`. */
async function contractRoots() {
  const { engine, merkletree } = await engineHarness();
  const roots = new Set();
  for (const batch of formatCommitments(fixture.squid.commitments)) {
    await engine.commitmentListener(V2, CHAIN, [batch], false, false);
    await merkletree.updateTreesFromWriteQueue(true);
    roots.add(`${batch.treeNumber}:${await merkletree.getRoot(batch.treeNumber)}`);
  }
  return roots;
}
const ROOTS = await contractRoots();

/**
 * The contract as a scan reads it: the roots it has had (`roots`, as `tree:root`), and its logs past the quick sync,
 * none unless `logs()` throws.
 */
const contract = ({ roots = ROOTS, logs = () => {} } = {}) => ({
  contract: { runner: { provider: { getBlockNumber: async () => fixture.to } } },
  validateMerkleroot: async (tree, root) => roots.has(`${tree}:${root}`),
  getHistoricalEvents: async (_from, to, _next, _commitments, _nullifiers, _unshields, synced) => {
    logs();
    await synced(to);
  },
});

/** A whole engine quick syncing from rail-squid (`queries`, paged by `pageSize`), and how each of its scans ended. */
async function engineOn({ Engine, queries = indexer(fixture.squid, PAGE).queries, pageSize = PAGE, roots, logs } = {}) {
  const built = await wholeEngine({ Engine, contract: contract({ roots, logs }), deploymentBlock: fixture.from });
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
  assert.deepEqual(takeRefusedRoot(), { tree: 0, root });
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
