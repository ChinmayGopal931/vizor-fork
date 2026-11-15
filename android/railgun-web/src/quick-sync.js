// The engine's quick sync reads Railgun's whole history before storing any of it: the SDK holds every page of every
// list in memory, joining each page onto the ones before (over a gigabyte of heap on a mainnet first sync), and
// hands the engine one array of each. Here the engine's `quickSyncEvents` stores each page as it comes and hands the
// engine nothing more to store.
import { TXIDVersion } from '@railgun-community/shared-models';
// The SDK's package exports none of its quick-sync modules.
import {
  formatGraphCommitmentEventsV2,
  formatGraphNullifierEventsV2,
  formatGraphUnshieldEventsV2,
} from '../node_modules/@railgun-community/wallet/dist/services/railgun/quick-sync/V2/graph-type-formatters-v2.js';
import {
  createGraphCommitmentBatches,
  sortByTreeNumberAndStartPosition,
} from '../node_modules/@railgun-community/wallet/dist/services/railgun/quick-sync/V2/quick-sync-events-graph-v2.js';
import { pauseMark, pausedSince } from './page-clock.js';

/** The most events the indexer answers at once. */
export const SQUID_PAGE_SIZE = 10_000;
/** As the SDK waits on each page, and between two of one list. */
export const PAGE_TIMEOUT_MS = 20_000;
const PAGE_GAP_MS = 250;
// A page the indexer didn't answer is asked again after 1, 2, 4 and 8 s: a phone's DNS can fail every lookup for
// seconds at a time. A try a pause of the page cut through is asked again at once, uncounted (page-clock.js).
const PAGE_ATTEMPTS = 5;
const PAGE_RETRY_MS = 1_000;
// How many leaves wait in the engine's write queue before they go into the trees. The engine asks Railgun's contract
// about the root of every insert, one call at a time, so a write per page or archive chunk cost a round trip each,
// hundreds on a mainnet first sync. This keeps them to a handful, and the queue small. A quick sync writes whatever
// the contract answers, since a write can end inside an on-chain batch, at a root the contract never recorded; the
// engine checks every tree's root at the end of the scan.
export const TREE_WRITE_LEAVES = 20_000;
// A write that leaves leaves in the queue is tried once more after this: the root check can fail with the connection.
const WRITE_RETRY_MS = 2_000;
// Where the engine's notes scan puts its quick sync: from a fifth to four fifths of its first half.
const PROGRESS_FROM = 0.1;
const PROGRESS_TO = 0.4;

export const NO_EVENTS = Object.freeze({ commitmentEvents: [], unshieldEvents: [], nullifierEvents: [] });

export const formatNullifiers = formatGraphNullifierEventsV2;
export const formatUnshields = formatGraphUnshieldEventsV2;
/** A page's commitments as the SDK's quick sync batches them: by tree and batch start, in tree order. */
export const formatCommitments = (commitments) =>
  formatGraphCommitmentEventsV2(createGraphCommitmentBatches(commitments).sort(sortByTreeNumberAndStartPosition));

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('the indexer did not answer in time')), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

// Every query sent to the indexer, counted across lists: which of two pages was asked for first.
let asks = 0;

/**
 * One of the indexer's event lists from `startingBlock` on, a page at a time: `{events, through, asked, newest}`, the
 * page's events as `format` makes them, the block through which the list has now given every event (Infinity once a
 * page reaches the indexer's newest block, the list's last), when the page was asked for (`asked`, counted across
 * lists), and the newest block the indexer has shown it has (`newest`). The next page is asked for while this one is
 * stored. The indexer pages by block, starting each page at the block the last one ended on, so a page's events that
 * the last page gave are left out. The last page's `again()` reads the list on from there, asked anew. `retryMs`
 * spaces the tries at a page.
 */
export function squidPages(
  query,
  format,
  startingBlock,
  { pageSize = SQUID_PAGE_SIZE, gapMs = PAGE_GAP_MS, retryMs = PAGE_RETRY_MS } = {},
) {
  return pagesFrom(
    query,
    format,
    { from: startingBlock, given: new Set(), newest: startingBlock - 1 },
    { pageSize, gapMs, retryMs },
  );
}

async function* pagesFrom(query, format, at, options) {
  const { pageSize, gapMs, retryMs } = options;
  const ask = (block, wait) => {
    const answer = (wait ? delay(wait) : Promise.resolve()).then(async () => {
      let pardoned = 0;
      for (let attempt = 1; ; attempt += 1) {
        // Counted at each try: a page answers as of the try it came from.
        const asked = ++asks;
        const mark = pauseMark();
        try {
          return { page: await withTimeout(query(block), PAGE_TIMEOUT_MS), asked };
        } catch (error) {
          if (pausedSince(mark) && pardoned < PAGE_ATTEMPTS) {
            pardoned += 1;
            attempt -= 1;
            continue;
          }
          if (attempt >= PAGE_ATTEMPTS) throw error;
          await delay(retryMs * 2 ** (attempt - 1));
        }
      }
    });
    answer.catch(() => {});
    return answer;
  };
  let { from, given, newest } = at;
  let next = ask(from, 0);
  for (;;) {
    const { page, asked } = await next;
    const full = page.length >= pageSize;
    const last = page.length === 0 ? from : Number(page[page.length - 1].blockNumber);
    const events = page.filter(({ id }) => !given.has(id));
    if (full && last === from && events.length === 0) {
      throw new Error(`the indexer has more than a page of events in block ${from}`);
    }
    if (page.length > 0) newest = Math.max(newest, last);
    if (!full) {
      // Read on from the same block, with what this page gave left out.
      const read = { from, given: new Set([...given, ...page.map(({ id }) => id)]), newest };
      yield {
        events: format(events),
        through: Infinity,
        asked,
        newest,
        again: () => pagesFrom(query, format, read, options),
      };
      return;
    }
    given = new Set(page.filter(({ blockNumber }) => Number(blockNumber) === last).map(({ id }) => id));
    from = last;
    next = ask(from, gapMs);
    yield { events: format(events), through: last - 1, asked, newest };
  }
}

/** Whether `merkletree`'s write queue holds leaves its trees didn't take. */
const leavesLeft = (merkletree) => merkletree.writeQueue.some((queue) => queue?.some((group) => group !== undefined));

/**
 * Stores a quick sync's events as they come and returns nothing more for the engine to store. `unshields`,
 * `nullifiers` and `commitments` are page lists as `squidPages` gives them; `commitments` can come from elsewhere, as
 * `{events, through}` pages. The engine resumes a quick sync from its newest stored commitment's block, so the
 * unshields and nullifiers of a page's blocks are stored before its commitments, which go into the trees `writeLeaves`
 * at a time, and at the end.
 *
 * The indexer's lists are whole up to its newest block when they were asked, and a later answer can reach further: a
 * list that ended before a page of the indexer's commitments was asked for is read on first. Commitments from
 * elsewhere are stored only as far as the lists show the indexer has come, where the quick sync ends.
 *
 * `progress(through)` hears, after each page of commitments, the block through which all three lists have come;
 * `stored(through)`, the block through which they are stored, once the trees have taken every leaf (or it throws).
 * A list that fails stores what the pages before it gave first.
 */
export async function storeEvents({
  engine,
  txidVersion,
  chain,
  unshields,
  nullifiers,
  commitments,
  stored,
  progress,
  writeLeaves = TREE_WRITE_LEAVES,
  writeRetryMs = WRITE_RETRY_MS,
}) {
  const merkletree = engine.getUTXOMerkletree(txidVersion, chain);
  const before = [
    { pages: unshields, store: (events) => engine.unshieldListener(txidVersion, chain, events) },
    { pages: nullifiers, store: (events) => engine.nullifierListener(txidVersion, chain, events) },
  ].map((list) => ({ ...list, through: -Infinity, newest: -Infinity, asked: 0, again: undefined }));
  const pull = async (list) => {
    const { value, done } = await list.pages.next();
    if (done) throw new Error('an event list ended before its last page');
    if (value.events.length > 0) await list.store(value.events);
    Object.assign(list, { through: value.through, newest: value.newest, asked: value.asked, again: value.again });
  };
  // Stores both lists through `block`, and read on for a page of the indexer's commitments asked for after a list
  // ended (`asked`). Answers the block through which the lists have shown every event.
  const storeThrough = async (block, asked) => {
    for (const list of before) {
      for (;;) {
        if (list.through < block) {
          await pull(list);
        } else if (asked !== undefined && list.through === Infinity && list.asked < asked) {
          list.pages = list.again();
          await pull(list);
        } else {
          break;
        }
      }
    }
    return Math.min(...before.map((list) => (list.through === Infinity ? list.newest : list.through)));
  };
  // The leaves waiting in the write queue, and the block through which the pages that gave them are whole.
  let queued = 0;
  let queuedThrough;
  const write = async () => {
    if (queued > 0) {
      await merkletree.updateTreesFromWriteQueue(true);
      // A missing leaf, or a root check that failed, stops the trees short and leaves the rest queued, which a store
      // that says how far it came can't have.
      if (stored !== undefined && leavesLeft(merkletree)) {
        await delay(writeRetryMs);
        await merkletree.updateTreesFromWriteQueue(true);
        if (leavesLeft(merkletree)) throw new Error('the trees stopped short of the leaves they were given');
      }
    }
    queued = 0;
    if (queuedThrough !== undefined) stored?.(queuedThrough);
    queuedThrough = undefined;
  };
  let ended = false;
  try {
    for await (const { events, through, asked } of commitments) {
      // A page's last block can go on in the next page, so its events reach past what it gives whole.
      const reached = events.reduce((highest, batch) => Math.max(highest, batch.blockNumber), through);
      const shown = await storeThrough(reached, asked);
      // The indexer's own commitments come no further than its lists; another source's can.
      const whole = asked === undefined ? Math.min(shown, reached) : reached;
      const kept = whole < reached ? events.filter(({ blockNumber }) => blockNumber <= whole) : events;
      if (kept.length > 0) {
        await engine.commitmentListener(txidVersion, chain, kept, false, false);
        queued += kept.reduce((leaves, batch) => leaves + batch.commitments.length, 0);
      }
      queuedThrough = Math.min(through, whole);
      progress?.(queuedThrough);
      if (whole < reached) {
        ended = true;
        break;
      }
      if (queued === 0 || queued >= writeLeaves) await write();
    }
  } catch (error) {
    // The pages before the one that failed came whole: their leaves go in, and a sync goes on after them.
    await write().catch(() => {});
    throw error;
  }
  await write();
  if (!ended) await storeThrough(Infinity);
  return NO_EVENTS;
}

/** The engine's notes-scan progress for a quick sync from `startingBlock` that has reached `block` of `head`. */
export function quickSyncProgress(startingBlock, head, block) {
  if (!(head > startingBlock)) return PROGRESS_FROM;
  const share = Math.min(1, Math.max(0, (block - startingBlock) / (head - startingBlock)));
  return PROGRESS_FROM + (PROGRESS_TO - PROGRESS_FROM) * share;
}

/**
 * Has `engine` quick sync from the indexer (`queries`, `squidQueries`), a page at a time. `head()` is the chain's
 * newest block number, for the progress it reports; without it the quick sync reports none of its own. `pages` are
 * `squidPages`'s options.
 */
export function installQuickSync(engine, { queries, head, pages }) {
  const own = engine.quickSyncEvents;
  engine.quickSyncEvents = async (txidVersion, chain, startingBlock) => {
    if (txidVersion !== TXIDVersion.V2_PoseidonMerkle) return own(txidVersion, chain, startingBlock);
    const newest = await head().catch(() => undefined);
    return storeEvents({
      engine,
      txidVersion,
      chain,
      ...squidLists(queries, startingBlock, pages),
      progress: progressReporter(engine, txidVersion, chain, startingBlock, newest),
    });
  };
}

/** The indexer's three lists from `startingBlock` on. */
export const squidLists = (queries, startingBlock, options) => ({
  unshields: squidPages(queries.unshields, formatUnshields, startingBlock, options),
  nullifiers: squidPages(queries.nullifiers, formatNullifiers, startingBlock, options),
  commitments: squidPages(queries.commitments, formatCommitments, startingBlock, options),
});

/**
 * Reports a quick sync's progress toward `head` (the newest block number) through the engine's own scan updates, so
 * the page hears it as the engine's; none without a head.
 */
export function progressReporter(engine, txidVersion, chain, startingBlock, head) {
  if (head === undefined) return undefined;
  return (block) =>
    engine.emitUTXOMerkletreeScanUpdateEvent(txidVersion, chain, quickSyncProgress(startingBlock, head, block));
}
