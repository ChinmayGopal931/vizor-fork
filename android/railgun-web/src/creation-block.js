// A Railgun wallet made from a seed Veylor generated can't own a note from before that seed existed, so the engine
// skips decrypting the leaves before its creation block. Only decryption: the trees, and every request a sync makes,
// stay the same for every wallet, and the leaves stay stored for a rescan or another wallet. A restored seed has no
// creation block, since its wallet may have been used before.
import { NetworkName } from '@railgun-community/shared-models';
import { mainnetBlockAtOrBefore } from './block-times.js';

/**
 * How long before its seed was made a wallet's scans start: the two chains' times, and the rounding down to a table
 * entry on either side, are never late by this much.
 */
export const CREATION_MARGIN_S = 24 * 60 * 60;

/**
 * The block `networkName`'s wallet decrypts from when its seed was made at `createdAt`, a Unix time no later than
 * that: a block of the shipped table, rounded down, a day early. Undefined without a time or a table, which only
 * Ethereum mainnet has; the wallet then decrypts every leaf.
 */
export function creationBlock(networkName, createdAt) {
  if (networkName !== NetworkName.Ethereum || !Number.isSafeInteger(createdAt) || createdAt <= 0) return undefined;
  return mainnetBlockAtOrBefore(createdAt - CREATION_MARGIN_S);
}
