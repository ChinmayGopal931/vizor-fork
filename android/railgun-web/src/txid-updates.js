// The engine's V2 txid sync gives each transaction's commitments and unshield event their railgunTxid one record at
// a time: a read, then a write behind the UTXO merkletree's lock that reads the record again. A first sync's records
// have none yet, so that is some 250,000 commitments and 90,000 unshield events in IndexedDB transactions of their own,
// most of the txid sync's time. The build (engine-hooks-plugin.mjs) has the sync hold them here; they go into the store
// in one batch before each group of transactions is committed to the txid tree, so a transaction there has its
// records updated, as before.

/** The updates the engine's txid sync makes to `merkletree` (the UTXO merkletree), held until `write()`. */
export function txidUpdates(merkletree) {
  let writes = [];
  return {
    /** `updateData(tree, position, commitment)`, for the commitment the sync just read and gave its railgunTxid. */
    commitment(tree, position, commitment) {
      const key = merkletree.db.constructor.pathToKey(merkletree.getDataDBPath(tree, position));
      writes.push({ type: 'put', key, value: commitment });
    },
    /** `updateUnshieldEvent(event)`, keyed as `addUnshieldEvents` keys it. */
    unshield(event) {
      const key = merkletree.getUnshieldEventsDBPath(event.txid, event.eventLogIndex, event.railgunTxid).join(':');
      writes.push({ type: 'put', key, value: event });
    },
    /** Writes what is held in one batch, behind the lock `updateData` takes, and answers how many records it wrote. */
    async write() {
      if (writes.length === 0) return 0;
      const batch = writes;
      writes = [];
      await merkletree.waitForUpdatesLock();
      merkletree.acquireUpdatesLock();
      try {
        await merkletree.db.batch(batch, 'json');
      } finally {
        merkletree.releaseUpdatesLock();
      }
      return batch.length;
    },
  };
}
