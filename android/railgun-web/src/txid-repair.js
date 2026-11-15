// Railgun's transaction list can stop for good at a transaction it can't take: every later sync asks rail-squid from
// the same place and stops there again, and a send's change, which screening holds until the list has the send, stays
// in Processing. The engine says why the list stopped (the build has it report, engine-hooks-plugin.mjs). Once the
// list has stopped short of the screening nodes' validated index at the same transaction, for the same reason, three
// times over ten minutes, the page repairs what that reason allows. A repair asks only what any wallet that far behind
// asks: its boundaries are fixed, never taken from the wallet's own transactions.
//
// - The screening node refused a root: the list is rewound to the boundary below the stop and synced again from
//   rail-squid, the archive off. One that stops there again is cleared and synced from the start, at most once a day.
// - An unshield the notes trees lack: rail-squid's unshields are read again from the block boundary below it, once.
// - A transaction that breaks the verification hashes: the archive goes off, so the list comes from rail-squid. One
//   rail-squid breaks too is left as it is, since clearing it would not mend it.
// - A commitment not stored yet: the notes are behind, which the next notes scan mends.
import { ARCHIVE_OFF_MS, archiveOff } from './tree-recovery.js';

/** How many stops in a row at one transaction, for one reason, and over how long, before the list is repaired. */
export const REPAIR_AFTER_CHECKS = 3;
export const REPAIR_AFTER_MS = 10 * 60_000;
/** At most one clear this often, counted from when the list it cleared caught up again. */
export const CLEAR_EVERY_MS = 24 * 60 * 60_000;
/** A rewind keeps the list through a multiple of this many transactions, less one. */
export const REWIND_STEP = 10_000;
/** Unshields are read again from a multiple of this many blocks. */
export const REREAD_STEP = 100_000;

// Why the list stopped last, `{reason, block}`, until it is taken.
let stop;

/** The engine's txid sync stopping, for `reason`, at a transaction in `block`, which the build has it report. */
export function listStopped(reason, block) {
  stop = { reason, block };
}

/** Why the list stopped since this was last asked, if it did. */
export function takeListStop() {
  const taken = stop;
  stop = undefined;
  return taken;
}

/** `sync`, each call forgetting why an earlier one stopped: why the list stopped is its last sync's to say. */
export const forgettingStops =
  (sync) =>
  (...args) => {
    takeListStop();
    return sync(...args);
  };

/**
 * `step()`, a change to the txid list (`merkletree`). The engine marks the list as syncing while it rewinds or clears
 * it and leaves it marked for good when the step throws, which would hold up every later sync: a throw unmarks it.
 */
export async function changeTxidList(merkletree, step) {
  try {
    return await step();
  } catch (error) {
    merkletree.isScanning = false;
    throw error;
  }
}

/** The index of the last transaction a rewind of a list stopped after `index` keeps: -1 for none. */
export const rewindPoint = (index) => Math.max(-1, Math.floor(index / REWIND_STEP) * REWIND_STEP - 1);

/** The block unshields are read again from for a stop at a transaction in `block`. */
export const rereadFrom = (block) => Math.floor(block / REREAD_STEP) * REREAD_STEP;

/**
 * What the page does around each catch-up of the list: `resume()` before it, `passed()` after one that reached the
 * validated index, and `stopped(index, stop)` after one that stopped at `index` short of it, `stop` being why
 * (`takeListStop()`), which answers what was done: `counted`, `busy` (a scan runs, so nothing was), `rewound`,
 * `cleared`, `reread`, `archive off` or `left` (nothing more to do). Only while `idle()`, with the notes and the list
 * not syncing, does a repair run:
 *
 * - `rewind(point)` drops every transaction after `point` and syncs the list again;
 * - `clear()` drops the whole list, which the next catch-up syncs again; one a closed page left unfinished is done
 *   again at `resume()`;
 * - `reread(from, through)` stores rail-squid's unshields again from block `from` through `through`.
 *
 * `store` (tree-recovery.js's) keeps the count across page starts, and turns the archive off.
 */
export function txidRepair({ store, now = Date.now, idle = () => true, rewind, clear, reread }) {
  const write = (changes) => store.write({ ...store.read(), ...changes });
  const archiveOffNow = () => write({ archiveOffUntil: now() + ARCHIVE_OFF_MS });

  async function clearNow() {
    archiveOffNow();
    write({ txidStall: undefined, txidClear: { since: now(), cleared: false } });
    await clear();
    write({ txidClear: { ...store.read().txidClear, cleared: true } });
  }

  async function repair({ index, reason, block }) {
    const state = store.read();
    if (reason === 'root') {
      if (state.txidRewound !== index && rewindPoint(index) >= 0) {
        archiveOffNow();
        write({ txidStall: undefined, txidRewound: index });
        await rewind(rewindPoint(index));
        return 'rewound';
      }
      if (state.txidClear !== undefined || now() - (state.txidClearedAt ?? -Infinity) < CLEAR_EVERY_MS) return 'left';
      await clearNow();
      return 'cleared';
    }
    if (reason === 'unshield' && state.txidReread !== index) {
      write({ txidStall: undefined, txidReread: index });
      await reread(rereadFrom(block), block);
      return 'reread';
    }
    if (reason === 'verification' && !archiveOff(store, now)) {
      archiveOffNow();
      write({ txidStall: undefined });
      return 'archive off';
    }
    return 'left';
  }

  return {
    async resume() {
      if (store.read().txidClear?.cleared === false && idle()) await clearNow();
    },
    passed() {
      const { txidClear, txidStall, txidRewound } = store.read();
      if (txidClear?.cleared === true) write({ txidClear: undefined, txidClearedAt: now() });
      if (txidStall !== undefined || txidRewound !== undefined) write({ txidStall: undefined, txidRewound: undefined });
    },
    async stopped(index, listStop) {
      if (listStop === undefined || listStop.reason === 'commitment') return 'left';
      const { txidStall } = store.read();
      const stall =
        txidStall?.index === index && txidStall.reason === listStop.reason
          ? { ...txidStall, checks: txidStall.checks + 1 }
          : { index, reason: listStop.reason, block: listStop.block, since: now(), checks: 1 };
      write({ txidStall: stall });
      if (stall.checks < REPAIR_AFTER_CHECKS || now() - stall.since < REPAIR_AFTER_MS) return 'counted';
      if (!idle()) return 'busy';
      return repair(stall);
    },
  };
}
