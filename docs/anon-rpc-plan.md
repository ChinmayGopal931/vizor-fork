# Anon-RPC for Private USD: Tier 1 plan (ETHGlobal Mumbai, 2026-11-05 to 2026-11-07)

**Goal.** Every Ethereum JSON-RPC request Veylor makes goes through
[anon-rpc](https://ethereum.github.io/anon-rpc/) by default: the Rust swap
engine's contract reads and the Railgun page's provider traffic alike. The
RPC provider sees a Tor exit (or a mixnet exit), never the phone's address,
and the code that anonymizes is a hash-pinned worker whose hash lives on
chain, not code Veylor ships. Nothing else about Private USD changes.

**Why this and not more.** The EF's Anon-RPC prize qualifies an app that
"routes its RPC reads through Anon-RPC by default" and scores how much
traffic goes through it, whether it works end to end, UX, shippability and
depth. No wallet ships anon-rpc yet (the adopters file says so), no mobile
host exists, and Veylor already makes every Ethereum read through one seam.
Tier 2 (a reusable Flutter plugin) and Tier 3 (a native Rust harness on
QuickJS) are out of scope for the hackathon and noted in §9.

**Deadline.** Submissions close Saturday 2026-11-07 at 09:00 IST. Only work
done during the hackathon is judged, and judges read the history: work on
`feature/anon-rpc`, commit per task, never squash.

**Eligibility (owner, before anything else).** ETHGlobal's rules make a team
that builds on pre-existing code ineligible for every partner prize unless it
is on an approved Continuity track. Register Veylor for the Continuity track
and disclose it in writing to ETHGlobal staff today. The EF prize page
confirms Mumbai has the track (its CROPS Upgrade prize is Continuity-only).

## 1. Status

- M0 plan: this file, 2026-11-05.
- M1 Rust: written 2026-11-05 (`rust/src/anon_rpc.rs`, `rust/src/api/anon_rpc.rs`,
  `RpcTransport` at every `EvmRpc` site, the union allowlist, the pins).
  `cargo check --tests` is clean and the ten new tests pass (the relay
  test's client needed a fix, see Deviations). The FRB bindings are
  regenerated.
- M2 page and native host: done 2026-11-05. `android/anon-rpc-web/` builds a
  61 KiB `anon.js` plus the sandbox page and `iframe-boot.js` into
  `assets/anon/`; the Kotlin host runs one page per kind, the anon handler
  is registered, the Railgun page's CSP and route admit the loopback relay
  (the rebuilt bundle changed only the three `index.html` copies), and the
  Kotlin unit tests pass (`AnonRpcBoundaryTest` added).
- M3 Dart: written 2026-11-05 (`lib/src/features/anon_rpc/`, the Settings
  row and sheet, the relay plumbing in `railgun_engine_provider.dart`).
  `fvm flutter analyze` is clean; the Private USD and Settings tests pass.
  Not yet run on a device.
- M4 device bring-up: blocked on the Galaxy A35 being attached (`adb
  devices` lists none).
- M5 submission: not started.

**Deviations.**

- D10 refined: the mode is also gated on the platform hosting the page.
  `anonRpcHostSupportedProvider` asks the anon handler `supported`; where
  nothing answers (iOS, desktop) Rust's mode is set off whatever is saved,
  the Settings row is hidden, and the Railgun page keeps direct providers.
  Without this an iOS build would fail every Ethereum request closed.
- The anon-rpc tests run on a multi-threaded tokio runtime: they block on a
  std channel while the relay task must keep running.
- hyper's HTTP/1 server treats a client half-close mid-request as the
  connection ending (`half_close` defaults to false), so the relay test's
  client sends `Connection: close` and reads to EOF instead of shutting
  down its write side. Chromium never half-closes first.
- `/android/anon-rpc-web/node_modules/` is ignored like the Railgun page's.
- `docs/private-usd-ios-plan.md` gained UI17: what the Swift host must add
  before the mode can be on there.

## 2. How to work

- Milestones in order, tasks within one in order. A milestone is done when
  its **Done when** list holds and `cd rust && cargo test`, `fvm flutter
  analyze` and `fvm flutter test` pass. Commit locally with the milestone in
  the message. Push only when the owner asks.
- Unit tests only for what guards funds, keys or the claim "every RPC read
  is anonymized": the fail-closed rule (§5), the loopback relay's refusals,
  and the host-list pins. The owner runs the suites at the end and inspects
  the build; no UI review here.
- When the code disagrees with this plan, follow the code, then fix the plan
  in the same commit.
- Never open `railgun.js`, the `.wasm` files or any `package-lock.json`.
  Grep with `--exclude-dir` or exclude `ios/Runner/Railgun/railgun` and
  `android/app/src/main/assets`.
- Never log a request's URL, headers or body: the RPC URL may carry a key.
  The rule from `routed_http.rs` applies to every new piece, the page's
  console lines included.

**Commands.**

| What | Command |
|---|---|
| Rust tests | `cd rust && CARGO_PROFILE_DEV_DEBUG=0 cargo test` |
| FRB bindings | `scripts/generate-rust-bridge.sh` after any `rust/src/api/*.rs` change |
| Dart | `fvm flutter analyze`; `fvm flutter test` |
| Anon page bundle | `cd android/anon-rpc-web && npm ci --ignore-scripts && npm run build` |
| Kotlin tests | `cd android && ./gradlew :app:testDebugUnitTest --tests 'com.keplr.vizor.railgun.*'` |
| Device (Galaxy A35) | `fvm flutter run -d RZCX40721QZ --dart-define=VIZOR_FORM_FACTOR=mobile --dart-define=VIZOR_PRIVATE_USD_ENABLED=true` |
| Worker logs on device | `log` events of the anon page in a debug build (`AnonRpcService` prints redacted status lines) |

## 3. What exists (before)

- The Rust engine reads the swap, Deposits and Railgun contracts through
  `EvmRpc<T: HttpTransport>` (`rust/src/wallet/private_usd/evm_rpc.rs`),
  always over `RoutedHttp` (`rust/src/wallet/routed_http.rs`): a direct
  connection, or an isolated Tor circuit when the user turned Tor on in
  Settings. Tor is off by default (`torEnabled = false`).
- The Railgun page (`android/railgun-web/`, a hidden WebView) builds ethers
  providers from `rpcUrls` (the build's keyed URL, then publicnode, or the
  user's own URL) and reaches them through the Rust loopback SOCKS5 bridge
  (`rust/src/railgun_bridge.rs`), which follows the same route. The page
  deletes `RTCPeerConnection` from its global scope (`src/shims.js`) so the
  SDK's dependencies cannot go around the proxy.
- So today the RPC provider sees the phone's address plus every deposit
  address, swap index and contract read, unless the user found the Tor
  switch. Privacy is a setting.

## 4. Design (after)

```
Rust swap engine ── EvmRpc over RpcTransport::Anon ──┐
                                                     ├─ anon_rpc::relay() ── FRB stream ─▶ Dart AnonRpcService
Railgun page ── ethers over http://127.0.0.1:P/ ─────┘   (loopback JSON-RPC relay, Rust)         │
                                                                                 MethodChannel com.zcash.wallet/anon_rpc
                                                                                                 ▼
                                                                      Kotlin: second hidden page, origin anon.appassets.androidplatform.net
                                                                                                 ▼
                                                                      anon page: @anon-rpc/browser-harness → hash-pinned worker
                                                                      (tor-js / Nox / Nym / passthrough) → KPS over WebRTC → gateway → Tor
```

Decisions, each with its reason:

- **D1. Rust is the one RPC gateway.** Every Ethereum request, the engine's
  and the page's, passes through `anon_rpc::relay` in Rust. One place proves
  the claim, counts the requests for the Settings row, and enforces the
  fail-closed rule. The page gets `rpcUrls: ['http://127.0.0.1:<port>/']`, a
  hyper HTTP/1 server on the loopback that forwards each POST body to the
  real RPC URL through the relay. Chromium's proxy override bypasses
  loopback implicitly, so these requests never touch the SOCKS bridge.
- **D2. The harness runs in a second hidden page, not the Railgun page.**
  KPS runs over WebRTC in a browser, and the Railgun page deletes WebRTC on
  purpose. Undoing that would let the SDK's dependencies around the proxy.
  The anon page has its own origin, CSP, allowlist and storage, and shares
  the Kotlin host class and the MessagePort protocol.
- **D3. Rust decides the mode, Dart only reports it.** `ANON_RPC_ENABLED`
  (default on) is set from the saved preference at startup and on toggle.
  While on, a request with no Dart subscriber, a page that is down or a
  worker that failed is refused as `route_blocked`, exactly like a Tor route
  that is starting: nothing ever falls back to a direct connection. Off
  restores today's `RoutedHttp` path.
- **D4. One worker per process, long-lived.** The anon page opens on the
  first request and stays while the Private USD engine runs in the
  foreground, unlocked. It closes on lock, on background, on a network
  change in Settings and with the engine. Tor's bootstrap costs seconds, so
  no idle close.
- **D5. Isolation keys.** The engine's reads carry
  `isolationKey = hex(keccak(process_salt || account_uuid))`, the page's
  reads one fixed key: tor-js builds a circuit per key, so two accounts'
  reads leave through independent exits. The key never leaves the device
  (tor-js keeps it local) and the salt is per process.
- **D6. Default network: tor-js.** Its specifier is on mainnet
  (`0x700dA3193D35fA54Cd3fBf29B66f2a2A0385659e`), its resolvers are jsDelivr,
  unpkg, raw.githubusercontent.com and a KPS resolver, and it needs a KPS
  gateway (`config.gateways`). Development uses the demo gateway
  `152.236.3.22:12298:uEiCH0VdbhryzJcMtCfB0vLA4sOvHdQ4hq5w7CopcwU59bQ`; the
  submission runs our own (`tor-js-gateway`, one Rust binary on one UDP
  port; owner deliverable O2). Nox (Sepolia specifier
  `0x35133267A8F7EC35046a83DCA0f4Ca8A6e1b7A9A`, dials KPS to its nodes) is
  offered on testnet builds. Nym's worker needs a transport we have not
  verified in a WebView behind the proxy; it ships only if it works on the
  device (M4.5). Passthrough (`0x4fd77be300f31c5fe6ab266d35d27750a3478d27`)
  is a debug option: it proves the sandbox and the hash check, not privacy.
- **D7. The bootstrap read is public.** The harness reads `workerHash()`
  and `workerResolvers()` once, through `preExisting.rpcProvider`: a plain
  fetch to publicnode (mainnet, or Sepolia for Nox) from the anon page. It
  carries nothing about the user. It goes through the SOCKS bridge when the
  Railgun page has set the proxy, directly otherwise.
- **D8. Excluded traffic, on purpose.** The screening nodes, Railgun's
  indexer, the proving artifacts, the maker, the relayer, the token issuer
  and lightwalletd are not JSON-RPC and keep today's route (Tor when on).
  The judges ask to be told; the README says it. The Settings check of a
  user-typed RPC URL (`PrivateUsdRpcChecker`) also stays direct in Tier 1:
  a one-time probe of a URL the user chose (M5 may route it too).
- **D9. Allowlists.** The bridge's allowlist becomes the union of the
  Railgun page's hosts and the anon page's (publicnode mainnet and Sepolia,
  `cdn.jsdelivr.net`, `unpkg.com`, `raw.githubusercontent.com`). The Rust
  pin test keeps the Railgun copies equal to `RAILGUN_PAGE_HOSTS` and gains a
  second pin: the Kotlin `AnonRpcEndpoints` and the anon page's CSP equal
  `ANON_RPC_PAGE_HOSTS`. The Railgun page's CSP and Kotlin route gain one
  loopback entry, `http://127.0.0.1:*`, for D1.
- **D10. iOS is out of scope for Tier 1.** The iOS Private USD port has not
  run on a device. The Swift host keeps compiling (its host list is pinned
  with Kotlin's and must stay equal), and the anon page's assets are not
  added to the Xcode project. The README states it.

## 5. Invariants

Each guards the submission's central claim or a secret. Keep them and the
tests that pin them.

- With the mode on, no Ethereum request leaves over a direct connection:
  a missing subscriber, a closed page or a failed worker refuses the request
  (`route_blocked`), never falls back. Pinned by a Rust test.
- The loopback relay binds `127.0.0.1` only, accepts `POST` only, caps the
  body at 1 MiB, forwards to the one target URL it was started with, and
  never logs a body or the URL. Pinned by a Rust test.
- The anon page reaches only its own assets and `ANON_RPC_PAGE_HOSTS`; the
  Railgun page reaches only its own assets, `RAILGUN_PAGE_HOSTS` and the
  loopback relay. Pinned by the host-list test.
- The RPC URL crosses Rust → Dart → Kotlin → page → worker. No layer logs
  it, prints it in an error, or stores it. `ApiAnonRpcRequest` has a
  redacted `Debug`.
- A mode change closes the Railgun page, whose `start` took the old
  `rpcUrls`, and the anon page's worker.
- The saved preference may be stricter than the enforced mode, never laxer:
  enabling writes before the runtime switch, disabling after it (the Tor
  rule, `networkPrivacyPersistedRouteIsSafe`).

## 6. Milestones

### M1. Rust: the gateway

Inputs: `rust/src/wallet/routed_http.rs`, `rust/src/wallet/private_usd/transport.rs`,
`swap.rs` (`transport(op)`, `SwapCall`), the `EvmRpc::new` sites in
`forward.rs`, `reverse.rs`, `deposits.rs`, `api/private_usd.rs`
(`send_settle_all`), `rust/src/api/sync.rs` (the `StreamSink` shape),
`rust/src/railgun_bridge.rs` (the pin test).

1. `rust/src/anon_rpc.rs`: `ANON_RPC_ENABLED` (AtomicBool, default true);
   the bridge statics (sink, pending map, next id, process salt);
   `relay(request, isolation_key, cancel) -> Result<RoutedResponse, RoutedError>`
   with the request's own timeout and the cancel flag; `respond(id, …)`,
   `fail(id, message)`, `disconnect()` failing every pending request;
   `isolation_key_for(account)`.
2. `AnonRpcTransport` and `enum RpcTransport { Routed, Anon }`, both
   `HttpTransport`. `swap::rpc_transport(op, account) -> RpcTransport` picks
   by mode. Every `EvmRpc::new(&transport, …)` site takes it; the maker,
   relayer and issuer clients keep `RoutedHttp`. Type aliases follow.
3. The loopback relay: `proxy_start(target_url) -> port`, `proxy_stop()`,
   hyper HTTP/1 on `127.0.0.1:0`, `POST` only, 1 MiB body cap, the page's
   fixed isolation key, `content-type: application/json` back. Enable
   hyper's `server` feature for every target in `rust/Cargo.toml`.
4. `rust/src/api/anon_rpc.rs`: `anon_rpc_set_enabled(bool)`,
   `anon_rpc_requests(sink: StreamSink<ApiAnonRpcRequest>)`,
   `anon_rpc_respond(id, status, headers, body)`, `anon_rpc_fail(id,
   message)`, `anon_rpc_disconnect()`, `anon_rpc_proxy_start(target_url)`,
   `anon_rpc_proxy_stop()`, `anon_rpc_stats()` (requests relayed, failed).
   Register the module, run `scripts/generate-rust-bridge.sh`.
5. Allowlists: `ANON_RPC_PAGE_HOSTS` in `deployment.rs`; the bridge allows
   the union; the pin test splits as D9 says and learns the loopback entry.
6. Tests: fail closed without a subscriber and with the mode on; a relayed
   request's answer reaches its caller and a late answer is dropped; the
   loopback relay refuses `GET` and an oversize body and forwards a `POST`
   to a scripted subscriber.

Done when: `cargo test` passes; `grep -rn "RoutedHttp" rust/src/wallet/private_usd/*.rs`
shows no `EvmRpc::new(&RoutedHttp…)` left outside tests.

### M2. The anon page and the Android host

Inputs: `android/railgun-web/{build.mjs,src/index.js,src/index.html}`,
`android/app/src/main/kotlin/com/keplr/vizor/railgun/*.kt`,
`MainActivity.kt` (the Railgun handler's registration), the browser
harness README (`iframeUrl`, `preExisting.rpcProvider`, `acceptLog`).

1. `android/anon-rpc-web/`: `package.json` (`@anon-rpc/browser-harness`
   0.4.0, esbuild), `build.mjs` writing `android/app/src/main/assets/anon/`:
   `index.html` (CSP: `default-src 'none'; script-src 'self'; worker-src
   blob:; frame-src 'self'; connect-src` the five anon hosts), `anon.js`,
   `sandbox.html` and the package's `iframe-boot.js`.
2. `src/index.js`: the Railgun page's MessagePort protocol with
   `INIT = 'vizor-anon-rpc-init'`; methods `start {specifier, chainId,
   bootstrapRpcUrl, config}`, `awaitReady {}`, `fetch {url, method, headers,
   bodyBase64, isolationKey, timeoutMs} -> {status, headers, bodyBase64}`,
   `status {}`, `stop {}`; events `status` and (debug) `log` from
   `acceptLog`. The bootstrap provider is a `fetch` of one JSON-RPC
   `eth_call` to `bootstrapRpcUrl`, throwing on a JSON-RPC error.
3. Kotlin: a `PageMethod` interface over `RailgunMethod` and a new
   `AnonRpcMethod` (`start` 2 min, `awaitReady` 5 min, `fetch` 2 min,
   `status` 10 s, `stop` 30 s); `RailgunChannel`/`RailgunProtocol` take
   `PageMethod`; `RailgunWebViewHost` keeps one page per kind
   (`RAILGUN`, `ANON`), each with its own origin, asset dir, allowlist and
   route table (`AnonRpcRequests`: own assets, `AnonRpcEndpoints`, `blob:`,
   `data:`); the Railgun route table admits `http://127.0.0.1:*`. Only the
   Railgun page sets the proxy override; closing it lifts the override as
   today.
4. `AnonRpcHostHandler` on `com.zcash.wallet/anon_rpc` and
   `com.zcash.wallet/anon_rpc/events` (`supported`, `load {debug}`, `call`,
   `close`, `isOpen`), registered in `MainActivity` beside the Railgun one.
5. The Railgun page: `connect-src` gains `http://127.0.0.1:*`; nothing else
   changes in the bundle. Rebuild it so the Android and iOS copies carry
   the new CSP (the pin test reads all three).
6. Swift: `RailgunEndpoints.swift` unchanged (the Railgun set is unchanged);
   note in `docs/private-usd-ios-plan.md` that the anon page and the
   loopback entry are Android-only until the iOS host gains them.

Done when: `npm run build` in both page projects; the Kotlin unit tests
pass; `cargo test` (the pin test) passes.

### M3. Dart: the service and the setting

Inputs: `lib/src/features/private_usd/services/railgun_host_channel.dart`,
`railgun_engine.dart` (lifecycle shape), `providers/railgun_engine_provider.dart`
(`rpcUrls`, the close triggers), `providers/private_usd_engine_provider.dart`,
`lib/src/providers/network_privacy_provider.dart` (the preference store
pattern), `mobile_settings_screen.dart` (`_EthereumRpcRow`, `_showThemeSheet`),
`lib/app.dart:1959` (`PrivateUsdEngineHost`).

1. `lib/src/features/anon_rpc/anon_rpc_network.dart`: `enum AnonRpcNetwork
   { tor, nox, nym, passthrough, off }` with specifier, bootstrap chain,
   label, availability per wallet network and debug-only flags, and the
   worker `config` (tor: `gateways`, `logLevel`).
2. `anon_rpc_settings_provider.dart`: `SharedPreferences` key
   `vizor_anon_rpc_network_v1`, default `tor`; `setNetwork` follows the
   stricter-first write order (§5), calls `anonRpcSetEnabled`, and closes
   both pages.
3. `anon_rpc_host_channel.dart`: `AnonRpcHost` over the new channel, the
   `RailgunHostChannel` shape and error codes.
4. `anon_rpc_service.dart`: subscribes to `anonRpcRequests()` while the
   engine is enabled, the app foreground and unlocked; serves each request
   (load page → `start` → `fetch`), answers with `anonRpcRespond` or
   `anonRpcFail`; `ValueNotifier<AnonRpcStatus>` (phase, network, requests
   relayed, last error code) for Settings; `disconnect` on pause so Rust
   fails closed at once. Registered with `privateUsdLifecycleProvider` like
   the Railgun engine. Mounted from `PrivateUsdEngineHost`.
5. Plumbing: the Railgun `start` params take
   `rpcUrls: ['http://127.0.0.1:$port/']` when the mode is on, with
   `anonRpcProxyStart(target)` (target = the user's URL, else the keyed one,
   else publicnode) and `anonRpcProxyStop()` with the page's close; the
   secrets list keeps the target. `railgunEngineProvider` closes the page
   on a mode change as it does for a route change.
6. Settings: an "Anonymous RPC" row in the Private USD group showing the
   network and the status ("Tor · ready", "Tor · connecting", "Off"), and a
   sheet with the options and a one-line description each; copy in
   `AnonRpcCopy`. Debug-only options (passthrough) appear in debug builds.
7. `fvm flutter analyze`; `fvm flutter test`.

Done when: a debug build on the phone shows the row, and toggling it closes
and reopens the pages (M4 verifies the traffic).

### M4. Device bring-up (Galaxy A35, testnet)

1. tor-js through the demo gateway: the anon page loads, the bundle's hash
   verifies, the worker reports ready, and the Private USD balance screen
   syncs with `rpcUrls` on the loopback relay. Record bootstrap time and
   per-request latency in §1.
2. The engine's reads: a forward quote's chain read and the deposits pass
   go through the relay (the stats counter rises; no `RoutedHttp` Ethereum
   request in a debug log line).
3. Fail closed: with the mode on and the anon page killed (`adb shell am
   kill` is too coarse; use the Settings toggle off → on while a sync
   runs), the engine reports a route problem and recovers when the page is
   back.
4. Off: everything behaves as before the branch.
5. Nox on testnet and Nym on mainnet: try each; keep what works, hide the
   rest behind debug.
6. A keyed RPC URL on the device: the URL appears in no log line (`adb
   logcat`, `run_device_round.sh --keyed-rpc`'s scan).

### M5. Submission

1. `README.md`: a short "Anonymous RPC" section with the before/after, and
   the required `CROPS` section (C, O, P, S, one or two lines each; O states
   the zecSwap stand-in honestly, see O3), plus the excluded traffic (D8)
   and the iOS note (D10).
2. The demo moment: a logging reverse proxy in front of publicnode on a host
   the owner controls, admitted by a debug-only define
   (`VIZOR_PRIVATE_USD_EXTRA_RPC_HOST`); the video flips the Settings row
   from Off to Tor and shows the source column change from the phone to Tor
   exits while a sync and a quote keep working, then shows the on-chain
   hash the bundle was checked against.
3. Our own gateway's address in the default config (O2), the demo gateway
   kept as a second entry.
4. Measurements for the write-up: bootstrap time, median request latency
   direct vs tor-js, bundle size, requests per sync.
5. Optional: open a PR to `adopters.json5` listing Veylor as the first
   wallet, on by default.

## 7. Owner deliverables

- **O1.** Continuity track registration and the written disclosure (today).
- **O2.** A VPS with a public UDP port for `tor-js-gateway` (and the
  logging proxy of M5.2). Without it the demo uses the public demo gateway,
  which the README then names as a known dependency.
- **O3.** A decision on the `[patch]` for zecSwap in `rust/Cargo.toml`: a
  clean clone does not build without the local checkout, which the CROPS
  "O" line must say, or the crates get vendored like
  `rust/vendor/zakura-client-backend`.
- **O4.** The 3-minute video, recorded on the phone.

## 8. Open questions, checked in M4

- WebRTC data channels inside an Android WebView while a SOCKS proxy
  override is in force (the override does not cover UDP; verify on device).
- The harness's `iframeUrl` sandbox page under `WebViewAssetLoader`: the
  frame is at an opaque origin and its `blob:` worker needs no CSP of its
  own. Verify `ready` settles.
- The loopback bypass of the proxy override (`127.0.0.1` is in Chromium's
  implicit bypass list; `removeImplicitRules()` is not called).
- tor-js bootstrap time on the A35 and whether its consensus cache (the
  harness's IndexedDB storage) survives a page close.
- Nym's worker transport behind the proxy; Nox's KPS dials to its nodes.

## 9. After the hackathon

- Tier 2: extract the anon page host into a Flutter plugin with a Kotlin
  and a Swift side so any Flutter wallet can take it.
- Tier 3: a native Rust harness on QuickJS with the `kps` crate over QUIC
  for workers without WebAssembly, and Veylor's own arti as a KPS gateway.
- iOS: the Swift host gains the second page and the loopback entry.
- Route the Settings RPC check and the Home price through the relay.

## 10. Source map

| Piece | Path |
|---|---|
| Rust gateway, relay, mode | `rust/src/anon_rpc.rs`, `rust/src/api/anon_rpc.rs` |
| Transport selection | `rust/src/wallet/private_usd/swap.rs` (`rpc_transport`), `transport.rs` (`RpcTransport`) |
| Allowlists and pins | `rust/src/wallet/private_usd/deployment.rs`, `rust/src/railgun_bridge.rs` |
| Anon page | `android/anon-rpc-web/`, built to `android/app/src/main/assets/anon/` |
| Android host | `android/app/src/main/kotlin/com/keplr/vizor/railgun/` (`AnonRpcHostHandler.kt`, `AnonRpcEndpoints.kt`, the generalized host) |
| Dart | `lib/src/features/anon_rpc/` |
| Settings row | `lib/src/features/settings/screens/mobile/mobile_settings_screen.dart` |
