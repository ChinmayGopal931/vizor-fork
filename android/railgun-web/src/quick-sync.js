// The engine's quick sync reads Railgun's whole history before storing any of it: the SDK holds every page of every
// list in memory, joining each page onto the ones before (1.65 GB of JavaScript heap on a mainnet first sync), and
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

/** The most events the indexer answers at once. */
export const SQUID_PAGE_SIZE = 10_000;
/** As the SDK waits on each page, and between two of one list. */
export const PAGE_TIMEOUT_MS = 20_000;
const PAGE_GAP_MS = 250;
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

/**
 * One of the indexer's event lists from `startingBlock` on, a page at a time: `{events, through}`, the page's events
 * as `format` makes them, and the block through which the list has now given every event (Infinity at its end). The
 * next page is asked for while this one is stored. The indexer pages by block, starting each page at the block the
 * last one ended on, so a page's events that the last page gave are left out.
 */
export async function* squidPages(query, format, startingBlock, { pageSize = SQUID_PAGE_SIZE, gapMs = PAGE_GAP_MS } = {}) {
  const ask = (block, wait) => {
    const answer = (wait ? delay(wait) : Promise.resolve()).then(() => withTimeout(query(block), PAGE_TIMEOUT_MS));
    answer.catch(() => {});
    return answer;
  };
  let from = startingBlock;
  let given = new Set();
  let next = ask(from, 0);
  for (;;) {
    const page = await next;
    const full = page.length >= pageSize;
    const last = page.length === 0 ? from : Number(page[page.length - 1].blockNumber);
    const events = page.filter(({ id }) => !given.has(id));
    if (full && last === from && events.length === 0) {
      throw new Error(`the indexer has more than a page of events in block ${from}`);
    }
    if (full) {
      given = new Set(page.filter(({ blockNumber }) => Number(blockNumber) === last).map(({ id }) => id));
      from = last;
      next = ask(from, gapMs);
    }
    yield { events: format(events), through: full ? last - 1 : Infinity };
    if (!full) return;
  }
}

/**
 * Stores a quick sync's events as they come and returns nothing more for the engine to store. `unshields`,
 * `nullifiers` and `commitments` are page lists as `squidPages` gives them. The engine resumes a quick sync from its
 * newest stored commitment's block, so the unshields and nullifiers of a page's blocks are stored before its
 * commitments, and a page's commitments go into the tree before the next page is read. `stored(block)` hears the
 * block each page of commitments reached.
 */
export async function storeEvents({ engine, txidVersion, chain, unshields, nullifiers, commitments, stored }) {
  const merkletree = engine.getUTXOMerkletree(txidVersion, chain);
  const before = [
    { pages: unshields, through: -Infinity, store: (events) => engine.unshieldListener(txidVersion, chain, events) },
    { pages: nullifiers, through: -Infinity, store: (events) => engine.nullifierListener(txidVersion, chain, events) },
  ];
  const storeThrough = async (block) => {
    for (const list of before) {
      while (list.through < block) {
        const { value, done } = await list.pages.next();
        if (done) {
          list.through = Infinity;
          break;
        }
        if (value.events.length > 0) await list.store(value.events);
        list.through = value.through;
      }
    }
  };
  for await (const { events } of commitments) {
    if (events.length === 0) continue;
    const reached = events.reduce((highest, batch) => Math.max(highest, batch.blockNumber), -Infinity);
    await storeThrough(reached);
    await engine.commitmentListener(txidVersion, chain, events, false, false);
    await merkletree.updateTreesFromWriteQueue(true);
    stored?.(reached);
  }
  await storeThrough(Infinity);
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
 * newest block, for the progress it reports; without it the quick sync reports none of its own. `pages` are
 * `squidPages`'s options.
 */
export function installQuickSync(engine, { queries, head, pages }) {
  const own = engine.quickSyncEvents;
  engine.quickSyncEvents = async (txidVersion, chain, startingBlock) => {
    if (txidVersion !== TXIDVersion.V2_PoseidonMerkle) return own(txidVersion, chain, startingBlock);
    return storeEvents({
      engine,
      txidVersion,
      chain,
      ...squidLists(queries, startingBlock, pages),
      stored: await progressReporter(engine, txidVersion, chain, startingBlock, head),
    });
  };
}

/** The indexer's three lists from `startingBlock` on. */
export const squidLists = (queries, startingBlock, options) => ({
  unshields: squidPages(queries.unshields, formatUnshields, startingBlock, options),
  nullifiers: squidPages(queries.nullifiers, formatNullifiers, startingBlock, options),
  commitments: squidPages(queries.commitments, formatCommitments, startingBlock, options),
});

/** Reports a quick sync's progress through the engine's own scan updates, so the page hears it as the engine's. */
export async function progressReporter(engine, txidVersion, chain, startingBlock, head) {
  let newest;
  try {
    newest = await head();
  } catch {
    return undefined;
  }
  return (block) =>
    engine.emitUTXOMerkletreeScanUpdateEvent(txidVersion, chain, quickSyncProgress(startingBlock, newest, block));
}
