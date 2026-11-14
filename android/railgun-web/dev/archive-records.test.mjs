import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import { test } from 'node:test';
import { commitmentBatches, transaction, unshieldEvents } from '../src/archive-records.js';
import { formatCommitments, formatUnshields } from '../src/quick-sync.js';
import { blockTime, history, word } from './history-fixture.mjs';

const require = createRequire(import.meta.url);
const SDK = path.join(path.dirname(require.resolve('@railgun-community/wallet')), 'services/railgun');
const { formatRailgunTransactions } = require(path.join(SDK, 'railgun-txids/railgun-txid-graph-type-formatters'));

const fixture = history({ blocks: 40 });
const options = { since: fixture.from, time: blockTime, chainId: 1 };
const TOKEN = `0x${word('token', 20)}`;

test("archive commitments come out as rail-squid's do, key order and all, dated from their blocks", () => {
  const ours = commitmentBatches(fixture.archive.commitments, options);
  const squid = formatCommitments(fixture.squid.commitments);
  assert.deepEqual(ours, squid);
  assert.equal(JSON.stringify(ours), JSON.stringify(squid));
});

test("archive unshields come out as rail-squid's do", () => {
  const ours = unshieldEvents(fixture.archive.unshields, options);
  assert.equal(JSON.stringify(ours), JSON.stringify(formatUnshields(fixture.squid.unshields)));
});

test('records from before the sync starts are left out, and so are unshields without an event index', () => {
  const since = fixture.from + 20;
  assert.ok(commitmentBatches(fixture.archive.commitments, { ...options, since }).every(({ blockNumber }) => blockNumber >= since));
  const preV2 = { ...fixture.archive.unshields[0], eventLogIndex: null };
  assert.deepEqual(unshieldEvents([preV2], options), []);
});

/** A shield commitment as rail-squid lists it and as the archive records it, with `fee` as each gives it. */
function shield(block, { squidFee, archiveFee }) {
  const common = { treeNumber: 0, blockNumber: block, utxoIndex: 7 };
  const preimage = { npk: word('npk'), value: '1000', token: { tokenType: 'ERC20', tokenSubID: '0x00', tokenAddress: TOKEN } };
  return {
    squid: {
      id: 'c-7',
      treeNumber: 0,
      batchStartTreePosition: 7,
      treePosition: 7,
      blockNumber: String(block),
      transactionHash: word('shield-tx'),
      blockTimestamp: String(blockTime(block)),
      commitmentType: 'ShieldCommitment',
      hash: BigInt(`0x${word('shield', 31)}`).toString(),
      preimage,
      encryptedBundle: [`0x${word('e0')}`, `0x${word('e1')}`, `0x${word('e2')}`],
      shieldKey: `0x${word('key')}`,
      fee: squidFee,
    },
    archive: {
      txid: word('shield-tx'),
      treeNumber: 0,
      startPosition: 7,
      blockNumber: block,
      commitments: [
        {
          ...common,
          commitmentType: 'ShieldCommitment',
          txid: word('shield-tx'),
          timestamp: 1,
          hash: word('shield', 31),
          utxoTree: 0,
          preImage: { npk: word('npk'), value: '1000', token: { tokenType: 0, tokenSubID: '0', tokenAddress: TOKEN } },
          encryptedBundle: [word('e0'), word('e1'), word('e2')],
          shieldKey: word('key'),
          ...(archiveFee === undefined ? {} : { fee: archiveFee }),
          from: null,
        },
      ],
    },
  };
}

test("a shield's fee comes out as rail-squid's: none before Railgun's fee upgrade, and zero after it as \"0\"", () => {
  for (const [block, squidFee, archiveFee] of [
    [16_788_910, null, undefined],
    [16_790_865, '0', undefined],
    [16_790_865, '25', '25'],
  ]) {
    const { squid, archive } = shield(block, { squidFee, archiveFee });
    assert.equal(
      JSON.stringify(commitmentBatches([archive], { ...options, since: 0 })),
      JSON.stringify(formatCommitments([squid])),
      `block ${block}, fee ${squidFee}`,
    );
  }
});

test("a legacy commitment from before V2 comes out as rail-squid's", () => {
  const block = 14_800_000;
  const squid = {
    id: 'c-0',
    treeNumber: 0,
    batchStartTreePosition: 0,
    treePosition: 0,
    blockNumber: String(block),
    transactionHash: word('legacy-tx'),
    blockTimestamp: String(blockTime(block)),
    commitmentType: 'LegacyEncryptedCommitment',
    hash: BigInt(`0x${word('legacy', 31)}`).toString(),
    legacyCiphertext: {
      ciphertext: { iv: word('liv', 16), tag: word('ltag', 16), data: [word('l0'), word('l1')] },
      ephemeralKeys: [word('k0'), word('k1')],
      memo: [word('m0')],
    },
  };
  const archive = {
    txid: word('legacy-tx'),
    treeNumber: 0,
    startPosition: 0,
    blockNumber: block,
    commitments: [
      {
        commitmentType: 'LegacyEncryptedCommitment',
        txid: word('legacy-tx'),
        timestamp: 1,
        hash: word('legacy', 31),
        blockNumber: block,
        utxoTree: 0,
        utxoIndex: 0,
        ciphertext: squid.legacyCiphertext,
      },
    ],
  };
  assert.equal(
    JSON.stringify(commitmentBatches([archive], { ...options, since: 0 })),
    JSON.stringify(formatCommitments([squid])),
  );
});

test("an archive transaction comes out as rail-squid's but for its id, the archive's railgunTxid kept out of sight", () => {
  const block = 16_100_000;
  const squid = {
    id: `0x${'1'.repeat(192)}`,
    nullifiers: [`0x${word('n0', 31)}`],
    commitments: [`0x${word('c0', 31)}`, `0x${word('c1', 31)}`],
    transactionHash: word('t'),
    boundParamsHash: word('bp', 31),
    blockNumber: String(block),
    utxoTreeIn: '1',
    utxoTreeOut: '1',
    utxoBatchStartPositionOut: '42',
    hasUnshield: true,
    unshieldToken: { tokenType: 'ERC20', tokenSubID: '0x00', tokenAddress: TOKEN },
    unshieldToAddress: `0x${word('to', 20)}`,
    unshieldValue: '1000',
    blockTimestamp: String(blockTime(block)),
    verificationHash: word('vh'),
  };
  const record = {
    version: 2,
    sequence: 5,
    commitments: squid.commitments,
    nullifiers: squid.nullifiers,
    boundParamsHash: squid.boundParamsHash,
    blockNumber: block,
    txid: squid.transactionHash,
    utxoTreeIn: 1,
    utxoTreeOut: 1,
    utxoBatchStartPositionOut: 42,
    timestamp: 1,
    verificationHash: squid.verificationHash,
    railgunTxid: word('rt'),
    unshield: { tokenData: { tokenType: 0, tokenAddress: TOKEN, tokenSubID: '0' }, toAddress: squid.unshieldToAddress, value: '1000' },
  };
  const ours = transaction(record, blockTime);
  const [theirs] = formatRailgunTransactions([squid]);
  assert.equal(JSON.stringify({ ...ours, graphID: theirs.graphID }), JSON.stringify(theirs));
  assert.equal(JSON.stringify(ours).includes(word('rt')), false);
});
