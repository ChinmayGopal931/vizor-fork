import assert from 'node:assert/strict';
import { test } from 'node:test';
import { Merkletree } from '@railgun-community/engine';
import { fillHashWriteGroup, forgetPrebuiltTrees, parseTree, usePrebuiltTree } from '../src/prebuilt-trees.js';
import { poseidon } from './engine-harness.mjs';
import { ZEROS, treeFile, treeLevels, word } from './history-fixture.mjs';

const leaves = Array.from({ length: 300 }, (_, i) => word(`leaf-${i}`, 31).padStart(64, '0'));
const UTXO = { merkletreeType: 'UTXO' };
const own = (...args) => Merkletree.fillHashWriteGroup(...args);

/** A group of `leaves[from..to]` as the engine's two callers hand it over, earlier leaves stored as `stored` gives. */
function group(from, to) {
  const first = [];
  for (let i = from; i <= to; i += 1) first[i] = leaves[i];
  return [first];
}

async function counting(run) {
  const hash = poseidon.poseidonHex;
  let hashed = 0;
  poseidon.poseidonHex = (inputs) => {
    hashed += 1;
    return hash(inputs);
  };
  try {
    return { group: await run(), hashed };
  } finally {
    poseidon.poseidonHex = hash;
  }
}

// The leaves before a group are stored: the engine looks their nodes up.
const levels = treeLevels(leaves);
const stored = (level, index) => levels[level][index] ?? ZEROS[level];

test('a tree file reads back as the tree it holds', () => {
  const tree = parseTree(treeFile(leaves));
  const levels = treeLevels(leaves);
  assert.equal(tree.leafCount, leaves.length);
  assert.equal(tree.root, levels[16][0]);
  assert.equal(tree.node(3, 5), levels[3][5]);
  assert.equal(tree.node(0, leaves.length), undefined);
});

test('a tree file of another format or size is refused', () => {
  const file = treeFile(leaves);
  const other = Buffer.from(file);
  other.writeUInt16BE(2, 0);
  assert.throws(() => parseTree(other), /format/);
  assert.throws(() => parseTree(file.subarray(0, file.length - 1)), /not a tree/);
});

for (const [caller, endIndex] of [
  ['insertLeaves, which passes the index after its last leaf', 251],
  ['rebuildAndWriteTree, which passes its last leaf', 250],
]) {
  test(`a group from ${caller}, copied from the prebuilt tree, is what the engine would hash`, async () => {
    usePrebuiltTree('UTXO', 0, parseTree(treeFile(leaves)));
    try {
      const hashed = await counting(() => own(group(100, 250), 0, 100, endIndex, stored));
      const copied = await counting(() => fillHashWriteGroup(UTXO, own, group(100, 250), 0, 100, endIndex, stored));
      assert.deepEqual(copied.group, hashed.group);
      assert.ok(copied.hashed < hashed.hashed / 3, `${copied.hashed} hashed with the tree, ${hashed.hashed} without`);
    } finally {
      forgetPrebuiltTrees('UTXO');
    }
  });
}

test('a group reaching past the prebuilt tree copies only what the tree covers', async () => {
  usePrebuiltTree('UTXO', 0, parseTree(treeFile(leaves.slice(0, 200))));
  try {
    const hashed = await own(group(100, 299), 0, 100, 300, stored);
    const copied = await fillHashWriteGroup(UTXO, own, group(100, 299), 0, 100, 300, stored);
    assert.deepEqual(copied, hashed);
  } finally {
    forgetPrebuiltTrees('UTXO');
  }
});

test("a group whose leaves aren't the prebuilt tree's is hashed", async () => {
  const other = [...leaves];
  other[150] = word('another', 31).padStart(64, '0');
  usePrebuiltTree('UTXO', 0, parseTree(treeFile(other)));
  try {
    const hashed = await counting(() => own(group(100, 250), 0, 100, 251, stored));
    const tried = await counting(() => fillHashWriteGroup(UTXO, own, group(100, 250), 0, 100, 251, stored));
    assert.deepEqual(tried.group, hashed.group);
    assert.equal(tried.hashed, hashed.hashed);
  } finally {
    forgetPrebuiltTrees('UTXO');
  }
});

test("another kind of tree's prebuilt one is never used", async () => {
  usePrebuiltTree('TXID', 0, parseTree(treeFile(leaves)));
  try {
    const hashed = await counting(() => own(group(0, 250), 0, 0, 251, stored));
    const tried = await counting(() => fillHashWriteGroup(UTXO, own, group(0, 250), 0, 0, 251, stored));
    assert.equal(tried.hashed, hashed.hashed);
  } finally {
    forgetPrebuiltTrees('TXID');
  }
});
