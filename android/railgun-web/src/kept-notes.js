// Until the build had the engine keep a shield's note only if it hashes to its leaf (engine-hooks-plugin.mjs), a wallet
// kept whatever amount its source gave for a shield it could open. The engine decrypts a leaf once, so a note kept
// wrong stays for good: a balance the chain doesn't hold, in a note no payment can spend (its proof fails, and the
// smallest notes are spent first). So the shield notes a wallet keeps are held to their leaves once, by the test the
// engine now makes as it decrypts, and the ones that fail are dropped.
//
// The build has a wallet do it as the engine loads it (engine-hooks-plugin.mjs), where the engine migrates a wallet's
// notes itself: before the wallet has its trees, so no decryption, screening refresh or balance read of the engine's
// can be holding a note this drops and write it back. Only the page's own store is read: asking a source again over a
// wallet's own note would show it whose note it is.
import { ByteLength, ByteUtils, TransactNote, fromUTF8String } from '@railgun-community/engine';
import { hasPublicNote } from './commitment-check.js';

// Kept beside the wallet's notes, so it goes when they do: with the wallet, and when its notes are cleared to be
// decrypted again, which this build does under the check. One for each txid version: the engine loads a wallet its V2
// trees and then its V3 ones, on every chain, and one mark for both had the V3 load, which finds no notes, say the V2
// notes were held when their leaves weren't there to hold them to. A key of four parts, where a note's has five.
const held = (txidVersion) => fromUTF8String(`notes-held-${txidVersion}`);

// The engine's own test of a note it decrypts (`decryptedNoteMatchesCommitment`), on the note as the wallet keeps it.
// A note that can't be judged is left as it is.
function hashesTo({ npk, tokenHash, value }, leaf) {
  try {
    const hash = TransactNote.getHash(ByteUtils.hexToBigInt(npk), tokenHash, ByteUtils.hexToBigInt(value));
    return ByteUtils.nToHex(hash, ByteLength.UINT_256) === ByteUtils.formatToByteLength(leaf.hash, ByteLength.UINT_256);
  } catch {
    return true;
  }
}

/**
 * Drops the shield notes `wallet` keeps of `txidVersion` that don't hash to their leaf in `merkletree`, once for a
 * wallet, and answers how many. A note counts as a shield's by the kind of leaf it was decrypted from, which the engine
 * keeps with it: trees built again since may hold another kind of leaf there, and the engine has always held a
 * transfer's note to its leaf. A note whose leaf the trees don't hold (trees being built again) is left, to be looked
 * at when the wallet next loads. Nothing here keeps a wallet from loading: a store that can't be read now is read
 * when the wallet next loads.
 */
export async function holdShieldNotesToLeaves(wallet, merkletree, txidVersion) {
  const { chain } = merkletree;
  let dropped = 0;
  try {
    const mark = [...wallet.getWalletDBPrefix(chain), held(txidVersion)];
    const done = await wallet.db.get(mark, 'utf8').then(
      () => true,
      () => false,
    );
    if (done) return 0;
    let unseen = 0;
    const kept = await wallet.queryAllStoredReceiveCommitments(txidVersion, chain);
    for (const { storedReceiveCommitment: note, tree, position } of kept) {
      if (!hasPublicNote(note.commitmentType)) continue;
      const leaf = await merkletree.getCommitmentSafe(tree, position);
      if (leaf === undefined) {
        unseen += 1;
      } else if (!hashesTo(note.decrypted, leaf)) {
        await wallet.db.del(wallet.getWalletReceiveCommitmentDBPrefix(chain, tree, position));
        dropped += 1;
      }
    }
    if (unseen === 0) await wallet.db.put(mark, '1', 'utf8');
  } catch {
    // The store failing a read or a write: the wallet loads as it is, and is looked at again when it next loads.
  } finally {
    if (dropped > 0) wallet.invalidateCommitmentsCache(chain);
  }
  return dropped;
}
