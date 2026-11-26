import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EngineEvent, MerkletreeScanStatus, RailgunEngine } from '@railgun-community/engine';
import { decryptionStopped, notesDecrypted, takeDecryptStop, undecrypted } from '../src/notes-decrypted.js';
import { CHAIN, V2 } from './engine-harness.mjs';
import { history } from './history-fixture.mjs';
import { builtWalletOn, engineTaking, shield, walletOn, withNotes } from './notes-fixture.mjs';

const fixture = history();
const MINE = 10;

/** Rail-squid's commitments with a shield to the wallet among them, and `others` (by leaf) beside it. */
async function listed(others = () => ({})) {
  const keys = await engineTaking(fixture, []);
  const wallet = await walletOn(keys.engine, CHAIN, 'the wallet');
  const stranger = await walletOn(keys.engine, CHAIN, 'a stranger');
  const beside = others(await shield(stranger, 2_000n));
  const positions = [MINE, ...Object.keys(beside).map(Number)];
  return withNotes(fixture, positions, [await shield(wallet, 1_000n), ...Object.values(beside)]).squid.commitments;
}

/** An engine taking `commitments` unchecked, the wallet on it, and how each of its notes scans ended. */
async function scanning(commitments, { Engine } = {}) {
  const built = await engineTaking(fixture, commitments, { Engine });
  const wallet = await builtWalletOn(built.engine, 'the wallet');
  const ends = [];
  built.engine.on(EngineEvent.UTXOScanDecryptBalancesComplete, () => ends.push('complete'));
  built.engine.on(EngineEvent.UTXOMerkletreeHistoryScanUpdate, ({ scanStatus }) => {
    if (scanStatus === MerkletreeScanStatus.Incomplete) ends.push('incomplete');
  });
  takeDecryptStop();
  const found = async () => (await wallet.TXOs(V2, CHAIN)).length;
  return { ...built, wallet, ends, found, scan: () => built.engine.scanUTXOHistory(V2, CHAIN, [wallet.id]) };
}

// A shield whose key is no hex, five leaves after the wallet's note: the engine's decryption throws on its batch.
const unreadable = (strangers) => ({ [MINE + 5]: { ...strangers, shieldKey: 'not hex at all' } });

test("a leaf the engine can't read ended every scan complete with the wallet's notes missing; the build's scan fails", async () => {
  const commitments = await listed(unreadable);
  // The engine's own scan: complete, three times over, the wallet's one note never found and nothing marked scanned.
  const own = await scanning(commitments, { Engine: RailgunEngine });
  for (let scan = 0; scan < 3; scan += 1) await own.scan();
  assert.deepEqual(own.ends, ['complete', 'complete', 'complete']);
  assert.equal(await own.found(), 0);
  assert.deepEqual(await undecrypted(own.wallet, own.utxo, V2, CHAIN), { tree: 0, scanned: 0, length: fixture.leaves });

  const built = await scanning(commitments);
  for (let scan = 0; scan < 3; scan += 1) {
    await built.scan();
    // How far the wallet came, and what the engine's catch-all caught: its own reading of the key.
    assert.match(
      takeDecryptStop(),
      new RegExp(`^the wallet's notes were decrypted through 0 of tree 0's ${fixture.leaves} leaves: .*hex`, 'i'),
    );
  }
  assert.deepEqual(built.ends, ['incomplete', 'incomplete', 'incomplete']);
});

test('a decryption a write that failed stopped fails its scan, and the next scan, its write through, completes', async () => {
  const { wallet, ends, found, scan } = await scanning(await listed());
  // The store refusing a batch's notes, a full quota or a lost connection, twice: the scan's try, and its try again.
  const scanLeaves = wallet.scanLeaves.bind(wallet);
  let failures = 2;
  wallet.scanLeaves = async (...batch) => {
    if (failures > 0) {
      failures -= 1;
      throw new Error('QuotaExceededError');
    }
    return scanLeaves(...batch);
  };
  await scan();
  assert.deepEqual(ends, ['incomplete']);
  assert.equal(
    takeDecryptStop(),
    `the wallet's notes were decrypted through 0 of tree 0's ${fixture.leaves} leaves: QuotaExceededError`,
  );
  assert.equal(await found(), 0);
  await scan();
  assert.deepEqual(ends, ['incomplete', 'complete']);
  assert.equal(takeDecryptStop(), undefined);
  assert.equal(await found(), 1);
});

/** A wallet whose trees stand at `lengths`, decrypted through `scanned` of each, `busy()` while a decryption runs. */
function decrypted({ lengths, scanned, creationTree, busy = () => false }) {
  const merkletree = {
    latestTree: async () => lengths.length - 1,
    getTreeLength: async (tree) => lengths[tree],
  };
  const wallet = {
    id: 'the wallet',
    decryptBalancesKeyForChain: { has: () => busy() },
    getWalletDetails: async () => ({ treeScannedHeights: scanned(), creationTree }),
  };
  const engine = { getUTXOMerkletree: () => merkletree, allWallets: () => [wallet, { id: 'another wallet' }] };
  return { engine, wallet, merkletree };
}

test('a wallet is through its trees when every tree it starts from is tried to its last leaf', async () => {
  const short = async (state) => {
    const { wallet, merkletree } = decrypted(state);
    return undecrypted(wallet, merkletree, V2, CHAIN);
  };
  const lengths = [65_536, 40];
  assert.equal(await short({ lengths, scanned: () => [65_536, 40] }), undefined);
  assert.deepEqual(await short({ lengths, scanned: () => [65_536, 32] }), { tree: 1, scanned: 32, length: 40 });
  // A tree the wallet has not begun: the engine lists none of its leaves as tried.
  assert.deepEqual(await short({ lengths, scanned: () => [65_536] }), { tree: 1, scanned: 0, length: 40 });
  // A wallet created in tree 1 never tries tree 0's leaves.
  assert.equal(await short({ lengths, scanned: () => [0, 40], creationTree: 1 }), undefined);
  assert.equal(await short({ lengths: [0], scanned: () => [] }), undefined);
});

test("a decryption the engine's listener began mid-scan is waited for: the scan's own ended early, short of the leaves", async () => {
  // The listener's run is on its way through the tree when the scan's returns.
  let polls = 0;
  const { engine } = decrypted({
    lengths: [40],
    scanned: () => (polls < 3 ? [32] : [40]),
    busy: () => (polls += 1) < 3,
  });
  takeDecryptStop();
  await notesDecrypted(engine, V2, CHAIN, ['the wallet'], { pollMs: 1 });
  assert.equal(polls, 3);
  assert.equal(takeDecryptStop(), undefined);
});

test('a decryption that never ends, or ends short, fails the scan and says why', async () => {
  const stuck = decrypted({ lengths: [40], scanned: () => [32], busy: () => true });
  const waiting = notesDecrypted(stuck.engine, V2, CHAIN, ['the wallet'], { pollMs: 1, waitMs: 5 });
  await assert.rejects(waiting, /still being decrypted/);
  assert.equal(takeDecryptStop(), "the wallet's notes are still being decrypted");
  const short = decrypted({ lengths: [40], scanned: () => [32] });
  await assert.rejects(notesDecrypted(short.engine, V2, CHAIN, undefined), /through 32 of tree 0's 40 leaves/);
  assert.equal(takeDecryptStop(), "the wallet's notes were decrypted through 32 of tree 0's 40 leaves");
  assert.equal(takeDecryptStop(), undefined, 'taken once');
});

test('what the engine caught is said once: a wallet through its trees, or reported short, forgets it', async () => {
  let scanned = [32];
  const { engine } = decrypted({ lengths: [40], scanned: () => scanned });
  decryptionStopped('the wallet', new Error('the store refused the write'));
  await assert.rejects(notesDecrypted(engine, V2, CHAIN, ['the wallet']), /leaves: the store refused the write$/);
  // Short again with nothing caught since: the listener's run ended the scan's early, and never finished.
  await assert.rejects(notesDecrypted(engine, V2, CHAIN, ['the wallet']), /leaves$/);
  // A failure a later run got over is not a later shortfall's cause.
  decryptionStopped('the wallet', new Error('the store refused the write'));
  scanned = [40];
  await notesDecrypted(engine, V2, CHAIN, ['the wallet']);
  scanned = [32];
  await assert.rejects(notesDecrypted(engine, V2, CHAIN, ['the wallet']), /leaves$/);
  // Nor is one caught before the page last asked, as it does before each scan: a scan's cause is caught while it runs.
  decryptionStopped('the wallet', new Error('the store refused the write'));
  takeDecryptStop();
  await assert.rejects(notesDecrypted(engine, V2, CHAIN, ['the wallet']), /leaves$/);
  takeDecryptStop();
});
