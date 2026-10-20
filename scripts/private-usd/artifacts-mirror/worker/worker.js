// A read-only mirror of the RAILGUN circuit artifacts the wallet SDK downloads from IPFS, for Veylor's Private USD
// page. The files are Workers static assets at their IPFS paths (/ipfs/<hash>/...), so only the base URL differs
// from the SDK's gateway; _headers adds CORS and long caching. They are content-addressed and the SDK checks every
// zkey and wasm against its own hashes, so the mirror is trusted for availability only.
//
// Every request comes here first: GET and HEAD go on to the assets, a CORS preflight is answered, the rest refused.
// A file over the 25 MiB asset limit is stored as <path>.part0, .part1, ... and served joined at its own path.
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Range',
  'Access-Control-Max-Age': '86400',
};

// Path -> number of parts.
const SPLIT = {
  '/ipfs/QmZrP9zaZw2LwErT2yA6VpMWm65UdToQiKj4DtStVsUJHr/POI_13x13/zkey.br': 2,
  '/ipfs/QmZ2MyM6TKxffkv6stuo2hFwmUfs3q4xgMYN164Sje8new/circuits/13x13/zkey.br': 2,
};

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405, headers: CORS });
    }
    const path = new URL(request.url).pathname;
    if (!path.startsWith('/ipfs/') || /\.part[0-9]+$/.test(path)) {
      return new Response('Not found', { status: 404, headers: CORS });
    }
    const parts = SPLIT[path];
    return parts ? joined(request, env, path, parts) : env.ASSETS.fetch(request);
  },
};

async function joined(request, env, path, parts) {
  const responses = [];
  for (let i = 0; i < parts; i++) {
    const part = await env.ASSETS.fetch(new Request(new URL(`${path}.part${i}`, request.url)));
    if (!part.ok) return new Response('Not found', { status: 404, headers: CORS });
    responses.push(part);
  }
  const headers = new Headers(CORS);
  headers.set('Content-Type', 'application/octet-stream');
  headers.set('Cache-Control', 'public, max-age=31536000, immutable');
  const lengths = responses.map((r) => Number(r.headers.get('Content-Length')));
  if (lengths.every((n) => n > 0)) headers.set('Content-Length', String(lengths.reduce((a, b) => a + b, 0)));
  if (request.method === 'HEAD') {
    for (const r of responses) await r.body?.cancel();
    return new Response(null, { headers });
  }
  const { readable, writable } = new TransformStream();
  (async () => {
    for (const r of responses) await r.body.pipeTo(writable, { preventClose: true });
    await writable.close();
  })();
  return new Response(readable, { headers });
}
