// A made-up stretch of Railgun's V2 history with its transaction list, the notes stores the engine's quick sync leaves
// for it, and a run of the engine's V2 txid sync over them: the txid sync tests' common ground.
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import path from 'node:path';
import { RailgunTransactionVersion } from '@railgun-community/engine';
import { formatCommitments, formatUnshields } from '../src/quick-sync.js';
import { CHAIN, ENGINE, TXIDMerkletree, V2, engineHarness } from './engine-harness.mjs';

const require = createRequire(import.meta.url);
export const { calculateRailgunTransactionVerificationHash } = require(path.join(ENGINE, 'transaction/railgun-txid'));

export const word = (seed, bytes = 32) =>
  createHash('sha256')
    .update(String(seed))
    .digest('hex')
    .slice(0, bytes * 2);
export const hex32 = (value) => `0x${BigInt(value).toString(16).padStart(64, '0')}`;

/**
 * Railgun V2 history from block `from`, as rail-squid lists it, and the transactions of Railgun's txid list for it:
 * one per commitment batch, the first batch of a block that unshields carrying that unshield as its last commitment.
 */
export function history({ from = 16_100_000, blocks = 60 } = {}) {
  const commitments = [];
  const unshields = [];
  const batches = [];
  let position = 0;
  for (let block = from; block < from + blocks; block += 1) {
    if (block % 5 === 0) {
      unshields.push({
        id: `u-${block}`,
        blockNumber: String(block),
        to: `0x${word(`to-${block}`, 20)}`,
        transactionHash: word(`tx-${block}-0`),
        fee: '25',
        blockTimestamp: String(1_670_000_000 + block * 12),
        amount: String(10_000 + block),
        eventLogIndex: block % 7,
        token: { id: 't', tokenType: 'ERC20', tokenSubID: '0x00', tokenAddress: `0x${word('token', 20)}` },
      });
    }
    for (let batch = 0; batch < 1 + (block % 3); batch += 1) {
      const transactionHash = word(`tx-${block}-${batch}`);
      const start = position;
      const hashes = [];
      for (let i = 0; i < 1 + ((block + batch) % 3); i += 1) {
        const hash = BigInt(`0x${word(`leaf-${position}`, 31)}`).toString();
        hashes.push(hash);
        commitments.push({
          id: `c-${position}`,
          treeNumber: 0,
          batchStartTreePosition: start,
          treePosition: position,
          blockNumber: String(block),
          transactionHash,
          blockTimestamp: String(1_670_000_000 + block * 12),
          commitmentType: 'TransactCommitment',
          hash,
          ciphertext: {
            ciphertext: {
              iv: word(`iv-${position}`, 16),
              tag: word(`tag-${position}`, 16),
              data: [word(`d0-${position}`)],
            },
            blindedReceiverViewingKey: word(`r-${position}`),
            blindedSenderViewingKey: word(`s-${position}`),
            memo: '0x',
            annotationData: `0x${word(`a-${position}`, 8)}`,
          },
        });
        position += 1;
      }
      batches.push({ block, batch, transactionHash, start, hashes });
    }
  }
  const stored = formatUnshields(unshields);
  const transactions = [];
  let previous;
  for (const { block, batch, transactionHash, start, hashes } of batches) {
    const nullifiers = [hex32(`0x${word(`nullifier-${start}`, 31)}`)];
    const event = batch === 0 ? stored.find(({ txid }) => txid.endsWith(transactionHash)) : undefined;
    const verificationHash = calculateRailgunTransactionVerificationHash(previous, nullifiers[0]);
    previous = verificationHash;
    transactions.push({
      version: RailgunTransactionVersion.V2,
      graphID: `0x${word(`g-${start}`)}`,
      commitments: hashes.map(hex32),
      nullifiers,
      boundParamsHash: hex32(`0x${word(`bp-${start}`, 31)}`),
      blockNumber: block,
      timestamp: 1_670_000_000 + block * 12,
      txid: transactionHash,
      utxoTreeIn: 0,
      utxoTreeOut: 0,
      utxoBatchStartPositionOut: start,
      unshield: event && {
        tokenData: { tokenType: event.tokenType, tokenAddress: event.tokenAddress, tokenSubID: event.tokenSubID },
        toAddress: event.toAddress,
        value: (BigInt(event.amount) + BigInt(event.fee)).toString(),
      },
      verificationHash,
    });
  }
  return { commitments, unshields, transactions };
}

/** A store holding `lists`' notes as the engine's quick sync stores them, with no railgunTxid on any record. */
export async function notesStored(lists) {
  const harness = await engineHarness();
  await harness.engine.unshieldListener(V2, CHAIN, formatUnshields(lists.unshields));
  await harness.engine.commitmentListener(V2, CHAIN, formatCommitments(lists.commitments), false, false);
  await harness.merkletree.updateTreesFromWriteQueue(true);
  return harness;
}

/**
 * Runs the engine's V2 txid sync (`handler`) over `transactions` on `harness`'s store, counting its writes, the
 * screening node accepting the roots `accepted` lets through. `verificationHash` is the stored list's last, which a
 * sync that goes on from it continues.
 */
export async function txidSync(
  handler,
  harness,
  transactions,
  { accepted = () => true, txidMerkletree, verificationHash } = {},
) {
  txidMerkletree ??= await TXIDMerkletree.createForWallet(harness.db, CHAIN, V2, async (...args) => accepted(...args));
  const counted = { puts: 0, batches: 0, invalidations: 0 };
  const { db } = harness;
  const put = db.put.bind(db);
  const batch = db.batch.bind(db);
  db.put = (...args) => {
    counted.puts += 1;
    return put(...args);
  };
  db.batch = (...args) => {
    counted.batches += 1;
    return batch(...args);
  };
  const engine = {
    isPOINode: false,
    getUTXOMerkletree: () => harness.merkletree,
    getTXIDMerkletree: () => txidMerkletree,
    getLatestValidatedTxidIndex: async () => undefined,
    shouldAddNewRailgunTransactions: async () => true,
    emitTXIDMerkletreeScanUpdateEvent() {},
    invalidateTXOsCacheAllWallets() {
      counted.invalidations += 1;
    },
  };
  try {
    await handler.call(engine, V2, CHAIN, transactions, verificationHash, 0, 1);
  } finally {
    db.put = put;
    db.batch = batch;
  }
  return { counted, txidMerkletree };
}
