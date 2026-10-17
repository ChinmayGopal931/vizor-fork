# Private USD (iOS): progress

Tracks `docs/private-usd-ios-plan.md` §4. A task is done only when its line is checked. Each milestone also has a gate line:

- its **Done when** holds;
- `cargo test`, `fvm flutter analyze`, `fvm flutter test`, the mobile lane and the Swift tests pass;
- Android's Kotlin tests still pass;
- its Traps have been re-read against the diff.

## Where things stand (2026-10-17; read this first)

- **MI1's code is done** (2026-10-17): one bundle for both platforms, with the iOS transport, `deleteWallet` and `WALLET_SOURCE = 'vizor'`. Android's state is in `docs/private-usd-progress.md`.
- **Open for the owner:** BI-3, when Dart deletes an account's Railgun wallet.
- **Decisions.** The owner confirmed DI2 (hide below iOS 17), DI6 (exclude from backups) and DI7 (the full rebuild) on 2026-10-17. DI1, DI3–DI5 and DI8 are still proposals; their defaults hold. DI3, the licensing review, blocks only external distribution.
- **Order (owner, 2026-10-17; VI-1).** Code first: MI1–MI3 without any simulator or device run. The MI0 checks, the device parts of MI1–MI3 and the Swift test runs wait for the first session with a phone connected. If space runs short, the Android Rust cache (`build/rust_lib_zcash_wallet/build/aarch64-linux-android`, about 3.5 GB) may be deleted; nothing else.
- **Deliverables.** EI1 (a test iPhone) and EI2 (signing for device builds) gate every device step. The simulator covers MI0's function checks.
- **Simulator.**
  - The iPhone 17 Pro simulator (iOS 26.5), UDID `2F355481-7C3B-47C9-ACBD-A9E08938C039`, already runs the app with the neon redesign: testnet, with a wallet created on 2026-10-17.
  - Private USD is hidden there, as it should be: the platform gate is Android-only (`private_usd_available_provider.dart:59`).
- **No iPhone yet.**
- **Disk.** About 10 GB was free after `rust/target` was deleted on 2026-10-17, and an iOS simulator build needs 5–6 GB of it. Check before each build.
- **Next.** MI1, MI2 and MI3's code (VI-1). The owner rules on DI8 before the first device build.

## MI0. Spikes (go/no-go)

- [ ] MI0.1 Spike bundle: the `safari17` target and a temporary iOS transport (branch `spike/private-usd-ios-m0`)
- [ ] MI0.2 Page shell: custom scheme, dedicated store, rule list, transport; the Dart harness modes
- [ ] MI0.3 Capabilities on the simulator and the iPhone (UI1): ES modules, WASM, IndexedDB across a relaunch, blob workers, `crypto`; a Sepolia first sync
- [ ] MI0.4 Proxy (UI2, UI5, UI7, UI8): only hostnames on 443 reach the bridge; with Tor on, no direct sockets; a flip and a Tor failure fail closed; no Local Network prompt, no ATS error
- [ ] MI0.5 Hidden page (UI3): detached against in-window, timed
- [ ] MI0.6 Background and the bridge (UI16): 2, 5 and 15 minutes away
- [ ] MI0.7 Wipe and backups (UI6)
- [ ] MI0.8 Memory and proof time on the iPhone (UI4; needs N2)
- [ ] MI0 gate: go, or a fallback recorded as a deviation

## MI1. One bundle for both platforms

- [x] MI1.1 The `index.js` transport abstraction; `INIT` becomes `vizor-railgun-init`
- [x] MI1.2 E5: `deleteWallet`, `WALLET_SOURCE = 'vizor'` (the page side; Dart's call waits on BI-3)
- [x] MI1.3 `build.mjs`: the `safari17` target and the iOS copy
- [x] MI1.4 Kotlin `INIT` and its tests; `check.mjs`
- [x] MI1.5 The Rust pin test reads the iOS copies (`index.html` here; `RailgunEndpoints.swift` comes with MI2)
- [ ] MI1.6 (optional) WebKit smoke test, `check-webkit.mjs`: skipped, Playwright is not installed here and nothing new was installed
- [ ] MI1.7 Android M3 device round with the new bundle (UI10, UI11): deferred to the first device session (VI-1)

MI1 evidence (2026-10-17, code only):

- The bundle builds reproducibly: two builds, identical hashes. The iOS copy is byte-identical to the Android output. The unchanged source also rebuilt byte-identical to the committed zapp bundle before any edit.
- The new bundle, against the old: only `railgun.js` changed, 9,767,606 → 9,768,846 bytes (SHA-256 `66847fb6…74ba`). `poseidon_hash_wasm_bg.wasm` 1,936,566, `curve25519_scalarmult_wasm_bg.wasm` 29,793, `COPYING` 35,147, `railgun.js.LEGAL.txt` 4,586 and `index.html` 617 are unchanged.
- `npm test`: 8 of 8 pass, two of them new (`wallet-namespaces.test.mjs`).
- `npm run check` (headless Chrome, Sepolia) passes: the Android transport with the new hello, a first sync and a reopen from IndexedDB, then `deleteWallet` removes all 3 of the fresh wallet's keys, a second delete is harmless, and the page that deleted refuses `start`.
- Kotlin railgun tests: 21 of 21 pass. Rust `railgun_bridge`: 8 pass, 1 ignored (it bootstraps Tor over the network).
- [ ] MI1 gate

## MI2. The Swift host

- [ ] MI2.1 The `ios/Runner/Railgun/` files and the folder reference
- [ ] MI2.2 Channel registration in `AppDelegate`
- [ ] MI2.3 `supported` on iOS and Android (with a Kotlin test)
- [ ] MI2.4 The page in the window; handling a terminated page
- [ ] MI2.5 The bridge after the background (XI14)
- [ ] MI2.6 Swift tests (`RailgunHostTests.swift`)
- [ ] MI2 gate

## MI3. Availability, balance and lifecycle on iOS

- [ ] MI3.1 The bootstrap's `hostSupported`; both gates; the availability-matrix tests
- [ ] MI3.2 Backup exclusion (DI6)
- [ ] MI3.3 Lifecycle checks: lock, route change, account switch, idle close, background, reset
- [ ] MI3.4 The device test's platform checks
- [ ] MI3.5 `scripts/private-usd/ios/run_device_round.sh`
- [ ] MI3.6 iOS M3 device round (iPhone)
- [ ] MI3 gate

## MI4. Forward conversion on iOS

- [ ] MI4.1 iOS M5 round
- [ ] MI4.2 iOS interruptions: an app-switcher kill, the power button, a call, Low Power Mode
- [ ] MI4 gate

## MI5. Reverse conversion on iOS

- [ ] MI5.1 iOS M6 round
- [ ] MI5.2 Reverse-funding proof time and memory
- [ ] MI5 gate

## MI6. Private send and withdraw on iOS

- [ ] MI6.1 iOS M7 round
- [ ] MI6.2 Send and withdraw proof time and memory
- [ ] MI6 gate

## MI7. Tokens and App Attest (deferred: no maker requires tokens)

- [ ] MI7.1 Swift attestation handler
- [ ] MI7.2 The token protocol's iOS form (with EI6)
- [ ] MI7.3 Dart: the attestation service picks the platform's method
- [ ] MI7 gate

## MI8. Hardening and release

- [ ] MI8.1 Route change in each phase on iOS
- [ ] MI8.2 Kill switch on iOS
- [ ] MI8.3 Keyed RPC scan of the logs and the container
- [ ] MI8.4 Measurements
- [ ] MI8.5 iOS device checklist on mainnet
- [ ] MI8.6 Privacy manifest, export compliance, review notes, licensing (DI3, DI4)
- [ ] MI8.7 AGENTS.md: the iOS host
- [ ] MI8.8 The flag turned on for iOS release builds, after sign-off
- [ ] MI8 gate

## Deviations

Number them VI-1, VI-2, and so on. Each entry says what the plan said, what reality required, and which section of the plan was updated in the same commit.

- **VI-1 (owner, 2026-10-17): code before the spike.** The plan put MI0, a go/no-go spike on the simulator and an iPhone, before MI1. Because Android already works, the owner moved the code first: MI1–MI3 are implemented without simulator or device runs, and the MI0 checks, the device parts of MI1–MI3 and the Swift test runs happen together in the first session with a phone connected. Their fallbacks (plan §11) still apply if a check fails then. Plan "How to work" updated.
- **VI-2 (MI1.2): what `deleteWallet` deletes, and how.** The plan named the method and A-plan U15 expected the SDK's `deleteWalletByID`. Reading the SDK (engine 9.8.0) showed that `deleteWalletByID` removes only the wallet's encrypted record (`['wallet', id]`); the notes a sync decrypted (`['wallet', id, chain, …]`, with the scan details) and the notes it sent (`['wallet', id-spent, chain, …]`) are written unencrypted and would stay. So the page's `deleteWallet {network, mnemonic}`:
  - derives the id as `openWallet` does (`RailgunWallet.generateID(mnemonic, 0)`);
  - deletes the record, then clears both namespaces, whose paths come from the engine's own methods (`src/wallet-namespaces.js`, pinned by a Node test against a real wallet object);
  - opens only the database (`startRailgunEngine` with no provider and no screening nodes), so nothing leaves the page; a page that deletes refuses `start`, and one that started refuses `deleteWallet`, because the engine is one per page;
  - is a new method in the host tables, with a 1-minute timeout (Kotlin's `RailgunMethod`, which its `thePageAnswersEveryMethod` test requires, and Swift's).

  `check.mjs` gained a delete check, which passes in Chrome. Dart does not call `deleteWallet` yet: when and how is the owner's choice (BI-3). Plan MI1 tasks 2 and 4 and §3.6, iOS reference §6.2 and §6.5, the Android reference's §6.2 method table and the A-plan's E5 and U15 rows updated.
- **VI-3 (MI1.2): `WALLET_SOURCE` does not touch stored wallets.** The plan left it unverified (UI10, A-plan U17) and the owner accepted that the A35's wallet might rescan. The SDK writes the wallet source only into the encrypted annotations of the notes a wallet sends (AES under the sender's viewing key). The wallet's id is `sha256(seed ‖ index)` and its record `['wallet', id]`, neither of which depends on it, so existing wallets open unchanged and nothing rescans. Plan MI1 Traps and UI10, and the A-plan's U17 row, updated.
- **VI-4 (MI1.3): the `safari17` target changes nothing.** The plan expected it might change esbuild's lowering for Android (UI11). A `chrome100`-only build of the same source is byte-identical to the `chrome100` + `safari17` build, so Android gets exactly the code it would get without the Safari target. The A35 round (MI1.7) still gates the source changes. Plan MI1 Traps and UI11 updated.

## Blocked

- **BI-1. A test iPhone (EI1) and signing for device builds (EI2).** Every device step waits on them. The simulator covers MI0.2 to MI0.7's function checks. MI0.6 and MI0.8 need the iPhone for real numbers.
- **BI-2. The licensing decision (EI3, DI3).** It blocks external TestFlight and the App Store; nothing before MI8 waits on it.
- **BI-3. When Dart deletes an account's Railgun wallet (owner's choice).** The page side is built (VI-2). The Railgun mnemonic comes from Rust, which checks the seed against the account, so it can be derived only before the Rust account delete. The options:
  - **(a) At deletion, through a page (recommended).** Before the Rust delete, derive the account's Railgun mnemonic, only if the account ever used Private USD (it has an engine key). After the delete succeeds, start the bridge, load a fresh page, call `deleteWallet`, then close the page and stop the bridge. It is best effort: if it fails (Tor down, the page won't load), the record stays unreadable until a reset, as today. The costs: the mnemonic is held through the Rust delete, as `openWallet`'s path already holds it for minutes, and the deletion waits for the bridge, up to 3 minutes while Tor bootstraps. The bridge is needed only because no page loads without its proxy (invariant 20); `deleteWallet` itself sends nothing.
  - **(b) Deferred.** Persist that the account's wallet must go (its id) and delete it the next time the page opens for any account. No page during the deletion, but a new persisted item, and the data stays until that next use.
  - **(c) Keep today's behaviour.** Delete only the engine key: the encrypted record and the unencrypted notes stay until a reset.
