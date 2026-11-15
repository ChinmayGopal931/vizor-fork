// Railgun's indexer (rail-squid) through the SDK's own GraphQL client, for the page's quick sync: the same three
// queries the SDK's quick sync sends, from the same block, so the indexer sees what it saw before.
import { NetworkName } from '@railgun-community/shared-models';
// The SDK's package exports none of its quick-sync modules.
import {
  getMeshOptions,
  getSdk,
} from '../node_modules/@railgun-community/wallet/dist/services/railgun/quick-sync/V2/graphql/index.js';

// Required, not imported: an import would bundle the package's ES build beside the CommonJS one the SDK requires.
const { getMesh } = require('@graphql-mesh/runtime');

const SOURCES = { [NetworkName.Ethereum]: 'ethereum', [NetworkName.EthereumSepolia]: 'sepolia' };

/** The indexer's event lists for `networkName`: each query answers up to 10,000 events from a block on, in order. */
export function squidQueries(networkName) {
  const source = SOURCES[networkName];
  if (source === undefined) throw new Error(`no indexer for ${networkName}`);
  let client;
  const sdk = () => {
    client ??= connect(source).catch((error) => {
      client = undefined;
      throw error;
    });
    return client;
  };
  const query = (name, list) => async (block) => (await (await sdk())[name]({ blockNumber: String(block) }))[list];
  return {
    nullifiers: query('Nullifiers', 'nullifiers'),
    unshields: query('Unshields', 'unshields'),
    commitments: query('Commitments', 'commitments'),
  };
}

// As the SDK builds its client: its mesh with this network's source alone.
async function connect(source) {
  const options = await getMeshOptions();
  options.sources = options.sources.filter(({ name }) => name === source);
  if (options.sources.length !== 1) throw new Error(`the SDK has no ${source} indexer`);
  const { sdkRequesterFactory } = await getMesh(options);
  const requester = sdkRequesterFactory();
  return getSdk((...args) => requester(...args));
}
