// Anon's archive records as the SDK's rail-squid formatters make them (quick-sync/V2 and railgun-txids), key order
// included, so the engine stores the same bytes whichever source fed it. Two things never come from the archive:
// - Times. The archive's are wrong in long stretches, so each record is dated from its block (`time`).
// - A commitment's railgunTxid, which rail-squid leaves to the txid sync as well: the wallet keeps the value a note had
//   when it was decrypted, before the archive's could be checked.
// A commitment's tree and index are its batch's, read through Railgun's global tree position (tree × 65,536 + index):
// the archive numbers the first leaf of mainnet's tree 1 as tree 0's leaf 65,536, the same global position.
import {
  ByteLength,
  ByteUtils,
  CommitmentType,
  Merkletree,
  RailgunTransactionVersion,
  serializePreImage,
  serializeTokenData,
} from '@railgun-community/engine';
import { getAddress } from 'ethers';

const f32 = (value, prefix) => ByteUtils.formatToByteLength(value, ByteLength.UINT_256, prefix);
const f16 = (value, prefix) => ByteUtils.formatToByteLength(value, ByteLength.UINT_128, prefix);
const strip = (text) => (text.startsWith('0x') || text.startsWith('0X') ? text.slice(2) : text);
// rail-squid hands these over as 0x-prefixed lowercase hex, which the SDK passes through.
const raw0x = (text) => `0x${strip(text).toLowerCase()}`;

// rail-squid gives a shield's fee as null before Railgun's fee upgrade and as a string ("0" included) after; the
// archive leaves out zero and null alike. On mainnet the last null fee is at block 16,788,910.
const SHIELD_FEE_FROM_BLOCK = { 1: 16_788_911 };

// rail-squid's token sub-ID is "0x00" for an ERC20 and even-length hex otherwise; the archive's is decimal.
function subID(decimal) {
  const value = BigInt(decimal);
  if (value === 0n) return '0x00';
  const digits = value.toString(16);
  return `0x${digits.length % 2 ? `0${digits}` : digits}`;
}

const preImage = ({ npk, token, value }) =>
  serializePreImage(npk, serializeTokenData(token.tokenAddress, token.tokenType, subID(token.tokenSubID)), BigInt(value));

const ciphertext = ({ iv, tag, data }) => ({
  iv: f16(iv, false),
  tag: f16(tag, false),
  data: data.map((word) => f32(word, false)),
});

/** The leaves a tree holds: where tree 1 starts in Railgun's global tree positions. */
export const TREE_LEAVES = Merkletree.getGlobalPosition(1, 0);

/** Archive commitment `c` as rail-squid's formatter makes it, at `at` (`{tree, index}`). */
function commitment(c, time, chainId, at) {
  const common = { txid: f32(c.txid, false), timestamp: time(c.blockNumber) };
  switch (c.commitmentType) {
    case 'ShieldCommitment': {
      const fee = c.fee != null ? String(c.fee) : c.blockNumber >= (SHIELD_FEE_FROM_BLOCK[chainId] ?? Infinity) ? '0' : undefined;
      const shield = {
        ...common,
        commitmentType: CommitmentType.ShieldCommitment,
        hash: f32(c.hash, false),
        preImage: preImage(c.preImage),
        blockNumber: Number(c.blockNumber),
        encryptedBundle: c.encryptedBundle.map(raw0x),
        shieldKey: raw0x(c.shieldKey),
        fee,
        utxoTree: at.tree,
        utxoIndex: at.index,
        from: undefined,
      };
      if (fee === undefined) delete shield.fee;
      return shield;
    }
    case 'TransactCommitmentV2':
    case 'TransactCommitment':
      return {
        ...common,
        commitmentType: CommitmentType.TransactCommitmentV2,
        hash: f32(c.hash, false),
        ciphertext: {
          ciphertext: ciphertext(c.ciphertext.ciphertext),
          blindedReceiverViewingKey: f32(c.ciphertext.blindedReceiverViewingKey, false),
          blindedSenderViewingKey: f32(c.ciphertext.blindedSenderViewingKey, false),
          memo: c.ciphertext.memo,
          annotationData: raw0x(c.ciphertext.annotationData ?? ''),
        },
        blockNumber: Number(c.blockNumber),
        utxoTree: at.tree,
        utxoIndex: at.index,
        railgunTxid: undefined,
      };
    case 'LegacyGeneratedCommitment':
      return {
        ...common,
        commitmentType: CommitmentType.LegacyGeneratedCommitment,
        hash: f32(c.hash, false),
        preImage: preImage(c.preImage),
        encryptedRandom: [f32(c.encryptedRandom[0], false), f16(c.encryptedRandom[1], false)],
        blockNumber: Number(c.blockNumber),
        utxoTree: at.tree,
        utxoIndex: at.index,
      };
    case 'LegacyEncryptedCommitment':
      return {
        ...common,
        commitmentType: CommitmentType.LegacyEncryptedCommitment,
        hash: f32(c.hash, false),
        ciphertext: {
          ciphertext: ciphertext(c.ciphertext.ciphertext),
          ephemeralKeys: c.ciphertext.ephemeralKeys.map((key) => f32(key, false)),
          memo: c.ciphertext.memo.map((word) => f32(word, false)),
        },
        blockNumber: Number(c.blockNumber),
        utxoTree: at.tree,
        utxoIndex: at.index,
        railgunTxid: undefined,
      };
    default:
      throw new Error(`unknown archive commitment type ${c.commitmentType}`);
  }
}

/**
 * A chunk's commitment batches from `since` on, as the engine's commitment listener takes them, each at its global tree
 * position's tree and index.
 */
export function commitmentBatches(batches, { since, time, chainId }) {
  return batches
    .filter(({ blockNumber }) => blockNumber >= since)
    .map((b) => {
      const { tree, index } = Merkletree.getTreeAndIndexFromGlobalPosition(Merkletree.getGlobalPosition(b.treeNumber, b.startPosition));
      return {
        txid: f32(b.txid, false),
        commitments: b.commitments.map((c, i) => commitment(c, time, chainId, { tree, index: index + i })),
        treeNumber: tree,
        startPosition: index,
        blockNumber: b.blockNumber,
      };
    })
    .sort((a, b) => a.treeNumber - b.treeNumber || a.startPosition - b.startPosition);
}

// rail-squid's transaction id is three 32-byte words: the block, an index the archive doesn't carry, and a sub-index.
// An archive transaction gets (block, ff…ff, sequence): ordered by block like rail-squid's, and, as a cursor, past every
// rail-squid id of its block.
const FF = 'f'.repeat(64);
const word = (value) => BigInt(value).toString(16).padStart(64, '0');
export const archiveGraphID = (blockNumber, sequence) => `0x${word(blockNumber)}${FF}${word(sequence)}`;
export const sequenceOf = (graphID) =>
  typeof graphID === 'string' && graphID.length === 194 && graphID.slice(66, 130) === FF
    ? Number(BigInt(`0x${graphID.slice(130)}`))
    : undefined;
export const blockOf = (graphID) =>
  typeof graphID === 'string' && graphID.length === 194 ? Number(BigInt(`0x${graphID.slice(2, 66)}`)) : undefined;
/** A rail-squid cursor just before every transaction of `blockNumber`. */
export const beforeBlock = (blockNumber) => `0x${word(blockNumber - 1)}${FF}${FF}`;

/** The archive's railgunTxid of a transaction it gave, which the txid sync hashes its leaf from (archive-txids.js). */
export const ARCHIVE_RAILGUN_TXID = Symbol('the archive railgunTxid');

/** An archive transaction as the SDK's txid formatter makes rail-squid's, with the archive's railgunTxid beside it. */
export function transaction(t, time) {
  const tx = {
    version: RailgunTransactionVersion.V2,
    graphID: archiveGraphID(t.blockNumber, t.sequence),
    commitments: t.commitments.map((c) => f32(c, true)),
    nullifiers: t.nullifiers.map((n) => f32(n, true)),
    boundParamsHash: f32(t.boundParamsHash, true),
    blockNumber: Number(t.blockNumber),
    timestamp: time(t.blockNumber),
    utxoTreeIn: Number(t.utxoTreeIn),
    utxoTreeOut: Number(t.utxoTreeOut),
    utxoBatchStartPositionOut: Number(t.utxoBatchStartPositionOut),
    txid: f32(t.txid, false),
    unshield: t.unshield
      ? {
          tokenData: {
            tokenType: t.unshield.tokenData.tokenType,
            tokenAddress: getAddress(t.unshield.tokenData.tokenAddress),
            tokenSubID: subID(t.unshield.tokenData.tokenSubID),
          },
          toAddress: t.unshield.toAddress.toLowerCase(),
          value: t.unshield.value,
        }
      : undefined,
    verificationHash: f32(t.verificationHash, true),
  };
  // Not enumerable: the engine spreads the transaction into what it stores.
  if (t.railgunTxid) Object.defineProperty(tx, ARCHIVE_RAILGUN_TXID, { value: f32(t.railgunTxid, false) });
  return tx;
}
