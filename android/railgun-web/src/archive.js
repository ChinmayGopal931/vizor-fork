// Anon's archive of Railgun's history (https://docs.anon.inc/advanced/digest-sync): sealed chunks of events, a tip
// that is replaced every few seconds, and the merkle trees prebuilt. Every path depends on the chain alone. Every file
// is checked against the SHA-256 the archive publishes for it before it is used, and anything unexpected is an
// `ArchiveUnavailable`, on which the sync turns to rail-squid.

/** The archive can't be used from here on: the sync goes on from rail-squid. */
export class ArchiveUnavailable extends Error {}

// The tip was replaced between two reads; read the manifest again.
class TipMoved extends ArchiveUnavailable {}

// The formats this reader knows. The root manifest, the chunk metas, the tip meta and the tree files each count their
// own versions.
const KNOWN = { version: 5, rootFormat: 2, chunkFormat: 3, tipFormat: 3, treeFormat: 1, txidVersion: 'V2_PoseidonMerkle' };
const TIP_ATTEMPTS = 3;
const TIMEOUT_MS = 60_000;

const hex = (bytes) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
export const sha256 = async (bytes) => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
const gunzip = async (bytes) =>
  new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
const decode = (bytes) => JSON.parse(new TextDecoder().decode(bytes));

/**
 * The archive at `base` (`https://digest.anon.inc/v4/<chain id>`) for `chainId`. `fetch` is the page's, which the host
 * answers for the archive's host itself, through the page's own route.
 */
export function archive(base, chainId, { fetch = globalThis.fetch } = {}) {
  async function get(path) {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), TIMEOUT_MS);
    let response;
    try {
      response = await fetch(`${base}/${path}`, { cache: 'no-store', signal: abort.signal });
      if (!response.ok) throw new ArchiveUnavailable(`the archive answered ${response.status} for ${path}`);
      return new Uint8Array(await response.arrayBuffer());
    } catch (error) {
      if (error instanceof ArchiveUnavailable) throw error;
      throw new ArchiveUnavailable(`the archive did not answer for ${path}: ${error?.message ?? error}`);
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
    if (typeof published?.checksum !== 'string' || (await sha256(json)) !== published.checksum) {
      throw new ArchiveUnavailable(`${path} does not match its checksum`);
    }
    const parsed = decode(json);
    if (!Array.isArray(parsed)) throw new ArchiveUnavailable(`${path} is not a list`);
    return parsed;
  }

  async function files(dir, meta, kinds, query = '') {
    const read = {};
    await Promise.all(
      kinds.map(async (kind) => {
        read[kind] = await events(`${dir}/${kind}.json.gz${query}`, meta.files?.[kind]);
      }),
    );
    return read;
  }

  return {
    /** The root manifest, its formats and chain checked. */
    async manifest() {
      const manifest = decode(await get('meta.json'));
      if (
        manifest.version !== KNOWN.version ||
        manifest.formatVersion !== KNOWN.rootFormat ||
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
      const index = decode(await get(`chunk-index.json?v=${manifest.latestSealedChunk}`));
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

    /** Sealed chunk `chunk`'s event files of `kinds`. */
    async chunk({ id, startBlock, endBlock }, kinds) {
      const meta = decode(await get(`chunks/${id}/meta.json`));
      if (meta.formatVersion !== KNOWN.chunkFormat || meta.chunkId !== id || meta.startBlock !== startBlock || meta.endBlock !== endBlock) {
        throw new ArchiveUnavailable(`chunk ${id} is not the one the index names`);
      }
      return { startBlock, endBlock, ...(await files(`chunks/${id}`, meta, kinds)) };
    },

    /**
     * The tip of `manifest`, starting the block after `after` (the last sealed chunk's end): its event files of `kinds`.
     * A tip replaced since the manifest was read fails as `TipMoved`.
     */
    async tip(manifest, after, kinds) {
      const query = `?v=${manifest.tipChecksum}`;
      const bytes = await get(`tip/meta.json${query}`);
      if ((await sha256(bytes)) !== manifest.tipChecksum) throw new TipMoved('the tip moved');
      const meta = decode(bytes);
      if (meta.formatVersion !== KNOWN.tipFormat || meta.startBlock !== after + 1 || !(meta.endBlock >= meta.startBlock - 1)) {
        throw new ArchiveUnavailable(`the tip does not follow block ${after}`);
      }
      try {
        return { startBlock: meta.startBlock, endBlock: meta.endBlock, ...(await files('tip', meta, kinds, query)) };
      } catch (error) {
        // Its files replaced under it.
        throw error instanceof ArchiveUnavailable ? new TipMoved(error.message) : error;
      }
    },

    /** A prebuilt tree file, checked against `checksum` (the SHA-256 of the gzip as served) when given. */
    async tree(path, checksum) {
      const gz = await get(path);
      if (checksum !== undefined && (await sha256(gz)) !== checksum) {
        throw new ArchiveUnavailable(`${path} does not match its checksum`);
      }
      try {
        return await gunzip(gz);
      } catch {
        throw new ArchiveUnavailable(`${path} is not gzip`);
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
