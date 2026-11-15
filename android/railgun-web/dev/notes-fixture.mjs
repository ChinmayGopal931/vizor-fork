// Real Railgun notes for the made-up history (history-fixture.mjs): wallets on a whole engine, and transfers to them
// encrypted as the engine's own transactions encrypt their outputs, as rail-squid lists them.
import { createRequire } from 'node:module';
import path from 'node:path';
import { Mnemonic } from 'ethers';
import { ENGINE } from './engine-harness.mjs';
import { word } from './history-fixture.mjs';

const require = createRequire(import.meta.url);
const load = (module) => require(path.join(ENGINE, module));
const { TransactNote } = load('note/transact-note');
const { getTokenDataERC20 } = load('note/note-util');
const { OutputType } = load('models/formatted-types');
const { getNoteBlindingKeys, getSharedSymmetricKey } = load('utils/keys-utils');
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

/**
 * The fixture's history (`history()`) with the commitment at each of `positions` replaced by `notes` (`transfer`'s,
 * in the same order). Answers a copy; the archive's records are left out of it.
 */
export function withNotes(fixture, positions, notes) {
  const commitments = fixture.squid.commitments.map((commitment) => {
    const at = positions.indexOf(commitment.treePosition);
    return at < 0 ? commitment : { ...commitment, ...notes[at] };
  });
  return { ...fixture, squid: { ...fixture.squid, commitments } };
}
