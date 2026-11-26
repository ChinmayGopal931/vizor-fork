// The notes trees can't get over a leaf stored wrong by themselves: the engine checks every tree's root at the end of
// each scan, and every scan after the leaf fails there while the store keeps it. The archive is a second source of
// leaves, on by default, so once the engine has refused one tree's root for a while the page rebuilds the trees from
// the start with the archive off.
//
// Two more failures outlast every scan the same way, with every root accepted, and count as a refused root does:
// - The trees short of the leaves Railgun's contract holds, once the engine's own read of the chain is done
//   (quick-sync.js). The engine starts each sync at the block of its newest stored leaf, which is its source's word: a
//   leaf dated past leaves the source left out has every later sync start after them.
// - A leaf the engine can't read as it decrypts (notes-decrypted.js), which stops a wallet's decryption there at
//   every scan.
import { changeTxidList } from './txid-list.js';

/** How long, and over how many refusals in a row, one tree's root must fail before the trees are rebuilt. */
export const REBUILD_AFTER_MS = 10 * 60_000;
export const REBUILD_AFTER_CHECKS = 3;
/** At most one rebuild this often, from when the last ended: a root that fails again so soon isn't the archive's. */
export const REBUILD_EVERY_MS = 24 * 60 * 60_000;
/** How long the archive stays off after a rebuild, or after it listed one of a wallet's sends wrong. */
export const ARCHIVE_OFF_MS = 7 * 24 * 60 * 60_000;

// The root the engine's end-of-scan check refused last, `{tree, root, index}`, until it is taken.
let refused;

/**
 * The engine's end-of-scan check refusing `tree`'s `root`, the tree's root after its leaf `index`, which the build has
 * it report (engine-hooks-plugin.mjs). Answers `error`, for the engine to throw.
 */
export function rootRefused(tree, root, error, index) {
  refused = { tree, root, index };
  return error;
}

/** How many blocks past a tree's newest leaf the RPC's newest block must be before its refusal of the tree counts. */
export const RPC_LAG_BLOCKS = 5;

/**
 * Whether the RPC that refused a tree's root may not have reached the tree's newest leaf yet: its newest block
 * (`head`) is not `RPC_LAG_BLOCKS` past the leaf's block (`leafBlock`). The contract records a tree's root in the block
 * of its newest leaf, and rail-squid's lists, which the trees come from, can be ahead of an RPC that lags: such a
 * refusal says nothing about the leaves, and counting it would have a lagging RPC rebuild the trees once a day. Unknown
 * blocks count the refusal, as before.
 */
export const rpcBehindLeaf = (leafBlock, head) =>
  Number.isSafeInteger(leafBlock) && Number.isSafeInteger(head) && head < leafBlock + RPC_LAG_BLOCKS;

/** The root the engine's end-of-scan check refused since this was last asked, if it did. */
export function takeRefusedRoot() {
  const taken = refused;
  refused = undefined;
  return taken;
}

// The tree a scan failed on with its roots accepted, in a way only trees built again get over, until it is taken.
let failedTree;

/**
 * A scan failing on `tree` so: a leaf of it the engine can't read, or the trees short of the contract's leaves with
 * `leaves` in it, which `broke` counts only while the tree stands still.
 */
export function treeFailed(tree, leaves) {
  failedTree = leaves === undefined ? { tree } : { tree, leaves };
}

/** The tree such a failure named since this was last asked, as `broke` takes a refused root's. */
export function takeFailedTree() {
  const taken = failedTree;
  failedTree = undefined;
  return taken;
}

/**
 * What the page does around each notes scan: `resume()` before it, `passed()` after one that completed, and
 * `broke(failed)` after one that broke off, `resume()` and `broke()` answering whether they rebuilt the trees.
 *
 * - Only a tree a scan failed on counts (`failed`): one whose root the engine's end-of-scan check refused
 *   (`takeRefusedRoot()`), or one short of the contract's leaves or holding a leaf the engine can't read
 *   (`takeFailedTree()`). A scan that broke otherwise, its lists failing or a write cut off, may have left a tree
 *   partway through an on-chain batch, at a root the contract never had.
 * - Refusals count for the tree, whatever its root: new notes move a tree's root on with the leaf stored wrong still
 *   under it. A root an RPC hasn't caught up to is refused for a moment, and the scan that completes after it starts
 *   the count again.
 * - A tree short of the contract's leaves counts while it stands still (`failed.leaves`, how many it has). Trees that
 *   only trail the chain, behind an RPC whose log reads lag its calls, take leaves between scans, and each start the
 *   count again: building them again would get them no further.
 * - `rebuild({started, cleared})` rebuilds every tree from the start (`rebuildTrees`), and answers false when it can't
 *   begin. The rebuild is kept unfinished from `started()` until it completes, so a page closed during it goes on with
 *   it when it reopens: a clearing cut off is done again (`resume()`, or the next refusal), and trees being built again
 *   go on building at the next scan, which ends the rebuild. The day between two rebuilds counts from when one ended.
 *
 * `store` keeps what was learned across page starts.
 */
export function treeRecovery({ rebuild, store, now = Date.now }) {
  const ended = () => store.write({ ...store.read(), rebuilding: undefined, failing: undefined, rebuiltAt: now() });

  async function rebuildNow() {
    const rebuilt = await rebuild({
      started: () =>
        store.write({
          ...store.read(),
          rebuilding: { since: now(), cleared: false },
          archiveOffUntil: now() + ARCHIVE_OFF_MS,
        }),
      cleared: () => store.write({ ...store.read(), rebuilding: { ...store.read().rebuilding, cleared: true } }),
    });
    if (rebuilt) ended();
    return rebuilt;
  }

  return {
    async resume() {
      const { rebuilding } = store.read();
      return rebuilding !== undefined && rebuilding.cleared !== true && rebuildNow();
    },
    passed() {
      const state = store.read();
      if (state.rebuilding?.cleared === true) ended();
      else if (state.failing !== undefined) store.write({ ...state, failing: undefined });
    },
    async broke(failed) {
      if (failed === undefined) return false;
      const state = store.read();
      // The trees built again are refused all the same: the rebuild has ended, and the count starts with this one.
      if (state.rebuilding?.cleared === true) {
        ended();
        store.write({ ...store.read(), failing: { ...failed, since: now(), checks: 1 } });
        return false;
      }
      const same = state.failing?.tree === failed.tree && state.failing.leaves === failed.leaves;
      const failing = same
        ? { ...state.failing, root: failed.root, checks: state.failing.checks + 1 }
        : { ...failed, since: now(), checks: 1 };
      store.write({ ...state, failing });
      const due =
        state.rebuilding !== undefined ||
        (failing.checks >= REBUILD_AFTER_CHECKS &&
          now() - failing.since >= REBUILD_AFTER_MS &&
          !(now() - (state.rebuiltAt ?? -Infinity) < REBUILD_EVERY_MS));
      return due && rebuildNow();
    },
  };
}

/**
 * Rebuilds `engine`'s notes trees on `chain` from the start, decrypting `walletIds`' notes, and answers whether it
 * began: not while the engine syncs the notes or Railgun's transaction list, which it won't clear meanwhile, nor while
 * `busy()`, the rest of a sync, which reads the balances a rebuild clears.
 * `started()` is called just before anything is cleared, and `cleared()` once all of it is, before the scan that builds
 * the trees again.
 *
 * These are the engine's full rescan's own steps (`fullRescanUTXOMerkletreesAndWallets`), run here so the clearing can
 * be marked done, and with the list cleared first rather than reset last. Its sync gave the notes their railgunTxids,
 * which a wallet proves its sends with and rebuilt notes lack, and it goes on only from where it stopped. The engine's
 * reset at the end of its rescan (which the build leaves out, engine-hooks-plugin.mjs) refuses to run before the page
 * has synced the list, which a page whose scans keep failing never has. The page syncs the list again after the next
 * scan that completes.
 */
export async function rebuildTrees(
  engine,
  { txidVersion, chain, walletIds, busy = () => false, started = () => {}, cleared = () => {} },
) {
  const utxo = engine.getUTXOMerkletree(txidVersion, chain);
  if (utxo.isScanning || engine.getTXIDMerkletree(txidVersion, chain).isScanning || busy()) return false;
  started();
  engine.emitUTXOMerkletreeScanUpdateEvent(txidVersion, chain, 0.01);
  const list = engine.getTXIDMerkletree(txidVersion, chain);
  await changeTxidList(list, () => engine.clearTXIDMerkletreeData(txidVersion, chain));
  // No scan while the leaves go, as in the engine's rescan.
  utxo.isScanning = true;
  try {
    await engine.clearUTXOMerkletreeAndLoadedWalletsAllTXIDVersions(chain);
    await engine.clearSyncedUnshieldEvents(txidVersion, chain);
  } finally {
    utxo.isScanning = false;
  }
  cleared();
  await engine.scanUTXOHistory(txidVersion, chain, walletIds);
  return true;
}

/** Whether `store` has the archive off now: after a rebuild, or after it listed one of a wallet's sends wrong. */
export const archiveOff = (store, now = Date.now) => (store.read().archiveOffUntil ?? -Infinity) > now();

/** A store under `key` in the page's local storage, and in memory where that can't be used. */
export function localStore(key) {
  let memory = {};
  return {
    read() {
      try {
        const kept = globalThis.localStorage?.getItem(key);
        return kept ? JSON.parse(kept) : memory;
      } catch {
        return memory;
      }
    },
    write(state) {
      memory = state;
      try {
        globalThis.localStorage?.setItem(key, JSON.stringify(state));
      } catch {
        // Kept in memory only.
      }
    },
  };
}
