// Railgun's Sepolia transaction list for Veylor's Railgun page, with its verificationHash chain repaired. Every GraphQL
// POST to /graphql goes on to Railgun's Sepolia indexer (the squid), and its answer comes back as it was, except that a
// `transactions` list's hashes from the break on are recomputed (repair.js). Nothing else is served.
//
// It logs nothing and keeps nothing. A request reaches the squid without its headers, and with the URL the SDK's client
// writes into the body set back to the squid's, so the squid sees the query as the SDK sends it there directly. The one
// query of its own, for the chain before a page, carries the break's ids and the page's first or last id. Answers are
// asked for uncompressed: the Worker hands on plain bytes either way, and inflating the whole list first would cost
// about 7 ms of CPU.
import { keccak_256 } from '@noble/hashes/sha3.js';
import { chainAnswer, chainRequest, queryShape, repair } from './repair.js';

const SQUID = 'https://rail-squid.squids.live/squid-railgun-eth-sepolia-v2/graphql';
const PLAIN = { 'Content-Type': 'application/json', 'Accept-Encoding': 'identity' };
// The SDK's queries are under 1 KiB.
const MAX_QUERY_BYTES = 64 * 1024;
const CORS = { 'Access-Control-Allow-Origin': '*' };
const PREFLIGHT = {
  ...CORS,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept',
  'Access-Control-Max-Age': '86400',
};

// V8 interprets keccak for its first few dozen calls, about 8 ms of CPU, and a repair hashes once per transaction since
// the break. Hashing at startup, before any request, leaves the requests the compiled function.
for (let i = 0, input = new Uint8Array(64); i < 100; i += 1) input.set(keccak_256(input));

export default {
  async fetch(request) {
    if (new URL(request.url).pathname !== '/graphql') return notFound();
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: PREFLIGHT });
    const payload = request.method === 'POST' ? await graphqlPayload(request) : undefined;
    if (payload === undefined) return notFound();

    let upstream;
    try {
      upstream = await fetch(SQUID, {
        method: 'POST',
        headers: { ...PLAIN, Accept: request.headers.get('Accept') ?? 'application/json' },
        body: JSON.stringify(payload),
      });
    } catch {
      return new Response('Bad gateway', { status: 502, headers: CORS });
    }
    const headers = new Headers({ ...CORS, 'Cache-Control': 'no-store' });
    headers.set('Content-Type', upstream.headers.get('Content-Type') ?? 'application/json');
    const shape = queryShape(payload.query);
    if (shape === undefined || upstream.status !== 200) {
      return new Response(upstream.body, { status: upstream.status, headers });
    }
    const { body, outcome } = await repair(new Uint8Array(await upstream.arrayBuffer()), shape, fetchChain);
    headers.set('X-Verification-Hashes', outcome);
    return new Response(body, { headers });
  },
};

// The request's GraphQL body, or undefined when it isn't one.
async function graphqlPayload(request) {
  if (Number(request.headers.get('Content-Length')) > MAX_QUERY_BYTES) return undefined;
  const text = await request.text();
  if (text.length > MAX_QUERY_BYTES) return undefined;
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    return undefined;
  }
  if (typeof payload?.query !== 'string') return undefined;
  if (typeof payload.extensions?.endpoint === 'string') payload.extensions = { ...payload.extensions, endpoint: SQUID };
  return payload;
}

async function fetchChain(bound) {
  const response = await fetch(SQUID, {
    method: 'POST',
    headers: { ...PLAIN, Accept: 'application/json' },
    body: JSON.stringify(chainRequest(bound)),
  });
  if (!response.ok) throw new Error(`the squid answered ${response.status}`);
  return chainAnswer(await response.json());
}

function notFound() {
  return new Response('Not found', { status: 404, headers: CORS });
}
