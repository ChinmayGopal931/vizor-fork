import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { TXIDVersion } from '@railgun-community/shared-models';
import { ENGINE_VERSION, checkEngineVersion, throughUnshieldWatermark } from '../engine-hooks-plugin.mjs';
import * as unshieldEvents from '../src/unshield-events.js';
import { memoryDatabase } from './memory-store.mjs';

const require = createRequire(import.meta.url);
const ENGINE = path.dirname(require.resolve('@railgun-community/engine'));
const UTXO_MERKLETREE = path.join(ENGINE, 'merkletree/utxo-merkletree.js');
const UNSHIELD_EVENTS = fileURLToPath(new URL('../src/unshield-events.js', import.meta.url));
const CHAIN = { type: 0, id: 1 };

await require(path.join(ENGINE, 'utils/poseidon')).initPoseidonPromise;

/** The engine's UTXOMerkletree as the build bundles it. */
function builtUTXOMerkletree() {
  const engineRequire = createRequire(UTXO_MERKLETREE);
  const module = { exports: {} };
  const source = throughUnshieldWatermark(readFileSync(UTXO_MERKLETREE, 'utf8'));
  const load = vm.compileFunction(source, ['exports', 'require', 'module', '__filename', '__dirname'], {
    filename: UTXO_MERKLETREE,
  });
  const resolve = (id) => (id === UNSHIELD_EVENTS ? unshieldEvents : engineRequire(id));
  load(module.exports, resolve, module, UTXO_MERKLETREE, path.dirname(UTXO_MERKLETREE));
  return module.exports.UTXOMerkletree;
}

const UTXOMerkletree = builtUTXOMerkletree();

/** A page's merkletree over `db`, and the blocks of the events it looked up before storing. */
async function page(db) {
  const merkletree = await UTXOMerkletree.create(db, CHAIN, TXIDVersion.V2_PoseidonMerkle, async () => true);
  const lookedUp = [];
  const lookUp = merkletree.hasExistingUnshieldEvent.bind(merkletree);
  merkletree.hasExistingUnshieldEvent = (unshield) => {
    lookedUp.push(unshield.blockNumber);
    return lookUp(unshield);
  };
  return { merkletree, lookedUp };
}

const hex = (n, bytes) => n.toString(16).padStart(bytes * 2, '0');

const unshield = (block, index = 0, extra = {}) => ({
  txid: hex(block, 16) + hex(index, 16),
  timestamp: 1_700_000_000 + block * 12,
  eventLogIndex: index,
  toAddress: `0x${'ab'.repeat(20)}`,
  tokenType: 0,
  tokenAddress: `0x${'cd'.repeat(20)}`,
  tokenSubID: '0x00',
  amount: '0x64',
  fee: '0x01',
  blockNumber: block,
  ...extra,
});

const blocks = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => unshield(from + i));

async function stored(merkletree, block, index = 0) {
  const [event] = await merkletree.getAllUnshieldEventsForTxid(hex(block, 16) + hex(index, 16));
  return event;
}

const storedEventCount = (down) => [...down.store.keys()].filter((key) => key.split(':').length === 6).length;

test('a first sync stores its unshield events without looking any up', async () => {
  const { db, down } = memoryDatabase();
  const { merkletree, lookedUp } = await page(db);
  await merkletree.addUnshieldEvents(blocks(1, 50));
  await merkletree.addUnshieldEvents(blocks(51, 100));
  assert.deepEqual(lookedUp, []);
  assert.equal(storedEventCount(down), 100);
  assert.equal((await stored(merkletree, 100)).blockNumber, 100);
});

test('events at or below the highest stored block are looked up, and a stored one keeps what syncs added to it', async () => {
  const { db } = memoryDatabase();
  const { merkletree, lookedUp } = await page(db);
  await merkletree.addUnshieldEvents(blocks(1, 10));
  // A txid sync gave block 7's event its railgunTxid.
  await merkletree.updateUnshieldEvent({ ...unshield(7), railgunTxid: 'aa'.repeat(32) });
  assert.deepEqual(lookedUp, []);

  // The next sync starts again at block 7: 7 to 10 are stored already, 11 and 12 are new.
  await merkletree.addUnshieldEvents(blocks(7, 12));
  assert.deepEqual(lookedUp.sort((a, b) => a - b), [7, 8, 9, 10]);
  assert.equal((await stored(merkletree, 7)).railgunTxid, 'aa'.repeat(32));
  assert.equal((await stored(merkletree, 12)).blockNumber, 12);
});

test('a first sync killed partway through its unshield writes skips the lookups for the rest when it resumes', async () => {
  const { db, down } = memoryDatabase();
  const killed = await page(db);
  await killed.merkletree.addUnshieldEvents(blocks(1, 40));
  await killed.merkletree.addUnshieldEvents(blocks(41, 80));

  // A new page over the same database, as after a kill. Its sync starts from an earlier block and goes past the end.
  const resumed = await page(db);
  await resumed.merkletree.addUnshieldEvents(blocks(61, 100));
  await resumed.merkletree.addUnshieldEvents(blocks(101, 140));
  assert.deepEqual(
    resumed.lookedUp.sort((a, b) => a - b),
    Array.from({ length: 20 }, (_, i) => 61 + i),
  );
  assert.equal(storedEventCount(down), 140);
});

test('an event twice in one page is stored once, without a lookup', async () => {
  const { db, down } = memoryDatabase();
  const { merkletree, lookedUp } = await page(db);
  await merkletree.addUnshieldEvents([unshield(5), unshield(6), unshield(6), unshield(6, 1)]);
  assert.deepEqual(lookedUp, []);
  assert.equal(storedEventCount(down), 3);
});

test('two adds at once leave the watermark at the higher block', async () => {
  const { db } = memoryDatabase();
  const { merkletree, lookedUp } = await page(db);
  await Promise.all([merkletree.addUnshieldEvents(blocks(150, 200)), merkletree.addUnshieldEvents(blocks(100, 120))]);
  lookedUp.length = 0;
  // Looked up, so the watermark stayed at 200 rather than falling back to the later add's 120.
  await merkletree.addUnshieldEvents([unshield(180, 9)]);
  assert.deepEqual(lookedUp, [180]);
});

test('once the engine clears its unshield events, the next sync is a first sync again', async () => {
  const { db } = memoryDatabase();
  const { merkletree, lookedUp } = await page(db);
  await merkletree.addUnshieldEvents(blocks(1, 30));
  await db.clearNamespace(merkletree.getUnshieldEventsDBPath(undefined, undefined, undefined));
  await merkletree.addUnshieldEvents(blocks(1, 30));
  assert.deepEqual(lookedUp, []);
});

test('events stored before the watermark existed are read through once, then kept to', async () => {
  const { db } = memoryDatabase();
  const { merkletree, lookedUp } = await page(db);
  // As an earlier build stored them: the events alone.
  await db.batch(
    blocks(1, 20).map((event) => ({
      type: 'put',
      key: merkletree.getUnshieldEventsDBPath(event.txid, event.eventLogIndex, undefined).join(':'),
      value: event,
    })),
    'json',
  );
  // Reads of the events themselves, not just their keys as the engine's lookups and counts make.
  let reads = 0;
  const readStream = db.level.createReadStream.bind(db.level);
  db.level.createReadStream = (options) => {
    if (options.values) reads += 1;
    return readStream(options);
  };
  await merkletree.addUnshieldEvents(blocks(19, 22));
  await merkletree.addUnshieldEvents(blocks(23, 25));
  assert.equal(reads, 1);
  assert.deepEqual(lookedUp.sort((a, b) => a - b), [19, 20]);
});

test("the engine's own replacements are written as before, without lookups", async () => {
  const { db } = memoryDatabase();
  const { merkletree, lookedUp } = await page(db);
  await merkletree.addUnshieldEvents([unshield(3)]);
  await merkletree.addUnshieldEvents([{ ...unshield(3), poisPerList: { list: 'Valid' } }], true);
  assert.deepEqual(lookedUp, []);
  assert.deepEqual((await stored(merkletree, 3)).poisPerList, { list: 'Valid' });
});

test("the rewrite applies to the pinned engine's addUnshieldEvents, and to nothing else", () => {
  const source = readFileSync(UTXO_MERKLETREE, 'utf8');
  const rewritten = throughUnshieldWatermark(source);
  assert.notEqual(rewritten, source);
  assert.ok(rewritten.includes(JSON.stringify(UNSHIELD_EVENTS)));
  assert.throws(() => throughUnshieldWatermark(source.replace('const hasExisting =', 'const exists =')), /changed/);
  assert.throws(() => throughUnshieldWatermark(`${source}\n${source}`), /changed/);
});

test('the build refuses any other engine version', () => {
  const installed = JSON.parse(readFileSync(path.join(ENGINE, '../package.json'), 'utf8')).version;
  assert.equal(installed, ENGINE_VERSION);
  assert.doesNotThrow(() => checkEngineVersion(ENGINE_VERSION));
  assert.throws(() => checkEngineVersion('9.8.1'), /9\.8\.0/);
});
