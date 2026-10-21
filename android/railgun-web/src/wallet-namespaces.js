import { AbstractWallet } from '@railgun-community/engine';

/**
 * Where the engine keeps a wallet's data on `chain` besides its encrypted keys (`['wallet', id]`): the notes a sync
 * decrypted for it, with its scan details, and the notes it sent. The engine writes both unencrypted, so deleting a
 * wallet clears them too. The engine's own methods build the paths; they read nothing of a wallet but its id.
 */
export function walletNamespaces(id, chain) {
  const wallet = { id };
  return [
    AbstractWallet.prototype.getWalletDBPrefix.call(wallet, chain),
    AbstractWallet.prototype.getWalletSentCommitmentDBPrefix.call(wallet, chain),
  ];
}
