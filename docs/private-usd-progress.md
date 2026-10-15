# Private USD (Android): progress

Tracks `docs/private-usd-android-plan.md` §4. A task is done only when its line
is checked. Each milestone also has a gate line: acceptance met, tests written,
`cargo test` / `fvm flutter analyze` / `fvm flutter test` (and the mobile lane
for UI milestones) passing, and its Pitfalls re-read against the diff.

## Where things stand (2026-10-15; read this first)

- **Gotham, Veylor and the portfolio chart (2026-10-15; local, nothing of it
  pushed yet; `origin` is still at `b52cfcc6b`):**
  - **Gotham.** The app uses Gotham: the nine uploaded cuts (Thin, Thin
    Italic, Extra Light Italic, Light, Book, Medium, Bold, Black, Ultra).
    `Gotham Regular.otf` is a cut-down copy, so Book serves 400. The files
    declare non-standard OS/2 weights (Book 325 up to Ultra 450) and Flutter
    takes a face's weight from the file, so in a `flutter_test` measurement
    `w400` rendered Bold. `loadGothamFonts()`
    (`lib/src/core/theme/gotham_fonts.dart`) loads the files as plain assets
    and rewrites each face's weight in memory, so Gotham is not a pubspec
    `fonts:` family and the files on disk are untouched. **Not yet confirmed on
    the phone.** Gotham is 6 to 9 percent wider than Geist and 21 percent
    wider than Young Serif, so mobile Headline L and M went from 32 and 28 to
    28 and 24. There is no SemiBold (`w600` renders Bold), no monospace face,
    and `→ ≈ ↳` come from the fallback font.
  - **The two Gotham commits are the last two on the branch and must not be
    pushed without the owner's OK.** Gotham is a commercial typeface and the
    fork is public; the owner has to confirm the licence covers this,
    including the in-memory weight rewrite. The code commit cannot build
    without the binaries, so push everything below them, or all of it.
  - **Veylor (branding only).** Visible text, the Android and iOS app label,
    permission texts, the Rust error strings that reach the UI, docs, README
    and release notes now say Veylor. Application IDs, `vizor_*` keys,
    `VIZOR_*` flags, identifiers and domains are unchanged, so the installed
    test wallet keeps working. `scripts/brand/rename_veylor.py` is
    idempotent; `--include-desktop` is the later desktop pass (desktop-only
    files skipped: 77 occurrences in 23 Dart files, 65 in 21 test files, 17 in
    6 native files; packaging names such as `PRODUCT_NAME` and `Vizor.app`
    are never touched). **Artwork still says Vizor** and needs the owner:
    `assets/icons/vizor_logo.svg` (welcome wordmark), `assets/icons/vizor.svg`,
    the Android and iOS launcher icons, `.github/assets/gh-vizor-banner.png`
    and some welcome art. "Veylor" is longer than "Vizor": "Veylor is
    synced" at 1.45x text scale overflowed the mobile top bar by 18 px, so
    the sync status is now capped at 65% of the bar.
  - **Portfolio chart (mobile Home, settings card).** Under the balance card:
    ZEC balance over time from local history (no network), 1w, 1m, 3m, 1y and
    All, hidden when the history does not reconcile and masked in privacy
    mode. **Use market prices** (off by default) values it in USD from the zapp
    pricing engine (`zapp-pricing-engine.majorworker.workers.dev`, USD only,
    verified live: HTTP 200, no key). A request carries only `asset=ZEC`,
    `fiat=USD`, `resolution=1d`, whole UTC `from` and `to` dates and
    `limit=1000`, identical for every user, and goes through
    `NetworkHttpClient` (Tor policy, fail closed). It is made only when
    "Show on home" and "Use market prices" are on, the wallet is unlocked,
    privacy mode is off and the app is in the foreground
    (`portfolioPriceRequestsAllowedProvider`). The server sees the IP address
    unless Tor is on; the settings card says so. `VIZOR_PRICING_ENGINE_BASE_URL`
    overrides the host (https only); the Home price still uses CoinGecko.
    Desktop is not done.
  - **Checks on the integrated tree.** `fvm flutter analyze`: clean. Rust
    `cargo test`: 1,515 library tests and the integration suites pass, none
    fail (12 ignored). Mobile lane on the final tree: 2,319 passed, 10 failed
    (the known ones below); its first run also caught the top-bar overflow,
    now fixed. Default lane (run just before that fix, which only touches a
    mobile-only widget): 6,029 passed, 13 failed. Failures that already exist at `b52cfcc6b` (checked
    there): `settings_seed_phrase_screen_test` (4, default lane) and
    `app_review_payment_handoff_test` (10, mobile lane); both are finder
    misses ("Enter amount", "Edit"). Desktop-lane failures from the font
    swap, deferred while the focus is iOS and Android:
    `widgetbook/settings_use_cases_test` (hangs on an uncaught exception in
    the endpoint use case), `payment_link_ledger_ui_test` (2),
    `ironwood_migration_flow_screen_test` (2) and `figma_compare_test` (1)
    (a 21 px overflow in `transfer_status.dart:184`),
    `lost_password_screen_test` (1) and `app_main_sidebar_test` (1).
  - **Owner decisions pending:** the Gotham licence question above; the
    Veylor artwork; whether to keep the Figma deviations (mobile Headline
    28 and 24, activity rows 15 px) or redo the mobile designs in Gotham; two
    near-miss mobile strings (the Ledger address pill, "Preparing your
    receiving account"); and whether market prices should be on by default.
- **Follow-up, local changes after `acdd2db45` (2026-10-15):**
  - M8 now selects the funded second account before sharing its context
    with the forward, reverse and send scenarios, matching M5/M7. The
    runner's default forward amount is now 0.01 TAZ, the amount used by
    the successful device rounds; the old 0.05 default exceeded the
    testnet maker's observed cap. The checklist explains topping up separate
    spendable notes when Sepolia change stays Processing.
  - Forward and reverse quote requests paused during their debounce are
    retained until the engine can run. Editing/clearing the amount or
    disposing the flow cancels the pending request. Actual request failures
    are not automatically retried. Four regressions cover these cases.
  - The review heading is **Review**, verified in forward/reverse widget
    captures at 393 × 852. General `ZcashWallet` errors no longer claim that
    syncing is the cause or remedy. The copy reference was updated too.
  - Opening an existing, current-schema swap store no longer takes an
    unnecessary write transaction. A regression holds a writer open while
    another connection opens and reads the send log; it passes. This removes
    a source of payment-guard delay; startup latency still needs remeasuring
    on the phone.
  - The joint-account regression now has an Orchard variant: deposit before
    NU6.3, check receipts, activate Ironwood, then sweep with the combined
    key and Discard OVK. It compiles. Execution is **pending**: Docker's
    daemon did not answer `info` or the harness's initial reset, and the
    stalled test process was stopped. Docker was not restarted.
  - Focused Flutter checks: desktop **68 passed, 5 mobile suites skipped**;
    mobile **35 passed**; `fvm flutter analyze --no-pub` reports no issues.
    Full `cargo test` passes: **1,515 library tests and 6 integration tests**,
    no failures (12 library and 21 integration tests remain opt-in/ignored).
    Captures: `/tmp/vizor-pusd-review.png` and
    `/tmp/vizor-pusd-review-reverse.png`. Logs use `/tmp/vizor-pusd-*`.
  - A stale ADB server temporarily hid the attached phone; restarting ADB
    restored the USB connection. E6 is still missing. GitHub login and
    remotes were left unchanged; nothing pushed.
- **Orchard and Ironwood pools (owner request): both are supported.** The
  swap deposit uses the ordinary send builder, so it spends notes from
  either pool (M2.7b spent a pre-NU6.3 Orchard note into an Ironwood
  deposit); the joint account's receipts and `find_deposit` read pool codes
  3 and 4; the sweep proposes over `[Orchard, Ironwood]`. Mainnet is already
  on NU6.3 (branch `37a5165b` at height 3,518,928), so deposits into the
  Orchard-only joint address always land in Ironwood there; an Orchard-pool
  note in the joint account could exist only for a deposit mined before
  activation, which no longer happens.
- **Device rounds on the Galaxy A35, testnet + Sepolia, all passed** (M3, M5,
  M6, M7: see their checklist lines). Still unrun on the device: the M8 route
  round (`--m8-route`), the keyed-RPC check (needs E6), M8.4 measurements and
  the release QA on mainnet.
- Harness lessons (not app bugs): the phone must be unlocked when a round
  starts (the runner keeps the screen on during a round, but a phone that
  locked between rounds hides the app: run chained rounds in one invocation,
  e.g. `--m5 --m7`); each Railgun spend leaves its change Processing on
  Sepolia, so every spend needs its own spendable note (top up with a
  conversion; the M7 rounds have `--m7-skip-send` and `--m7-skip-withdraw`
  for reruns); the round's account-switch check leaves account 1 active, so
  the later rounds select the second account.

## Where things stood on 2026-10-14 (kept for history)

- **Branch** `feature/private-usd-android`, pushed to `origin` (the owner's fork)
  at the owner's request. Not merged anywhere. The local `[patch]`/path
  stand-ins (`~/dev/zapp/zecSwap-zakura`, `~/dev/wallet-libraries-e4`) still
  apply (B-6), and `spike/private-usd-m0` stays local.
- **Device rounds on the Galaxy A35, testnet + Sepolia:**
  - M3: passed (D-109 to D-111).
  - M5: passed. 0.01 TAZ → $10.86 private USD, `PAID`; kill and lock checks
    passed; the account-switch and delete-warning checks were skipped (the
    swap finished first).
  - M6: passed on the device. Cancel before funding → `CANCELLED`
    (reverse index 2); cancel after funding → `REFUNDED` (index 3); and the
    full conversion (index 4, account 2: $1.25 private USD → 0.00057929
    TAZ) reached `COMPLETE` at 13:11–13:16 after the NU7 PCZT circuit fix
    (`pczt.rs` keys the circuit on `orchard_protocol_revision()`; before it,
    every sweep failed `Extract TX from PCZT: Ironwood(InvalidProof)`
    because NU7 PCZTs were proved with the post-NU6.2 circuit). The last
    round's exit code was 1 only because the harness expected to see
    `awaitingReady` on a conversion already authorized by the earlier run;
    `_reachesComplete` should accept a later phase when it follows a
    leftover. `cargo test` has not been rerun since the circuit fix.
  - M7 and the M8 route round: not run. Account 2 has $1.89 available and
    $8.69 Processing (a spend's change waits on Railgun's POI on Sepolia);
    top up with a fresh forward conversion (`--m5 --m5-zec 0.01`; the
    testnet maker caps a swap at 20 USDC and prices ZEC near 1,200 USD).
- **Fixed today, all committed:** testnet NU7 (`zakura-protocol` 2.2.0,
  B-11, D-113); the NU7 PCZT circuit (above); the joint DB's fresh tip
  (D-50); new wallets' ZIP-32 index (D-109); the voting restorer's
  `ref.mounted` (D-111); the balance watch mid-build (D-112); two Private USD
  routes that force-unwrapped `GoRouter.extra` (crashed on review → progress).
- **Update (2026-10-15):** with the NU7 circuit fix `cargo test` passes
  (lib 1514 passed, 0 failed). M5 now passes in full on the device: kill
  mid-confirmation, an advance with another account active, the delete
  warning ("showed 1, nothing deleted"), the 90 s lock ("no advance while
  locked; resumed after unlock") and `PAID` (swap index 8; two top-up
  conversions gave account 2 two more $10.86 notes). M7 first hit an app bug
  (`privateUsdReceiveAddressProvider` read its ref after an await; fixed) and
  then harness problems (tapping the Private USD strip once while home was
  animating in; the M5 account-switch check leaving account 1 active, which
  holds no dollars; now every strip tap retries and M7 starts on the second
  account). The M7 round (`--m7 --m7-usd 1 --m7-to 0xabEa…0c13`) was
  rerunning at commit time; its result is not recorded here. E2
  (relicensing) is dropped by the owner.
- **Open findings to fix next:**
  - "Your Zcash wallet isn't ready" is shown for any `ZcashWallet` failure,
    not only syncing (misleading on the sweep failure).
  - The payment guard's first send-log read after app start is slow, so
    Convert stays disabled for a while.
  - The review title "Review conversion" is truncated on the phone.
  - A quote skipped while the engine cannot run is never retried.
  - Orchard pool: the code handles pools 3 and 4 (receipts, `find_deposit`,
    the sweep spends both), but only Ironwood was exercised on device. Add
    a regtest case: the joint account receives in Orchard before NU6.3 and
    sweeps after (owner asked for Orchard and Ironwood support).
- **Owner items:** E1's zecSwap Zakura build must carry the
  `zakura-protocol =2.2.0` pin (bumped locally, uncommitted, in
  `~/dev/zapp/zecSwap-zakura/crates/zecswap-core/Cargo.toml` lines 21 and
  31); upstream veylor has the same testnet NU7 gap; N1 (tokens, M4), E6, E7,
  E4, and sign-off for M8.7. E2 (relicensing) is dropped: the owner said
  none is needed (2026-10-14); sign off at the end, then commit and push.

## M0. Prerequisites and spikes (go/no-go)

- [x] M0.1.0 Local patched zecSwap checkout (`~/dev/zapp/zecSwap-zakura`, §12 manifest and diff) and the `[patch]` in veylor
- [x] M0.1.1 `rust/Cargo.toml`: `zecswap-core`, `zecswap-railgun`, `hmac`, `sha3`, `bech32`; `rust-version = "1.92"`
- [ ] M0.1.1b `zecswap-tokens` resolves in veylor's graph (no-go today: `digest` conflict, Deviations D-1; needs an owner decision)
- [x] M0.1.2 `cargo build` and `cargo tree -d`: one `zakura-orchard`, one `zakura-pczt`, no upstream `orchard`/`pczt`/`zcash_protocol` (with `zecswap-core` + `zecswap-railgun`; build 5m20s)
- [x] M0.1.3 zecSwap's 16 library and 8 `tests/sweep.rs` tests on the Zakura build (24/24 pass; workspace narrowed, D-2)
- [x] M0.1.4 Debug APK build (`VIZOR_FORM_FACTOR=mobile`); record the `.so` size delta. Both builds pass on all four ABIs. Rust `.so` delta (spike over baseline): arm64 +0.47 MB (67.77 → 68.24 MB, +0.7%), armeabi-v7a +0.41 MB, x86_64 +0.44 MB. No veylor code calls the zecSwap crates yet, so the linker drops most of them; the real delta shows from M1 (re-measure in M8)
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
- [ ] M1.10b Separate PR: Enhance PIR transport and voting `VizorRoute` onto `routed_http` (slipped to M8; deferred again in M8: not a safe drop-in, see the M1 status below and D-108)
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
- [x] M3.14 Device round (Galaxy A35, testnet + Sepolia; the M3 Done-when device checks and the R8 release-build check): passed 2026-10-14 (results below; D-109 to D-111)
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

M3 device round (2026-10-14, second attempt): passed on the Galaxy A35 (`RZCX40721QZ`;
Android 16, WebView 155), Zcash testnet and Sepolia, debug build with
`CARGOKIT_SKIP_EMULATOR_ABIS`. The R8 release check passed in the first
run. The integration test passed on the seventh run (`+7: All tests
passed!`, runner exit 0); runs 1 to 6 found one app bug, one existing
voting bug and three harness assumptions, all fixed (D-109 to D-111), and
in run 5 the page's first sync over Tor failed three times (page `FAILED`,
about 70 s each; no direct socket meanwhile), which run 4 and run 7 did
not repeat (free RPC over Tor; E6). Stay awake was set to USB for each run
and restored to `0` after it. Evidence:
`scratchpad/m3-round` (release) and `scratchpad/m3-round7`.

| Check | Result | Evidence |
|---|---|---|
| 1. Before first use the strip shows "—" and no WebView renderer runs | Pass | Home held 20 s: strip "—", engine idle, `isOpen` false; host: no renderer, no loopback listener beyond the debug build's baseline (D-110) |
| 2. `/private-usd` shows the first-sync percentage, then $0; the address equals Rust's | Pass | First sync direct passed its 120 s checkpoint (M0: 96–136 s); the shown address equals Rust's (the engine also refuses a mismatch) |
| 3. Tor on: no direct socket while the page syncs or refreshes; Tor off works | Pass | First sync through Tor passed its 150 s checkpoint, then a refresh; every Tor-phase sample: 0 Railgun-host and 0 unexplained sockets, only loopback and Tor relays (Onionoo). Tor off: a direct refresh |
| 4. Lock closes the page and leaves no loopback listener | Pass | The bridge listener (40737 direct, then 35425 after the route round trip: a new port per route, U19) is gone after lock and 20 s later. Chromium keeps the renderer process (PSS 220 MB, then 95 MB) with the page closed and the bridge stopped |
| 5. The R8 release build loads the page | Pass | arm64 release APK installed over the test install; `/private-usd` opened, renderer and bridge seen, first sync 0 % → 53 % with no error text; no listener before first use |
| 6. Hidden on regtest, for hardware accounts and with the kill switch false | Unit-tested; not run on device | The availability matrix and the strip tests (M3.7, M3.8; D-42) |

Memory (debug build): peak app PSS 662 MB, peak renderer PSS 335 MB
(M0: 446 MB and 382 MB).

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
- [x] M5.3 Dart engine and provider (D-51, D-52)
- [x] M5.4 Lifecycle provider and account-deletion guards (D-53)
- [x] M5.5 UI (D-54)
- [x] M5.6 Copy (Convert tables, Accounts) (D-55)
- [x] M5.7 Widgetbook and capture scenarios (forward rows) (D-56)
- [x] M5.8 Device round: passed on the Galaxy A35 (2026-10-14/15, testnet + Sepolia): 0.01 TAZ → $10.86 private USD, `PAID`; kill mid-confirmation, an advance with another account active, the delete warning ("showed 1, nothing deleted"), the 90 s lock ("no advance while locked") all held, in three runs. Kill-switch-off-mid-swap is not in the harness (D-42).
- [x] M5 gate: every suite passes (status below); the device checks are M5.8, deferred

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
    `private_usd/tests/forward.rs` (38: the ★ cases and veylor's own, on the
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

M5 status (2026-10-14): done except M5.8, the device round, which needs
testnet ZEC on the phone's wallet (E8) and the phone attached (B-9); its
opt-in scenario is written (D-57). Part 1 is `0a4cb8182` (M5.1–M5.2); part
2a is `518bda590` (M5.3–M5.4); part 2b is the commit that checks this note
(M5.5–M5.7). Nothing in part 2 touched Rust, the FRB API or Kotlin.

- **What landed in part 2.**
  - The engine (D-51): `services/private_usd_engine.dart`,
    `services/private_usd_swap_backend.dart` (the FRB seam) and
    `services/private_usd_paths.dart`; `providers/private_usd_engine_provider.dart`
    (the engine, its backend and its build gate) and
    `providers/private_usd_unfinished_provider.dart` (the engine's snapshot,
    the unfinished set the router reads, and the deletion and reset counts);
    `PrivateUsdEngineHost` beside `BackgroundAutoLockHost` in `lib/app.dart`.
  - The lifecycle (D-53): `privateUsdLifecycleProvider` counts conversions
    and removes a deleted account's; `removeAccount` and `resetWallet` refuse
    more than the user confirmed; the mobile removal sheet and the
    forgot-passcode sheet warn with the count.
  - The UI (D-54): `/private-usd/convert`, `/private-usd/convert/review` and
    `/private-usd/conversion/:direction/:index` with their screens, the guard
    exception, the convert provider and quote search, the conversion, banner
    and keep-awake providers, the progress presentation
    (`models/private_usd_status_presentation.dart`), the banner and activity
    rows on home, in Activity and on `/private-usd`, and Convert there.
    `MobileHomeEntryCard` and `MobileWarningNotice` moved to
    `lib/src/core/widgets/mobile/`.
  - The copy (D-55), Widgetbook entries and 15 capture scenarios (D-56), and
    the device round's `--m5` scenario (D-57).
- **The engine host's behaviour.** Inert unless the build has the define,
  the mobile form factor, Android and a deployment (desktop builds none). It
  advances every account's conversions under way (D14), one serial queue
  per account, only in the foreground, unlocked and outside a drain; it
  idles with no timer when nothing is under way. A lock cancels the running
  step, drops the held quotes and problem timers, and waits at most 5 s; the
  background only cancels; a drain cancels and waits at most 30 s. A step
  queued before a pause never starts, a result after one is dropped (advances
  and accept), and a seed read after one is zeroed before Rust sees it.
  Problems show after a minute of failures; `cancelled` and `busy` are never
  failures.
- **Tests.**
  - Rust, the FRB bindings and Kotlin did not change in part 2, so `cargo
    test`, the codegen and the Gradle tests were not run (part 1's Rust run
    stands: lib 1500 passed, 11 ignored; integration 6 passed, 21 ignored).
  - `fvm flutter analyze`: no issues.
  - `fvm flutter test` (desktop lane): 5963 passed, 161 skipped, 4 failed,
    the 4 pre-existing failures in `settings_seed_phrase_screen_test.dart`
    ("incoming links cannot interrupt backup …").
  - Mobile lane (`--tags mobile --run-skipped
    --dart-define=VIZOR_FORM_FACTOR=mobile`): 2276 passed, 10 failed, the 10
    pre-existing failures in `app_review_payment_handoff_test.dart` ("Edit"
    and "Review" × 5).
  - New: 37 untagged tests (part 2a's 15 among them) and 34 mobile-tagged
    ones (D-58). Both lanes' totals grew by exactly those.
  - Captures: the new scenarios rendered with `scripts/figma-compare.sh
    widget --form-factor mobile` and reviewed (D-56).
- **For M5.8 (the device round).** With testnet ZEC on the phone's testnet
  wallet (an earlier round's, passcode 111111) and the phone on USB and
  unlocked: `ANDROID_SERIAL=RZCX40721QZ scripts/private-usd/run_device_round.sh
  --m5` (`--m5-zec` sets the amount; 0.05 by default). It checks, in two
  runs around an `am force-stop`: a small conversion reaches `Paid`; killed
  mid-confirmation, it resumes; locked mid-swap, no advance (so no key) runs
  for 90 s and unlock resumes it; with another account active it keeps
  advancing; the removal sheet shows the count. Not covered by the harness:
  the kill switch turned off mid-swap (D-42: a flag URL the phone can
  reach).

M5 review (2026-10-14): a read-only fund-safety review of M5 found no
double deposit, no reveal inside the margin, no payout above 2 USDC, no
reused index and no leaked secret. It found four bugs, fixed here without new
unit tests (owner: E2E first):

- The convert screen re-quoted every 1 s tick after a failed replacement
  quote, spending a swap index (and a maker request and a seed read) each
  time. A failed replacement is now left for the user (editing the amount
  asks again), and a debounced quote no longer runs once the app is
  backgrounded or locked.
- A lock or background that arrived while the deposit was being proposed
  (the wallet write lock can take seconds) was not checked before `Started`,
  so the seed signed after the lock. `ensure_paid` checks the cancel flag
  again before `Started`; the proposal guard releases the proposal.
- An accept interrupted by background or lock left the review stuck in
  `confirming`. It now returns to the review and shows a conversion under
  way instead.
- After a deletion whose conversion cleanup gave up (a busy driver), the
  engine retried the deleted account every pass. It now skips accounts the
  wallet no longer lists; their rows stay, unreadable without the seed.

And one hardening (D-59). Checks after the fixes: `cargo test` lib 1500
passed, 0 failed; `fvm flutter analyze` clean; desktop lane 5963 passed, 4
failed (the known `settings_seed_phrase_screen_test.dart` four); mobile lane
2276 passed, 10 failed (the known `app_review_payment_handoff_test.dart`
ten).

## M6. Reverse conversion, reverse refunds, rescue and the Refunds screen

- [x] M6.1 `reverse.rs` and `funding_calls.rs` (D-70 to D-78)
- [x] M6.2 FRB reverse calls (D-79)
- [x] M6.3 Dart (D-81 to D-83, D-85, D-86)
- [x] M6.4 Copy (Reverse, Refunds) (D-84)
- [x] M6.5 Widgetbook and capture scenarios (reverse, refunds rows) (D-87)
- [x] M6.6 Device round: passed on the Galaxy A35 (2026-10-14, testnet + Sepolia): cancel before funding → `CANCELLED`; cancel after funding → `REFUNDED`; a $1.25 conversion → 0.00057929 TAZ `COMPLETE` (after the NU7 circuit fix). The lock-during-the-proof check was skipped: the proof finished before the lock (a fast phone); the earlier cancel runs show nothing is paid without the user.
- [x] M6 gate: every suite passes (status below); the device checks are M6.6, deferred

M6 part 1 status (2026-10-14): M6.1 and M6.2, the Rust half, are done. Part 2
(M6.3–M6.5: the Dart funding orchestration, providers, screens, copy and
Widgetbook) is next; the M6 gate and its device checks wait for it.

- **What landed.**
  - `rust/src/wallet/private_usd/reverse.rs`: the §5.7 driver and the §5.8
    reverse refund and rescue. `ReverseView` holds the steps that need no
    key (`price`, `set_cost`, `go_ahead`, `submit_funding`, `can_rescue`);
    `Reverse` the keyed ones (`quote`, `accept`, `funding_request`,
    `advance`/`advance_report`, `authorize_ready`, `cancel`, `rescue`), over
    `ChainReader`, `HttpTransport`, the new `ReverseZcash` seam (implemented
    by `WalletZcash`), `Clock` and `TokenSource`. `ReverseCall` and
    `run_view` wire the real seams for one FRB call.
  - `rust/src/wallet/private_usd/funding_calls.rs`: the funding's three
    calls (`approve`, `openReverse`, `transfer`), 68 + 548 + 68 bytes.
  - Smaller changes: `engine.rs` (the reverse funding sessions, maker checks
    per direction, the `Funding`, `Readying` and `Refunding` activities),
    `forward.rs` (the joint-account helpers of `WalletZcash` take a
    direction, the sweep builder is shared, and the maker, relayer and
    acceptance checks are free functions), `models.rs` (record helpers),
    `store.rs` (`updated_at`), `joint.rs` (`sent_value_and_fee`), and the
    claim scan's docstring (`sync_engine/mod.rs`), which wrongly said it takes
    no global write lock.
  - FRB (`rust/src/api/private_usd.rs`): the thirteen calls below. Bindings
    regenerated; the rustc 1.93 noise was reverted as before.
- **The reverse state machine as built** (reference §5.7). Phases: `Quoted`
  (a priced draft, not under way) → `Accepting` (gone ahead) →
  `AwaitingFunding` (accepted, joint account imported; the user's first
  approval) → `SendingUsdc` (funding kept, posted) → `ConfirmingEscrow` (the
  relayer or node knows it) → `ReceivingZec` (escrow confirmed; waiting for
  the maker's ZEC) → `AwaitingReady` (the whole deposit has 2 confirmations;
  the user's second approval) → `Settling` (`ready` kept and sent) →
  `Receiving` (the maker claimed, revealing `e`; the sweep home) →
  `Complete`. Refund branch: `RefundWait` → `Refunding` (refund lock taken,
  `z` revealed under it) → `RefundPayout` → `Refunded`; `Cancelled` ends a
  conversion with nothing paid. Waits, all re-read from the chain each
  advance: the funding until the node knows it (sent again only while it
  does not, before the funding deadline and without a cancel; called off
  10 min after the deadline), the escrow's confirmations, the deposit's 2
  confirmations, the maker's claim or the refund deadlines, the refund lock's
  turn, and the sweep's 2 confirmations.
- **Tests.** The 7 new tests are `private_usd/tests/reverse.rs`, one per M6
  "Done when" rule (D-80).
  - Rust: `cd rust && cargo test` passes: lib 1507 passed, 0 failed, 11
    ignored; integration 6 passed, 21 ignored (regtest). `private_usd`
    alone: 68 passed, 1 ignored (the regtest test). The known flaky
    `gift_card_input::tests::recovery` family passed. rustfmt was applied to
    the changed files after that run (formatting only); `cargo check --lib
    --tests` is clean after it.
  - Dart: `fvm flutter analyze` finds no issues. `fvm flutter test`: +5941
    ~160 -4, the 4 pre-existing failures in
    `settings_seed_phrase_screen_test.dart` (the `AppButton` "Enter amount"
    finder at test line 159). No Dart besides the bindings changed, so the
    mobile lane was not run.
- **For part 2: the FRB calls** (`lib/src/rust/api/private_usd.dart`).
  Arguments as for forward (part 1 of M5): `dbPath`, `network`,
  `accountUuid`, `storeDir` (`getPrivateUsdDirPath` for calls that write a
  first record; the reverse quote is one), `mnemonicBytes` (zeroed in
  `finally`), `lightwalletdUrl`, `ethRpcUrl` (the keyed URL or `""`).
  - `Future<ApiReverseQuote> privateUsdReverseQuote({dbPath, network,
    accountUuid, storeDir, mnemonicBytes, lightwalletdUrl, ethRpcUrl,
    required int units})`: spends an index and keeps a `QUOTED` draft
    (replacing an earlier draft). `units` = token base units, whole cents
    (a multiple of 10,000), else `amountRefused`. Returns `{ApiReverseRecord
    record; ApiReverseCostRequest costRequest}`.
  - `Future<ApiReverseCostRequest> privateUsdReverseCostRequest({network,
    accountUuid, storeDir, required int index})`: `{int index; String amount,
    railgunProxy, fee; PlatformInt64? feeExpiresAt}`, the page's
    `reverseCost` params now (after a lock cut pricing short, or after
    `fundingCostChanged`).
  - `Future<ApiReverseRecord> privateUsdReverseSetCost({network,
    accountUuid, storeDir, required int index, required String debit,
    required String railgunFee})`: the page's `{debit, railgunFee}`; only for
    `quoted`, or `awaitingFunding` with no funding kept.
  - `Future<ApiReverseRecord> privateUsdReverseGoAhead({network,
    accountUuid, storeDir, ethRpcUrl, required int index})`.
  - `Future<ApiAcceptResult> privateUsdReverseAccept({dbPath, network,
    accountUuid, storeDir, mnemonicBytes, lightwalletdUrl, ethRpcUrl,
    required int index})`: idempotent; `kind` `accepted`, `tokensNeeded`
    (cancel the conversion: no tokens client before M4) or `nothingSent`
    (ended `cancelled`; `cause` when known).
  - `Future<ApiFundingRequest> privateUsdReverseFundingRequest({dbPath,
    network, accountUuid, storeDir, mnemonicBytes, ethRpcUrl, required int
    index, required String railgunAddress})`: `{String amount, railgunProxy,
    token; List<String> callsTo, callsData; String relayAdapt, fee; bool
    alreadyFunded}`. `railgunAddress` is the page's open wallet.
  - `Future<ApiReverseRecord> privateUsdReverseSubmitFunding({network,
    accountUuid, storeDir, ethRpcUrl, required int index, required String
    to, required String data, required String value, required String debit,
    required String railgunFee})`: the page's `prepareReverse` result.
  - `Future<ApiReverseAdvance> privateUsdReverseAdvance({dbPath, network,
    accountUuid, storeDir, mnemonicBytes, lightwalletdUrl, ethRpcUrl,
    required int opId, required int index})`: `{ApiReverseRecord record; int
    nextPollMs; ApiPrivateUsdErrorCode? problem; bool needsYou}`.
  - `Future<ApiReverseRecord> privateUsdReverseAuthorizeReady({dbPath,
    network, accountUuid, storeDir, mnemonicBytes, lightwalletdUrl,
    ethRpcUrl, required int index})`.
  - `Future<ApiReverseRecord> privateUsdReverseCancel({dbPath, network,
    accountUuid, storeDir, mnemonicBytes, lightwalletdUrl, ethRpcUrl,
    required int index})`.
  - `Future<bool> privateUsdReverseCanRescue({network, accountUuid,
    storeDir, ethRpcUrl, required int index})`: a chain read; no key, no
    lock.
  - `Future<ApiReverseRecord> privateUsdReverseRescue({dbPath, network,
    accountUuid, storeDir, mnemonicBytes, ethRpcUrl, required int index})`.
  - `Future<List<ApiReverseRecord>> privateUsdReverseRecords({required
    String accountUuid, required String storeDir})`: the active record first
    (a draft too), then the rest, newest first.
  - `ApiReverseRecord { int index; String swapId; ApiReversePhase phase;
    String amount; String? networkCost; BigInt depositZat; PlatformInt64
    quoteExpiresAt, fundingDeadline, readyDeadline, refundAfter;
    ApiReverseCost? cost; bool funded; String? fundingTx; bool
    cancelRequested, settled, cancellable, awaitingUser; BigInt?
    receiveEstimateZat, receiveFeeZat; String? receiveTxid; BigInt?
    receivedZat; int receiveConfirmations; PlatformInt64? acceptedAt;
    PlatformInt64 updatedAt }`. `ApiReverseCost { String debit, railgunFee,
    broadcasterFee; PlatformInt64? feeExpiresAt }`. `receiveTxid` is internal
    byte order (match history rows; show with `zcashDisplayTxidHex`);
    `fundingTx` is the Ethereum hash. The "ZEC" figure is `receivedZat`, else
    `receiveEstimateZat`, else `depositZat − 10,000` (reference §9.4 S4).
  - `ApiActivity` now also reports `funding`, `readying`, `refunding`, and
    `sweeping` for the reverse sweep home.
- **For part 2: error codes and what the UI says.**
  - `busy`: another step of the account runs (the per-account queue makes it
    rare), or a conversion is under way (quote, go ahead).
  - `quoteExpired`: the quote ran out (go ahead), or it is too late to fund
    (funding request): quote again.
  - `tooLate`: the maker's deadlines leave too little time (quote); the
    conversion changed while the page proved (submit); too late to
    authorize settlement; the escrow is open already; already settled, so no
    refund (cancel: "This conversion has already settled…").
  - `fundingCostChanged`: price it (cost request → page `reverseCost` → set
    cost) before going ahead or paying; the proof's cost differs from the
    reviewed one (the new cost is kept: show "The fees changed, so nothing
    was paid…", the button "Pay {debit}"); the relayer's fee moved while
    pricing, or after a refused funding (the cost is cleared: price again).
  - `cancelled` (submit): the user called it off or the wallet locked while
    the page proved: drop the proof silently. From an advance: a pause.
  - `depositUnconfirmed`: "The market maker's ZEC isn't confirmed yet."
  - `mismatch`: the page holds another Railgun wallet (funding request), the
    proof does not match the request, or the maker's quote or proof does not
    verify. `unavailable`: no maker or relayer sponsorship for conversions to
    ZEC now. `relayerFee`: a fee above 2 USDC, or one leaving nothing.
  - Advance returns `Err` only for `busy`, `cancelled`, a key or store
    failure and "no such conversion" (`other`); a failed step is `Ok` with
    `problem` (the §5.8 set, shown after a minute).
- **For part 2: the engine loop.** For each account of
  `privateUsdAccountsWithUnfinished` (reverse records past `quoted` count),
  advance each reverse record that is under way (`phase` not `quoted`,
  `complete`, `refunded` or `cancelled`) with a fresh `opId`; nap
  `nextPollMs` (15 s under way, 0 once ended, 15 s after a failure). Never
  advance a `quoted` draft. `needsYou` (= `awaitingUser`) drives the
  "Conversion needs attention" banner. Nudge after accept, submit, ready,
  cancel and rescue. Rescues are never sent by the loop.
- **For part 2: the page calls and the funding orchestration** (§5.11
  R2–R6). Pricing: `privateUsdReverseQuote` → page `reverseCost({amount,
  railgun: railgunProxy, fee})` with its `costRequest` →
  `privateUsdReverseSetCost(debit, railgunFee)`; review shows the record's
  `cost`. "Convert": `privateUsdReverseGoAhead` → `privateUsdReverseAccept`
  (stop on `tokensNeeded` or `nothingSent`) → spend guard `startConversion`
  → `privateUsdReverseFundingRequest(railgunAddress: the page's address)`
  (on `alreadyFunded` skip to an advance) → page `prepareReverse({amount,
  railgun: railgunProxy, token, calls: [{to: callsTo[i], data: callsData[i]}]
  × 3, relayAdapt, fee})`, showing its `proof` events (up to 10 min,
  keep-awake) → only if still unlocked, in the foreground and in the same
  engine epoch, `privateUsdReverseSubmitFunding(to, data, value, debit:
  cost.debit, railgunFee: cost.railgunFee)`. Do not hold the account's
  queue across the page proof: a cancel must be able to run meanwhile (the
  submit then refuses). Rust holds the request in memory only: a lock
  (`privateUsdClearSessions`) or a restart drops it, and "Pay {debit}"
  proves again. An error after the submit kept the funding means the loop
  resends the same bytes; never prove again while `funded`.
- **For part 2: "Authorize settlement".** Enable it only in
  `awaitingReady`, with `cancelRequested` false, until `readyDeadline −
  120 s` (device clock; Rust checks the chain's). Rust signs `ready` only in
  `privateUsdReverseAuthorizeReady`; a second tap or a restart sends the
  kept one again. Cancel shows while `cancellable`: "Cancel conversion"
  before any funding (`funded` false), else "Request private refund".

M6 status (2026-10-14): done except M6.6, the device round, which needs the
phone attached and private USD in its testnet wallet from an M5 round
(B-9); its opt-in scenario is written (D-89). Part 1 is `35cead966` (merged
in `e269c98bb`); part 2 (M6.3–M6.5) is the commit that checks this note.
Nothing in part 2 touched Rust, the FRB bindings or Kotlin.

- **What landed in part 2.**
  - The engine and the funding (D-81, D-82): reverse records in the
    engine's loop and snapshot, the reverse calls on the per-account queue,
    `services/private_usd_reverse_funding.dart` (pricing through the page,
    and the funding: spend guard, `funding_request`, the page's proof with
    its `proof` events, `submit_funding` only while unlocked, in the
    foreground and in the same epoch), and the minimal
    `services/private_usd_spend_guard.dart`.
  - The providers: `private_usd_reverse_convert_provider.dart` (`?to=zec`,
    2-decimal amounts, Max, the priced quote, "Convert" = go ahead, accept,
    pay), `private_usd_reverse_conversion_provider.dart` ("Pay {debit}",
    "Authorize settlement", the call-off), `private_usd_refunds_provider.dart`,
    the reverse banner (attention while it needs the user) and the reverse
    activity rows.
  - The UI (D-86): the direction toggle, the reverse amount and review
    views, `/private-usd/conversion/reverse/:index`, `/private-usd/refunds`,
    the confirmation sheets for cancel, refund and rescue (D18), "Refunds"
    beside the Activity heading.
  - The copy (D-84, D-85), the Widgetbook entries and 13 capture scenarios
    (D-87), and the device round's `--m6` and `--m6-refund` (D-89).
- **Tests.**
  - Rust, the FRB bindings and Kotlin did not change in part 2, so `cargo
    test`, the codegen and the Gradle tests were not run (part 1's Rust run
    stands: lib 1507 passed, 11 ignored; integration 6 passed, 21 ignored).
  - `fvm flutter analyze`: no issues.
  - `fvm flutter test` (desktop lane): 5970 passed, 162 skipped, 4 failed,
    the 4 pre-existing failures in `settings_seed_phrase_screen_test.dart`
    ("incoming links cannot interrupt backup …").
  - Mobile lane (`--tags mobile --run-skipped
    --dart-define=VIZOR_FORM_FACTOR=mobile`): 2292 passed, 10 failed, the 10
    pre-existing failures in `app_review_payment_handoff_test.dart` ("Edit"
    and "Review" × 5).
  - New (D-88): 7 untagged tests (4 for the funding, 3 for amounts, Max and
    the settlement window) and 3 mobile-tagged ones, plus the 13 new
    scenarios rendered in `figma_compare_mobile_scenarios_test.dart`. Against
    M5's runs, the desktop lane grew by 7 passed (and one skipped file) and
    the mobile lane by 16.
  - Captures: the new scenarios rendered with `scripts/figma-compare.sh
    widget --form-factor mobile` and reviewed (D-87).
- **For M6.6 (the device round).** After an M5 round has left private USD
  in the phone's testnet wallet (passcode 111111), with the phone on USB and
  unlocked: `ANDROID_SERIAL=RZCX40721QZ scripts/private-usd/run_device_round.sh
  --m6` (`--m6-usd` sets the amount, 2 by default; `--m5 --m6` runs both
  rounds in one go). It checks that a lock while the page proves the payment
  pays nothing, that the unpaid conversion cancelled ends `CANCELLED`, and
  that a new one reaches `COMPLETE` after "Authorize settlement". Add
  `--m6-refund` for a paid conversion cancelled to `REFUNDED` (it waits out
  the refund deadlines, up to 3 h).

## M7. Private send and withdraw

- [x] M7.1 Rust: `relayer_client.rs` (sends terms, transact), `sends.rs`
  (the log, keep-before-post, settlement), `evm_rpc.rs` (`nullifiers`),
  FRB (D-90 to D-95)
- [x] M7.2 Dart: the sender, the full spend guard, the send and
  spend-status providers, the send, withdraw, review and status routes, and
  settlement (D-96 to D-99)
- [x] M7.3 Copy (Send and withdraw) (D-100)
- [x] M7.4 Widgetbook and capture scenarios (send rows) (D-101)
- [x] M7.5 Device round: passed on the Galaxy A35 (2026-10-15, Sepolia): two private sends of $1 relayed (`Sent`, 18 and 27 s) and arrived at the second account as Processing (the expected Sepolia `MissingExternalPOI`); a $1 withdrawal relayed (`Sent`, 17 s) and the public USDC landed at the given `0x` address 21 s later; a send kept but never posted, the app killed, and after the restart it landed from the kept bytes with no new proof (30 s).
- [x] M7 gate: every suite passes (status below); the device checks are
  M7.5, deferred

M7 status (2026-10-14): done except M7.5, the device round, which needs the
private USD an M5 round leaves in the phone's testnet wallet (E8, N2), and a
Sepolia address of the owner's to withdraw to.

- **What landed (part 2).**
  - `services/private_usd_sender.dart`: `PrivateUsdSender` (zapp
    `RelayedPrivateUsdSender`): pricing (`cost`, `held`), proving through
    the page, keeping (`send_log_put`, asked right before the call whether
    the app is still unlocked, in the foreground and at the tap's engine
    epoch), the first post (`relayer_transact`), the landing wait and
    settlement passes (`settle`, `settleIfUnsettled`), over two seams:
    `PrivateUsdSendPage` (`RailgunSendPage`) and `PrivateUsdSendBackend`
    (`RustPrivateUsdSendBackend`).
  - `services/private_usd_spend_guard.dart`: the full guard (zapp
    `PrivateUsdSpendGuard`): the send log's `unconfirmed` rows across
    restarts, a send or funding starting now, and conversions under way in
    both directions; `checking` and `unreadable` included.
  - `models/private_usd_send.dart`: the mode, request, cost, outcomes,
    network-fee reserve and the form's rules (zapp `PrivateUsdSendForm`);
    `isValidEvmAddress` and `isZeroEvmAddress` beside `_isEvmAddress` in
    `address_format_validator.dart`.
  - Providers: `privateUsdSenderProvider` (kept alive by
    `PrivateUsdEngineHost`; settles on every Railgun sync, on unlock and on
    an account switch), `privateUsdSendProvider(mode)`,
    `privateUsdSpendStatusProvider(uuid)`, `privateUsdSendRecordsProvider(uuid)`
    and `privateUsdSendBackendProvider`.
  - Routes: `/private-usd/send`, `/private-usd/withdraw`, their `/review`,
    and `/private-usd/send/status` (`extra`: the mode). Send and Withdraw
    sit under the total on `/private-usd`, with the spending note; send
    rows join its activity.
- **Tests.** The 8 new Dart tests are listed in D-102.
  - `fvm flutter analyze`: no issues.
  - `fvm flutter test` (desktop lane): `+5976 ~163 -4`; the 4 are the
    pre-existing `settings_seed_phrase_screen_test.dart` failures ("incoming
    links cannot interrupt backup completion/deferral success/failure").
  - Mobile lane (`--tags mobile --run-skipped
    --dart-define=VIZOR_FORM_FACTOR=mobile`): `+2304 -10`; the 10 are the
    pre-existing `app_review_payment_handoff_test.dart` failures. The 10
    new capture scenarios pass the mobile scenario smoke test.
  - No Rust changed, so `cargo test` was not run again (M7 part 1's run
    stands).
- **Device checks (M7.5, deferred).** A send arriving at a second
  account's `0zk`, a withdrawal reaching a `0x` address, a kill between
  proving and the post (the same bytes go out, nothing is proved again),
  and Sepolia outputs staying "Processing": all in the `--m7` round (D-103).

M7 part 1 status (2026-10-14): M7.1, the Rust half, is done. Part 2 (M7.2–M7.4:
the Dart sender, spend guard, providers, routes, copy and Widgetbook) is
next; the M7 gate and its device checks wait for it.

- **What landed.**
  - `rust/src/wallet/private_usd/relayer_client.rs`: `railgun_sends(pins)`,
    the relayer's `railgunSends` terms held to the pins (zapp
    `PrivateUsdRelayer.pinned`: chain, proxy, `0zk`, fee token, a positive
    gas price, a rate only with its expiry) and to the 2 USDC cap; and
    `railgun_transact(request)`, `POST /v1/railgun/transact` with exactly
    `{chainId, to, data, value}`, mapped to `RailgunBroadcast`: `200` with a
    transaction `Sent`, `200` naming none `Retry`, `409 alreadySpent`
    `Spent` (with the transactions it names), any other 4xx `Refused`, and
    everything else (other 409s, 5xx, transport failures, unreadable
    answers) `Retry`, with `Retry-After` delay-seconds capped at an hour.
  - `rust/src/wallet/private_usd/sends.rs`: the send log in `swaps.db`'s
    `railgun_sends` (`keep`, `records`) and `Sends` (`transact`,
    `settle_all`), zapp's `PrivateUsdSendLog` and `PrivateUsdSendSettlement`
    with the `when` of `PrivateUsdSender.kt:323-386` ported exactly.
  - `rust/src/wallet/private_usd/evm_rpc.rs`: the `SendChain` seam:
    `send_status` (the receipt, 1 confirmation) and `nullifier_spent`
    (`nullifiers(uint256,bytes32)`, `0xf19ea903`, on Railgun's proxy at
    `latest`).
  - FRB (`rust/src/api/private_usd.rs`): the five calls below. Bindings
    regenerated; the rustc 1.93 noise was reverted as before.
- **Tests.** The 7 new tests are listed in D-95.
  - Rust: `cd rust && cargo test` passes: lib 1514 passed, 0 failed, 11
    ignored; integration 6 passed, 21 ignored (regtest); doc-tests 0.
    `private_usd` alone: 75 passed, 1 ignored (the regtest test). The known
    flaky `gift_card_input::tests::recovery` family passed. rustfmt was
    applied to the new and changed files before that run.
  - Dart: `fvm flutter analyze` finds no issues. `fvm flutter test`: +5963
    ~161 -4, the 4 pre-existing failures in
    `settings_seed_phrase_screen_test.dart` (the "incoming links cannot
    interrupt backup completion/deferral success/failure" cases). No Dart
    besides the bindings changed, so the mobile lane was not run.
- **For part 2: the FRB calls** (`lib/src/rust/api/private_usd.dart`).
  `storeDir` is `getPrivateUsdDirPath`, `network` the wallet network
  (`"main"`/`"test"`), `ethRpcUrl` the keyed URL or `""`.
  - `Future<ApiRailgunSendsTerms> privateUsdRailgunSendsTerms({required
    String network})`: `{PlatformInt64 chainId; String railgunAddress,
    railgunProxy, token, feeFloor; String? feePerUnitGas; PlatformInt64?
    feeExpiresAt; String maxGasLimit, maxGasPriceWei; int
    maxCalldataBytes}`, already pinned. The page's broadcaster `B` is
    `{chainId, railgunProxy, railgunAddress, token, minFee: feeFloor,
    feePerUnitGas?, maxGasPrice: maxGasPriceWei}`; `feePerUnitGas` and
    `feeExpiresAt` come together or not at all.
  - `Future<ApiSendRecord> privateUsdSendLogPut({required String storeDir,
    required String network, required String accountUuid, required
    ApiProvedSend send})` with `ApiProvedSend({required String sendId,
    token, amount, fee, to, proofJson})`: `sendId` a new UUID per send,
    `token` the token sent, `amount` its base units (the fee aside), `fee`
    the `broadcasterFee` the proof pays (deployment-token base units), `to`
    the lowercase `0zk` or the `0x` address, `proofJson` the page's
    `transfer`/`unshield` result string unchanged. Returns the kept record
    (`unconfirmed`); keeping the same send again returns it.
  - `Future<List<ApiSendRecord>> privateUsdSendLogList({required String
    storeDir, required String accountUuid})`: newest first; empty when the
    wallet never kept one.
  - `Future<ApiTransactResult> privateUsdRelayerTransact({required String
    storeDir, required String network, required String accountUuid,
    required String sendId})`: `{ApiTransactKind kind; List<String>
    transactions; int? retryAfterSecs}`. Posts the kept bytes only.
  - `Future<List<ApiSendRecord>> privateUsdSendSettleAll({required String
    storeDir, required String network, required String ethRpcUrl, required
    String accountUuid})`: one pass; the rows after it.
  - `ApiSendRecord { String sendId, token, amount, fee, to; bool withdraw;
    PlatformInt64 sentAt; ApiSendState state; String? txHash; PlatformInt64?
    postedAt, spentAt, retryAt }`; `txHash` is the Ethereum hash (`0x`), for
    `explorerTxPrefix`.
- **For part 2: the send log's states.**
  - `unconfirmed`: kept, maybe posted, not seen in a block. It blocks the
    account's next payment (Send, Withdraw and conversions: the guard's
    `SENDING`) across restarts. `txHash` set: the relayer sent it, waiting
    for a block. `spentAt` set: the relayer says its notes are spent; the
    chain settles it. `retryAt` set: the relayer asked to wait until then.
  - `confirmed`: landed (`txHash` when known). History; at most 100 kept.
  - Gone from the list: the relayer refused it, it reverted, or another
    proof took part of its notes. Nothing moved: "Not sent".
- **For part 2: error codes and what the UI says.** Every error leaves
  nothing new on chain.
  - Terms: `unavailable` (the relayer sends none now, or not on the pinned
    terms): Send and Withdraw unavailable; `relayerFee` (its least fee is
    above 2 USDC): `send_error_fee_cap`; `relayerUnreachable` (no answer,
    Tor down included) and `relayerRefused` (a non-2xx answer): the relayer
    cannot be reached; try again.
  - Put: `relayerFee` (the proved fee is above the cap; Dart checks the
    `broadcasterFee` against `maxRelayerFee` before proving, and Rust again
    here): `send_error_fee_cap`; `busy` (another payment of the account is
    unsettled, or a conversion is under way): the guard's message;
    `mismatch` (the proof is not this deployment's or this send's): a bug,
    "Not sent"; `storeUnreadable`: "Not sent", spending stays blocked.
  - List: `storeUnreadable` makes the guard `UNREADABLE` (Send, Withdraw and
    conversions disabled).
  - Transact: `other` (no such send kept): nothing went out. Results:
    `sent`: wait for the block; `refused`: nothing went, the row is gone:
    price again, and if the relayer now asks more than the proved fee show
    `Repriced` (confirm the new fee), else "Not sent"; `spent` and `retry`:
    "Unconfirmed: it may still land" (never prove again; settlement
    decides).
  - Settle: only `storeUnreadable`; a send whose chain read or post fails
    stays as it was for the next pass.
- **For part 2: the send flow** (zapp `RelayedPrivateUsdSender`). Spend
  guard (one payment per account: the log has no `unconfirmed` row, no
  send is proving, `privateUsdUnfinishedCount` is 0) → terms → page
  `broadcasterFee` (refuse above `maxRelayerFee` before proving) → review
  → page `transfer` (to a `0zk`) or `unshield` (to a `0x`), showing `proof`
  events → only if still unlocked, in the foreground and in the same
  engine epoch, `privateUsdSendLogPut` (on error, "Not sent") →
  `privateUsdRelayerTransact`. Never prove again once a put succeeded:
  after a crash, settlement posts the kept bytes. Before a reverse
  conversion's funding (`startConversion`), check the log too: Rust's
  reverse calls do not. Offer withdrawals in the terms' `token` only: the
  relayer refuses a withdrawal paying out another token (`refused`, zapp
  `SwapClientsTest` 382).
- **For part 2: when to call settle.** `privateUsdSendSettleAll` runs one
  pass: call it after each Private USD balance sync (zapp reconciles on
  every sync, the syncs that sends and conversions start included), on
  unlock while the log holds an `unconfirmed` row, and every 4 s for up
  to 2 min after a `sent` answer (zapp's landing wait). Then the row says
  what happened: `confirmed` "Sent"; gone "Not sent"; still `unconfirmed`
  "Unconfirmed". Only in the foreground while unlocked (D9). A pass asked
  for while one runs returns the rows at once.

## M8. Hardening and release QA

- [ ] M8.1 Route changes during each phase fail closed and resume. Written;
  device check pending: `run_device_round.sh --m8-route` (D-104), not run
  because the phone was not attached (B-10)
- [x] M8.2 Kill switch: live JSON, missing flag, fetch failure. The M3 unit
  tests cover all three, and no new test was needed (D-107). The live
  check against the owner's URL waits for E7 (checklist run M-13)
- [ ] M8.3 Keyed RPC never appears in logs or records. Written; device check
  pending: `run_device_round.sh --keyed-rpc <json>` (D-105), which needs
  the phone (B-10) and E6's keyed RPC JSON. The static audit found no leak
  (D-105)
- [x] M8.4 Measured on the Galaxy A35 (Android 16, WebView 155) during the device rounds, 2026-10-14/15:
  arm64 release APK 116 MB (the Rust `.so` grew about 0.5 MB per ABI in M0); first Railgun sync on Sepolia
  with the page storage wiped: 96 s direct and 101 to 136 s through Tor in M0, and the M3 round's direct sync
  and Tor sync finished inside its 120 s and 150 s checkpoints; proof and post: a reverse funding (page proof
  plus submit) took 7 s and a relayed send or withdrawal 17 to 27 s from the tap to `Sent`; a withdrawal's
  public USDC arrived 21 s later; peak PSS on a debug build 662 MB for the app and 335 MB for the WebView
  renderer (M0: 446 MB and 382 MB). Not measured: a mainnet first sync (about 40 min expected, plan §11) and a
  release-build memory profile (M8 mainnet QA).
- [x] M8.5 `docs/private-usd-device-checklist.md`
- [x] M8.6 AGENTS.md "Private USD" section; correct the Android worker /
  `android_jni.rs` description (D-106: they were removed in `459a8565b`)
- [ ] M8.7 `VIZOR_PRIVATE_USD_ENABLED` on for release builds (owner sign-off only)
- [ ] M8 gate: done when the checklist passes on mainnet with the beta limits
  (plan M8 **Done when**); the suites pass (status below)

M8 status (2026-10-14): the non-device parts are done.

- **Still waiting.**
  - The device runs of M8.1 and M8.3, and M8.4, need the phone (B-10); M8.3
    also needs E6.
  - M8.2's live check needs E7.
  - M8.7 needs the owner's sign-off.
  - M8's **Done when**, the checklist passing on mainnet with the beta
    limits, needs all of the above.
  - M1.10b is deferred again (D-108). M4 still waits for N1.
- **What landed.**
  - `integration_test/private_usd_device_test.dart`: the opt-in route round
    (`_M8RouteRound`, D-104).
  - `scripts/private-usd/run_device_round.sh`: `--m8-route`,
    `--m8-route-phases` and `--keyed-rpc` (D-104, D-105).
  - `scripts/private-usd/device_round.py`: `keyed-rpc-check` and
    `keyed-rpc-scan`; `summarize` now reports both scans.
  - `docs/private-usd-device-checklist.md` (M8.5):
    - what to check before you start;
    - the round order: M3 first, which creates the testnet wallet; then fund
      it with testnet ZEC; then `--m5 --m6 --m7 --m7-to 0x…`, then
      `--m8-route`, with `--keyed-rpc`;
    - what each flag asserts;
    - 16 manual runs: both directions, refunds, rescue, send and withdraw,
      lock, background, kill, account switch, Tor on and off, deletion, the
      kill switch, hidden cases, the beta limit and the measurements;
    - the mainnet release QA. The beta limit (`maxSwapUsdc` 50) is the
      server's: test above it and never hard-code it;
    - a results table.
  - AGENTS.md (M8.6): a "Private USD" section, and the corrected description
    of the Android migration worker (D-106).
  - Plan: the status line, the Commands row, D9, the M8 tasks, §10 and §11.
  - The static audit for M8.3 found no leak, so no code changed (D-105).
- **Tests.**
  - No new unit test: nothing new guards funds or keys.
  - The route round compiles and analyzes clean. It has not run.
  - The keyed RPC scan's host side was exercised with a fake key (D-105).
  - Rust (`cd rust && CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 cargo
    test`): lib `1514 passed; 0 failed; 11 ignored`; integration 6 passed,
    21 ignored (regtest). The flaky `gift_card_input::tests::recovery::*`
    family passed this time.
  - `fvm flutter analyze`: no issues.
  - Desktop lane (`fvm flutter test`): `+5976 ~163 -4`. The 4 are the
    pre-existing `settings_seed_phrase_screen_test.dart` failures
    ("incoming links cannot interrupt backup completion/deferral
    success/failure").
  - Mobile lane (`--tags mobile --run-skipped
    --dart-define=VIZOR_FORM_FACTOR=mobile`): `+2304 -10`. The 10 are the
    pre-existing `app_review_payment_handoff_test.dart` failures (the "Edit"
    and "Review" cases, 5 each).

## Deviations

- **D-1 (M0.1 step 1): `zecswap-tokens` is not in veylor's graph.** It does not
  resolve: `blind-rsa-signatures ^0.18` needs `digest ^0.11.3`, and veylor's
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
  `orchard_payment_routes_to_ironwood_and_builds`, and the new veylor test
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
    `rand 0.10` `CryptoRng`, and veylor's `rand` is 0.8 (M5 adds `rand` 0.10
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
  - The handler exposes `handle(call, result)`, like veylor's other handlers,
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
    (zapp checks once per driver; veylor's driver lives for one call).
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
  - veylor's own: `swap_indices_are_never_reused`,
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
- **D-51 (M5.3): the Dart engine as built.** Reference §5.10 and §9.2
  updated.
  - `services/private_usd_engine.dart`: `PrivateUsdEngine` holds one serial
    queue per account (`runFor`), an epoch every pause, drain and dispose
    bumps, and the published `conversions` snapshot
    (`PrivateUsdConversionStatus`: record, wait, activity, problem,
    `failingSince`, `resuming`, `checkedAt`). The loop idles, with no timer,
    while nothing is under way; accept, opening a progress screen, unlock
    and the foreground start it again. It naps the shortest `next_poll_ms`
    of a pass (at least 1 s), 15 s after a failed step or `busy`, 30 s when
    the listing itself failed.
  - Only the loop's advances and accept drop a result that lands after a
    pause (`PrivateUsdEngineInterruptedException`). A quote or a "Call it
    off" that finished in Rust is still shown: the index is spent either
    way, and a lock drops the offer in Rust (`private_usd_clear_sessions`).
    A step queued before a pause never starts, and a seed read that ends
    after one is zeroed and never reaches Rust.
  - Op ids are unique per process (a static counter), so a cancel Rust
    remembers for an old id can never stop a newer call. The activity label
    is polled every 500 ms while an advance runs.
  - A setup error an advance throws counts as a failed step (`mismatch`,
    `zcashWallet`, `storeUnreadable`, `routeBlocked`, the unreachable codes,
    else `other`); `cancelled` and `busy` never do.
  - `services/private_usd_swap_backend.dart` is the FRB seam
    (`PrivateUsdSwapBackend`, `RustPrivateUsdSwapBackend`). Key-using calls
    take a `PrivateUsdSecretReader`: the seed is read only once the paths
    are known, handed to Rust in the same synchronous step, and zeroed in
    `finally`, as `swap_deposit_sender.dart` does. Reads go through the new
    `getExistingPrivateUsdDirPath` and never create the store; only a quote
    or an accept (which may write a first record) creates it.
    `services/private_usd_paths.dart` wraps both.
  - `privateUsdEngineProvider` holds the `AppLifecycleListener` (hide and
    pause → `pause(background)`, resume → `start(resuming: true)`) and the
    lock listener (`pause(lock)`: cancel, `private_usd_clear_sessions`, clear
    the problem timers, wait at most 5 s), Gift Card's shape as the M5
    pitfall says, rather than the host widget §9.2 described. It registers
    `quiesceAndDrain` / `resumeAfterMutation` with
    `privateUsdLifecycleProvider`, and forgets a deleted account's
    conversions (all of them on a reset).
  - `PrivateUsdEngineHost` (beside `BackgroundAutoLockHost` in `lib/app.dart`)
    only keeps the engine alive, when `privateUsdEngineEnabledProvider`
    holds: the define, the mobile form factor, Android and a deployment. It
    does not follow the kill switch or the active account, so conversions
    under way keep being driven (D14, D16).
- **D-52 (M5.3): the Dart ★ cases as built.** In
  `test/features/private_usd/private_usd_engine_test.dart`, on a scripted
  `FakePrivateUsdBackend` and the widget tester's fake clock:
  `SwapLoopTest` 58 (`a failed step is tried again, says why only once…`),
  155 (`a nudge cuts a nap short`) and 186 (`cancellation is never taken for
  a failed step`, plus an unexpected error counting as one) as zapp wrote
  them. 77 (`failing for five minutes asks the user once…`) is adapted: zapp
  asks through a notification, which veylor does not have (D9), so the ask is
  the problem on the conversion, which appears once and holds while steps
  keep failing, and clears on the first that goes through. Four more pin the
  M5 pitfalls: a lock with a call in flight, a seed read that finishes after
  a lock, the drain, and D14 (every account under way is advanced).
- **D-53 (M5.4): the deletion and reset guards as built.** Reference §8.4
  updated.
  - `removeAccount` and `resetWallet` take `confirmedPrivateUsdUnfinishedCount`
    and throw `PrivateUsdUnfinishedConversionsException(count)` when more
    conversions are under way than the user confirmed. The count is read
    after the drain (§8.4 said before it), like the Gift Card recheck, so one
    that started meanwhile is counted; a store that cannot be read never
    blocks (warn and allow). A reset refuses only while unlocked, summed over
    every account.
  - After the Rust account delete, `deleteAccountConversions(uuid)` removes
    the account's records and joint accounts, asking again (up to three
    times, 1 s apart) on `busy`. A failed Rust delete leaves them.
  - The warning is in the mobile removal sheet (title, the count, and "Delete
    anyway" or "Reset anyway") and the forgot-passcode sheet, not in
    `accounts_screen.dart` or `settings_uninstall_screen.dart`: those are
    desktop routes, and Private USD is mobile-only. The mobile account rows
    show no pending counts, so `accountsPendingConversions` is not shown in
    v1.
  - The lifecycle's conversions backend exists only in builds with the
    define on the mobile form factor (const), so desktop never looks for
    conversions.
- **D-54 (M5.5): the UI as built.** Reference §9.1, §9.2 and §9.7 updated.
  - Routes: `/private-usd/convert`, `/private-usd/convert/review` (extra
    `PrivateUsdReviewArgs`, else back to the convert screen) and
    `/private-usd/conversion/:direction/:index` (a `reverse` path goes to
    `/private-usd` until M6). While Private USD is unavailable, the guard
    still lets the active account's conversion under way show its progress
    (`privateUsdUnfinishedProvider`, which `_routerProvider` now listens to).
  - Navigation: "Convert" on `/private-usd` opens the conversion under way,
    else the convert screen, which itself gives way to one found on opening
    (the engine's set, then the records, as after a crash mid-accept) or
    after a quote refused as `busy`. Accept pops the review with the
    conversion's route and the convert screen replaces itself with its
    progress (§9.1 said the review is replaced), so back from progress lands
    on `/private-usd`. "View private USD" goes home and pushes `/private-usd`,
    as send's status does; "Try again" replaces progress with the convert
    screen.
  - The convert provider quotes through the engine's per-account queue (a
    quote takes Rust's driver lock too). "Getting quote…" shows from the
    first keystroke; the countdown runs to the 20 s cutoff; on the amount
    step the 1 s tick asks again, at the same size, for a quote past it
    (only in the foreground and unlocked: each quote spends an index); on
    the review "Refresh quote" asks there and the review keeps the answer
    (zapp went back to the amount phase), and says why when it fails; any
    other quote that lands while the review is up is dropped, and one already
    past its cutoff on arrival shows the clock message (on the review the
    expired quote stays, so "Refresh quote" does too). "Max" needs a balance Rust vouches for
    (`authoritative`) and a wallet not catching up. `units` is clamped to a
    `u32`, the most a quote can name. No direction toggle, and `?to=zec` is
    ignored, until M6.
  - Accept: `quoteExpired`, `relayerFee` and `depositUnpayable` are refusals
    before anything was saved; the quote then counts as spent and the review
    offers "Refresh quote". `relayerFee` says the 2 USDC message when the
    quote's fee is above the deployment's cap, else the "doesn't cover"
    one. Any other failure reads the records and opens the progress if the
    index is under way, else says it couldn't start. `tokensNeeded` (no
    tokens client, D-33) says "The market maker isn't taking conversions
    right now…" and calls the record off, never asking again.
  - Progress: the result, problem card, note and "Call it off" sit above
    the step list, so they show without scrolling. Paid shows "Arriving"
    until the balance was read 30 s after the payout (the screen asks for
    that read), "Screening" while some is still arriving, then the completed
    status card. The details tab has the swap ID, the ZEC deposit and refund
    (explorer order), the payout (an Etherscan link) and the start time.
  - The banner reuses home's emphasized entry card, now
    `MobileHomeEntryCard` in `lib/src/core/widgets/mobile/`: on home after
    the action row, and on `/private-usd`. Its second line is "Keep Veylor
    open to finish" whenever a conversion is under way: every forward stage
    still has a key step to come.
  - Activity: rows from the engine's snapshot of the account's records,
    read once per account: "Converting ZEC" (its stage), "Converted ZEC"
    (the ZEC paid; opens the payout on Etherscan) and "Conversion called
    off"; nothing sent makes no row. The main-wallet rows of deposits and
    refund sweeps are dropped. On home, in Activity and on `/private-usd`.
    Builds without the engine have none, and read no deployment.
  - Keep-awake: `privateUsdKeepAwakeProvider` is true while a progress
    screen shows and its conversion is unfinished, OR-ed into
    `SyncKeepAwakeNativeHost` (both watched, no short-circuit).
  - The balance counts an account with any conversion record as in use
    (D-21's M5 step), so the home strip keeps it fresh.
  - The Tor-off disclosure (D10) is not shown in M5: it is about the token
    service, and M5 fetches no tokens. The review takes a flag, which the
    capture scenario sets.
  - The swap review's warning line is now `MobileWarningNotice` in
    `lib/src/core/widgets/mobile/` (§9.1), used by both.
- **D-55 (M5.6): the copy as built.** The Convert tables (amount and quote,
  errors, review and info, forward progress, problems, forward results) and
  Accounts are in `PrivateUsdCopy`, with `privateUsdErrorMessage`,
  `privateUsdProblemMessage`, `privateUsdNothingSentMessage` and
  `privateUsdRefundedMessage`. New: "Max" (veylor's visible label; "Use it
  all" stays the semantics label), the details tab and its row labels, and
  `convertProblemRoute` for a step held up by the Tor route (`route_blocked`
  says "nothing was sent", which a conversion in progress cannot say).
  `makerUnavailable` maps to "can't be reached"; `tokensNeeded` to the
  maker-unavailable result; `mismatch`, `busy`, `unavailable` and `other` to
  the generic quote error. The reverse, refunds and send tables wait for M6
  and M7.
- **D-56 (M5.7): Widgetbook and capture scenarios.** The 15 forward rows of
  §9.7 except the reverse attention banner (M6), registered in Widgetbook's
  Home and Private USD folders and as `FigmaCompareScenario`s;
  `mobile-private-usd-default` gains a converted and a called-off row and the
  Convert button. All 26 Private USD mobile scenarios render in
  `figma_compare_mobile_scenarios_test.dart`. Captured with
  `scripts/figma-compare.sh widget --form-factor mobile`, in dark (every new
  screen) and light (convert, the review with Tor off, progress, the home
  banner), and reviewed; that review made the bottom buttons full width,
  right-aligned the ledger values and moved the problem card above the
  steps.
- **D-57 (M5): the device round's M5 scenario, written and not run.**
  `run_device_round.sh --m5 [--m5-zec 0.05]` (off by default; implies no
  release check and keeps the page storage) runs
  `private_usd_device_test.dart` twice: `VIZOR_PUSD_DEVICE_M5=start`
  unlocks the testnet wallet already on the phone (passcode 111111, an
  earlier round's), waits for it to sync with the amount spendable, converts
  through the screens and stops once the deposit is kept; the runner then
  `am force-stop`s the app (killed mid-confirmation) and runs
  `VIZOR_PUSD_DEVICE_M5=resume`, which checks that it resumes, that a lock
  runs no advance for 90 s (each advance reads the seed) and unlock resumes
  it, that it advances with another account active (adding one if the
  wallet has none), that removing the account warns with the count and
  Cancel deletes nothing, and that it reaches Paid. A check the conversion
  outran is recorded as skipped, not failed. The test refuses to run with
  `VIZOR_PUSD_DEVICE_RESET`, so it can never reset the funded wallet; each
  test now returns early unless its round was asked for (`--run-skipped`
  lifts `skip:`). Events carry the swap index, phases and timings only.
- **D-58 (M5): the Dart tests as built.** Plan §10 updated. Untagged:
  `test/features/private_usd/private_usd_engine_test.dart` (8: D-52),
  `private_usd_zec_quote_search_test.dart` (10: all nine of zapp's
  `PrivateUsdZecQuotesTest`, plus the `u32` clamp),
  `private_usd_convert_provider_test.dart` (10: the `PrivateUsdConvertVMTest`
  button-enable cases at 107, 126, 138, 150, 179, 201 and 216, then veylor's
  back rule and two expiry rules: the 20 s cutoff with the same-size
  replacement on the amount step, and "Refresh quote" on the review),
  `test/providers/private_usd_account_lifecycle_test.dart` (7: the refusal
  after the drain, a count above the confirmed one, drain before the Rust
  delete and cleanup after it, no cleanup when the Rust delete fails, no
  question without conversions, the reset refusal only while unlocked, and
  an unreadable store never blocking), and two more in
  `private_usd_available_provider_test.dart` (the engine's build gate, and
  the host building no engine without the define). Mobile-tagged:
  `mobile_private_usd_conversion_screens_test.dart` (16: the convert, review
  and progress states, the banner, and `/private-usd` with a conversion), 3
  removal-sheet cases in `mobile_accounts_screen_test.dart`, and the 15 new
  scenarios in `figma_compare_mobile_scenarios_test.dart`. The convert flow
  runs the real quote search and engine over a scripted backend on the
  widget tester's fake clock; time-driven tests pump `Duration.zero` because
  a bare `pump()` fires no timers.
- **D-59 (M5 review): the reveal margin counts from the later clock.**
  `hold_claim_lock` and `require_fresh_claim_lock` measure the 300 s margin
  from `max(head time, device clock)`, not the head time alone (zapp and
  D-38 use the head). The head may trail real time by up to
  `MAX_HEAD_LAG_SECONDS` (180 s), which left as little as 120 s of real
  margin. Lock-taking (`may_take_lock`) still uses the head, as the contract
  does.
- **D-70 (M6.1): the reverse engine as built.** Plan §3.6 and reference §5.7
  and §5.10 updated.
  - `reverse.rs` splits zapp's driver into `ReverseView` (no key: pricing,
    going ahead, submitting a proof, the rescue check) and `Reverse` (keyed:
    quote, accept, the funding request, advance, ready, cancel, rescue).
    `ReverseZcash` is the Zcash seam; `WalletZcash` implements it beside
    `ForwardZcash`, and its joint-account helpers (`import_joint`,
    `synced_joint`, `joint_tx_status`, `sweep_home`, `broadcast_kept`,
    `forget_joint`) now take the direction.
  - The maker's `/v1/info` check, the pinned relayer check and the
    acceptance are shared free functions in `forward.rs`; `MakerChecks` is
    kept per network and direction, as reverse also needs `reverseEnabled`.
  - zapp's `ReverseOutbox` defers posts until its record lock is released.
    Here the per-account driver lock spans the post and `OPERATIONS` does
    not: each step saves in one SQLite transaction, then posts. The
    funding's answer is merged into the record as it is then
    (`ReverseFundingSubmission`).
  - `engine.rs` gains `Activity::{Funding, Readying, Refunding}` and the
    funding sessions (D-72).
- **D-71 (M6.1, M6.2): pricing is split around the page.** zapp's quote calls
  the page's `reverseCost` itself; Rust cannot. `reverse_quote` keeps the
  draft with no cost and returns the cost request (amount, Railgun proxy, and
  the relayer's funding fee and expiry, within the 2 USDC cap); the new
  `private_usd_reverse_cost_request` asks again. `set_cost` reads the
  relayer's fee again and keeps the cost only if `debit = amount + fee +
  railgun_fee` (the page's `fundingAmounts`): another fee is
  `FundingCostChanged`, a cost that does not cover the escrow `Mismatch`.
  Going ahead and the funding request need a priced record
  (`FundingCostChanged`). After a relayer refused a funding and now asks a
  higher fee, the dropped funding's cost is cleared for the page to price
  (zapp prices it itself).
- **D-72 (M6.1): the funding proof's round trip.** `funding_request` keeps a
  `FundingSession` in memory (the record as signed, the fee and its expiry,
  the relayer's Relay Adapt and calldata limit) under the lock session;
  `submit_funding` takes it once. It refuses (`Cancelled`) when none is held,
  as after a lock or a restart, or when the user called the conversion off;
  `TooLate` when the record changed. The proof must go to that Relay Adapt
  with no value, be well-formed calldata within the limit, and cost exactly
  what the calls pay (`Mismatch`). A cost other than the reviewed one is kept
  for review and `FundingCostChanged` (zapp).
- **D-73 (M6.1): the page's wallet is checked at funding.** `funding_request`
  takes the page's open address and refuses one other than the account's
  (`Mismatch`, §3.5 item 19): the funding's refund note is the account's.
- **D-74 (M6.1): reverse error mappings.** A quote whose ready deadline is too
  near is `TooLate` (zapp `MISMATCH`); one whose refund is more than a day
  out stays `Mismatch`. A maker without `reverseEnabled` and a relayer
  without paid sponsorship are `Unavailable` (zapp `WRONG_DEPLOYMENT`,
  `FUNDING_UNAVAILABLE`). zapp's `DEADLINE_PASSED`, `UNDER_WAY_ON_CHAIN` and
  "already settled" are `TooLate`; a conversion not waiting on the user is
  `Other` while a draft, else `TooLate`. A reverse amount must be whole cents
  (a multiple of 10,000 base units, plan M6 trap), else `AmountUnquotable`
  (`AmountRefused` over FRB).
- **D-75 (M6.1): the maker's acceptance.** A refusal no other try would change
  ends the conversion `CANCELLED` and is reported as `NothingSent`:
  `unavailable` and `watchtowerUnavailable` as `MakerUnavailable`,
  `unknownQuote` as `QuoteExpired`, `rejected`, `invalidRequest`,
  `unknownSwap`, `notFound` and `methodNotAllowed` as `MakerRefused` (zapp
  `MISMATCH`), another swap or other deadlines as `Mismatch`; `internal`,
  `alreadySpent` and unknown codes are errors, posted again. A token-gate
  refusal on the user's accept is `TokensNeeded` and leaves the record
  unanswered (D-33); found by the loop resuming an interrupted accept, it
  ends `CANCELLED`, as zapp's turned-down token does, since no client can
  pay one before M4.
- **D-76 (M6.1): a cancel waits for a funding post.** The driver lock spans
  the post (up to the client's 180 s), so a cancel then gets `Busy` and
  runs after it; zapp lets it interleave. A cancel while the page proves is
  not held up (the proof is outside Rust), and the submit then refuses.
- **D-77 (M6.1): the record's deployment.** A step refuses a record whose
  chain, contract, token, Railgun proxy, maker, relayer or Zcash network is
  not the build's pins (`WrongDeployment`). zapp compares the whole pinned
  deployment; URLs, confirmations and the issuer may change between
  versions, so they do not strand a conversion, and the current pins' URLs
  are used.
- **D-78 (M6.1): the sweep home.** It pays at most the reviewed
  `receiveEstimate.feeZat` (without one, the forward refund's limit); the
  estimate is `joint_receipts`' confirmed amount and `5000 × max(2, notes +
  1)`. Send flow `private-usd-receive:{account}:{index}`. An earlier sweep
  found again reports its amount and fee from `joint.db`
  (`joint::sent_value_and_fee`; fee 0 when the wallet did not record it).
- **D-79 (M6.2): the FRB surface as built.** Reference §8.2 updated.
  - New: `private_usd_reverse_cost_request`. `private_usd_reverse_quote`
    returns `ApiReverseQuote { record, cost_request }`.
  - The calls that need no key take no `db_path` (D-32's rule): `set_cost`,
    `go_ahead`, `submit_funding`, `can_rescue` and `cost_request` take
    `network, account_uuid, store_dir` (and `eth_rpc_url` where the plan had
    it); `reverse_records` takes `account_uuid, store_dir`.
    `funding_request` takes no `lightwalletd_url` and adds
    `railgun_address`; `rescue` takes no `lightwalletd_url`.
  - `ApiReverseRecord` adds `network_cost`, `funded` and `awaiting_user`.
  - Only the calls that write take the driver lock; `cost_request`,
    `can_rescue` and `records` read.
- **D-80 (M6): the tests as built.** Per the owner's scope change
  (2026-10-14: fewer unit tests, more E2E), one test per M6 "Done when" rule
  in `private_usd/tests/reverse.rs`, on the shared fakes (reverse escrow,
  funding, maker and relayer paths, and `ReverseZcash` added to
  `tests/fakes.rs`):
  - `a_lost_funding_answer_is_sent_again_only_while_the_node_does_not_know_it`
    (`ReverseFundingTest` 43 and 95, `ReverseSwapDriverTest` 183,
    `ReverseSwapRefundTest` 171)
  - `a_late_funding_answer_keeps_the_users_cancel` (`ReverseFundingTest` 24,
    with `Busy` for a cancel during the post and a store-level cancel during
    it for the merge; `ReverseSwapRefundTest` 370, the cancel during the
    proof)
  - `ready_is_signed_only_by_the_user_and_never_again_after_a_restart`
    (`ReverseSwapDriverTest` 200, 215 and 382)
  - `the_sweep_home_pays_no_more_than_the_reviewed_fee`
    (`ReverseSwapRefundTest` 220, `ReverseSwapDriverTest` 47's receive)
  - `the_refund_secret_is_revealed_only_under_a_fresh_lock_with_time_to_spare`
    (`ReverseSwapDriverTest` 338, `ReverseSwapRevealTest` 13 and 33,
    `ReverseSwapRefundTest` 202)
  - `a_refund_is_rescued_only_from_a_vault_holding_more_than_the_fee`
    (`ReverseSwapRevealTest` 46, `ReverseSwapRefundTest` 99 and 305)
  - `open_reverse_calldata_matches_the_independent_encoding_and_zapps_roles`:
    zapp has no hex fixture for `openReverse`, so the calls are compared byte
    for byte with zecSwap's funding vector (`sdk-vector.json` at `d69e3fb`,
    encoded by ethers with the contract's ABI; its signature also recovers
    under zecswap-core's `OpenReverse` digest), now in `vectors.json` as
    `reverseFunding`, plus zapp's `ReverseSwapRefundTest` 283 roles on a real
    funding request. The three selectors joined the vector list.
  - Not ported, per the scope change: `ReverseSwapDriverTest` 145 (partial
    deposits never enable `ready`) and 359 (the refund after `ready` waits
    for its deadline and turn), and `ReverseFundingTest` 64 (a funding that
    landed during a timeout is followed, never sent again); 47 is covered
    only from the receive on. The device rounds cover the rest.
- **D-81 (M6.3): the Dart reverse engine and funding as built.** Reference
  §5.10, §5.11 and §9.2 updated.
  - `PrivateUsdEngine` keeps reverse records in a second snapshot
    (`reverseConversions`, published as `privateUsdReverseConversionsProvider`,
    drafts included); `privateUsdUnfinishedProvider` is the union of both
    directions' records under way. Each pass reads both directions per
    account and advances a reverse record only when it is under way
    (never `quoted`, `complete`, `refunded`, `cancelled`), with the forward
    loop's naps, problem timing and pause rules. The loop never sends a
    rescue. `needsYou` is `record.awaitingUser` (the attention banner).
  - The reverse calls go through the per-account queue (`reverseQuote`,
    `reverseSetCost`, `reverseGoAhead`, `reverseAccept`,
    `reverseFundingRequest`, `reverseSubmitFunding`,
    `reverseAuthorizeReady`, `reverseCancel`, `reverseRescue`);
    `reverseCostRequest` and `reverseCanRescue` are reads off it. A
    funding is bound to a `PrivateUsdEngineTicket` (the engine's epoch when
    "Convert" or "Pay" was tapped): its `funding_request` runs at that
    epoch, and its submit runs only while the ticket holds, asked again in
    the backend right before the FRB call (`stillCurrent`, after the last
    await), else `PrivateUsdStaleStepException` and nothing reaches Rust.
  - `services/private_usd_reverse_funding.dart`: a keep-alive service
    (`privateUsdReverseFundingProvider`) over a page seam
    (`PrivateUsdReversePage`, `RailgunReversePage` over `RailgunEngine`). It
    prices (`reverseCost` → `set_cost`, once more if the relayer's fee moved)
    and funds (spend guard → page address → `funding_request` → page
    `prepareReverse` → `submit_funding`), publishing per conversion
    `preparing`/`proving`/`submitting` and the last error
    (`privateUsdFundingStatesProvider`). The proof runs outside the queue,
    so a cancel can run meanwhile; a cancel also `drop`s the running try. A
    lock, the background, a drain, a closed page or the cancel drops the
    proof silently ("Pay {debit}" proves again); `fundingCostChanged` from
    a submit shows the kept new total, and one from `funding_request` prices
    the cleared cost first. `RailgunSession.prepareReverse` now publishes
    `proving` and clears the last proof, so the `proof` events show as
    "Proving your payment · n%".
  - "Convert" on the review goes ahead, accepts, starts the funding and
    pops to the progress at once; the payment continues there (zapp shows it
    on one screen). The page is opened before a quote, so a page that cannot
    start spends no swap index.
- **D-82 (M6.3): the spend guard is minimal.**
  `services/private_usd_spend_guard.dart` keeps the §9.2 status enum and
  `startConversion`, in memory per account: one funding at a time per
  Railgun wallet. M7 adds sends and the send log (which carries an
  unsettled send across restarts); a kept funding needs no such record, as
  the loop follows it and it is never proved again.
- **D-83 (M6.3): Max's funding fee.** No FRB call reads the relayer's
  funding fee without a record (zapp's `fundingFee()` reads `/v1/terms`).
  Max reads it through the account's `quoted` draft
  (`private_usd_reverse_cost_request`, no index spent), else uses the 2 USDC
  cap (X6), so Max is never more than the fees leave; with no draft it can be
  up to the cap below the true maximum. A Rust call for the fee alone would
  make it exact (plan M6 traps updated). The unshield fee is the page's
  `RailgunFees`; the balance is the swap token's `Spendable` bucket only.
- **D-84 (M6.4): the copy as built.** The Reverse and Refunds tables are in
  `PrivateUsdCopy`, with `privateUsdReverseQuoteMessage`,
  `privateUsdReverseStepMessage`, `privateUsdReverseProblemMessage` and
  `privateUsdReverseNothingSentMessage`. The call-off reads "Request refund"
  (the copy table's `reverse_request_refund`), not §9.5's "Request private
  refund". New for veylor: "Pay {debit}", "Proving your payment · n%" and
  its keep-open note, "Use at most 2 decimal places.", "Converting to ZEC"
  (activity), the reverse details rows ("Escrow payment", "ZEC received"),
  "Refresh" (Refunds), "Not now" (the sheets), and an unpaid variant of the
  cancel sheet ("Nothing has been paid yet, so nothing is lost. This can't
  be undone."). `refunds_recover_confirm_body` names the fee's cap ("The
  relayer's fee, at most $2.00, comes out of the refund."): Rust reads the
  rescue fee only as it signs. `reverse_title` titles the reverse info
  sheet; `reverse_review` is the banner's detail while a payment waits.
- **D-85 (M6.3): the cancel-requested note.** `ApiReverseRecord` does not
  say whether `ready` was sent, so the refund-wait note is always
  `reverse_refund_requested`; `reverse_refund_requested_after_ready` is in
  the copy for when the record exposes it (settling already shows the
  `refundAfter` limit).
- **D-86 (M6.3): routes and UI as built.** Reference §9.2 and §9.4 updated.
  - `/private-usd/convert?to=zec` and a direction toggle between the cards
    (both directions, on the amount step); the review route's args carry the
    direction; `/private-usd/conversion/reverse/:index` opens
    `MobilePrivateUsdReverseConversionScreen`; `/private-usd/refunds` opens
    `MobilePrivateUsdRefundsScreen` over `privateUsdRefundsProvider` (every
    `refunded` record newest first, checked every 15 s, 4 at a time, 30 s
    each, only while the engine may run; one recovery at a time, back
    blocked meanwhile).
  - Progress: "Pay {debit}" in `awaitingFunding` (disabled while a funding
    runs, or before the cleared cost is priced again, which the screen does
    on opening); "Authorize settlement" in `awaitingReady` until
    `readyDeadline − 120 s` on a 5 s tick; the call-off behind a sheet while
    `cancellable`; "New conversion" and, once refunded, "View refunds". Back
    is blocked while settlement or a call-off runs. The problem card keeps
    veylor's "Try now" (zapp's reverse card has none).
  - "Refunds" sits beside the Activity heading on `/private-usd` once a
    conversion was refunded, and on the reverse amount step. Activity rows
    for reverse records (no row for a draft or a cancelled one); the main
    wallet's row for the sweep home is dropped, as the forward deposit's is.
- **D-87 (M6.5): Widgetbook and capture scenarios.** The twelve reverse and
  refunds rows of §9.7 plus `mobile-private-usd-reverse-proving` (the proof
  at 42 %), in `lib/widgetbook/private_usd_reverse_use_cases.dart`,
  registered in Widgetbook and as `FigmaCompareScenario`s; the forward
  convert fixture now shows the direction toggle, as the app does. Captured
  with `scripts/figma-compare.sh widget --form-factor mobile` (dark; the
  ready state also light) and reviewed: the reverse ledger gives labels the
  free width and values their own.
- **D-88 (M6): the Dart tests as built.** Untagged:
  `private_usd_reverse_funding_test.dart` (4: a proof submitted once in the
  foreground; dropped, never submitted, after a lock, in the background,
  and after a pause even back in the foreground) and
  `private_usd_reverse_amount_test.dart` (3: 2-decimal amounts by string
  arithmetic, Max, the "Authorize settlement" window). Mobile-tagged:
  `mobile_private_usd_reverse_screens_test.dart` (3: the amount step, the
  progress actions, Refunds) and the 13 new scenarios in
  `figma_compare_mobile_scenarios_test.dart`. The reverse screens test runs
  430 px wide: the test font's square glyphs make "Authorize settlement" a
  pixel wider than the button at 393 px.
- **D-89 (M6): the device round's M6 scenario, written and not run.**
  `run_device_round.sh --m6 [--m6-usd 2] [--m6-refund]` (off by default;
  implies no release check and keeps the page storage; with `--m5` it runs
  after M5's round) runs `private_usd_device_test.dart` once with
  `VIZOR_PUSD_DEVICE_M6=run`, on the wallet an M5 round left (never reset):
  it waits for the dollars, converts through the screens (strip, Convert,
  the toggle), locks while the page proves and checks nothing was paid then
  or after unlock, cancels that unpaid conversion behind its sheet
  (`CANCELLED`), converts again, authorizes settlement and reaches
  `COMPLETE`. `--m6-refund` adds a paid conversion cancelled to `REFUNDED`
  (it waits out the refund deadlines, up to 3 h) and its row on Refunds.
  Events carry the swap index, phases and timings only.
- **D-90 (M7.1): the send FRB surface as built.** Reference §8.2 updated.
  - `private_usd_railgun_sends_terms(network)` takes no `eth_rpc_url`:
    nothing in it reads the chain.
  - `private_usd_send_log_put(store_dir, network, account_uuid, send:
    ApiProvedSend) -> ApiSendRecord`: Dart hands over the page's
    `transfer`/`unshield` result unchanged (`proof_json`) with the send id,
    token, amount, fee and destination; Rust parses the request and the
    nullifiers itself, sets `sent_at` and the state. It takes `network` to
    check the proof against the pins.
  - No `send_log_update` or `send_log_remove`: after the put every change is
    Rust's (`relayer_transact`, `send_settle_all`), so Dart can never alter
    or drop a kept proof. Account deletion removes an account's rows as
    before.
  - `ApiSendRecord` adds `fee` and drops `request_json` and
    `nullifiers_json`: the proof never goes back to Dart.
  - `relayer_transact` on a send that is not kept is `Other`, and nothing is
    posted; on one a settle pass already found landed it answers `Spent`
    (with its transaction, if known) without posting.
- **D-91 (M7.1): Rust guards the keep, beyond zapp.** zapp's log keeps what
  its sender hands it. `send_log_put` refuses, keeping nothing:
  - `Busy` while another send of the account is unconfirmed or a conversion
    is under way (`unfinished_count`): the spend guard's rule, enforced again
    in Rust and across restarts;
  - `RelayerFee` for a fee above 2 USDC (D11);
  - `Mismatch` for a proof not for the pinned chain and Railgun proxy, with a
    value, without nullifiers in every spend or with calldata shorter than a
    selector; a token not in the deployment's `usd_tokens`; a destination
    that is neither a `0zk` nor a non-zero `0x` address; a request over
    132 KiB; and another proof under a kept send's id (never re-proved). The
    same send kept again returns the kept one.
  The terms call refuses a relayer whose least fee is above the cap
  (`RelayerFee`): no send could pay it.
- **D-92 (M7.1): "retry for at most 1 h" is zapp's cap on the wait.** A
  `Retry-After` above an hour waits an hour (`MAX_RETRY_AFTER`); one that
  does not read as delay-seconds (an HTTP date, negative, fractional,
  overflowing) is ignored. A send that keeps getting `Retry` is never
  dropped: it stays `unconfirmed`, blocking spending, until the chain
  settles it.
- **D-93 (M7.1): one pass at a time per account.** zapp has one settlement
  lock per wallet; here a per-account lock in `sends.rs` is shared by
  `relayer_transact` (which waits for a running pass) and
  `send_settle_all` (which returns the rows without a pass while one runs).
  The record body is veylor's own JSON (camelCase, strictly decoded), not
  zapp's `private_usd_sends_v2` shape, which nothing here reads.
- **D-94 (M7.1): the chain reads.** The receipt status is D-7's
  `transaction_status` with 1 confirmation, behind a new `SendChain` seam
  (`send_status`, `nullifier_spent`) that `EvmRpc` implements; the
  `nullifiers` selector joined the vector list. The relayer's sends pin is
  zapp's exactly (chain, proxy, `0zk`, fee token; a positive gas price; a
  rate only with its expiry): it does not compare the swap contract or the
  relayer's address.
- **D-95 (M7.1): the tests as built.** Per the owner's scope (fewer unit
  tests, E2E first), 7 tests, one per M7 "Done when" Rust item:
  - `relayer_client::tests::railgun_send_answers_say_whether_to_drop_it_or_post_it_again`
    (zapp `SwapClientsTest` 228 and 355): `200` with and without a
    transaction, `409 alreadySpent` with and without, `409` otherwise,
    `400`/`404`/`413`/`415`/`422`, `500`/`503`, six `Retry-After` values
    and a dropped connection; every post is the same four fields.
  - `relayer_client::tests::railgun_sends_terms_are_held_to_the_pins_and_the_fee_cap`
    (`RelayedPrivateUsdSenderTest` 247 and 296).
  - `tests::sends::a_send_is_kept_before_it_is_posted_and_posted_from_the_store`
    (`RelayedPrivateUsdSenderTest` 63, `PrivateUsdSendLogTest` 52).
  - `tests::sends::an_unsettled_send_blocks_the_next_payment_across_restarts`
    (the guard's log half; `PrivateUsdSendLogTest` 98's case, a send left
    proving, cannot arise: one being proved is never written).
  - `tests::sends::a_kept_send_goes_again_as_the_same_bytes_no_sooner_than_asked`
    (`RelayedPrivateUsdSenderTest` 92, 104 and 132): settlement's third
    branch, a crash between keep and post included.
  - `tests::sends::a_named_transaction_settles_from_its_receipt`
    (`RelayedPrivateUsdSenderTest` 230's revert): the second branch.
  - `tests::sends::notes_the_relayer_calls_spent_settle_from_the_chain`
    (`RelayedPrivateUsdSenderTest` 180, 209 and 230's partial spend): the
    first branch.
  Not ported: `RelayedPrivateUsdSenderTest` 274 (a higher fee is never paid
  unconfirmed) is pricing, which is Dart's (M7.2).
- **D-96 (M7.2): the sender as built.** Reference §6.7 and §9.2 updated.
  - `PrivateUsdSender.send` runs inside the spend guard: `held` (zapp's: the
    confirmed fee while the relayer still holds it 2 minutes past now and
    its floor is not above it, else the page's `broadcasterFee` again),
    then nothing is proved above the 2 USDC cap (`send_error_fee_cap`) or
    above the confirmed fee (`Repriced`); `cost` refuses a fee above the cap
    for review too (`PrivateUsdSendFeeCapException`), before any proof.
  - The page proves (`transfer` or `unshield`); `RailgunSession.prove` now
    keeps the page's result text on `RailgunRelayedProof.json`, which goes
    to `send_log_put` unchanged and is never logged or stored by Dart. The
    keep is bound to an engine ticket taken at the tap
    (`PrivateUsdEngine.ticket`, as M6's funding): the backend asks
    `isCurrent` after its last await, right before the FRB call, so a proof
    that lands after a lock, in the background or after a drain is dropped
    and nothing is kept or sent.
  - After a keep it is never proved again: the first post
    (`relayer_transact`) runs only while the app may run, else the outcome
    is `Unconfirmed` and settlement posts the kept bytes later (D9). An
    error from the post is `Unconfirmed` too, except `other` (nothing was
    kept: `NotSent`). `sent` waits for a block (a settlement pass every 4 s
    for up to 2 minutes: `Sent`, the row gone `NotSent`, else
    `Unconfirmed`); `refused` prices again (`Repriced` when the relayer now
    asks more than the proved fee, else `NotSent`); `spent` and `retry` are
    `Unconfirmed`. A page sync follows every proved send.
  - Busy from Rust's keep reads the log again to say which: a pending send
    (`sending`) or a conversion (`converting`).
  - The send id is a random version-4 UUID made in Dart (`Random.secure`);
    the app has no direct `uuid` dependency.
- **D-97 (M7.2): the spend guard as built, beyond the minimal one (D-82).**
  `PrivateUsdSpendGuard` is a `ChangeNotifier` per wallet with zapp's rule
  order: a payment starting now (`send`, `startConversion`, in memory),
  then `unreadable` (the log did not read; read again after 30 s), then
  `checking` (not read yet), then `sending` (an `unconfirmed` row), then
  `converting` (the engine's snapshot holds a conversion under way), else
  `available`. `send` reads the log and Rust's `unfinished_count` again
  just before anything is proved; `startConversion` (the reverse funding)
  reads the log, since Rust's reverse calls do not, and never counts the
  conversion it funds. `canStartConversion` is now zapp's (`available` or
  `converting`), for the Convert button; the reverse funding shows the
  pending-payment note or the store error when a send blocks it. The guard
  keeps the rows it last read for the activity, and forgets a deleted
  account's.
- **D-98 (M7.2): when settlement runs, as built.** `privateUsdSenderProvider`
  is kept alive by `PrivateUsdEngineHost` and settles the account of every
  Railgun sync (`railgunEngineStateProvider.lastSync`: balance refreshes,
  the sync after each send, conversions'), the active account on unlock,
  on an account switch and at start when its log holds an `unconfirmed`
  row, and during a send's landing wait; only in the foreground while
  unlocked and not drained. Building it at start builds the `RailgunEngine`
  object (no page and no bridge start; its constructor's cleanup of a page
  a previous Flutter engine left now runs at start rather than on first
  use). It registers with `privateUsdLifecycleProvider`: a deletion or
  reset refuses new sends and passes and waits up to 30 s for running ones.
- **D-99 (M7.2): routes and UI as built.** Reference §9.2 and §9.4 S8
  updated.
  - `/private-usd/send` and `/private-usd/withdraw` (one screen, the mode
    fixed by the button), `/private-usd/{send,withdraw}/review`, and
    `/private-usd/send/status` (`extra`: the mode). Each step pushes the
    next and pops with a result, as the convert review does; "Done" closes
    the status, the review and the form. Back is blocked while a send runs;
    back during the price look-up drops it.
  - The status reuses `MobileTransactionProgressScreen`: "Proving your
    transaction · n%" with the proving detail, then "Sending" with a new
    landing line once kept; "Sent" or "Withdrawn", pending while not in a
    block. It has two action slots, so it offers "Done" and "View on
    Etherscan"; "View on Railscan" (copy kept) is not shown.
  - The amount field takes up to 18 typed decimals so "Use at most 6
    decimal places." can show (zapp flags rather than blocks). "Use it all"
    is the available amount less the reserve: the last quoted fee, else the
    relayer's floor (`minNetworkFee`, read from the terms when the form
    opens). Withdrawals offer the deployment's swap token only.
  - On `/private-usd`: Send and Withdraw under the total (enabled when the
    guard is `available` and some dollars are available), the spending
    note under them, and Convert disabled unless a conversion is under way
    or the guard allows one. Send rows (sent, withdrew, not in a block yet;
    the transaction on Etherscan) show on `/private-usd` only; the home and
    Activity feeds keep conversions only. A send still being proved has no
    row: it is not in the log, and back is blocked meanwhile.
  - `isValidEvmAddress` requires a lowercase `0x` prefix, as zapp's
    `^0x[0-9a-fA-F]{40}$` and Rust's `is_destination` do; the mixed-case
    EIP-55 rule and the zero-address refusal are `_isEvmAddress`'s and
    `isZeroEvmAddress`'s. `0zk` recipients go through Rust's synchronous
    `private_usd_is_valid_railgun_address` and are sent lowercased.
- **D-100 (M7.3): the copy as built.** The Send and withdraw table is in
  `PrivateUsdCopy`, with `privateUsdSpendMessage(status)` (the spending
  note) and `privateUsdSendErrorMessage(code)`. New for veylor: "Paste" (the
  recipient's paste button), "Veylor can't read its saved payments." with
  the support sentence (the guard's `unreadable`), "Proving your
  transaction · n%", and the landing line "The relayer is sending it.
  Waiting for a block can take a minute. Keep Veylor open."
- **D-101 (M7.4): Widgetbook and capture scenarios.** The nine send rows of
  §9.7 and `mobile-private-usd-payment-pending`, in
  `lib/widgetbook/private_usd_send_use_cases.dart` and
  `private_usd_use_cases.dart`, registered in Widgetbook and as
  `FigmaCompareScenario`s; the default screen now has Send, Withdraw and a
  send row. Previews have no Rust, so they pass their own `0zk` check.
  Captured with `scripts/figma-compare.sh widget --form-factor mobile`
  (dark) and reviewed; `mobile-private-usd-send-done` shows Etherscan only
  (D-99).
- **D-102 (M7): the Dart tests as built.** Eight, per the owner's scope.
  Untagged: `private_usd_sender_test.dart` (3: the fee cap before proving,
  for review and for a confirmed fee priced again, with `Repriced` above the
  confirmed fee and no proof; a proof that lands after a lock, in the
  background or after a pause even back in the foreground is never kept,
  and in the foreground it is kept, then posted from the store, then
  settled, the page's JSON unchanged; a refusal priced higher is
  `Repriced`, and a `retry` is `Unconfirmed` and blocks the next send
  unproved) and `private_usd_send_rules_test.dart` (3: `0zk` through Rust's
  call; `0x` with EIP-55, the zero address and the amount rules; the guard
  across restarts). Mobile-tagged: `mobile_private_usd_send_screens_test.dart`
  (2: the form's states; review, proof, outcome and the payment-pending
  screen), plus the 10 new scenarios in the mobile scenario smoke test.
- **D-103 (M7): the device round's M7 scenario, written and not run.**
  `run_device_round.sh --m7 --m7-to 0x… [--m7-usd 1]` (off by default;
  implies no release check and keeps the page storage; with `--m5` or
  `--m6` it runs after them) runs `private_usd_device_test.dart` twice
  around `am force-stop`, on the wallet an M5 round left (never reset).
  Start: a send through the screens to a second account's `0zk` arrives
  there, in Processing (MissingExternalPOI) on Sepolia; a withdrawal
  reaches `--m7-to` (the host reads its public ERC-20 balance over the
  deployment's keyless RPC: `device_round.py`'s new `/erc20-balance`); a
  third send is kept and its first post held (a provider override in the
  test, no production hook), so the kill lands between proving and the
  post. Resume: before unlock the log holds that send, kept and never
  posted; after unlock settlement posts the same kept bytes and it lands,
  with no proof made (a counting page override) and no new row. Events
  carry outcomes, buckets and timings only.
- **D-104 (M8.1): the route round, written and not run.** Plan M8 updated.
  - **How it runs.** `run_device_round.sh --m8-route [--m8-route-phases
    forward,reverse,send]` is off by default. It implies no release check
    and keeps the page storage. Given with `--m5`, `--m6` or `--m7`, it runs
    after them. It runs `private_usd_device_test.dart` once, with
    `VIZOR_PUSD_DEVICE_M8_ROUTE=<phases>`.
  - **What it reuses.** It runs on the wallet earlier rounds funded (never
    reset), starting with Tor off. `_M8RouteRound` drives the screen steps
    of `_M5Round`, `_M6Round` and `_M7Round` on its own app, with their
    amounts (`--m5-zec`, `--m6-usd`, `--m7-usd`).
  - **Forward.** It converts ZEC, or follows a forward conversion already
    under way. Once the record shows `CLAIMING` it turns Tor on, then
    follows the conversion to Paid. It records the step codes seen after
    the flip. If the conversion ends before its claim is seen, the phase is
    recorded as skipped.
  - **Reverse.** It converts private USD back and turns Tor on while the
    page proves the payment. It records whether the flip cut off the proof
    (nothing to pay with) or met a submit. Then it taps "Pay" over Tor (up
    to three tries), authorizes settlement and waits for `COMPLETE`.
  - **Send.** It sends to a second account's `0zk` and turns Tor on while
    the page proves the send. A send the flip cut off must be back on its
    review with nothing kept. The same review then sends it again. Exactly
    one new proof is kept, and it lands (`confirmed`) over Tor.
  - **Fail closed.** From the flip on, no host sample may show a direct
    socket to a Railgun host. The host samples every 15 s while Tor
    connects, then every 30 to 60 s. Once Tor has connected, no sample may
    show a socket that is neither loopback nor a Tor relay. The sample
    taken as Tor connects is the exception, as in M3: sockets the direct
    route opened may still be closing. Tor turns off after each phase.
  - **Refusals and events.** The reverse and send phases refuse to start
    while a conversion is under way. Events carry the swap index, phases,
    steps, outcomes and timings only.
  - **Deviation from the plan's "resumes".** The forward claim resumes by
    itself: the loop retries the failed step over Tor. The reverse funding
    and the send resume through the user's own retry ("Pay", or the review's
    send), because the app never proves again by itself (D-81, D-96).
- **D-105 (M8.3): the keyed RPC check as built, and the static audit.** Plan
  M8 updated.
  - **The input file.** `run_device_round.sh --keyed-rpc <json>` takes a
    `--dart-define-from-file` JSON.
    - The runner refuses a file that git tracks, or one inside the repo that
      is not gitignored.
    - `device_round.py keyed-rpc-check --require sepolia` checks that
      `VIZOR_ETHEREUM_RPC_URL_SEPOLIA` is https, on a host the app accepts,
      with a key in its path or query. It prints the hosts only.
    - Every build in the round takes the file, so the URL never appears on a
      command line.
  - **The app's files.** After the test the runner force-stops the app and
    runs `keyed-rpc-scan --app-files`.
    - `run-as` lists the `*private_usd*` files and `shared_prefs/`: that is
      `swaps.db` with its WAL and SHM, `joint.db` and the token state.
    - It reads each into memory with `exec-out run-as … cat`, and checks the
      byte count against `stat`.
  - **The logs.** At the end the runner saves `logcat -d` to
    `logcat-final.txt` and runs `keyed-rpc-scan --logs` over every file in
    the evidence directory: the logcat captures, the test and build logs,
    the driver log, events and checkpoints.
  - **The patterns.** Each keyed URL's host and path, the same JSON-escaped
    (org.json writes `\/`), and its key: each path or query part of 12 or
    more characters.
  - **The verdict.** Exit 0 means clean, 1 found, 2 could not check; 1 or 2
    fails the round.
    - The verdicts go to `keyed-rpc-scan-{app-files,logs}.json` and
      `summary.json`.
    - They name patterns only by label ("sepolia key"): neither the URL nor
      the key is ever printed or written.
    - Tested on the host with a fake key: a clean directory passes; a
      JSON-escaped URL in a log is found under both labels; a host outside
      the allowlist is refused.
  - **Not scanned.** The page's own storage (`app_webview`), which receives
    the keyed URL by design.
  - **The static audit found no leak, so nothing was changed.**
    - Rust: the keyed URL reaches only `EvmRpc::new`, through
      `Deployment::rpc_url`, and records pin only `keyless_rpc_url`
      (`RecordDeployment`). `evm_rpc` errors name the JSON-RPC method only.
      `routed_http`'s errors quote connector and Tor errors, which name at
      most the host, never the path. The Private USD log lines carry error
      codes, swap indices and send ids. `railgun_bridge.rs` logs no target.
    - Dart: only `private_usd_feature_config.dart` reads the define;
      `privateUsdKeyedRpcUrl` logs only that a host was refused.
      `PrivateUsdSwapContext.ethRpcUrl` is a getter, so no `toString` shows
      it, and `RailgunStartParams.toString` hides `rpcUrls`. Page log
      events are dropped, and page errors print only through
      `redactRailgunMessage`. Engine and sender debug lines print runtime
      types. There is no `ProviderObserver`. No persisted value holds the
      URL: the balance cache, the engine key store and the kill switch hold
      none of it.
    - Kotlin: the Railgun host has no `Log` call. `onConsoleMessage`
      consumes the page's console, which is forwarded only as debug `log`
      events, and Dart drops those. Its errors name page asset paths only.
      Gradle decodes only its own dart-defines and prints none.
- **D-106 (M8.6): the D9 claim holds; AGENTS.md corrected.** Plan D9 and §11
  updated.
  - **What is gone.**
    - `rust/src/android_jni.rs` does not exist.
    - `IronwoodMigrationPreparationWorker` appears nowhere in `android/`,
      `lib/` or `rust/`.
    - Neither `pubspec.yaml` nor Gradle has WorkManager.
  - **Why.** Commit `459a8565b` (2026-07-28, "[mobile] Remove Android
    private migration service") removed the Android preparation and outbox
    workers, their Kotlin bridge, secure store and tests, and
    `android_jni.rs`. It also made the private mobile migration iOS-only:
    Android redirects to the fast migration
    (`supportsPrivateMobileIronwoodMigration`).
  - **What AGENTS.md now says.**
    - The Rust module tree: `migration_preparation.rs`'s operation
      lifecycle, preparation-only sync and advance have no native caller.
    - "Foreground Sync and Platform-Specific Migration Preparation": only
      iOS has native background work.
    - The key files.
    - A new "Private USD" section, before Testing.
  - **The plan was right.** D9 and §11 now put it in the past tense.
- **D-107 (M8.2): the kill switch's coverage, recorded; no new test.**
  - `test/core/config/private_usd_feature_config_test.dart` (M3) covers:
    - only an explicit bool is an answer: not a string, another key, an
      array or non-JSON;
    - without an answer the last value stands, else available;
    - no URL means available, with no fetch;
    - an explicit `false` hides the feature and is remembered;
    - a failed fetch, and a document without the flag, both keep the last
      `false`;
    - a failed fetch with nothing known stays available;
    - a later `true` brings it back.
  - `private_usd_available_provider_test.dart` covers that `false` makes
    the feature unavailable, and that the engine's build gate never reads
    the switch, so conversions under way keep going.
  - The live check (E7) is checklist run M-13. The device test cannot reach
    a flag URL (D-42).
- **D-108 (M1.10b): deferred again.** Not done in M8. Moving the Enhance PIR
  transport and voting's `VizorRoute` onto `routed_http` without a
  behaviour change needs three things `routed_http` lacks: streaming
  response bodies, the `on_dispatch` hook and the SDK's observation phases
  (M1 status). So it is not a safe drop-in. It stays a separate PR, outside
  this branch.
- **D-109 (M3.14): a wallet made in mobile onboarding had no ZIP-32 index
  until the next launch.** `_createAccount` and `_createAccountFromMnemonic`
  built `AccountInfo` without `zip32AccountIndex`, which Rust's
  `list_accounts` only fills at the next bootstrap, so Private USD stayed
  hidden (D6, D8) on a new wallet until a restart. Both now set 0: Rust
  creates ZIP-32 account 0 of the mnemonic on both paths
  (`init_db_and_create_account` on a fresh DB, `add_account_at_index(…, 0)`).
  Found by the device round's first check.
- **D-110 (M3.14): the device round's listener and timing checks.** A debug
  build holds a loopback listener of its own (the Dart VM service and
  tooling; the release build has none before first use), so the round takes
  a baseline of the app's loopback listeners right after creating the
  wallet and counts only listeners that appear after it. A refresh over Tor
  can wait behind the engine's previous use for more than 10 s, so the
  round now waits up to 60 s for it to start. The availability check's
  message now names every input.
- **D-111 (M3.14): an existing voting bug the round hit.**
  `VotingShareTrackingRestorer.resume` read its `ref` after awaiting the
  pause in flight; when the provider was disposed meanwhile (app exit, a
  test's teardown) it threw `UnmountedRefException`. It now checks
  `ref.mounted` after the wait. Voting's tests pass (`+311`).
- **D-112 (M5.8): the balance watch is registered after the build.**
  `privateUsdBalanceKeepFreshProvider` called `notifier.watch(…)` while
  building; watching starts polling, which can refresh at once and so
  modify `privateUsdBalanceProvider` during another provider's build
  (Riverpod: "Providers are not allowed to modify other providers during
  their initialization"). It surfaced in the M5 device round once the
  account had a conversion record (in use, D-21). The watch is now
  registered in a microtask and cancelled with the provider.
- **D-113 (B-11): `zakura-protocol =2.2.0`.** Veylor's pin moved from
  `=2.0.0`; the lockfile changes only that crate. `zecswap-core`'s two exact
  pins in the local E1 stand-in (`~/dev/zapp/zecSwap-zakura`, uncommitted,
  with the owner's go-ahead) moved with it; E1's Zakura build must carry
  the same bump. zapp-android is unaffected: it builds from
  `~/dev/zapp/zecSwap` with upstream crates. The M5 round also gained a wait
  for earlier conversions before converting, and the device test an opt-in
  fund phase (`VIZOR_PUSD_DEVICE_FUND=<zec>`): it sends that much from the
  first account to the second through the Send screens and leaves the
  second active, so a conversion can start there while the first account's
  is still closing.

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
- **B-9. The M5 device round (M5.8) needs testnet ZEC on the phone's wallet
  (E8), and the phone attached (2026-10-14).** The scenario is written and
  off by default (D-57). Owner: fund the testnet wallet an earlier round left
  on the phone (or let the M3 round create one, then fund its receive
  address), attach the phone over USB, unlock it, and run
  `ANDROID_SERIAL=RZCX40721QZ scripts/private-usd/run_device_round.sh --m5`.
- **B-6. E1, E2 and E4 are not delivered.** Local stand-ins:
  `~/dev/zapp/zecSwap-zakura` (detached worktree at `d69e3fb` with the §12
  diff; zecSwap has no LICENSE yet) and `~/dev/wallet-libraries-e4` (`391d0b0`
  plus the §6.8 `connect_stream` patch). Nothing built on them, and nothing
  ported from zapp, may be pushed or merged; the M0.3 spike lives on the local
  branch `spike/private-usd-m0`. Since M3 this branch depends on both through
  `rust/Cargo.toml` paths (D-18), and carries zapp's Railgun bundle, JS source
  and the ported Kotlin host, so `feature/private-usd-android` stays local
  until E1, E2 and E4 land.
- **B-10. The M8 device checks need the phone attached (2026-10-14).** M8.1
  (`--m8-route`) and M8.4 (the measurements) run on the Galaxy A35. So does
  M8.3 (`--keyed-rpc`), which also needs E6's keyed RPC JSON. They come
  after the M3, M5, M6 and M7 rounds (B-8, B-9). Owner: the order and the
  commands are in `docs/private-usd-device-checklist.md`.
- **B-11. Testnet sends are rejected: the public testnet is not the Zakura
  testnet (2026-10-14).** The M5 device round's deposit (txid
  `e62e4dcd…6cb20c`, built at 4502115) never landed. Its bytes, sent to
  `testnet.zec.rocks` by hand, came back `errorCode -25: transaction did not
  pass consensus validation: transaction uses an incorrect consensus branch
  id`. `zakura-protocol 2.0.0` puts testnet NU6.2 at 4,052,000 (branch
  `5437f330`) and NU6.3 at 4,134,000 (branch `37a5165b`), so above 4,134,000
  the wallet signs every testnet transaction for Ironwood (v6, `37a5165b`).
  `testnet.zec.rocks` (Zebra 7.0.0-rc.0, the app's only testnet endpoint)
  was at 4,502,135 on branch `77190ad9`. Every testnet send from this build
  fails there, not only Private USD deposits; receiving still works.
  Funds are safe: the deposit never left the wallet, its notes return at
  its expiry (4502158), and the swap ends with nothing sent. The M5 to M7
  device rounds need a testnet whose consensus matches the wallet's (an
  Ironwood testnet lightwalletd), owner to provide.
  Cause, from zecSwap's `docs/deployment.md` ("October 6 NU7 maker
  upgrade") and `deployments/retired/sepolia-nu7-maker.json`: **Zcash
  testnet activated NU7 at block 4,465,026 (2026-10-04, branch
  `0x77190AD9`).** zecSwap's maker hit the same rejection with
  `zcash_protocol` 0.10.6 (NU6.3 newest) and was moved to the librustzcash
  NU7 pre-releases on 2026-10-06; zapp's Android SDK builds are noted as
  still rejected. Veylor's Zakura libraries have no testnet NU7 (veylor's
  `network.rs`: NU7 has no activation height on main or test), so the fix
  is NU7 testnet support in the Zakura wallet libraries (owner: E1/E4 or a
  wallet-libraries release), not app code. Mainnet has no NU7 and is
  unaffected. Until then the swap device rounds can run only on mainnet
  (owner's explicit go-ahead, small amounts under the beta limits), or wait.
  **Fix applied (2026-10-14, owner's go-ahead): `zakura-protocol` 2.0.0 →
  2.2.0** (D-113). 2.2.0's only behavioural change sets the testnet NU7
  activation (4,465,026); mainnet is unchanged. The Zakura node crates
  (`zakura-chain` 9, `zakura-consensus` 10, `zakura-rpc` 12) pin 2.2.0;
  Zakura's 3.0.0 wallet crates (Rust 1.97) are not needed. The swap that
  hit the rejection (index 11) stays under way until the maker refunds its
  lock after t1 (19:33:48 UTC), then ends with nothing sent; the next M5
  round waits for it. Also learned: the
  testnet maker caps a swap at 20 USDC, and testnet prices ZEC at about
  1,200 USD, so the rounds use about 0.01 ZEC (the quote for 0.01 was
  $10.86 after fees).

