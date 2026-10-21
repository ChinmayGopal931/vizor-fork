// Checks a Sepolia transaction list the way the wallet uses it. The list at the URL (the deployed Worker by default, or
// `wrangler dev`'s) is read through the SDK's own GraphQL client, with Sepolia's endpoint pointed at it as the page's
// build points it, and then:
//   1. every transaction must pass the engine's verificationHash check, chained from the first as the engine chains it;
//   2. the engine's txid merkletree, built from the list, must have at the screening node's validated index the root
//      the node validated there (its ppoi_node_status).
// Needs `npm ci --ignore-scripts` in android/railgun-web, for the SDK and the engine: `node verify.mjs [url]`.
import { createRequire } from 'node:module';
import path from 'node:path';

const LIST = process.argv[2] ?? 'https://railgun-sepolia-list.pepeman931.workers.dev/graphql';
const SQUID = 'https://rail-squid.squids.live/squid-railgun-eth-sepolia-v2/graphql';
const POI_NODE = 'https://ppoi.fdi.network';

const require = createRequire(new URL('../../../android/railgun-web/package.json', import.meta.url));
const Module = require('node:module');
const compile = Module.prototype._compile;
Module.prototype._compile = function (content, filename) {
  const client = /@railgun-community[\\/]wallet[\\/].*[\\/]graphql[\\/]index\.js$/.test(filename);
  return compile.call(this, client ? content.replaceAll(SQUID, LIST) : content, filename);
};

const { AbstractIterator, AbstractLevelDOWN } = require('abstract-leveldown');
const engine = require('@railgun-community/engine');
const { quickSyncRailgunTransactionsV2 } = require('@railgun-community/wallet');
const { NETWORK_CONFIG, NetworkName, TXIDVersion } = require('@railgun-community/shared-models');
const dist = path.dirname(require.resolve('@railgun-community/engine'));
const { TXIDMerkletree } = require(path.join(dist, 'merkletree/txid-merkletree.js'));
const { initPoseidonPromise } = require(path.join(dist, 'utils/poseidon.js'));

/** An in-memory LevelDB store for the engine's Database: sorted keys, enough for a merkletree. */
class MemoryStore extends AbstractLevelDOWN {
  entries = new Map();

  _get(key, _options, callback) {
    if (!this.entries.has(key)) return this._nextTick(callback, new Error('NotFound'));
    this._nextTick(callback, null, this.entries.get(key));
  }

  _put(key, value, _options, callback) {
    this.entries.set(key, value);
    this._nextTick(callback);
  }

  _del(key, _options, callback) {
    this.entries.delete(key);
    this._nextTick(callback);
  }

  _batch(operations, _options, callback) {
    for (const { type, key, value } of operations) {
      if (type === 'put') this.entries.set(key, value);
      else this.entries.delete(key);
    }
    this._nextTick(callback);
  }

  _iterator(options) {
    return new MemoryIterator(this, options);
  }
}

class MemoryIterator extends AbstractIterator {
  constructor(store, { gt, gte, lt, lte, reverse, limit }) {
    super(store);
    const keys = [...store.entries.keys()]
      .filter((key) => !(key <= gt) && !(key < gte) && !(key >= lt) && !(key > lte))
      .sort();
    if (reverse) keys.reverse();
    this.keys = limit >= 0 ? keys.slice(0, limit) : keys;
    this.store = store;
  }

  _next(callback) {
    const key = this.keys.shift();
    if (key === undefined) return this._nextTick(callback);
    this._nextTick(callback, null, key, this.store.entries.get(key));
  }
}

const { chain } = NETWORK_CONFIG[NetworkName.EthereumSepolia];
console.log(`list: ${LIST}`);
const transactions = await quickSyncRailgunTransactionsV2(chain, undefined);
console.log(`transactions: ${transactions.length} (index 0 to ${transactions.length - 1})`);

let previous;
let broken = -1;
for (const [index, transaction] of transactions.entries()) {
  const expected = engine.calculateRailgunTransactionVerificationHash(previous, transaction.nullifiers[0]);
  if (expected !== transaction.verificationHash) {
    broken = index;
    break;
  }
  previous = expected;
}
console.log(
  broken < 0
    ? 'verification hashes: the engine accepts every one, chained from index 0'
    : `verification hashes: the engine stops at index ${broken} (${transactions[broken].graphID})`,
);

const status = await fetch(POI_NODE, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', method: 'ppoi_node_status', params: {}, id: 1 }),
});
const { validatedTxidIndex, validatedMerkleroot } = (await status.json()).result.forNetwork.Ethereum_Sepolia.txidStatus;

await initPoseidonPromise;
const tree = await TXIDMerkletree.createForWallet(
  new engine.Database(new MemoryStore()),
  chain,
  TXIDVersion.V2_PoseidonMerkle,
  async () => true,
);
// As the engine queues a sync's transactions: no further than the validated index.
await tree.queueRailgunTransactions(transactions.map(engine.createRailgunTransactionWithHash), validatedTxidIndex);
await tree.updateTreesFromWriteQueue();
const latest = await tree.getLatestTreeAndIndex();
const root = (await tree.getRoot(0)).replace(/^0x/, '').toLowerCase();
console.log(`txid merkletree root at index ${latest.index} (the engine, from the list): ${root}`);
console.log(`validatedMerkleroot at index ${validatedTxidIndex} (the screening node):    ${validatedMerkleroot}`);
const matches = latest.tree === 0 && latest.index === validatedTxidIndex && root === validatedMerkleroot.toLowerCase();
console.log(matches ? 'roots match' : 'ROOTS DIFFER');
process.exitCode = broken < 0 && matches ? 0 : 1;
