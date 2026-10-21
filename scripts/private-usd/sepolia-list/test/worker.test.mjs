// The Worker's handler with `fetch` standing in for the squid: what it serves, what reaches the squid, and that a list
// comes back repaired.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { afterEach, test } from 'node:test';
import { PREDECESSOR } from '../repair.js';
import worker from '../worker.js';

const SQUID = 'https://rail-squid.squids.live/squid-railgun-eth-sepolia-v2/graphql';
const LIST = 'https://railgun-sepolia-list.example.workers.dev/graphql';
const fixture = JSON.parse(readFileSync(new URL('fixture.json', import.meta.url), 'utf8'));
const at = (index) => fixture.transactions[index - fixture.first];

const PAGE_QUERY = `query GetRailgunTransactionsAfterGraphID($idLow: String = "0x00") {
  transactions(orderBy: id_ASC, limit: 10000, where: {id_gt: $idLow}) {
    id
    nullifiers
    verificationHash
  }
}`;
const NULLIFIERS_QUERY = `query Nullifiers($blockNumber: BigInt = 0) {
  nullifiers(orderBy: [blockNumber_ASC, nullifier_DESC], where: {blockNumber_gte: $blockNumber}, limit: 10000) {
    id
    nullifier
  }
}`;
// As the SDK's GraphQL client posts it: it names the URL it called in `extensions`.
const sdkBody = (query, variables = {}) =>
  JSON.stringify({ query, variables, extensions: { headers: {}, endpoint: LIST } });
const squidAnswer = (list) => `${JSON.stringify({ data: { transactions: list } })}\n`;
const JSON_TYPE = { 'Content-Type': 'application/json' };

const calls = [];
const original = globalThis.fetch;
/** Answers the Worker's requests with `answers`, in order, and records them. */
function squid(...answers) {
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    const answer = answers.shift();
    if (answer instanceof Error) throw answer;
    const headers = { 'Content-Type': 'application/json; charset=utf-8' };
    return new Response(answer.body, { status: answer.status ?? 200, headers });
  };
}
afterEach(() => {
  globalThis.fetch = original;
  calls.length = 0;
});

const post = (body, headers = {}) =>
  worker.fetch(new Request(LIST, { method: 'POST', body, headers: { ...JSON_TYPE, ...headers } }));

test('only GraphQL POSTs to /graphql are served, after a CORS preflight', async () => {
  squid();
  const preflight = await worker.fetch(new Request(LIST, { method: 'OPTIONS' }));
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('Access-Control-Allow-Origin'), '*');
  assert.match(preflight.headers.get('Access-Control-Allow-Methods'), /\bPOST\b/);
  assert.match(preflight.headers.get('Access-Control-Allow-Headers'), /\bContent-Type\b/);
  const refused = [
    new Request(LIST),
    new Request(new URL('/', LIST), { method: 'POST', body: sdkBody(PAGE_QUERY) }),
    new Request(new URL('/graphql/more', LIST), { method: 'POST', body: sdkBody(PAGE_QUERY) }),
    new Request(new URL('/', LIST), { method: 'OPTIONS' }),
    new Request(LIST, { method: 'POST', body: 'not json' }),
    new Request(LIST, { method: 'POST', body: '{"variables":{}}' }),
    new Request(LIST, { method: 'POST', body: JSON.stringify({ query: `{ ${'x'.repeat(70_000)} }` }) }),
  ];
  for (const request of refused) {
    const response = await worker.fetch(request);
    assert.equal(response.status, 404, `${request.method} ${request.url}`);
    assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
  }
  assert.equal(calls.length, 0);
});

test("a query reaches the squid as the SDK sends it there, without the requester's headers", async () => {
  const events = '{"data":{"nullifiers":[]}}\n';
  squid({ body: events });
  const accept = 'application/graphql-response+json, application/json, multipart/mixed';
  const response = await post(sdkBody(NULLIFIERS_QUERY, { blockNumber: '0' }), {
    Accept: accept,
    Origin: 'https://railgun.appassets.androidplatform.net',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14; SM-A356E; wv)',
    'Accept-Language': 'en-US',
    'X-Forwarded-For': '203.0.113.7',
    'CF-Connecting-IP': '203.0.113.7',
  });
  assert.equal(calls.length, 1);
  const [{ url, init, body }] = calls;
  assert.equal(url, SQUID);
  assert.equal(init.method, 'POST');
  assert.deepEqual(init.headers, { 'Content-Type': 'application/json', 'Accept-Encoding': 'identity', Accept: accept });
  assert.deepEqual(body, JSON.parse(sdkBody(NULLIFIERS_QUERY, { blockNumber: '0' }).replace(LIST, SQUID)));

  assert.equal(response.status, 200);
  assert.equal(await response.text(), events);
  assert.equal(response.headers.get('Content-Type'), 'application/json; charset=utf-8');
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('X-Verification-Hashes'), null);
});

test('a page past the break comes back repaired, with the one extra query', async () => {
  const page = [4192, 4193, 4194].map(at);
  const chain = fixture.transactions
    .filter(({ id }) => id > PREDECESSOR.id && id < at(4192).id)
    .map(({ id, nullifiers }) => ({ id, nullifiers }));
  const predecessor = { verificationHash: PREDECESSOR.verificationHash };
  squid({ body: squidAnswer(page) }, { body: JSON.stringify({ data: { predecessor, chain } }) });
  const response = await post(sdkBody(PAGE_QUERY, { idLow: at(4191).id }));
  assert.equal(response.headers.get('X-Verification-Hashes'), 'repaired 3');
  const served = JSON.parse(await response.text()).data.transactions;
  assert.deepEqual(served.map(({ verificationHash }) => verificationHash), page.map(({ id }) => fixture.repaired[id]));

  assert.equal(calls.length, 2);
  const extra = calls[1];
  assert.equal(extra.url, SQUID);
  assert.deepEqual(extra.init.headers, {
    'Content-Type': 'application/json',
    'Accept-Encoding': 'identity',
    Accept: 'application/json',
  });
  assert.deepEqual(extra.body.variables, { predecessor: PREDECESSOR.id, bound: at(4192).id });
});

test("the squid's errors are relayed, and a failed extra query leaves the list as it came", async () => {
  squid({ body: '{"errors":[{"message":"bad"}]}\n', status: 400 });
  const rejected = await post(sdkBody(PAGE_QUERY));
  assert.equal(rejected.status, 400);
  assert.equal(await rejected.text(), '{"errors":[{"message":"bad"}]}\n');
  assert.equal(rejected.headers.get('X-Verification-Hashes'), null);

  squid(new Error('offline'));
  assert.equal((await post(sdkBody(PAGE_QUERY))).status, 502);

  const page = squidAnswer([at(4192)]);
  squid({ body: page }, new Error('offline'));
  const unrepaired = await post(sdkBody(PAGE_QUERY, { idLow: at(4191).id }));
  assert.equal(unrepaired.status, 200);
  assert.equal(unrepaired.headers.get('X-Verification-Hashes'), 'unrepaired: list unavailable');
  assert.equal(await unrepaired.text(), page);
});
