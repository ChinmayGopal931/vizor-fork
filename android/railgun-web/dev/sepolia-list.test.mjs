import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { test } from 'node:test';
import vm from 'node:vm';
import { SEPOLIA_LIST, SEPOLIA_SQUID, throughSepoliaList } from '../sepolia-list-plugin.mjs';

const require = createRequire(import.meta.url);
// The SDK's two GraphQL clients, which its package doesn't export: the txid list's and the quick sync's.
const RAILGUN = path.join(path.dirname(require.resolve('@railgun-community/wallet')), 'services/railgun');
const CLIENTS = [
  path.join(RAILGUN, 'railgun-txids/graphql/index.js'),
  path.join(RAILGUN, 'quick-sync/V2/graphql/index.js'),
];
const SQUIDS = /https:\/\/rail-squid\.squids\.live\/[\w-]+\/graphql/g;

/** Each source's network name and endpoint, from the client's own mesh options. */
async function endpoints(file, source) {
  const module = { exports: {} };
  const parameters = ['exports', 'require', 'module', '__filename', '__dirname'];
  const load = vm.compileFunction(source, parameters, { filename: file });
  load(module.exports, createRequire(file), module, file, path.dirname(file));
  const { sources } = await module.exports.getMeshOptions();
  return Object.fromEntries(sources.map(({ name, handler }) => [name, handler.config.endpoint]));
}

test("only Sepolia's URL is rewritten, once in each of the SDK's clients", async () => {
  for (const file of CLIENTS) {
    const source = readFileSync(file, 'utf8');
    const built = throughSepoliaList(source);
    assert.equal(built, source.replace(`"${SEPOLIA_SQUID}"`, `"${SEPOLIA_LIST}"`), file);
    assert.ok(!built.includes(SEPOLIA_SQUID), file);
    assert.equal(built.split(SEPOLIA_LIST).length, 2, file);
    // Railgun's indexer keeps every other network: mainnet, BNB Chain, Polygon and Arbitrum.
    const others = source.match(SQUIDS).filter((url) => url !== SEPOLIA_SQUID);
    assert.equal(others.length, 4, file);
    assert.deepEqual(built.match(SQUIDS), others, file);
    assert.ok(others.includes('https://rail-squid.squids.live/squid-railgun-ethereum-v2/graphql'), file);

    const before = await endpoints(file, source);
    const after = await endpoints(file, built);
    const sepolia = Object.keys(before).find((name) => before[name] === SEPOLIA_SQUID);
    assert.ok(sepolia, file);
    assert.deepEqual(after, { ...before, [sepolia]: SEPOLIA_LIST }, file);
  }
});

test("a client that doesn't name Sepolia's URL exactly once is refused", () => {
  const source = readFileSync(CLIENTS[0], 'utf8');
  assert.throws(() => throughSepoliaList(source.replace(SEPOLIA_SQUID, 'https://example.com/graphql')), /changed/);
  assert.throws(() => throughSepoliaList(`${source}\n"${SEPOLIA_SQUID}";`), /changed/);
});
