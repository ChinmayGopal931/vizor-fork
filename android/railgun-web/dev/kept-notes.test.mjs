import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { throughKeptNotes, throughShieldHashChecks } from '../engine-hooks-plugin.mjs';
import { holdShieldNotesToLeaves } from '../src/kept-notes.js';
import { CHAIN, ENGINE, V2 } from './engine-harness.mjs';
import { history } from './history-fixture.mjs';
import {
  builtWalletOn,
  engineTaking,
  shield,
  transfer,
  walletOn,
  withAmount,
  withNotes,
} from './notes-fixture.mjs';

const fixture = history();
const AT = { mine: 10, small: 70, strangers: 200, transfer: 300 };
const UNITS = 1_000_000n;
const note = (at, value) => `${at}: ${value}`;
const MINE = [note(AT.mine, 25n * UNITS), note(AT.small, 1_000n), note(AT.transfer, 3n * UNITS)].sort();
// What the engine's own wallet makes of the forged records: 0.001 USDC read as a million, a stranger's 250 as its own.
const FORGED = [
  note(AT.mine, 25n * UNITS),
  note(AT.small, 1_000_000n * UNITS),
  note(AT.strangers, 250n * UNITS),
  note(AT.transfer, 3n * UNITS),
].sort();
// The forged notes dropped: the small shield's leaf is the wallet's, but its record's amount opens no note of it.
const KEPT = [note(AT.mine, 25n * UNITS), note(AT.transfer, 3n * UNITS)].sort();

/**
 * Rail-squid's commitments with four notes among them: two shields to the wallet, a stranger's shield, and a transfer
 * to the wallet. `honest` lists each as its event has it. `forged` gives the small shield a million times its amount,
 * and puts on the stranger's leaf the ciphertext of a shield made up for the wallet: that record's own note still
 * hashes to its leaf. Every leaf's hash is the same in both.
 */
async function listed() {
  const keys = await engineTaking(fixture, []);
  const wallet = await walletOn(keys.engine, CHAIN, 'the wallet');
  const stranger = await walletOn(keys.engine, CHAIN, 'a stranger');
  const mine = await shield(wallet, 25n * UNITS);
  const small = await shield(wallet, 1_000n);
  const strangers = await shield(stranger, 250n * UNITS);
  const sent = await transfer(stranger, wallet, 3n * UNITS);
  const { encryptedBundle, shieldKey } = await shield(wallet, 5_000_000n * UNITS);
  const among = (notes) =>
    withNotes(fixture, [AT.mine, AT.small, AT.strangers, AT.transfer], notes).squid.commitments;
  return {
    honest: among([mine, small, strangers, sent]),
    forged: among([mine, withAmount(small, 1_000_000n * UNITS), { ...strangers, encryptedBundle, shieldKey }, sent]),
  };
}

const notes = async (wallet) =>
  (await wallet.TXOs(V2, CHAIN)).map(({ position, note: kept }) => note(position, kept.value)).sort();

/** What the wallet keeps of a scan of `commitments`: the build's wallet when `built`, else the engine's own. */
async function scanned(commitments, { built }) {
  const { engine, utxo } = await engineTaking(fixture, commitments);
  const wallet = built ? await builtWalletOn(engine, 'the wallet') : await walletOn(engine, CHAIN, 'the wallet');
  await engine.scanUTXOHistory(V2, CHAIN, [wallet.id]);
  return { engine, wallet, kept: await notes(wallet), root: await utxo.getRoot(0) };
}

test("the build's wallet keeps a shield's note only if it hashes to its leaf, where the engine's own kept any it could open", async () => {
  const { honest, forged } = await listed();
  const unchecked = await scanned(forged, { built: false });
  assert.deepEqual(unchecked.kept, FORGED);
  const checked = await scanned(forged, { built: true });
  assert.deepEqual(checked.kept, KEPT);
  // The trees are an honest source's all the while: their root vouches for neither note.
  const { root } = await scanned(honest, { built: true });
  assert.equal(unchecked.root, root);
  assert.equal(checked.root, root);
});

test('with every record as its event has it, the build keeps exactly the notes the engine keeps', async () => {
  const { honest } = await listed();
  const checked = await scanned(honest, { built: true });
  assert.deepEqual(checked.kept, MINE);
  assert.deepEqual(checked.kept, (await scanned(honest, { built: false })).kept);
});

test('a wallet that kept such notes before the check drops them as it next loads, once, and keeps the rest as they were', async () => {
  const { forged } = await listed();
  const { engine, wallet: unchecked, kept: before } = await scanned(forged, { built: false });
  assert.deepEqual(before, FORGED);
  const records = async (wallet) =>
    new Map(
      (await wallet.queryAllStoredReceiveCommitments(V2, CHAIN)).map(({ position, storedReceiveCommitment }) => [
        position,
        JSON.stringify(storedReceiveCommitment),
      ]),
    );
  const stored = await records(unchecked);
  // The page opening the wallet again, on the build with the check: nothing is scanned, and no source is asked.
  const loaded = await builtWalletOn(engine, 'the wallet');
  assert.deepEqual(await notes(loaded), KEPT);
  for (const [position, record] of await records(loaded)) {
    assert.equal(record, stored.get(position), `the note at ${position}`);
  }
  // What is left is what the build's own decryption of the same leaves keeps.
  assert.deepEqual(await notes(loaded), (await scanned(forged, { built: true })).kept);
  // Once: a wallet held to its leaves is not read through again.
  let reads = 0;
  const utxo = engine.getUTXOMerkletree(V2, CHAIN);
  const counting = { chain: CHAIN, getCommitmentSafe: (...at) => ((reads += 1), utxo.getCommitmentSafe(...at)) };
  assert.equal(await holdShieldNotesToLeaves(loaded, counting, V2), 0);
  assert.equal(reads, 0);
});

test('a kept note whose leaf the trees do not hold is left, and the wallet is looked at again when it next loads', async () => {
  const { engine, wallet } = await scanned((await listed()).forged, { built: false });
  const utxo = engine.getUTXOMerkletree(V2, CHAIN);
  // Trees being built again, not yet as far as the wallet's later notes.
  const rebuilding = {
    chain: CHAIN,
    getCommitmentSafe: (tree, position) => (position > AT.small ? undefined : utxo.getCommitmentSafe(tree, position)),
  };
  assert.equal(await holdShieldNotesToLeaves(wallet, rebuilding, V2), 1);
  assert.deepEqual(await notes(wallet), FORGED.filter((kept) => kept !== note(AT.small, 1_000_000n * UNITS)));
  assert.equal(await holdShieldNotesToLeaves(wallet, utxo, V2), 1);
  assert.deepEqual(await notes(wallet), KEPT);
});

test("the shield check is engine 9.9.1's own: a build against an engine that has it, or that loads a wallet another way, fails", () => {
  const source = readFileSync(path.join(ENGINE, 'wallet/abstract-wallet.js'), 'utf8');
  const checked = throughShieldHashChecks(source);
  assert.equal(checked.split('preImage hash does not match commitment.').length, 3, 'a shield and a legacy shield');
  assert.throws(() => throughShieldHashChecks(checked), /no longer applies/);
  const loadedAnotherWay = source.replace('this.utxoMerkletrees.set(txidVersion,', 'this.trees.set(txidVersion,');
  assert.throws(() => throughKeptNotes(loadedAnotherWay), /no longer applies/);
});
