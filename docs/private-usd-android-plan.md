# Private USD (shielded ZEC ↔ Railgun USDC) on Android: implementation plan

**Goal.** Port zapp-android's Private USD to vizor:

- a Railgun USDC ("private USD") balance on the home screen
- conversion both ways between shielded ZEC and private USD, by atomic swap, with refunds and refund recovery ("rescue")
- private USD send (to a Railgun `0zk` address) and withdraw (to a public `0x` address)

**Scope.** Android, mobile form factor (`--dart-define=VIZOR_FORM_FACTOR=mobile`). iOS and desktop come later, so keep the Rust engine, the Dart models and the JS bundle platform-neutral. iOS then needs only a Swift `WKWebView` host and an attestation channel.

**Status (2026-10-13).** M0 is done (results in §4). M1 is done except its optional task 10b, which slips to M8. M2 is done, including its Ironwood regtest run (M2.7b, passed 2026-10-13 after the fresh-tip fix D-50). M3 is done (tasks 1–13: the native layer, the Dart Railgun side, balance, availability, the home strip, `/private-usd`, lifecycle, copy, Widgetbook and the Kotlin tests) except its device round, M3.14, which is batched with the others. M4 is skipped for now: it waits for N1 (B-5), and M5–M7 proceed without tokens (D20; the owner disabled them on testnet for now). M5 part 1 (tasks 1–2, the Rust engine and its FRB calls) is done; part 2 (tasks 3–7, Dart) is next. Progress lives in `docs/private-usd-progress.md`.

**Two files.** This file holds the decisions, the architecture, the work and the test strategy. The reference sections §5–§9 and §12 live in `docs/private-usd-reference.md`, with the same numbers:

- §5 protocol and state machines
- §6 the Railgun host
- §7 pinned config
- §8 vizor integration
- §9 UI and copy
- §12 the source map

A pointer such as "§5.5" means that file. Open a reference section only when a milestone's **Inputs** names it.

## How to work

- **Checklist.** `docs/private-usd-progress.md` has one line per task. Check a line only when the task is done, and commit the checklist with the work. It also holds the Deviations and Blocked lists.
- **Order.** Work the milestones in order, and the tasks within one in order, without stopping between tasks.
- **Milestone done.** A milestone is done when its **Done when** list holds and `cd rust && cargo test`, `fvm flutter analyze` and `fvm flutter test` pass, plus the mobile lane for UI milestones. Then commit locally with the milestone in the message. Never push.
- **When to stop and report.** Stop at these points only:
  - a milestone is done
  - nothing can move without an owner deliverable or decision (§2)
  - the next step is risky or irreversible: a push or PR, mainnet funds, Figma edits, deleting user data, or running a heavy regtest suite without the owner's go-ahead
- **When not to stop.** Do not end a turn to:
  - announce the next step without taking it
  - offer options
  - list decisions that block nothing

  Put status notes and recommendations in the same message as the next tool call.
- **Deviations.** When the code or a library disagrees with this plan, follow reality. Then fix the plan and log the deviation in the progress doc, in the same commit.
- **Testing** (owner, 2026-10-13). End-to-end runs come first, and device rounds are batched for when funded test wallets exist (§10). Write unit tests only for what guards funds or keys: known-answer vectors, fee caps, the index, deposit and reveal rules, and parsing.
- **Reading.**
  - Load only a milestone's **Inputs**.
  - Read only the line ranges given for these large files: `rust/src/wallet/sync/send.rs`, `pczt.rs`, `lib/src/providers/sync_provider.dart`, `account_provider.dart`, `lib/app.dart` and `mobile_home_screen.dart`.
  - Never open `railgun.js`, the `.wasm` files, `package-lock.json` or zapp's whole `strings.xml`; the copy is in §9.6.
  - Copy zapp files with the §8.7 commands; never read them into context in order to copy them.

**Commands.**

| What | Command |
|---|---|
| Rust tests | `cd rust && cargo test` (use `CARGO_PROFILE_DEV_DEBUG=0` locally; the disk runs near-full) |
| FRB bindings | `scripts/generate-rust-bridge.sh` after any `rust/src/api/*.rs` change. rustc 1.93 adds comment-only noise in the voting/sync bindings (a renamed `derive(Eq)` helper); commit only real changes. |
| Dart | `fvm flutter analyze`; `fvm flutter test`; mobile lane: `fvm flutter test --tags mobile --run-skipped --dart-define=VIZOR_FORM_FACTOR=mobile` |
| Kotlin | `cd android && ./gradlew :app:testDebugUnitTest --tests 'com.keplr.vizor.railgun.*'` |
| Device (Galaxy A35, `adb -s RZCX40721QZ`) | `fvm flutter run -d RZCX40721QZ --dart-define=VIZOR_FORM_FACTOR=mobile --dart-define=VIZOR_PRIVATE_USD_ENABLED=true`; keep the screen on during long steps (U21) |
| Stale native-lib merge after switching ABIs | delete `build/app/intermediates/{merged,stripped}_native_libs` and rebuild |

**Local stand-ins until the owner delivers.** These must never be pushed:

- E1: `~/dev/zapp/zecSwap-zakura`, a detached worktree at `d69e3fb` with the §12 Zakura diff, referenced through a `[patch]`.
- E4: `~/dev/wallet-libraries-e4`, rev `391d0b0` plus `connect_stream`. Since M3 every wallet-libraries reference in `rust/Cargo.toml` (the eight `[patch.crates-io]` entries and both `zakura-pir-transparent` entries) is a path into it, marked do-not-merge (B-6).
- The M0 spike code is on the local branch `spike/private-usd-m0`: the bridge, the Kotlin host, `RailgunHostHandler` and the device harness `lib/railgun_spike_main.dart`. M3 starts from it.

**Path prefixes.** Unprefixed paths are in this repo (`main` at `4a859bee0`).

| Prefix | Meaning |
|---|---|
| `za/` | `~/dev/zapp/zapp-android`, branch `release/4.7.0` (`60bcf0b30`) |
| `ui/` | `za/ui-lib/src/main/java/co/electriccoin/zcash/ui/` |
| `ua/` | `ui/common/atomicswap/` (zapp's Android runtime for swaps) |
| `pu/` | `ui/screen/privateusd/` |
| `rl/` | `za/railgun-lib/` |
| `of/` | `za/offramp-lib/src/commonMain/kotlin/xyz/justzappit/offramp/atomicswap/` (the swap driver, pure Kotlin; the source of truth) |
| `str:` | a line in `za/ui-lib/src/main/res/ui/private_usd/values/strings.xml` |
| `zs/` | `~/dev/zapp/zecSwap-mainnet-beta`, branch `feature/mainnet-beta` (`d69e3fb`). zapp pins zecSwap `9b52dfc`. |
| `zc/`, `zapi/`, `zcore/` | `zs/crates/zecswap-client/src/`, `zs/crates/zecswap-api/src/`, `zs/crates/zecswap-core/src/` |
| `zl/` | `~/dev/zapp/zecSwap/docs/local/` (gitignored handoffs; `android.md` §2, §6 and §6b give the client flow step by step) |
| `zo/` | the `zakura-orchard 2.0.0` crate source |
| `wl/` | `zakura-core/wallet-libraries@391d0b02`, in the cargo cache at `~/.cargo/git/checkouts/wallet-libraries-c6fca17639ab2de0/391d0b0/` |
| `vr/` | `rust/src/` in this repo |

## 1. Decisions

### 1.1 Owner decisions (final, 2026-10-13)

| # | Decision | Why, and what follows |
|---|---|---|
| D1 | The owner registers vizor's app id and signing-certificate digests with the token issuers. | Without it the issuer refuses vizor's attestation, so no swap can be accepted (E3). |
| D2 | Networks: mainnet beta, plus Zcash testnet with Sepolia for development and E2E. | Regtest has no deployment, so the feature is hidden there (§7.1). |
| D3 | Path B. The owner adds a Zakura build of `zecswap-core` to zecSwap under an Apache-2.0-compatible license, and relicenses their zapp code to Apache-2.0. vizor depends on `zecswap-core`, `zecswap-railgun` and `zecswap-tokens` by git rev. The Railgun JS bundle ships as a separately licensed asset, with its GPL-3.0 notices. | One audited source with known-answer vectors. Do **not** depend on `zecswap-client`: it pulls `zecswap-chain` (alloy, rusqlite, the orchard circuit) and its own reqwest, which bypasses vizor's Tor route. Port its driver instead, as zapp did in Kotlin. Shipping `libzecswap.so` (two Zcash stacks in one APK, no iOS path) is rejected. |
| D4 | Build a Tor bridge: a loopback SOCKS5 listener in Rust over vizor's in-process arti, with the WebView pointed at it through androidx.webkit `ProxyController`. | Railgun page traffic then follows vizor's route setting. It is **unverified**, so it is spike M0.3. **Fallback if the spike fails:** Private USD is unavailable while Tor is on. |
| D5 | v1 scope: home balance, convert both ways, refunds and rescue, and private send and withdraw. | |
| D6 | One Private USD wallet and one swap state per software account, following the active account. Hardware accounts (Keystone, Ledger) hide the feature. | Hardware accounts have no seed on the phone. An account with no ZIP-32 derivation metadata also hides it (D8 needs the index). |
| D7 | The Railgun BIP-85 input is the account's 64-byte BIP-39 seed **including** its passphrase, the same seed the Zcash keys use. | A passphrase-protected vizor account therefore has a different Railgun wallet from zapp on the same words. |
| D8 | The BIP-85 index and the swap-key `account` are the vizor account's ZIP-32 account index. | Index 0 matches zapp for the same seed. Two accounts on one seed get separate key spaces. |
| D9 | Foreground only. Every key-using step (deposit, claim, payout signature, refund, sweep, Railgun proving) runs only while the app is unlocked and in the foreground. No per-swap keys are stored. No worker, alarms or notifications in v1. | vizor's mnemonic is encrypted under the session password and is unreadable while locked (`lib/src/core/storage/app_secure_store.dart:284-300, 898-915`). vizor has no Android worker: the `IronwoodMigrationPreparationWorker` and `rust/src/android_jni.rs` that AGENTS.md describes are not in this repo, and `pubspec.yaml` has no WorkManager. An absent user cannot lose funds (§5.8), but a conversion may fail or refund. A key-free reminder notification is a later enhancement. |
| D10 | Privacy Pass token issuance follows the route setting: over Tor when Tor is on, direct otherwise. | zapp requires Tor for issuance; vizor's Tor is opt-in. Disclose, when Tor is off, that the issuer sees the device attestation next to the IP (`tor_off_disclosure`, §9.6). |
| D11 | Relayer fee cap: **2 USDC** (2,000,000 base units for 6-decimal tokens) per network, enforced at quote, payout, refund payout and Railgun sends. A higher fee is refused with a clear error. | zapp has no cap. X6 extends it to the reverse funding fee and the rescue fee. |
| D12 | Joint sweeps and refund sweeps use **Discard OVK**. | The maker knows the joint viewing key. A sweep encrypted to the joint OVK would let the maker read the user's home address. The deposit keeps the sender OVK (§8.1.3). |
| D13 | The ~15-line `connect_stream` patch lives in the owner's fork of `zakura-core/wallet-libraries`. vizor's wallet-libraries refs point at that fork's rev. | No upstream PR and no second arti instance. |
| D14 | While the app is unlocked and in the foreground, advance the in-flight swaps of **every** software account, not only the active one. | An account switch must not push a claim past `t0` or `t1`. `getMnemonicBytesForAccount(uuid)` works for any account while unlocked. |
| D15 | Add a delete-wallet method to the Railgun page (bundle rebuild). Deleting one account removes its Railgun data from WebView storage. A full reset still wipes the whole origin. | |
| D16 | Kill switch: an owner-hosted static JSON file, `{"private_usd_available": true}`, at a URL given by a build-time define, fetched over vizor's policy-aware (Tor-aware) route. | `false` hides the feature, but in-flight swaps keep being driven to completion or refund. A failed fetch keeps the last known value, defaulting to available. Do not use `functions.vizor.cash`, which is upstream's. |
| D17 | Stuck-funds copy says "contact support" with no link. An optional build-time support URL define turns it into a link. | |
| D18 | Spend authentication follows vizor: no extra passcode prompt once the wallet is unlocked. Add confirmation sheets for cancel, refund request and rescue. | zapp prompts before every spend; vizor's send and swap do not. |
| D19 | The issuer allowlist and the build use the current applicationId `com.keplr.vizor`, hard-coded for now. | The fork will move to its own id later. When it does, change `applicationId` in `android/app/build.gradle.kts` and the issuer config together. The Kotlin package `com.keplr.vizor` and the channel names (X7) stay. Attestation carries the applicationId, so an id the issuer does not list fails with `403`. |
| D20 | Makers do not require Privacy Pass tokens today. | M5–M7 device testing does not wait on the issuer allowlist (E3) or a locked-bootloader phone (E9). M4 is still built and unit-tested, because a maker can turn tokens on at any time and the client must already handle `401 tokenRequired`. |
| D21 | zecSwap is licensed `MIT OR Apache-2.0`. | The usual dual license in the Rust and Zcash ecosystem, and compatible with vizor's Apache-2.0 (E1). |
| D22 | Routed HTTP is shared, not duplicated. `rust/src/wallet/routed_http.rs` is built for Private USD (M1 task 10), then the Enhance PIR transport and voting's `VizorRoute` move onto it (M1 task 10b, separate PR). Send settlement stays in Rust. | One routed executor to audit for Tor fail-closed behaviour. Settlement in Rust keeps iOS cheap. |

The owner also confirmed (2026-10-13) that joint accounts live in a **separate database**, not as hidden accounts in `zcash_wallet.db` as zapp does. Hidden accounts would leak into account lists, sync status, voting, PIR recovery and the Ironwood migration.

### 1.2 Plan defaults

The research settled these. They are not owner decisions, so the owner may override any of them.

| # | Default | Why |
|---|---|---|
| X1 | The Railgun host is native Kotlin behind a MethodChannel and an EventChannel, ported from zapp's `railgun-lib`. It is not a Dart WebView plugin. | The host's guarantees need `WebViewAssetLoader`, `shouldInterceptRequest` on every subresource, `createWebMessageChannel` ports (no injected bridge that any frame can call), `onRenderProcessGone` and `WebStorage.deleteOrigin`. `webview_flutter` has no subresource interception and no MessagePort. `flutter_inappwebview` adds a large third-party plugin to a wallet. The engine must also run headless and outside the widget tree. A Swift host can implement the same channel contract later. |
| X2 | Rebuild the bundle (needed for D15 anyway) with `WALLET_SOURCE = 'vizor'` (`rl/web/src/wallet.js:25`) and the init string `vizor-railgun-init` (`rl/web/src/index.js:7`, plus the Kotlin constant). | The rebuild costs nothing extra, and vizor's transactions stop being tagged as zapp's. The wallet id and the `0zk` address do not depend on it. **Unverified:** where the wallet source surfaces on chain. Fallback: keep `'zapp'`. |
| X3 | The `≈ ZEC` figure uses the existing CoinGecko price (`zecHomeUsdUnitPriceProvider`, through the Tor-aware `NetworkHttpClient`). Its gate becomes `swapFeatureEnabled || privateUsdAvailable`. | The figure is indicative only. Never use a maker quote for display, because every quote spends a swap index. |
| X4 | A full reset deletes the device-wide token store. The Keystore attestation key is never deleted; it is regenerated only when a certificate in its chain expires. | The token store's pending returns reference swaps the reset erased. A new attestation key would get a fresh daily allowance, which zapp also avoids. |
| X5 | Swap records live in plain SQLite in app-private storage, like `zcash_wallet.db`. | The records hold no keys. Their most sensitive fields are the relayer ticket and the token blinding secrets. Never log either. `allowBackup="false"` is already set. |
| X6 | The 2 USDC cap (D11) also applies to the reverse funding fee (`reverseFunding.fee`) and the rescue fee. | They are fees to the same relayer, signed by the same user, with the same risk. |
| X7 | Channel names use vizor's existing prefix: `com.zcash.wallet/railgun`, `com.zcash.wallet/railgun/events` and `com.zcash.wallet/private_usd_attestation`. | `MainActivity.kt:447-451`, `BiometricUnlockHandler.kt:227`, `LedgerMobileHandler.kt:821-822` |
| X8 | While a conversion progress screen is visible and a key-using step is pending, keep the screen awake by default, through the existing host `SyncKeepAwakeNativeHost` (`lib/src/core/widgets/mobile/sync_keep_awake_native_host.dart`, over `NativeScreenAwakeBridge`, `lib/src/services/native_screen_awake.dart`); it owns the single native flag (M5 pitfalls). It does not follow the opt-in sync keep-awake setting. | Under D9, screen-off means background, and background means pause. |
| X9 | Add `rust-version = "1.92"` to `rust/Cargo.toml` `[package]`. Do not add a `rust-toolchain.toml`. | zecSwap needs Rust 1.92 and edition 2024; zakura-orchard needs 1.91. The reproducible Android and F-Droid builds pin 1.98.0 (`scripts/release-config/android-reproducible-rust-version.txt`), and a toolchain file would conflict with the policy in `fdroid/README.md:62-68`. Edition-2024 dependencies compile under vizor's edition-2021 root. |
| X10 | Quotes are debounced 700 ms after typing stops. Never quote per keystroke. | Every quote spends a swap index (§9.1). |
| X11 | Tokens are issued in two FRB phases around a Kotlin signing call (§5.9). The engine never issues tokens mid-accept by itself. | Rust cannot call the Keystore. A `401` at the token gate sends nothing, so retrying the accept after issuance is safe. |
| X12 | vizor has no in-app licenses page. Ship `railgun.js.LEGAL.txt` and the GPL-3.0 text beside the bundle, and keep the bundle's JS source and lockfile in the repo. | This satisfies GPL source availability. The owner may also want an in-app notice. |

## 2. Owner deliverables

The implementer cannot produce these. Check the row a milestone waits on before starting it.

| # | What | Blocks | Until it arrives | Status |
|---|---|---|---|---|
| E1 | **zecSwap Zakura build plus license (D3).** A branch or a second manifest for `zecswap-core` (the 17-line diff is in §12) at a pinned rev, licensed `MIT OR Apache-2.0` (D21): `LICENSE-MIT` and `LICENSE-APACHE` at the root, and `license` in every crate's `Cargo.toml`. A Zakura manifest cannot share a workspace with `zecswap-tokens` (M0). | Merging anything that imports the zecSwap crates | Develop against the local `[patch]` (How to work); do not merge | open |
| E2 | **zapp relicensed to Apache-2.0 (D3):** `railgun-lib` (Kotlin and JS glue), `evm-lib/.../hd/Bip85.kt`, `common/privateusd`, `offramp-lib`, the UI copy and the ported tests. Headers still say `AGPL-3.0-only`. | Merging anything ported from zapp (M3 onward) | Write it locally; do not merge | open |
| E3 | **Issuer allowlist (D1).** `com.keplr.vizor` (D19) and the SHA-256 digests of the upload and Play signing keys in the mainnet and testnet issuer configs (`zs/deployments/mainnet-beta.json` `issuer.android`); optionally the debug digest on testnet; turn the mainnet issuer on. | M4 device acceptance; release once a maker requires tokens | M4 merges on unit tests; M5–M7 do not wait (D20) | open |
| E4 | **wallet-libraries fork with `connect_stream` (D13):** `391d0b02` plus the §6.8 patch. | The M3 bridge (merge) | The local copy (How to work). M0 proved the patch on device. | open |
| E5 | **Railgun bundle rebuild:** a `deleteWallet` page method (D15) plus X2's identifiers. The implementer can do it from `rl/web` once E2 lands. | M3 account deletion only | Ship zapp's bundle; account deletion then drops only the engine key | open |
| E6 | **Keyed Ethereum RPC URLs** (paid Alchemy or Infura, mainnet and Sepolia, rate-capped keys). Free tiers fail during Railgun startup. | Realistic device testing; release | publicnode only (M0 synced Sepolia fine on it) | open |
| E7 | **Kill-switch JSON (D16)** at an owner URL. | Release | With the define empty, the feature is available | open |
| E8 | **Testnet stack:** the testnet maker, relayer and issuer workers; a Sepolia test-USD faucet; funded testnet ZEC. | M5–M7 device runs; M0.2b | — | open |
| E9 | **A real Android device with a locked bootloader.** | M4 device runs | — | **done**: Galaxy A35 SM-A356E (Android 16, bootloader locked, verified boot green) |
| E10 | **Artwork:** a Private USD icon and a "private" badge; shared assets, lossless WebP if raster. | M3 polish | An existing `AppIcons` glyph | open |
| E11 | Optional: a support URL (D17). | Nothing | Generic wording | open |
| N1 | **The `zecswap-tokens` decision** (M0): (a) E1 also ships a tokens client build on `blind-rsa-signatures 0.15`; (b) vendor the client half into `rust/src/wallet/private_usd/vendor/`; (c) wait for wallet-libraries to drop its RustCrypto pre-release pins. | M4 code | Nothing else depends on it | open (owner will decide later) |
| N2 | **A funded Sepolia Railgun wallet**: test USDC shielded into a Railgun wallet whose test mnemonic the implementer may use. | The M0.3 transfer proof; M3 and M7 device E2E | Device E2E rounds wait | open |

Nothing is needed on the relayer side: the fee cap is enforced by the client. The toolchain pin is an implementer task (X9).

## 3. Architecture

### 3.1 Components and boundaries

Dart owns UI and orchestration only. Rust owns every key, every swap rule and all swap networking. Kotlin owns the WebView and the Keystore. This matches vizor's architecture (AGENTS.md "Architecture"), and it keeps iOS cheap later.

| Component | Location | Owns | Talks to |
|---|---|---|---|
| zecSwap primitives | git deps `zecswap-core` (Zakura build), `zecswap-railgun`, `zecswap-tokens` at one pinned rev | `derive_user_keys`, share proofs, `JointAccount` (joint UFVK and UA), `spend_key` (`±(e+z)`), `sign_pczt` with `SweepIntent`, EIP-712 and terms hashing, the Railgun payout and refund note, Railgun keys and `0zk` address encoding, RFC 9578 blind-RSA tokens | used by the engine |
| Swap engine | `rust/src/wallet/private_usd/` | deployments, keys, forward and reverse state machines, index allocation, the store, and the maker, relayer, issuer and Ethereum clients | routed HTTP, the main DB, `joint.db`, `swaps.db` |
| FRB API | `rust/src/api/private_usd.rs` | thin, primitives-only wrappers and typed error codes (§8.2) | Dart |
| Joint-account ops | `rust/src/wallet/private_usd/joint.rs`, plus small changes in `rust/src/wallet/sync/{send,pczt}.rs` | import, scan, receipts, deposit create and broadcast, sweep with the combined key, Discard OVK, tx status (§8.1) | librustzcash |
| Routed HTTP | `rust/src/wallet/routed_http.rs` (new; generalized from the Enhance PIR transport, `rust/src/wallet/sync_engine/enhancement/transport/mod.rs`) | one HTTP executor that follows the Tor or direct route, fails closed and never retries (§8.5) | arti, or a `DirectRouteLease` socket |
| Railgun bridge | `rust/src/railgun_bridge.rs` (new; sibling of `rust/src/tor_update_relay.rs`) | a loopback SOCKS5 listener with a host allowlist, tunnelling over arti or a leased direct socket (§6.8) | WebView proxy |
| Railgun host | `android/app/src/main/kotlin/com/keplr/vizor/railgun/` | a hidden WebView, the asset loader, the request filter, the MessagePort envelope, proxy override, wipe (§6) | JS bundle; Dart over channels |
| Railgun JS bundle | built assets in `android/app/src/main/assets/railgun/`; source in `android/railgun-web/` | the Railgun engine: scan, balance, proving `transfer`/`unshield`/`prepareReverse`, POI | allowlisted hosts through the bridge |
| Attestation handler | `android/app/src/main/kotlin/com/keplr/vizor/PrivateUsdAttestationHandler.kt` | the Keystore EC P-256 attested key and its signature (§5.9) | Dart, then Rust |
| Dart feature | `lib/src/features/private_usd/{models,providers,services,screens/mobile,widgets/mobile}/` | the foreground engine loop, the Railgun engine wrapper, the balance repository and cache, send orchestration, screens, copy | FRB, channels |
| Lifecycle fence | `lib/src/providers/private_usd_lifecycle_provider.dart` | the drain for account deletion and reset (§8.4) | `account_provider.dart` |

### 3.2 Data flow

```
 flutter_secure_storage ─► accountProvider.getMnemonicBytesForAccount(uuid)  (null while locked)
                                     │ mnemonic_bytes, zeroed in `finally`
 ┌──────────────── Dart (foreground, unlocked only) ─────────────────────────────────────┐
 │ PrivateUsdEngineLoop ── FRB ──► api/private_usd.rs ──► wallet/private_usd/*           │
 │ RailgunEngine ── MethodChannel com.zcash.wallet/railgun ──► Kotlin RailgunWebViewHost │
 │      ▲  EventChannel com.zcash.wallet/railgun/events (scan, proof)  │ WebMessagePort  │
 │ AttestationService ── MethodChannel com.zcash.wallet/private_usd_attestation ─► Keystore
 └──────┼──────────────────────────────────────────────────────────────┼────────────────┘
        │                                                              ▼
        │                                         JS bundle (Railgun engine, hidden WebView)
        │                                                              │ HTTPS, proxied
        ▼                                                              ▼
 wallet/private_usd ──► routed_http ──┬─► Tor (arti, isolated)   railgun_bridge 127.0.0.1 SOCKS5
   maker / relayer / issuer / EVM RPC  └─► direct (DirectRouteLease) ◄──┘  (same route policy)
   │
   ├─► main DB: deposit = propose → create (stored) → persist bytes → broadcast
   ├─► joint.db: import joint UFVK at the exact birthday, scan, sweep with ±(e+z), Discard OVK
   └─► swaps.db: index counter, records, joint-account index, Railgun send log
```

**Forward, ZEC → USD**, in one paragraph (§5.6). Take the index, quote, and accept with the user's share. Read the escrow `Open` on Ethereum and derive the joint UA from the on-chain shares. Pay ZEC from the main account to the joint UA. When the escrow is `Ready` (or `Open` after `t0`), take a claim lock and reveal `z` through the relayer. USDC is shielded into the user's Railgun wallet as the pre-agreed payout note. If the maker refunds, it reveals `e`, and the wallet sweeps the joint ZEC home with `±(e+z)`.

**Reverse, USD → ZEC** (§5.7). Quote, accept, then import the joint account. The Railgun page proves a Relay Adapt transaction that funds the escrow (the first approval). The maker deposits ZEC to the joint UA. Once the deposit has 2 confirmations, the user signs `Ready` (the second approval). The maker claims the USDC by revealing `e`, and the wallet sweeps the ZEC home with `±(e+z)`.

**Send and withdraw** (§6.7). The page proves a Railgun `transfer` (to `0zk`) or `unshield` (to `0x`) that pays the relayer's fee note. The proved bytes are persisted in the Rust send log (§3.4) before Rust posts them to the relayer.

### 3.3 Keys

**Seed input.** Dart reads the stored secret with `ref.read(accountProvider.notifier).getMnemonicBytesForAccount(uuid)` (`lib/src/providers/account_provider.dart:2815`). It returns `null` while locked. The bytes are the stored value: either a raw phrase or the `{version, mnemonic, bip39Passphrase}` envelope (`lib/src/core/storage/app_secure_store.dart:336-355`; Dart view `lib/src/core/security/software_wallet_secret.dart:18-29`).

- Pass the bytes to Rust as `mnemonic_bytes: Vec<u8>`, and wrap them at once in `zeroize::Zeroizing` (pattern: `rust/src/api/gift_card_tracking.rs:6-23`, `rust/src/api/sync.rs:1656-1663`).
- Parse them with `keys::mnemonic_bytes_to_seed` (`rust/src/wallet/keys.rs:200`), which yields the 64-byte seed **with the passphrase** (D7).
- Zero the Dart `Uint8List` in `finally` (template: `lib/src/features/swap/providers/swap_deposit_sender.dart:156-183`).
- Rust cannot read secure storage, so every key-using API takes `mnemonic_bytes`.

**ZIP-32 index and seed check.** Read the index in Rust from the main wallet DB, as the signing paths do: `account.source().key_derivation().ok_or(..)?.account_index()` (`rust/src/wallet/sync/send.rs:1407-1411`).

- Require `key_derivation().seed_fingerprint()` to equal the fingerprint of the passed seed. This makes it impossible to derive Private USD keys from the wrong seed.
- `None` (no derivation metadata, or a hardware account) means "Private USD unavailable".
- The Dart mirror is `AccountInfo.zip32AccountIndex` (`int?`, `lib/src/providers/account_models.dart:38`), from Rust `AccountInfo.zip32_account_index` (`rust/src/api/wallet.rs:96-105`). Use it only for availability gating.

**Railgun chain.** This is zapp's chain, with D7 and D8 applied. zapp uses an empty passphrase and index 0.

| Step | What | zapp source |
|---|---|---|
| 1 | `seed` = the account's 64-byte BIP-39 seed, passphrase included (D7) | `ui/common/usecase/GetWalletSeedBytesUseCase.kt:12-16` |
| 2 | BIP-32 secp256k1 master from `seed` (HMAC-SHA512, key `"Bitcoin seed"`). Derive `m/83696968'/39'/0'/24'/{zip32Index}'`: all hardened, language 0 = English, 24 words, index = the ZIP-32 index (D8) | `za/evm-lib/.../hd/Bip85.kt:12-56` (`PURPOSE = 83_696_968` at `:48`), `Bip32.kt` |
| 3 | `entropy = HMAC-SHA512(key = "bip-entropy-from-k", data = node.privateKey)`, truncated to 32 bytes (`words/3*4`) | `Bip85.kt:35-46, 22-33` |
| 4 | Railgun mnemonic = the 24 English BIP-39 words of `entropy` | `ui/common/provider/RailgunMnemonicProvider.kt:76-83` |
| 5 | `railgunSeed` = the 64-byte BIP-39 seed of that mnemonic, empty passphrase | `RailgunMnemonicProvider.kt:86` |
| 6 | Railgun keys: an HMAC-SHA512 tree over `railgunSeed` keyed `"babyjubjub seed"`, hardened-only, raw left halves never reduced. Spending key at `m/44'/1984'/0'/0'/0'`, viewing key at `m/420'/1984'/0'/0'/0'`. Railgun wallet index **0** (`RAILGUN_WALLET = 0`) | `zs/crates/zecswap-railgun/src/keys.rs:13-14, 35-51, 142-149`; `zs/crates/zecswap-jni/src/ops.rs:15, 257-265` |
| 7 | `0zk` address: bech32m, hrp `0zk`, over 73 bytes: version `1`, MPK (32 B), the all-chains id `ff…ff` XOR `"railgun\0"`, the viewing public key (32 B) | `zecswap-railgun/src/address.rs:5-28` |

- **Implementation.** BIP-85 is not in zecSwap. Write it in Rust in `rust/src/wallet/private_usd/railgun_keys.rs` (~40 lines). Do not port `Bip32.kt`/`Bip85.kt`: they are KMP code over zapp's own BigInteger and platform HMAC.
  - Hardened CKD needs no point math: `I = HMAC-SHA512(chain, 0x00 ‖ k ‖ (i | 0x8000_0000) as u32 BE)`, `k' = (I_L + k) mod n`, `chain' = I_R`. Use `secp256k1::SecretKey::from_slice(k)?.add_tweak(&Scalar::from_be_bytes(I_L)?)` (`secp256k1 0.29`, `rust/Cargo.toml:26`). An `I_L ≥ n` or a zero result is an error (probability ~2⁻¹²⁷).
  - **`hmac` is not a direct dependency** (only transitive, `0.12.1` in `Cargo.lock`). Add `hmac = "0.12"`; `sha2 0.10` is direct (`:46`). Wrap `k`, the chain code and `I` in `Zeroizing`.
  - Steps 4–5 reuse vizor's helpers: `keys::mnemonic_from_entropy(entropy.to_vec())` (`rust/src/wallet/keys.rs:149`) and `keys::mnemonic_to_seed(&words)` (`:194`, empty passphrase, returns `SecretVec<u8>`).
  - Steps 6–7 are `zecswap_railgun::Keys::from_seed(railgun_seed, 0)` and `.address()`.
  - A Python reference (stdlib only) that reproduces every vector below was used to compute the vizor vector. It is not in the repo; the vectors are enough.
- **JS side.** The engine receives the step-4 words and derives the same keys itself: `createRailgunWallet(encryptionKey, mnemonic, creationBlocks, 0)` (`rl/web/src/wallet.js:96-112`).
- **Address check.** Refuse a Railgun session whose engine address differs from the Rust-derived one (`ui/common/repository/RailgunEngine.kt:84-95`).
- **The mnemonic's path to JS.** Dart bytes go to Rust `private_usd_railgun_mnemonic(...) -> String`, then over the MethodChannel to Kotlin, then over the WebMessagePort. It is briefly a Dart `String`, which cannot be zeroed; zapp has the same exposure. Accept it, and drop references after `openWallet`.
- **Never stored:** the words, `seed` and `railgunSeed`. Re-derive them per use and drop them.
- **Stored:** a random 32-byte engine encryption key per account in flutter_secure_storage (`vizor_railgun_encryption_key_{uuid}`). It encrypts the wallet in the WebView's IndexedDB (zapp: `railgun_wallet_encryption_key_v2`, `ui/common/provider/RailgunKeyProvider.kt:25-40`). Losing it costs a rescan, never funds: the page recreates a wallet whose stored copy no longer opens. As built (M3, D-20): an `AppSecureStore` app-managed secret, encrypted under the session password and rotated with it like the voting hotkeys, so the key and the page's storage together never open the Railgun wallet without the password.
- **Cached in memory:** derived public swap keys, payout notes and deposit addresses, per account and index (zapp: per seed fingerprint, `ua/AtomicSwapKeysImpl.kt:131-169`). Clear the cache on lock.

**Known-answer vectors.** Test against all of these.

- **BIP-85 spec.** The master is `xprv9s21ZrQH143K2LBWUUQRFXhucrQqBpKdRRxNVq2zBqsx8HVqFk2uYo8kmbaLLHRdqtQpUm98uKfu3vca1LqdGhUtyoFnCNkfmXRyPXLjbKb`.
  - 24-word entropy at index 0: `ae131e2312cdc61331542efe0d1077bac5ea803adf24b313a4f0e48e9c51f37f`
  - mnemonic: `puppy ocean match cereal symbol another shed magic wrap hammer bulb intact gadget divorce twin tonight reason outdoor destroy simple truth cigar social volcano`
  - Source: `za/evm-lib/src/commonTest/.../hd/Bip85Test.kt:19-38`, `ui-lib/src/test/.../provider/RailgunMnemonicTest.kt:14-23`.
- **zapp end to end.** The Zcash mnemonic is `abandon`×23 + `art`, with an empty passphrase and ZIP-32 index 0.
  - Railgun mnemonic: `water combine battle truck reopen scene dilemma art raise title fault fade employ inject defense bleak flavor document trash timber loud rate receive math`
  - `railgunSeed`: `a06f3b95b9ae6a46eded63da4807a1dbb4450d547f72ce309ae49f95fe0a07f9ad445c52a12d9057b66e86035ce002b2b8ff2deedefbd555f07e9ce94c76d952`
  - entropy (step 3): `f7c5bc4d749b67810f8866b13c5d4fa8e48ee80e58bc58a80f9df11843646ce4`
  - Source: `RailgunMnemonicTest.kt:26-40`.
- **The `0zk` address for that seed**, computed with `zecswap_railgun::Keys::from_seed(railgunSeed, 0).address()`:
  `0zk1qy4jkxxr9zsw46luz7hvp2j6rtqmjws6ttnrrr6uf485mg9xwpwu0rv7j6fe3z53llrc73lffkv84nudklsglyryy0703mu97e8sgn6sk8anxxypf8jjz382jz9`
- **Engine-checked key steps:** `zs/crates/zecswap-railgun/tests/engine-vectors.json` (engine 9.8.0, wallets 0 and 1 of seeds `5eb00bbd…e38e4` and `243c1266…5c3a`).
- **The vizor vector** (pins D7 and D8). Mnemonic `abandon`×23 + `art`, BIP-39 passphrase `vizor`, ZIP-32 index 1. Computed 2026-10-13 with an independent Python reference that reproduces both vectors above; the address is from `zecswap_railgun::Keys::from_seed(railgunSeed, 0).address()`.
  - entropy: `723d0672c95ccdd3d85c10388379d7e46ff863d2be0143db88e52c4db9ffcf0e`
  - Railgun mnemonic: `impulse trial original naive smoke try gesture link decade bridge invest silver zebra cradle enough scan duck sword deer flat swear zoo destroy space`
  - `railgunSeed`: `7d401812003ef389f2fa19ce6c6cae5371b46ec3b9200e3785b9d0a1aafcc046dc39f4a5c312681660a5041f815da650315be3e9374548fc33b8de89e7133f31`
  - `0zk`: `0zk1qy9fp87z33daqyvxaqveyjgrpx243jupm2sprzzply0qtp948rafnrv7j6fe3z53la94m9hv6a8k9t6g6lslxsmyua7rcaclem6j2ekcjxpvg5w0v68dzd7477k`
- The swap-key vectors (`derive_user_keys`, joint UA/UFVK, note, EIP-712, ids) are in §5.5.

**Swap keys.**

- `derive_user_keys(seed64, network, account = zip32Index, index)` (`zs/crates/zecswap-core/src/seed.rs:30-69`) gives the share `z`, the public share `Z`, the per-swap auth secp256k1 key (the swap's `user`, never funded) and the viewing keys `nk‖rivk` (`seed.rs:62-65`, `ViewingKeys::from_uniform`).
- The network comes from the pinned deployment. zapp always passes `account = 0` (`zecswap-jni/src/ops.rs:240-242`). Map vizor's `WalletNetwork::{Main, Test}` (`rust/src/wallet/network.rs:40-55`; strings `"main"`/`"test"`) to `zecswap_core::NetworkType::{Main, Test}`; coin type is 133 on Main and 1 otherwise (`seed.rs:36-39`), so a wrong mapping silently changes every key.
- `note_entropy = expand(4)[..32]` builds the swap's payout note (forward) or refund note (reverse) into the step-6 Railgun wallet: `railgun(railgun_seed).note(&keys.note_entropy)` (`ops.rs:245-249`). **The note is built in Rust, so the forward path never needs the Railgun page.** Only reverse funding (`prepareReverse`), the balance, and sends need it.
- The joint account is `JointAccount::derive(E, Z, viewing)`, which gives `{unified_address, ufvk}` (`ops.rs:190-197`, zecSwap `joint.rs:66-110`).
- The combined spend key is `joint.spend_key(e, z)`, which computes `±(e+z)` and checks `[ask]·G == ak` (`joint.rs:113-121`). Sign with `sign_pczt(pczt, &[key], intent)` (`ops.rs:236-238`).
- Mirror `zs/crates/zecswap-jni/src/ops.rs:160-265` when wiring these.

**Index allocation.** One counter per account, shared by both directions. It lives in `swaps.db` `swap_counter` (§3.4).

- `take_index` commits `next_index + 1` **before** returning (zapp `SwapIndices.take()`, `of/SwapIndices.kt:23-45`).
- It skips an index the chain shows in use, up to 16 in a row (`MAX_SKIPPED`). An index is in use if a forward swap with id `swap_id(maker, Z)` exists (latest-block read), or if `makerKeyUsed(swap_id(authAddress, Z))` is true (reverse). Both reads run per pinned contract (`of/SwapIndices.kt:31-45`). Sixteen used indices in a row throw `INDICES_IN_USE` (each skipped index stays consumed).
- This protects against reuse after a reinstall, or when the same seed runs in both zapp and vizor on ZIP-32 index 0.

### 3.4 Persistence

| Data | Location | Written by | Removed by |
|---|---|---|---|
| Index counter, swap records, active pointers, joint-account index, Railgun send log | `<support>/private_usd_<walletDbName>_<network>/swaps.db` | Rust | account delete (its rows); full reset (the directory) |
| Joint accounts (librustzcash DB) | `<support>/private_usd_<walletDbName>_<network>/joint.db` | Rust | each joint account is deleted once its sweep is confirmed; account delete; full reset |
| Privacy Pass token state (device-wide, per network) | `<support>/private_usd_tokens_<network>.json`, written atomically (temp file + rename) | Rust | full reset (X4) |
| Railgun engine encryption key | flutter_secure_storage `vizor_railgun_encryption_key_{uuid}` (random 32 B), an app-managed secret under the session password (D-20) | Dart | account delete; reset (`deleteAll`) |
| Balance cache | `AppSecureStore` `vizor_private_usd_balances_v1:<uuid>`: `{address, updatedAt ms, buckets}` | Dart | account delete; reset |
| Railgun engine data | WebView IndexedDB `railgun-<network>` and `railgun-artifacts`, origin `https://railgun.appassets.androidplatform.net` | JS | `deleteWallet` (account, E5); `WebStorage.deleteOrigin` (reset) |
| Kill-switch last value | `SharedPreferences` `vizor_private_usd_available_v1` | Dart | none needed |
| Attestation key | Android Keystore alias `vizor_privateusd_attest_<issuerName>` | Kotlin | never (X4); regenerated only on certificate expiry |

- **Paths.** `<support>` and `walletDbName` are what `getGiftCardTrackingDbPath` uses (`lib/src/core/storage/wallet_paths.dart:157-169`). Add `getPrivateUsdDirPath(network)` and `deletePrivateUsdDirectories()` next to `getGiftCardTrackingDbPath` and `deleteGiftCardTrackingDirectories` (`:171-182`). Dart passes the directory to Rust.
- **Why `swaps.db` is not inside `joint.db`.** `joint.db` is a librustzcash DB. It gets accounts imported and deleted, it runs migrations, and it may need a delete-and-rescan to recover from corruption. Its loss must never take the index counter or the in-flight records with it.
- **One `joint.db` per wallet**, shared by all of its accounts. That is safe because each joint account exists only between accept and its sweep. The scan covers from the minimum birthday of the live joint accounts.

**`swaps.db` schema** (WAL; `PRAGMA user_version` for migrations):

```sql
CREATE TABLE swap_counter(account_uuid TEXT PRIMARY KEY, next_index INTEGER NOT NULL);
CREATE TABLE swaps(
  account_uuid TEXT NOT NULL,
  direction    TEXT NOT NULL CHECK (direction IN ('forward','reverse')),
  swap_index   INTEGER NOT NULL,
  deployment   TEXT NOT NULL,      -- 'mainnet' | 'testnet'
  swap_id      TEXT,               -- 0x… once known
  phase        TEXT NOT NULL,
  finished     INTEGER NOT NULL,
  record_json  TEXT NOT NULL,      -- zapp's serialized record shape (§5.6, §5.7)
  updated_at   INTEGER NOT NULL,
  PRIMARY KEY(account_uuid, direction, swap_index));
CREATE TABLE active(account_uuid TEXT, direction TEXT, swap_index INTEGER,
  PRIMARY KEY(account_uuid, direction));
CREATE TABLE joint_accounts(account_uuid TEXT, direction TEXT, swap_index INTEGER,
  joint_uuid TEXT NOT NULL, ufvk TEXT NOT NULL, birthday INTEGER NOT NULL,
  PRIMARY KEY(account_uuid, direction, swap_index));
CREATE TABLE railgun_sends(       -- zapp PrivateUsdSendLog (`private_usd_sends_v2`), ≤100 per account
  account_uuid TEXT NOT NULL, send_id TEXT NOT NULL, created_at INTEGER NOT NULL,
  state TEXT NOT NULL, record_json TEXT NOT NULL,
  PRIMARY KEY(account_uuid, send_id));
```

- **Record bodies.** `record_json` uses zapp's serialized shapes (`AtomicSwapRecordSerializer.Stored`, `of/AtomicSwapModels.kt:209-292`; `ReverseSwapRecord`, `of/ReverseSwapModels.kt:120-147`), so the fixtures from zapp's `SwapRecordStorageTest` port directly.
- **Writes.** Each driver save is one SQLite transaction. A crash cannot tear a record. `keep` skips writes that change nothing.
- **Strict decoding.** An unknown or garbled record is an error, never a reset (zapp: an unreadable `atomicswap_state_v3` throws, `ua/AtomicSwapStoreImpl.kt:52-58, 91-103`). A stored record must re-encode to exactly the JSON it was read from (`models::decode_strict`).
- **History.** Keep at most 100 finished records per direction. Reverse `REFUNDED` records are kept forever (rescue may still be possible, `ua/ReverseSwapStoreImpl.kt:61-69`). A `QUOTED` reverse draft is never written to history.
- **Scoping.** Every row is keyed by `account_uuid`. The ZIP-32 index is not part of any key.
- **The deployment is pinned in each record** (zapp pins the whole deployment in a reverse record). The keyed RPC URL is never in a record.
- **Token state.** It is the zapp shape `SwapTokenState` (§5.9), with lenient decoding: an unreadable file starts empty. It holds blinding secrets (`pending`), so never log it.
- **`swaps.state` and "unfinished".** Forward: `phase` = zapp's stage name derived from the record while under way (`OPENING`, `DEPOSITING`, `CONFIRMING`, `CLAIMING`, `REFUNDING`), the outcome once ended (`PAID`, `REFUNDED`, `NOTHING_SENT`); `finished = end != null`. Reverse: `phase` = the `ReversePhase` name, `finished = phase ∈ {COMPLETE, REFUNDED, CANCELLED}`. `unfinished_count` counts forward `finished = 0` plus reverse `finished = 0 AND phase <> 'QUOTED'` (a QUOTED draft is not under way, `of/ReverseSwapModels.kt:151`). A new reverse quote replaces the account's QUOTED draft in `active`.
- **`railgun_sends.state`** is `unconfirmed` (proved and kept, `record_json` holds the relay request bytes and nullifiers) or `confirmed`. A send still being proved is **not** written (zapp keeps it in an in-memory `live` set and drops it on restart, `PrivateUsdSendLog.kt:146-149, 181-189`): nothing left the wallet. Trim to 100 `confirmed` rows per account; never trim `unconfirmed`.

### 3.5 Invariants

Each one exists because breaking it loses funds or privacy. Most are enforced in Rust. Tests must pin each one (§10).

1. **Never reuse a swap index.** Commit `next_index + 1` before any quote leaves the device, and skip indices in use on chain (§3.3). *Why:* claiming reveals `z`, so any other swap that shares that `z` becomes spendable by its maker.
2. **Save the record before accept.** Treat an accept timeout, transport failure or `5xx` as "maybe opened". *Why:* the maker may have opened an escrow that only this record can follow.
3. **Never pay a deposit twice.** Save `deposit = Started` before creating the transaction. Save the bytes (`Kept`) before the first broadcast. Rebuild only after the old transaction is **proven** expired (the wallet has fully scanned past its expiry height), and never once the maker holds a refund lock. On resume with `Started` and no bytes, search the main DB for a sent transaction to the joint UA (`findDeposit`) before building anything. The deposit must be exactly one transaction, with a total ≤ the approved `maxTotalZat`. *Why:* a second deposit is unrecoverable once the first lands.
4. **Derive the deposit address from the on-chain shares** in the confirmed `getSwap` terms, never from the API alone. *Why:* a malicious API could otherwise substitute an address it controls.
5. **Reveal `z` only under a fresh lock.** That means a held, confirmed claim lock (forward) or refund lock (reverse) with **more than 300 s** left, re-read from a fresh confirmed head immediately before sending. Never reveal on a relayer answer or an old observation. *Why:* a reveal that lands after the lock lapses lets the maker take both sides.
6. **Only a confirmed read authorizes anything.** Only `confirmedSwap` (block `head − confirmations + 1`) authorizes a deposit, a reveal or completion. Refuse lock reasoning when the head's timestamp trails the device clock by more than 180 s (`freshHead`). *Why:* a lagging node can show stale stages.
7. **Never prove a second reverse funding because a response was lost.** Resend the same bytes only while the node does not know the hash, `now < fundingDeadline`, and the user has not cancelled. `ready` is never re-signed after a restart, only resent. *Why:* a second funding pays twice.
8. **Save every signed payout, refund payout, refund lock and ready before sending it.** (A forward claim lock is not saved: losing one reveals nothing, D-36.) A refused payout is re-signed only when the relayer's fee rose; otherwise a payout is re-signed only when the fee to pay changed, the offer's within its window or else the relayer's now (reference §5.6 step 8). Every relayer fee must be `< amount` and **≤ 2 USDC** (D11, X6).
9. **Broadcast before store** for every externally signed PCZT: the joint sweeps reuse `store_and_broadcast_pczts_with_compact_signatures_for_proposal` (`rust/src/wallet/sync/pczt.rs:1645`). *Why:* AGENTS.md hardware invariant 1. A rejected broadcast must not leave notes marked spent.
10. **`PROPOSAL_STORE` is consume-on-entry.** Discard on every non-consuming exit, for the deposit and sweep proposals alike (AGENTS.md hardware invariant 4).
11. **Discard OVK on joint sweeps (D12). Sender OVK on the deposit**, so the user's own OVK still recovers it.
12. **Import joint accounts at the exact birthday** (`make_birthday(network, Some(h))`, `rust/src/wallet/keys.rs:297`), never the rounded mainnet restore birthday. *Why:* rounding rescans up to 10,000 blocks inside a swap's deadline window. The exact birthday reveals swap timing to lightwalletd through `GetTreeState(h−1)`; Gift Card observers already accept this.
13. **Fail closed on Tor.** All engine HTTP goes through `routed_http`, with no clearnet fallback. Railgun page traffic goes only through the bridge (D4), or the page does not run while Tor is on. Never persist or log the keyed RPC URL, the relayer ticket or token secrets.
14. **Foreground and unlocked only (D9).** No step starts while `requiresUnlock` or in the background. Background cancels the Rust step and stops polling, but leaves the Railgun page open: closing it would restart a first sync from zero (§6.3), and the 10-minute idle timer or the lock closes it. Lock cancels the Rust step, closes the page and drops Dart-held secrets.
15. **Guard account deletion and reset.** While an account has an unfinished conversion, show a warning before deleting it or resetting, with the number of unfinished conversions (copy `delete_unfinished_*`, `reset_unfinished_body`, §9.6). Delete only after the user explicitly confirms (owner decision, 2026-10-13: warn and allow, never block, so a user who must reset is never trapped). Drain `privateUsdLifecycle` before deleting. Clean up only after the Rust delete succeeds. *Why:* the funds sit in a joint account or escrow that only that seed and index can recover.
16. **One conversion at a time per account**, in either direction (zapp `acceptanceLock`). **One outgoing Railgun payment at a time per wallet**, conversions included, across restarts (the spend guard, §6.7).
17. **The chain is the only evidence.** The maker's status API never is.
18. **Never quote per keystroke** (X10).
19. **Check seed and address.** Derive keys only after the seed-fingerprint check (§3.3). Refuse a Railgun session whose address differs from Rust's.

### 3.6 Rust skeleton

Signature level only. The milestone that creates each file is in brackets. The FRB surface is in §8.2; the Kotlin↔Dart channels are in §6.2.

```text
rust/src/
├── lib.rs                     + `mod railgun_bridge;` [M3]
├── railgun_bridge.rs          [M3] loopback SOCKS5 → arti or leased direct socket (§6.8)
├── api/mod.rs                 + `pub mod private_usd;` [M1]
├── api/private_usd.rs         [M1+] thin FRB wrappers, ApiPrivateUsdError (§8.2)
└── wallet/
    ├── mod.rs                 + `pub(crate) mod private_usd; pub(crate) mod routed_http;` [M1]
    ├── routed_http.rs         [M1] routed_request, generalized from sync_engine/enhancement/transport (§8.5)
    ├── keys.rs                make `make_birthday` (:297) `pub(crate)` [M2]
    ├── sync/{send,pczt,mod}.rs  SendPurpose::JointSweep, StoredProposal.purpose, deposit split [M2] (§8.1)
    └── private_usd/
        ├── mod.rs             PrivateUsdNetwork, PrivateUsdError{code,message}, OPERATIONS mutex
        ├── deployment.rs      Deployment consts per network (§7.1) + driver consts (§7.2)
        ├── railgun_keys.rs    BIP-85 → Railgun mnemonic → railgunSeed → zecswap_railgun::Keys (§3.3)
        ├── keys.rs            SwapKeyContext (seed, ZIP-32 index, fingerprint check)
        ├── terms.rs           swap_id, reverse_swap_id, forward/reverse Terms, Domain (§5.5)
        ├── models.rs          ForwardRecord, ReverseRecord, SwapQuote… (serde, zapp's JSON shape)
        ├── store.rs           SwapStore over swaps.db (§3.4)
        ├── indices.rs         take_index with on-chain skipping
        ├── transport.rs       HttpTransport trait + RoutedTransport (over routed_http); swap-service JSON exchange, SwapHttpError
        ├── evm_rpc.rs         ChainReader trait + EvmRpc (§5.4, §8.5)
        ├── maker_client.rs    §5.2
        ├── relayer_client.rs  §5.3, §6.7
        ├── tokens.rs          [M4] token state, pay/settle, two-phase issuance (§5.9)
        ├── joint.rs           [M2] joint.db ops (§8.1)
        ├── engine.rs          [M5] per-account driver locks, the forward offer cache, the op_id cancel + activity registry, the Clock and TokenSource seams, problem mapping, account deletion (§5.10)
        ├── forward.rs         [M5] the §5.6 driver and §5.8 forward refund over the seams; WalletZcash (the M2 ops); ForwardCall
        │                      reverse.rs, funding_calls.rs [M6]   sends.rs [M7] (send log over swaps.db)
        └── tests/vectors.json the §3.3 and §5.5 vectors
```

```rust
// mod.rs
pub(crate) enum PrivateUsdNetwork { Mainnet, Testnet }
impl PrivateUsdNetwork {
    pub fn from_wallet(n: WalletNetwork) -> Option<Self>;   // Regtest → None
    pub fn zcash(self) -> zecswap_core::NetworkType;        // Main | Test
    pub fn record_name(self) -> &'static str;               // "mainnet" | "testnet" (swaps.db, file names)
    pub fn railgun_name(self) -> &'static str;              // "mainnet" | "sepolia" (page `start.network`)
}
pub(crate) struct PrivateUsdError { pub code: ErrorCode, pub message: String } // → ApiPrivateUsdError
// ErrorCode = the §8.2 codes + internal WrongDeployment, ChainUnreadable, IndicesInUse, AmountUnquotable
pub(crate) static OPERATIONS: std::sync::Mutex<()>;        // one store/joint.db writer at a time

// deployment.rs
pub(crate) struct Deployment { /* every §7.1 row as &'static str / u64 / [u8;20] */ }
pub(crate) fn deployment(n: PrivateUsdNetwork) -> &'static Deployment;
pub(crate) const MAX_RELAYER_FEE: u128 = 2_000_000;  // + the §7.2 constants

// railgun_keys.rs
pub(crate) fn bip85_entropy(seed64: &[u8], index: u32) -> Result<Zeroizing<[u8; 32]>, String>;
pub(crate) fn railgun_mnemonic(seed64: &[u8], zip32_index: u32) -> Result<Zeroizing<String>, String>;
pub(crate) fn railgun_keys(seed64: &[u8], zip32_index: u32) -> Result<zecswap_railgun::Keys, String>;
pub(crate) fn is_valid_railgun_address(s: &str) -> bool; // bech32m, hrp "0zk", 73 bytes, byte 0 == 1

// keys.rs
pub(crate) struct SwapKeyContext { /* network, zip32_index, Zeroizing seed */ }
impl SwapKeyContext {
    pub fn open(main_db: &str, n: WalletNetwork, account_uuid: &str, mnemonic_bytes: &[u8]) -> Result<Self, PrivateUsdError>;
    pub fn user_keys(&self, index: u32) -> Result<zecswap_core::UserSwapKeys, PrivateUsdError>;
    pub fn auth_address(&self, index: u32) -> Result<[u8; 20], PrivateUsdError>;
    pub fn note(&self, index: u32) -> Result<zecswap_railgun::ShieldNote, PrivateUsdError>;
    pub fn joint(&self, index: u32, maker: &zecswap_core::PublicShare) -> Result<zecswap_core::JointAccount, PrivateUsdError>;
    pub fn railgun_mnemonic(&self) -> Result<Zeroizing<String>, PrivateUsdError>;
    pub fn railgun_address(&self) -> Result<String, PrivateUsdError>;
    // M5: verifies the maker's proof, proves Z with rand 0.10's UnwrapErr(SysRng) (`rand_0_10`)
    pub fn acceptance(&self, index: u32, context: SwapContext, maker: &PublicShare, maker_proof: &[u8; 64]) -> Result<SwapAcceptance, PrivateUsdError>;
    pub fn seed(&self) -> SecretVec<u8>;   // M5: a copy for the deposit's creation; zeroized on drop
}

// store.rs (rusqlite 0.37 is already a dependency; open with WAL + busy_timeout)
pub(crate) struct SwapStore { conn: rusqlite::Connection }
impl SwapStore {
    pub fn open(dir: &Path) -> Result<Self, PrivateUsdError>;  // creates swaps.db, runs user_version migrations
    pub fn take_index(&mut self, account: &str) -> Result<u32, PrivateUsdError>;
    pub fn save(&mut self, account: &str, rec: &StoredRecord) -> Result<bool /*changed*/, PrivateUsdError>;
    pub fn active(&self, account: &str, dir: Direction) -> Result<Option<StoredRecord>, PrivateUsdError>;
    pub fn history(&self, account: &str, dir: Direction) -> Result<Vec<StoredRecord>, PrivateUsdError>;
    pub fn unfinished_count(&self, account: &str) -> Result<u32, PrivateUsdError>;
    pub fn delete_account(&mut self, account: &str) -> Result<(), PrivateUsdError>;
    // + update (in place), find, accounts_with_unfinished, joint_accounts and railgun_sends accessors
}

// transport.rs / evm_rpc.rs: native `async fn` in traits (Rust ≥ 1.75), used through generics, never `dyn`
pub(crate) trait HttpTransport { async fn send(&self, req: RoutedRequest) -> Result<RoutedResponse, RoutedError>; }
pub(crate) trait ChainReader {   // errors are PrivateUsdError (D-7)
    async fn chain_id(&self) -> Result<u64>;
    async fn head(&self) -> Result<Head /*{number, timestamp}*/>;
    async fn swap(&self, id: &[u8; 32]) -> Result<Option<SwapState>>;                           // latest
    async fn confirmed_swap(&self, id: &[u8; 32], terms: &Terms) -> Result<ConfirmedSwap /*{head, swap}*/>;
    async fn lock_duration(&self) -> Result<u64>;
    async fn maker_key_used(&self, key: &[u8; 32]) -> Result<bool>;
    async fn reverse_state(&self, id: &[u8; 32], terms: &Terms) -> Result<ReverseChainState>;   // refund note, funding block, getSwap at one confirmed block
    async fn vault_balance(&self, id: &[u8; 32]) -> Result<u128>;
    async fn rescue_nonce(&self, id: &[u8; 32]) -> Result<u64>;
    async fn railgun_accepts(&self) -> Result<bool>;                                            // tokenBlocklist; revert → false
    async fn confirmed_payout(&self, id: &[u8; 32], since: u64) -> Result<Option<PaidOut>>;
    async fn transaction_status(&self, tx: &[u8; 32], confirmations: u32) -> Result<TransactionStatus>; // Unknown | Pending | Confirmed | Reverted
}
pub(crate) async fn take_index<C: ChainReader>(store: &mut SwapStore, chains: &[(&C, [u8; 20])], keys: &SwapKeyContext, account: &str) -> Result<u32, PrivateUsdError>;
```

- **Runtime.** vizor's FRB functions are mostly plain `pub fn` that build a runtime and `block_on` (`api/sync.rs:429`). Never call such a wrapper from inside async code: a nested `Runtime::new().block_on` panics. Call the async engine function instead (for example `sync_engine::run_payment_link_claim_sync`, not `api::sync::run_payment_link_claim_sync`).
- **Locks.** Hold `private_usd::OPERATIONS` around `swaps.db` and `joint.db` writes, like `wallet::gift_card_tracking::OPERATIONS` (`rust/src/wallet/gift_card_tracking.rs:8`). librustzcash writes to `joint.db` also take the process-global `with_wallet_db_write_lock` (`rust/src/wallet/db.rs:220`). Never hold `OPERATIONS` across network I/O.

## 4. Milestones

Each milestone has the same parts:

- **Goal**
- **Needs:** the §2 rows it waits on
- **Inputs:** the sections and sources to load, and nothing else
- **Tasks:** numbered as in the checklist
- **Done when:** the completion condition
- **Traps:** only what you would otherwise discover at runtime

Every milestone also follows these rules:

- Gate everything user-visible behind `VIZOR_PRIVATE_USD_ENABLED` (default `false`, §7.3).
- Rust tests go in each file's `#[cfg(test)] mod tests`, or in `<module>/tests.rs`; public-API tests go in `rust/tests/`.
- Mobile UI tests start with `@Tags(['mobile'])`. Untagged tests compare against token constants.

### M0. Spikes: done (2026-10-13)

- **Crates (M0.1).**
  - `zecswap-core` (the Zakura build, through the local `[patch]`) and `zecswap-railgun` build in vizor's graph, with one `zakura-orchard`, one `zakura-pczt` and no upstream Zcash crates.
  - zecSwap's 24 tests pass on the Zakura build. The debug APK builds on all four ABIs, and the Rust `.so` grows by 0.4–0.5 MB while unused.
  - **`zecswap-tokens` does not resolve.** Its `blind-rsa-signatures ^0.18` needs `digest ^0.11.3`, while vizor's `zakura-client-backend` pins `digest =0.11.0-pre.9` (through `bip32 =0.6.0-pre.1` and `hmac =0.13.0-pre.4`). No `blind-rsa-signatures` 0.16+ accepts that pre-release. That leads to N1. Only M4 needs the crate.
- **Ironwood deposit (M0.2).** A payment to an Orchard-only UA after NU6.3 lands in the Ironwood bundle, and `sent_notes` records it (`output_pool` 4, `to_address` = the UA). Proof: the wallet-libraries test `orchard_payment_routes_to_ironwood_and_builds`, and `rust/src/wallet/sync/send/orchard_receiver_tests.rs`. A testnet confirmation is pending funds (E8), and M2's regtest test covers it for good.
- **Tor bridge (M0.3, D4): go.** It ran on a Galaxy A35 against Sepolia.
  - The page syncs over Tor: the first sync took 101 s and 136 s (96 s direct).
  - Zero direct sockets in 26 samples.
  - A route flip and a Tor failure both fail closed.
  - Chromium keeps pooled sockets after the page closes (U19), so always restart the bridge on a route change.
  - Screen-off freezes the app within about 60 s (U21).
  - The transfer proof is pending N2.

### M1. Rust foundations

**Goal.** Every Rust building block that does not touch Zcash wallet state. Nothing user-visible.

**Needs.** Nothing to build. E1 to merge.

**Inputs.**
- This file: §3.3–§3.6.
- Reference: §5.2–§5.5, §7, §8.2, §8.5.
- Sources:
  - `rust/src/api/gift_card_tracking.rs:1-40`
  - `rust/src/api/sync.rs:60-122` (the error pattern) and `:429, :857` (runtime, `catch`)
  - `rust/src/wallet/voting/route.rs`
  - `rust/src/network_privacy.rs:160-301, 600-722`
  - `rust/src/wallet/keys.rs:120-230`
  - `rust/src/wallet/sync_engine/enhancement/transport/mod.rs:100-312` (the routed-HTTP template)
- Port from (only the file a task names): `of/SwapIndices.kt`, `SwapTerms.kt`, `SwapChecks.kt`, `AtomicSwapChain.kt`, `SwapWire.kt`, `SwapClients.kt`, `AtomicSwapModels.kt` and `ReverseSwapModels.kt`.

**Tasks** (all under `rust/src/wallet/private_usd/` unless stated):

1. `rust/Cargo.toml`: `zecswap-core` and `zecswap-railgun` (rev `d69e3fb…`, plus the local `[patch]` until E1), `hmac = "0.12"`, `sha3 = "0.10"`, `bech32 = "0.11"`. Not `zecswap-tokens` (N1).
2. `mod.rs`:
   - the module tree (§3.6)
   - `PrivateUsdNetwork::{Mainnet, Testnet}` from `WalletNetwork`; regtest gives `None`
   - register `pub(crate) mod private_usd; pub(crate) mod routed_http;` in `rust/src/wallet/mod.rs`
3. `deployment.rs`: every §7.1 pin and §7.2 constant, including `MAX_RELAYER_FEE = 2_000_000`. Keep the token keys as strings; their parse test waits for N1.
4. `railgun_keys.rs`: BIP-85 and the Railgun chain (§3.3).
5. `keys.rs`:
   - `SwapKeyContext::open(main_db, network, account_uuid, mnemonic_bytes)` parses the seed, reads the ZIP-32 index and checks the seed fingerprint (§3.3)
   - `user_keys`, `auth_address`, `note` and `joint`, mirroring `zs/crates/zecswap-jni/src/ops.rs:160-265`
6. `models.rs`: the forward and reverse records in zapp's JSON shape (§5.6, §5.7).
7. `terms.rs`:
   - forward terms, and swapped-role reverse terms (`zecswap_core::ReverseOpen::terms()`)
   - `terms_hash` and the EIP-712 digests from `zecswap-core`
   - `swap_id` and `reverse_swap_id` written with Keccak (§5.5 formulas; they live in `zecswap-chain`, which vizor does not use)
8. `store.rs`:
   - the `swaps.db` schema and `user_version` migrations (§3.4)
   - `take_index` (one transaction)
   - `save` (one transaction, skip-if-unchanged)
   - `active` and `history` with the history limits
   - strict decoding
   - `railgun_sends`
9. `indices.rs`: take an index, skipping up to 16 used on chain, through a `ChainReader`.
10. `rust/src/wallet/routed_http.rs` (§8.5), generalized from the Enhance PIR transport:
    - arbitrary request headers
    - returned response headers (`WWW-Authenticate`, `Retry-After`)
    - non-2xx bodies (the maker's `{code, error}`)
    - a `phase` on errors, classified like `classify_tor_error`
    - a pooled direct client per `RoutedHttp` instance (make one per operation; PIR needs pooling)
    - a per-request route re-check, fail closed, never retry

    Reuse `DirectRouteConnector` (`rust/src/wallet/sync_engine/lwd.rs:318-360`, made `pub(crate)`).
10b. Separate change; it may slip to M8. Move the PIR transport and voting's `VizorRoute` onto `routed_http` with no change in behaviour:
    - `VizorRoute` keeps `RouteHttp`, the `classify_tor_error` semantics and the `on_dispatch` timing
    - PIR keeps pooling and its per-request re-check
    - gate it on the existing voting and PIR tests, and update the routing table in `rust/src/wallet/voting/README.md`
11. `evm_rpc.rs`: every read in §5.4, behind `ChainReader`.
12. `maker_client.rs` and `relayer_client.rs`: §5.2 and §5.3, behind `HttpTransport`. That trait is the seam for M5's and M6's fakes.
13. `rust/src/api/private_usd.rs`, plus `pub mod private_usd;` in `rust/src/api/mod.rs`:
    - `ApiPrivateUsdError` and its codes, `ApiDeployment`, and the five M1 calls with the §8.2 signatures
    - regenerate the bindings; `lib/src/rust/api/private_usd.dart` must exist

**Done when** `cd rust && cargo test private_usd` passes with:

- every §3.3 vector, including the vizor passphrase-and-index vector
- every §5.5 vector (EIP-712 digests and signatures, ids, joint UA and UFVK, notes, terms hashes), pinned in `tests/vectors.json`
- `is_valid_railgun_address`: true for every `0zk` in this plan; false for a one-character change, a `0x` address and a bech32 (not bech32m) checksum
- `getSwap` decoding: exactly 192 bytes; a revert reads as closed; a `chainId` mismatch is a wrong deployment
- the store: a crash between saves leaves the last whole record; strict decoding; the counter never goes backwards across reopen
- the 16-index skip cap
- routed HTTP fails closed while `Bootstrapping` or failed, with the error phase `BeforeDispatch` (under `lock_route_policy()`)
- maker and relayer error classification against a local test server

`fvm flutter analyze` must also be clean.

**Traps.**

- **FRB here has no `freezed`.** A Rust enum with data generates a `@freezed` class and breaks the Dart build. Use fieldless enums plus flat structs with `Option` fields.
- **FRB maps `u64` to Dart `BigInt`.** Use `u32` for indices, counts and milliseconds, and `String` for u128 amounts.
- **Network strings are `"main"`, `"test"` and `"regtest"`** (`WalletNetwork::from_str`). `private_usd_deployment("main")` must work.
- **Coin type follows the network** in `derive_user_keys` (133 or 1), so the §5.5 vectors need `NetworkType::Test`.
- **Keccak, not SHA3.** Use `sha3::Keccak256`. Check: `keccak("hashTerms((address,address,uint128,uint256[2],uint256[2],address,uint64,uint64,bytes32))")[..4] == 0x2f25f5c9`.
- **Addresses are `[u8; 20]` in Rust.** Parse `0x` hex case-insensitively and emit lowercase on the wire; the §7.1 pins are EIP-55 mixed case.
- **`getSwap` words are big-endian 32-byte words.**
  - `stage` is word 1's last byte.
  - The lock times must fit `u64` (the high 24 bytes are zero); anything else is `WRONG_DEPLOYMENT`.
  - `secret` (word 5) is what `SecretShare::from_be_bytes` takes.
- **`swaps.db` is a plain `rusqlite::Connection`** (WAL, `busy_timeout`, `user_version`), opened per call. Never use `zcash_client_sqlite`'s helpers on it.
- **Runtimes.** Wrap every FRB body in `catch` and build its runtime inside it. Never call such a wrapper from async code: a nested runtime panics.
- **Never log secrets:** the mnemonic, the seed, `z`, the relayer ticket, the token `pending` state or the keyed RPC URL. Give secret-holding structs a redacting `Debug`.

### M2. Zcash joint-account operations: done (2026-10-13)

**Goal.** Everything the swaps need from librustzcash.

**Needs.** The owner's go-ahead for the Ironwood regtest run (M2.7b); given, and the run passed on 2026-10-13.

**Inputs.**
- §3.5 (items 3 and 9–12); §8.1; AGENTS.md "Hardware Wallet (Keystone) Send Flow", invariants 1–4.
- Sources:
  - `rust/src/wallet/sync/send.rs:120-150, 780-1040, 1400-1420, 1516-1680, 4580-4700, 6750-6800`
  - `sync/mod.rs:570-610`
  - `pczt.rs:95-120, 495-600, 890-900, 1640-1760, 2040-2070, 2150-2180, 2360-2400, 4060-4160`
  - `keys.rs:250-300, 505-560, 1030-1060`
  - `sync_engine/mod.rs:2800-3000`
  - `rust/tests/ironwood_regtest_gift_card_claim.rs`
- Port from: `ua/JointAccounts.kt`, `ua/SwapZcashTransactions.kt:98-141` and `zs/crates/zecswap-chain/src/zcash/wallet.rs:305-320, 451-470`.

**Tasks** (details in §8.1; the signatures are as built, deviations D-8 to D-14):

1. `rust/src/wallet/private_usd/joint.rs`:
   - `register_joint_account(joint_db, network, ufvk, birthday: u32) -> joint_uuid`. Import it as `AccountPurpose::Spending { derivation: None }`, never `ViewOnly`, which does not track spends. The shape follows `register_gift_card_observer` (`keys.rs:512`). `make_birthday` (`keys.rs:297`) is now `pub(crate)`.
   - `async sync_joint_db(joint_db, lwd, network, cancel)`, through the async engine function `sync_engine::run_payment_link_claim_sync` (`sync_engine/mod.rs:2808`), not its FRB wrapper. It returns at once while every joint account is born above the tip (U6), and runs one scan per `joint.db` at a time.
   - `joint_receipts(joint_db, network, joint_uuid, confirmations) -> JointReceipts`: received and confirmed amounts and notes, spendable and pending under the sweep policy, and the fully scanned height.
   - `delete_joint_account(joint_db, network, joint_uuid)`, through `keys::delete_account` (`:1033`).
2. Discard OVK (§8.1.3):
   - `SendPurpose::JointSweep` in `send.rs`
   - `StoredProposal.purpose` in `sync/mod.rs`
   - a purpose-based refusal in `pczt.rs`, passing the stored OVK policy to `zcb_create_pczt`
3. `propose_joint_sweep(joint_db, network, joint_uuid, flow_id, home_ua, max_fee) -> SwapProposal { proposal_id, needs_sapling_params, fee_zatoshi, amount_zatoshi }` in `send.rs`. The lock-and-store block of `propose_send_with_request` is now `lock_and_store_proposal`, which takes a built proposal.
4. `async sweep_joint(joint_db, lwd, network, joint_uuid, flow_id, home_ua, max_fee, key: &SpendKey) -> JointSweep` in `joint.rs`: propose, create the PCZT, sign with `±(e+z)`, extract the compact signatures, prove, then broadcast and store. It returns `transaction: CreatedTransaction { txid, raw, expiry_height }`, the amount and fee, and how the broadcast ended (`Accepted`, `Unknown`, `StorageFailed`).
5. Split the deposit in `send.rs`:
   - `propose_swap_deposit(main_db, network, account_uuid, flow_id, joint_ua, deposit_zat, max_total_zat) -> SwapProposal`: one step only, and a total no higher than `max_total_zat`
   - `async create_stored_proposal_transactions(main_db, lwd, proposal_id, flow_id, seed, spend_params?, output_params?) -> Vec<CreatedTransaction>`: signs and stores, the create half of `execute_stored_proposal`
   - `async broadcast_raw(lwd, raw)`: exposes `broadcast_raw_transaction_isolated`

   `execute_proposal`'s behaviour does not change: it runs the same create half, then the same broadcast.
6. `find_deposit(main_db, network, account_uuid, joint_ua) -> Option<CreatedTransaction>` and `swap_tx_status(db, network, txid, expiry_height) -> SwapTxStatus` in `joint.rs` (§8.1.2).
7. An ignored Ironwood regtest test, in-crate at `rust/src/wallet/private_usd/tests/ironwood_regtest.rs`, because it needs `pub(crate)` functions. Copy about 60 lines of the gift-card test's harness and use the §5.5 seed and maker root with `NetworkType::Regtest`. It does the following:
   1. Derive the joint key.
   2. Deposit through the split, and assert the output is Ironwood.
   3. Import at the exact birthday, including a birthday ≥ the tip.
   4. Scan to 2 confirmations.
   5. Sweep home with Discard OVK.
   6. Assert broadcast-before-store, and that the sweep's `out_ciphertext` does not decrypt under the joint OVK.

**Done when** these unit tests pass:

- a `JointSweep` PCZT's outputs fail OVK recovery under the joint OVK
- `PaymentLinkClaim` is still refused for a PCZT
- a sweep with more than one step, or a fee over the maximum, is an error and releases the lock
- `swap_tx_status` covers `Mined`, `Unmined`, `Expired` (only once fully scanned past expiry) and `Unknown`
- the deposit split rejects more than one step and a total over the maximum
- `find_deposit` finds a stored but unbroadcast deposit
- the existing gift-card PCZT tests still pass

The unit tests are in `rust/src/wallet/private_usd/tests/joint.rs`; the `PaymentLinkClaim` refusal stays in `pczt.rs`. No joint-account proposal can take two steps (a TEX recipient needs a ZIP 320 ephemeral transparent address, which an Orchard-only joint account cannot derive), so the deposit and the sweep share one one-transaction check, and its test refuses a deposit to a TEX address (D-12).

Then, with the owner's go-ahead, run the regtest test once (M2.7b; done 2026-10-13, passed): `cd rust && cargo test --lib private_usd::tests::ironwood_regtest -- --ignored --nocapture --test-threads=1`. It resets and starts the Docker stack itself. It also settles U4–U9.

**Traps.**

- **`StoredProposal` is built in exactly two places,** `send.rs:950` and the test at `pczt.rs:4137`; adding `purpose` touches both. As built, the first is `lock_and_store_proposal` in `send.rs`.
- **Signatures you will call** (as of `4a859bee0`):
  - `create_pczt_from_proposal(db_path, lwd_url, network, proposal_id, send_flow_id) -> Result<Vec<u8>, String>` (`pczt.rs:502`)
  - `add_proofs_to_pczt(pczt, spend_params?, output_params?)` (`:895`)
  - `extract_required_compact_sigs_from_signed_pczt(base, signed) -> Vec<SpendAuthSignature>` (`:2367`)
  - `store_and_broadcast_pczts_with_compact_signatures_for_proposal(db_path, lwd_url, network, proposal_id, send_flow_id, proofs, signatures, spend_params?, output_params?)` (`:1645`)
  - `broadcast_raw_transaction_isolated(lwd_url, raw)` (`send.rs:6762`)
  - `delete_account(db_path, network, account_uuid)` (`keys.rs:1033`)
  - `propose_send_max_transfer(..., MaxSpendMode::Everything, ...)` (`wl/.../data_api/wallet.rs:930`)
- **Sign the unredacted base PCZT, then diff.** `zecswap_core::sign_pczt` needs the full note data to check the `SweepIntent` (`SweepIntent::from_address(home_ua, network, amount, fee)`).
- **`TxId` bytes are in internal (little-endian) order;** displayed hex and lightwalletd JSON are reversed. Store and compare bytes.
- **`expiry_height == 0` means no expiry,** so it is never `Expired`.
- **The regtest test needs `simple_api::configure_regtest_ironwood_activation_height` before any wallet call.** In test builds that height is per thread (`wallet/network.rs`), so the in-crate test keeps every wallet call on its own thread: a current-thread runtime, and no FRB wrapper that builds a runtime of its own around consensus-dependent work.

### M3. Railgun host, Tor bridge, availability and the read-only balance

**Goal.** A software account on testnet or mainnet sees its private USD balance on home and on `/private-usd`, with the receive address. Nothing spends yet.

**Needs.** E2 and E4 to merge (build locally until then); E5 and E10 are optional.

**Inputs.**
- Reference: §6, §7.3, §8.2 (the bridge and M1 calls), §8.3, §8.4, §8.5 "Route changes at runtime", §8.6, §8.7, §9.4 S1–S2 and §9.7.
- **Start from the spike branch** `spike/private-usd-m0`: the bridge, the Kotlin host, `RailgunHostHandler` and the `org.json` protocol, all compiled and run on device.
- Sources:
  - `MainActivity.kt:97-242, 329-332`
  - `android/app/build.gradle.kts:15-40, 189-203`
  - `lib/src/core/config/swap_feature_config.dart`
  - `lib/src/core/storage/wallet_paths.dart:150-185`
  - `lib/src/features/payment_links/providers/gift_card_tracking_provider.dart:76-131`
  - `mobile_home_screen.dart:1027-1330, 1733-2200`
- Port from: `rl/.../RailgunModels.kt`, `RailgunWallet.kt` and `RailgunReverseFunding.kt` (Dart models); `ui/common/repository/RailgunEngine.kt`; `ui/common/privateusd/PrivateUsdBalanceRepository.kt` and `PrivateUsdBalanceCache.kt`.

**Tasks.**

1. **Bundle.** Run the §8.7 commands 1, 2 and 5, plus the `build.mjs` edit; ship `railgun.js.LEGAL.txt` and the GPL-3.0 text (X12). With E5: `deleteWallet`, X2's identifiers, and a rebuild.
2. **Kotlin host.** Bring over the spike's `railgun/` package and `RailgunHostHandler` (§6.2 contract). Add a process singleton built with `applicationContext`, and close the page in `onDestroy` only when `isFinishing`.
3. **Gradle and manifest.**
   - `androidx.webkit:webkit:1.17.1`, `kotlinx-coroutines-android:1.10.2` and `kotlin-test-junit:2.2.20`
   - the backup exclusion `domain="root" path="app_webview"` in `data_extraction_rules.xml` (path confirmed, U12)
4. **Rust bridge.** Bring over `rust/src/railgun_bridge.rs` and the tokio I/O for `DirectRouteIo`.
   - Take the allowlist from `deployment::RAILGUN_PAGE_HOSTS`.
   - Drop the spike's per-tunnel logging and byte counters.
   - Name `net`, `io-util` and `time` on the `tokio` line.
5. **Dart, Railgun side** (`lib/src/features/private_usd/`):
   - `services/railgun_host_channel.dart`
   - `models/railgun_models.dart`
   - `services/railgun_engine.dart`: one use at a time, a 10-minute idle close, the address check against Rust, phases, `reset`/`forget`, and a close and reopen on a route change, an account switch or lock (§6.3, §8.4)
   - `services/railgun_engine_key_store.dart`
6. **Dart, balance:** the repository, the cache and the provider, with the polling, back-off, `isInUse` gating and first-sync progress rules in §6.6.
7. **Availability:**
   - `lib/src/core/config/private_usd_feature_config.dart`: the define, plus `HttpPrivateUsdAvailabilitySource` (D16; modelled on `HttpSwapEnabledOverrideSource`)
   - `providers/private_usd_available_provider.dart` (§8.3)
   - the X3 gate in `zec_price_change_provider.dart:251`
8. **Home:** `_MobilePrivateUsdStrip` (§8.3, §9.4 S1), passed to `_BalanceCard` through new optional fields.
9. **Screen:** the `/private-usd` route and its guard (§9.2), and `mobile_private_usd_screen.dart`. Convert, Send and Withdraw stay hidden until M5 and M7. The guard's exception for an unfinished conversion's progress route comes with that route in M5.
10. **Lifecycle (no funds yet):**
    - lock closes the page
    - hide stops polling
    - a route change closes and reopens the page
    - an account switch closes the page and swaps the cache
    - account delete removes the engine key and the cache (plus `deleteWallet` with E5)
    - reset runs `wipe()`, `deletePrivateUsdDirectories()` and clears the token store

    All of these go through `privateUsdLifecycleProvider` (§8.4).
11. **Copy:** `private_usd_copy.dart`, with the Shared, Home, Private USD screen and Activity tables (§9.6).
12. **Widgetbook and capture scenarios:** home and `/private-usd` (§9.7).
13. **Kotlin tests:** port `RailgunBoundaryTest`, `RailgunChannelTest` and `RailgunProtocolTest` (§8.7 table), with raw-JSON strings, Robolectric for `org.json`, and the paths adjusted.

**Done when.**
- The unit essentials pass: bucket mapping (headline = `available + processing`), kill-switch parsing and its last-known fallback, the availability matrix, the bridge tests, the three Kotlin tests, and mobile-tagged strip and screen states.
- Device E2E (in the next device round, §10):
  - the strip shows "—" and starts no WebView before first use
  - `/private-usd` shows the first-sync percentage, then the balance; the address equals Rust's
  - the strip is hidden on regtest, on hardware accounts and with the kill switch false
  - Tor on: no direct sockets (the M0 checker)
  - lock closes the page
  - a release build loads the page (R8)

**Traps.**

- **Route change order.** Close the page, `stop_railgun_bridge()`, `start_railgun_bridge()` (a new port and a new isolated Tor client), then `load({proxyPort})`. Chromium keeps pooled sockets otherwise (U19).
- **Stop the bridge with the page.** A running bridge is a no-auth loopback proxy that any app on the device can use, so stop it whenever the page closes (lock, idle, account switch, reset), not only on a route change. `startRailgunBridge()` can wait up to 3 minutes for a Tor bootstrap, and fails with the route's message when Tor failed.
- **Return `true` from `onRenderProcessGone`,** or the app process dies with the renderer.
- **WebView work happens on the main thread; port messages are decoded on the `railgun-page` thread.** A `MethodChannel` result is answered exactly once. EventChannel `success` is called only on the main thread.
- **The proxy override is process-wide** and outlives a page close until cleared. Clear it in `close` and `wipe`; set it, and wait for it, in every `load`.
- **The bundle is an Android asset, not a Flutter asset.** Never add it to `pubspec.yaml`. AAPT compression is fine.
- **Never log `paramsJson`:** the page's `start` params can hold keyed RPC URLs.
- **Paths.** `getPrivateUsdDirPath(network)` validates the wallet DB name like `getGiftCardTrackingDbPath` and creates `<support>/private_usd_<walletDbName>_<network>`. Add `getPrivateUsdTokenStorePath(network)` for M4.
- **The engine lives outside the widget tree** (a `keepAlive` provider). Only lock, an account switch, a route change, idle or reset closes the page.
- **Mask the strip and the `≈ ZEC` figure** with `hideAmountIfPrivacyMode`.
- **The first sync needs the foreground and the screen on** (U21). On mainnet it takes about 40 min. For UI testing, keep one Sepolia wallet's WebView data between runs.

### M4. Privacy Pass tokens and attestation

**Goal.** A device can get and spend issuer tokens through vizor.

**Needs.** N1 before any code. E3 for acceptance (E9 is done).

**Inputs.**
- Reference: §5.2 (the `401` flow), §5.9, §6.2 (the attestation channel), §8.2 (M4).
- Sources: `zs/crates/zecswap-tokens/src/lib.rs` (the client API), `zs/crates/zecswap-jni/src/tokens.rs`, `zs/docs/tokens.md` and `BiometricUnlockHandler.kt`.
- Port from: `of/SwapTokens.kt:161-460` and `SwapTokensTest.kt`.

**Tasks.**

1. `tokens.rs` (§5.9): the state file; `pay` and `settle`; collecting returns; day rollover; the pinned checks; two-phase issuance (X11).
2. FRB `private_usd_tokens_issuance_begin`, `…_finish` and `…_status` (§8.2). The session lives in memory for at most 5 minutes and is dropped on finish, on expiry and on lock (`private_usd_clear_sessions()`).
3. Kotlin `PrivateUsdAttestationHandler.kt` on `com.zcash.wallet/private_usd_attestation` (§6.2):
   - alias `vizor_privateusd_attest_<issuer>`
   - key challenge `SHA-256("zecswap-issuer-v1" ‖ issuer)`
   - EC P-256, StrongBox once, then TEE
   - regenerate only when a certificate has expired
   - sign with `SHA256withECDSA`; return the chain base64url without padding
   - Keystore work on `Dispatchers.IO` under a mutex
4. Dart: `services/private_usd_attestation.dart` and `services/private_usd_tokens_service.dart` (begin in Rust, sign in Kotlin, finish in Rust). Prefetch on the convert screen and after every conversion.
5. Error codes and copy: `TokensUnreachable`, `TokensRefused`, `TokensDeviceRefused`, `NoTokensToday`, `Keystore`.

**Done when.**
- The state machine passes against a fake issuer and maker:
  - the pinned name and key; day checks (±10 min)
  - issuer tokens are spent before returns
  - `401` drops the token; `400`, `404` and `503` keep it
  - `403` retries with a new challenge; `429` means exhausted
- The attestation message is `"zecswap-issuer-v1" ‖ challenge ‖ SHA-256(blinded…)`.
- Device E2E (with E3): the testnet issuer returns a batch to the A35.

**Traps.**

- **Two different challenges.**
  - The token challenge comes from a maker's `401 WWW-Authenticate`; blind for it.
  - The attestation challenge is a fresh 32 bytes from `GET /v1/challenge`, and only it goes into the signed message. Mixing them up gives a `403` that looks like a device refusal.
- **A fresh install cannot prefetch.** `begin` returns `None` until a maker has answered one `401`.
- **The `403` retry needs a second Keystore signature** (`SignAgain` with `next`). Keep the same blinded batch.
- **Wire encodings** (all base64url, unpadded):
  - `GET /v1/token-key` → `{issuer, tokenKey, tokensPerDay}`. Refuse it unless it equals the pin.
  - `POST /v1/tokens` takes `{attestation: {challenge, chain, signature}, blinded}` and returns `{blindSignatures}`.
  - Fewer signatures than requested exhausts today. More than requested, or zero on a 2xx, is `TokensUnreachable`.
- **Make each issuance call a fresh, non-pooled routed request.**
- **The day** is the last 8 bytes of the 32-byte redemption context: big-endian days since the epoch, with ±600 s accepted.
- **Write the state file atomically** (temp file, `fsync`, rename). Read it leniently: an unreadable file starts empty.

### M5. Forward conversion (ZEC → USD), the engine loop, lifecycle guards and forward refunds

**Goal.** Convert ZEC to private USD end to end, safely under lock, background, crash, account switch and deletion.

**Needs.** E8 and N2 for the device E2E; not E3 (D20).

**Inputs.**
- This file: §3.5.
- Reference: §5.6, §5.8, §5.10, §5.11 (forward), §8.1.2, §8.2 (M5–M7), §8.3, §8.4, §9.1, §9.2, §9.4 S1/S3/S5, §9.5 (forward), §9.6 (Convert, Accounts), §9.7 (forward rows), §8.7 (M5–M8 table).
- Sources:
  - `account_provider.dart:1596-1700, 1865-1940`
  - `gift_card_tracking_provider.dart:76-131`
  - `public_details_loads_provider.dart`
  - `sync_provider.dart:1128, 2411-2455, 2620-2650`
  - `swap_deposit_sender.dart:75-234`
  - `lib/app.dart:541-556, 650-736, 1847-1905`
  - `mobile_routes.dart:74-110, 288-298, 338-360`
  - `mobile_home_screen.dart:1076-1188, 1578-1704`
  - `sync_keep_awake_native_host.dart:46-70`
- Port from: the §8.7 ranges only.

**Tasks.**

1. `engine.rs` (the per-account driver lock, the forward offer cache, the `op_id` registry) and `forward.rs`: the §5.6 state machine and the forward refund (§5.8), over `ChainReader`, `HttpTransport` and the joint-ops seams.
2. FRB (§8.2 M5):
   - `private_usd_forward_quote` (with `deposit_fee`), `…_forward_accept`, `…_forward_advance`, `…_forward_abandon`, `…_forward_records`
   - `…_unfinished_count`, `…_accounts_with_unfinished`, `…_delete_account`
   - `private_usd_cancel` and `private_usd_activity`
3. Dart engine (§5.10, §9.2): `services/private_usd_engine.dart` and a `keepAlive` provider, started by a `PrivateUsdEngineHost` beside `BackgroundAutoLockHost` (`lib/app.dart:1893`).
   - The host is inert unless the feature is on, the form factor is mobile and the platform is Android.
   - It loops over every account with unfinished work (D14).
   - It runs only in the foreground and unlocked, and not while the lifecycle fence is quiesced.
4. Lifecycle (§8.4):
   - `lib/src/providers/private_usd_lifecycle_provider.dart`
   - the unfinished-conversions warning (invariant 15: warn, then allow), drained in `_removeAccount` and `_resetWallet`
   - counts in `accounts_screen.dart:326` and `settings_uninstall_screen.dart:147-151`
   - cleanup after the Rust delete
5. UI (§9):
   - the convert, review and progress routes, and the guards
   - the convert provider (quote search, 700 ms debounce, 1 s expiry tick)
   - the conversion and unfinished providers
   - the status presentation (§9.5)
   - the home banner, activity rows, keep-awake (X8), and the Convert button
6. Copy: the Convert tables and Accounts (§9.6).
7. Widgetbook and capture scenarios: the forward rows of §9.7.

**Done when.**
- The fund-safety unit tests pass on fakes (the ★ cases in §8.7):
  - a deposit is never paid twice (`withFound`; created but unbroadcast is found, never rebuilt)
  - an expired deposit is rebuilt only when payable and with no refund lock
  - the claim refuses to reveal inside the 300 s margin
  - a payout is re-signed only on a fee rise, and never above 2 USDC
  - a concurrent advance and accept on one account gives `Busy` and leaves the record intact
- The lifecycle refusal, drain and cleanup tests pass.
- Device E2E (testnet + Sepolia, §10):
  - a small conversion reaches `Paid`
  - killed mid-confirmation, it resumes
  - locked mid-swap, no key is used, and unlock resumes it
  - an account switch keeps it advancing
  - the delete warning shows the count
  - with the kill switch false mid-swap, the swap still completes
- The desktop build still shows nothing new.

**Traps.**

- **The forward quote is not persisted.** Keep the offer in Rust (the `engine.rs` cache keyed `(account, index)`, dropped at `expires_at` and on lock). A missing offer at accept is `QuoteExpired`. Never pass quote JSON through Dart.
- **The share proof needs `rand` 0.10.** `zecswap_core::SwapContext::prove_user` takes a `rand` 0.10 `CryptoRng`; vizor's `rand` is 0.8, whose `OsRng` does not satisfy it. Add `rand` 0.10 (already in the lockfile through `zecswap-core`) under a renamed dependency with `sys_rng`, and use `UnwrapErr(SysRng)` as zecSwap's tests do. `SwapKeyContext::acceptance` (mirroring `ops.rs:164-188`) lands with it (D-7).
- **Accept must be re-entrant.** A repeat accept for a saved, unfinished, unanswered index (`t0 == None`) re-POSTs `record.quote`. After any accept error, Dart reads `forward_records` and switches to progress if the index is under way.
- **Two Rust locks.**
  - `OPERATIONS` guards SQLite writes and is never held across I/O.
  - A per-account `tokio::sync::Mutex` is held for a whole driver step; a second caller gets `Busy`. Without it, accept and the loop overwrite each other's `t0` and ticket.
- **The deposit runs beside the main sync.** Both take `with_wallet_db_write_lock` per call or batch, so multi-second waits are normal.
  - Don't use `runWithAuthoritativeSpendable`, which breaks D14.
  - Rust compares the scanned height with the **live** lightwalletd tip and returns `wait = ZcashSyncing` until it catches up.
- **A created deposit is always broadcast:** the main sync's `resubmit_pending_transactions` rebroadcasts it. Never replace one; reconcile by txid only. A deposit that lands after a refund lock is swept through `DEPOSIT_UNSETTLED`.
- **`PROPOSAL_STORE` within one advance.** Hold the deposit proposal in an RAII guard that discards it unless create consumed it. Use `send_flow_id = "private-usd-deposit:{account}:{index}"`. A refusal during app exit is retryable.
- **The deposit fee preview** builds the `propose_swap_deposit` proposal without storing or locking it, and requires one step and no Sapling parameters (D-35). `None` makes the quote unpayable.
- **Txid order.** Return internal-order hex for matching history rows; display it with `zcashDisplayTxidHex`. zapp's JSON stores display hex.
- **Lock with a call in flight.** Run `private_usd_cancel(op_id)` and `private_usd_clear_sessions()`, await at most 5 s, then drop the result: compare an engine epoch before and after each await. Zero the Dart mnemonic in `finally`.
- **No shared foreground provider exists.** Copy Gift Card's shape: `ref.listen(appSecurityProvider)` and lifecycle `onHide`/`onPause` pause; `onResume` resumes and nudges.
- **The mutation guard does not pause the engine.** Register it with the `privateUsdLifecycle` drain; `quiesceAndDrain` cancels and awaits.
- **The router is synchronous.** Add `ref.listen(privateUsdAvailableProvider)` and `ref.listen(privateUsdUnfinishedProvider)` in `_routerProvider`. The in-flight exception needs a synchronous `Set` held in a `Notifier`.
- **Keep-awake has one native flag.** Change the host's watch to `syncActive || privateUsdActive`; never call `NativeScreenAwakeBridge` directly.
- **Amounts never touch `double`.**
  - ZEC goes through `parseZecAmount` and `formatZecAmount`.
  - USDC is `BigInt` base units.
  - `units` is a `u32`.
  - `receives` comes from Rust.
- **Quotes spend indices.**
  - A search makes up to 1 probe plus 3 quotes, with a 700 ms debounce.
  - Never quote on screen open, on "Max" before the balance is authoritative, or while the review is up.
  - Stop offering a quote 20 s before expiry.
- **`RAILGUN_CLOSED` is a chain read (`railgunAccepts`), not the page.** The forward path never opens the WebView.
- **Activity rows** merge inline on home and in Activity. Drop main-DB rows whose txid is a record's deposit or sweep, and mask with privacy mode.
- **Desktop stays inert:** availability is false off Android mobile, and the routes exist only in `buildMobileRoutes`.

### M6. Reverse conversion (USD → ZEC), reverse refunds, rescue and the Refunds screen

**Goal.** Convert private USD to ZEC, with cancel, refund and rescue.

**Needs.** E8 and N2 for the device E2E.

**Inputs.**
- Reference: §5.7, §5.8 (reverse refund, rescue), §5.10, §5.11 (reverse), §6.2 (`reverseCost`, `prepareReverse`, `proof`), §6.3, §8.2 (M6), §9.4 S4/S6/S7, §9.5, §9.6 (Reverse, Refunds), §9.7, §8.7 (M5–M8 table).
- Port from: the §8.7 ranges only.

**Tasks.**

1. `reverse.rs` and `funding_calls.rs`: the §5.7 state machine, the reverse refund and rescue (§5.8), and the `openReverse` calldata.
2. FRB (§8.2 M6): `private_usd_reverse_quote`, `…_set_cost`, `…_go_ahead`, `…_accept`, `…_funding_request`, `…_submit_funding`, `…_advance`, `…_authorize_ready`, `…_cancel`, `…_can_rescue`, `…_rescue` and `…_records`.
3. Dart:
   - reverse support in the convert, review and conversion providers (`?to=zec`)
   - the funding orchestration (`private_usd_reverse_funding.dart`, §5.11 R5–R8) under the spend guard, showing `proof` events
   - the "Pay {debit}" and "Authorize settlement" actions
   - the reverse progress route, and `/private-usd/refunds` with its provider
   - confirmation sheets for cancel, refund and rescue (D18)
4. Copy: the Reverse and Refunds tables (§9.6).
5. Widgetbook and capture scenarios: the reverse and refunds rows (§9.7).

**Done when.**
- The fund-safety unit tests pass on fakes (★ cases in §8.7):
  - lost-response resend rules
  - a late funding response after cancel keeps the cancel
  - `ready` is never re-signed after a restart
  - the receive sweep is capped at the reviewed fee
  - a reveal is refused when the refund lock is about to lapse
  - rescue eligibility and nonce
  - `openReverse` calldata matches zapp's fixture
- Device E2E:
  - a small reverse conversion reaches `COMPLETE`
  - cancel before funding gives `CANCELLED`
  - cancel after funding gives `REFUNDED`
  - lock during the funding proof pays nothing

**Traps.**

- **The reverse quote needs the page.** `cost` comes from the page's `reverseCost`, so the direction works only once the page is `READY`. For each amount: `reverse_quote`, then `reverseCost`, then `set_cost`.
- **The Railgun seed signs `OpenReverse`,** so `funding_request` takes `mnemonic_bytes`. Refuse a page whose address differs (invariant 19).
- **A funding proof can finish after lock or background** (it takes up to 10 min in the page). Before `submit_funding`, re-check unlocked, foreground and the epoch; otherwise drop the proof.
- **Cancel can race the proof.** `submit_funding` refuses when `cancelRequested` is set.
- **Outbox order:** save in one SQLite transaction, then post. The driver lock may span the post; `OPERATIONS` must not.
- **`ready` is a user action only.** The loop only resends a saved `ready` before its deadline. The button is enabled in `AWAITING_READY` until `readyDeadline − 120 s`.
- **The joint import and claim scan take the global write lock** and contend with the main sync. A docstring at `sync_engine/mod.rs:2805-2807` wrongly says otherwise.
- **Reverse amounts have at most 2 decimals.** Convert with string arithmetic. Max = `available − unshieldFee − fundingFee`, rounded down.
- **`can_rescue` is a chain read only;** `rescue` needs the secret and the lock.

### M7. Private send and withdraw

**Goal.** Send private USD to a `0zk` address, or withdraw to a `0x` address.

**Needs.** N2 for the device E2E.

**Inputs.**
- This file: §3.4 (`railgun_sends`).
- Reference: §6.2 (`broadcasterFee`, `transfer`, `unshield`), §6.6 "Shared syncs", §6.7, §8.2 (M7), §9.4 S2 and S8, §9.6 (Send and withdraw), §9.7.
- Sources: `address_format_validator.dart:52-70, 120-140` and `mobile_transaction_progress_screen.dart`.
- Port from: the §8.7 ranges only.

**Tasks.**

1. Rust:
   - `relayer_client.rs`: `railgunSends` terms and `POST /v1/railgun/transact`
   - `sends.rs`: the send log, and settlement (`private_usd_send_settle_all`, the `when` of `PrivateUsdSender.kt:323-386`)
   - `evm_rpc.rs`: `nullifiers(uint256,bytes32)` (`0xf19ea903`) and the receipt status
   - FRB (§8.2 M7)
2. Dart:
   - `private_usd_sender.dart` (pricing, proving, keeping, the first post)
   - `private_usd_spend_guard.dart`
   - the send and spend-status providers
   - the send, withdraw, review and status routes
   - the 2 USDC cap on the `broadcasterFee` fee, enforced before proving
3. Copy: the Send and withdraw table (§9.6).
4. Widgetbook and capture scenarios: the send rows (§9.7).

**Done when.**
- Unit tests pass:
  - the transact answer mapping (`200`, `409`, other `4xx`, and `5xx` or transport errors retry the same bytes for at most 1 h, honouring `Retry-After`)
  - keep-before-post
  - the guard across restarts
  - form validation (`0zk` through Rust; `0x` with EIP-55 and the zero address)
- Device E2E on Sepolia:
  - a send arrives at a second account's `0zk` address
  - a withdrawal reaches a `0x` address
  - killed between proving and the post, it resends the same bytes and never re-proves
  - on Sepolia, outputs stay "Processing" (`MissingExternalPOI`)

**Traps.**

- **Keep before post, and post from the store:** `transfer`/`unshield`, then `send_log_put` (`unconfirmed`), then `relayer_transact(send_id)` reading the bytes from `swaps.db`.
- **A proof can land after lock or background.** Re-check before `send_log_put`.
- **Settlement reads the chain:** the receipt (1 confirmation) or the nullifiers (one transact spends all or none). Port the `when` exactly.
- **The EVM validator is private.** Add a public `isValidEvmAddress` beside `_isEvmAddress`, plus a zero-address check.
- **Fees are `BigInt` base units,** compared with `ApiDeployment.max_relayer_fee`. "Use it all" = `available − reserve`. Only withdraw pays Railgun's 25 bps unshield fee.
- **One payment at a time per account,** conversions included. Send and Withdraw are disabled while `CHECKING` or `UNREADABLE`.

### M8. Hardening and release QA

**Goal.** Release readiness on mainnet.

**Needs.** E6, E7, and the owner's sign-off before turning the flag on.

**Inputs.**
- This file: §3.5, §11.
- Reference: §7.3.
- AGENTS.md (this milestone edits it); `android/app/build.gradle.kts:15-40`.

**Tasks.**

1. Change the route during each phase (a forward claim, reverse funding, a send): each fails closed and resumes.
2. The kill switch: live JSON (E7), a version without the flag, and a fetch failure, which keeps the last value.
3. The keyed RPC (E6), through `--dart-define-from-file`, must never appear in logcat or in `swaps.db`.
4. Measure APK size, first-sync time, proof time and memory on the A35; update §11.
5. `docs/private-usd-device-checklist.md`: the manual E2E runs for both directions, refund, rescue, send, withdraw, lock, background, kill, account switch, and Tor on and off.
6. A "Private USD" section in AGENTS.md: §3.5, §7.3, foreground-only, and the separate DBs. Also correct AGENTS.md's description of the Android preparation worker and `android_jni.rs`, which do not exist (D9).
7. Turn `VIZOR_PRIVATE_USD_ENABLED` on for release builds only after the owner signs off.

**Done when.** The checklist passes on mainnet with the beta limits (`maxSwapUsdc` 50).

**Traps.**

- **Build release with all the defines:** `fvm flutter build apk --release --dart-define=VIZOR_FORM_FACTOR=mobile --dart-define=VIZOR_PRIVATE_USD_ENABLED=true --dart-define-from-file=<rpc json>`.
- **Issuer acceptance is per signing digest** (E3): a differently signed APK gets `TokensDeviceRefused`.
- **The beta limits are enforced by the server.** Test with more than 50 USDC; never hard-code the limit.

## 10. Test strategy

The owner's preference (2026-10-13): end-to-end first. Device runs are batched into rounds, run once the funded test wallets exist (E8, N2). Unit tests stay small and guard only funds and keys.

**Unit tests: only these.**

- Known-answer vectors (§3.3, §5.5).
- The 2 USDC fee cap, amount parsing, and strict decoding (ABI words, stored records).
- The fund-safety rules of the state machines, on fakes in `rust/src/wallet/private_usd/tests/fakes.rs` (a `ChainReader`, an `HttpTransport` routed by path, the Zcash ops, an in-memory store):
  - an index is never reused
  - a deposit is never paid twice
  - the reveal margin
  - `ready` is never re-signed
  - keep before post
  - the refund branches

  Port only the ★ zapp cases these need (§8.7, "Tests to translate"). As built for the forward machine (M5 part 1): `private_usd/tests/forward.rs` (38 tests) and `private_usd/tests/lifecycle.rs` (3, through the FRB calls) on the fakes in `private_usd/tests/fakes.rs`; the ★ mapping is progress-doc D-39.
- Routes fail closed under `network_privacy::test_route_policy::lock_route_policy()`.

Skip unit tests for UI glue, provider wiring and copy; the device rounds cover them. The existing suites must keep passing: `cargo test`, `fvm flutter analyze`, `fvm flutter test` and the mobile lane.

**End-to-end lanes.**

| Lane | What | When |
|---|---|---|
| Device rounds (Galaxy A35, testnet + Sepolia) | Each milestone's device checks under **Done when** | One round each after M3, M5, M6 and M7; mainnet in M8 |
| Ironwood regtest | The M2 joint-account test (deposit, import, scan, sweep, Discard OVK) | The M2 gate, with the owner's go-ahead |
| Railgun host harness | `lib/railgun_spike_main.dart`: `SPIKE_MODE=direct\|tor\|flip\|fail`, a debug-only entrypoint over the app's channel wrapper and page models since M3 (D-30) | Host or bridge changes |

**In every device round:**

- Tor on: no direct sockets. `scripts/private-usd/check_sockets.py` classifies the app UID's `/proc/net/tcp{,6}`; `--onionoo` checks every remote against the Tor relay list.
- Lock, background, kill and account switch mid-flow.
- Memory and timing: `scripts/private-usd/sample_device.sh`.
- Keep the screen on (U21) with Developer options "Stay awake", and restore the setting afterwards.
- Never install an emulator.

**Notes.**

- Regtest has no Ethereum, so the convert flows cannot run end to end on regtest.
- The existing mobile E2E harness (`scripts/e2e/flutter-ios-regtest-mobile-*.sh`) is iOS-simulator-only, so Android flows are device rounds.
- Assets never go under `assets/**/desktop/`. Run `test/core/platform_asset_contract_test.dart` after changing assets or `pubspec.yaml`.
- Tests and Widgetbook assert on the constants in `private_usd_copy.dart`, never on duplicated literals.

## 11. Risks and unverified items

| # | Item | How and when to verify | Fallback |
|---|---|---|---|
| U1 | The zecSwap crates build inside vizor's own crate graph (the scratch build used the same Zakura versions and patch rev). **M0 (2026-10-13):** `zecswap-core` (Zakura build) and `zecswap-railgun` do; `zecswap-tokens` does not (`digest` conflict, M0.1 result) | M0.1 | Path A vendoring (E1) |
| U2 | A V6 deposit to an Orchard-only UA lands as an Ironwood output in vizor. **M0 (2026-10-13):** verified offline (M0.2 result); testnet confirmation pending | M0.2 on testnet; asserted in the M2 regtest test | Escalate: the protocol depends on it (§5.1) |
| U3 | vizor's main DB keeps `to_address` for the deposit's sent output (`findDeposit`). **M0 (2026-10-13):** verified offline (`orchard_receiver_tests.rs`) | M0.2; M2 unit test | Recover sent outputs with the account's OVK (the deposit uses the sender OVK) |
| U4 | **Answered by M2.7b (2026-10-13): the Ironwood regtest run passed.** `zecswap_core::sign_pczt` accepts vizor's `bind_pczt` proprietary lock-owner field | M2.7b (the regtest test signs a bound PCZT) | Sign a clone with proprietary fields stripped. They are not covered by the sighash. |
| U5 | **Answered by M2.7b (2026-10-13): the Ironwood regtest run passed.** `extract_required_compact_sigs_from_signed_pczt` returns exactly the joint spends | M2.7b (asserted there; the completion path's preflight also refuses any other set) | Extract with `extract_orchard_spend_auth_signatures` (`wl/librustzcash/pczt/src/roles/signer/mod.rs:478-487`) and apply them by index |
| U6 | **Answered by M2.7b (2026-10-13): the Ironwood regtest run passed.** A joint-DB scan whose birthday is ≥ the tip (librustzcash#2301 panics on an empty scan range next to a deleted account's ranges; vizor's claim sync normalizes ranges, `rust/src/wallet/sync_engine/mod.rs:2865-2868`). **M2 (2026-10-13):** by reading the claim scan, a `joint.db` born above the tip fails its completion checks (no block is stored at the tip), so `sync_joint_db` returns at once until the tip reaches the birthday, as zecSwap's `born_above` does (D-10); the tip it compares is read fresh, never from the 15 s transaction tip cache (D-50) | M2.7b imports above the tip and syncs | Import at tip + 1, as zecSwap does (`zs/…/zcash/wallet.rs:451-470`) |
| U7 | ~~`payment_link_resubmit_exclusions` is harmless on a joint DB~~ Answered (M2, code reading; M2.7b ran it, 2026-10-13): it reads only librustzcash tables, and excludes only an unmined local send whose note another transaction six blocks deep already spent. That is right for a joint DB too. M2.7b runs it | M2 | Pass no exclusions for joint DBs |
| U8 | **Answered by M2.7b (2026-10-13): the Ironwood regtest run passed.** With Discard OVK, the primary store path (`extract_and_store_transaction_from_pczt`) still records the sweep as sent. The fallback `decrypt_and_store_transaction` (`pczt.rs:2056`) cannot recover the outgoing metadata. **M2 (code reading):** the primary path rebuilds each sent output from the PCZT's own fields and recipient metadata and never uses an OVK; `sweep_joint` returns the bytes either way | M2.7b asserts the sent row | Harmless: the joint DB is deleted after the sweep. Persist the bytes in the record regardless. |
| U9 | **Answered by M2.7b (2026-10-13): the Ironwood regtest run passed.** `create_pczt_from_proposal` works for a `Spending { derivation: None }` account (zapp does the equivalent on the upstream SDK). **M2 (2026-10-13):** PCZT creation verified offline by the M2 unit tests; signing, proving and extraction remain for M2.7b | M2, M2.7b | Investigate: there is no alternative path |
| U10 | WebView `PROXY_OVERRIDE` support, SOCKS5 behaviour, keep-alive on a route change, IndexedDB and `blob:` workers under the proxy, the cleartext policy for the loopback hop. **M0 (2026-10-13):** the Rust side is verified on a desktop host (SOCKS5 no-auth, allowlist, direct lease aborted by a Tor enable, and a real Tor bootstrap tunnelling to an allowlisted host through the patched `connect_stream`); on a device (Galaxy A35, Android 16, WebView 155): `PROXY_OVERRIDE` works, SOCKS5 through the bridge works, IndexedDB and the engine's workers run under the proxy, and the loopback SOCKS hop needs no `network_security_config` | M0.3 | D4 fallback |
| U11 | ~~Whether each maker requires tokens today~~ Answered: not today (D20). Re-check before release. | Before release | none needed; M4 is built either way |
| U12 | The WebView data directory path for the backup exclusion (`app_webview`). **M0 (2026-10-13):** confirmed as `/data/data/com.keplr.vizor/app_webview` (`Default/IndexedDB` holds the Railgun DB) | M3: inspect `/data/data/com.keplr.vizor/` on a device | Exclude the observed path |
| U13 | R8 shrinking on the release build breaks nothing the host needs (no reflection; `org.json` is platform code) | M3 release build | Add keep rules |
| U14 | Memory, proof time, and total artifact download for a typical send (`01x02/zkey.br` 3.53 MB, `01x02.wasm.br` 0.89 MB, `POI_3x3/zkey.br` 7.78 MB; larger variants are bigger). **M0 (2026-10-13, Galaxy A35, Sepolia, debug build):** a first sync downloads about 6.8 MB (almost all from `rail-squid.squids.live`; RPC about 12 KB, POI about 6 KB). Peak PSS is 446 MB for the app and 382 MB for the WebView renderer. Proof time and artifact bytes are pending a funded wallet | M0.3, then M8 | none; record the numbers here |
| U15 | `deleteWalletByID` exists in `@railgun-community/wallet` 11.1.0 for the D15 page method | E5 | Delete only the engine key; the orphaned blob stays encrypted |
| U16 | ~~`zcash_voting::RouteRequest` can be built outside its crate~~ Moot: Private USD calls `routed_http` directly, and `VizorRoute` delegates to it (M1 task 10b) | — | — |
| U17 | Where `WALLET_SOURCE` surfaces on chain (X2) | E5 | Keep `'zapp'` |
| U18 | Alchemy origin allowlisting reduces key exposure | M8 | Rate-capped dedicated keys |
| U19 | ~~Whether Chromium tears down pooled sockets on a proxy change by itself~~ Answered (M0): it does not. 2–3 tunnels were still open 10 s after the page closed and the override was cleared | M0.3 | Always close the page, stop the bridge and reopen on a route change (now required, not just the default) |
| U20 | iOS `WKWebView` runs the chrome100-target bundle (ESM, WASM, IndexedDB, blob workers) unchanged | the iOS port, later | Rebuild with an iOS target |
| U21 | **New (M0):** the Railgun first sync survives only in the foreground with the screen on. On the A35, Android froze the app about 60 s after screen-off (`onFreezeStateChanged`), Tor circuits died, and `refresh` failed `Incomplete`. A restarted sync resumed faster (68.5 s against about 100 s), so some progress persists. Mainnet first syncs take about 40 min (§6.3) | M3 device run on mainnet | Keep the screen awake during a first sync (extend X8), or accept a resumable sync that continues on the next foreground |

**Accepted risks.**

- **A created deposit always goes out.** The main sync rebroadcasts every unmined, unexpired outgoing transaction (`resubmit_pending_transactions`), so the engine cannot withhold a deposit it has already created, even after the maker takes a refund lock. Such a deposit is swept home through `DEPOSIT_UNSETTLED` (§5.8), less fees. Excluding joint-UA deposits from resubmission is possible but not planned.

- **The GPL-3.0 bundle inside an Apache-2.0 app.** The owner decided to ship it as a separately licensed asset (D3, X12). The swap path never needs the bundle; only the balance, reverse funding and sends do. A native prover (`Railgun-Community/mopro`) is the alternative if legal review objects. That would be new work.
- **The exact birthday reveals swap timing** to lightwalletd (invariant 12).
- **The no-auth loopback proxy** is reachable by other local apps while the page is open (§6.8).
- **Foreground-only conversions fail more often** than zapp's (D9). The copy says to keep Vizor open, and X8 keeps the screen awake.
- **The same seed in zapp and vizor** on ZIP-32 index 0 shares the Railgun wallet and the swap index space. Chain-checked index skipping prevents reuse (§3.3).
- **The Sepolia screening indexer is broken,** so relayed-send outputs stay `MissingExternalPOI` (Processing) on testnet.
- **The first Railgun sync is slow.** On mainnet the notes phase alone took ~40 minutes on a Galaxy A35 over Wi-Fi (~60 % of the sync). It needs the foreground and the screen on (U21). In M0 a restarted sync finished faster (68.5 s against about 100 s on Sepolia), so some progress persists.
- **AGENTS.md describes an Android preparation worker and `rust/src/android_jni.rs` that do not exist in this repo.** Do not build on them. M8 corrects AGENTS.md.
