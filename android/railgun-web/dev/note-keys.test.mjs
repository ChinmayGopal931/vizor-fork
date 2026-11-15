import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { after, test } from 'node:test';
import { ByteLength, ByteUtils, CommitmentType } from '@railgun-community/engine';
import { throughNoteKeyBatches, throughPreparedKeys, throughPreparedLegacyKeys } from '../engine-hooks-plugin.mjs';
import { prepareKeys, preparedKey, preparedLegacyKey, useKeyPool, workerPool } from '../src/note-keys.js';
import { multiplyAll } from '../src/note-keys-worker.js';
import { installQuickSync } from '../src/quick-sync.js';
import { CHAIN, ENGINE, V2, builtEngineModule, wholeEngine } from './engine-harness.mjs';
import { history, indexer } from './history-fixture.mjs';
import { ENCRYPTION_KEY, mnemonicOf, transfer, walletOn, withNotes } from './notes-fixture.mjs';

const require = createRequire(import.meta.url);
const load = (module) => require(path.join(ENGINE, module));
const { getSharedSymmetricKey, getPrivateScalarFromPrivateKey } = load('utils/keys-utils');
const { getSharedSymmetricKeyLegacy } = load('utils/keys-utils-legacy');
const { scalarMultiply } = require('@railgun-community/curve25519-scalarmult-wasm');
const ed = require('@noble/ed25519');

after(() => useKeyPool(async () => null));

/** A stand-in for the Web Workers: the worker's own multiplication, run here. `asked` counts the points. */
function inProcessPool({ products: tamper } = {}) {
  const pool = {
    asked: 0,
    async multiply(scalar, points) {
      pool.asked += points.length / 32;
      const answer = multiplyAll(scalarMultiply, scalar, points);
      return tamper === undefined ? answer : { ...answer, products: tamper(answer.products) };
    },
    close() {},
  };
  return pool;
}

const point = () => ed.Point.BASE.multiply(BigInt(`0x${randomBytes(32).toString('hex')}`) % ed.CURVE.l).toRawBytes();
const hex = (bytes) => Buffer.from(bytes).toString('hex');
const EDGES = [
  Uint8Array.from(Buffer.from(`01${'00'.repeat(31)}`, 'hex')),
  Uint8Array.from(Buffer.from(`ed${'ff'.repeat(30)}7f`, 'hex')),
  Uint8Array.from(Buffer.from('c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a', 'hex')),
];

test("the worker's products are the engine's own, and a point it can't multiply is marked failed", async () => {
  const privateKey = randomBytes(32);
  const scalar = ByteUtils.nToBytes(await getPrivateScalarFromPrivateKey(privateKey), ByteLength.UINT_256);
  const points = [...Array.from({ length: 50 }, point), ...EDGES, ...Array.from({ length: 50 }, () => randomBytes(32))];
  const packed = new Uint8Array(points.length * 32);
  points.forEach((bytes, i) => packed.set(bytes, i * 32));
  const { products, failed } = multiplyAll(scalarMultiply, scalar, packed);
  let refused = 0;
  for (const [i, bytes] of points.entries()) {
    const legacy = await getSharedSymmetricKeyLegacy(privateKey, bytes);
    if (failed[i] === 1) {
      refused += 1;
      assert.equal(legacy, undefined, `point ${i}: the engine refuses it too`);
    } else {
      assert.equal(hex(products.subarray(i * 32, i * 32 + 32)), hex(legacy), `point ${i}`);
    }
  }
  assert.ok(refused > 10 && refused < 50, `${refused} of 50 random byte strings refused`);
});

/** Leaves of each kind whose keys the engine works out, `points` holding the points in each. */
function leavesOf(points) {
  const at = (i) => `0x${hex(points[i])}`;
  return [
    {
      commitmentType: CommitmentType.TransactCommitmentV2,
      ciphertext: { blindedSenderViewingKey: at(0), blindedReceiverViewingKey: at(1) },
    },
    { commitmentType: CommitmentType.ShieldCommitment, shieldKey: hex(points[2]) },
    { commitmentType: CommitmentType.LegacyEncryptedCommitment, ciphertext: { ephemeralKeys: [at(3), at(4)] } },
    { commitmentType: CommitmentType.LegacyGeneratedCommitment },
    null,
  ];
}
const typeOf = (leaf) => leaf.commitmentType;

test('a batch prepares the key the engine works out for each point, and only until it is released', async () => {
  const pool = inProcessPool();
  useKeyPool(async () => pool);
  const privateKey = randomBytes(32);
  const points = Array.from({ length: 5 }, point);
  const { release } = await prepareKeys(privateKey, leavesOf(points), typeOf);
  assert.equal(pool.asked, 5);
  for (const i of [0, 1, 2]) {
    assert.equal(hex(preparedKey(privateKey, points[i])), hex(await getSharedSymmetricKey(privateKey, points[i])));
    assert.equal(preparedLegacyKey(privateKey, points[i]), undefined);
  }
  for (const i of [3, 4]) {
    assert.equal(
      hex(preparedLegacyKey(privateKey, points[i])),
      hex(await getSharedSymmetricKeyLegacy(privateKey, points[i])),
    );
  }
  assert.equal(preparedKey(randomBytes(32), points[0]), undefined, "another wallet's key is never prepared");
  release();
  assert.equal(preparedKey(privateKey, points[0]), undefined);
});

test('a note its sender sent back to itself has one point, worked out once', async () => {
  const pool = inProcessPool();
  useKeyPool(async () => pool);
  const privateKey = randomBytes(32);
  const change = point();
  const leaves = [
    {
      commitmentType: CommitmentType.TransactCommitmentV2,
      ciphertext: { blindedSenderViewingKey: `0x${hex(change)}`, blindedReceiverViewingKey: `0x${hex(change)}` },
    },
  ];
  const { release } = await prepareKeys(privateKey, leaves, typeOf);
  assert.equal(pool.asked, 1);
  assert.equal(hex(preparedKey(privateKey, change)), hex(await getSharedSymmetricKey(privateKey, change)));
  release();
});

test('a point the workers refuse is left for the engine to work out', async () => {
  useKeyPool(async () => inProcessPool());
  const privateKey = randomBytes(32);
  const notAPoint = Uint8Array.from(Buffer.from(`02${'00'.repeat(30)}80`, 'hex'));
  const points = [point(), notAPoint, point(), point(), point()];
  const { release } = await prepareKeys(privateKey, leavesOf(points), typeOf);
  if ((await getSharedSymmetricKeyLegacy(privateKey, notAPoint)) === undefined) {
    assert.equal(preparedKey(privateKey, notAPoint), undefined);
  }
  assert.ok(preparedKey(privateKey, points[0]) !== undefined);
  release();
});

test('a batch the workers fail prepares nothing, and after a second the page leaves every key to the engine', async () => {
  let made = 0;
  useKeyPool(async () => {
    made += 1;
    return {
      multiply: async () => {
        throw new Error('a worker failed');
      },
      close() {},
    };
  });
  const privateKey = randomBytes(32);
  const points = Array.from({ length: 5 }, point);
  for (let batch = 0; batch < 4; batch += 1) {
    const { release } = await prepareKeys(privateKey, leavesOf(points), typeOf);
    assert.equal(preparedKey(privateKey, points[0]), undefined);
    release();
  }
  assert.equal(made, 2, 'started again once after the first failure, never after the second');
});

test("without workers, every key is the engine's to work out", async () => {
  useKeyPool(async () => null);
  const privateKey = randomBytes(32);
  const points = Array.from({ length: 5 }, point);
  await prepareKeys(privateKey, leavesOf(points), typeOf);
  assert.equal(preparedKey(privateKey, points[0]), undefined);
});

/** Stand-ins for Web Workers, answering note-keys-worker.js's messages as it does, or never when `silent`. */
function workers(count, { silent = false } = {}) {
  return Array.from({ length: count }, () => {
    const worker = {
      batches: 0,
      terminated: false,
      postMessage({ id, scalar, points }) {
        worker.batches += 1;
        if (silent) return;
        setTimeout(() => worker.onmessage({ data: { id, ...multiplyAll(scalarMultiply, scalar, points) } }));
      },
      terminate() {
        worker.terminated = true;
      },
    };
    return worker;
  });
}

test('a pool splits a batch among its workers and puts their products back in order', async () => {
  const pool = workers(3);
  const scalar = ByteUtils.nToBytes(await getPrivateScalarFromPrivateKey(randomBytes(32)), ByteLength.UINT_256);
  const points = Array.from({ length: 10 }, point);
  const packed = new Uint8Array(points.length * 32);
  points.forEach((bytes, i) => packed.set(bytes, i * 32));
  const expected = multiplyAll(scalarMultiply, scalar, packed.slice());
  const answer = await workerPool(pool).multiply(scalar, packed);
  assert.deepEqual(answer, expected);
  assert.deepEqual(
    pool.map(({ batches }) => batches),
    [1, 1, 1],
  );
});

test('a pool whose workers keep a batch past its time fails it, and stops them when closed', async () => {
  const pool = workers(2, { silent: true });
  const answering = workerPool(pool, { timeoutMs: 20 });
  await assert.rejects(answering.multiply(new Uint8Array(32), new Uint8Array(64)), /in time/);
  answering.close();
  assert.ok(pool.every(({ terminated }) => terminated));
});

// A whole engine whose wallets scan through the build's note keys: its keys, wallets and their scans rewritten.
const keysUtils = builtEngineModule('utils/keys-utils.js', throughPreparedKeys);
const keysUtilsLegacy = builtEngineModule('utils/keys-utils-legacy.js', throughPreparedLegacyKeys, {
  './keys-utils': keysUtils,
});
const abstractWallet = builtEngineModule('wallet/abstract-wallet.js', throughNoteKeyBatches, {
  '../utils/keys-utils': keysUtils,
  '../utils/keys-utils-legacy': keysUtilsLegacy,
});
const { RailgunWallet: KeyedWallet } = builtEngineModule('wallet/railgun-wallet.js', (source) => source, {
  './abstract-wallet': abstractWallet,
  '../utils/keys-utils': keysUtils,
});

const PAGE = 40;
const fixture = history();
const at = (offset) =>
  fixture.squid.commitments.find(({ blockNumber }) => Number(blockNumber) >= fixture.from + offset).treePosition;
const contract = {
  contract: { runner: { provider: { getBlockNumber: async () => fixture.to } } },
  validateMerkleroot: async () => true,
  getHistoricalEvents: async (_from, to, _next, _commitments, _nullifiers, _unshields, synced) => synced(to),
};

/** What `seed`'s wallet finds scanning `lists`, its scans through the build's note keys when `keyed`. */
async function scanned(lists, seed, { keyed }) {
  const built = await wholeEngine({ contract, deploymentBlock: fixture.from });
  installQuickSync(built.engine, {
    queries: indexer(lists, PAGE).queries,
    head: async () => fixture.to,
    pages: { pageSize: PAGE, gapMs: 0, retryMs: 0 },
  });
  const wallet = keyed
    ? await KeyedWallet.fromMnemonic(
        built.engine.db,
        ENCRYPTION_KEY,
        mnemonicOf(seed),
        0,
        undefined,
        built.engine.prover,
      )
    : await walletOn(built.engine, CHAIN, seed);
  if (keyed) await built.engine.loadWallet(wallet);
  await built.engine.scanUTXOHistory(V2, CHAIN, [wallet.id]);
  const txos = await wallet.TXOs(V2, CHAIN);
  return txos.map(({ note, position, spendtxid }) => `${position}:${note.value}:${spendtxid ?? '-'}`).sort();
}

test("a scan through the build's note keys finds exactly the notes the engine's own finds", async () => {
  const keys = await wholeEngine({ contract, deploymentBlock: fixture.from });
  const sender = await walletOn(keys.engine, CHAIN, 'sender');
  const receiver = await walletOn(keys.engine, CHAIN, 'receiver');
  const lists = withNotes(
    fixture,
    [at(5), at(60), at(110)],
    [
      await transfer(sender, receiver, 1_000n),
      await transfer(sender, receiver, 2_000n),
      await transfer(receiver, sender, 3_000n),
    ],
  ).squid;
  const pool = inProcessPool();
  useKeyPool(async () => pool);
  const own = await scanned(lists, 'receiver', { keyed: false });
  assert.equal(own.length, 2);
  assert.deepEqual(await scanned(lists, 'receiver', { keyed: true }), own);
  assert.ok(pool.asked >= fixture.leaves, `${pool.asked} points worked out ahead`);
  // Keys the workers got wrong would be taken as they are: so a scan through them shows the keys are the workers'.
  useKeyPool(async () => inProcessPool({ products: (products) => products.map((byte) => byte ^ 1) }));
  assert.deepEqual(await scanned(lists, 'receiver', { keyed: true }), []);
});
