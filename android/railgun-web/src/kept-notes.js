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
import { AbstractWallet, ByteLength, ByteUtils, TransactNote, fromUTF8String } from '@railgun-community/engine';
import { hasPublicNote } from './commitment-check.js';

// Kept beside the wallet's notes, so it goes when they do: with the wallet, and when its notes are cleared to be
// decrypted again, which this build does under the check.
const HELD = fromUTF8String('shield-notes-held-to-leaves');

// The engine's own test of a note it decrypts (`decryptedNoteMatchesCommitment`), on the note as the wallet keeps it.
function hashesTo({ npk, tokenHash, value }, leaf) {
  const hash = TransactNote.getHash(ByteUtils.hexToBigInt(npk), tokenHash, ByteUtils.hexToBigInt(value));
  return ByteUtils.nToHex(hash, ByteLength.UINT_256) === ByteUtils.formatToByteLength(leaf.hash, ByteLength.UINT_256);
}

/**
 * Drops the shield notes `wallet` keeps that don't hash to their leaf in `merkletree`, once for a wallet, and answers
 * how many. A note whose leaf the trees don't hold (trees being built again) is left, to be looked at when the wallet
 * next loads.
 */
export async function holdShieldNotesToLeaves(wallet, merkletree, txidVersion) {
  const { chain } = merkletree;
  const held = [...wallet.getWalletDBPrefix(chain), HELD];
  const done = await wallet.db.get(held, 'utf8').then(
    () => true,
    () => false,
  );
  if (done) return 0;
  let dropped = 0;
  let unseen = 0;
  const kept = await wallet.queryAllStoredReceiveCommitments(txidVersion, chain);
  for (const { storedReceiveCommitment: note, tree, position } of kept) {
    const leaf = await merkletree.getCommitmentSafe(tree, position);
    if (leaf === undefined) {
      unseen += 1;
    } else if (hasPublicNote(AbstractWallet.getCommitmentType(leaf)) && !hashesTo(note.decrypted, leaf)) {
      await wallet.db.del(wallet.getWalletReceiveCommitmentDBPrefix(chain, tree, position));
      dropped += 1;
    }
  }
  if (dropped > 0) wallet.invalidateCommitmentsCache(chain);
  if (unseen === 0) await wallet.db.put(held, '1', 'utf8');
  return dropped;
}
