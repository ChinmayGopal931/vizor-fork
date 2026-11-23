// The engine marks Railgun's transaction list as syncing while it clears or rewinds it, and leaves the mark for good
// when that step throws: every later txid sync then waits for a sync that never ends, and so does the rest of a sync
// (sync-finish.js), which every later refresh joins.

/**
 * `step()`, a change to the txid list (`merkletree`). A step that throws after the engine marked the list unmarks it;
 * one that threw because the list was already marked (a clear or a sync under way) leaves that mark to its owner.
 */
export async function changeTxidList(merkletree, step) {
  const marked = merkletree.isScanning === true;
  try {
    return await step();
  } catch (error) {
    if (!marked) merkletree.isScanning = false;
    throw error;
  }
}
