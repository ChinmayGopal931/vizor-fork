# Railgun circuit artifact mirror

A read-only copy of the RAILGUN circuit artifacts (zkey, wasm, vkey) that the wallet SDK downloads before a
proof, served at `https://railgun-artifacts.pepeman931.workers.dev` from the owner's Cloudflare account (Worker
`railgun-artifacts`, static assets). The Private USD page downloads from `https://ipfs-lb.com`, the SDK's own
gateway, and falls back to this mirror when that fails (an HTTP or network error, or no answer within about 30 s).

**Why.** The SDK hard-codes `ipfs-lb.com` as its only gateway, with no setting and no fallback. On 2026-10-17 it
went down (Cloudflare 502 for everything), and a fresh install could not make its first proof. Railway and zapp
depend on the same gateway; Kohaku runs its own mirror. The owner chose a mirror the same day, as the fallback
behind ipfs-lb.com.

**Trust.** Availability only. The files are content-addressed, served at their IPFS paths
(`/ipfs/<hash>/...`), and the SDK checks every zkey and wasm against the hashes it ships
(`artifact-v2-hashes.json`, copied here) after decompressing it. It does not check the vkey; a wrong vkey can
only make a proof fail locally.

## Rebuild or refresh

Run from this directory. `files/` and `oversize/` are gitignored (about 1.06 GB).

1. Download and verify every file. Any IPFS gateway that serves the content works; Pinata did on 2026-10-17.
   A rerun skips files that already verify.

   ```bash
   node fetch-verify.mjs artifact-v2-hashes.json files https://gateway.pinata.cloud
   cp _headers files/_headers
   ```

2. Split any file over the 25 MiB static-asset limit into `.partN` files and list it in `worker/worker.js`
   (`SPLIT`). Today that is only the POI 13x13 zkey:

   ```bash
   P=files/ipfs/QmZrP9zaZw2LwErT2yA6VpMWm65UdToQiKj4DtStVsUJHr/POI_13x13
   mkdir -p oversize && mv $P/zkey.br oversize/POI_13x13-zkey.br
   split -b 20971520 -a 1 oversize/POI_13x13-zkey.br $P/zkey.br.part
   mv $P/zkey.br.parta $P/zkey.br.part0 && mv $P/zkey.br.partb $P/zkey.br.part1
   ```

3. Deploy (wrangler logged in to the owner's account): `cd worker && wrangler deploy`.

4. Check the live mirror end to end; this downloads everything again and verifies every hash:

   ```bash
   node fetch-verify.mjs artifact-v2-hashes.json /tmp/railgun-mirror-check https://railgun-artifacts.pepeman931.workers.dev
   ```

The Worker sends every request through `worker/worker.js` first: GET and HEAD go to the assets (`_headers` adds
CORS and immutable caching), a CORS preflight gets 204, `.partN` paths and anything outside `/ipfs/` get 404.

If the mirror's host ever changes, it must change everywhere the page's hosts are listed: the Kotlin and Swift
`RailgunEndpoints`, the Rust bridge's `RAILGUN_PAGE_HOSTS`, the page's CSP, and the page's artifact base URL.
