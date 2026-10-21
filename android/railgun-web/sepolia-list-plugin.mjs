// Points the Railgun SDK's Sepolia queries at our copy of Railgun's Sepolia transaction list, which repairs the
// verificationHash chain Railgun's indexer breaks at #4188 and relays everything else as it is
// (scripts/private-usd/sepolia-list/). The SDK names its indexer's URL in its two GraphQL clients, the txid list's and
// the quick sync's, with no setting, so the build rewrites exactly Sepolia's URL in both; every other network's stays.
import { readFile } from 'node:fs/promises';

export const SEPOLIA_SQUID = 'https://rail-squid.squids.live/squid-railgun-eth-sepolia-v2/graphql';
export const SEPOLIA_LIST = 'https://railgun-sepolia-list.pepeman931.workers.dev/graphql';

// The txid list's client and the quick sync's; V3's names no Sepolia URL.
const CLIENTS =
  /[\\/]wallet[\\/]dist[\\/]services[\\/]railgun[\\/](railgun-txids|quick-sync[\\/]V2)[\\/]graphql[\\/]index\.js$/;
const ENDPOINT = JSON.stringify(SEPOLIA_SQUID);

/** A client's source with Sepolia's endpoint on our list; it throws unless the source names that endpoint once. */
export function throughSepoliaList(source) {
  if (source.split(ENDPOINT).length !== 2) {
    throw new Error(`the SDK's GraphQL client changed: it should name ${ENDPOINT} once`);
  }
  return source.replace(ENDPOINT, JSON.stringify(SEPOLIA_LIST));
}

export const sepoliaList = {
  name: 'sepolia-list',
  setup(build) {
    const rewritten = new Set();
    build.onLoad({ filter: CLIENTS }, async (args) => {
      const contents = throughSepoliaList(await readFile(args.path, 'utf8'));
      rewritten.add(args.path);
      return { contents, loader: 'js' };
    });
    // A bundle with a client this didn't reach would sync Sepolia from the broken list.
    build.onEnd(() =>
      rewritten.size === 2
        ? undefined
        : { errors: [{ text: "the SDK's two GraphQL clients were not both bundled through the Sepolia list" }] },
    );
  },
};
