import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { SEPOLIA_LIST, SEPOLIA_SQUID } from '../sepolia-list-plugin.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const read = (file) => readFileSync(path.join(here, file), 'utf8');
// The SDK's GraphQL clients, which name each network's indexer: the page's quick sync and txid list ask these.
const mesh = read('../node_modules/@railgun-community/wallet/dist/services/railgun/quick-sync/V2/graphql/index.js');
// Rust's pins, mainnet's deployment first, as deployment.rs lists them.
const pins = [...read('../../../rust/src/wallet/private_usd/deployment.rs').matchAll(/railgun_indexer_url: "([^"]+)"/g)];

test("Rust reads Railgun's head from the indexer the page syncs from, on each network", () => {
  const [mainnet, testnet] = pins.map(([, url]) => url);
  assert.equal(pins.length, 2);
  assert.ok(mesh.includes(`"endpoint": "${mainnet}"`), `the SDK's own Ethereum indexer, not ${mainnet}`);
  assert.match(mainnet, /ethereum/);
  assert.equal(testnet, SEPOLIA_LIST, "the page's mended copy of Sepolia's indexer");
  assert.ok(mesh.includes(`"endpoint": "${SEPOLIA_SQUID}"`), "which the build puts in place of the SDK's");
});
