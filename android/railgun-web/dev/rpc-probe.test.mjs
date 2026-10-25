import assert from 'node:assert/strict';
import { test } from 'node:test';
import { errorCode } from '../src/errors.js';
import { syncFailure } from '../src/rpc-probe.js';

const RPC = 'https://eth-mainnet.g.alchemy.com/v2/secret-key';
const POI = 'https://ppoi.fdi.network/';
const urls = { rpcUrls: [RPC], poiNodeUrls: [POI] };
const cause = new Error('the notes scan broke off, so the balances may be stale');

/** A fetch answering each URL per `answers` (a status, or an Error thrown), and recording what it was asked. */
function fetching(answers) {
  const asked = [];
  const fetch = async (url, init) => {
    asked.push({ url, body: init.body });
    const answer = answers[url];
    if (answer instanceof Error) throw answer;
    return { status: answer };
  };
  return { asked, fetch };
}

test('an RPC that answers leaves the failure as it was', async () => {
  const { asked, fetch } = fetching({ [RPC]: 200 });
  assert.equal(await syncFailure(cause, { ...urls, fetch }), cause);
  assert.deepEqual(
    asked.map(({ url, body }) => [url, JSON.parse(body).method]),
    [[RPC, 'eth_blockNumber']],
  );
});

test('an RPC that turns requests away is the failure, whatever else answers', async () => {
  for (const limited of [403, 429]) {
    const { asked, fetch } = fetching({ [RPC]: limited, [POI]: new TypeError('Failed to fetch') });
    const failure = await syncFailure(cause, { ...urls, fetch });
    assert.equal(errorCode(failure), 'RPC_FAILED');
    assert.equal(failure.message, `the Ethereum RPC answers ${limited}: ${cause.message}`);
    assert.equal(asked.length, 1, 'no screening node is asked');
  }
});

test('an RPC that does not answer is the failure only while a screening node does', async () => {
  const silent = new TypeError('Failed to fetch');
  const { fetch } = fetching({ [RPC]: silent, [POI]: 404 });
  const failure = await syncFailure(cause, { ...urls, fetch });
  assert.equal(errorCode(failure), 'RPC_FAILED');
  assert.equal(failure.message, `the Ethereum RPC does not answer: ${cause.message}`);
  assert.ok(!failure.message.includes('alchemy'), 'the keyed URL stays out of it');

  const down = fetching({ [RPC]: silent, [POI]: silent });
  assert.equal(await syncFailure(cause, { ...urls, fetch: down.fetch }), cause);
  const unanswered = fetching({ [RPC]: 502, [POI]: silent });
  assert.equal(await syncFailure(cause, { ...urls, fetch: unanswered.fetch }), cause);
});

test('nothing to compare against blames nothing', async () => {
  const { fetch } = fetching({ [RPC]: new TypeError('Failed to fetch') });
  assert.equal(await syncFailure(cause, { rpcUrls: [RPC], fetch }), cause);
  assert.equal(await syncFailure(cause, { rpcUrls: [], poiNodeUrls: [POI], fetch }), cause);
});

test('a probe that hangs counts as no answer', async () => {
  const hanging = (_url, init) =>
    new Promise((_resolve, reject) => {
      init.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
    });
  assert.equal(await syncFailure(cause, { ...urls, fetch: hanging, timeoutMs: 20 }), cause);
});
