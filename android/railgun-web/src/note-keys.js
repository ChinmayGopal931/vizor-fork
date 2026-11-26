// Finding a wallet's notes works out a shared key for every leaf, a curve25519 scalar multiplication each and two for
// a transfer: most of a notes scan's time, all of it on the page's one thread. Each batch's keys are worked out ahead
// instead, its points split among Web Workers that run the engine's own WebAssembly, and kept for the engine's
// per-note decryption to take: the build has `scanLeaves` prepare them and the key functions look here first
// (engine-hooks-plugin.mjs). A key not prepared, or a batch that fails, is worked out by the engine itself, as before.
import { ByteLength, ByteUtils, CommitmentType } from '@railgun-community/engine';
// The engine's package exports neither.
import { sha256 } from '../node_modules/@railgun-community/engine/dist/utils/hash.js';
import { getPrivateScalarFromPrivateKey } from '../node_modules/@railgun-community/engine/dist/utils/keys-utils.js';
import workerSource from './note-keys-worker-source.js';
import { pauseMark, pausedSince } from './page-clock.js';

const WASM_FILE = 'curve25519_scalarmult_wasm_bg.wasm';
/** The most workers a batch is split among; a phone keeps two cores besides. */
export const MAX_WORKERS = 6;
/** How long a batch may take before the engine works its keys out itself. */
export const BATCH_TIMEOUT_MS = 60_000;
/** How long the workers may take to start before the page works its keys out on its own thread. */
export const POOL_TIMEOUT_MS = 30_000;
/** Workers left idle this long are stopped; the next batch starts them again. */
export const IDLE_MS = 30_000;
// After this many batches failed, a page works its keys out on its own thread. A batch a pause of the page cut through
// (page-clock.js) doesn't count: the workers stood still with the page, and its timeout came due as the page woke.
const FAILURES_ALLOWED = 2;

const hex = (bytes) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');

// The keys of the batches each wallet's scans are on, by its viewing private key: a set of `{modern, legacy}`, each a
// map by point.
const batches = new WeakMap();
// The page's workers, as a promise: null where they can't run.
let pool;
let makePool = webWorkerPool;
let poolTimeoutMs = POOL_TIMEOUT_MS;
let failures = 0;
let idle;
// What the page's batches came to, for dev/check.mjs.
const counted = { batches: 0, points: 0, refused: 0, prepared: 0, workers: 0 };

/** How many batches and points the workers worked keys out for, how many they refused, and how many workers ran. */
export const noteKeysCounts = () => ({ ...counted, failures });

function prepared(privateKey, kind, point) {
  const scans = batches.get(privateKey);
  if (scans === undefined) return undefined;
  const key = hex(point);
  for (const batch of scans) {
    const found = batch[kind].get(key);
    if (found !== undefined) return found;
  }
  return undefined;
}

/** The key `getSharedSymmetricKey(privateKey, point)` answers, if a batch prepared it. */
export const preparedKey = (privateKey, point) => prepared(privateKey, 'modern', point);

/** The key `getSharedSymmetricKeyLegacy(privateKey, point)` answers, if a batch prepared it. */
export const preparedLegacyKey = (privateKey, point) => prepared(privateKey, 'legacy', point);

/**
 * Has batches use the pool `make()` answers, null for none, given `timeoutMs` to start: dev tests' stand-ins for Web
 * Workers.
 */
export function useKeyPool(make, { timeoutMs = POOL_TIMEOUT_MS } = {}) {
  closePool();
  makePool = make;
  poolTimeoutMs = timeoutMs;
  failures = 0;
}

/** The pool `makePool()` answers, or none if it takes longer than the timeout to start; one that starts later stops. */
function startPool() {
  const making = makePool();
  let timer;
  const late = new Promise((resolve) => {
    timer = setTimeout(() => resolve(null), poolTimeoutMs);
    timer.unref?.();
  });
  return Promise.race([making, late]).then(
    (made) => {
      clearTimeout(timer);
      if (made === null) making.then((workers) => workers?.close()).catch(() => {});
      return made;
    },
    () => {
      clearTimeout(timer);
      return null;
    },
  );
}

function closePool() {
  clearTimeout(idle);
  const closing = pool;
  pool = undefined;
  closing?.then((workers) => workers?.close()).catch(() => {});
}

/**
 * Works out the keys of `leaves`, a batch of a notes scan with `viewingPrivateKey`, and keeps them until `release()`.
 * `commitmentTypeOf` is the engine's own reading of a leaf's type.
 */
export async function prepareKeys(viewingPrivateKey, leaves, commitmentTypeOf) {
  let mine;
  // Only this batch's keys: another scan of the same wallet may be on a batch of its own.
  const release = () => {
    const scans = batches.get(viewingPrivateKey);
    scans?.delete(mine);
    if (scans?.size === 0) batches.delete(viewingPrivateKey);
  };
  const points = pointsOf(leaves, commitmentTypeOf);
  if (points.length === 0 || failures >= FAILURES_ALLOWED) return { release };
  clearTimeout(idle);
  pool ??= startPool();
  const workers = await pool;
  if (workers === null) return { release };
  let mark;
  try {
    const scalar = ByteUtils.nToBytes(await getPrivateScalarFromPrivateKey(viewingPrivateKey), ByteLength.UINT_256);
    const packed = new Uint8Array(points.length * 32);
    points.forEach(({ bytes }, i) => packed.set(bytes, i * 32));
    mark = pauseMark();
    const { products, failed } = await workers.multiply(scalar, packed);
    // Workers whose WebAssembly never started refuse every point, as the engine refuses almost none.
    if (failed.every((refused) => refused !== 0)) throw new Error('the note keys workers refused every point');
    const modern = new Map();
    const legacy = new Map();
    points.forEach(({ key, isLegacy }, i) => {
      if (failed[i] !== 0) return;
      const product = products.slice(i * 32, i * 32 + 32);
      if (isLegacy) legacy.set(key, product);
      else modern.set(key, ByteUtils.hexStringToBytes(sha256(product)));
    });
    mine = { modern, legacy };
    batches.set(viewingPrivateKey, (batches.get(viewingPrivateKey) ?? new Set()).add(mine));
    counted.batches += 1;
    counted.points += points.length;
    counted.refused += failed.reduce((sum, refused) => sum + refused, 0);
    counted.prepared += modern.size + legacy.size;
    counted.workers = workers.size ?? counted.workers;
  } catch {
    // The batch's keys are the engine's to work out; workers that failed are started again for the next.
    if (mark === undefined || !pausedSince(mark)) failures += 1;
    closePool();
  }
  if (pool !== undefined) {
    idle = setTimeout(closePool, IDLE_MS);
    idle.unref?.();
  }
  return { release };
}

/**
 * The points the engine works keys out for in `leaf`, of commitment type `type`, read as the engine reads them
 * (`AbstractWallet.createScannedDBCommitments`): a transfer's two blinded viewing keys, a shield's key, and a legacy
 * note's two ephemeral keys, `{bytes, isLegacy}` each. Throws where the engine's own read throws. The engine reads them
 * before it tries to decrypt the leaf, outside the try that expects a leaf of someone else's, so a leaf this throws on
 * fails the whole batch it is decrypted in (commitment-check.js).
 */
export function leafPoints(leaf, type) {
  const modern = (bytes) => ({ bytes, isLegacy: false });
  const legacy = (bytes) => ({ bytes, isLegacy: true });
  switch (type) {
    case CommitmentType.TransactCommitmentV2:
    case CommitmentType.TransactCommitmentV3:
      return [
        modern(ByteUtils.hexStringToBytes(leaf.ciphertext.blindedSenderViewingKey)),
        modern(ByteUtils.hexStringToBytes(leaf.ciphertext.blindedReceiverViewingKey)),
      ];
    case CommitmentType.ShieldCommitment:
      return [modern(ByteUtils.hexToBytes(leaf.shieldKey))];
    case CommitmentType.LegacyEncryptedCommitment:
      return [
        legacy(ByteUtils.hexStringToBytes(leaf.ciphertext.ephemeralKeys[0])),
        legacy(ByteUtils.hexStringToBytes(leaf.ciphertext.ephemeralKeys[1])),
      ];
    default:
      return [];
  }
}

/**
 * The points the engine works keys out for in `leaves`, each once (one point for a note its sender sent back to
 * itself); a legacy note's key is the bare product.
 */
function pointsOf(leaves, commitmentTypeOf) {
  const points = new Map();
  for (const leaf of leaves) {
    if (leaf == null) continue;
    try {
      for (const { bytes, isLegacy } of leafPoints(leaf, commitmentTypeOf(leaf))) {
        if (bytes.length !== 32) continue;
        const key = hex(bytes);
        points.set(`${isLegacy}:${key}`, { bytes, key, isLegacy });
      }
    } catch {
      // A leaf the engine can't read either: its keys, if any, are the engine's to work out.
    }
  }
  return [...points.values()];
}

/** Web Workers running note-keys-worker.js on the engine's WebAssembly, a core each but two, at most `MAX_WORKERS`. */
async function webWorkerPool() {
  if (workerSource === undefined || typeof Worker === 'undefined') return null;
  const wasm = await fetch(new URL(WASM_FILE, import.meta.url));
  const module = await WebAssembly.compile(await wasm.arrayBuffer());
  const url = URL.createObjectURL(new Blob([workerSource], { type: 'text/javascript' }));
  const cores = globalThis.navigator?.hardwareConcurrency ?? 4;
  const workers = Array.from({ length: Math.min(MAX_WORKERS, Math.max(1, cores - 2)) }, () => {
    const worker = new Worker(url, { type: 'module' });
    worker.postMessage({ module });
    return worker;
  });
  return workerPool(workers);
}

/**
 * Splits each batch of points among `workers` (Web Workers running note-keys-worker.js, or stand-ins that answer the
 * same messages): `multiply(scalar, points)` answers the products and failures as `multiplyAll` packs them. A batch
 * one of them fails, or keeps past `timeoutMs`, fails whole.
 */
export function workerPool(workers, { timeoutMs = BATCH_TIMEOUT_MS } = {}) {
  let asked = 0;
  const waiting = new Map();
  const failAll = (error) => {
    for (const { reject } of waiting.values()) reject(error);
    waiting.clear();
  };
  for (const worker of workers) {
    worker.onmessage = ({ data }) => {
      const pending = waiting.get(data.id);
      if (pending === undefined) return;
      waiting.delete(data.id);
      if (data.error === undefined) pending.resolve(data);
      else pending.reject(new Error(data.error));
    };
    worker.onerror = () => failAll(new Error('a note keys worker failed'));
  }
  const ask = (worker, scalar, points) =>
    new Promise((resolve, reject) => {
      asked += 1;
      waiting.set(asked, { resolve, reject });
      worker.postMessage({ id: asked, scalar, points }, [points.buffer]);
    });
  return {
    size: workers.length,
    async multiply(scalar, points) {
      const count = points.length / 32;
      const share = Math.ceil(count / workers.length);
      const parts = [];
      for (let from = 0, w = 0; from < count; from += share, w += 1) {
        const to = Math.min(count, from + share);
        parts.push(ask(workers[w], scalar, points.slice(from * 32, to * 32)).then((answer) => ({ from, answer })));
      }
      let timer;
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('the note keys workers did not answer in time')), timeoutMs);
      });
      try {
        const answers = await Promise.race([Promise.all(parts), timeout]);
        const products = new Uint8Array(points.length);
        const failed = new Uint8Array(count);
        for (const { from, answer } of answers) {
          products.set(answer.products, from * 32);
          failed.set(answer.failed, from);
        }
        return { products, failed };
      } catch (error) {
        failAll(error);
        throw error;
      } finally {
        clearTimeout(timer);
      }
    },
    close() {
      failAll(new Error('the note keys workers stopped'));
      for (const worker of workers) worker.terminate();
    },
  };
}
