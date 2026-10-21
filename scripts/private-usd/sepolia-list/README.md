# Railgun's Sepolia transaction list, repaired

A relay to Railgun's Sepolia indexer (the squid, `https://rail-squid.squids.live/squid-railgun-eth-sepolia-v2/graphql`)
that serves its transaction list with the verificationHash chain repaired, at
`https://railgun-sepolia-list.pepeman931.workers.dev/graphql` from the owner's Cloudflare account (Worker
`railgun-sepolia-list`). The Private USD page's build points the SDK's Sepolia queries at it
(`android/railgun-web/sepolia-list-plugin.mjs`); every other network still goes to the squid.

**Why.** The squid's chain breaks at #4188 (block 11816741): its hash there doesn't follow from #4187's, and every
later hash follows from that wrong one. The wallet's engine checks hash[n] = keccak256(hash[n-1] || firstNullifier[n])
as it syncs the list, so it stops at #4188 and never gets past it. It then can't prove a relayed send made after
#4188, and that send's change stays unspendable. The transactions themselves are right.

**What changes.** Only the verificationHash of each transaction from #4188 on, recomputed from #4187's. Every other
byte of the squid's answer, and every other query (the quick sync's events among them), goes through as it was. The
break is found by the squid's id for #4188, and the transaction before it must be #4187 with the hash the chain from
#0 reaches there (both pinned in `repair.js`); a list that disagrees is passed on untouched. A page of the SDK's sync
that holds #4187 is repaired from itself; any other answer past the break takes one extra query, for the first
nullifiers from the break to the page's first id (or through a filtered list's last). The `X-Verification-Hashes`
header says what was done: `repaired N`, `nothing to repair`, `intact` (the squid's hashes were already right), or
`unrepaired: <why>`.

**Trust.** The repaired hashes follow from the transactions and #4187's hash alone. `verify.mjs` checks a list the way
the wallet uses it, read through the SDK's own GraphQL client: the engine must accept every hash from index 0, and the
engine's txid merkletree built from the list must have the root the screening node (`ppoi.fdi.network`) validated at
its validated index. That root depends on the transactions, not on their hashes, so it shows the list is the one the
screening node validated, byte for byte.

**Privacy.** The Worker logs nothing and keeps nothing: no `console` calls, no storage, no cache, and no
`observability` block, so wrangler keeps Workers Logs off. A request reaches the squid without the requester's headers,
with the URL the SDK's client writes into the body set back to the squid's, so the squid sees the query as the SDK
sends it there directly. Don't `wrangler tail` it: a tail streams each request's headers and IP address.

**CPU.** A list past the break costs a keccak per transaction since the break, and the list grows by about 19 a day.
The free plan's limit is 10 ms per request; if requests start failing with error 1102, move the Worker to the paid
plan.

## Test, verify, deploy

Run from this directory after `npm ci` (which also installs the pinned wrangler), and `npm ci --ignore-scripts` in
`android/railgun-web` for `verify.mjs`, which loads the SDK and the engine from there.

1. Unit tests: `npm test`. They run against `test/fixture.json`, the squid's #4180 to #4199 with the hashes the engine
   expects (`node test/record-fixture.mjs` records it again).

2. Locally: `npx wrangler dev`, then `node verify.mjs http://127.0.0.1:8787/graphql`.

3. Deploy (wrangler logged in to the owner's account): `npx wrangler deploy`.

4. Check the live list end to end: `node verify.mjs`.

If the list's host ever changes, it must change everywhere the page's hosts are listed: the Kotlin and Swift
`RailgunEndpoints`, the Rust bridge's `RAILGUN_PAGE_HOSTS`, the page's CSP, and `SEPOLIA_LIST` in the page's build.
Once the squid's chain is right again (the header says `intact`), drop the page's rewrite and this Worker.
