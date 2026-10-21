// The repair against fixture.json: the squid's #4180 to #4199 as the SDK selects them, and the hashes the wallet's
// engine expects from #4188 on (record-fixture.mjs).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils.js';
import { BREAK_ID, CHAIN_LIMIT, PREDECESSOR, chainAnswer, chainRequest, queryShape, repair } from '../repair.js';

const fixture = JSON.parse(readFileSync(new URL('fixture.json', import.meta.url), 'utf8'));
const { transactions, repaired } = fixture;
const at = (index) => transactions[index - fixture.first];
const range = (from, to) => transactions.slice(from - fixture.first, to - fixture.first + 1);
/** The fixture with the transaction `id` changed by `change`. */
const changed = (id, change) => transactions.map((t) => (t.id === id ? { ...t, ...change } : t));

// The SDK's three queries of the list, as its client sends them.
const SELECTION = `{
    id
    nullifiers
    commitments
    transactionHash
    boundParamsHash
    blockNumber
    utxoTreeIn
    utxoTreeOut
    utxoBatchStartPositionOut
    hasUnshield
    unshieldToken {
      tokenType
      tokenSubID
      tokenAddress
    }
    unshieldToAddress
    unshieldValue
    blockTimestamp
    verificationHash
  }`;
const AFTER_GRAPH_ID = `query GetRailgunTransactionsAfterGraphID($idLow: String = "0x00") {
  transactions(orderBy: id_ASC, limit: 10000, where: {id_gt: $idLow}) ${SELECTION}
}`;
const BY_TXID = `query GetRailgunTransactionsByTxid($txid: Bytes) {
  transactions(where: {transactionHash_eq: $txid}) ${SELECTION}
}`;
const BY_UNSHIELD_TO_ADDRESS = `query GetRailgunTransactionsByUnshieldToAddress($address: Bytes) {
  transactions(
    orderBy: id_ASC
    limit: 10000
    where: {unshieldToAddress_eq: $address}
  ) ${SELECTION}
}`;
const PAGE = queryShape(AFTER_GRAPH_ID);
const BY_HASH = queryShape(BY_TXID);
const BY_ADDRESS = queryShape(BY_UNSHIELD_TO_ADDRESS);

const encoder = new TextEncoder();
const decoder = new TextDecoder();
/** The squid's answer to a `transactions` query, byte for byte: compact JSON and a newline. */
const answer = (list) => encoder.encode(`${JSON.stringify({ data: { transactions: list } })}\n`);
const listOf = (body) => JSON.parse(decoder.decode(body)).data.transactions;

/** The extra query, answered from `list` as the squid would, with the calls it got. */
function squid({ list = transactions, predecessor = PREDECESSOR.verificationHash } = {}) {
  const calls = [];
  const fetchChain = async (bound) => {
    calls.push(bound);
    const rows = list
      .filter(({ id }) => id > PREDECESSOR.id && (bound.before === undefined ? id <= bound.through : id < bound.before))
      .map(({ id, nullifiers }) => ({ id, nullifiers }));
    return { predecessor, rows };
  };
  return { calls, fetchChain };
}

const noQuery = async () => assert.fail('no extra query expected');

/** The repaired answer differs from the squid's in the hashes from the break on, and only there. */
function assertRepaired(input, output) {
  const before = listOf(input);
  const after = listOf(output);
  assert.equal(after.length, before.length);
  let text = decoder.decode(output);
  for (const [i, transaction] of after.entries()) {
    const { verificationHash, ...rest } = before[i];
    const { verificationHash: hash, ...others } = transaction;
    assert.deepEqual(others, rest);
    assert.equal(hash, repaired[transaction.id] ?? verificationHash, `#${transaction.id.slice(0, 70)}`);
    text = text.replace(hash, verificationHash);
  }
  assert.equal(text, decoder.decode(input));
}

const outcome = async (body, shape, fetchChain = noQuery) => (await repair(body, shape, fetchChain)).outcome;

test('the fixture holds the break, and the pins name it', () => {
  assert.equal(at(4187).id, PREDECESSOR.id);
  assert.equal(at(4187).verificationHash, PREDECESSOR.verificationHash);
  assert.equal(at(4188).id, BREAK_ID);
  assert.equal(Object.keys(repaired).length, 12);
  assert.notEqual(at(4188).verificationHash, repaired[BREAK_ID]);
});

test("the SDK's queries of the list, and what else comes through", () => {
  assert.deepEqual(PAGE, { sorted: true, page: true });
  assert.deepEqual(BY_HASH, { sorted: false, page: false });
  assert.deepEqual(BY_ADDRESS, { sorted: true, page: false });
  // The replay script's own page.
  const replay = 'query($idLow: String) { transactions(orderBy: id_ASC, limit: 1000, where: {id_gt: $idLow}) {';
  assert.deepEqual(queryShape(`${replay} id verificationHash } }`), { sorted: true, page: true });
  // The quick sync's events carry no verificationHash.
  assert.equal(queryShape('query Nullifiers($blockNumber: BigInt = 0) { nullifiers { id nullifier } }'), undefined);
  for (const query of [
    '{ verificationHashes { id verificationHash } }',
    '{ txs: transactions(orderBy: id_ASC) { id verificationHash } }',
    '{ transactions(limit: 1) { id verificationHash } other: transactions(limit: 2) { id verificationHash } }',
    '{ transactionById(id: "0x") { id verificationHash } }',
  ]) {
    assert.deepEqual(queryShape(query), { unknown: true }, query);
  }
  // A page needs id_gt alone: anything more filters it.
  const filtered = '{ transactions(orderBy: id_ASC, limit: 10, where: {id_gt: "0x", hasUnshield_eq: true}) {';
  assert.equal(queryShape(`${filtered} verificationHash } }`).page, false);
});

test('a page that holds the predecessor is repaired from itself', async () => {
  const input = answer(transactions);
  const { body, outcome: done } = await repair(input, PAGE, noQuery);
  assert.equal(done, 'repaired 12');
  assertRepaired(input, body);
  // The chain the engine checks holds end to end: hash[n] = keccak256(hash[n-1] || firstNullifier[n]).
  const list = listOf(body);
  for (let i = 1; i < list.length; i += 1) {
    const joined = new Uint8Array([
      ...hexToBytes(list[i - 1].verificationHash.slice(2)),
      ...hexToBytes(list[i].nullifiers[0].slice(2)),
    ]);
    assert.equal(list[i].verificationHash, `0x${bytesToHex(keccak_256(joined))}`);
  }
});

test('a long page is read from its end, as far back as the break needs', async () => {
  const input = answer(transactions);
  const whole = await repair(input, PAGE, noQuery);
  for (const window of [64, 1500, 9000]) {
    const { body, outcome: done } = await repair(input, PAGE, noQuery, { window });
    assert.equal(done, 'repaired 12');
    assert.deepEqual(body, whole.body, `window ${window}`);
  }
  // Parsed whole, as an unsorted list is, it comes out the same.
  const { body } = await repair(input, BY_HASH, squid().fetchChain);
  assert.deepEqual(body, whole.body);
});

test('a page that starts after the break asks for the chain up to its first transaction', async () => {
  const input = answer(range(4192, 4199));
  const { calls, fetchChain } = squid();
  const { body, outcome: done } = await repair(input, PAGE, fetchChain);
  assert.equal(done, 'repaired 8');
  assert.deepEqual(calls, [{ before: at(4192).id }]);
  assertRepaired(input, body);
});

test('a page that starts at the break asks for the predecessor alone', async () => {
  const input = answer(range(4188, 4199));
  const { calls, fetchChain } = squid();
  const { body, outcome: done } = await repair(input, PAGE, fetchChain);
  assert.equal(done, 'repaired 12');
  assert.deepEqual(calls, [{ before: BREAK_ID }]);
  assertRepaired(input, body);
});

test('a transaction found by its hash, or a list with gaps, asks for the chain through its last', async () => {
  const one = answer([at(4190)]);
  const byHash = squid();
  const found = await repair(one, BY_HASH, byHash.fetchChain);
  assert.equal(found.outcome, 'repaired 1');
  assert.deepEqual(byHash.calls, [{ through: at(4190).id }]);
  assertRepaired(one, found.body);

  const gaps = answer([4181, 4185, 4189, 4195].map(at));
  const byAddress = squid();
  const filtered = await repair(gaps, BY_ADDRESS, byAddress.fetchChain);
  assert.equal(filtered.outcome, 'repaired 2');
  assert.deepEqual(byAddress.calls, [{ through: at(4195).id }]);
  assertRepaired(gaps, filtered.body);
});

test('a list without its nullifiers takes them all from the extra query', async () => {
  const bare = (list) => list.map(({ nullifiers, ...transaction }) => transaction);
  for (const [list, shape, done] of [
    [transactions, PAGE, 'repaired 12'],
    [[at(4190)], BY_HASH, 'repaired 1'],
  ]) {
    const input = answer(bare(list));
    const { calls, fetchChain } = squid();
    const { body, outcome: outcomeOf } = await repair(input, shape, fetchChain);
    assert.equal(outcomeOf, done);
    assert.deepEqual(calls, [{ through: list.at(-1).id }]);
    assertRepaired(input, body);
  }
});

test('a list before the break is passed on as it came, with no query', async () => {
  for (const list of [range(4180, 4187), [], [at(4181)]]) {
    const input = answer(list);
    for (const shape of [PAGE, BY_HASH, BY_ADDRESS]) {
      const { body, outcome: done } = await repair(input, shape, noQuery);
      assert.equal(done, 'nothing to repair');
      assert.equal(body, input);
    }
  }
  const failed = encoder.encode('{"errors":[{"message":"no"}],"data":null}\n');
  assert.equal(await outcome(failed, PAGE), 'nothing to repair');
});

test('a list whose chain is already right is left alone', async () => {
  const fixed = transactions.map((t) => ({ ...t, verificationHash: repaired[t.id] ?? t.verificationHash }));
  const input = answer(fixed);
  const { body, outcome: done } = await repair(input, PAGE, noQuery);
  assert.equal(done, 'intact');
  assert.equal(body, input);
  assert.equal(await outcome(answer(fixed.slice(10)), PAGE, squid({ list: fixed }).fetchChain), 'intact');
});

test('anything unexpected about the chain before the break passes the list on unrepaired, saying why', async () => {
  const past = answer(range(4192, 4199));
  // A transaction between the predecessor and the break.
  const between = { ...at(4180), id: `${PREDECESSOR.id.slice(0, -1)}1` };
  const offline = async () => {
    throw new Error('offline');
  };
  const cutShort = async () => ({ predecessor: PREDECESSOR.verificationHash, rows: Array(CHAIN_LIMIT).fill(at(4188)) });
  const aliased = queryShape('{ txs: transactions(orderBy: id_ASC) { id verificationHash } }');
  const cases = [
    ['predecessor changed', answer(changed(PREDECESSOR.id, { verificationHash: repaired[BREAK_ID] })), PAGE],
    ['predecessor changed', past, PAGE, squid({ predecessor: repaired[BREAK_ID] }).fetchChain],
    ['predecessor changed', past, PAGE, squid({ predecessor: null }).fetchChain],
    // A page whose transaction before the break is another.
    ['predecessor changed', answer(transactions.filter(({ id }) => id !== PREDECESSOR.id)), PAGE],
    ['break moved', past, PAGE, squid({ list: [between, ...transactions] }).fetchChain],
    ['list unavailable', past, PAGE, offline],
    ['list incomplete', past, PAGE, cutShort],
    ['list incomplete', answer([at(4195)]), BY_HASH, squid({ list: range(4180, 4194) }).fetchChain],
    ['list changed', answer([{ ...at(4195), nullifiers: at(4194).nullifiers }]), BY_HASH, squid().fetchChain],
    ['out of order', answer([...range(4180, 4190), at(4192), at(4191)]), PAGE],
    ['unexpected response', answer(changed(BREAK_ID, { nullifiers: ['0xzz'] })), PAGE],
    ['unexpected response', answer(changed(BREAK_ID, { verificationHash: '0x39dc' })), PAGE],
    ['unknown query', answer(transactions), aliased],
  ];
  for (const [reason, input, shape, fetchChain = noQuery] of cases) {
    const { body, outcome: done } = await repair(input, shape, fetchChain);
    assert.equal(done, `unrepaired: ${reason}`);
    assert.equal(body, input);
  }
});

test('the extra query asks for the predecessor and the first nullifiers after it, and nothing else', () => {
  const page = chainRequest({ before: at(4192).id });
  assert.deepEqual(page.variables, { predecessor: PREDECESSOR.id, bound: at(4192).id });
  assert.match(page.query, /predecessor: transactionById\(id: \$predecessor\) \{ verificationHash \}/);
  assert.match(page.query, /where: \{id_gt: \$predecessor, id_lt: \$bound\}\) \{\s+id nullifiers\s+\}/);
  const through = chainRequest({ through: at(4195).id });
  assert.deepEqual(through.variables, { predecessor: PREDECESSOR.id, bound: at(4195).id });
  assert.match(through.query, /id_lte: \$bound/);

  const rows = [{ id: BREAK_ID, nullifiers: at(4188).nullifiers }];
  const predecessor = { verificationHash: PREDECESSOR.verificationHash };
  const answered = chainAnswer({ data: { predecessor, chain: rows } });
  assert.deepEqual(answered, { predecessor: predecessor.verificationHash, rows });
  assert.equal(chainAnswer({ data: { predecessor: null, chain: [] } }).predecessor, undefined);
  assert.throws(() => chainAnswer({ errors: [{ message: 'no' }], data: null }));
  assert.throws(() => chainAnswer({ data: { predecessor: null } }));
});
