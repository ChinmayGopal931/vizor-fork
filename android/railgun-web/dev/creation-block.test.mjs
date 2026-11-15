import assert from 'node:assert/strict';
import { test } from 'node:test';
import { NetworkName } from '@railgun-community/shared-models';
import { blockAtOrBefore, mainnetBlockAtOrBefore, mainnetBlockTime } from '../src/block-times.js';
import { START, STEP, TIMES } from '../src/block-times-mainnet.js';
import { CREATION_MARGIN_S, creationBlock } from '../src/creation-block.js';
import { installQuickSync } from '../src/quick-sync.js';
import { CHAIN, V2, wholeEngine } from './engine-harness.mjs';
import { history, indexer } from './history-fixture.mjs';
import { transfer, walletOn, withNotes } from './notes-fixture.mjs';

const table = { start: 1_000, step: 1_000, times: [10_000, 22_000, 36_000] };

test('the block made by a time is the newest entry no later than it, and never past the table', () => {
  assert.equal(blockAtOrBefore(table, 10_000), 1_000);
  assert.equal(blockAtOrBefore(table, 21_999), 1_000);
  assert.equal(blockAtOrBefore(table, 22_000), 2_000);
  assert.equal(blockAtOrBefore(table, 35_999), 2_000);
  assert.equal(blockAtOrBefore(table, 36_000), 3_000);
  assert.equal(blockAtOrBefore(table, 1e12), 3_000, 'past the table, its last entry: no block counted from the clock');
  assert.equal(blockAtOrBefore(table, 9_999), undefined, 'before the table');
  assert.equal(blockAtOrBefore(table, Number.NaN), undefined);
  assert.equal(blockAtOrBefore({ ...table, times: [] }, 20_000), undefined);
});

test("the shipped table's block for a time was made by then", () => {
  for (let i = 0; i < TIMES.length; i += 97) {
    assert.equal(mainnetBlockAtOrBefore(TIMES[i]), START + i * STEP);
    assert.equal(mainnetBlockAtOrBefore(TIMES[i] - 1), i === 0 ? undefined : START + (i - 1) * STEP);
  }
});

test('a mainnet wallet decrypts from the newest table block at least a day before its seed was made', () => {
  const createdAt = TIMES[500] + 3_600;
  const block = creationBlock(NetworkName.Ethereum, createdAt);
  assert.ok(mainnetBlockTime(block) <= createdAt - CREATION_MARGIN_S);
  assert.ok(mainnetBlockTime(block + STEP) > createdAt - CREATION_MARGIN_S);
});

test('a seed made past the table decrypts from its last entry', () => {
  const end = START + (TIMES.length - 1) * STEP;
  assert.equal(creationBlock(NetworkName.Ethereum, TIMES.at(-1) + 365 * 24 * 3_600), end);
});

test('without a time, or off mainnet, a wallet decrypts every leaf', () => {
  for (const createdAt of [undefined, null, 0, -5, 1.5, '1700000000', Number.NaN]) {
    assert.equal(creationBlock(NetworkName.Ethereum, createdAt), undefined, String(createdAt));
  }
  assert.equal(creationBlock(NetworkName.EthereumSepolia, TIMES[500]), undefined);
  assert.equal(creationBlock(undefined, TIMES[500]), undefined);
});

const PAGE = 40;
const pages = { pageSize: PAGE, gapMs: 0, retryMs: 0 };
const fixture = history();
const at = (offset) =>
  fixture.squid.commitments.find(({ blockNumber }) => Number(blockNumber) >= fixture.from + offset).treePosition;

/** A whole engine whose contract accepts every root and records the stretches of logs a scan asks for. */
async function recordedEngine() {
  const logs = [];
  const built = await wholeEngine({
    contract: {
      contract: { runner: { provider: { getBlockNumber: async () => fixture.to } } },
      validateMerkleroot: async () => true,
      getHistoricalEvents: async (from, to, _next, _commitments, _nullifiers, _unshields, synced) => {
        logs.push([from, to]);
        await synced(to);
      },
    },
    deploymentBlock: fixture.from,
  });
  return { ...built, logs };
}

test('a creation block changes only what a wallet decrypts: the requests and the trees are the same', async () => {
  const keys = await recordedEngine();
  const sender = await walletOn(keys.engine, CHAIN, 'sender');
  const receiver = await walletOn(keys.engine, CHAIN, 'receiver');
  const lists = withNotes(
    fixture,
    [at(10), at(100)],
    [await transfer(sender, receiver, 1_000n), await transfer(sender, receiver, 2_000n)],
  ).squid;

  const sync = async (creation) => {
    const built = await recordedEngine();
    const squid = indexer(lists, PAGE);
    installQuickSync(built.engine, { queries: squid.queries, head: async () => fixture.to, pages });
    const wallet = await walletOn(built.engine, CHAIN, 'receiver', creation);
    await built.engine.scanUTXOHistory(V2, CHAIN, [wallet.id]);
    const values = (await wallet.TXOs(V2, CHAIN)).map(({ note }) => note.value).sort();
    const details = await wallet.getWalletDetails(V2, CHAIN);
    return { asked: squid.asked, logs: built.logs, root: await built.utxo.getRoot(0), values, details };
  };
  const whole = await sync(undefined);
  const floored = await sync(fixture.from + 50);

  assert.deepEqual(whole.values, [1_000n, 2_000n]);
  assert.deepEqual(floored.values, [2_000n], 'the note from before the creation block is never decrypted');
  assert.equal(whole.details.creationTree, undefined);
  assert.equal(floored.details.creationTree, 0);
  assert.ok(floored.details.creationTreeHeight > at(10) && floored.details.creationTreeHeight <= at(100));
  assert.deepEqual(floored.asked, whole.asked, 'rail-squid hears the same requests');
  assert.deepEqual(floored.logs, whole.logs, 'the RPC hears the same requests');
  assert.equal(floored.root, whole.root, 'the trees are the same');
});
