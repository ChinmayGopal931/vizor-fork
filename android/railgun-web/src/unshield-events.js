// The engine never overwrites an unshield event it has, since a stored one carries what later syncs added to it (its
// railgunTxid, its screening results). So it looks every new event up first, one IndexedDB transaction each: on a
// first sync that is some 111,000 lookups that all find nothing, about ten minutes on a phone. An event can only be
// stored already if its block is at or below the highest block of the stored events, so that block is kept beside
// them, written in the same batch as every event. Events above it skip the lookup; the rest are looked up as before.
// The build (engine-hooks-plugin.mjs) has the engine's `addUnshieldEvents` call `addUnshieldEvents` here.
import { Database } from '@railgun-community/engine';

// A key of its own inside the unshield events' namespace, so whatever clears the events clears it too. The events'
// own keys are a txid and an event index (or railgunTxid) deeper.
const WATERMARK = Buffer.from('vizor-unshield-watermark').toString('hex');
const EVENT_KEY_PARTS = 6;

// One add at a time per merkletree: the watermark only ever rises.
const adding = new WeakMap();

/** The engine's `UTXOMerkletree.addUnshieldEvents(unshields, replaceExisting)`, for `merkletree`. */
export function addUnshieldEvents(merkletree, unshields, replaceExisting = false) {
  // Only events read back from the store are replaced, so the watermark already covers them.
  if (replaceExisting) return write(merkletree, unshields);
  const added = (adding.get(merkletree) ?? Promise.resolve()).then(() => addNew(merkletree, unshields));
  adding.set(
    merkletree,
    added.catch(() => {}),
  );
  return added;
}

async function addNew(merkletree, unshields) {
  const watermark = await storedWatermark(merkletree);
  // A page of events can hold one twice (sources page by block, and repeat the block a page ends on).
  const unique = new Map(unshields.map((unshield) => [eventKey(merkletree, unshield), unshield]));
  const fresh = [];
  const stored = [];
  for (const unshield of unique.values()) {
    (blockOf(unshield) > watermark ? fresh : stored).push(unshield);
  }
  const absent = await Promise.all(
    stored.map(async (unshield) => ((await merkletree.hasExistingUnshieldEvent(unshield)) ? undefined : unshield)),
  );
  const added = [...absent.filter((unshield) => unshield !== undefined), ...fresh];
  if (added.length === 0) return undefined;
  const highest = added.reduce((top, unshield) => Math.max(top, blockOf(unshield)), watermark);
  return write(merkletree, added, highest);
}

/** The events (and the watermark, when it is a block) in one batch, as the engine writes them. */
function write(merkletree, unshields, watermark) {
  const batch = unshields.map((unshield) => ({ type: 'put', key: eventKey(merkletree, unshield), value: unshield }));
  if (Number.isSafeInteger(watermark)) {
    batch.push({ type: 'put', key: Database.pathToKey(watermarkPath(merkletree)), value: watermark });
  }
  return merkletree.db.batch(batch, 'json');
}

const eventKey = (merkletree, { txid, eventLogIndex, railgunTxid }) =>
  merkletree.getUnshieldEventsDBPath(txid, eventLogIndex, railgunTxid).join(':');

// An event without a block is looked up, and never moves the watermark.
const blockOf = ({ blockNumber }) => (Number.isSafeInteger(blockNumber) ? blockNumber : -Infinity);

const namespaceOf = (merkletree) => merkletree.getUnshieldEventsDBPath(undefined, undefined, undefined);

const watermarkPath = (merkletree) => [...namespaceOf(merkletree), WATERMARK];

/**
 * The highest block of the stored events: -Infinity with none stored. A store written before the watermark existed is
 * read through once, and the block it finds kept.
 */
async function storedWatermark(merkletree) {
  const path = watermarkPath(merkletree);
  try {
    const kept = await merkletree.db.get(path, 'json');
    if (Number.isSafeInteger(kept)) return kept;
  } catch (error) {
    if (!isNotFound(error)) throw error;
  }
  const namespace = namespaceOf(merkletree);
  if ((await merkletree.db.countNamespace(namespace)) === 0) return -Infinity;
  const highest = await highestStoredBlock(merkletree.db, namespace);
  if (Number.isSafeInteger(highest)) await merkletree.db.put(path, highest, 'json');
  return highest;
}

/** The highest block among the events stored under `namespace`; Infinity if one has none, so all are looked up. */
function highestStoredBlock(db, namespace) {
  const prefix = Database.pathToKey(namespace);
  return new Promise((resolve, reject) => {
    let highest = -Infinity;
    db.level
      .createReadStream({ gte: prefix, lte: `${prefix}~`, keys: true, values: true, valueEncoding: 'json' })
      .on('data', ({ key, value }) => {
        if (String(key).split(':').length !== EVENT_KEY_PARTS) return;
        highest = Math.max(highest, Number.isSafeInteger(value?.blockNumber) ? value.blockNumber : Infinity);
      })
      .on('error', reject)
      .on('end', () => resolve(highest));
  });
}

const isNotFound = (error) => error?.notFound === true || error?.type === 'NotFoundError';
