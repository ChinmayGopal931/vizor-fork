// The engine's own merkletrees and event listeners in Node, as the build bundles them (engine-hooks-plugin.mjs), over
// an in-memory store: enough of the engine to store a sync's events exactly as it does on a phone.
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { TXIDVersion } from '@railgun-community/shared-models';
import { throughUnshieldWatermark } from '../engine-hooks-plugin.mjs';
import * as unshieldEvents from '../src/unshield-events.js';
import { memoryDatabase } from './memory-store.mjs';

const require = createRequire(import.meta.url);
export const ENGINE = path.dirname(require.resolve('@railgun-community/engine'));
export const CHAIN = Object.freeze({ type: 0, id: 1 });
export const V2 = TXIDVersion.V2_PoseidonMerkle;

const PAGE_MODULES = new Map([[fileURLToPath(new URL('../src/unshield-events.js', import.meta.url)), unshieldEvents]]);

await require(path.join(ENGINE, 'utils/poseidon')).initPoseidonPromise;

/** An engine module (`merkletree/utxo-merkletree.js`, …) run through `rewrite`, as the build does. */
export function builtEngineModule(file, rewrite) {
  const filename = path.join(ENGINE, file);
  const engineRequire = createRequire(filename);
  const module = { exports: {} };
  const load = vm.compileFunction(rewrite(readFileSync(filename, 'utf8')), ['exports', 'require', 'module', '__filename', '__dirname'], {
    filename,
  });
  load(module.exports, (id) => PAGE_MODULES.get(id) ?? engineRequire(id), module, filename, path.dirname(filename));
  return module.exports;
}

export const { UTXOMerkletree } = builtEngineModule('merkletree/utxo-merkletree.js', throughUnshieldWatermark);
const { RailgunEngine } = require('@railgun-community/engine');

/**
 * A UTXO merkletree over `store` (a fresh memory one by default, as `memoryDatabase` makes), and an engine around it
 * with the engine's own commitment, nullifier and unshield listeners. `progress` collects the scan updates it emits.
 */
export async function engineHarness({ store = memoryDatabase() } = {}) {
  const { db, down } = store;
  const merkletree = await UTXOMerkletree.create(db, CHAIN, V2, async () => true);
  const progress = [];
  const engine = {
    db,
    getUTXOMerkletree: () => merkletree,
    invalidateTXOsCacheAllWallets() {},
    triggerDelayedTXIDMerkletreeSyncV2() {},
    emitUTXOMerkletreeScanUpdateEvent: (_txidVersion, _chain, value) => progress.push(value),
  };
  for (const listener of ['commitmentListener', 'nullifierListener', 'unshieldListener']) {
    engine[listener] = RailgunEngine.prototype[listener].bind(engine);
  }
  return { db, down, engine, merkletree, progress };
}

/** Every key and value in a memory store, for comparing two of them. */
export const contents = (down) => new Map([...down.store.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
