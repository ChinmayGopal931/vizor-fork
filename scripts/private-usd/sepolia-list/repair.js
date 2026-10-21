// Railgun's Sepolia indexer (the squid) serves its transaction list with a verificationHash chain that breaks at
// #4188. The wallet's engine checks hash[n] = keccak256(hash[n-1] || firstNullifier[n]) as it syncs, so it stops there
// and never gets past it. The transactions themselves are right, and every hash after #4188 chains correctly from the
// squid's one wrong value there. This recomputes the hashes from #4188 on, from #4187's (the last right one), and
// changes no other byte of the squid's answer.
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils.js';

/** The squid's id for #4188, the first transaction whose hash it gets wrong. */
export const BREAK_ID =
  '0x0000000000000000000000000000000000000000000000000000000000b44f25' +
  '0000000000000000000000000000000000000000000000000000000000000040' +
  '0000000000000000000000000000000000000000000000000000000000000000';

/**
 * #4187, the transaction before the break, with the hash the chain from #0 reaches there. The repaired chain starts
 * from it, and a list that disagrees about it is passed on untouched.
 */
export const PREDECESSOR = {
  id:
    '0x0000000000000000000000000000000000000000000000000000000000b44859' +
    '0000000000000000000000000000000000000000000000000000000000000056' +
    '0000000000000000000000000000000000000000000000000000000000000000',
  verificationHash: '0x267e5169077324960d1dfaf76dd4444ee1e9c0b1b8ab158069e8619144d1cd5f',
};

/** The most transactions the extra query asks for, as the SDK's own sync does; a full answer may be cut short. */
export const CHAIN_LIMIT = 10_000;

// A long list is read from its end, where the break's transactions are, this much at a time.
const WINDOW = 1 << 20;
// The squid's answer to a `transactions` query, compact, and one transaction's opening and hash.
const OPEN = '{"data":{"transactions":[';
const CLOSE = ']}}';
const TRANSACTION = '{"id":"';
const HASH = '"verificationHash":"';

const decoder = new TextDecoder();
const encoder = new TextEncoder();

class Unrepaired extends Error {}

/**
 * What `query` asks of the transaction list: undefined when no verificationHash can come back from it, `unknown` for
 * a shape this can't repair, and otherwise whether its transactions come sorted by id (`sorted`) and whether they are
 * every transaction after a cursor, in order (`page`: the SDK's sync, filtered by `id_gt` alone).
 */
export function queryShape(query) {
  if (typeof query !== 'string' || !query.includes('verificationHash')) return undefined;
  const fields = query.match(/\btransactions\b/g)?.length ?? 0;
  if (fields !== 1 || /\w\s*:\s*transactions\b/.test(query)) return { unknown: true };
  const args = (/\btransactions\s*\(([^)]*)\)/.exec(query)?.[1] ?? '').replace(/[\s,]+/g, ' ').trim();
  return {
    sorted: /(^| )orderBy: id_ASC( |$)/.test(args),
    page: /^orderBy: id_ASC limit: \d+ where: \{ ?id_gt: (\$\w+|"[^"]*") ?\}$/.test(args),
  };
}

/**
 * The extra query: the predecessor's hash, and the first nullifiers of the transactions after it, up to a page's
 * first id (`before`) or through a filtered list's last (`through`).
 */
export function chainRequest({ before, through }) {
  const bound = before === undefined ? 'id_lte' : 'id_lt';
  return {
    query: `query RepairChain($predecessor: String!, $bound: String!) {
  predecessor: transactionById(id: $predecessor) { verificationHash }
  chain: transactions(orderBy: id_ASC, limit: ${CHAIN_LIMIT}, where: {id_gt: $predecessor, ${bound}: $bound}) {
    id nullifiers
  }
}`,
    variables: { predecessor: PREDECESSOR.id, bound: before ?? through },
  };
}

/** The squid's answer to `chainRequest`, as `repair`'s `fetchChain` returns it. */
export function chainAnswer(json) {
  if (json?.errors !== undefined || !Array.isArray(json?.data?.chain)) throw new Error('no chain in the answer');
  return { predecessor: json.data.predecessor?.verificationHash, rows: json.data.chain };
}

/**
 * The squid's answer `body` (bytes) to a query of `shape`, with the hash of every transaction at or after the break
 * recomputed, and what was done, for the response's header. The chain comes from the answer itself when it is a page
 * holding the predecessor; otherwise `fetchChain` makes the one extra query (`chainRequest`). Anything unexpected
 * leaves the answer as it came, and the outcome says why.
 */
export async function repair(body, shape, fetchChain, { window = WINDOW } = {}) {
  try {
    if (shape.unknown) throw new Unrepaired('unknown query');
    const list = locate(body, shape.sorted, window);
    const after = list.transactions.filter((transaction) => transaction.id >= BREAK_ID);
    if (after.length === 0) return { body, outcome: 'nothing to repair' };
    const hashes = await repairedHashes(list.transactions, after, shape.page, fetchChain);
    const patches = hashPatches(list.text, list.transactions, hashes);
    if (patches.length === 0) return { body, outcome: 'intact' };
    const repaired = body.slice();
    for (const [at, hash] of patches) encoder.encodeInto(hash, repaired.subarray(list.offset + at));
    return { body: repaired, outcome: `repaired ${patches.length}` };
  } catch (error) {
    return { body, outcome: `unrepaired: ${error instanceof Unrepaired ? error.message : 'unexpected response'}` };
  }
}

// The transactions to read, and their text, which starts at byte `offset` of the body with one character to a byte (so
// a hash's place in the text is its place in the body). A sorted list in the squid's compact form is read from its
// end, back to the transaction before the break, which keeps a long list's work to the part that needs it; anything
// else is parsed whole.
function locate(body, sorted, window) {
  const end = sorted ? closeAt(body) : -1;
  for (let size = window; end > 0; size *= 4) {
    const start = Math.max(0, end - size);
    const text = decoder.decode(body.subarray(start, end));
    if (text.length !== end - start) break;
    const from = firstNeeded(text, start === 0);
    if (from === undefined) continue;
    const region = text.slice(from);
    let transactions;
    try {
      transactions = JSON.parse(`[${region}]`);
    } catch {
      break;
    }
    checked(transactions);
    ascending(transactions);
    return { text: region, offset: start + from, transactions };
  }
  const text = decoder.decode(body);
  if (text.length !== body.length) throw new Unrepaired('unexpected response');
  const transactions = JSON.parse(text)?.data?.transactions;
  return { text, offset: 0, transactions: checked(Array.isArray(transactions) ? transactions : []) };
}

// Where the list's closing `]` is when the body is a lone `transactions` list in the squid's form, or -1.
function closeAt(body) {
  let end = body.length;
  while (end > 0 && (body[end - 1] === 0x0a || body[end - 1] === 0x0d || body[end - 1] === 0x20)) end -= 1;
  const opens = decoder.decode(body.subarray(0, OPEN.length)) === OPEN;
  const closes = end >= OPEN.length + CLOSE.length && decoder.decode(body.subarray(end - CLOSE.length, end)) === CLOSE;
  return opens && closes ? end - CLOSE.length : -1;
}

// Where in `text`, the end of a sorted list up to its closing `]`, the transactions to read begin: at the last one
// before the break, so that a list holding the predecessor brings it along, or, when `whole` and all are past the
// break, at the first. Undefined when the text starts too late to tell.
function firstNeeded(text, whole) {
  let first = text.length;
  while (first > 0) {
    const at = text.lastIndexOf(TRANSACTION, first - 1);
    if (at < 0) break;
    const id = at + TRANSACTION.length;
    if (text.slice(id, text.indexOf('"', id)) < BREAK_ID) return at;
    first = at;
  }
  return whole ? first : undefined;
}

function checked(transactions) {
  for (const transaction of transactions) {
    if (typeof transaction?.id !== 'string' || typeof transaction.verificationHash !== 'string') {
      throw new Unrepaired('unexpected response');
    }
  }
  return transactions;
}

function ascending(transactions) {
  for (let i = 1; i < transactions.length; i += 1) {
    if (!(transactions[i].id > transactions[i - 1].id)) throw new Unrepaired('out of order');
  }
}

// Each transaction's repaired hash at and after the break, from the predecessor's: from the list itself when it is a
// page that holds the predecessor (every transaction after it then comes with it), otherwise with the extra query. A
// page whose transactions come without their nullifiers takes them all from the extra query.
async function repairedHashes(transactions, after, page, fetchChain) {
  const first = after.reduce((low, transaction) => (transaction.id < low.id ? transaction : low));
  const last = after.reduce((high, transaction) => (transaction.id > high.id ? transaction : high));
  const at = transactions.indexOf(first);
  const fromPage = page && after.every(({ nullifiers }) => Array.isArray(nullifiers));
  let anchor;
  let chain;
  if (fromPage && at > 0) {
    anchor = transactions[at - 1];
    chain = transactions.slice(at);
  } else {
    let answer;
    try {
      answer = await fetchChain(fromPage ? { before: first.id } : { through: last.id });
    } catch {
      throw new Unrepaired('list unavailable');
    }
    const { predecessor, rows } = answer;
    if (rows.length >= CHAIN_LIMIT || (!fromPage && rows.at(-1)?.id !== last.id)) {
      throw new Unrepaired('list incomplete');
    }
    anchor = { id: PREDECESSOR.id, verificationHash: predecessor };
    chain = fromPage ? [...rows, ...transactions] : rows;
  }
  if (anchor.id !== PREDECESSOR.id || anchor.verificationHash !== PREDECESSOR.verificationHash) {
    throw new Unrepaired('predecessor changed');
  }
  if (chain[0]?.id !== BREAK_ID) throw new Unrepaired('break moved');
  ascending(chain);

  const hashes = new Map();
  const firstNullifiers = new Map();
  const input = new Uint8Array(64);
  let hash = bytes32(PREDECESSOR.verificationHash);
  for (const { id, nullifiers } of chain) {
    input.set(hash, 0);
    input.set(bytes32(nullifiers?.[0]), 32);
    hash = keccak_256(input);
    hashes.set(id, `0x${bytesToHex(hash)}`);
    firstNullifiers.set(id, nullifiers[0]);
  }
  // The extra query is a second read of the list: it must agree with the first about every transaction it repairs.
  for (const { id, nullifiers } of after) {
    if (!hashes.has(id)) throw new Unrepaired('list incomplete');
    if (nullifiers !== undefined && firstNullifiers.get(id) !== nullifiers[0]) throw new Unrepaired('list changed');
  }
  return hashes;
}

// A 32-byte value from the squid's hex, as the engine reads it.
function bytes32(hex) {
  if (typeof hex !== 'string' || !/^0x[0-9a-fA-F]{1,64}$/.test(hex)) throw new Unrepaired('unexpected response');
  return hexToBytes(hex.slice(2).padStart(64, '0'));
}

// Where in `text` each transaction's hash is to be replaced by its entry in `hashes`, with the entry. Every transaction
// has one hash, in the order of `transactions`; a text that disagrees with that is left alone.
function hashPatches(text, transactions, hashes) {
  const patches = [];
  let from = 0;
  for (const transaction of transactions) {
    const key = text.indexOf(HASH, from);
    if (key < 0) throw new Unrepaired('unexpected response');
    const start = key + HASH.length;
    const end = text.indexOf('"', start);
    if (text.slice(start, end) !== transaction.verificationHash) throw new Unrepaired('unexpected response');
    from = end;
    const hash = hashes.get(transaction.id);
    if (hash !== undefined && hash !== transaction.verificationHash) {
      if (end - start !== hash.length) throw new Unrepaired('unexpected response');
      patches.push([start, hash]);
    }
  }
  if (text.indexOf(HASH, from) >= 0) throw new Unrepaired('unexpected response');
  return patches;
}
