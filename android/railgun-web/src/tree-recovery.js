// The notes trees can't get over a leaf stored wrong by themselves: the engine checks every tree's root at the end of
// each scan, and every scan after the leaf fails there while the store keeps it. The archive is a second source of
// leaves, on by default, so once one tree's root has failed for a while the page rebuilds the trees from the start
// with the archive off.

/** How long, and over how many checks after broken scans, one tree's root must fail before the trees are rebuilt. */
export const REBUILD_AFTER_MS = 10 * 60_000;
export const REBUILD_AFTER_CHECKS = 3;
/** At most one rebuild this often: a root that fails again so soon after one isn't down to the archive. */
export const REBUILD_EVERY_MS = 24 * 60 * 60_000;
/** How long the archive stays off after a rebuild. */
export const ARCHIVE_OFF_MS = 7 * 24 * 60 * 60_000;

/**
 * What the page does after a notes scan broke off, answering whether it rebuilt the trees. `firstInvalidTree()`
 * answers the first tree whose root the contract has never had (`{tree, root}`), `null` when it has had every one, or
 * throws when that can't be told. A root an RPC hasn't caught up to fails for a moment, a wrong one for good.
 * `rebuild()` rebuilds every tree from the start. `store` keeps what was learned across page starts.
 */
export function treeRecovery({ firstInvalidTree, rebuild, store, now = Date.now }) {
  return async () => {
    let found;
    try {
      found = await firstInvalidTree();
    } catch {
      return false;
    }
    const state = store.read();
    if (found === null) {
      if (state.failing !== undefined) store.write({ ...state, failing: undefined });
      return false;
    }
    const same = state.failing?.tree === found.tree && state.failing?.root === found.root;
    const failing = same ? { ...state.failing, checks: state.failing.checks + 1 } : { ...found, since: now(), checks: 1 };
    const due =
      failing.checks >= REBUILD_AFTER_CHECKS &&
      now() - failing.since >= REBUILD_AFTER_MS &&
      !(now() - (state.rebuiltAt ?? -Infinity) < REBUILD_EVERY_MS);
    if (!due) {
      store.write({ ...state, failing });
      return false;
    }
    // Kept before the rebuild starts, so a page closed during it goes on without the archive.
    store.write({ rebuiltAt: now(), archiveOffUntil: now() + ARCHIVE_OFF_MS });
    await rebuild();
    return true;
  };
}

/** Whether the last rebuild `store` kept leaves the archive off now. */
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
