// Real Railgun notes for the made-up history (history-fixture.mjs): wallets on a whole engine, and transfers and
// shields to them encrypted as the engine's own transactions encrypt their outputs, as rail-squid lists them.
import { randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';
import path from 'node:path';
import { Mnemonic } from 'ethers';
import { NO_EVENTS } from '../src/quick-sync.js';
import { BuiltWallet, ENGINE, wholeEngine } from './engine-harness.mjs';
import { word } from './history-fixture.mjs';

const require = createRequire(import.meta.url);
const load = (module) => require(path.join(ENGINE, module));
const QUICK_SYNC = path.join(path.dirname(require.resolve('@railgun-community/wallet')), 'services/railgun/quick-sync');
const { formatGraphCommitmentEventsV2 } = require(path.join(QUICK_SYNC, 'V2/graph-type-formatters-v2'));
const { createGraphCommitmentBatches, sortByTreeNumberAndStartPosition } = require(
  path.join(QUICK_SYNC, 'V2/quick-sync-events-graph-v2'),
);
const { TransactNote } = load('note/transact-note');
const { ShieldNote } = load('note/shield-note');
const { getTokenDataERC20 } = load('note/note-util');
const { OutputType } = load('models/formatted-types');
const { getNoteBlindingKeys, getPublicViewingKey, getSharedSymmetricKey } = load('utils/keys-utils');
const { ByteUtils } = load('utils/bytes');

export const ENCRYPTION_KEY = word('the store key');
const TOKEN = `0x${word('token', 20)}`;

/** A valid mnemonic of its own for each `seed`. */
export const mnemonicOf = (seed) => Mnemonic.fromEntropy(`0x${word(`mnemonic ${seed}`, 16)}`).phrase;

/** Creation blocks as the engine keeps them, by chain type and id. */
export function creationBlocksFor(chain, block) {
  const blocks = [];
  blocks[chain.type] = [];
  blocks[chain.type][chain.id] = block;
  return blocks;
}

/** The wallet `seed`'s mnemonic derives, on `engine`, first used at `creationBlock` when given. */
export function walletOn(engine, chain, seed, creationBlock) {
  const blocks = creationBlock === undefined ? undefined : creationBlocksFor(chain, creationBlock);
  return engine.createWalletFromMnemonic(ENCRYPTION_KEY, mnemonicOf(seed), 0, blocks);
}

/**
 * The wallet `seed`'s mnemonic derives, on `engine`, as the build bundles a wallet (`BuiltWallet`): one already in the
 * engine's store loads from it, as a page opening a wallet again does.
 */
export async function builtWalletOn(engine, seed) {
  const wallet = await BuiltWallet.fromMnemonic(
    engine.db,
    ENCRYPTION_KEY,
    mnemonicOf(seed),
    0,
    undefined,
    engine.prover,
  );
  await engine.loadWallet(wallet);
  return wallet;
}

/**
 * `value` of the fixture's token sent from `sender` to `receiver` (engine wallets): the ciphertext and hash of its
 * commitment, as rail-squid lists a transaction's.
 */
export async function transfer(sender, receiver, value) {
  const note = TransactNote.createTransfer(
    receiver.addressKeys,
    sender.addressKeys,
    value,
    getTokenDataERC20(TOKEN),
    false,
    OutputType.Transfer,
    undefined,
  );
  const viewing = sender.getViewingKeyPair();
  const { blindedSenderViewingKey, blindedReceiverViewingKey } = getNoteBlindingKeys(
    viewing.pubkey,
    receiver.addressKeys.viewingPublicKey,
    note.random,
    note.senderRandom,
  );
  const sharedKey = await getSharedSymmetricKey(viewing.privateKey, blindedReceiverViewingKey);
  const { noteCiphertext, noteMemo, annotationData } = note.encryptV2(
    'V2_PoseidonMerkle',
    sharedKey,
    sender.addressKeys.masterPublicKey,
    note.senderRandom,
    viewing.privateKey,
  );
  return {
    hash: note.hash.toString(),
    ciphertext: {
      ciphertext: noteCiphertext,
      blindedReceiverViewingKey: ByteUtils.hexlify(blindedReceiverViewingKey),
      blindedSenderViewingKey: ByteUtils.hexlify(blindedSenderViewingKey),
      memo: noteMemo,
      annotationData,
    },
  };
}

/** Someone with Railgun keys of their own and no wallet here, to shield to: `seed` makes the keys. */
export async function someone(seed) {
  const pubkey = await getPublicViewingKey(Buffer.from(word(`viewing ${seed}`), 'hex'));
  return { masterPublicKey: BigInt(`0x${word(`master ${seed}`, 31)}`), getViewingKeyPair: () => ({ pubkey }) };
}

/**
 * A shield of `value` of the fixture's token to `receiver` (an engine wallet), as its event has it and rail-squid
 * lists its commitment: the note in the open, hashing to the leaf, and the random that makes it the receiver's
 * encrypted to its viewing key. From before Railgun's fee upgrade, as the fixture's blocks are, so rail-squid lists
 * no fee.
 */
export async function shield(receiver, value) {
  const note = new ShieldNote(receiver.masterPublicKey, ByteUtils.randomHex(16), value, getTokenDataERC20(TOKEN));
  const { preimage, ciphertext } = await note.serialize(randomBytes(32), receiver.getViewingKeyPair().pubkey);
  return {
    commitmentType: 'ShieldCommitment',
    hash: ShieldNote.getShieldNoteHash(note.notePublicKey, note.tokenHash, value).toString(),
    preimage: {
      npk: preimage.npk,
      value: value.toString(),
      token: { tokenType: 'ERC20', tokenSubID: '0x00', tokenAddress: TOKEN },
    },
    encryptedBundle: ciphertext.encryptedBundle,
    shieldKey: ciphertext.shieldKey,
    fee: null,
  };
}

/**
 * A shield of `value` to `receiver` (an engine wallet) from before shields were encrypted to a viewing key, as
 * rail-squid lists a legacy commitment: the note in the open, and its random encrypted to the wallet's own key.
 */
export function legacyShield(receiver, value) {
  const token = getTokenDataERC20(TOKEN);
  const note = new TransactNote(receiver.addressKeys, undefined, ByteUtils.randomHex(16), value, token);
  const { encryptedRandom } = note.serializeLegacy(receiver.getViewingKeyPair().privateKey);
  return {
    commitmentType: 'LegacyGeneratedCommitment',
    hash: note.hash.toString(),
    preimage: {
      npk: ByteUtils.nToHex(note.notePublicKey, 32, true),
      value: value.toString(),
      token: { tokenType: 'ERC20', tokenSubID: '0x00', tokenAddress: TOKEN },
    },
    encryptedRandom: encryptedRandom.map((part) => `0x${part}`),
    ciphertext: undefined,
  };
}

/** `listed` (a `shield`) with its amount given as `value`, its leaf's hash as it was: what a source could serve. */
export const withAmount = (listed, value) => ({ ...listed, preimage: { ...listed.preimage, value: value.toString() } });

// A shield as the archive records it, beside what the archive's record of a leaf always carries (`leaf`).
const archived = ({ txid, timestamp, blockNumber, utxoTree, utxoIndex }, listed) => ({
  commitmentType: 'ShieldCommitment',
  txid,
  timestamp,
  hash: BigInt(listed.hash).toString(16),
  blockNumber,
  utxoTree,
  utxoIndex,
  preImage: {
    npk: listed.preimage.npk,
    value: listed.preimage.value,
    token: { tokenType: 0, tokenSubID: '0', tokenAddress: listed.preimage.token.tokenAddress },
  },
  encryptedBundle: listed.encryptedBundle,
  shieldKey: listed.shieldKey,
  from: null,
});

/**
 * The fixture's history (`history()`) with the commitment at each of `positions` replaced by `notes` (`transfer`'s or
 * `shield`'s, in the same order). Answers a copy. Rail-squid's list takes every note; the archive's records take the
 * shields alone, each as `archive(note)` gives it (the note itself by default), so the two can be made to differ.
 */
export function withNotes(fixture, positions, notes, archive = (note) => note) {
  const noteAt = (position) => notes[positions.indexOf(position)];
  const commitments = fixture.squid.commitments.map((commitment) => {
    const note = noteAt(commitment.treePosition);
    return note === undefined ? commitment : { ...commitment, ...note };
  });
  const filed = fixture.archive.commitments.map((batch) => ({
    ...batch,
    commitments: batch.commitments.map((leaf) => {
      const note = noteAt(leaf.utxoIndex);
      return note?.commitmentType === 'ShieldCommitment' ? archived(leaf, archive(note)) : leaf;
    }),
  }));
  return {
    ...fixture,
    squid: { ...fixture.squid, commitments },
    archive: { ...fixture.archive, commitments: filed },
  };
}

/**
 * A whole engine (`Engine`, the build's by default) over `fixture`'s blocks whose quick sync hands it rail-squid's
 * `commitments` whole and as the SDK's own formats them: nothing of the page checks them on the way in, as nothing did
 * before commitment-check.js. Its contract takes every root.
 */
export async function engineTaking(fixture, commitments, { Engine } = {}) {
  const contract = {
    contract: { runner: { provider: { getBlockNumber: async () => fixture.to } } },
    validateMerkleroot: async () => true,
    getHistoricalEvents: async (_from, to, _next, _commitments, _nullifiers, _unshields, synced) => synced(to),
  };
  const built = await wholeEngine({ Engine, contract, deploymentBlock: fixture.from });
  const commitmentEvents = formatGraphCommitmentEventsV2(
    createGraphCommitmentBatches(commitments).sort(sortByTreeNumberAndStartPosition),
  );
  built.engine.quickSyncEvents = async (_version, _chain, startingBlock) =>
    startingBlock > fixture.from ? NO_EVENTS : { ...NO_EVENTS, commitmentEvents };
  return built;
}
