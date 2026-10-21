import assert from 'node:assert/strict';
import { test } from 'node:test';
import { Database, RailgunWallet } from '@railgun-community/engine';
import { NETWORK_CONFIG, NetworkName } from '@railgun-community/shared-models';
import { walletNamespaces } from '../src/wallet-namespaces.js';

// Throwaway BIP-39 phrases (public test vectors), never a real wallet's.
const MNEMONIC = 'test test test test test test test test test test test junk';
const OTHER = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const CHAINS = [NetworkName.Ethereum, NetworkName.EthereumSepolia].map((name) => NETWORK_CONFIG[name].chain);

// A wallet object as the engine builds one; the database is never touched.
async function walletFor(mnemonic) {
  const id = RailgunWallet.generateID(mnemonic, 0);
  return RailgunWallet.createWallet(id, {}, mnemonic, '', 0, undefined, undefined);
}

// What the engine's clearNamespace removes: every key from the namespace's own up to it followed by '~'.
const clears = (namespace, path) => {
  const prefix = Database.pathToKey(namespace);
  const key = Database.pathToKey(path);
  return key >= prefix && key <= `${prefix}~`;
};

test("the namespaces are the ones the engine's wallet writes to", async () => {
  const wallet = await walletFor(MNEMONIC);
  for (const chain of CHAINS) {
    assert.deepEqual(walletNamespaces(wallet.id, chain), [
      wallet.getWalletDBPrefix(chain),
      wallet.getWalletSentCommitmentDBPrefix(chain),
    ]);
  }
});

test("clearing them removes every note and detail the engine keeps for the wallet, and nothing of another's", async () => {
  const wallet = await walletFor(MNEMONIC);
  const other = await walletFor(OTHER);
  for (const chain of CHAINS) {
    const namespaces = walletNamespaces(wallet.id, chain);
    const writes = (owner) => [
      owner.getWalletReceiveCommitmentDBPrefix(chain, 0, 7),
      owner.getWalletSentCommitmentDBPrefix(chain, 1, 3),
      owner.getWalletDetailsPath(chain),
      owner.getUTXOMerkletreeHistoryVersionDBPrefix(chain),
    ];
    for (const path of writes(wallet)) {
      assert.ok(namespaces.some((namespace) => clears(namespace, path)), Database.pathToKey(path));
    }
    for (const path of writes(other)) {
      assert.ok(!namespaces.some((namespace) => clears(namespace, path)), Database.pathToKey(path));
    }
    // The encrypted keys go with deleteWalletByID, not with the namespaces.
    assert.ok(!namespaces.some((namespace) => clears(namespace, RailgunWallet.dbPath(wallet.id))));
  }
});
