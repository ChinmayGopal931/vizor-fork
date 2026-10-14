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
- [x] M2.7b Run the Ironwood regtest test once (2026-10-13, with the owner's go-ahead: passed after the fresh-tip fix, D-50; settles U4–U9)
- [x] M2 gate (including the M2.7b regtest run)

M2 status (2026-10-13): done. The regtest run (M2.7b) passed on the second
attempt, after a fix (below).

- **M2.7b, the Ironwood regtest run** (Dockerized Zero zcashd and the
  Ironwood lightwalletd, NU6.3 at 500):
  `cargo test --lib private_usd::tests::ironwood_regtest -- --ignored --nocapture --test-threads=1`.
  - First run: failed at the first receipt check (`received_zatoshi` 0, not
    50,000,000). The deposit was mined at height 507, the joint birthday, but
    the joint DB had scanned nothing: no `blocks` rows, and `scan_queue` held
    only `[1, 507)` Ignored. `sync_joint_db` had judged the DB born above the
    tip using `latest_block_for_transaction`, a tip cache up to 15 s old,
    which still said 506.
  - Fix (D-50): `sync_joint_db` reads a fresh tip.
  - Second run: `test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured;
    1510 filtered out; finished in 73.17s`. Every assertion held: deposit
    into the Ironwood bundle and recorded for `find_deposit`, import above
    the tip, two-confirmation receipts, broadcast before store, and a sweep
    home whose output does not recover under the joint OVKs. That answers
    U4–U9 (plan §11).

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
- [x] M3.8 Home strip (D-24)
- [x] M3.9 `/private-usd` route, guard and screen (D-25)
- [x] M3.10 Lifecycle (no funds yet) (D-26)
- [x] M3.11 Copy (Shared, Home, Private USD screen, Activity) (D-27)
- [x] M3.12 Widgetbook and capture scenarios (home, `/private-usd`) (D-28)
- [x] M3.13 Kotlin tests (`RailgunBoundaryTest`, `RailgunChannelTest`, `RailgunProtocolTest`) (D-29)
- [ ] M3.14 Device round (batched; Galaxy A35, Sepolia; the M3 Done-when device checks and the R8 release-build check). Harness ready (D-40 to D-42); not run on 2026-10-14, the phone was not attached (B-8)
- [x] M3 gate: the unit essentials and every suite pass (status below); the device checks are M3.14, deferred

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

M3 status (2026-10-13): done except M3.14, the device round, which is
batched with the others (the M3 **Done when** device checks and the R8
release-build check). Part 2a is `405bf700d` (M3.5–M3.7); part 2b is the
commit that checks this note.

- **What landed in part 2.**
  - `lib/src/features/private_usd/`: the channel wrapper
    (`services/railgun_host_channel.dart`), the page models
    (`models/railgun_models.dart`), the engine wrapper
    (`services/railgun_engine.dart`) and its key store, the balance model,
    cache and repository helpers, `private_usd_copy.dart`, the home strip
    (`widgets/mobile/private_usd_home_strip.dart`), the info sheet, and
    `screens/mobile/mobile_private_usd_screen.dart`.
  - Providers: `privateUsdAvailableProvider` (with the deployment
    providers), `railgunEngineProvider` and `railgunEngineStateProvider`,
    `privateUsdBalanceProvider(uuid)` and
    `privateUsdBalanceKeepFreshProvider((uuid, ifUsed))`,
    `privateUsdReceiveAddressProvider(uuid)`, and the kill switch
    `privateUsdKillSwitchProvider` in
    `lib/src/core/config/private_usd_feature_config.dart`;
    `lib/src/providers/private_usd_lifecycle_provider.dart` is the fence.
  - Wiring: the `/private-usd` route and its redirect, the strip in the home
    balance card, the X3 price gate, the account-deletion and reset drains
    and cleanups, the Railgun key's rotation with the password.
  - `ApiDeployment.usd_tokens` (bindings regenerated; the rustc 1.93 noise
    reverted as in M1).
  - Widgetbook entries (Home and a new Private USD folder), 11 capture
    scenarios, the three Kotlin tests, and the debug harness
    `lib/railgun_spike_main.dart`.
- **Tests.**
  - Rust: the first gate run of `cd rust && cargo test` hit the known Gift
    Card isolation gap once:
    `gift_card_input::tests::recovery::observed_mining_and_conflicting_spends_never_relay_or_unlock_funding`
    failed with "network: network privacy blocked lightwalletd: Tor
    connection failed" (lib 1458 passed, 1 failed, 11 ignored). Alone it
    passed (1 passed), and the next full run passed: lib 1459 passed, 0
    failed, 11 ignored; integration 6 passed, 21 ignored (regtest). An
    earlier run in this part failed its neighbour
    `observer_and_configured_endpoint_disagreement_does_not_recover_receipts`
    the same way ("tip changed" assertion); alone it passed too. M3 part 2
    adds no Rust tests (one pin moved).
  - Dart: `fvm flutter analyze` finds no issues. `fvm flutter test`
    (desktop lane): 5926 passed, 160 skipped, 4 failed, the 4 pre-existing
    failures in `settings_seed_phrase_screen_test.dart` (the `AppButton`
    "Enter amount" finder at test line 159). The 30 new tests: page-model
    parsing (9, zapp's `RailgunSessionTest` cases and the events), bucket
    mapping, formatting and the cache (6), the availability matrix (2), the
    engine's open order, address refusal, interruption and drain (4), and
    the kill switch, its last-known fallback and the keyed RPC host check
    (9); the password-rotation test also covers the Railgun key.
  - Mobile lane (`--tags mobile --run-skipped
    --dart-define=VIZOR_FORM_FACTOR=mobile`): 2242 passed, 10 failed. All 10
    are pre-existing, in `test/core/feedback/app_review_payment_handoff_test.dart`
    ("Edit"/"Review" × 5: the finder for that button finds nothing); the same
    file fails the same 10 at `fcca09a9c`, before any part-2 change. New: 7
    strip and 7 screen tests, and the 11 scenarios in
    `figma_compare_mobile_scenarios_test.dart`.
  - After the gate, a zero balance stopped showing "≈ 0 ZEC"; analyze, the
    Private USD tests in both lanes and the mobile scenario test were run
    again and pass (desktop 21 passed, 2 skipped; mobile 274 passed).
  - Kotlin: `cd android && ./gradlew :app:testDebugUnitTest --tests
    'com.keplr.vizor.railgun.*'`: BUILD SUCCESSFUL; `RailgunBoundaryTest` 4,
    `RailgunChannelTest` 7, `RailgunProtocolTest` 10, no failures. A dry run
    first showed no cargokit or native-lib task. No main Kotlin changed, so
    `compileDebugKotlin` was not re-run beyond what the test task compiles.
  - Captures: all 11 scenarios rendered with `scripts/figma-compare.sh
    widget --form-factor mobile` in both themes and were reviewed.
- **For M3.14 (the device round).** Build with
  `--dart-define=VIZOR_PRIVATE_USD_ENABLED=true` on testnet. Check that the
  strip shows "—" and no WebView process starts before first use; that
  `/private-usd` shows the first-sync percentage and then the balance, with
  the address equal to Rust's; that the strip is hidden on regtest, for
  Keystone and Ledger accounts, and with the kill switch false; Tor on means
  no direct sockets (`scripts/private-usd/check_sockets.py`); lock closes the
  page and stops the bridge (no loopback listener left); and a release build
  (R8) loads the page.

M3 device round (2026-10-14): not run on the phone, so M3.14 stays open
(B-8). The Galaxy A35 (`RZCX40721QZ`) was not attached: no USB device from
23:05 to 00:06, and its wireless-debugging advert (`_adb-tls-connect`,
192.168.0.7:38161) refused connections, then went away. Nothing was
installed, cleared or changed on the phone, and its Stay awake setting was
never touched. The round's harness is committed and ready (D-40 to D-42).
With the phone attached over USB and unlocked:
`ANDROID_SERIAL=RZCX40721QZ scripts/private-usd/run_device_round.sh`.

| Check | Result | Evidence |
|---|---|---|
| 1. Before first use the strip shows "—" and no WebView renderer runs | Not run | The test holds home for 20 s, then the host looks for the app's `sandboxed_process` renderer and loopback listeners |
| 2. `/private-usd` shows the first-sync percentage, then $0; the address equals Rust's | Not run | Time to first balance from the engine's own stamp (M0: 96–136 s), the percentages shown, and the shown address against the page's wallet and `privateUsdRailgunAddress` |
| 3. Tor on: no direct socket while the page syncs or refreshes; Tor off works | Not run | A first sync through Tor (page storage wiped) and a refresh, sampled every 30 s with `check_sockets.py --onionoo`; Tor bootstrap time; then a direct refresh |
| 4. Lock closes the page and leaves no loopback listener | Not run | `isOpen` false, then no LISTEN row on loopback for the app UID except the Dart VM service |
| 5. The R8 release build loads the page | Built; not run | arm64 release APK with the round's defines: 116 MB, built in 8.5 min. R8's mapping keeps every Railgun host class (renamed; only unused data-class `copy`/`componentN` methods went) and `AndroidDispatcherFactory`; the host uses no reflection |
| 6. Hidden on regtest, for hardware accounts and with the kill switch false | Unit-tested; not run on device | The availability matrix and the strip tests (M3.7, M3.8; D-42) |

## M4. Privacy Pass tokens and attestation

Skipped for now: blocked on N1 (B-5); M5–M7 proceed (D20).
Tokens disabled on testnet by the owner (2026-10-13), temporarily; M5–M7
testnet E2E are not blocked by tokens; N1 still open for when they return.
Until M4 lands, the engine's token seam holds none (D-33).

- [ ] M4.1 `private_usd/tokens.rs`
- [ ] M4.2 FRB issuance begin, finish and status
- [ ] M4.3 Kotlin `PrivateUsdAttestationHandler.kt`
- [ ] M4.4 Dart
- [ ] M4.5 Error codes and copy
- [ ] M4 gate

## M5. Forward conversion, engine loop, lifecycle guards and forward refunds

- [x] M5.1 `engine.rs` and `forward.rs` (D-31, D-33 to D-38)
- [x] M5.2 FRB forward calls (D-32)
- [ ] M5.3 Dart engine and provider
- [ ] M5.4 Lifecycle provider and account-deletion guards
- [ ] M5.5 UI
- [ ] M5.6 Copy (Convert tables, Accounts)
- [ ] M5.7 Widgetbook and capture scenarios (forward rows)
- [ ] M5 gate

M5 part 1 status (2026-10-13): M5.1 and M5.2, the Rust half, are done. Part 2
(M5.3–M5.7: the Dart engine, lifecycle, UI, copy and Widgetbook) is next; the
M5 gate and its device checks wait for it. M4 is skipped for now (N1, B-5), so
the forward path runs without tokens (D-33).

- **What landed.**
  - `rust/src/wallet/private_usd/engine.rs`: the per-account driver lock
    (`lock_account`, a `tokio::sync::Mutex` per account; a second caller gets
    `Busy`), the forward offer cache (per `(account, index)`, dropped at the
    quote's expiry and on lock, never persisted), the `op_id` registry
    (`OpHandle`, `cancel_op`, `op_activity`; a cancel that arrives before its
    call registers still stops it), the `Clock` and `TokenSource` seams
    (`SystemClock`, `NoTokens`), the problem mapping and `delete_account`.
  - `rust/src/wallet/private_usd/forward.rs`: the §5.6 driver (`quote`,
    `accept`, `advance`, `advance_report`, `abandon`, `records`) and the §5.8
    forward refund, generic over `ChainReader`, `HttpTransport`,
    `ForwardZcash`, `Clock` and `TokenSource`; `WalletZcash`, the Zcash seam
    over the M2 operations; `ForwardCall`, which wires the real seams for one
    FRB call.
  - Smaller changes: `keys.rs` (`SwapKeyContext::acceptance`, over
    `rand_0_10`'s `UnwrapErr(SysRng)`; `seed`), `joint.rs`
    (`scanned_height`, `find_sent`, `forget_joint_account`), `store.rs`
    (`open_existing`), `indices.rs` (readers by reference), `send.rs`
    (`estimate_swap_deposit_fee`, `proposal_needs_sapling`), `Cargo.toml`
    (`rand_0_10 = { package = "rand", version = "0.10", features =
    ["sys_rng"] }`, already in the lockfile).
  - FRB (`rust/src/api/private_usd.rs`): the ten calls below. Bindings
    regenerated; the rustc 1.93 noise was reverted as before (the
    comment-only changes in `network_privacy.dart`, `sync.dart`,
    `voting.dart`, `voting_session.dart` and
    `third_party/zcash_voting/wire.dart`, the import-group blank lines in
    `frb_generated{,.io,.web}.dart`, and the new file's ignored-trait wording).
- **Tests.**
  - Rust: `cd rust && cargo test` passes: lib 1500 passed, 0 failed, 11
    ignored; integration 6 passed, 21 ignored (regtest). The 41 new tests are
    `private_usd/tests/forward.rs` (38: the ★ cases and vizor's own, on the
    fakes in `private_usd/tests/fakes.rs`) and `private_usd/tests/lifecycle.rs`
    (3, through the FRB calls). The ★ mapping is in D-39.
  - Dart: `fvm flutter analyze` finds no issues. `fvm flutter test`: +5926
    ~160 -4, the 4 pre-existing failures in
    `settings_seed_phrase_screen_test.dart` (the `AppButton` "Enter amount"
    finder at test line 159). No Dart besides the bindings changed, so the
    mobile lane was not run.
- **For part 2: the FRB calls** (`lib/src/rust/api/private_usd.dart`). Common
  arguments: `dbPath` (`getWalletDbPath()`), `network` (`"main"` | `"test"`),
  `accountUuid`, `storeDir` (`getPrivateUsdDirPath(network)`),
  `mnemonicBytes` (from `getMnemonicBytesForAccount`, zeroed in `finally`),
  `lightwalletdUrl` (`rpcEndpointFailoverProvider.current
  .normalizedLightwalletdUrl`) and `ethRpcUrl` (the keyed URL if its host is
  in `ApiDeployment.allowedHosts`, else `""` for publicnode).
  - `void privateUsdCancel({required int opId})` (sync).
  - `ApiActivity? privateUsdActivity({required int opId})` (sync):
    `depositing`, `claiming`, `payingOut`, `sweeping` while an advance runs
    (`funding`, `readying`, `refunding` arrive with M6).
  - `void privateUsdClearSessions()` (sync): call on lock; drops every held
    quote and maker check (M4 adds its issuance sessions here).
  - `Future<int> privateUsdUnfinishedCount({storeDir, accountUuid})`: the
    deletion and reset warning count; 0 when the wallet never converted
    (nothing is created by asking).
  - `Future<List<String>> privateUsdAccountsWithUnfinished({storeDir})`: the
    engine loop's accounts (D14).
  - `Future<void> privateUsdDeleteAccount({storeDir, network, accountUuid})`:
    after the user confirmed and the engine drained; `busy` while one of the
    account's steps runs (drain, then call again). Removes the account's
    joint accounts from `joint.db`, then its rows from `swaps.db`.
  - `Future<ApiForwardQuote> privateUsdForwardQuote({dbPath, network,
    accountUuid, storeDir, mnemonicBytes, lightwalletdUrl, ethRpcUrl,
    required int units})`: spends an index. `ApiForwardQuote { int index;
    PlatformInt64 expiresAt; String amount; String? networkCost; String
    relayerFee; String receives; BigInt depositZat; BigInt? depositFeeZat;
    BigInt? maxTotalZat; PlatformInt64? feeExpiresAt }`. `maxTotalZat ==
    null` means unpayable: do not offer it.
  - `Future<ApiAcceptResult> privateUsdForwardAccept({dbPath, network,
    accountUuid, storeDir, mnemonicBytes, lightwalletdUrl, ethRpcUrl,
    required int index, required BigInt maxTotalZat})`: pass the quote's
    `maxTotalZat`. `ApiAcceptResult { ApiAcceptKind kind;
    ApiNothingSentCause? cause; int index }`, `kind` ∈ `accepted`,
    `tokensNeeded`, `nothingSent`. Repeat calls for the same index are safe.
  - `Future<ApiForwardAdvance> privateUsdForwardAdvance({dbPath, network,
    accountUuid, storeDir, mnemonicBytes, lightwalletdUrl, ethRpcUrl,
    required int opId, required int index})`: `ApiForwardAdvance {
    ApiForwardRecord record; ApiForwardWait? wait; int nextPollMs;
    ApiPrivateUsdErrorCode? problem }`.
  - `Future<ApiForwardRecord> privateUsdForwardAbandon({network, accountUuid,
    storeDir, ethRpcUrl, required int index})` ("Call it off"; no key).
  - `Future<List<ApiForwardRecord>> privateUsdForwardRecords({dbPath,
    network, accountUuid, storeDir})`: the active record first, then the
    rest, newest first.
  - `ApiForwardRecord { int index; String swapId; ApiForwardPhase phase;
    PlatformInt64 acceptedAt, quoteExpiresAt; BigInt depositZat; BigInt?
    maxTotalZat; String amount, receives, relayerFee; PlatformInt64? t0, t1;
    String? depositTxid; int? depositConfirmations; String? sweepTxid;
    String? payoutTx; ApiForwardOutcome? outcome; ApiRefundCause?
    refundCause; ApiNothingSentCause? nothingSentCause; PlatformInt64?
    endedAt }`. `phase` ∈ `opening`, `depositing`, `confirming`, `claiming`,
    `refunding`, `paid`, `refunded`, `nothingSent`. `depositTxid` and
    `sweepTxid` are internal byte order (match history rows; show with
    `zcashDisplayTxidHex`). `depositConfirmations` is set only while under
    way with a deposit kept (0 until mined; the maker waits for
    `ApiDeployment.zcashConfirmations`).
- **For part 2: error codes** (`ApiPrivateUsdError.code`; copy follows the
  code).
  - Quote: `busy` (a conversion is under way, or a step of the account is
    running: open its progress), `amountRefused` (the maker turned the amount
    down), `makerBusy`, `makerUnavailable`, `relayerFee` (the relayer's fee is
    above 2 USDC), `relayerUnreachable` (also a service on another
    deployment), `ethereumUnreachable`, `tokensRefused`, `zcashWallet`,
    `mismatch` (wrong seed), `unavailable` (no deployment, hardware account,
    no derivation), `other` (16 used indices in a row).
  - Accept: `quoteExpired` (no offer held: expired, too close to expiry, or
    quoted before a lock; quote again), `relayerFee` (the fee takes the whole
    amount, or is above the cap), `depositUnpayable` (the deposit does not fit
    one transaction from this wallet, or `maxTotalZat` is below the deposit),
    `busy`, `mismatch` (the maker's share proof does not verify). Any other
    error after the record was saved means "maybe opened": read
    `privateUsdForwardRecords` and show the progress of `index` if its
    `outcome` is null.
  - Advance returns `Err` only for `busy`, `cancelled` (drop it; never a
    failure), a key or store failure (`mismatch`, `unavailable`,
    `storeUnreadable`, `zcashWallet` opening the DB) and `other` ("no such
    conversion"). A failed step returns the reloaded record with `problem`
    set to one of `relayerUnreachable`, `relayerRefused`, `relayerFee`,
    `ethereumUnreachable`, `railgunClosed`, `claimTurn`, `zcashWallet`,
    `depositUnpayable`, `zcashRejected`, `mismatch`, `tokensUnreachable`,
    `routeBlocked` or `other` (the §5.8 problem set; Rust folds the rest).
  - Abandon: `tooLate` once a deposit started or the chain shows the swap.
  - Accept `tokensNeeded`: the maker wants a token and there is no tokens
    client before M4. Nothing opened. Show that conversions are unavailable
    right now and call `privateUsdForwardAbandon(index)`; never retry it in a
    loop. A record left alone ends `nothingSent` within about five minutes of
    its quote's expiry anyway.
- **For part 2: the engine loop** (reference §5.10).
  - For each account of `privateUsdAccountsWithUnfinished`, for each forward
    record with `outcome == null` (`privateUsdForwardRecords`), call
    `privateUsdForwardAdvance` with a fresh `opId`, polling
    `privateUsdActivity(opId)` about every 500 ms for the step label.
  - Nap the smallest `nextPollMs` of the pass: 5 s `opening`, 20 s
    `confirming`, 30 s `depositUnsettled` and `refunding`, 15 s
    `zcashSyncing` and after a failed step (`problem != null`), 0 once the
    record ended. On `Err(busy)` retry after 15 s or on a nudge; ignore
    `Err(cancelled)`. Nudge after accept (accept never advances).
  - Show `problem` only after 60 s of consecutive failures of that `(account,
    index)`; clear the timer on any result without one. `zcashSyncing` is a
    wait, never a problem.
  - Pause (lock, hide, quiesce): `privateUsdCancel(currentOpId)`; on lock also
    `privateUsdClearSessions()`. A cancelled advance stops at its next safe
    point (never between saving a deposit as started and keeping its bytes)
    and returns `cancelled`.
  - Each advance holds the account's driver lock for its whole run (up to a
    minute while the chain catches up after a lock or claim), so keep one
    serial queue per account.

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
  `joint.db` at a time; a second gets `Busy`. M2.7b exercises it; the tip it
  compares against must be fresh (D-50).
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
- **D-24 (M3.8): the home strip as built.** `PrivateUsdHomeStrip` in
  `widgets/mobile/private_usd_home_strip.dart`, passed to `_BalanceCard`
  through its new optional `privateUsdStrip`, under the transparent row:
  - Two columns: "Private USD" and the `≈ Y ZEC` worth on the left; the
    headline amount and the one detail that needs saying on the right
    (refused funds first, as "$Z needs attention" in the danger colour,
    else "+$Y arriving" in the positive colour), then a chevron. One line
    each did not fit 393 px with both the worth and an arriving amount.
  - It uses `AppTypography.labelMedium` and `bodyExtraSmall`: the home's
    label style is private to `mobile_home_screen.dart`. `AppIcons.moneyBag`
    stands in for the E10 artwork.
  - Hidden balances mask the amounts and drop the worth. Its semantics are
    one button, "Open private USD", whose value reads the amounts ("Needs
    attention: $X" while refused).
- **D-25 (M3.9): the Private USD screen as built.** `MobilePrivateUsdScreen`
  wraps `MobilePrivateUsdView`, which Widgetbook and tests build directly.
  It has the total card (headline, `≈ ZEC`, the status line, a refresh
  button, the error line), the buckets card, Assets only when more than one
  dollar token is held, the empty state when the total is 0, the receive
  address card (the plain clipboard: the address is not sensitive; new copy
  "Address copied"), the Activity heading with its empty state, and the info
  sheet. Not in M3: Convert, Send and Withdraw (M5, M7), the banner and the
  guard's conversion exception (M5), the Refunds button (M6), the spending
  note (M7). The empty state does not yet check for a conversion under way
  (M5).
- **D-26 (M3.10): the lifecycle as built.**
  - Lock, account switch and route change are listeners in
    `railgunEngineProvider`; they close the page and stop the bridge. Hiding
    the app stops balance polling and leaves the page to its idle close.
  - The engine registers its drain, resume and page wipe with
    `privateUsdLifecycleProvider`, which `removeAccount` and `resetWallet`
    drain after the Gift Card claims and resume with them.
  - After the Rust delete, `removeAccount` calls
    `deletePrivateUsdAccountData` (the engine key and the balance cache);
    without `deleteWallet` (E5) the page's stored wallet stays, unreadable
    without its key.
  - Once the wallet DB is gone, `resetWallet` calls `wipeRailgunPage()` (the
    engine's wipe, or the channel's when this run built no engine; a
    platform without the host has nothing to wipe), then
    `deletePrivateUsdDirectories()` and `deletePrivateUsdTokenStores()`.
    Either failure is a reset error, like the claim-DB cleanup, so a retry
    finishes it. `deleteAll()` takes the engine keys and balance caches.
  - `private_usd_paths.dart` is not built yet: `wallet_paths.dart` gained
    `getPrivateUsdDirPath`, `getPrivateUsdTokenStorePath`,
    `deletePrivateUsdDirectories` and `deletePrivateUsdTokenStores`, and the
    wrapper waits for its first caller (M4, M5).
- **D-27 (M3.11): the copy file.** `PrivateUsdCopy`, an
  `abstract final class` of consts and builders, with zapp's key on each.
  Two strings are new: the "Address copied" toast and the info sheet's
  "Close". `privateUsdErrorMessage` comes with the M5 error tables.
- **D-28 (M3.12): Widgetbook and capture scenarios cover what M3 shows.**
  Home: the strip with a balance, not used yet, loading, arriving, refused
  and hidden. Screen: default, empty, first load at 42 %, refresh failed and
  refused (plus hidden in Widgetbook). The converting and attention banners
  wait for M5, payment-pending for M7, and tor-unavailable is moot (D-22).
  Checked with `scripts/figma-compare.sh widget --form-factor mobile` in
  both themes. Reference §9.7 updated.
- **D-29 (M3.13): the Kotlin tests as built.** `RailgunBoundaryTest` runs on
  the plain JVM; `RailgunChannelTest` and `RailgunProtocolTest` run on
  Robolectric SDK 34, the only android-all jar cached here (no new test
  dependencies were needed). The cases are zapp's over raw JSON strings,
  with `Message.Event(name, raw)` and the timeout message naming the wire
  method. Added: params must be one JSON object and are spliced unparsed (a
  large number keeps every digit), the page's `INIT` equals
  `RailgunProtocol.INIT`, and `openNewWallet` is not exposed. Moved out:
  scan-data decoding (Dart's `RailgunEvent.decode`) and the `RailgunAddress`
  checksum tests (Rust's `is_valid_railgun_address`). The
  `RailgunSessionTest` parsing cases are in Dart
  (`test/features/private_usd/railgun_models_test.dart`).
- **D-30: the device harness.** `lib/railgun_spike_main.dart` keeps its spike
  name and modes and now drives `RailgunHostChannel` and the page models.
  It does not use `RailgunEngine`, whose address check needs an
  account-derived address; the harness opens a throwaway or given Railgun
  mnemonic. Debug builds only (a release build shows a notice and does
  nothing); it prints the public address, the fee, bucket names and page
  lines with keyed URLs redacted, never params or amounts.
- **D-31 (M5.1): the engine as built.** Plan §3.6 and reference §5.10
  updated.
  - The driver lock is a function, `engine::lock_account(account) ->
    DriverGuard`, over a `tokio::sync::Mutex` per account; `try_lock_owned`
    gives `Busy`. The FRB wrappers take it before they build their runtime;
    `private_usd_delete_account` takes it too, so a step that is still
    running cannot save a record back after a delete.
  - Offers are pruned per account, not across accounts, and a quote made
    before `private_usd_clear_sessions` (a lock) is never held after it: the
    cache keeps a session number that every clear bumps.
  - The maker's `/v1/info` check is cached per network until the next clear
    (zapp checks once per driver; vizor's driver lives for one call).
  - The op registry remembers up to 64 ids cancelled before their call
    registered, so a cancel that overtakes its call on the FRB worker queue
    still stops it.
  - Two more seams: `Clock` (device time and the 2 s catch-up waits, so the
    tests run instantly) and `TokenSource` (D-33).
  - `forward.rs` holds the driver and its Zcash seam, `ForwardZcash`, whose
    real implementation `WalletZcash` sits over the M2 operations, plus
    `ForwardCall`, which builds the real seams for one FRB call
    (`AsyncFnOnce` step).
- **D-32 (M5.2): the FRB surface as built.** Reference §8.2 updated.
  - A new error code, `Cancelled` (both enums): a cancelled call is never a
    failure, so Dart can tell it from one. Part 2 has no Dart switch over
    the codes yet, so nothing else changes.
  - `private_usd_clear_sessions` lands now, not in M4: on lock it drops the
    forward offers and maker checks. M4 adds its issuance sessions to it.
  - `private_usd_forward_abandon(network, account_uuid, store_dir,
    eth_rpc_url, index)` takes no `db_path`: it reads no wallet DB.
  - `ApiForwardRecord` gains `phase: ApiForwardPhase` (the store's phase
    column), for the activity row and the banner without an advance at hand.
    `deposit_confirmations` is set only while the record is under way.
  - `ApiActivity` already lists the reverse activities M6 will report.
    `ApiDirection` is not added: no call uses it yet.
  - `private_usd_unfinished_count`, `…_accounts_with_unfinished` and
    `…_forward_records` never create `swaps.db` (`SwapStore::open_existing`),
    so asking on a wallet that never converted writes nothing.
  - A failed advance step is `Ok` with `problem` set, folded into the §5.8
    problem set by `engine::problem` (`ChainLagging` and `ChainUnreadable`
    become `EthereumUnreachable`, `WrongDeployment` `RelayerUnreachable`,
    the rest `Other`; `RouteBlocked` passes through). Only setup failures,
    `Busy` and `Cancelled` are errors.
- **D-33 (M5): tokens without M4.** M4 waits for N1 (B-5); makers do not
  require tokens today (D20), and the owner disabled them on testnet for now.
  - `engine::TokenSource` is the seam M4 fills: `accept_authorization()`
    (the `Authorization` of a token already held, sent with the accept) and
    `token_required(challenge)`. `NoTokens` holds none.
  - A maker's `tokenRequired` refusal returns `ApiAcceptKind::TokensNeeded`
    with no retry loop. The refusal sent nothing, so the record stays saved
    and unanswered; a repeat accept posts the saved quote again for the same
    index, as the M4 flow will after issuance.
  - `abandon` ends an unanswered record `MakerUnavailable` (the token
    turn-away of reference §5.9 and §5.11 F3a) and an answered one
    `NeverOpened` (zapp's `abandon`, §5.6 step 12). Reference §5.6 updated.
  - The token return (§5.6 step 11) is not collected: nothing is awaited.
- **D-34 (M5.1): the forward refund's sweep.** Reference §5.8 updated.
  - An earlier sweep that may still land is looked for in `joint.db`
    (`joint::find_sent`, from the joint account to any address) before the
    balance is checked: an unmined earlier sweep leaves nothing spendable,
    so the §5.8 order (balance, then the earlier sweep) would wait forever.
  - The sweep pays the account's current receive address
    (`keys::get_address_from_db`), as zapp pays its account's UA. The fee
    limit is `min(320,000, balance − 1)`, refused below 10,000.
  - Every sweep status read imports the joint account (idempotently) and
    syncs `joint.db` first, so a lost `joint.db` heals by rescanning from the
    exact birthday.
  - Forgetting the joint account after the sweep is final is best effort: a
    failure is logged and the swap still ends `Refunded`; deleting the
    account or a reset removes what is left. `joint::forget_joint_account`
    succeeds when the account is already gone.
- **D-35 (M5.1): the deposit.** Reference §5.6 updated.
  - The wait for the main wallet's scan (`ZcashSyncing`) gates only building
    a new deposit: the fully scanned height must reach the live
    lightwalletd tip. Status reads and resending a kept deposit do not wait.
  - A deposit that would spend Sapling notes is refused
    (`DepositUnpayable`) and its proposal released: Rust cannot fetch the
    Sapling parameters, and `swap_deposit_sender.dart` refuses them too. The
    fee preview (`estimate_swap_deposit_fee`) is `None` then, and also for
    any proposal error (zapp treats an SDK failure as no estimate).
  - Accept refuses an offer whose fee preview was `None`, and a
    `max_total_zat` below the deposit (`DepositUnpayable`), before anything
    is saved.
  - The send flow ids are `private-usd-deposit:{account}:{index}` and
    `private-usd-sweep:{account}:{index}`.
- **D-36 (M5.1): payout fees.** Reference §5.6 step 8 already says this; plan
  §3.5 item 8 is narrowed to it.
  - The payout is signed again whenever the fee to pay differs from the saved
    one: the offer's fee within its window, else the relayer's fee now. After
    a claim that did not pay out, that can be a lower fee (zapp
    `aLowerFeeCanFinishASplitClaim…`). On a `400 rejected`, it is signed
    again only if the relayer's fee rose, and posted once more.
  - The 2 USDC cap applies at quote and to every payout signature, the
    refused one's re-signature included. `finishPaid` checks the event's
    relayer and that its fee leaves something, not the cap: the event can
    only carry a fee we signed.
  - The forward claim lock's signature is not saved before it is sent (zapp
    does not either). Losing it costs only a new lock; it reveals nothing.
- **D-37 (M5.1): small mappings.** A quote while a conversion is under way
  is `Busy` (there is no dedicated code); a maker turning a quote down
  (`rejected`, `invalidRequest`) is `AmountRefused`.
- **D-38 (M5.1): reads that authorize.** `ConfirmedSwap.head` is the "now"
  of the fresh check before a reveal (D-7); `hold_claim_lock`, the t0 check
  and the deposit window read `head()` again, as zapp reads `chain.now()`.
- **D-39 (M5): the tests as built.** Plan §10 has the list.
  - `private_usd/tests/fakes.rs`: one shared `World` behind `FakeChain`
    (terms hashed from the eleven words the contract hashes, checked
    against `Terms::hash`), `FakeServices` (the maker and relayer routed by
    path, acting on the chain), `FakeZcash` (with crash points around the
    deposit's saves, through a test-only `store::crash_before_next_commit`),
    `FakeClock`, and real keys, a real maker proof and a real `swaps.db`.
  - The ★ cases, all in `private_usd/tests/forward.rs`:
    `AtomicSwapDriverTest` 21 (`the_happy_path_claims_into_railgun`), 55
    (`an_offer_says_what_arrives_…`), 114 (`a_quote_about_to_run_out_…`),
    214 (`an_accept_that_may_have_opened_…`), 242, 255, 266, 284, 298
    (`an_interrupted_deposit_that_went_out_…`, `…_never_went_out_…`,
    `a_deposit_the_wallet_cannot_pay_…`, `a_deposit_is_sent_again_…`,
    `an_expired_deposit_is_paid_again_only_while_payable`), 398
    (`nothing_is_deposited_into_a_swap_whose_terms_are_off_by_one_…`), 428
    (`a_silent_maker_is_claimed_…`); `AtomicSwapClaimTest` 19–131 (the eight
    `a_refund_…`/`a_sweep_…`/`an_expired_sweep_…` and
    `a_swap_left_under_the_same_id_…` tests), 161–214 (`the_share_stays_…`),
    225–271 (`a_claim_signs_the_offers_fee_…`,
    `a_refused_payout_is_signed_again_only_at_a_higher_fee`), 311
    (`a_claim_revealed_before_an_interruption_…`), 385 and 397
    (`an_accept_refusal_ends_only_when_nothing_can_have_opened`);
    `AtomicSwapSettlementTest` 17–82 (`a_delayed_lock_response_…`,
    `the_lock_and_terms_are_read_again_immediately_before_the_reveal`,
    `an_unconfirmed_open_…`, `an_unconfirmed_claim_lock_…`), 124
    (`an_orphaned_payout_…`).
  - vizor's own: `swap_indices_are_never_reused`,
    `a_crash_around_the_deposit_never_pays_it_twice`,
    `no_deposit_is_built_until_the_wallet_has_scanned_to_the_tip`,
    `a_payout_is_never_signed_above_the_cap`,
    `a_maker_asking_for_a_token_turns_the_accept_away_without_a_retry` and
    `a_concurrent_advance_and_accept_on_one_account_gives_busy_and_leaves_the_record_intact`;
    the lifecycle file's three through the FRB calls.
  - Adapted from zapp: a refund ends at the testnet pins' 2 Zcash
    confirmations, not zapp's default 3; the fees a payout was signed for are
    read from the posted bodies (the keys are real); zapp's
    `beforeClaimSecret` cases change the chain on the third confirmed read,
    the one immediately before the reveal.
- **D-40 (M3.14): the device round's harness.** Plan §10 updated.
  - `integration_test/private_usd_device_test.dart`, tagged `mobile` and
    `private-usd-device`; `dart_test.yaml` skips the new tag, so only the
    runner starts it. It resets the build's testnet wallet (the
    testnet-scoped secure storage, the wallet DB and the files beside it),
    creates one through the UI (the mnemonic screens are never captured),
    runs checks 1–4 of the round and an unlock in one test, and posts its
    timings to the host. Later rounds extend it.
  - `scripts/private-usd/run_device_round.sh` refuses a phone whose
    `com.keplr.vizor` is installed but not debuggable. It records
    `stay_on_while_plugged_in`, sets `svc power stayon usb` and restores the
    original on exit; wipes `app_webview` with `run-as` for a true first
    sync; serves the host checkpoints; samples with `sample_device.sh`;
    keeps logcat; runs the test; installs the release APK with
    `adb install -r` and drives it; and reinstalls a debug build of
    `lib/main.dart`, so the next round's debuggable check passes.
  - `scripts/private-usd/device_round.py`: `serve` (over `adb reverse`: the
    app's renderer process, the app UID's LISTEN rows, PSS,
    `check_sockets.py --onionoo`, screenshots and timings),
    `release-check` (`adb shell input` and `uiautomator dump`: unlock, the
    strip, `/private-usd`, until a refresh stamped after the launch shows;
    logcat scanned for crashes and missing-class errors), `probe` and
    `summarize`. A failed adb call fails a probe rather than reporting
    nothing, and `check_sockets.py` now refuses an unreadable
    `/proc/net/tcp{,6}` the same way.
  - `flutter test` uninstalls an integration test's app when it ends, and
    uninstalls the installed app first when `adb install -r` fails. The
    runner passes `--no-uninstall` and checks debuggability before anything
    installs.
  - Mobile has no manual lock, only `BackgroundAutoLockHost` after 15
    minutes in the background, so the test runs that host's sequence:
    `lock()`, `clearSensitiveStateForLock()`, `go('/unlock')`, then the sync
    provider's.
  - A debug build's Dart VM service listens on loopback. The test reports
    its port (`Service.getInfo()`), and "no loopback listener" means none
    but that one; the release check expects none at all before first use.
  - Tor goes on and off through `networkPrivacyProvider.setTorEnabled`,
    which the settings row calls. The first sync through Tor follows
    `RailgunEngine.wipe()` and a 10 s pause for WebStorage's asynchronous
    delete.
- **D-41 (M3.14): debug builds on a full disk.** `flutter test` always
  builds debug, and cargokit adds the x86 and x86_64 emulator ABIs to every
  debug variant, so `--target-platform android-arm64` still compiled three
  Rust targets. With the dev profile's full debuginfo, the arm64 debug
  target alone grew to about 6 GB, and a first attempt filled the disk
  (ENOSPC). The runner now builds with `CARGO_PROFILE_DEV_DEBUG=0`, as
  `cargo test` does locally, and sets `CARGOKIT_SKIP_EMULATOR_ABIS=true`, a
  new opt-in switch in `rust_builder/cargokit/gradle/plugin.gradle`; unset,
  debug builds are unchanged. An arm64-only debug APK then built in 30 s on
  a warm cache. To recover the disk, the superseded Rust targets under
  `build/rust_lib_zcash_wallet/build/` (aarch64 debug and release, and the
  partial i686 and x86_64 ones) were deleted; they are caches.
- **D-42 (M3.14): the hidden cases are not run on the device.** Regtest needs
  another build and has no Sepolia, a hardware account needs a Keystone or
  a Ledger, and a false kill switch needs a flag URL the phone can reach.
  The availability matrix and the strip tests cover all three.
- **D-50 (M2.7b): `sync_joint_db` reads a fresh tip.** It compared the
  joint birthday with `latest_block_for_transaction`, which returns a tip
  observed up to 15 s earlier (a cache meant for building transactions). A
  deposit mined into the birthday block within those 15 s was therefore
  skipped by that sync: the regtest run's first attempt failed this way. In
  the app it would only have delayed the deposit by a poll. It now opens a
  route-checked channel (`open_lwd_channel_with_cancel`, honouring the scan's
  cancel) and reads the tip with `get_latest_block_recorded`. Numbered D-50 so
  as not to collide with the M3 device round's D-40 onward.

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
- **B-5. `zecswap-tokens` (D-1).** Tokens disabled on testnet by the owner
  (2026-10-13), temporarily; M5–M7 testnet E2E are not blocked by tokens; N1
  still open for when they return. An owner decision is needed before M4:
  options (a)–(c) in plan M0.1 result.
- **B-7. A funded Sepolia Railgun wallet.** It needs test USDC shielded into a
  Railgun wallet whose mnemonic can be passed as `SPIKE_MNEMONIC`. It blocks
  M0.3.4b and M0.3.5b (one transfer proof, `proofMs`, artifact bytes). Part of
  E8.
- **B-8. The M3 device round needs the phone attached (2026-10-14).** The
  Galaxy A35 was not connected over USB when the round was due, and its
  wireless-debugging advert refused connections. Owner: attach it over USB,
  unlock it, and run
  `ANDROID_SERIAL=RZCX40721QZ scripts/private-usd/run_device_round.sh`, or
  ask for the round again.
- **B-6. E1, E2 and E4 are not delivered.** Local stand-ins:
  `~/dev/zapp/zecSwap-zakura` (detached worktree at `d69e3fb` with the §12
  diff; zecSwap has no LICENSE yet) and `~/dev/wallet-libraries-e4` (`391d0b0`
  plus the §6.8 `connect_stream` patch). Nothing built on them, and nothing
  ported from zapp, may be pushed or merged; the M0.3 spike lives on the local
  branch `spike/private-usd-m0`. Since M3 this branch depends on both through
  `rust/Cargo.toml` paths (D-18), and carries zapp's Railgun bundle, JS source
  and the ported Kotlin host, so `feature/private-usd-android` stays local
  until E1, E2 and E4 land.
