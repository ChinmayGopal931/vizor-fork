// Records fixture.json: the squid's transactions #4180 to #4199, around the break, as the SDK selects them, and the
// hashes the wallet's engine expects for #4188 on (its calculateRailgunTransactionVerificationHash, chained from
// #4187). Needs `npm ci --ignore-scripts` in android/railgun-web, for the engine: `node test/record-fixture.mjs`.
import { writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../../../android/railgun-web/package.json', import.meta.url));
const { calculateRailgunTransactionVerificationHash } = require('@railgun-community/engine');

const SQUID = 'https://rail-squid.squids.live/squid-railgun-eth-sepolia-v2/graphql';
const FIRST = 4180;
const COUNT = 20;
const BREAK = 4188;
const FIELDS = `id nullifiers commitments transactionHash boundParamsHash blockNumber utxoTreeIn utxoTreeOut
  utxoBatchStartPositionOut hasUnshield unshieldToken { tokenType tokenSubID tokenAddress } unshieldToAddress
  unshieldValue blockTimestamp verificationHash`;

const response = await fetch(SQUID, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: `{ transactions(orderBy: id_ASC, offset: ${FIRST}, limit: ${COUNT}) { ${FIELDS} } }` }),
});
const { transactions } = (await response.json()).data;

const repaired = {};
let previous = transactions[BREAK - 1 - FIRST].verificationHash;
for (const transaction of transactions.slice(BREAK - FIRST)) {
  previous = calculateRailgunTransactionVerificationHash(previous, transaction.nullifiers[0]);
  repaired[transaction.id] = previous;
}
const fixture = { source: SQUID, first: FIRST, break: BREAK, transactions, repaired };
await writeFile(new URL('fixture.json', import.meta.url), `${JSON.stringify(fixture, null, 2)}\n`);
console.log(`recorded #${FIRST} to #${FIRST + transactions.length - 1}, ${Object.keys(repaired).length} repaired`);
