// The engine's V2 txid sync gives each transaction's commitments and unshield event their railgunTxid, then commits the
// transactions to the txid tree a group at a time, the screening node checking each group's root first. The engine
// writes each record as it goes, one IndexedDB transaction each, before that check: most of the sync's time on a first
// sync, and a railgunTxid the node then refuses stays on its record, where the wallet takes its own sends' from once.
// The build (engine-hooks-plugin.mjs) has the sync hold its updates here, and the txid tree hand over the transactions
// it is about to write, their root accepted: their records go into the store in one batch, just before them. So a
// transaction in the tree has its records updated, and nothing of a group the node refused is written.

// The updates held for each txid merkletree's sync.
const syncs = new WeakMap();

/**
 * The updates the engine's txid sync makes to `utxoMerkletree`, held by railgunTxid until `txidMerkletree` writes
 * their transactions. `unshieldsUpdated()` hears that unshield events were written.
 */
export function txidUpdates(utxoMerkletree, txidMerkletree, unshieldsUpdated = () => {}) {
  const held = new Map();
  const hold = (railgunTxid) => {
    let updates = held.get(railgunTxid);
    if (updates === undefined) {
      updates = { puts: [], added: [], unshields: false };
      held.set(railgunTxid, updates);
    }
    return updates;
  };
  const sync = {
    /** `updateData(tree, position, commitment)`, for the commitment the sync just read and gave its railgunTxid. */
    commitment(tree, position, commitment) {
      const key = utxoMerkletree.db.constructor.pathToKey(utxoMerkletree.getDataDBPath(tree, position));
      hold(commitment.railgunTxid).puts.push({ type: 'put', key, value: commitment });
    },
    /** `updateUnshieldEvent(event)`, keyed as `addUnshieldEvents` keys it. */
    unshield(event) {
      const key = utxoMerkletree.getUnshieldEventsDBPath(event.txid, event.eventLogIndex, event.railgunTxid).join(':');
      const updates = hold(event.railgunTxid);
      updates.puts.push({ type: 'put', key, value: event });
      updates.unshields = true;
    },
    /** `addUnshieldEvents([event])`, for an unshield from before Railgun's V2, which only its transaction lists. */
    added(event) {
      const updates = hold(event.railgunTxid);
      updates.added.push(event);
      updates.unshields = true;
    },
    /**
     * Writes the records of `transactions` (the leaves the txid tree is about to write, by position) in one batch,
     * behind the lock `updateData` takes.
     */
    async write(transactions) {
      const puts = [];
      const added = [];
      let unshields = false;
      transactions.forEach(({ railgunTxid }) => {
        const updates = held.get(railgunTxid);
        if (updates === undefined) return;
        held.delete(railgunTxid);
        puts.push(...updates.puts);
        added.push(...updates.added);
        unshields ||= updates.unshields;
      });
      if (puts.length > 0) {
        await utxoMerkletree.waitForUpdatesLock();
        utxoMerkletree.acquireUpdatesLock();
        try {
          await utxoMerkletree.db.batch(puts, 'json');
        } finally {
          utxoMerkletree.releaseUpdatesLock();
        }
      }
      if (added.length > 0) await utxoMerkletree.addUnshieldEvents(added);
      if (unshields) unshieldsUpdated();
    },
    /**
     * After a group was committed: what the tree refused is dropped, the records and the leaves still queued, so no
     * later write takes a leaf without its records. The sync reads them again from the tree's newest transaction.
     */
    settle() {
      held.clear();
      txidMerkletree.writeQueue = [];
    },
  };
  syncs.set(txidMerkletree, sync);
  return sync;
}

/** Called by `merkletree` with the leaves it is about to write, their root accepted: their held records go first. */
export async function leavesAccepted(merkletree, leaves) {
  await syncs.get(merkletree)?.write(leaves);
}
