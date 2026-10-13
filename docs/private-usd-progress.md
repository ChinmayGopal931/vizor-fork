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
- [ ] M0.1.4 Debug APK build (`VIZOR_FORM_FACTOR=mobile`); record the `.so` size delta
- [x] M0.2a Offline: a payment to an Orchard-only UA lands in the Ironwood bundle, and `sent_notes` records it (`output_pool` 4, `to_address` = the UA). Go on both checks (D-3)
- [ ] M0.2b The same on testnet (blocked: B-3, B-4)
- [x] M0.3.1 `connect_stream` patch in a local wallet-libraries checkout (`~/dev/wallet-libraries-e4`); all ten wallet-libraries refs repointed (spike branch)
- [x] M0.3.2 `rust/src/railgun_bridge.rs`, tokio I/O for `DirectRouteIo`, and the Rust FRB `start_railgun_bridge` / `stop_railgun_bridge` (spike branch). 8 tests pass, including an ignored one run once here that bootstraps real Tor and tunnels through the bridge to `ethereum-sepolia-rpc.publicnode.com:443` via the patched `connect_stream`
- [ ] M0.3.2b Dart bindings for the bridge calls regenerated (blocked: B-1)
- [ ] M0.3.3 Minimal Kotlin host (org.json port) with the `ProxyController` override: written on the spike branch, not compiled (blocked: B-1)
- [ ] M0.3.4 Debug-only route on Sepolia: `start`, `openWallet`, `refresh`, one `transfer` proof (not posted)
- [ ] M0.3.5 Measure first sync, proof time, peak memory and artifact bytes; record in plan §11
- [ ] M0 gate: go/no-go recorded for M0.1, M0.2 and M0.3; only the `rust-version` line lands

M0 status (2026-10-13). M0.1 is a go for `zecswap-core` and `zecswap-railgun`
and a no-go for `zecswap-tokens` (D-1). M0.2 is a go offline. M0.3 is
undecided: the Rust side works on a desktop host, and the WebView side needs a
device. On this branch's M0 commit (the `rust-version` line, the M0.2 test,
docs), `cd rust && cargo test` passes: lib 1430 passed, 0 failed, 9 ignored;
integration 6 passed, 21 ignored (regtest). After the toolchain install:
`fvm flutter analyze` finds no issues, and `fvm flutter test` (desktop lane)
gives 5896 passed, 158 skipped, 4 failed. The 4 failures are pre-existing on
`main`; this branch changes no Dart. They are in
`test/features/settings/settings_seed_phrase_screen_test.dart`, the "incoming
links cannot interrupt backup completion/deferral success/failure" cases, which
cannot find the `AppButton` "Enter amount" (test line 159). They fail the same
way when the file runs alone. The APK build is still pending (NDK and disk).

## M1. Rust foundations

- [ ] M1.1 `rust/Cargo.toml` dependency lines (zecSwap crates, `hmac`, `sha3`, `bech32`)
- [ ] M1.2 `private_usd/mod.rs`: module tree and `PrivateUsdNetwork`
- [ ] M1.3 `deployment.rs`: §7.1 pins and §7.2 constants, including the 2,000,000 fee cap
- [ ] M1.4 `railgun_keys.rs`: BIP-85 and the Railgun key chain (§3.3)
- [ ] M1.5 `keys.rs`: `SwapKeyContext::open` (seed, ZIP-32 index, fingerprint check)
- [ ] M1.6 `models.rs`: forward and reverse records in zapp's JSON shape
- [ ] M1.7 `terms.rs`: forward and reverse terms, `terms_hash`, EIP-712
- [ ] M1.8 `store.rs`: `swaps.db` schema and migrations, `take_index`, `save_record`, queries
- [ ] M1.9 `indices.rs`: index allocation with on-chain skipping
- [ ] M1.10 `rust/src/wallet/routed_http.rs` (§8.5)
- [ ] M1.10b Separate PR: Enhance PIR transport and voting `VizorRoute` onto `routed_http` (may slip to M8)
- [ ] M1.11 `evm_rpc.rs`: every §5.4 read behind `ChainReader`
- [ ] M1.12 `maker_client.rs` and `relayer_client.rs` behind `HttpTransport`
- [ ] M1.13 `rust/src/api/private_usd.rs`: `ApiPrivateUsdError`, `ApiDeployment`, the five M1 calls; bridge regenerated
- [ ] M1 gate

## M2. Zcash joint-account operations

- [ ] M2.1 `private_usd/joint.rs` (`joint.db` operations)
- [ ] M2.2 Discard OVK for joint sweeps (`SendPurpose::JointSweep`, `StoredProposal.purpose`)
- [ ] M2.3 `propose_joint_sweep` in `send.rs`
- [ ] M2.4 `sweep_joint` in `joint.rs`
- [ ] M2.5 The deposit split in `send.rs`
- [ ] M2.6 `find_deposit` and `swap_tx_status`
- [ ] M2.7 Ignored Ironwood regtest test (run only with the owner's go-ahead)
- [ ] M2 gate

## M3. Railgun host, Tor bridge, availability and the read-only balance

- [ ] M3.1 Bundle (§8.7 commands 1, 2, 5 and the `build.mjs` edit)
- [ ] M3.2 Kotlin host in `android/app/src/main/kotlin/com/keplr/vizor/railgun/`
- [ ] M3.3 Gradle and manifest
- [ ] M3.4 Rust bridge `rust/src/railgun_bridge.rs` for real
- [ ] M3.5 Dart, Railgun side
- [ ] M3.6 Dart, balance repository, cache and provider
- [ ] M3.7 Availability
- [ ] M3.8 Home strip
- [ ] M3.9 `/private-usd` route, guard and screen
- [ ] M3.10 Lifecycle (no funds yet)
- [ ] M3.11 Copy (Shared, Home, Private USD screen, Activity)
- [ ] M3.12 Widgetbook and capture scenarios (home, `/private-usd`)
- [ ] M3.13 Kotlin tests (`RailgunBoundaryTest`, `RailgunChannelTest`, `RailgunProtocolTest`)
- [ ] M3 gate

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
- **Local build setting:** all Rust builds here use
  `CARGO_PROFILE_DEV_DEBUG=0` (no debug info) so the target directory fits the
  free disk. No repo file changes.

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
- **B-2. Disk.** 7.4 GB is free on a 460 GB volume after M0's builds
  (`rust/target` is 9.2 GB with Rust debug info off). Flutter, Gradle and the Android Rust targets need more.
  The largest reclaimable directories are `~/dev/zapp/zecSwap/target` (39 GB)
  and `~/dev/zapp/zecSwap-mainnet-beta/target` (18 GB). Clearing them is the
  owner's call.
- **B-3. No Android device or emulator.** `adb devices` is empty, and the SDK
  has no emulator package, system images or `cmdline-tools`. That blocks
  M0.3.4–M0.3.5 (and so the D4 go/no-go), the M0.2 testnet run and every device
  acceptance from M3 on.
- **B-4. M0.2 on testnet needs funded testnet ZEC (E8).** The routing was
  verified offline instead (see the M0.2 line).
- **B-5. `zecswap-tokens` (D-1).** An owner decision is needed before M4:
  options (a)–(c) in plan M0.1 result.
- **B-6. E1, E2 and E4 are not delivered.** Local stand-ins:
  `~/dev/zapp/zecSwap-zakura` (detached worktree at `d69e3fb` with the §12
  diff; zecSwap has no LICENSE yet) and `~/dev/wallet-libraries-e4` (`391d0b0`
  plus the §6.8 `connect_stream` patch). Nothing built on them, and nothing
  ported from zapp, may be pushed or merged; the M0.3 spike lives on the local
  branch `spike/private-usd-m0`.
