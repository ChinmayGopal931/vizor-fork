// Railgun's notes from Anon's archive (archive.js) rather than rail-squid: their commitments, from its chunks and tip,
// streamed chunk by chunk. Unshields and nullifiers come from rail-squid's whole lists. The archive keeps one event per
// nullifier, where Railgun keys them by tree and nullifier, and so drops the second when one nullifier is spent in two
// trees, which would count that note unspent; and an unshield missing from the store stops the txid sync at its
// transaction for good. The archive's commitments must run on from those stored, and are stored only as far as
// rail-squid's lists have shown it has come. On anything unexpected the quick sync goes on from rail-squid at the block
// after the archive's last good one; what the archive gave stays stored.
import { Merkletree } from '@railgun-community/engine';
import { TXIDVersion } from '@railgun-community/shared-models';
import { ArchiveUnavailable, archiveRange } from './archive.js';
import { commitmentBatches } from './archive-records.js';
import { formatNullifiers, formatUnshields, quickSyncProgress, squidLists, squidPages, storeEvents } from './quick-sync.js';

/** The archives the page reads, by network: only Ethereum's is kept up. */
export const ARCHIVES = { mainnet: { base: 'https://digest.anon.inc/v4/1', chainId: 1 } };

/**
 * About four days of blocks, the most the archive's tip has held: it holds what came after the newest sealed chunk, and
 * sealed chunks span 7,000 to 27,000 blocks. A sync that starts closer to the newest block than this has only the tip
 * to read, which rail-squid serves for a fraction of the bytes, so it never asks the archive.
 */
export const ARCHIVE_MIN_BLOCKS = 28_800;

/** Whether a sync from `block` is far enough behind `head` (the newest block number) to read the archive. */
export const farBehind = (block, head) => head - block > ARCHIVE_MIN_BLOCKS;

/**
 * Where the engine puts a note numbered `tree`:`index`: at its global tree position (tree × 65,536 + index), so one
 * numbered past a tree's last leaf goes into the next tree.
 */
const placement = (tree, index) => Merkletree.getTreeAndIndexFromGlobalPosition(Merkletree.getGlobalPosition(tree, index));

/**
 * The archive's commitment batches from `since` on, as `storeEvents` takes them (`{events, through}`, a chunk at a
 * time). Their notes must start at `next`, the tree and position the next leaf takes, and run on without a gap where
 * the engine places them: a batch starts where the last one ended, or at the start of the next tree, and its notes
 * follow its start within one tree. A batch the store ends inside goes on from it too: a cut-off write or a rail-squid
 * page can end a store partway through a batch, and the engine queues only the leaves it doesn't have. Rail-squid and
 * the archive both number the first leaf of mainnet's tree 1 as tree 0's leaf 65,536.
 */
export async function* archiveCommitments(reader, since, next, { time, chainId }) {
  let { tree, position } = next;
  for await (const chunk of archiveRange(reader, since, ['commitments'])) {
    const events = [];
    for (const batch of commitmentBatches(chunk.commitments, { since, time, chainId })) {
      const start = placement(batch.treeNumber, batch.startPosition);
      const end = start.index + batch.commitments.length;
      // The starting block's batches the store already has whole.
      if (start.tree < tree || (start.tree === tree && end <= position)) continue;
      const follows = start.tree === tree ? start.index <= position : start.tree === tree + 1 && start.index === 0;
      if (!follows) {
        throw new ArchiveUnavailable(`the archive's commitments skip from ${tree}:${position} to ${start.tree}:${start.index}`);
      }
      // The engine places each note by its own number.
      batch.commitments.forEach(({ utxoTree, utxoIndex }, i) => {
        const note = placement(utxoTree, utxoIndex);
        if (note.tree !== start.tree) {
          throw new ArchiveUnavailable(`the archive's batch at ${start.tree}:${start.index} runs past its tree`);
        }
        if (note.index !== start.index + i) {
          throw new ArchiveUnavailable(`the archive's batch at ${start.tree}:${start.index} numbers its notes apart from it`);
        }
      });
      events.push(batch);
      tree = start.tree;
      position = end;
    }
    yield { events, through: chunk.endBlock };
  }
}

/**
 * Has `engine`'s quick sync read the archive (`reader`, archive.js) before rail-squid (`queries`, squid.js). `time` is
 * how records are dated (`time(blockNumber, head)`), `head()` the chain's newest block (`{blockNumber, timestamp}`),
 * read once a sync, and `log` hears why the archive was left. While `useArchive()` says no (after the trees were
 * rebuilt, tree-recovery.js), syncs read rail-squid alone. `pages` are `squidPages`'s options, `writeRetryMs`
 * `storeEvents`'s.
 */
export function installArchiveSync(
  engine,
  { reader, queries, chainId, time, head, log = () => {}, useArchive = () => true, pages, writeRetryMs },
) {
  const own = engine.quickSyncEvents;
  engine.quickSyncEvents = async (txidVersion, chain, startingBlock) => {
    if (txidVersion !== TXIDVersion.V2_PoseidonMerkle) return own(txidVersion, chain, startingBlock);
    const newest = await head().catch(() => undefined);
    const report =
      newest === undefined
        ? undefined
        : (block) =>
            engine.emitUTXOMerkletreeScanUpdateEvent(txidVersion, chain, quickSyncProgress(startingBlock, newest.blockNumber, block));
    // Every list is stored through this block.
    let through = startingBlock - 1;
    if (newest !== undefined && farBehind(startingBlock, newest.blockNumber) && useArchive()) {
      try {
        const latest = await engine.getUTXOMerkletree(txidVersion, chain).getLatestTreeAndIndex();
        await storeEvents({
          engine,
          txidVersion,
          chain,
          unshields: squidPages(queries.unshields, formatUnshields, startingBlock, pages),
          nullifiers: squidPages(queries.nullifiers, formatNullifiers, startingBlock, pages),
          commitments: archiveCommitments(
            reader,
            startingBlock,
            { tree: latest.tree, position: latest.index + 1 },
            { time: (block) => time(block, newest), chainId },
          ),
          stored: (block) => {
            through = block;
          },
          progress: report,
          writeRetryMs,
        });
      } catch (error) {
        log(`the archive was left at block ${through}: ${error?.message ?? error}`);
      }
    }
    // Rail-squid's lists anew from there: one that failed beside the archive is never read on.
    return storeEvents({ engine, txidVersion, chain, ...squidLists(queries, through + 1, pages), progress: report, writeRetryMs });
  };
}
