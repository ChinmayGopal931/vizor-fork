// A made-up stretch of Railgun's history, as rail-squid lists it and as Anon's archive publishes it, and an archive
// server over it: the files gzipped and checksummed as the archive's are, which tests can tamper with, drop or move.
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import path from 'node:path';
import { gzipSync } from 'node:zlib';
import { ENGINE } from './engine-harness.mjs';

const require = createRequire(import.meta.url);
const { poseidonHex } = require(path.join(ENGINE, 'utils/poseidon'));
const { MERKLE_ZERO_VALUE } = require(path.join(ENGINE, 'models/merkletree-types'));

export const word = (seed, bytes = 32) => createHash('sha256').update(String(seed)).digest('hex').slice(0, bytes * 2);
/** The time the fixture's rail-squid gives a block; tests date archive records the same way. */
export const blockTime = (block) => 1_650_000_000 + block * 12;
const TOKEN = `0x${word('token', 20)}`;

/**
 * Blocks `from` to `from + blocks - 1`, each with a few commitment batches, nullifiers and unshields:
 * `squid` (rail-squid's raw lists) and `archive` (the archive's records, in block order).
 */
export function history({ from = 14_760_000, blocks = 120 } = {}) {
  const squid = { commitments: [], nullifiers: [], unshields: [] };
  const archive = { commitments: [], nullifiers: [], unshields: [] };
  let position = 0;
  for (let block = from; block < from + blocks; block += 1) {
    const time = blockTime(block);
    for (let batch = 0; batch < block % 4; batch += 1) {
      const txid = word(`tx-${block}-${batch}`);
      const start = position;
      const records = [];
      for (let i = 0; i < 1 + ((block + batch) % 4); i += 1) {
        const hash = word(`leaf-${position}`, 31);
        const ciphertext = {
          ciphertext: { iv: word(`iv-${position}`, 16), tag: word(`tag-${position}`, 16), data: [word(`d0-${position}`), word(`d1-${position}`)] },
          blindedReceiverViewingKey: word(`r-${position}`),
          blindedSenderViewingKey: word(`s-${position}`),
          memo: '0x',
          annotationData: `0x${word(`a-${position}`, 8)}`,
        };
        squid.commitments.push({
          id: `c-${position}`,
          treeNumber: 0,
          batchStartTreePosition: start,
          treePosition: position,
          blockNumber: String(block),
          transactionHash: txid,
          blockTimestamp: String(time),
          commitmentType: 'TransactCommitment',
          hash: BigInt(`0x${hash}`).toString(),
          ciphertext,
        });
        records.push({
          commitmentType: 'TransactCommitmentV2',
          txid,
          // The archive's times are wrong in long stretches; nothing may store them.
          timestamp: time + 3_600 * 24 * 30,
          hash,
          blockNumber: block,
          utxoTree: 0,
          utxoIndex: position,
          ciphertext,
          railgunTxid: word(`railgun-${position}`),
        });
        position += 1;
      }
      archive.commitments.push({ txid, treeNumber: 0, startPosition: start, blockNumber: block, commitments: records });
    }
    for (let i = 0; i < block % 3; i += 1) {
      const nullifier = word(`nullifier-${block}-${i}`);
      squid.nullifiers.push({ id: `n-${block}-${i}`, blockNumber: String(block), nullifier, transactionHash: word(`tx-${block}-0`), blockTimestamp: String(time), treeNumber: 0 });
      archive.nullifiers.push({ nullifier, treeNumber: 0, txid: word(`tx-${block}-0`), blockNumber: block });
    }
    if (block % 5 === 0) {
      const to = `0x${word(`to-${block}`, 20)}`;
      squid.unshields.push({
        id: `u-${block}`,
        blockNumber: String(block),
        to,
        transactionHash: word(`tx-${block}-0`),
        fee: '25',
        blockTimestamp: String(time),
        amount: String(10_000 + block),
        eventLogIndex: block % 7,
        token: { id: 't', tokenType: 'ERC20', tokenSubID: '0x00', tokenAddress: TOKEN },
      });
      archive.unshields.push({
        txid: word(`tx-${block}-0`),
        timestamp: time - 600,
        toAddress: to,
        tokenType: 0,
        tokenAddress: TOKEN,
        tokenSubID: '0',
        amount: String(10_000 + block),
        fee: '25',
        blockNumber: block,
        eventLogIndex: block % 7,
        railgunTxid: word(`railgun-u-${block}`),
        poisPerList: null,
      });
    }
  }
  return { from, to: from + blocks - 1, squid, archive, leaves: position };
}

/** rail-squid answering `pageSize` events of each list from a block on, and what it was asked. */
export function indexer(lists, pageSize) {
  const asked = [];
  const answer = (name) => async (block) => {
    asked.push([name, block]);
    return lists[name].filter(({ blockNumber }) => Number(blockNumber) >= block).slice(0, pageSize);
  };
  return { asked, queries: { nullifiers: answer('nullifiers'), unshields: answer('unshields'), commitments: answer('commitments') } };
}

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const json = (value) => Buffer.from(JSON.stringify(value));

/** The node of an empty subtree at each level, as the engine's merkletrees start. */
export const ZEROS = [MERKLE_ZERO_VALUE];
for (let level = 1; level <= 16; level += 1) ZEROS.push(poseidonHex([ZEROS[level - 1], ZEROS[level - 1]]));

/** Every level of a tree over `leaves` (hex), leaves first, as the archive's tree files hold them. */
export function treeLevels(leaves) {
  const levels = [leaves.map((leaf) => leaf.padStart(64, '0'))];
  for (let level = 0; level < 16; level += 1) {
    const below = levels[level];
    const above = [];
    for (let i = 0; i < below.length; i += 2) above.push(poseidonHex([below[i], below[i + 1] ?? ZEROS[level]]));
    levels.push(above);
  }
  return levels;
}

/** A tree file: a u16 format, a u64 big-endian leaf count, then every level's nodes. */
export function treeFile(leaves) {
  const levels = treeLevels(leaves);
  const header = Buffer.alloc(10);
  header.writeUInt16BE(1, 0);
  header.writeBigUInt64BE(BigInt(leaves.length), 2);
  return Buffer.concat([header, ...levels.flat().map((node) => Buffer.from(node.padStart(64, '0'), 'hex'))]);
}

/**
 * Anon's archive of `fixture` for chain 1, sealed into chunks at `sealedAt` (the first block of each chunk after the
 * first) with the rest as the tip, and `transactions` (archive records) placed by block. `files` maps each path to its
 * bytes; `fetch` answers from it (404 for a missing one) and records every path asked for.
 */
export function archiveServer(fixture, { sealedAt, transactions = [], trees = {} }) {
  const files = new Map();
  const asked = [];
  const ranges = [];
  let start = fixture.from;
  for (const boundary of [...sealedAt, fixture.to + 1]) {
    ranges.push([start, boundary - 1]);
    start = boundary;
  }
  const tipRange = ranges.pop();
  const inRange = ([from, to]) => ({ blockNumber }) => blockNumber >= from && blockNumber <= to;
  const kinds = { ...fixture.archive, transactions };
  const publish = (dir, range) => {
    const meta = { files: {}, counts: {} };
    for (const [kind, records] of Object.entries(kinds)) {
      const body = json(records.filter(inRange(range)));
      files.set(`${dir}/${kind}.json.gz`, gzipSync(body));
      meta.files[kind] = { checksum: sha256(body), size: 0, jsonSize: body.length };
      meta.counts[kind] = records.filter(inRange(range)).length;
    }
    return meta;
  };
  const chunks = ranges.map(([from, to], id) => {
    const meta = publish(`chunks/${id}`, [from, to]);
    files.set(`chunks/${id}/meta.json`, json({ chunkId: id, formatVersion: 3, startBlock: from, endBlock: to, ...meta }));
    // The archive's index leaves early chunks' sequences unset though they hold transactions.
    return { id, startBlock: from, endBlock: to, firstSeq: -1, lastSeq: -1 };
  });
  files.set(`chunk-index.json`, json({ chainId: 1, chunks }));
  const tipMeta = json({ formatVersion: 3, startBlock: tipRange[0], endBlock: tipRange[1], ...publish('tip', tipRange) });
  files.set('tip/meta.json', tipMeta);
  const manifest = {
    version: 5,
    formatVersion: 2,
    chainId: 1,
    txidVersion: 'V2_PoseidonMerkle',
    latestSealedChunk: chunks.length - 1,
    tipChecksum: sha256(tipMeta),
    generatedAt: '2026-11-14T00:00:00Z',
    treeSnapshot: { treeDepth: 16, finalized: { utxo: [], txid: [] }, ...trees.snapshot },
  };
  for (const [name, bytes] of Object.entries(trees.files ?? {})) files.set(name, bytes);
  files.set('meta.json', json(manifest));
  return {
    files,
    asked,
    manifest,
    chunks,
    /** Re-publishes the manifest after an edit to it. */
    setManifest(edit) {
      files.set('meta.json', json(edit(JSON.parse(files.get('meta.json')))));
    },
    fetch: async (url) => {
      const name = url.replace(/^https:\/\/digest\.test\/v4\/1\//, '').replace(/\?v=.*$/, '');
      asked.push(name);
      const bytes = files.get(name);
      if (bytes === undefined) return new Response('', { status: 404 });
      return new Response(typeof bytes === 'function' ? bytes() : bytes);
    },
  };
}

export const ARCHIVE_BASE = 'https://digest.test/v4/1';
export const gz = gzipSync;
export const hashOf = sha256;
