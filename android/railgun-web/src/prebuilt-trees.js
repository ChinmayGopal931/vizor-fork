// Anon's archive publishes Railgun's merkle trees prebuilt: every finalized tree, and the active ones as of its last
// sealed chunk. The engine hashes every parent of every leaf it inserts (Poseidon, minutes on a phone). With a prebuilt
// tree whose root Railgun's contract (notes) or the screening node (txids) accepts, a parent whose every leaf the
// engine is inserting now, equal to the prebuilt tree's, is copied instead. Every other parent is hashed as before, so
// each root the engine checks along the way is still its own. The build (engine-hooks-plugin.mjs) has the engine's
// merkletrees fill their parents through `fillHashWriteGroup` here.
import { Merkletree } from '@railgun-community/engine';
import { ArchiveUnavailable } from './archive.js';

export const TREE_DEPTH = 16;
const TREE_FORMAT = 1;

const toHex = (bytes) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
const word = (value) => (value.startsWith('0x') ? value.slice(2) : value).toLowerCase().padStart(64, '0');

/**
 * A tree file: a u16 format, a u64 big-endian leaf count, then every level of 32-byte nodes, the leaves first and the
 * root last. `node(level, index)` is 64 hex digits, undefined past the level's end.
 */
export function parseTree(bytes) {
  if (bytes.length < 10) throw new ArchiveUnavailable('a tree file is cut short');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint16(0) !== TREE_FORMAT) throw new ArchiveUnavailable('a tree file has an unknown format');
  const leafCount = Number(view.getBigUint64(2));
  const levels = [];
  let offset = 10;
  for (let level = 0, count = leafCount; level <= TREE_DEPTH; level += 1, count = Math.ceil(count / 2)) {
    levels.push({ offset, count });
    offset += count * 32;
  }
  if (leafCount === 0 || leafCount > 2 ** TREE_DEPTH || offset !== bytes.length) {
    throw new ArchiveUnavailable('a tree file is not a tree');
  }
  const node = (level, index) => {
    const { offset: at, count } = levels[level];
    return index < count ? toHex(bytes.subarray(at + index * 32, at + index * 32 + 32)) : undefined;
  };
  return { leafCount, node, root: node(TREE_DEPTH, 0) };
}

// By merkletree type (the engine's `merkletreeType`, UTXO or TXID) and tree number.
const prebuilt = new Map();
const key = (type, tree) => `${type}:${tree}`;

/** Copies parents from `parsed` into `type`'s tree `tree` until `forgetPrebuiltTrees(type)`. */
export function usePrebuiltTree(type, tree, parsed) {
  prebuilt.set(key(type, tree), parsed);
}

export function forgetPrebuiltTrees(type) {
  for (const name of [...prebuilt.keys()]) if (name.startsWith(`${type}:`)) prebuilt.delete(name);
}

/**
 * The engine's `Merkletree.fillHashWriteGroup(group, tree, startIndex, endIndex, lookup)` for `merkletree`, `own`
 * being the engine's own. The engine's two callers disagree on `endIndex`: insertLeaves passes the index after its last
 * leaf, rebuildAndWriteTree its last leaf. So the leaves present say where the group ends.
 */
export function fillHashWriteGroup(merkletree, own, group, tree, startIndex, endIndex, lookup) {
  const candidate = prebuilt.get(key(merkletree.merkletreeType, tree));
  const leaves = group[0] ?? [];
  const lastLeaf = leaves[endIndex] !== undefined ? endIndex : endIndex - 1;
  const covered = candidate === undefined ? -1 : Math.min(lastLeaf, candidate.leafCount - 1);
  if (covered < startIndex || !matches(candidate, leaves, startIndex, covered)) {
    return own(group, tree, startIndex, endIndex, lookup);
  }
  return fill(candidate, group, startIndex, endIndex, covered, lookup);
}

function matches(candidate, leaves, from, to) {
  for (let index = from; index <= to; index += 1) {
    if (leaves[index] === undefined || word(leaves[index]) !== candidate.node(0, index)) return false;
  }
  return true;
}

// The engine's loop, pair by pair up the levels. A parent whose leaves all lie in [startIndex, covered] is the
// prebuilt tree's; any other is hashed from its children, the group's or the stored ones.
async function fill(candidate, group, startIndex, endIndex, covered, lookup) {
  let start = startIndex;
  let end = endIndex;
  for (let level = 0; level < TREE_DEPTH; level += 1) {
    group[level] = group[level] ?? [];
    group[level + 1] = group[level + 1] ?? [];
    for (let index = start; index <= end + 1; index += 2) {
      const left = index % 2 === 0 ? index : index - 1;
      const parent = left >> 1;
      const first = parent << (level + 1);
      const last = ((parent + 1) << (level + 1)) - 1;
      group[level + 1][parent] =
        first >= startIndex && last <= covered
          ? candidate.node(level + 1, parent)
          : Merkletree.hashLeftRight(
              group[level][left] || (await lookup(level, left)),
              group[level][left + 1] || (await lookup(level, left + 1)),
            );
    }
    start >>= 1;
    end >>= 1;
  }
  return group;
}

/**
 * The prebuilt trees the archive's `manifest` names for `type` (`utxo` or `txid`) that the engine's `merkletree` hasn't
 * finished, read with `reader` and each used once `rootAccepted(tree, index, root)` (Railgun's contract, or the
 * screening node) accepts its root. A tree whose file or root fails is left to the engine's own hashing. Answers how
 * many it uses.
 */
export async function usePrebuiltTrees({ reader, manifest, type, merkletree, rootAccepted }) {
  const snapshot = manifest.treeSnapshot;
  if (snapshot?.treeDepth !== TREE_DEPTH) return 0;
  const wanted = [
    ...(snapshot.finalized?.[type] ?? []).map((entry) => ({
      ...entry,
      path: `chunks/${entry.chunkId}/tree-${type}-${entry.tree}.bin.gz`,
      checksum: undefined,
    })),
    ...(snapshot.active?.[type] ? [{ ...snapshot.active[type], path: `tip/tree-${type}-active.bin.gz?v=${manifest.tipChecksum}` }] : []),
  ];
  let used = 0;
  for (const entry of wanted) {
    if ((await merkletree.getTreeLength(entry.tree)) >= entry.leafCount) continue;
    try {
      const parsed = parseTree(await reader.tree(entry.path, entry.checksum));
      if (parsed.leafCount !== entry.leafCount || parsed.root !== word(entry.root)) {
        throw new ArchiveUnavailable(`the ${type} tree ${entry.tree} file is not the one the manifest names`);
      }
      if ((await rootAccepted(entry.tree, entry.leafCount - 1, parsed.root)) !== true) {
        throw new ArchiveUnavailable(`the ${type} tree ${entry.tree} root was refused`);
      }
      usePrebuiltTree(merkletree.merkletreeType, entry.tree, parsed);
      used += 1;
    } catch {
      // That tree is hashed by the engine, as without the archive.
    }
  }
  return used;
}
