// Railgun's history from Anon's archive (archive.js) rather than rail-squid: commitments and unshields from its chunks
// and tip, and its prebuilt notes trees, streamed chunk by chunk. Nullifiers always come from rail-squid's whole list:
// the archive keeps one event per nullifier, where Railgun keys them by tree and nullifier, and so drops the second
// when one nullifier is spent in two trees, which would count that note unspent. On anything unexpected the quick
// sync goes on from rail-squid at the block after the archive's last good one; what the archive gave stays stored.
import { RailgunEngine } from '@railgun-community/engine';
import { TXIDVersion } from '@railgun-community/shared-models';
import { ArchiveUnavailable, archiveRange } from './archive.js';
import { commitmentBatches, unshieldEvents } from './archive-records.js';
import { forgetPrebuiltTrees, usePrebuiltTrees } from './prebuilt-trees.js';
import {
  formatCommitments,
  formatNullifiers,
  formatUnshields,
  quickSyncProgress,
  squidPages,
  storeEvents,
} from './quick-sync.js';

/** The archives the page reads, by network: only Ethereum's is kept up. */
export const ARCHIVES = { mainnet: { base: 'https://digest.anon.inc/v4/1', chainId: 1 } };

/**
 * About a day of blocks, which the archive's tip holds. A sync that starts closer to the newest block than this has only
 * the tip to read, which rail-squid serves for a fraction of the bytes, so it never asks the archive.
 */
export const ARCHIVE_MIN_BLOCKS = 7_200;

/** Whether a sync from `block` is far enough behind `head` (the newest block, if known) to read the archive. */
export const farBehind = (block, head) => head === undefined || head.blockNumber - block > ARCHIVE_MIN_BLOCKS;

/**
 * Two page lists over one walk of the archive, which downloads each chunk once: `unshields` and `commitments`, each
 * `{events, through}` as `storeEvents` takes them. A chunk is let go once both have given it.
 */
export function archiveLists(range, { since, time, chainId }) {
  const held = [];
  let first = 0;
  const given = [0, 0];
  async function chunkAt(position) {
    while (first + held.length <= position) {
      const { value, done } = await range.next();
      if (done) return undefined;
      held.push(value);
    }
    return held[position - first];
  }
  async function* list(which, events) {
    for (;;) {
      const chunk = await chunkAt(given[which]);
      if (chunk === undefined) return;
      given[which] += 1;
      while (first < Math.min(...given)) {
        held.shift();
        first += 1;
      }
      yield { events: events(chunk), through: chunk.endBlock };
    }
  }
  return {
    unshields: list(0, (chunk) => unshieldEvents(chunk.unshields, { since, time })),
    commitments: list(1, (chunk) => commitmentBatches(chunk.commitments, { since, time, chainId })),
  };
}

/**
 * Has `engine`'s quick sync read the archive (`reader`, archive.js) before rail-squid (`queries`, squid.js). `time` is
 * how records are dated (`time(blockNumber, head)`), `head()` the chain's newest block (`{blockNumber, timestamp}`),
 * read once a sync, and `log` hears why the archive was left. `pages` are `squidPages`'s options.
 */
export function installArchiveSync(engine, { reader, queries, chainId, time, head, log = () => {}, pages }) {
  const own = engine.quickSyncEvents;
  engine.quickSyncEvents = async (txidVersion, chain, startingBlock) => {
    if (txidVersion !== TXIDVersion.V2_PoseidonMerkle) return own(txidVersion, chain, startingBlock);
    const newest = await head().catch(() => undefined);
    const report = (block) =>
      newest !== undefined &&
      engine.emitUTXOMerkletreeScanUpdateEvent(txidVersion, chain, quickSyncProgress(startingBlock, newest.blockNumber, block));
    // Rail-squid's whole list, read alongside the archive, and on past it.
    const nullifiers = squidPages(queries.nullifiers, formatNullifiers, startingBlock, pages);
    // Every list is stored through this block.
    let through = startingBlock - 1;
    if (farBehind(startingBlock, newest)) {
      try {
        await usePrebuiltTrees({
          reader,
          manifest: await reader.manifest(),
          type: 'utxo',
          merkletree: engine.getUTXOMerkletree(txidVersion, chain),
          rootAccepted: (tree, index, root) => RailgunEngine.validateMerkleroot(txidVersion, chain, tree, index, root),
        });
        const lists = archiveLists(archiveRange(reader, startingBlock, ['commitments', 'unshields']), {
          since: startingBlock,
          time: (block) => time(block, newest),
          chainId,
        });
        await storeEvents({
          engine,
          txidVersion,
          chain,
          unshields: lists.unshields,
          nullifiers,
          commitments: lists.commitments,
          stored: (block) => {
            through = block;
          },
          progress: report,
        });
      } catch (error) {
        if (!(error instanceof ArchiveUnavailable)) throw error;
        log(`the archive was left at block ${through}: ${error.message}`);
      } finally {
        forgetPrebuiltTrees('UTXO');
      }
    }
    return storeEvents({
      engine,
      txidVersion,
      chain,
      unshields: squidPages(queries.unshields, formatUnshields, through + 1, pages),
      nullifiers,
      commitments: squidPages(queries.commitments, formatCommitments, through + 1, pages),
      progress: report,
    });
  };
}
