// The notes trees can't get over a leaf stored wrong by themselves: the engine checks every tree's root at the end of
// each scan, and every scan after the leaf fails there while the store keeps it. The archive is a second source of
// leaves, on by default, so once the engine has refused one tree's root for a while the page rebuilds the trees from
// the start with the archive off.

/** How long, and over how many refusals, one tree's root must fail before the trees are rebuilt. */
export const REBUILD_AFTER_MS = 10 * 60_000;
export const REBUILD_AFTER_CHECKS = 3;
/** At most one rebuild this often: a root that fails again so soon after one isn't down to the archive. */
export const REBUILD_EVERY_MS = 24 * 60 * 60_000;
/** How long the archive stays off after a rebuild, or after it listed one of a wallet's sends wrong. */
export const ARCHIVE_OFF_MS = 7 * 24 * 60 * 60_000;

// The root the engine's end-of-scan check refused last, `{tree, root}`, until it is taken.
let refused;

/**
 * The engine's end-of-scan check refusing `tree`'s `root`, which the build has it report (engine-hooks-plugin.mjs).
 * Answers `error`, for the engine to throw.
 */
export function rootRefused(tree, root, error) {
  refused = { tree, root };
  return error;
}

/** The root the engine's end-of-scan check refused since this was last asked, if it did. */
export function takeRefusedRoot() {
  const taken = refused;
  refused = undefined;
  return taken;
}

/**
 * What the page does after each notes scan: `passed()` after one that completed, and `broke(refusedRoot)` after one
 * that broke off, answering whether it rebuilt the trees. Only a root the engine's end-of-scan check refused counts
 * (`refusedRoot`, from `takeRefusedRoot()`): a scan that broke before that check, its lists failing or a write cut
 * off, may have left a tree partway through an on-chain batch, at a root the contract never had. A root an RPC
 * hasn't caught up to is refused for a moment, a wrong one for good. `rebuild(started)` rebuilds every tree from the
 * start, calling `started()` as it begins clearing them, and answers false when it can't begin. `store` keeps what
 * was learned across page starts.
 */
export function treeRecovery({ rebuild, store, now = Date.now }) {
  return {
    passed() {
      const state = store.read();
      if (state.failing !== undefined) store.write({ ...state, failing: undefined });
    },
    async broke(refusedRoot) {
      if (refusedRoot === undefined) return false;
      const state = store.read();
      const same = state.failing?.tree === refusedRoot.tree && state.failing?.root === refusedRoot.root;
      const failing = same ? { ...state.failing, checks: state.failing.checks + 1 } : { ...refusedRoot, since: now(), checks: 1 };
      store.write({ ...state, failing });
      const due =
        failing.checks >= REBUILD_AFTER_CHECKS &&
        now() - failing.since >= REBUILD_AFTER_MS &&
        !(now() - (state.rebuiltAt ?? -Infinity) < REBUILD_EVERY_MS);
      if (!due) return false;
      // Kept as the clearing begins, so a page closed during the rebuild goes on without the archive.
      return rebuild(() => store.write({ rebuiltAt: now(), archiveOffUntil: now() + ARCHIVE_OFF_MS }));
    },
  };
}

/**
 * Rebuilds `engine`'s notes trees on `chain` from the start, decrypting `walletIds`' notes, and answers whether it
 * began: not while the engine syncs the notes or Railgun's transaction list, which it won't clear meanwhile.
 * `started()` is called just before anything is cleared. The list goes first: its sync gave the notes their
 * railgunTxids, which a wallet proves its sends with and rebuilt notes lack, and it goes on only from where it stopped.
 * The engine's full rescan would reset it last (the build leaves that out, engine-hooks-plugin.mjs), which a page
 * closed during the rebuild never reaches, and refuses to before the page has synced the list, which a page whose scans
 * keep failing never has. The page syncs the list again after the next scan that completes.
 */
export async function rebuildTrees(engine, { txidVersion, chain, walletIds, started }) {
  if (engine.getUTXOMerkletree(txidVersion, chain).isScanning || engine.getTXIDMerkletree(txidVersion, chain).isScanning) {
    return false;
  }
  started();
  await engine.clearTXIDMerkletreeData(txidVersion, chain);
  await engine.fullRescanUTXOMerkletreesAndWallets(chain, walletIds);
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
