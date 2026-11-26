// The engine finds a wallet's notes by trying to decrypt every leaf, a batch at a time, and keeps how far each tree has
// been tried. That whole pass sits inside a catch-all that logs whatever stops it and returns as if it had finished
// (`AbstractWallet.decryptBalances`): a leaf it can't read, or a write its store refused. The scan then ended complete,
// and the wallet's balance read as up to date with every note after that batch missing; a store that keeps such a leaf
// stopped there at every scan, for every wallet that hadn't decrypted past it.
//
// So the build has each notes scan check, once its decryption returns, that the wallets it decrypted for got through
// every leaf the trees hold (engine-hooks-plugin.mjs). One that didn't fails the scan, as a root the contract refuses
// does: the engine reports it incomplete, and the page's refresh fails rather than answer a balance. The build has the
// catch-all say what it caught, too, so the failure names its cause.
//
// A leaf the engine can't read stops every scan there for as long as the store keeps it, so the build has the engine
// mark what it fails on reading a leaf, and a decryption such a failure stopped counts its tree toward building the
// trees again, as a refused root does (tree-recovery.js). A write the store refused is no fault of the trees'.
import { treeFailed } from './tree-recovery.js';

/** How long a scan waits on a decryption that began outside it, and how often it looks. */
export const DECRYPT_WAIT_MS = 10 * 60_000;
const DECRYPT_POLL_MS = 250;

// Why the last notes scan's decryption fell short, until it is taken.
let stopped;
// What the engine's catch-all last caught decrypting each wallet's notes, by wallet id, until a scan finds the wallet
// through its trees or reports it short of them, or the page asks why a scan fell short.
const caught = new Map();

// What the engine threw reading a leaf, before anything of its batch was written.
const unread = new WeakSet();

/**
 * The engine failing to read a leaf as it decrypts (`AbstractWallet.scanLeaves`), which the build has it report: marks
 * `error`, and throws it on to the engine's catch-all.
 */
export function leafUnread(error) {
  if (Object(error) === error) unread.add(error);
  throw error;
}

/** The engine's decryption of wallet `id`'s notes stopping on `error`, which the build has it report. */
export function decryptionStopped(id, error) {
  caught.set(id, error);
}

/**
 * Why a notes scan's decryption fell short since this was last asked, if it did. What the engine caught until now is
 * forgotten with it: the page asks before each scan, so the cause a scan gives is one caught while it ran, not one
 * from a decryption before it (the engine's listener's, or a wallet's that was still loading).
 */
export function takeDecryptStop() {
  const taken = stopped;
  stopped = undefined;
  caught.clear();
  return taken;
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * The first tree `wallet`'s decryption stops short of, as `{tree, scanned, length}`, or undefined when it has tried
 * every leaf `merkletree` holds, from the tree it starts at (a wallet with a creation block skips the trees before it).
 * The lengths are read first: leaves that arrive while this looks are the next decryption's.
 */
export async function undecrypted(wallet, merkletree, txidVersion, chain) {
  const latest = await merkletree.latestTree();
  const lengths = [];
  for (let tree = 0; tree <= latest; tree += 1) lengths.push(await merkletree.getTreeLength(tree));
  const { treeScannedHeights, creationTree } = await wallet.getWalletDetails(txidVersion, chain);
  for (let tree = creationTree ?? 0; tree <= latest; tree += 1) {
    const scanned = treeScannedHeights[tree] ?? 0;
    if (scanned < lengths[tree]) return { tree, scanned, length: lengths[tree] };
  }
  return undefined;
}

/**
 * Throws unless every wallet `engine`'s notes scan decrypted for (those in `walletIdFilter`, or all) has tried every
 * leaf of `chain`'s trees, and keeps why for `takeDecryptStop`: how far the wallet came, and what stopped it when the
 * engine caught something. The engine's listener can begin a decryption of its own while a scan runs, which ends the
 * scan's early and carries on by itself: this waits for it first, `waitMs` at most.
 */
export async function notesDecrypted(
  engine,
  txidVersion,
  chain,
  walletIdFilter,
  { waitMs = DECRYPT_WAIT_MS, pollMs = DECRYPT_POLL_MS } = {},
) {
  const stop = (reason) => {
    stopped = reason;
    throw new Error(reason);
  };
  const merkletree = engine.getUTXOMerkletree(txidVersion, chain);
  for (const wallet of engine.allWallets()) {
    if (walletIdFilter != null && !walletIdFilter.includes(wallet.id)) continue;
    for (let waited = 0; wallet.decryptBalancesKeyForChain.has(null, chain); waited += pollMs) {
      if (waited >= waitMs) stop("the wallet's notes are still being decrypted");
      await delay(pollMs);
    }
    const short = await undecrypted(wallet, merkletree, txidVersion, chain);
    const cause = caught.get(wallet.id);
    caught.delete(wallet.id);
    if (short !== undefined) {
      if (unread.has(cause)) treeFailed(short.tree);
      const through = `through ${short.scanned} of tree ${short.tree}'s ${short.length} leaves`;
      stop(`the wallet's notes were decrypted ${through}${cause === undefined ? '' : `: ${cause?.message ?? cause}`}`);
    }
  }
}
