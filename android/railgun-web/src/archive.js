// Anon's archive of Railgun's history (https://docs.anon.inc/advanced/digest-sync): sealed chunks of events, and a tip
// that is replaced every few seconds. Every path depends on the chain alone. Every event file is checked against the
// SHA-256 the archive publishes for it before it is used, and anything unexpected is an `ArchiveUnavailable`, on which
// the sync turns to rail-squid.
import { pauseMark, pausedSince } from './page-clock.js';

/** The archive can't be used from here on: the sync goes on from rail-squid. */
export class ArchiveUnavailable extends Error {}

/**
 * The archive didn't answer a request, or turned it away as a busy or failing server does, through every try: this
 * says nothing against what it holds (archive-sync.js asks it again later).
 */
export class ArchiveUnreachable extends ArchiveUnavailable {}

// The tip was replaced between two reads; read the manifest again.
class TipMoved extends ArchiveUnavailable {}

// An event file that doesn't hash to the checksum published for it (`checksum`).
class ChecksumMismatch extends ArchiveUnavailable {
  constructor(message, checksum) {
    super(message);
    this.checksum = checksum;
  }
}

// The formats this reader knows. The root manifest, the chunk metas, the tip meta and the tree files each count their
// own versions.
const KNOWN = { version: 5, rootFormat: 2, chunkFormat: 3, tipFormat: 3, txidVersion: 'V2_PoseidonMerkle' };
// A format this reader takes: the one it knows (`least`), or a later one. The archive moves to a new path for a format
// that breaks its readers (`v4` today) and raises a number where it is, as it has the tip's, for one that doesn't.
// Nothing rests on the number: what a file holds is checked against the chain and the screening nodes whatever it says.
const reads = (format, least) => Number.isSafeInteger(format) && format >= least;
const TIP_ATTEMPTS = 3;
const TIMEOUT_MS = 60_000;
// A request that failed on the way, or that a busy or failing server turned away (the host answers 502 for a fetch of
// its own that failed), is sent again after 1, 2, 4 and 8 s: a phone's DNS can fail every lookup for seconds at a time,
// and a sync that leaves the archive reads the rest of its history from rail-squid, far slower. One a pause of the page
// cut through is sent again uncounted (page-clock.js).
const ATTEMPTS = 5;
const RETRY_MS = 1_000;
const retried = (status) => status === 408 || status === 425 || status === 429 || status >= 500;

const hex = (bytes) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
export const sha256 = async (bytes) => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
const gunzip = async (bytes) =>
  new Uint8Array(
    await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer(),
  );
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function decode(bytes, path) {
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new ArchiveUnavailable(`${path} is not JSON`);
  }
}

/**
 * The archive at `base` (`https://digest.anon.inc/v4/<chain id>`) for `chainId`. `fetch` is the page's, which the host
 * answers for the archive's host itself, through the page's own route; `retryMs` spaces the attempts at a request.
 */
export function archive(base, chainId, { fetch = globalThis.fetch, retryMs = RETRY_MS } = {}) {
  async function get(path) {
    let pardoned = 0;
    for (let attempt = 1; ; attempt += 1) {
      const mark = pauseMark();
      const { bytes, failure, again } = await getOnce(path);
      if (bytes !== undefined) return bytes;
      if (!again) throw failure;
      if (pausedSince(mark) && pardoned < ATTEMPTS) {
        pardoned += 1;
        attempt -= 1;
      } else if (attempt >= ATTEMPTS) {
        throw new ArchiveUnreachable(failure.message);
      }
      await delay(retryMs * 2 ** Math.max(0, attempt - 1));
    }
  }

  async function getOnce(path) {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), TIMEOUT_MS);
    try {
      const response = await fetch(`${base}/${path}`, { cache: 'no-store', signal: abort.signal });
      if (!response.ok) {
        return {
          failure: new ArchiveUnavailable(`the archive answered ${response.status} for ${path}`),
          again: retried(response.status),
        };
      }
      return { bytes: new Uint8Array(await response.arrayBuffer()) };
    } catch (error) {
      return {
        failure: new ArchiveUnavailable(`the archive did not answer for ${path}: ${error?.message ?? error}`),
        again: true,
      };
    } finally {
      clearTimeout(timer);
    }
  }

  /** An event file, checked as the archive publishes it: the SHA-256 of its JSON, unzipped. */
  async function events(path, published) {
    let json;
    try {
      json = await gunzip(await get(path));
    } catch (error) {
      if (error instanceof ArchiveUnavailable) throw error;
      throw new ArchiveUnavailable(`${path} is not gzip`);
    }
    if (typeof published?.checksum !== 'string') throw new ArchiveUnavailable(`${path} has no checksum`);
    if ((await sha256(json)) !== published.checksum) {
      throw new ChecksumMismatch(`${path} does not match its checksum`, published.checksum);
    }
    const parsed = decode(json, path);
    if (!Array.isArray(parsed)) throw new ArchiveUnavailable(`${path} is not a list`);
    return parsed;
  }

  // `query(kind)` is what a file's path is asked with.
  async function files(dir, meta, kinds, query = () => '') {
    const read = {};
    await Promise.all(
      kinds.map(async (kind) => {
        read[kind] = await events(`${dir}/${kind}.json.gz${query(kind)}`, meta.files?.[kind]);
      }),
    );
    return read;
  }

  /** Sealed chunk `chunk`'s meta, as the index names the chunk; `query` asks for it past a cache. */
  async function chunkMeta({ id, startBlock, endBlock }, query = '') {
    const path = `chunks/${id}/meta.json`;
    const meta = decode(await get(`${path}${query}`), path);
    if (
      !reads(meta.formatVersion, KNOWN.chunkFormat) ||
      meta.chunkId !== id ||
      meta.startBlock !== startBlock ||
      meta.endBlock !== endBlock
    ) {
      throw new ArchiveUnavailable(`chunk ${id} is not the one the index names`);
    }
    return meta;
  }

  return {
    /** The root manifest, its formats and chain checked. */
    async manifest() {
      const manifest = decode(await get('meta.json'), 'meta.json');
      if (
        !reads(manifest.version, KNOWN.version) ||
        !reads(manifest.formatVersion, KNOWN.rootFormat) ||
        manifest.chainId !== chainId ||
        manifest.txidVersion !== KNOWN.txidVersion ||
        !Number.isSafeInteger(manifest.latestSealedChunk) ||
        typeof manifest.tipChecksum !== 'string'
      ) {
        throw new ArchiveUnavailable('the archive manifest is not one this page reads');
      }
      return manifest;
    },

    /**
     * The sealed chunks `manifest` names, 0 to its latest, each after the last: their ids and block ranges. The index's
     * transaction sequences are left out: early chunks list none though they hold transactions.
     */
    async chunks(manifest) {
      const index = decode(await get(`chunk-index.json?v=${manifest.latestSealedChunk}`), 'chunk-index.json');
      const chunks = Array.isArray(index?.chunks) && index.chainId === chainId ? index.chunks : undefined;
      if (chunks === undefined || chunks.length !== manifest.latestSealedChunk + 1) {
        throw new ArchiveUnavailable('the chunk index does not match the manifest');
      }
      return chunks.map(({ id, startBlock, endBlock }, at) => {
        const before = chunks[at - 1];
        if (id !== at || !(startBlock <= endBlock) || (before !== undefined && !(startBlock > before.endBlock))) {
          throw new ArchiveUnavailable(`the chunk index is out of order at chunk ${at}`);
        }
        return { id, startBlock, endBlock };
      });
    },

    /**
     * Sealed chunk `chunk`'s event files of `kinds`. A file that doesn't match its checksum may be a cache's older
     * copy, of it or of the meta: the meta is asked for once more past the cache by the checksum that failed, and the
     * files by the checksums it names, which every wallet asks the same way.
     */
    async chunk(chunk, kinds) {
      const { id, startBlock, endBlock } = chunk;
      try {
        return { startBlock, endBlock, ...(await files(`chunks/${id}`, await chunkMeta(chunk), kinds)) };
      } catch (error) {
        if (!(error instanceof ChecksumMismatch)) throw error;
        const meta = await chunkMeta(chunk, `?v=${error.checksum}`);
        const query = (kind) => `?v=${meta.files?.[kind]?.checksum}`;
        return { startBlock, endBlock, ...(await files(`chunks/${id}`, meta, kinds, query)) };
      }
    },

    /**
     * The tip of `manifest`, starting the block after `after` (the last sealed chunk's end): its event files of
     * `kinds`. A tip replaced since the manifest was read fails as `TipMoved`.
     */
    async tip(manifest, after, kinds) {
      const query = `?v=${manifest.tipChecksum}`;
      const bytes = await get(`tip/meta.json${query}`);
      if ((await sha256(bytes)) !== manifest.tipChecksum) throw new TipMoved('the tip moved');
      const meta = decode(bytes, 'tip/meta.json');
      if (
        !reads(meta.formatVersion, KNOWN.tipFormat) ||
        meta.startBlock !== after + 1 ||
        !(meta.endBlock >= meta.startBlock - 1)
      ) {
        throw new ArchiveUnavailable(`the tip does not follow block ${after}`);
      }
      try {
        return {
          startBlock: meta.startBlock,
          endBlock: meta.endBlock,
          ...(await files('tip', meta, kinds, () => query)),
        };
      } catch (error) {
        // Its files replaced under it.
        throw error instanceof ArchiveUnavailable ? new TipMoved(error.message) : error;
      }
    },
  };
}

/**
 * Every sealed chunk overlapping `fromBlock` and on, then the tip, from `reader` (`archive`): `{startBlock, endBlock,
 * <kinds>}` in block order, each starting after the last, `prefetch` chunks downloading ahead. The manifest is read
 * again before the tip, and chunks sealed since come first; a tip that moved is read again. The tip must start the
 * block after the last sealed chunk, or the range ends there as an `ArchiveUnavailable`.
 */
export async function* archiveRange(reader, fromBlock, kinds, { prefetch = 4 } = {}) {
  let manifest = await reader.manifest();
  let sealed = await reader.chunks(manifest);
  // Every event through this block has been given.
  let given = fromBlock - 1;
  for (let attempt = 1; ; ) {
    const chunks = sealed.filter(({ endBlock }) => endBlock > given);
    const pending = [];
    const ask = () => {
      while (pending.length < prefetch && chunks.length > 0) {
        const read = reader.chunk(chunks.shift(), kinds);
        read.catch(() => {});
        pending.push(read);
      }
    };
    ask();
    while (pending.length > 0) {
      const chunk = await pending.shift();
      ask();
      yield chunk;
      given = chunk.endBlock;
    }
    const fresh = await reader.manifest();
    if (fresh.latestSealedChunk !== manifest.latestSealedChunk) {
      // Chunks sealed since the index was read: they come before the tip.
      manifest = fresh;
      sealed = await reader.chunks(fresh);
      continue;
    }
    try {
      yield await reader.tip(fresh, sealed.at(-1).endBlock, kinds);
      return;
    } catch (error) {
      if (!(error instanceof TipMoved) || attempt >= TIP_ATTEMPTS) throw error;
      attempt += 1;
    }
  }
}
