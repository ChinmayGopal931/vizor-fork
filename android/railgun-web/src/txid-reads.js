// The engine's V2 txid sync reads, for each transaction, the commitments it made and the unshield events it emitted,
// one IndexedDB transaction per read: about 250,000 commitments and 100,000 unshield transactions on a mainnet first
// sync, minutes on a phone. The build (engine-hooks-plugin.mjs) has it read them here instead: commitments a window at a
// time in one range read, and the unshield events of a whole batch of transactions in one IndexedDB transaction. Each
// read answers what the engine's own would, a record of its own, and a record served once is read again from the store.
import { ByteLength, ByteUtils, Database } from '@railgun-community/engine';

/** How many commitments one range read takes. */
export const COMMITMENT_WINDOW = 2_000;
/** How many transactions' unshield events one IndexedDB transaction reads. */
export const UNSHIELD_BATCH = 2_000;

// What the page's txid syncs read, for dev/check.mjs.
const counted = { windows: 0, unshieldTransactions: 0, unshieldBatches: 0 };

/** How many commitment windows, and how many transactions' unshield events in how many batches, the syncs read. */
export const txidReadsCounts = () => ({ ...counted });

/**
 * The reads of a txid sync of `transactions` (the engine's raw ones) over `utxoMerkletree`: `commitment(tree, position)`,
 * as `getCommitmentSafe`, and `unshieldEvents(txid)`, as `getAllUnshieldEventsForTxid`.
 */
export function txidReads(utxoMerkletree, transactions, { window = COMMITMENT_WINDOW, batch = UNSHIELD_BATCH } = {}) {
  let commitments;
  let unshields;

  async function readWindow(tree, position) {
    const length = await utxoMerkletree.getTreeLength(tree);
    if (position >= length) return undefined;
    const end = Math.min(position + window, length) - 1;
    const values = await utxoMerkletree.getCommitmentRange(tree, position, end);
    counted.windows += 1;
    // A tree holds every leaf below its length; a range that misses one is read a leaf at a time.
    return values.length === end - position + 1 ? { tree, start: position, values } : undefined;
  }

  return {
    async commitment(tree, position) {
      let at = commitments?.tree === tree ? position - commitments.start : -1;
      if (!(at >= 0 && at < commitments.values.length)) {
        commitments = await readWindow(tree, position);
        if (commitments === undefined) return utxoMerkletree.getCommitmentSafe(tree, position);
        at = 0;
      }
      const value = commitments.values[at];
      commitments.values[at] = undefined;
      return value ?? utxoMerkletree.getCommitmentSafe(tree, position);
    },

    async unshieldEvents(txid) {
      unshields ??= await readUnshields(utxoMerkletree, transactions, batch);
      const prefix = eventsPrefix(utxoMerkletree, txid);
      const events = unshields?.get(prefix);
      if (events === undefined) return utxoMerkletree.getAllUnshieldEventsForTxid(txid);
      unshields.delete(prefix);
      return events;
    },
  };
}

/** The key under which `txid`'s unshield events are stored, as `getAllUnshieldEventsForTxid` finds them. */
function eventsPrefix(utxoMerkletree, txid) {
  const stripped = ByteUtils.formatToByteLength(txid, ByteLength.UINT_256, false);
  return Database.pathToKey(utxoMerkletree.getUnshieldEventsDBPath(stripped, undefined, undefined));
}

/**
 * The unshield events of every unshielding transaction among `transactions`, by their prefix, read `batch` transactions
 * to one IndexedDB transaction; undefined where the store isn't IndexedDB, which reads them one at a time.
 */
async function readUnshields(utxoMerkletree, transactions, batch) {
  const { db } = utxoMerkletree;
  if (!db.usesIndexedDB()) return undefined;
  const prefixes = [
    ...new Set(transactions.flatMap(({ unshield, txid }) => (unshield ? [eventsPrefix(utxoMerkletree, txid)] : []))),
  ];
  const read = new Map();
  for (let at = 0; at < prefixes.length; at += batch) {
    const store = db.getIndexedDBStore();
    counted.unshieldBatches += 1;
    counted.unshieldTransactions += Math.min(batch, prefixes.length - at);
    await Promise.all(
      prefixes.slice(at, at + batch).map(async (prefix) => {
        const range = IDBKeyRange.bound(new TextEncoder().encode(prefix), new TextEncoder().encode(`${prefix}~`));
        const [keys, values] = await Promise.all([request(store.getAllKeys(range)), request(store.getAll(range))]);
        // As the engine reads them: the keys of events, a txid and an event index (or railgunTxid) deep.
        const events = values.flatMap((value, i) =>
          new TextDecoder().decode(keys[i]).split(':').length === 6 ? [db.decode(value, 'json')] : [],
        );
        events.forEach((event) => {
          event.timestamp = event.timestamp ?? undefined;
        });
        read.set(prefix, events);
      }),
    );
  }
  return read;
}

const request = (idbRequest) =>
  new Promise((resolve, reject) => {
    idbRequest.onsuccess = () => resolve(idbRequest.result);
    idbRequest.onerror = () => reject(idbRequest.error);
  });
