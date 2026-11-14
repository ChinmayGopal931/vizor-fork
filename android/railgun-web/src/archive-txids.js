// Railgun's transaction list from Anon's archive rather than rail-squid. The engine checks the archive's transactions
// as it does rail-squid's: each one's verification hash continues the chain, and each batch's root must be one the
// screening node validated. It also hashes each leaf from the archive's railgunTxid (`withHash`) rather than working
// that out, which was most of the list's Poseidon; a wrong railgunTxid would change the batch's root, so the node's
// check vouches for every one. Where the archive can't go on, the list goes on from rail-squid after the last
// transaction the archive gave.
import { ByteLength, ByteUtils, getGlobalTreePosition, getRailgunTxidLeafHash } from '@railgun-community/engine';
import { ENGINE_V2_START_BLOCK_NUMBERS_EVM } from '../node_modules/@railgun-community/engine/dist/utils/constants.js';
import { ArchiveUnavailable, archiveRange } from './archive.js';
import { ARCHIVE_RAILGUN_TXID, beforeBlock, blockOf, sequenceOf, transaction } from './archive-records.js';
import { farBehind } from './archive-sync.js';
import { forgetPrebuiltTrees, usePrebuiltTrees } from './prebuilt-trees.js';

let v2StartBlock = 0;
// How long the newest block dates records past the block-time table.
const HEAD_MAX_AGE_MS = 10 * 60_000;

/**
 * The engine's `createRailgunTransactionWithHash(transaction)` (`own`), for the transactions the archive gave: their
 * leaf hashed from the archive's railgunTxid. The build (engine-hooks-plugin.mjs) has the engine's txid sync call it.
 * An unshield from before Railgun's V2 is worked out as before: the engine stores it under its railgunTxid before the
 * batch's root is checked.
 */
export function withHash(railgunTransaction, own) {
  const archived = railgunTransaction[ARCHIVE_RAILGUN_TXID];
  if (archived === undefined || (railgunTransaction.unshield && railgunTransaction.blockNumber < v2StartBlock)) {
    return own(railgunTransaction);
  }
  const railgunTxid = BigInt(`0x${archived}`);
  const { utxoTreeIn, utxoTreeOut, utxoBatchStartPositionOut } = railgunTransaction;
  return {
    ...railgunTransaction,
    railgunTxid: ByteUtils.nToHex(railgunTxid, ByteLength.UINT_256),
    hash: getRailgunTxidLeafHash(railgunTxid, BigInt(utxoTreeIn), getGlobalTreePosition(utxoTreeOut, utxoBatchStartPositionOut)),
  };
}

/**
 * Has `engine`'s txid sync read the archive (`reader`) before rail-squid (the engine's own source). `batchSize()` is
 * the engine's txid batch, `time` dates records (`time(blockNumber, head)`), `head()` is the chain's newest block, and
 * `log` hears why the archive was left.
 *
 * - The archive gives transactions by sequence, which must run on from the last one stored without a gap; the
 *   engine reads on only after a full batch, so one the archive ends partway through is filled from rail-squid.
 * - The engine refuses a batch it can't check without saying so: when it asks again from where it asked last, having
 *   kept nothing of the archive's batch, the list goes on from rail-squid after the last transaction it kept.
 * - The archive's prebuilt txid trees stand in for hashing once the screening node accepts their roots.
 */
export function installArchiveTxids(engine, { reader, txidVersion, chain, batchSize, time, head, log = () => {} }) {
  const own = engine.quickSyncRailgunTransactionsV2;
  v2StartBlock = ENGINE_V2_START_BLOCK_NUMBERS_EVM[chain.id] ?? 0;
  const merkletree = () => engine.getTXIDMerkletree(txidVersion, chain);
  // Where the archive walk stands: the cursor its next transaction follows, the walk, and what is left of its chunk.
  let walk;
  // The last batch handed over with archive transactions in it: the cursor it followed, and how many.
  let handed;
  // The prebuilt trees are in use until the archive has nothing more.
  let trees = false;
  let newest;
  let newestAt = 0;

  const reset = () => {
    walk?.range.return?.();
    walk = undefined;
  };
  const leave = () => {
    reset();
    trees = false;
    forgetPrebuiltTrees('TXID');
  };

  async function transactionsAfter(cursor, count) {
    const after = cursor === undefined ? -1 : sequenceOf(cursor);
    if (!trees) {
      trees = true;
      await usePrebuiltTrees({
        reader,
        manifest: await reader.manifest(),
        type: 'txid',
        merkletree: merkletree(),
        rootAccepted: (tree, index, root) => engine.validateRailgunTxidMerkleroot(txidVersion, chain, tree, index, root),
      });
    }
    if (walk === undefined || walk.cursor !== cursor) {
      reset();
      walk = { cursor, last: after, range: archiveRange(reader, cursor === undefined ? 0 : blockOf(cursor), ['transactions']), left: [] };
    }
    const out = [];
    try {
      while (out.length < count) {
        if (walk.left.length === 0) {
          const { value, done } = await walk.range.next();
          if (done) break;
          walk.left = [...value.transactions].sort((a, b) => a.blockNumber - b.blockNumber || a.sequence - b.sequence);
          continue;
        }
        const next = walk.left.shift();
        if (next.sequence <= walk.last) continue;
        if (next.sequence !== walk.last + 1) {
          throw new ArchiveUnavailable(`the archive's transaction ${next.sequence} follows ${walk.last}`);
        }
        walk.last = next.sequence;
        out.push(transaction(next, (block) => time(block, newest)));
      }
    } catch (error) {
      if (!(error instanceof ArchiveUnavailable)) throw error;
      // What came before the break stands; the rest comes from rail-squid.
      return { out, left: error };
    }
    walk.cursor = out.at(-1)?.graphID ?? cursor;
    return { out, left: undefined };
  }

  /** Rail-squid's transactions after `last` (the last one kept, `{graphID, blockNumber, verificationHash}`). */
  async function fromSquid(txChain, last) {
    if (last === undefined || sequenceOf(last.graphID) === undefined) return own(txChain, last?.graphID);
    // Rail-squid's ids within a block aren't the archive's: start at the block and skip through the last one kept.
    const listed = await own(txChain, beforeBlock(last.blockNumber));
    const at = listed.findIndex(({ verificationHash }) => verificationHash === last.verificationHash);
    if (at >= 0) return listed.slice(at + 1);
    // Rail-squid hasn't reached it yet, and the next sync asks again; or it lists another history from that block,
    // which the engine's verification chain refuses and rolls back.
    return listed.some(({ blockNumber }) => blockNumber > last.blockNumber) ? listed : [];
  }

  engine.quickSyncRailgunTransactionsV2 = async (txChain, latestGraphID) => {
    // A cursor rail-squid gave: the archive's sequences can't follow it.
    if (latestGraphID !== undefined && sequenceOf(latestGraphID) === undefined) return own(txChain, latestGraphID);
    const kept = async () => (latestGraphID === undefined ? undefined : merkletree().getLatestRailgunTransaction());
    if (handed !== undefined && handed.cursor === latestGraphID && handed.count > 0) {
      handed = undefined;
      leave();
      log('the engine kept nothing of an archive batch');
      return fromSquid(txChain, await kept());
    }
    if (Date.now() - newestAt > HEAD_MAX_AGE_MS) {
      newest = await head().catch(() => newest);
      newestAt = Date.now();
    }
    if (latestGraphID !== undefined && !farBehind(blockOf(latestGraphID), newest)) {
      if (walk !== undefined) leave();
      return fromSquid(txChain, await kept());
    }
    const size = batchSize();
    let batch = [];
    try {
      const read = await transactionsAfter(latestGraphID, size);
      batch = read.out;
      if (read.left !== undefined) {
        log(`the archive's transactions were left: ${read.left.message}`);
        leave();
      }
    } catch (error) {
      if (!(error instanceof ArchiveUnavailable)) throw error;
      log(`the archive's transactions were left: ${error.message}`);
      leave();
    }
    handed = { cursor: latestGraphID, count: batch.length };
    if (batch.length === size) return batch;
    // The archive has nothing more: the rest comes from rail-squid, after the last transaction there is.
    if (walk !== undefined) leave();
    const more = await fromSquid(txChain, batch.at(-1) ?? (await kept()));
    return batch.concat(more.slice(0, size - batch.length));
  };
}
