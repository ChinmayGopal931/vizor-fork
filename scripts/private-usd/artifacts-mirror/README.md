# Railgun circuit artifact mirror

A read-only copy of the RAILGUN circuit artifacts (zkey, wasm, vkey) that the wallet SDK downloads before a
proof, served at `https://railgun-artifacts.pepeman931.workers.dev` from the owner's Cloudflare account (Worker
`railgun-artifacts`, static assets). The Private USD page downloads from `https://ipfs-lb.com`, the SDK's own
gateway, and falls back to this mirror when that fails (an HTTP or network error, or nothing from it for 10 s).

**Why.** The SDK hard-codes `ipfs-lb.com` as its only gateway, with no setting and no fallback. While that
gateway is down, a fresh install cannot make its first proof.

**Trust.** Availability only. The files are content-addressed, served at their IPFS paths
(`/ipfs/<hash>/...`), and the SDK checks every zkey and wasm against the hashes it ships
(`artifact-v2-hashes.json`) after decompressing it. It does not check the vkey; a wrong vkey can only make a
proof fail locally.

**POI circuits.** Wallet 11.2.0 replaced the POI circuits; the POI nodes verify only proofs from the new ones
and answer the earlier ones' `Invalid proof`. Their directory (`QmZ2MyM6…`) resolves on no public gateway, only
its files do, so `fetch-verify.mjs` gets each by its own CID (`POI_FILE_CIDS`) and saves it at the path the SDK
asks for. Their vkeys are in `poi-v2/`, exported with snarkjs from the zkeys once those matched 11.2.0's hashes,
and equal to the ones railgun-rust embeds. The earlier POI directory (`QmZrP9…`, hashes in
`poi-nov-2-23-hashes.json`) stays for builds before 11.2.0.

## Rebuild or refresh

Run from this directory, after `npm ci --ignore-scripts` in `android/railgun-web`: the hashes are the ones the
SDK the page bundles ships. `files/` and `oversize/` are gitignored (about 1.1 GB).

```bash
HASHES=../../../android/railgun-web/node_modules/@railgun-community/wallet/dist/services/artifacts/json/artifact-v2-hashes.json
```

1. Download and verify every file. Any IPFS gateway that serves the content works, Filebase among them;
   Pinata can answer quick requests with a bot check. A rerun skips files that already verify.

   ```bash
   node fetch-verify.mjs "$HASHES" files https://ipfs.filebase.io
   cp _headers files/_headers
   ```

2. Split any file over the 25 MiB static-asset limit into `.partN` files and list it in `worker/worker.js`
   (`SPLIT`). Today that is the two POI 13x13 zkeys:

   ```bash
   P=files/ipfs/QmZrP9zaZw2LwErT2yA6VpMWm65UdToQiKj4DtStVsUJHr/POI_13x13
   mkdir -p oversize && mv $P/zkey.br oversize/POI_13x13-zkey.br
   split -b 20971520 -a 1 oversize/POI_13x13-zkey.br $P/zkey.br.part
   mv $P/zkey.br.parta $P/zkey.br.part0 && mv $P/zkey.br.partb $P/zkey.br.part1
   P=files/ipfs/QmZ2MyM6TKxffkv6stuo2hFwmUfs3q4xgMYN164Sje8new/circuits/13x13
   mv $P/zkey.br oversize/POI_13x13-v2-zkey.br
   split -b 20971520 -a 1 oversize/POI_13x13-v2-zkey.br $P/zkey.br.part
   mv $P/zkey.br.parta $P/zkey.br.part0 && mv $P/zkey.br.partb $P/zkey.br.part1
   ```

3. Deploy (wrangler logged in to the owner's account): `cd worker && wrangler deploy`.

4. Check the live mirror end to end at the paths the SDK asks for; this downloads everything again and verifies
   every hash, and every POI vkey against `poi-v2/`:

   ```bash
   node fetch-verify.mjs "$HASHES" /tmp/railgun-mirror-check https://railgun-artifacts.pepeman931.workers.dev --paths
   ```

The Worker sends every request through `worker/worker.js` first: GET and HEAD go to the assets (`_headers` adds
CORS and immutable caching), a CORS preflight gets 204, `.partN` paths and anything outside `/ipfs/` get 404.

If the mirror's host ever changes, it must change everywhere the page's hosts are listed: the Kotlin and Swift
`RailgunEndpoints`, the Rust bridge's `RAILGUN_PAGE_HOSTS`, the page's CSP, and the page's artifact base URL.
