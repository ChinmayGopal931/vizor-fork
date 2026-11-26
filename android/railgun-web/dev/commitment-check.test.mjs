import assert from 'node:assert/strict';
import { test } from 'node:test';
import { refusedRecord } from '../src/commitment-check.js';
import { formatCommitments } from '../src/quick-sync.js';
import { CHAIN, V2, wholeEngine } from './engine-harness.mjs';
import { history, word } from './history-fixture.mjs';
import { builtWalletOn, legacyShield as legacyShieldTo, shield, someone, transfer } from './notes-fixture.mjs';

const fixture = history({ blocks: 8 });
const [leaf] = fixture.squid.commitments;
// One record, as the engine's listener takes it, of what rail-squid lists as `listed` at the fixture's first leaf.
const recordOf = (listed) => formatCommitments([{ ...leaf, ...listed }])[0].commitments[0];
const refused = (record) => refusedRecord([{ commitments: [record] }]);

test('a shield as its event has it is taken; one whose amount, token or key is not what its leaf hashes is refused', async () => {
  const real = recordOf(await shield(await someone('a receiver'), 1_000n));
  assert.equal(refused(real), undefined);
  const { preImage } = real;
  const other = { ...preImage.token, tokenAddress: `0x${word('another token', 20)}` };
  const amount = (value) => value.toString(16).padStart(32, '0');
  assert.equal(preImage.value, amount(1_000n));
  for (const [what, note] of [
    ['a raised amount', { ...preImage, value: amount(1_000_000_000_000n) }],
    ['a lowered amount', { ...preImage, value: amount(1n) }],
    ['another token', { ...preImage, token: other }],
    ["another's key", { ...preImage, npk: word('another key', 31).padStart(64, '0') }],
    ['an amount that is no number', { ...preImage, value: 'a million' }],
    ['no note at all', undefined],
  ]) {
    assert.deepEqual(
      refused({ ...real, preImage: note }),
      { tree: real.utxoTree, index: real.utxoIndex, why: 'does not hash to its leaf' },
      what,
    );
  }
  // The leaf moved under an honest note is refused the same way: the two must agree.
  const moved = { ...real, hash: word('another leaf', 31).padStart(64, '0') };
  assert.equal(refused(moved)?.why, 'does not hash to its leaf');
});

// A legacy shield, from before shields were encrypted to a viewing key, as rail-squid lists it: its note in the open.
const legacyShield = async () => {
  const { hash, preimage } = await shield(await someone('a legacy receiver'), 2_000n);
  return {
    commitmentType: 'LegacyGeneratedCommitment',
    hash,
    preimage,
    encryptedRandom: [`0x${word('random', 32)}`, `0x${word('random tag', 16)}`],
  };
};

const legacyTransfer = {
  commitmentType: 'LegacyEncryptedCommitment',
  legacyCiphertext: {
    ciphertext: { iv: word('liv', 16), tag: word('ltag', 16), data: [word('l0'), word('l1')] },
    ephemeralKeys: [word('k0'), word('k1')],
    memo: [word('m0')],
  },
};

test("a legacy shield's note is held to its leaf as a shield's is", async () => {
  const real = recordOf(await legacyShield());
  assert.equal(refused(real), undefined);
  const raised = { ...real, preImage: { ...real.preImage, value: 'f'.repeat(32) } };
  assert.equal(refused(raised)?.why, 'does not hash to its leaf');
});

/** Every copy of `record` with one of its fields, at any depth, replaced by `value`, with the field's path. */
function* withEachField(record, value, path = []) {
  for (const [key, field] of Object.entries(record)) {
    const here = [...path, key];
    const replaced = (by) =>
      Array.isArray(record) ? record.map((kept, i) => (String(i) === key ? by : kept)) : { ...record, [key]: by };
    yield { path: here.join('.'), record: replaced(value) };
    if (field !== null && typeof field === 'object') {
      for (const inner of withEachField(field, value, here)) yield { path: inner.path, record: replaced(inner.record) };
    }
  }
}

test("every record the engine's decryption throws on is refused before it is stored, whatever in it is wrong and whoever's it is", async () => {
  const { engine } = await wholeEngine({ contract: {}, deploymentBlock: fixture.from });
  // The build's wallets: the one the records below are addressed to, the one that sent it a transfer, and a stranger
  // to them all. The engine reads more of a note a wallet opens than of one it can't.
  const wallet = await builtWalletOn(engine, 'the wallet');
  const sender = await builtWalletOn(engine, 'a sender');
  const stranger = await builtWalletOn(engine, 'a wallet of someone else');
  const scans = (who, record, at) => who.scanLeaves(V2, [record], 0, CHAIN, at, undefined);
  // What a leaf the engine can't read does to a batch: the whole batch's decryption throws, for some wallet at least.
  const engineThrows = async (record, at) => {
    for (const who of [wallet, sender, stranger]) {
      const threw = await scans(who, record, at).then(
        () => false,
        () => true,
      );
      if (threw) return true;
    }
    return false;
  };
  const kept = async (who) => (await who.queryAllStoredReceiveCommitments(V2, CHAIN)).map(({ position }) => position);
  const records = {
    shield: recordOf(await shield(await someone('a receiver'), 1_000n)),
    transfer: recordOf({}),
    'legacy shield': recordOf(await legacyShield()),
    'legacy transfer': recordOf(legacyTransfer),
    'shield to the wallet': recordOf(await shield(wallet, 1_000n)),
    'transfer to the wallet': recordOf(await transfer(sender, wallet, 3_000n)),
    'legacy shield to the wallet': recordOf(legacyShieldTo(wallet, 2_000n)),
  };
  const thrownOn = {};
  for (const [at, [kind, record]] of Object.entries(records).entries()) {
    assert.equal(await engineThrows(record, at), false, `${kind}: the engine reads the record as it is`);
    assert.equal(refused(record), undefined, `${kind}: the record as it is is taken`);
    const mine = kind.endsWith('to the wallet');
    assert.equal((await kept(wallet)).includes(at), mine, `${kind}: the wallet's note or not`);
    thrownOn[kind] = new Set();
    for (const wrong of ['not hex', undefined, null, 7, 1.5, -1, '7e0']) {
      for (const { path, record: garbled } of withEachField(record, wrong)) {
        if (!(await engineThrows(garbled, at))) continue;
        thrownOn[kind].add(path);
        const stored = `${kind} with ${path} as ${wrong}: stored, it would stop a wallet's scans`;
        assert.notEqual(refused(garbled), undefined, stored);
      }
    }
  }
  // What the engine reads outside its try, at least: the test would pass on an engine that threw on nothing.
  for (const [kind, paths] of Object.entries({
    shield: ['shieldKey'],
    transfer: ['ciphertext.blindedSenderViewingKey', 'ciphertext.blindedReceiverViewingKey'],
    'legacy shield': ['preImage.token.tokenAddress'],
    'legacy transfer': ['ciphertext.ephemeralKeys.0', 'ciphertext.ephemeralKeys.1'],
    'shield to the wallet': ['utxoTree', 'utxoIndex'],
    'transfer to the wallet': ['utxoTree', 'utxoIndex', 'hash'],
    'legacy shield to the wallet': ['utxoTree', 'utxoIndex'],
  })) {
    for (const path of paths) assert.ok(thrownOn[kind].has(path), `${kind}: the engine throws on ${path}`);
  }
});

test('a record numbered by anything but whole numbers is refused, and what its source put there is in no message', () => {
  const real = recordOf({});
  assert.equal(refused(real), undefined);
  for (const [field, wrong] of [
    ['utxoIndex', `${real.utxoIndex}e0`],
    ['utxoIndex', String(real.utxoIndex)],
    ['utxoIndex', 1.5],
    ['utxoIndex', -1],
    ['utxoTree', '0'],
    ['utxoTree', null],
  ]) {
    const { tree, index, why } = refused({ ...real, [field]: wrong });
    assert.equal(why, 'is not one the engine can read', `${field} as ${JSON.stringify(wrong)}`);
    const at = { tree: real.utxoTree, index: real.utxoIndex, [field === 'utxoTree' ? 'tree' : 'index']: '?' };
    assert.deepEqual({ tree, index }, at);
  }
});
