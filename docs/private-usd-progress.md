# Private USD (Android): progress

Tracks `docs/private-usd-android-plan.md` §4. A task is done only when its line
is checked. Each milestone also has a gate line: acceptance met, tests written,
`cargo test` / `fvm flutter analyze` / `fvm flutter test` (and the mobile lane
for UI milestones) passing, and its Pitfalls re-read against the diff.

## M0. Prerequisites and spikes (go/no-go)

- [x] M0.1.0 Local patched zecSwap checkout (`~/dev/zapp/zecSwap-zakura`, §12 manifest and diff) and the `[patch]` in vizor
- [x] M0.1.1 `rust/Cargo.toml`: `zecswap-core`, `zecswap-railgun`, `hmac`, `sha3`, `bech32`; `rust-version = "1.92"`
- [ ] M0.1.1b `zecswap-tokens` resolves in vizor's graph (no-go today: `digest` conflict, Deviations D-1; needs an owner decision)
- [x] M0.1.2 `cargo build` and `cargo tree -d`: one `zakura-orchard`, one `zakura-pczt`, no upstream `orchard`/`pczt`/`zcash_protocol` (with `zecswap-core` + `zecswap-railgun`; build 5m20s)
- [x] M0.1.3 zecSwap's 16 library and 8 `tests/sweep.rs` tests on the Zakura build (24/24 pass; workspace narrowed, D-2)
- [x] M0.1.4 Debug APK build (`VIZOR_FORM_FACTOR=mobile`); record the `.so` size delta. Both builds pass on all four ABIs. Rust `.so` delta (spike over baseline): arm64 +0.47 MB (67.77 → 68.24 MB, +0.7%), armeabi-v7a +0.41 MB, x86_64 +0.44 MB. No vizor code calls the zecSwap crates yet, so the linker drops most of them; the real delta shows from M1 (re-measure in M8)
- [x] M0.2a Offline: a payment to an Orchard-only UA lands in the Ironwood bundle, and `sent_notes` records it (`output_pool` 4, `to_address` = the UA). Go on both checks (D-3)
- [ ] M0.2b The same on testnet (blocked: B-4, funded testnet ZEC)
- [x] M0.3.1 `connect_stream` patch in a local wallet-libraries checkout (`~/dev/wallet-libraries-e4`); all ten wallet-libraries refs repointed (spike branch)
- [x] M0.3.2 `rust/src/railgun_bridge.rs`, tokio I/O for `DirectRouteIo`, and the Rust FRB `start_railgun_bridge` / `stop_railgun_bridge` (spike branch). 8 tests pass, including an ignored one run once here that bootstraps real Tor and tunnels through the bridge to `ethereum-sepolia-rpc.publicnode.com:443` via the patched `connect_stream`
- [x] M0.3.2b Dart bindings for the bridge calls regenerated (spike branch; `startRailgunBridge()` → `Future<int>`)
- [x] M0.3.3 Minimal Kotlin host (org.json port) with the `ProxyController` override, plus `RailgunHostHandler` (the §6.2 channel contract) registered in `MainActivity`. Compiles and runs on the device (spike branch)
- [x] M0.3.4 On Sepolia, through the debug entrypoint `lib/railgun_spike_main.dart` (D-4) on the Galaxy A35: `start`, `openWallet` and `refresh`, with Tor on and off, a mid-sync route flip and a Tor failure. All five exit criteria hold except the proof half of criterion 1 (results below)
- [ ] M0.3.4b One `transfer` proof (not posted) (blocked: B-7, a funded Sepolia Railgun wallet)
- [x] M0.3.5 Measure first sync, peak memory and bytes; recorded in plan §11 (U10, U14, U19)
- [ ] M0.3.5b Proof time (`proofMs`) and proving-artifact bytes (blocked with M0.3.4b)
- [ ] M0 gate: go/no-go recorded for M0.1, M0.2 and M0.3; only the `rust-version` line lands

M0 status (2026-10-13).

- **M0.1:** go for `zecswap-core` and `zecswap-railgun`, no-go for `zecswap-tokens` (D-1).
- **M0.2:** go, verified offline.
- **M0.3 (D4, the Tor bridge):** go, pending the transfer proof (M0.3.4b).

M0.3 ran on a Samsung Galaxy A35 (SM-A356E; Android 16; WebView 155; user
build, bootloader locked) on Sepolia, with a fresh wallet and the page storage
wiped before each run:

| Exit criterion | Result |
|---|---|
| 1. Syncs (and proves) with Tor on | Sync: yes. First sync over Tor took 101 s and 136 s in two runs (direct: 96 s); Tor bootstrap 1–12 s. Proof: blocked (B-7). |
| 2. No direct socket while Tor is on | Yes. 26 samples across the Tor runs of the app UID's `/proc/net/tcp{,6}` during Tor syncs: zero connections to Railgun hosts; every other remote is a Tor relay (Onionoo). The same checker does see the direct connections in direct mode. |
| 3. A mid-sync route flip cancels cleanly | Yes. The in-flight `refresh` ended `CLOSED` 0.0 s after the close. A new bridge started on a new port, the same wallet reopened, and the sync resumed and finished direct in 68.5 s. |
| 4. With Tor failed, the page errors and never goes direct | Yes. After `fail_network_privacy_enable`, the page's open tunnels stayed on Tor. Close and stop ended the `refresh` (`CLOSED`), and a new bridge was refused ("Tor connection failed"). |
| 5. With Tor off, the page works through the direct path | Yes (96 s first sync). |

Other findings:

- **Screen-off freezes the app.** With the screen off, Android froze the app
  within about 60 s (`onFreezeStateChanged uid=10601`). The Tor circuits then
  died and the sync failed `Incomplete` (D-5). Runs with the screen on passed.
- **U19 answered:** Chromium keeps pooled sockets after the page closes and the
  proxy override is cleared (2–3 tunnels still open 10 s later). Restarting the
  bridge on every route change is required.
- **Wiping works:** `wipe` (WebStorage `deleteOrigin`) clears the page's
  IndexedDB (U12 path: `/data/data/com.keplr.vizor/app_webview`).
- **First sync bytes (Sepolia):** about 6.8 MB down, almost all from
  `rail-squid.squids.live`; RPC about 12 KB, POI about 6 KB.
- **Peak memory:** app PSS 446 MB (debug build), renderer PSS 382 MB.

On this branch's M0 commit (the `rust-version` line, the M0.2 test, docs),
`cd rust && cargo test` passes: lib 1430 passed, 0 failed, 9 ignored;
integration 6 passed, 21 ignored (regtest). After the toolchain install:
`fvm flutter analyze` finds no issues, and `fvm flutter test` (desktop lane)
gives 5896 passed, 158 skipped, 4 failed. The 4 failures are pre-existing on
`main`; this branch changes no Dart. They are in
`test/features/settings/settings_seed_phrase_screen_test.dart`, the "incoming
links cannot interrupt backup completion/deferral success/failure" cases, which
cannot find the `AppButton` "Enter amount" (test line 159). They fail the same
way when the file runs alone.

## M1. Rust foundations

- [x] M1.1 `rust/Cargo.toml` dependency lines (`zecswap-core`, `zecswap-railgun`, `hmac`, `sha3`, `bech32`; not `zecswap-tokens`, N1). Builds with the local `[patch]` (E1 pending; do not merge)
- [x] M1.2 `private_usd/mod.rs`: module tree and `PrivateUsdNetwork`
- [x] M1.3 `deployment.rs`: §7.1 pins and §7.2 constants, including the 2,000,000 fee cap. Token keys are string constants; their `TokenKey::from_base64` parse test waits for N1
- [x] M1.4 `railgun_keys.rs`: BIP-85 and the Railgun key chain (§3.3)
- [x] M1.5 `keys.rs`: `SwapKeyContext::open` (seed, ZIP-32 index, fingerprint check)
- [x] M1.6 `models.rs`: forward and reverse records in zapp's JSON shape
- [x] M1.7 `terms.rs`: forward and reverse terms, `terms_hash`, EIP-712
- [x] M1.8 `store.rs`: `swaps.db` schema and migrations, `take_index`, `save_record`, queries
- [x] M1.9 `indices.rs`: index allocation with on-chain skipping
- [x] M1.10 `rust/src/wallet/routed_http.rs` (§8.5)
- [ ] M1.10b Separate PR: Enhance PIR transport and voting `VizorRoute` onto `routed_http` (may slip to M8; not started in M1)
- [x] M1.11 `evm_rpc.rs`: every §5.4 read behind `ChainReader`
- [x] M1.12 `maker_client.rs` and `relayer_client.rs` behind `HttpTransport`
- [x] M1.13 `rust/src/api/private_usd.rs`: `ApiPrivateUsdError`, `ApiDeployment`, the five M1 calls; bridge regenerated
- [x] M1 gate

M1 status (2026-10-13): done except the optional M1.10b, which slips to M8.
Moving the PIR transport and voting's `VizorRoute` onto `routed_http` without
behaviour change needs streaming response bodies, the `on_dispatch` hook and
the SDK's observation phases in `routed_http`, so it is not a safe drop-in.

- **Rust:** `cd rust && cargo test` passes: lib 1447 passed, 0 failed, 9
  ignored; integration 6 passed, 21 ignored (regtest). The 17 new tests
  (`private_usd`, `routed_http`) cover the M1 **Done when** list: every §3.3
  and §5.5 vector (pinned in `private_usd/tests/vectors.json`, plus the §5.4
  selectors), address validation, `getSwap` decoding, a revert as closed, a
  wrong chain, store crash safety, strict decoding of every zapp
  `SwapRecordStorageTest` fixture, the counter across reopen, the 16-index
  cap, routed HTTP failing closed, and maker and relayer error classification
  against a local server.
- **Pre-existing test-isolation gap, not M1's:** the Gift Card test
  `settlement_requires_an_uncancelled_contiguous_agreed_observation` (and its
  `gift_card_input` neighbours) open direct lightwalletd connections without
  `lock_route_policy()`. When a route test flips Tor at the same moment, the
  test fails. It reproduces with the pre-existing voting route tests (6 of 8
  paired runs), and it failed once in a full run that overlapped
  `flutter test`. Alone it passes 5 of 5, and the clean full runs pass. The
  fix is for those tests to take the lock, as `network_privacy`'s
  `test_route_policy` asks.
- **Dart:** `fvm flutter analyze` finds no issues. `fvm flutter test`: 5896
  passed, 158 skipped, 4 failed, the 4 pre-existing failures in
  `settings_seed_phrase_screen_test.dart` ("incoming links cannot interrupt
  backup completion/deferral success/failure": the `AppButton` "Enter amount"
  finder at test line 159).
- **Bindings:** `lib/src/rust/api/private_usd.dart` is new. The codegen's
  rustc 1.93 noise was reverted: the comment-only changes in
  `network_privacy.dart`, `sync.dart`, `voting.dart`, `voting_session.dart`
  and `third_party/zcash_voting/wire.dart`, and the import-group blank lines
  it dropped in `frb_generated{,.io,.web}.dart`. The new file's
  ignored-trait comment uses the committed files' `assert_fields_are_eq`
  wording.

## M2. Zcash joint-account operations

- [x] M2.1 `private_usd/joint.rs` (`joint.db` operations)
- [x] M2.2 Discard OVK for joint sweeps (`SendPurpose::JointSweep`, `StoredProposal.purpose`)
- [x] M2.3 `propose_joint_sweep` in `send.rs`
- [x] M2.4 `sweep_joint` in `joint.rs`
- [x] M2.5 The deposit split in `send.rs`
- [x] M2.6 `find_deposit` and `swap_tx_status`
- [x] M2.7 Ignored Ironwood regtest test (written; compiles)
- [ ] M2.7b Run the Ironwood regtest test once (deferred to the batched E2E round; needs the owner's go-ahead; settles U4–U9)
- [x] M2 gate (the regtest run is M2.7b, deferred)

M2 status (2026-10-13): done except M2.7b, the regtest run, which waits for
the batched E2E round and the owner's go-ahead.

- **Rust:** `cd rust && cargo test` passes: lib 1451 passed, 0 failed, 10
  ignored; integration 6 passed, 21 ignored (regtest). The 4 new tests in
  `private_usd/tests/joint.rs` cover the M2 **Done when** list on real wallet
  DBs that scan synthetic compact blocks, with a local fake lightwalletd for
  the tip:
  - `a_swap_deposit_is_one_transaction_within_its_approved_total`: a total
    over the cap and a two-transaction (TEX) deposit are refused before
    anything is locked.
  - `a_stored_deposit_is_found_and_followed_until_it_expires`: the create
    half stores the deposit and sends nothing, and `find_deposit` finds it.
    `swap_tx_status` gives `Unmined` and `Unknown`, `Expired` only once the
    block after the expiry is scanned (never for an expiry of 0), then
    `Mined`.
  - `a_joint_sweep_pczt_discards_the_joint_ovk`: the sweep's one output does
    not recover under the joint OVKs, while an ordinary send's payment from
    the same account does.
  - `a_joint_sweep_over_its_fee_limit_is_refused_and_locks_nothing`.

  The Gift Card claim refusal test in `pczt.rs` now keys on purpose, and the
  gift-card PCZT and send tests pass unchanged. The ignored regtest test
  (`private_usd/tests/ironwood_regtest.rs`) compiles and was not run (M2.7b).
- **Dart:** `fvm flutter analyze` finds no issues. `fvm flutter test`: 5896
  passed, 158 skipped, 4 failed, the same 4 pre-existing failures in
  `settings_seed_phrase_screen_test.dart` (the `AppButton` "Enter amount"
  finder at test line 159). M2 changes no Dart.
- **API:** no `rust/src/api/` change, so the bindings were not regenerated.
- **U-items:** U7 is answered by reading. U6 and U8 are read and handled
  (D-10; plan §11). The unit tests create a PCZT for a spending account
  without derivation, the first half of U9. U4, U5 and the rest wait for
  M2.7b.

## M3. Railgun host, Tor bridge, availability and the read-only balance

- [x] M3.1 Bundle (§8.7 commands 1, 2, 5 and the `build.mjs` edit; zapp's bundle, no rebuild: E5, D-15)
- [x] M3.2 Kotlin host in `android/app/src/main/kotlin/com/keplr/vizor/railgun/` (D-16)
- [x] M3.3 Gradle and manifest
- [x] M3.4 Rust bridge `rust/src/railgun_bridge.rs` for real (D-17; E4 stand-in, D-18)
- [x] M3.5 Dart, Railgun side (channel wrapper, models, engine, engine key store; D-20, D-23)
- [x] M3.6 Dart, balance repository, cache and provider (D-19, D-21)
- [x] M3.7 Availability (define, kill switch, `privateUsdAvailableProvider`, the X3 price gate; D-22)
- [ ] M3.8 Home strip
- [ ] M3.9 `/private-usd` route, guard and screen
- [ ] M3.10 Lifecycle (no funds yet)
- [ ] M3.11 Copy (Shared, Home, Private USD screen, Activity)
- [ ] M3.12 Widgetbook and capture scenarios (home, `/private-usd`)
- [ ] M3.13 Kotlin tests (`RailgunBoundaryTest`, `RailgunChannelTest`, `RailgunProtocolTest`)
- [ ] M3 gate

M3 part 1 status (2026-10-13): M3.1–M3.4, the native layer, are done. Part 2
(M3.5–M3.13: the Dart services, balance, availability, UI, copy, Widgetbook
and the Kotlin tests) is next; the M3 gate and its device checks wait for it.

- **What landed.**
  - `android/railgun-web/`: zapp's JS source, lockfile, build script, stubs
    and dev tests, plus `COPYING` (GPL-3.0). `android/app/src/main/assets/railgun/`:
    zapp's bundle, plus `COPYING`. `.gitignore` keeps
    `/android/railgun-web/node_modules/` out.
  - `android/app/src/main/kotlin/com/keplr/vizor/railgun/`:
    `RailgunWebViewHost`, `RailgunChannel`, `RailgunProtocol`,
    `RailgunEndpoints`, `RailgunException` and `RailgunHostHandler`,
    registered in `MainActivity`. `onDestroy` unbinds it and closes the page
    only when the Activity is finishing.
  - Gradle: `androidx.webkit:webkit:1.17.1`,
    `kotlinx-coroutines-android:1.10.2`, and the test dependency
    `kotlin-test-junit:2.2.20`. `data_extraction_rules.xml` excludes
    `root/app_webview` from cloud backup and device transfer.
  - Rust: `rust/src/railgun_bridge.rs`, the tokio `AsyncRead`/`AsyncWrite`
    for `DirectRouteIo`, and the two FRB calls in
    `rust/src/api/network_privacy.rs`. The `tokio` line names `net`,
    `io-util` and `time`.
- **Tests.**
  - Rust: `cd rust && cargo test` passes: lib 1459 passed, 0 failed, 11
    ignored; integration 6 passed, 21 ignored (regtest). The 9 new tests are
    the bridge's: the spike's 8 (one ignored, the real-Tor tunnel, not run
    here) and the 9-host pinning test. The tests that flip the route take
    `lock_route_policy()`.
  - The full run after the bindings were regenerated hit the known Gift Card
    isolation gap (M1 status) once:
    `gift_card_input::tests::recovery::receipt_recovery_preserves_retained_reservations_until_their_expiry`
    failed with "network privacy blocked lightwalletd: Tor connection
    failed", a route test's state. Alone it passed, and the next full run
    passed (the numbers above). It did not recur, so the Gift Card tests
    still do not take the lock.
  - Dart: `fvm flutter analyze` finds no issues. `fvm flutter test`: 5896
    passed, 158 skipped, 4 failed, the 4 pre-existing failures in
    `settings_seed_phrase_screen_test.dart` (the `AppButton` "Enter amount"
    finder at test line 159).
  - Bindings: `lib/src/rust/api/network_privacy.dart` gains the two bridge
    calls. The codegen's rustc 1.93 noise was reverted as in M1 (the
    comment-only changes in `network_privacy.dart`, `private_usd.dart`,
    `sync.dart`, `voting.dart`, `voting_session.dart` and
    `third_party/zcash_voting/wire.dart`, and the import-group blank lines in
    `frb_generated{,.io,.web}.dart`).
  - Kotlin: `cd android && ./gradlew :app:compileDebugKotlin` builds
    (`BUILD SUCCESSFUL`, no Kotlin warnings in the new files); it runs no
    cargokit task. The Kotlin unit tests are M3.13.
  - No device or E2E run in part 1: the M3 device checks are batched for the
    next device round.
- **For part 2.**
  - FRB (`lib/src/rust/api/network_privacy.dart`):
    `Future<int> startRailgunBridge()` and `Future<void> stopRailgunBridge()`.
    Start is idempotent (it returns the running bridge's port), can wait up
    to 3 minutes for a Tor bootstrap, and throws the route's message (a
    `String`) when Tor failed or is unavailable. Stop is idempotent.
  - `MethodChannel('com.zcash.wallet/railgun')`: `load({proxyPort: int,
    debug: bool})` → `null`; `call({method: String, paramsJson: String})` →
    the result as raw JSON `String`; `close()` and `wipe()` → `null`;
    `isOpen()` → `bool`. Errors are `PlatformException` with code `CLOSED`,
    `TIMEOUT`, `UNAVAILABLE`, `PROTOCOL`, `FAILED` or `BAD_ARGS`
    (reference §6.2).
  - `EventChannel('com.zcash.wallet/railgun/events')`: each event is the
    page's raw `{event, data}` JSON as a `String`: `scan` and `proof`, and
    `log` only from a page loaded with `debug` in a debug build.
  - Where the engine calls the bridge:
    - open: `startRailgunBridge()`, then `load` on its port, then `start`,
      `openWallet` and the address check
    - every close (lock, the 10-minute idle close, an account switch,
      `forget`): `close`, then `stopRailgunBridge()`. A running bridge is a
      no-auth loopback proxy, so it runs only while a page is open.
    - a route change (`ref.listen(networkPrivacyProvider…)`): `close`, then
      `stopRailgunBridge()`; the next use reopens, on a new bridge
    - reset: `wipe`, then `stopRailgunBridge()`
    - when the engine is first built in a process: `close` and
      `stopRailgunBridge()` once. The page and the bridge can outlive a
      Flutter engine whose Activity Android destroyed without finishing.
  - Never log `paramsJson`, a result or a `FAILED` message: ethers errors can
    quote the keyed RPC URL. Redact it before showing a message.
  - The bundle is still zapp's (E5 open): no `deleteWallet`, so an account
    deletion drops only the engine key and the cache.
  - For the Kotlin test port (M3.13): `RailgunChannel(post, onEvent)` takes
    `(RailgunProtocol.Message.Event) -> Unit`; `Message.Event(name, raw)`;
    `RailgunEndpoints.hosts` and `POI_NODE_URL` are `internal`;
    `RailgunRequests.route(scheme, host, port)` is unchanged. The page files
    are at `../railgun-web/src/` and `src/main/assets/railgun/` from
    `android/app`.
  - The spike's device harness `lib/railgun_spike_main.dart` is not on this
    branch. Plan §10 keeps it as a debug entrypoint; it fits once
    `railgun_host_channel.dart` (M3.5) exists.

## M4. Privacy Pass tokens and attestation

- [ ] M4.1 `private_usd/tokens.rs`
- [ ] M4.2 FRB issuance begin, finish and status
- [ ] M4.3 Kotlin `PrivateUsdAttestationHandler.kt`
- [ ] M4.4 Dart
- [ ] M4.5 Error codes and copy
- [ ] M4 gate

## M5. Forward conversion, engine loop, lifecycle guards and forward refunds

- [ ] M5.1 `engine.rs` and `forward.rs`
- [ ] M5.2 FRB forward calls
- [ ] M5.3 Dart engine and provider
- [ ] M5.4 Lifecycle provider and account-deletion guards
- [ ] M5.5 UI
- [ ] M5.6 Copy (Convert tables, Accounts)
- [ ] M5.7 Widgetbook and capture scenarios (forward rows)
- [ ] M5 gate

## M6. Reverse conversion, reverse refunds, rescue and the Refunds screen

- [ ] M6.1 `reverse.rs` and `funding_calls.rs`
- [ ] M6.2 FRB reverse calls
- [ ] M6.3 Dart
- [ ] M6.4 Copy (Reverse, Refunds)
- [ ] M6.5 Widgetbook and capture scenarios (reverse, refunds rows)
- [ ] M6 gate

## M7. Private send and withdraw

- [ ] M7.1 Rust
- [ ] M7.2 Dart
- [ ] M7.3 Copy (Send and withdraw)
- [ ] M7.4 Widgetbook and capture scenarios (send rows)
- [ ] M7 gate

## M8. Hardening and release QA

- [ ] M8.1 Route changes during each phase fail closed and resume
- [ ] M8.2 Kill switch: live JSON, missing flag, fetch failure
- [ ] M8.3 Keyed RPC never appears in logs or records
- [ ] M8.4 Measure APK size, first sync, proof time and memory; update plan §11
- [ ] M8.5 `docs/private-usd-device-checklist.md`
- [ ] M8.6 AGENTS.md "Private USD" section; correct the Android worker / `android_jni.rs` description
- [ ] M8.7 `VIZOR_PRIVATE_USD_ENABLED` on for release builds (owner sign-off only)
- [ ] M8 gate

## Deviations

- **D-1 (M0.1 step 1): `zecswap-tokens` is not in vizor's graph.** It does not
  resolve: `blind-rsa-signatures ^0.18` needs `digest ^0.11.3`, and vizor's
  `zakura-client-backend` pins `digest =0.11.0-pre.9` (through
  `bip32 =0.6.0-pre.1` and `hmac =0.13.0-pre.4`). No `blind-rsa-signatures`
  0.16+ accepts that pre-release. `zecswap-core` and `zecswap-railgun` resolve and
  build. Plan updated (M0.1 result, §2 E1, M4 goal, §5.9). The fallback
  options need an owner decision before M4; none has been applied.
- **D-2 (M0.1 step 3): the throwaway worktree's workspace was narrowed** to
  `crates/zecswap-core`. Cargo resolves every member even for `-p`, and
  `zakura-primitives`' `crypto-common =0.2.0-rc.1` cannot coexist with
  `zecswap-tokens`. Plan updated (M0.1 step 3, §2 E1).
- **D-3 (M0.2): verified offline, not on testnet.** No funded testnet wallet or
  device exists here (B-3, B-4). Evidence: wallet-libraries' own
  `orchard_payment_routes_to_ironwood_and_builds`, and the new vizor test
  `rust/src/wallet/sync/send/orchard_receiver_tests.rs` (Ironwood bundle;
  `sent_notes.output_pool` 4; `to_address` = the UA). The plan's check "the
  Orchard bundle has no actions" was wrong when the sender spends Orchard
  notes (the spend and change stay in Orchard); plan M0.2 corrected.
- **D-4 (M0.3 step 4): a separate debug entrypoint instead of a debug-only
  route.** `lib/railgun_spike_main.dart` (`fvm flutter run -t …
  --dart-define=SPIKE_MODE=direct|tor|flip|fail`), on the spike branch only. It
  leaves the app's routing untouched, and the modes run unattended with results
  in logcat.
- **D-5 (M0.3): the screen stays on during device runs.** A run whose screen
  turned off failed. Android froze the app within about 60 s
  (`onFreezeStateChanged uid=10601`), Tor circuits died, and the sync ended
  `Incomplete`. That is D9's foreground-only behaviour, so the runs used
  Developer options "Stay awake" (`svc power stayon usb`), restored afterwards.
  Consequence for M3: the first sync (about 40 min on mainnet, §6.3) needs the
  app in the foreground with the screen on. X8 covers conversion progress
  screens only, so M3 needs the same keep-awake for a first sync (owner to
  confirm).
- **Testing emphasis (owner, 2026-10-13):** invest in end-to-end and device
  tests over unit tests. Keep unit tests to known-answer vectors and
  correctness or security checks.
- **D-6 (owner request, 2026-10-13): the plan was restructured.**
  `docs/private-usd-android-plan.md` is now the lean plan: decisions,
  deliverables, architecture, milestones and tests. Each milestone has Goal,
  Needs, Inputs, Tasks, Done when and Traps; only non-obvious traps are kept.
  M0 is collapsed to its results, and testing is E2E-first. The reference
  sections §5–§9 and §12 moved verbatim to `docs/private-usd-reference.md`,
  with the same numbers. Device E2E helpers are in `scripts/private-usd/`.
- **Local build setting:** all Rust builds here use
  `CARGO_PROFILE_DEV_DEBUG=0` (no debug info) so the target directory fits the
  free disk. No repo file changes.
- **D-7 (M1): the Rust skeleton as built differs from plan §3.6 in these
  places.** Plan §3.6, §3.3, §3.4, task 10 and reference §8.5 updated to
  match.
  - `ChainReader` returns `PrivateUsdError` (internal codes
    `WrongDeployment`, `ChainUnreadable`, `Mismatch`, `EthereumUnreachable`);
    there is no separate `EvmError`.
  - `reverse_funding(id)` is `reverse_state(id, terms)`: the refund note, the
    funding block, `getSwap` and `LOCK_DURATION` read at one confirmed block,
    as zapp's `AtomicSwapChain.read` does. Two reads at different blocks could
    disagree.
  - `receipt_succeeded(tx)` is `transaction_status(tx, confirmations)`
    (`Unknown`/`Pending`/`Confirmed`/`Reverted`, zapp `transactionStatus`). M6
    needs to know whether the node knows a funding hash at all (§3.5 item 7).
  - `confirmed_swap` returns `ConfirmedSwap { head, swap }`, so lock reasoning
    uses the head the read was taken against.
  - Internal error codes add `WrongDeployment`, `ChainUnreadable`,
    `IndicesInUse` and `AmountUnquotable`; the FRB enum keeps the §8.2 list
    and folds them in (`WrongDeployment` → `RelayerUnreachable`, as zapp's
    hold mapping does; `ChainUnreadable` → `EthereumUnreachable`;
    `IndicesInUse` → `Other`; `AmountUnquotable` → `AmountRefused`).
  - Strict decoding is a round trip: a stored record must re-encode to exactly
    the JSON it was read from. An unknown field, a written-out default, a
    mixed-case id or a malformed value is `StoreUnreadable`. Wire answers stay
    lenient (unknown fields ignored).
  - Forward rows' `phase` column: zapp's stage names while under way
    (`OPENING`, `DEPOSITING`, `CONFIRMING`, `CLAIMING`, `REFUNDING`, derived
    from the record), the outcome once ended (`PAID`, `REFUNDED`,
    `NOTHING_SENT`).
  - `take_index` also never returns an index below one a kept record already
    has. `swaps.db` runs with `synchronous = FULL`, so a taken index survives
    power loss.
  - `RoutedHttp` pools direct connections per instance (make one per
    operation) rather than taking a pooling flag. Test builds alone admit
    plaintext `http://127.0.0.1` URLs, for the client tests' local server.
  - `getSwap`: any length other than 192 bytes is `WrongDeployment`, as the
    plan says. zapp reads a shorter answer as `CHAIN_UNREADABLE`.
  - Deferred: the op-id cancel registry moves to `engine.rs` (M5), where
    `private_usd_cancel` lands. `SwapKeyContext::acceptance` (the user's share
    proof, `ops.rs:164-188`) moves to M5: `zecswap-core`'s `prove_user` needs a
    `rand 0.10` `CryptoRng`, and vizor's `rand` is 0.8 (M5 adds `rand` 0.10
    under a renamed dependency; it is already in the lockfile). The Rust test
    pinning the 9 page hosts against Kotlin and the CSP (reference §8.2)
    moves to M3, where those copies land.
  - The engine vectors are wallets 0 and 1 of two seeds (`5eb00bbd…e38e4` and
    `243c1266…5c3a`), not wallets 0–3 of one; plan §3.3 corrected.
  - `#![allow(dead_code)]` on `private_usd`: most M1 blocks are reached only
    from tests until the engine (M5–M7) drives them. Remove it then.
- **D-8 (M2): the signatures as built.** Plan M2 tasks and reference §8.1
  updated.
  - `find_deposit` and `swap_tx_status` also take the network: they read the
    fully scanned height through a librustzcash handle.
  - `register_joint_account` takes the birthday as `u32`. `sync_joint_db` is
    async and takes a cancel flag.
  - `propose_swap_deposit` and `propose_joint_sweep` return `SwapProposal {
    proposal_id, needs_sapling_params, fee_zatoshi, amount_zatoshi }`. The
    sweep's `SweepIntent` needs the amount, and the engine needs the fee.
  - `create_stored_proposal_transactions` keeps `execute_proposal`'s optional
    Sapling parameters, since a deposit may spend Sapling notes. It returns
    `Vec<CreatedTransaction { txid, raw, expiry_height }>`.
  - `sweep_joint` proposes the sweep itself, because the intent needs the
    proposed amount and the fee limit, and takes the combined `SpendKey`. It
    returns `JointSweep { transaction, amount_zatoshi, fee_zatoshi, broadcast,
    message }`, where `broadcast` is `Accepted`, `Unknown` or
    `StorageFailed`. A PCZT that expires before broadcast is an error.
  - `JOINT_SWEEP_CONFIRMATIONS = 2` is its own constant in `wallet/mod.rs`:
    the Gift Card claim depth, but not tied to it.
  - M2 needed no `rand` 0.10: `zecswap_core::sign_pczt` draws its own
    randomness.
- **D-9 (M2): `swap_tx_status` semantics.** Reference §5.6 and §8.1 updated.
  - `Mined` counts its depth from the fully scanned height, as zecSwap's own
    wallet does, not from the advertised tip (zapp). A lagging scan only
    delays completion. `joint_receipts` counts depth the same way.
  - `Expired` needs the fully scanned height above the expiry height
    (zecSwap's `is_expired`). zapp's `≥` is one block earlier, but a
    transaction can still be mined in its expiry block.
  - An expiry height of 0 never expires, also for a transaction the wallet
    does not hold (zapp's absent branch would call it expired).
  - `find_deposit` skips only expired deposits and treats an unknown expiry
    as none. It fails closed when a matching deposit has no stored bytes.
- **D-10 (M2, U6): a `joint.db` born above the tip is not scanned.** By
  reading the claim scan, such a DB fails its completion checks: no block is
  stored at the tip. `sync_joint_db` returns at once until the tip reaches the
  wallet birthday (zecSwap's `born_above`). It also runs one scan per
  `joint.db` at a time; a second gets `Busy`. M2.7b exercises it.
- **D-11 (M2): the TEX PCZT path keeps an OVK-based refusal.** It builds both
  PCZTs with the sender's OVK, so it still refuses every `Discard` proposal:
  claims keep the Gift Card message, others get a generic one. Only
  `create_pczt_from_proposal` moved to the purpose-based refusal.
- **D-12 (M2): the multi-step sweep test.** A joint account cannot produce a
  two-step proposal: a TEX recipient needs a ZIP 320 ephemeral transparent
  address, which an Orchard-only joint account cannot derive. So the deposit
  and the sweep share one one-transaction check (`single_swap_transaction`),
  and the unit test refuses a deposit to a TEX address, the usual
  two-transaction send. Both checks run before anything is locked; the tests
  assert that no lock rows remain and the note can still be proposed.
- **D-13 (M2): the bytes `sweep_joint` returns.** They are the joint DB's
  stored bytes, or, when storing failed, a re-extraction from the same proofs
  and signatures: the same txid with another binding signature. The stored
  bytes are themselves a second extraction
  (`extract_and_store_transaction_from_pczt`), so no path keeps the exact
  broadcast encoding. Any encoding with the txid resends safely.
- **D-14 (M2): the regtest test's shape.**
  - In test builds the regtest NU6.3 height is per thread
    (`wallet/network.rs`). The in-crate test therefore runs every wallet call
    on its own thread, with a current-thread runtime, and scans wallets with
    the claim scan rather than the main full sync.
  - It asserts broadcast before store by sending a fully signed sweep through
    a dead route: nothing is stored, and the note stays spendable. Then it
    sweeps for real.
  - It also asserts U2 (the deposit's Ironwood bundle, `sent_notes` pool 4),
    a sender-OVK control on the deposit, U5 (one compact signature), U8 (the
    sweep's sent row), U7 (the joint sync resubmits the pending sweep) and the
    sweep arriving home.
- **D-15 (M3.1): the bundle copy.** Reference §8.7 updated.
  - The bundle is zapp's, copied blind with §8.7 command 2; its five files
    are byte-identical to the spike's. E5 is not delivered, so nothing was
    rebuilt and `npm` never ran: `INIT` stays `zapp-railgun-init`,
    `WALLET_SOURCE` stays `'zapp'`, and the page has no `deleteWallet`.
  - The GPL-3.0 text (the canonical 35,147-byte `COPYING`, md5
    `d32239bcb673463ab874e80d47fae504`, copied from a local GNU package) is
    `android/railgun-web/COPYING`. It is also placed by hand as
    `android/app/src/main/assets/railgun/COPYING`, which is where the edited
    `build.mjs` copies it on a rebuild.
  - `dev/check.mjs` (the desktop smoke test) needed the same path move as
    `build.mjs`: `ASSETS` → `../app/src/main/assets/railgun` and
    `LOCAL_PROPERTIES` → `../local.properties` (`android/local.properties`,
    gitignored).
  - `package.json` keeps `"license": "AGPL-3.0-only"` until E2.
- **D-16 (M3.2): the Kotlin host as built differs from the spike and from
  reference §6.2 and §8.7 in these places.** Both sections updated.
  - `load`'s `debug` argument is honoured; the spike ignored it and used
    `BuildConfig.DEBUG`. Kotlin ANDs it with `BuildConfig.DEBUG`, so a release
    build never debugs the page.
  - The page sends `log` events without `debug` too (`wallet.js:123`, a failed
    screening refresh), so the host drops page `log` events unless the page
    was loaded with `debug`. To allow that, `RailgunProtocol.Message.Event`
    carries the event name, and `RailgunChannel`'s `onEvent` takes the
    `Message.Event` rather than a `String`.
  - `close` and `wipe` lift the proxy override even when no page is open. The
    host records whether it set one, so a close with nothing to lift never
    loads the WebView package (Dart may close on every lock).
  - The wait for the proxy override is bounded at 10 s (`TIMEOUT`), and a page
    closed while its override was pending no longer calls `loadUrl` on a
    destroyed WebView.
  - A call whose coroutine is cancelled is answered `CLOSED`; in the spike it
    was never answered.
  - `RailgunEndpoints` is `internal` and lists its hosts as literals (the Rust
    pinning test reads them); the spike's unused `SEPOLIA_RPC_URL` and
    `MAINNET_RPC_URL` are gone.
  - The handler exposes `handle(call, result)`, like vizor's other handlers,
    instead of implementing `MethodCallHandler`.
  - The debug-only page method `openNewWallet` is not in `RailgunMethod`, so
    `call` refuses it with `BAD_ARGS`.
- **D-17 (M3.4): the bridge as built.** Reference §6.8 and §8.2 updated.
  - The SOCKS5 handshake is the spike's own RFC 1928 parser, not
    `tor-socksproto`'s `SocksProxyHandshake`. The bridge needs only a no-auth
    `CONNECT` to a domain name; the parser refuses everything else, and
    `tor-socksproto` stays transitive. It ran on the device in M0.
  - The route is resolved once, in `start()`, waiting out a bootstrap (up to
    3 minutes), not per connection. Each connection only checks that the
    route still matches the bridge's, and is refused otherwise.
  - Logging is down to "started", "stopped" and an accept failure. The
    spike's per-tunnel lines, its byte counters (`Counted`, `TRAFFIC`,
    `log_traffic`) and its open-tunnel count are gone.
  - The 9-host pinning test that D-7 moved here is
    `railgun_bridge::tests::the_page_hosts_match_the_kotlin_filter_and_the_page_csp`.
    It reads `RailgunEndpoints.kt` and both `index.html` files through
    `CARGO_MANIFEST_DIR/../android`, so `cargo test` needs the whole
    repository, as CI has.
- **D-18 (M3.4): the E4 stand-in is on this branch now, not only on the
  spike.** All ten wallet-libraries references in `rust/Cargo.toml` (the
  eight `[patch.crates-io]` entries and both `zakura-pir-transparent`
  entries) are paths into `~/dev/wallet-libraries-e4`, under a do-not-merge
  comment. `rust/Cargo.lock` follows: its nine wallet-libraries packages lost
  their git `source` lines. Local only (B-6): before anything is pushed, all
  ten go back to git refs on the owner's fork rev with the patch (E4, D13).
- **D-19 (M3.6): `ApiDeployment` carries the dollar tokens.** The balance
  counts only known dollar tokens (reference §6.6), and Dart never duplicates
  pins, so `ApiDeployment` gains `usd_tokens: Vec<ApiUsdToken { address,
  symbol }>`, the swap token first (mainnet USDC; Sepolia tUSD, then Circle's
  test USDC). In Rust, `Deployment::extra_usd_tokens` (unused) became
  `usd_tokens: &[UsdToken]`, built from the same consts as `token`. Sepolia's
  WETH is not listed: it is not a dollar. Bindings regenerated; reference
  §8.2 updated.
- **D-20 (M3.5): the Railgun engine key is an app-managed secret.** It is
  stored with `AppSecureStore.writeSecretString` under
  `vizor_railgun_encryption_key_<uuid>`, encrypted under the session password
  and re-encrypted by `changePassword` (the prefix joins
  `_isAppManagedGeneralSecretKey`, as the voting hotkeys are), and read only
  unlocked. A plain flutter_secure_storage entry would have let the key and
  the page's IndexedDB open the Railgun wallet without the password, which
  the Zcash seed never allows. Losing it still costs only a rescan: the page
  recreates a wallet whose stored copy no longer opens. The rotation test in
  `app_secure_store_test.dart` covers it. Plan §3.3 and §3.4 updated.
- **D-21 (M3.6): the balance provider as built.** Riverpod rather than
  zapp's flows:
  - `privateUsdBalanceProvider(uuid)` (autoDispose family) holds the state,
    shows the cache at once, and shows every sync of that account, also
    syncs another use made (the engine's `lastSync`).
  - Polling runs while something watches
    `privateUsdBalanceKeepFreshProvider((accountUuid, ifUsed))`: the home
    strip with `ifUsed: true`, the Private USD screen with `ifUsed: false`
    (zapp's `observeIfUsed`/`observe`). Each 30 s tick refreshes what is
    older than 30 s while funds arrive, else 5 min; only in the foreground,
    unlocked and outside a drain. Failures back off 30 s × 2^n up to 32×.
  - "In use" is, in M3, a non-zero balance; swap history (M5) and the send
    log (M7) join it later.
  - A refresh that times out (5 min, or 2 h before anything shows) marks the
    balance failed but lets the page finish: its result still shows, and no
    second refresh queues behind it (zapp's async-in-scope does the same).
  - A close the engine made itself (lock, switch, route change, drain) is
    not a failure and backs nothing off.
  - The cache is keyed by account, so it is not checked against a
    Rust-derived address before showing; the next sync replaces it with its
    own address.
- **D-22 (M3.7): no `privateUsdTorBlockedProvider`.** It applies only under
  D4's fallback, and the M0.3 spike passed. `tor_unavailable` stays in the
  copy, unused.
- **D-23 (M3.5): the engine wrapper as built.**
  - It runs one use at a time on a serial lock; `close()` bypasses the lock
    and bumps an epoch, so a lock, an account switch or a route change
    interrupts a running use at once (`RailgunEngineInterruptedException`).
    Every step of an open re-checks the epoch, and an abandoned open closes
    the page and stops the bridge it started.
  - A call that fails `CLOSED`, `TIMEOUT` or `UNAVAILABLE` drops the session
    and stops the bridge. Before reusing a session the engine asks
    `isOpen`, so a renderer that died between uses is reopened.
  - The page is loaded with `debug: kDebugMode` (content debugging only);
    `start.debug` is false. The app never prints page `log` events, and the
    engine state carries a host error code, never a message.
    `redactRailgunMessage` strips keyed URLs (and Alchemy/Infura key paths)
    from anything a debug build prints.
  - The keyed RPC URL is dropped (publicnode alone) unless it is `https` on
    the default port and its host is in `ApiDeployment.allowed_hosts`.
  - The mnemonic is held only until `openWallet` is sent; the mnemonic bytes
    are zeroed as soon as both Rust derivations have started (they copy them
    as they start, as `swap_deposit_sender.dart` relies on).

## Blocked

- **B-1. Resolved 2026-10-13:** installed fvm 4.3.1 (Homebrew), Flutter
  3.47.2 (Dart 3.13.2), `flutter_rust_bridge_codegen` 2.11.1, `cargo-expand`
  and Android `cmdline-tools` (in the SDK). NDK 28.2.13676358, which Gradle
  pins, still needs installing once there is disk space. Before that:
  there was no `fvm`, no Flutter 3.47.2 (`.fvmrc`), no `dart` and no
  `flutter_rust_bridge_codegen`. That blocks
  `fvm flutter analyze`, `fvm flutter test`, the mobile lane,
  `scripts/generate-rust-bridge.sh`, every APK build (M0.1.4) and any Kotlin
  compile (the Android build needs the Flutter SDK). Every milestone gate needs
  them. Owner: install them, or approve installing them (see B-2).
- **B-2. Resolved 2026-10-13.** A cleanup of `~/dev/zapp` build outputs
  (zecSwap untouched, at the owner's request) freed about 45 GB; about 19 GB
  is free after the device runs. Before that, 7.4 GB was free on the 460 GB
  volume. Flutter, Gradle and the Android Rust targets need more.
  The largest reclaimable directories are `~/dev/zapp/zecSwap/target` (39 GB)
  and `~/dev/zapp/zecSwap-mainnet-beta/target` (18 GB). Clearing them is the
  owner's call.
- **B-3. Resolved 2026-10-13:** the owner's Galaxy A35 (SM-A356E) is the
  device (Android 16, bootloader locked, verified boot green, so it also
  suits E9). Do not install emulators.
- **B-4. M0.2 on testnet needs funded testnet ZEC (E8).** The routing was
  verified offline instead (see the M0.2 line).
- **B-5. `zecswap-tokens` (D-1).** An owner decision is needed before M4:
  options (a)–(c) in plan M0.1 result.
- **B-7. A funded Sepolia Railgun wallet.** It needs test USDC shielded into a
  Railgun wallet whose mnemonic can be passed as `SPIKE_MNEMONIC`. It blocks
  M0.3.4b and M0.3.5b (one transfer proof, `proofMs`, artifact bytes). Part of
  E8.
- **B-6. E1, E2 and E4 are not delivered.** Local stand-ins:
  `~/dev/zapp/zecSwap-zakura` (detached worktree at `d69e3fb` with the §12
  diff; zecSwap has no LICENSE yet) and `~/dev/wallet-libraries-e4` (`391d0b0`
  plus the §6.8 `connect_stream` patch). Nothing built on them, and nothing
  ported from zapp, may be pushed or merged; the M0.3 spike lives on the local
  branch `spike/private-usd-m0`. Since M3 this branch depends on both through
  `rust/Cargo.toml` paths (D-18), and carries zapp's Railgun bundle, JS source
  and the ported Kotlin host, so `feature/private-usd-android` stays local
  until E1, E2 and E4 land.
