// A quick sync takes Railgun's commitments from an indexer or an archive, and the trees' root check vouches for each
// leaf's hash alone. What a wallet reads beside the hash is held here, before a record is stored, to what the engine
// makes of the event when it reads the chain itself:
// - A shield's note (its key, token and amount) is public in its event, and the engine hashes the leaf from it
//   (`V2Events.formatShieldCommitments`, and the legacy events' the same). A record whose note doesn't hash to its leaf
//   would show the note's wallet an amount the chain doesn't hold; under the wallet's own check of what it decrypts
//   (engine-hooks-plugin.mjs) it would hide the note from it instead.
// - The engine reads a leaf's keys, and a legacy transfer's memo, before it tries to decrypt the leaf, outside the try
//   that expects a leaf of someone else's. A leaf it can't read there stops every wallet's decryption at that leaf's
//   batch, for good.
// - Of a note a wallet opened, the engine reads the leaf's hash and numbers the note by the record's own tree and
//   index, outside that try too. A record numbered by anything but whole numbers would stop the decryption of the
//   wallets whose note it is, and of no other: the record's source would see whose it is.
// Every record is checked, whoever's it is: a wallet that turned to another source over its own notes alone would show
// the source which notes are its. What a record's ciphertext holds only its wallet can check, and it does.
import { AbstractWallet, ByteLength, ByteUtils, CommitmentType, getNoteHash } from '@railgun-community/engine';
import { leafPoints } from './note-keys.js';

/** A source's record that isn't the chain's: the sync turns to another source for it. */
export class RecordRefused extends Error {}

// The commitments whose note is public: a shield's, and one from before shields were encrypted to a viewing key.
const PUBLIC_NOTE = new Set([CommitmentType.ShieldCommitment, CommitmentType.LegacyGeneratedCommitment]);

// Whether `commitment`'s note hashes to its leaf, as the engine hashes a shield it reads from the chain.
function hashesToLeaf({ hash, preImage }) {
  try {
    const noteHash = getNoteHash(preImage.npk, preImage.token, ByteUtils.hexToBigInt(preImage.value));
    return (
      ByteUtils.nToHex(noteHash, ByteLength.UINT_256) === ByteUtils.formatToByteLength(hash, ByteLength.UINT_256)
    );
  } catch {
    // A note that can't be hashed.
    return false;
  }
}

// Whether `n` numbers a tree, or a leaf in one.
const isCount = (n) => Number.isSafeInteger(n) && n >= 0;

// Whether the engine's decryption gets through `commitment`, whoever's it is
// (`AbstractWallet.createScannedDBCommitments`): it reads the leaf's keys first (note-keys.js) and joins a legacy
// transfer's memo, and of a note it opened it reads the leaf's hash and numbers the note by the record's tree and index
// (`getGlobalTreePosition`, which adds them: a string joins on instead, and nothing but a whole number makes a BigInt).
function engineReads(commitment, type) {
  try {
    leafPoints(commitment, type);
    if (type === CommitmentType.LegacyEncryptedCommitment) ByteUtils.combine(commitment.ciphertext.memo.slice());
    ByteUtils.formatToByteLength(commitment.hash, ByteLength.UINT_256);
    return isCount(commitment.utxoTree) && isCount(commitment.utxoIndex);
  } catch {
    return false;
  }
}

/**
 * The first of `events`' records (commitment batches as the engine's listener takes them) that isn't the chain's, as
 * `{tree, index, why}`, or undefined when every one is. A record's type is read as the engine's decryption reads it.
 * A tree or an index that is no number is given as '?': what a source put there goes into no message.
 */
export function refusedRecord(events) {
  for (const { commitments } of events) {
    for (const commitment of commitments) {
      const type = AbstractWallet.getCommitmentType(commitment);
      const why = !engineReads(commitment, type)
        ? 'is not one the engine can read'
        : PUBLIC_NOTE.has(type) && !hashesToLeaf(commitment)
          ? 'does not hash to its leaf'
          : undefined;
      if (why !== undefined) {
        const numbered = (n) => (isCount(n) ? n : '?');
        return { tree: numbered(commitment.utxoTree), index: numbered(commitment.utxoIndex), why };
      }
    }
  }
  return undefined;
}
