// Railgun's transaction list from Anon's archive rather than rail-squid. The engine checks the archive's transactions
// as it does rail-squid's: each one's verification hash continues the chain, and each batch's root must be one the
// screening node validated. It also hashes each leaf from the archive's railgunTxid (`withHash`) rather than working
// that out, which was most of the list's Poseidon: a wrong railgunTxid changes the batch's root, which the node then
// refuses, and the records the sync gives railgunTxids are written only once it accepts one (txid-updates.js). Where
// the archive can't go on, the list goes on from rail-squid after the last transaction the archive gave.
import {
  ByteLength,
  ByteUtils,
  calculateRailgunTransactionVerificationHash,
  getGlobalTreePosition,
  getRailgunTxidLeafHash,
} from '@railgun-community/engine';
import { ENGINE_V2_START_BLOCK_NUMBERS_EVM } from '../node_modules/@railgun-community/engine/dist/utils/constants.js';
import { archiveRange } from './archive.js';
import { ARCHIVE_RAILGUN_TXID, beforeBlock, blockOf, sequenceOf, transaction } from './archive-records.js';
import { farBehind } from './archive-sync.js';

let v2StartBlock = 0;
// How long the newest block dates records past the block-time table.
const HEAD_MAX_AGE_MS = 10 * 60_000;
// How many times the engine may keep nothing of one archive batch before the list goes on from rail-squid: its root
// check fails with the connection, which may be back by the next sync.
export const ARCHIVE_TRIES = 3;

/**
 * The engine's `createRailgunTransactionWithHash(transaction)` (`own`), for the transactions the archive gave: their
 * leaf hashed from the archive's railgunTxid. The build (engine-hooks-plugin.mjs) has the engine's txid sync call it.
 * An unshield from before Railgun's V2 is worked out as before, since the sync stores it under its railgunTxid.
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
 * Has `engine`'s txid sync read the archive (`reader`) before rail-squid (the engine's own source), and set the
 * engine's txid batch (`setBatchSize`) to `batchSizes.archive` for a batch of the archive's and `batchSizes.squid` for
 * one of rail-squid's. `time` dates records (`time(blockNumber, head)`), `head()` is the chain's newest block, and
 * `log` hears why the archive was left. Without a `reader`, a list an archive sync left goes on from rail-squid.
 *
 * - The archive gives transactions by sequence, which must run on from the last one stored without a gap, each
 *   verification hash continuing the chain as the engine checks it; the engine reads on only after a full batch, so
 *   one the archive ends partway through is filled from rail-squid.
 * - The engine refuses a batch without saying so. Asked again from where it was asked last, having kept nothing of
 *   the archive's batch, this gives the batch again, `ARCHIVE_TRIES` times in all; asked from before, the engine having
 *   rolled back on a verification hash the archive's transactions broke, it leaves the archive at once.
 */
export function installArchiveTxids(
  engine,
  { reader, txidVersion, chain, batchSizes, setBatchSize, time, head = async () => undefined, log = () => {} },
) {
  const own = engine.quickSyncRailgunTransactionsV2;
  v2StartBlock = ENGINE_V2_START_BLOCK_NUMBERS_EVM[chain.id] ?? 0;
  const merkletree = () => engine.getTXIDMerkletree(txidVersion, chain);
  // Whether this page still reads the archive.
  let reading = reader !== undefined;
  // Where the archive walk stands: the cursor its next transaction follows, the last sequence given, the walk, and
  // what is left of its chunk.
  let walk;
  // The sequence the last batch with archive transactions followed, and how many times running the engine kept
  // nothing of it.
  let handed;
  let refused = 0;
  let newest;
  let newestAt = 0;

  const reset = () => {
    walk?.range.return?.();
    walk = undefined;
  };
  const leave = (why) => {
    log(`the archive's transactions were left: ${why}`);
    reset();
    reading = false;
  };
  const sequenceAfter = (cursor) => (cursor === undefined ? -1 : sequenceOf(cursor));

  /**
   * Up to `count` archive transactions after `cursor` (the stored transaction `kept`), and the error the walk stopped
   * on, if it did.
   */
  async function transactionsAfter(cursor, kept, count) {
    if (walk === undefined || walk.cursor !== cursor) {
      reset();
      const from = cursor === undefined ? 0 : blockOf(cursor);
      const range = archiveRange(reader, from, ['transactions']);
      walk = { cursor, last: sequenceAfter(cursor), verificationHash: kept?.verificationHash, range, left: [] };
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
        const next = walk.left[0];
        if (next.sequence > walk.last) {
          if (next.sequence !== walk.last + 1) throw new Error(`the archive's transaction ${next.sequence} follows ${walk.last}`);
          // Read before the walk moves on: a record that can't be read leaves it where it was.
          const read = transaction(next, (block) => time(block, newest));
          if (calculateRailgunTransactionVerificationHash(walk.verificationHash, read.nullifiers[0]) !== read.verificationHash) {
            throw new Error(`the archive's transaction ${next.sequence} breaks the verification hashes`);
          }
          out.push(read);
          walk.last = next.sequence;
          walk.verificationHash = read.verificationHash;
        }
        walk.left.shift();
      }
    } catch (error) {
      // What came before the break stands; the rest comes from rail-squid.
      reset();
      return { out, error };
    }
    walk.cursor = out.at(-1)?.graphID ?? cursor;
    return { out, error: undefined };
  }

  /** Rail-squid's transactions after `last` (the last one kept, `{graphID, blockNumber, verificationHash}`). */
  async function fromSquid(txChain, last) {
    setBatchSize(batchSizes.squid);
    if (last === undefined || sequenceOf(last.graphID) === undefined) return own(txChain, last?.graphID);
    // Rail-squid's ids within a block aren't the archive's: start at the block and skip through the last one kept.
    const listed = await own(txChain, beforeBlock(last.blockNumber));
    const at = listed.findIndex(({ verificationHash }) => verificationHash === last.verificationHash);
    if (at >= 0) return listed.slice(at + 1);
    // Rail-squid hasn't reached it yet, and the next sync asks again; or it lists another history from that block,
    // which the engine's verification chain refuses and rolls back.
    return listed.some(({ blockNumber }) => blockNumber > last.blockNumber) ? listed : [];
  }

  // What the engine kept of the archive's last batch, from where it asks now (`after`, a sequence).
  function judge(after) {
    if (handed === undefined) return;
    if (after < handed) {
      leave('the engine rolled back what the archive gave');
    } else if (after === handed) {
      refused += 1;
      if (refused >= ARCHIVE_TRIES) leave(`the engine kept nothing of an archive batch, ${refused} times`);
    } else {
      refused = 0;
    }
    handed = undefined;
  }

  engine.quickSyncRailgunTransactionsV2 = async (txChain, latestGraphID) => {
    // Rail-squid's own cursor: the archive's sequences can't follow it.
    if (latestGraphID !== undefined && sequenceOf(latestGraphID) === undefined) {
      setBatchSize(batchSizes.squid);
      return own(txChain, latestGraphID);
    }
    // The newest transaction stored, which the engine asks after.
    const kept = latestGraphID === undefined ? undefined : await merkletree().getLatestRailgunTransaction();
    if (reading) judge(sequenceAfter(latestGraphID));
    if (!reading) return fromSquid(txChain, kept);
    if (Date.now() - newestAt > HEAD_MAX_AGE_MS) {
      newest = await head().catch(() => newest);
      newestAt = Date.now();
    }
    // A list near the newest block reads rail-squid, as it would without the archive.
    if (latestGraphID !== undefined && !(newest !== undefined && farBehind(blockOf(latestGraphID), newest.blockNumber))) {
      reset();
      return fromSquid(txChain, kept);
    }
    const size = batchSizes.archive;
    const read = await transactionsAfter(latestGraphID, kept, size);
    if (read.error !== undefined) leave(read.error?.message ?? String(read.error));
    if (read.out.length > 0) handed = sequenceAfter(latestGraphID);
    if (read.out.length === size) {
      setBatchSize(batchSizes.archive);
      return read.out;
    }
    // The archive has nothing more: the rest comes from rail-squid, after the last transaction there is.
    reset();
    const more = await fromSquid(txChain, read.out.at(-1) ?? kept);
    return read.out.concat(more.slice(0, size - read.out.length));
  };
}
