import { ArtifactStore, clearArtifactCache } from '@railgun-community/wallet';

const DB_NAME = 'railgun-artifacts';
const STORE = 'files';

let opened;

function database() {
  opened ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }).catch((error) => {
    opened = undefined;
    throw error;
  });
  return opened;
}

async function run(mode, action) {
  const db = await database();
  return new Promise((resolve, reject) => {
    const request = action(db.transaction(STORE, mode).objectStore(STORE));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

/** Circuit artifacts the SDK downloads, all but the vkey hash-checked, kept in their own IndexedDB. */
export const artifactStore = new ArtifactStore(
  async (path) => {
    const item = await run('readonly', (store) => store.get(path));
    if (item === undefined) throw new Error(`missing artifact ${path}`);
    return typeof item === 'string' ? item : Buffer.from(item.buffer, item.byteOffset, item.byteLength);
  },
  (_dir, path, item) =>
    run('readwrite', (store) => store.put(typeof item === 'string' ? item : new Uint8Array(item), path)),
  async (path) => (await run('readonly', (store) => store.count(path))) > 0,
);

/**
 * Drops every circuit's kept verification key, from the store and from the SDK's memory: the next proof of each
 * circuit fetches its key afresh.
 */
export async function dropVerificationKeys() {
  const keys = await run('readonly', (store) => store.getAllKeys());
  for (const key of keys) {
    if (typeof key === 'string' && key.endsWith('/vkey.json')) await run('readwrite', (store) => store.delete(key));
  }
  clearArtifactCache();
}

/**
 * snarkjs's `groth16` as the engine takes it, but for a proof of the page's own that its circuit's verification key
 * refuses: every kept key is dropped (`drop`), and the proof still fails. The SDK checks every circuit file against
 * its pinned hashes but the key, which checks nothing but the page's own proofs before they go out (the contract
 * verifies with its own keys). A key the gateway or the mirror served wrong would fail every proof of its circuit for
 * good, kept as it came; the proving files are hash-checked, so a refusal points at the key, and the next try fetches
 * it again.
 */
export function withKeysDroppedOnRefusal(groth16, drop = dropVerificationKeys) {
  return {
    fullProve: (...args) => groth16.fullProve(...args),
    async verify(...args) {
      const valid = await groth16.verify(...args);
      if (!valid) await drop().catch(() => {});
      return valid;
    },
  };
}
