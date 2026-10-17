# Private USD (shielded ZEC ↔ Railgun USDC) on iOS: implementation plan

**Goal.** Bring Private USD, as built and device-tested on Android, to iOS:

- a Railgun USDC ("private USD") balance on the home screen
- conversion both ways between shielded ZEC and private USD, by atomic swap, with refunds and refund recovery ("rescue")
- private USD send (to a Railgun `0zk` address) and withdraw (to a public `0x` address)

**Scope.** iOS, mobile form factor (`--dart-define=VIZOR_FORM_FACTOR=mobile`), with the same v1 scope as Android (A-plan D5). Desktop stays out, and Android must not change behaviour. The Android plan kept the Rust engine, the Dart models and the JS bundle platform-neutral so that iOS would need "only a Swift `WKWebView` host and an attestation channel" (A-plan, Scope). That still holds, with four findings this plan adds:

- **The page's handshake is Android-only.** The host hands the page a `MessagePort` with `postWebMessage`, and the page accepts only a message whose `source` is `null` (`android/railgun-web/src/index.js:53-58`). WebKit has no API to hand a port into a page, so the bundle needs an iOS transport.
- **The WebView proxy needs iOS 17.** `WKWebsiteDataStore.proxyConfigurations` and `WKWebsiteDataStore(forIdentifier:)` are iOS 17 APIs, while the app supports iOS 15.0.
- **The App Store raises licensing and review questions** that Android's Play and APK paths did not.
- **iOS suspends a backgrounded app within seconds** and may reclaim its listening sockets, which affects the loopback bridge.

**Status (2026-10-17).** Planned; nothing built. On Android, M3, M5, M6 and M7 passed on the device, M4 is skipped (tokens are not required, A-plan D20) and M8 is partly done (`docs/private-usd-progress.md`). The owner deferred the iOS host on 2026-10-17 and asked for this plan the same day.

**Four files.**

- This file holds the decisions, the architecture, the work, the test strategy and the risks.
- `docs/private-usd-ios-reference.md` is the iOS reference, numbered as this plan points to it:
  - §6 the `WKWebView` host
  - §7 config on iOS
  - §8 iOS integration
  - §12 the Kotlin-to-Swift source map
- `docs/private-usd-ios-progress.md` has one line per task, and the Deviations and Blocked lists.
- `docs/private-usd-ios-device-checklist.md` holds the simulator smoke run, the iPhone rounds and the manual runs.

**Shared with Android and not repeated here:**

- from the Android plan: §3.3 (keys), §3.4 (persistence, apart from the iOS rows in §3.4 below) and §3.5 (invariants);
- from the Android reference: §5 (protocol and state machines), §7.1–§7.2 (pins) and §9 (UI and copy).

**Pointers.**

- "A-plan §3.5" means `docs/private-usd-android-plan.md`.
- "A-ref §5.6" means `docs/private-usd-reference.md`.
- A bare "§6.2" means the iOS reference.

## How to work

- **Checklist.** `docs/private-usd-ios-progress.md` has one line per task. Check a line only when the task is done, and commit the checklist with the work. Log deviations (VI-n) and blockers (BI-n) there.
- **Order.** MI0 is a go/no-go spike. Do not start MI1 until MI0's **Done when** holds, or its fallback is recorded as a deviation. Then work the milestones in order, and the tasks within one in order. **Changed by the owner on 2026-10-17 (VI-1):** Android already works, so MI1–MI3's code goes first, with no simulator or device runs. MI0's checks, the device parts of MI1–MI3 and the Swift test runs are done together in the first session with a phone connected.
- **Milestone done.** A milestone is done when its **Done when** list holds, and all of these pass:
  - `cd rust && cargo test`
  - `fvm flutter analyze`
  - `fvm flutter test`
  - the mobile lane
  - the Swift tests

  Android must keep passing its own gates too: the Kotlin tests always, and, after MI1, an Android M3 device round, because the bundle changes for both platforms. Then commit locally with the milestone in the message. Push only when the owner asks.
- **When to stop and report.** As on Android (A-plan "How to work"), plus at two more points:
  - anything that needs the owner's Apple account: signing, App Store Connect, the App Attest capability
  - any install on a phone that may hold a real wallet (XI11)
- **The owner reviews the UI.** Put the build on the simulator or the iPhone and say what changed and where to look. Do not spend agents on screenshot walkthroughs. Run at most one subagent at a time.
- **Testing** (owner, 2026-10-13, unchanged). End-to-end first. Write unit tests only where they guard funds, keys or the host boundary.
- **Reading.** As on Android: load only a milestone's **Inputs**. Never open `railgun.js`, the `.wasm` files or `package-lock.json`, not even to debug a load failure; use Safari's Web Inspector on a debug build instead.
- **Disk.** The Mac runs near-full. An iOS simulator build needs about 5–6 GB free beyond Xcode's cache (on 2026-10-17 the first build stopped with 1.7 GB left). Build with `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0`, check `df -h /System/Volumes/Data` first, and never delete anything to make room without the owner's OK.

**Commands.**

| What | Command |
|---|---|
| Rust tests | `cd rust && cargo test` (`CARGO_PROFILE_DEV_DEBUG=0`; `rust/target` was deleted on 2026-10-17, so the first run rebuilds it) |
| Dart | `fvm flutter analyze`; `fvm flutter test`; mobile lane `fvm flutter test --tags mobile --run-skipped --dart-define=VIZOR_FORM_FACTOR=mobile` |
| Swift tests | `xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:RunnerTests/RailgunHostTests` (RunnerTests already holds XCTest suites, for example `LedgerMobileHandlerTests.swift`) |
| Kotlin (Android's gate, unchanged) | `cd android && ./gradlew :app:testDebugUnitTest --tests 'com.keplr.vizor.railgun.*'` |
| Bundle | `cd android/railgun-web && npm ci --ignore-scripts && npm run build` (after MI1 it writes the Android assets and the iOS copy) |
| Simulator | `CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 fvm flutter run -d <simulator-udid> --no-pub --dart-define=VIZOR_FORM_FACTOR=mobile --dart-define=VIZOR_PRIVATE_USD_ENABLED=true --dart-define=ZCASH_DEFAULT_NETWORK=test` |
| iPhone | the same with `-d <iphone-udid>`, signed with the owner's team (EI2), and never over a real Vizor install (XI11) |
| Device round | `scripts/private-usd/ios/run_device_round.sh --device <udid>` (written in MI3; options in its header; order in the iOS device checklist) |

**Local stand-ins.** The E1 and E4 stand-ins of A-plan "How to work" are unchanged, and they still keep the branch out of `main`. iOS adds none.

**Path prefixes.** As in the A-plan, plus:

| Prefix | Meaning |
|---|---|
| `kt/` | `android/app/src/main/kotlin/com/keplr/vizor/railgun/`, the Kotlin host this port mirrors |
| `rw/` | `android/railgun-web/`, the page's source and build |
| `sw/` | `ios/Runner/Railgun/` (new): the Swift host and the iOS copy of the bundle |

## 1. Decisions

### 1.1 Decisions for the owner (proposed 2026-10-17)

Each row is a proposal with its reasoning; the owner confirms or overrides it before the milestone that needs it. **Confirmed by the owner on 2026-10-17:** DI2 (hide below iOS 17), DI6 (exclude from backups) and DI7 (the full rebuild, E5's changes included, accepting that the A35's test wallet may rescan once). The others are still proposals.

| # | Proposal | Why, and what follows | Needed by |
|---|---|---|---|
| DI1 | Same v1 scope as Android (A-plan D5): the balance, conversion both ways, refunds and rescue, and send and withdraw. | The Rust engine and the Dart flows are shared, so a smaller scope saves little. The cost is the host, and every feature needs it. | MI1 |
| DI2 | **Private USD on iOS 17 and later only**, by a runtime check. The app keeps its iOS 15.0 deployment target (`ios/Podfile:1`, `project.pbxproj:697`). | The page's proxy (`WKWebsiteDataStore.proxyConfigurations` with Network's `ProxyConfiguration`) and its dedicated, deletable store (`WKWebsiteDataStore(forIdentifier:)`) are iOS 17 APIs. Raising the whole app to iOS 17 would drop iOS 15 and 16 users for one feature. Below 17 the host answers `supported: false` and the feature stays hidden, as it does for a hardware account. | MI2 |
| DI3 | **A licensing review before any external iOS distribution** (external TestFlight testers or the App Store). | The bundle ships GPL-3.0 code (snarkjs 0.7.6, ffjavascript, circomlibjs) and zapp's `AGPL-3.0-only` glue (A-ref §6.1; `rw/package.json`). Android ships it as a separately licensed asset (A-plan D3, X12). The App Store's terms are widely held to conflict with the GPL (the FSF's position; VLC was removed from the App Store in 2011 over it), so the Android reasoning may not carry over. The options: (a) ship as on Android after a legal review; (b) get the authors' permission; (c) replace the GPL prover with a native one (A-plan accepted risks: `Railgun-Community/mopro`), which is new work; (d) keep iOS developer-only (Xcode installs) until it is resolved. Development and internal testing do not wait. | MI8 |
| DI4 | **App Review positioning.** Describe Private USD as a self-custodial wallet feature: atomic swaps with market makers, no custody, no exchange account. Ship it behind the kill switch (A-plan D16), so it can be turned off without a release. | Guideline 3.1.5 governs cryptocurrency apps, and swaps through a privacy protocol invite questions. The kill switch already exists. | MI8 |
| DI5 | **Tokens on iOS use Apple App Attest.** Build them only when a maker requires tokens (A-plan D20: none does today). | iOS has no Keystore attestation, and the issuer must learn to accept App Attest (EI6, a server change in zecSwap). Until then MI7 waits, as Android's M4 does. | MI7 |
| DI6 | **Keep Private USD data out of iCloud and device backups:** the `private_usd_*` directories, the token state and the Railgun page's WebKit store. | Android sets `allowBackup="false"` and excludes `app_webview` (A-ref §8.6), while iOS backs up Application Support by default. The records hold relayer tickets and token blinding secrets (A-plan §3.4, X5), and the page's IndexedDB holds the encrypted Railgun wallet. veylor already excludes its Tor directory on iOS this way (`AppDelegate.swift:427-465`), and the `.tpir` directory too (AGENTS.md). | MI3 |
| DI7 | **One bundle for both platforms**, rebuilt once with E5's changes (A-plan E5: `deleteWallet`, `WALLET_SOURCE = 'vizor'`, `vizor-railgun-init`), an iOS transport and a Safari target. | The page's handshake only works on Android today (§6.2). One rebuild avoids two bundles that drift apart; Android repeats its M3 device round to confirm (UI11). | MI1 |
| DI8 | **Which Apple team and bundle ID ship iOS Private USD.** The project is signed for team `SZTB68DXM4` as `com.keplr.vizor`, with `com.keplr.vizor.SyncWidget` and the app group `group.com.keplr.vizor`. | Device builds, App Attest (keyed to `<TeamID>.<bundle ID>`), the issuer allowlist and App Store Connect all follow from it, as Android's D19 does. If the fork moves to its own ID, the widget extension, the app group and the keychain access groups move with it. | MI2 (device), MI7, MI8 |

**Android decisions that carry over unchanged:** D2 (networks), D3 (the zecSwap crates; the bundle's licensing on iOS is DI3), D5–D18 and D20–D22.

**Android decisions that change on iOS:**

- D1 and D19, the attestation identity: DI5 and DI8.
- D4: the bridge stays, and the WebView side becomes `WKWebsiteDataStore.proxyConfigurations` (XI3).
- D9, foreground only: the rule is unchanged, but iOS suspends a backgrounded app within seconds (XI8, UI16).
- D15: a full reset deletes the page's data store (XI6).

### 1.2 Plan defaults

The research settled these. They are not owner decisions, so the owner may override any of them.

| # | Default | Why |
|---|---|---|
| XI1 | **A native Swift host** in `sw/`. It implements the existing channel contract (A-ref §6.2: `com.zcash.wallet/railgun` and `com.zcash.wallet/railgun/events`) method for method and error code for error code. It adds one method, `supported`, on both platforms. No Flutter WebView plugin. | The host needs a custom-scheme loader, a content rule list, a dedicated data store with a proxy, process-termination callbacks, and a page that lives as long as the engine, outside the widget tree. These are A-plan X1's reasons, on WebKit, and `webview_flutter` exposes none of the first three. Dart's `RailgunHost` interface (`railgun_host_channel.dart:90-110`) stays as it is. |
| XI2 | **The page loads from a custom scheme**, `veylor-railgun://app/index.html`, served by a `WKURLSchemeHandler` from the app bundle's `railgun/` folder. | WebKit cannot intercept `https`, so Android's `WebViewAssetLoader` approach (A-ref §6.4) has no iOS equivalent. `file://` gives an opaque origin with no IndexedDB. Custom schemes are how hybrid shells such as Capacitor host IndexedDB, worker and WASM apps on iOS. **Unverified for this bundle** (UI1); the fallback is in UI1. |
| XI3 | **The proxy is set per data store.** Before each load: `store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: 127.0.0.1:<bridge port>)]`, with `allowFailover = false` (the default, set explicitly). | The Rust bridge (`rust/src/railgun_bridge.rs`) is reused unchanged: SOCKS5 with no authentication, `CONNECT` to allowlisted hostnames on port 443 only. With failover off, a request the proxy refuses fails instead of going direct. **Unverified:** that WebKit hands the proxy hostnames rather than resolved IPs, and that it proxies worker fetches too (UI2). The fallback is an HTTP `CONNECT` mode in the bridge (`ProxyConfiguration(httpCONNECTProxy:)`), which always carries the hostname. |
| XI4 | **Four layers stand in for `shouldInterceptRequest`:** (1) the bridge's host allowlist, which decides what leaves the device; (2) a `WKContentRuleList` that blocks every load except the page's scheme, `blob:`, `data:` and https to the allowlisted hosts; (3) the page's CSP, unchanged, now also sent as a response header by the scheme handler; (4) navigation and window refusal in the delegates. | WebKit has no per-request interception for network schemes. The bridge already refuses everything off its list, so the other three layers are defence in depth. |
| XI5 | **The iOS transport.** Page to host goes through a `WKScriptMessageHandler` named `railgunHost`, accepted only from the main frame, the page world and the page's own origin. Host to page goes through `callAsyncJavaScript("__railgunHostDeliver(m)", arguments: ["m": json], in: nil, in: .page)`. The envelope does not change (A-ref §6.2: `{id, method, params}`, `{id, result}`, `{id, error}`, `{event, data}`). | WebKit has no API to hand a `MessagePort` into a page. Passing the JSON as an argument value, never spliced into script source, means it cannot inject code. The page picks its transport at runtime (`globalThis.webkit?.messageHandlers?.railgunHost`), so Android keeps its port. |
| XI6 | **A dedicated persistent store,** `WKWebsiteDataStore(forIdentifier: RailgunPageHost.storeID)`, holds the page's IndexedDB (`railgun-<network>` and `railgun-artifacts`). `wipe` closes the page, then calls `WKWebsiteDataStore.remove(forIdentifier:)`, retrying while WebKit reports the store in use. | This is the equivalent of Android's `WebStorage.deleteOrigin`, and it keeps the page's data away from any other web content (the app has none today). |
| XI7 | **The page lives in the key window** as a 1×1 view behind the Flutter view. It never takes touches, is hidden from accessibility, and moves with the window. | WebKit treats a `WKWebView` outside a window as hidden, and it throttles hidden pages' timers and may suspend them. The engine polls the chain every 15 s and syncs for up to two hours. **Unverified** which of the two placements hurts (UI3); MI0 measures both before the code settles on one. |
| XI8 | **Foreground only, adapted to iOS.** D9 stays: every key-using step runs only while unlocked and in the foreground. Pause on `hidden`, not on `inactive`: Face ID prompts, the notification shade and the app switcher make the app inactive without leaving it. No `beginBackgroundTask` to stretch a step. | The rule itself is unchanged. iOS suspends a backgrounded app within seconds, so a step cut short by the background must already be safe to resume, and it is (A-plan §3.5 items 2–8). |
| XI9 | **Support is known from the first frame.** `loadAppBootstrap()` (`lib/src/app_bootstrap.dart:254`) asks the host's `supported` once and stores the answer in the bootstrap (as built, only builds with the define and the mobile form factor ask: VI-10; an iOS answer still unknown is asked again after the first frame). `privateUsdAvailableFor` (`private_usd_available_provider.dart:49-59`) and `privateUsdEngineEnabledFor` (`private_usd_engine_provider.dart:60`) accept iOS when it is true. | The router's guards are synchronous (A-plan M5 traps), so a late answer would bounce a cold-start deep link to `/private-usd`. |
| XI10 | **The allowlist stays in Rust** (`deployment::RAILGUN_PAGE_HOSTS`, `rust/src/wallet/private_usd/deployment.rs:45-55`). The Swift copy, like the Kotlin one, is a literal list. The existing Rust pin test (`railgun_bridge.rs:503-526`) is extended to read `sw/RailgunEndpoints.swift` and the iOS copy of `index.html`. | One source, with every copy checked against it. There are four copies today: Rust, Kotlin, the CSP and `scripts/private-usd/check_sockets.py`, which no test checks. |
| XI11 | **Device testing never touches a real Vizor install.** A development build signed with the App Store bundle ID replaces an App Store Vizor and inherits its data container. On a personal iPhone, use a side-by-side bundle ID, the analogue of Android's `com.keplr.vizor.veylor`, and never commit it. | This is the rule the owner set for the OnePlus 15 (`docs/private-usd-progress.md`, handoff), applied to iOS. |
| XI12 | **Inspection in debug only.** `webView.isInspectable` only when `load`'s `debug` is true and the build is a debug build (Swift `#if DEBUG`). | It mirrors Kotlin's `BuildConfig.DEBUG` gate. Safari's Web Inspector on a release build would expose the page's keys. |
| XI13 | **A bundle smoke test in WebKit.** `rw/dev/check-webkit.mjs` runs the built bundle in Playwright's WebKit on macOS with the iOS transport stubbed, beside the existing Chrome `check.mjs`. | It catches a Safari-incompatible bundle before a device build. It is optional if Playwright is unavailable, because the simulator spike covers the same ground. |
| XI14 | **The bridge is restarted after the background** whenever the page is open, then the page's proxy is pointed at the new port (§6.8). | iOS may reclaim a suspended app's listening sockets (Apple TN2277), so a bridge that served before the background may be dead after it (UI16). |

## 2. Owner deliverables

The implementer cannot produce these. Check the row a milestone waits on before starting it.

| # | What | Blocks | Until it arrives | Status |
|---|---|---|---|---|
| EI1 | **A test iPhone on iOS 17 or later**, ideally with no personal Vizor on it. Also, if possible, an older model with 4 GB of RAM (for example an iPhone 12 or 13) to find the memory limit. | MI0's device checks and every device round | The simulator, for function only: no memory, timing or radio evidence | open |
| EI2 | **Signing for device builds**: the Apple Developer team and bundle ID (DI8), with a development certificate and profiles on this Mac for the main app and `SyncWidget`. | Any iPhone install | Simulator only | open |
| EI3 | **The licensing decision (DI3)**, after a legal review. | External TestFlight, the App Store | Internal and developer installs only | open |
| EI4 | **App Store Connect**: the app record, review notes for Private USD (DI4), export compliance, and the privacy manifest's declarations. | MI8 | — | open |
| EI5 | **Shared with Android:** E6 (keyed RPC), E7 (the kill-switch JSON), E8 (the testnet maker, relayer and issuer, and funded testnet ZEC) and N2 (a funded Sepolia Railgun wallet). | The device rounds, as on Android | publicnode only; no flag URL | as on Android |
| EI6 | **Issuer support for App Attest (DI5):** zecSwap's issuer verifies an App Attest attestation (CBOR, the Apple root, the app ID `<TeamID>.<bundle ID>`, the counter) and an assertion for each issuance, with an `issuer.ios` entry in the deployments. | MI7, and only once a maker requires tokens | Not needed while makers don't (A-plan D20) | open |
| EI7 | **Decisions DI2, DI6 and DI8.** | MI2 and MI3 | The defaults stated in §1.1 | open |

## 3. Architecture

### 3.1 What is shared and what is new

Dart owns the UI and the orchestration; Rust owns every key, every swap rule and all swap networking. Both are shared. On iOS, Swift owns the `WKWebView` and, later, App Attest, just as Kotlin owns the WebView and the Keystore on Android.

| Component | Location | iOS status |
|---|---|---|
| zecSwap primitives, the swap engine, the joint-account operations, routed HTTP, the FRB API | `rust/src/wallet/private_usd/`, `rust/src/wallet/routed_http.rs`, `rust/src/api/private_usd.rs` | **Shared and unchanged.** They have no platform gates and are already linked into the iOS library (the simulator's `librust_lib_zcash_wallet.a` holds them). |
| The Railgun bridge | `rust/src/railgun_bridge.rs`; FRB `start_railgun_bridge` and `stop_railgun_bridge` (`rust/src/api/network_privacy.rs:111-126`) | **Shared.** It is ungated and already compiled into the iOS library, but never started there. MI0 may add an HTTP `CONNECT` mode (XI3's fallback). As built, `start()` replaces a bridge whose accept loop has ended instead of handing back its dead port (VI-16). |
| Tor | arti in process (`rust/src/network_privacy.rs`) | **Shared.** It already runs on iOS, and its directory is excluded from backups through `com.zcash.wallet/network_privacy` `excludeFromBackup`. |
| The Dart feature | `lib/src/features/private_usd/` and `lib/src/providers/private_usd_lifecycle_provider.dart` | **Shared**, with two gates widened and a bootstrap field added (XI9). |
| The JS bundle | source in `rw/`; built into the Android assets and (new) `sw/railgun/` | **Rebuilt once for both platforms** (DI7): the iOS transport, a Safari target and E5's changes. |
| The Railgun host | `kt/` on Android; **new in `sw/`** on iOS | **New:** Swift over `WKWebView` (XI1–XI7, XI12, XI14). |
| Attestation | Kotlin and the Keystore (Android M4, skipped) | **New, later:** Swift and App Attest (MI7, DI5). |
| The device round | `scripts/private-usd/` (adb only) and `integration_test/private_usd_device_test.dart` (which fails unless on Android, `:338, 368, 392, 410, 427`) | **A new iOS runner**, and the test's platform checks widened (MI3). |

### 3.2 Data flow

```
 flutter_secure_storage (Keychain) ─► accountProvider.getMnemonicBytesForAccount(uuid)  (null while locked)
 ┌──────────────── Dart (foreground, unlocked only) ─────────────────────────────────────┐
 │ PrivateUsdEngineLoop ── FRB ──► api/private_usd.rs ──► wallet/private_usd/*  (shared)│
 │ RailgunEngine ── MethodChannel com.zcash.wallet/railgun ──► Swift RailgunHostHandler  │
 │      ▲  EventChannel com.zcash.wallet/railgun/events (scan, proof)  │                 │
 └──────┼──────────────────────────────────────────────────────────────┼─────────────────┘
        │                               RailgunPageHost (process singleton, main actor)
        │                               └─ RailgunPage: WKWebView (key window, 1×1, behind Flutter)
        │                                    ├─ veylor-railgun://app/ ◄─ RailgunSchemeHandler (bundle files)
        │                                    ├─ WKContentRuleList (the allowlist)
        │                                    ├─ page → host: webkit.messageHandlers.railgunHost
        │                                    ├─ host → page: callAsyncJavaScript(__railgunHostDeliver)
        │                                    └─ WKWebsiteDataStore(forIdentifier:)
        │                                         IndexedDB railgun-<network>, railgun-artifacts
        │                                         proxyConfigurations = SOCKS5 127.0.0.1:<port>, no failover
        ▼                                                            │ HTTPS, proxied
 wallet/private_usd ──► routed_http ──┬─► Tor (arti, isolated)       ▼
   maker / relayer / issuer / EVM RPC └─► direct (DirectRouteLease) ◄── railgun_bridge 127.0.0.1 SOCKS5
                                                                        (allowlist, 443, same route policy)
```

The forward, reverse and send flows are A-plan §3.2's, unchanged. The forward path never opens the page.

### 3.3 Keys

Unchanged from A-plan §3.3: the BIP-85 chain, the swap keys, the seed-fingerprint check and every known-answer vector. Notes for iOS:

- **The seed bytes** come through the same `getMnemonicBytesForAccount(uuid)`, over flutter_secure_storage on the Keychain. Nothing here is iOS-specific.
- **The Railgun mnemonic's path to JS** gains one hop: Rust, then a Dart `String`, then the method channel, then a Swift `String`, then the `callAsyncJavaScript` arguments. Swift holds it only for the `openWallet` delivery: never log a call's arguments, and drop the references once the delivery returns. This is the same exposure Android accepts.
- **The engine encryption key** stays an `AppSecureStore` app-managed secret (`vizor_railgun_encryption_key_{uuid}`, A-plan §3.3), Keychain-backed with the app's existing accessibility class.
- **The App Attest key (MI7)** is a Secure Enclave key that never leaves the device. Only its `keyId` is stored, in the Keychain as `vizor_privateusd_appattest_<issuer>`. Never delete it on reset (as A-plan X4), and regenerate it only when the issuer refuses it.

### 3.4 Persistence

Every row of A-plan §3.4 applies on iOS. The iOS locations:

| Data | Location on iOS | Backup | Removed by |
|---|---|---|---|
| `swaps.db`, `joint.db` | `<Application Support>/private_usd_<walletDbName>_<network>/` (Dart's `getPrivateUsdDirPath`) | **excluded** (DI6), marked when the directory is created | as on Android |
| Token state (MI7) | `<Application Support>/private_usd_tokens_<network>.json` | **excluded** (DI6) | full reset |
| Engine key, balance cache | the Keychain, through `AppSecureStore` | the Keychain's rules (this-device-only items do not migrate) | as on Android |
| Railgun engine data | `WKWebsiteDataStore(forIdentifier: storeID)`: IndexedDB `railgun-<network>` and `railgun-artifacts`, on disk under `Library/WebKit/` (the exact path is UI6) | **excluded** (DI6), marked after the store's first use | `deleteWallet` (one account); `WKWebsiteDataStore.remove(forIdentifier:)` (full reset) |
| Kill-switch last value | `NSUserDefaults` through `shared_preferences` (`vizor_private_usd_available_v1`) | default | none needed |
| App Attest `keyId` (MI7) | the Keychain | not migrated | never (as X4) |

### 3.5 Invariants

**All 19 invariants of A-plan §3.5 apply unchanged on iOS.** The shared Rust and Dart enforce them. iOS adds these:

20. **The page never loads without its proxy.** Set `proxyConfigurations` to the bridge's port, with failover off, on the store **before** the `WKWebView` is created for each load. If the bridge is not running or the store cannot be configured, `load` fails `UNAVAILABLE`. *Why:* the bridge is the only thing that holds the page to the route policy (A-plan invariant 13).
21. **One page, one port, one bridge.** A route change, the lock, an account switch, the idle close and a reset all close the page **and** stop the bridge, and the next `load` gets a new port. After the background, a bridge that no longer accepts is replaced (XI14). *Why:* pooled connections can outlive a close (Android U19), and a suspended app's listening socket can be reclaimed (UI16).
22. **Only the page's own main frame talks to the host.** Accept a `railgunHost` message only from `frameInfo.isMainFrame`, the page world and the origin `veylor-railgun://app`. Deliver host messages only as `callAsyncJavaScript` arguments. *Why:* the host boundary is the page's key boundary (A-ref §6.4).
23. **Every channel call is answered exactly once.** A page that timed out, closed or was terminated answers its pending calls `CLOSED` or `TIMEOUT`, and a late page reply is dropped. *Why:* a second `FlutterResult` call crashes the app, and a missing one hangs the Dart engine's single-use mutex.
24. **The page is never interactive and never inspectable in a release build.** It takes no touches, is hidden from accessibility, and is inspectable only in debug builds with `debug` set (XI12).
25. **Private USD data stays out of backups** (DI6), marked before the first write that could hold a secret. As built (VI-11), a mark that fails is tried again on the next use and never stops a conversion under way: a weaker backup posture must not cost funds.
26. **A development build never installs over a real wallet** (XI11).

### 3.6 Swift skeleton

Signature level only. The milestone that creates each file is in brackets. The channel contract is A-ref §6.2's, plus `supported` (§6.2 here).

```text
ios/Runner/Railgun/
├── RailgunHostHandler.swift     [MI2] channel binding, com.zcash.wallet/railgun (+ /events); exactly-once replies; BAD_ARGS
├── RailgunPageHost.swift        [MI2] @MainActor process singleton: the current page, the store, the rule list, the event buffer
├── RailgunPage.swift            [MI2] one WKWebView page: load, ready wait, calls with timeouts, delivery, close; its delegates. As built it also holds RailgunChannel, the pending calls and their exactly-once answers (Kotlin's RailgunChannel), which the tests drive without WebKit
├── RailgunSchemeHandler.swift   [MI2] WKURLSchemeHandler for veylor-railgun://app/… from Bundle.main's railgun/
├── RailgunContentRules.swift    [MI2] the WKContentRuleList JSON, built from RailgunEndpoints and compiled once
├── RailgunProtocol.swift        [MI2] wire methods and timeouts, the envelope (JSONSerialization)
├── RailgunEndpoints.swift       [MI2] the nine hosts and POI_NODE_URL (pinned by the Rust test, XI10)
├── RailgunError.swift           [MI2] disconnected | timeout | unavailable | protocol | failed → FlutterError codes
└── railgun/                     [MI1] the built bundle: a folder reference, copied blind, never opened
ios/Runner/PrivateUsdAttestationHandler.swift   [MI7] App Attest on com.zcash.wallet/private_usd_attestation
ios/RunnerTests/RailgunHostTests.swift          [MI2] the envelope, the methods table, the scheme handler, the rules, exactly-once
```

```swift
// RailgunHostHandler.swift
final class RailgunHostHandler: NSObject, FlutterStreamHandler {
  static let channelName = "com.zcash.wallet/railgun"
  static let eventsName = "com.zcash.wallet/railgun/events"
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult)  // supported | load | call | close | wipe | isOpen
}

// RailgunPageHost.swift
@MainActor final class RailgunPageHost {
  static let shared = RailgunPageHost()
  static let storeID: UUID                                      // fixed: the page's only data store
  var isSupported: Bool                                         // if #available(iOS 17, *)
  func load(proxyPort: UInt16, debug: Bool) async throws        // closes any page; proxy before WKWebView; waits for "ready" (30 s)
  func call(_ method: RailgunMethod, paramsJSON: String) async throws -> String  // per-method timeout; a timeout closes the page
  func close()                                                  // idempotent; fails pending calls CLOSED
  func wipe() async throws                                      // close, then WKWebsiteDataStore.remove(forIdentifier:), retried
  var isOpen: Bool { get }
  var onEvent: ((String) -> Void)?                              // raw {"event","data"} JSON; 256 buffered, oldest dropped
}

// RailgunProtocol.swift
enum RailgunMethod: String, CaseIterable {
  case start, openWallet, refresh, deleteWallet, broadcasterFee, transfer, unshield, reverseCost, prepareReverse
  var timeout: TimeInterval { get }  // 120, 60, 7200, 60, 120, 600, 600, 30, 600 (kt/RailgunProtocol.kt; deleteWallet VI-2)
}
enum RailgunMessage {
  case ready
  case event(name: String, rawJSON: String)
  case reply(id: Int64, resultJSON: String)
  case failure(id: Int64, error: RailgunError)
}
```

## 4. Milestones

Each milestone has the same parts as on Android (A-plan §4):

- **Goal**
- **Needs:** the §2 rows it waits on
- **Inputs:** the sections and sources to load, and nothing else
- **Tasks:** numbered as in the checklist
- **Done when:** the completion condition
- **Traps:** only what you would otherwise discover at runtime

Every milestone also follows these rules:

- Gate everything user-visible behind `VIZOR_PRIVATE_USD_ENABLED` (as on Android) **and** the host's `supported` (XI9).
- Android must not change behaviour. Its Kotlin tests pass, and after MI1 its M3 device round passes once more.
- Swift tests go in `ios/RunnerTests/Railgun*Tests.swift`. Mobile UI tests start with `@Tags(['mobile'])`.

### MI0. Spikes (go/no-go)

**Goal.** Prove on the simulator and an iPhone that the bundle runs in a `WKWebView` the way the host needs, and that its traffic can be held to the bridge. Nothing user-visible. The spike code stays on a local branch, `spike/private-usd-ios-m0`, as Android's M0 did.

**Needs.** Nothing for the simulator parts. EI1 and EI2 for the iPhone parts; N2 for the proof.

**Inputs.**
- This file: §1.2, §3.5 (items 20–23).
- iOS reference: §6.
- Android reference: §6.2, §6.4, §6.8.
- Sources: `kt/RailgunWebViewHost.kt`; `rw/src/index.js`, `rw/src/index.html` and `rw/build.mjs`; `rust/src/railgun_bridge.rs`; `lib/railgun_spike_main.dart`.

**Tasks.**

1. **Spike bundle.** Rebuild with `target: ['chrome100', 'safari17']` and a temporary iOS transport in `index.js` (XI5), and copy it to the spike's `sw/railgun/`.
2. **Page shell.** A debug-only Swift harness with the custom-scheme loader (XI2), the iOS transport, a dedicated store (XI6) and the content rules (XI4). On the Dart side, reuse `lib/railgun_spike_main.dart`'s modes (`SPIKE_MODE=direct|tor|flip|fail`, A-plan §10) over a temporary iOS channel.
3. **Capabilities (UI1).** On the simulator and the iPhone, check each of these:
   - ES modules
   - WASM under `'wasm-unsafe-eval'`
   - IndexedDB in the identified store, surviving an app relaunch
   - blob Web Workers (snarkjs)
   - `crypto.getRandomValues`, and `crypto.subtle` if the engine uses it

   Then run `start`, `openWallet` and `refresh` on Sepolia to a full first sync.
4. **Proxy (UI2, UI5, UI7, UI8).** With the bridge on and `proxyConfigurations` set:
   - every page request reaches the bridge as a hostname `CONNECT` on 443 (log hostnames only, in the spike only);
   - with Tor on, the app opens no direct socket (simulator: `lsof -nP -iTCP -a -p <pid>` on the Mac; iPhone: `rvictl` and `tcpdump`, with every remote a Tor relay by onionoo);
   - a route flip and a Tor failure both fail closed;
   - no tunnel outlives the bridge's stop after a page close;
   - the loopback hop raises no Local Network prompt and no ATS error.
5. **Hidden page (UI3).** Time a Sepolia first sync and a refresh with the page detached, then with it in the window at 1×1 behind Flutter. Look for throttled timers or a suspended page, and pick XI7's mode.
6. **Background and the bridge (UI16).** Background the app for 2, 5 and 15 minutes with the page open and the bridge running, then return. Record whether the bridge still accepts connections. If it doesn't, check whether updating the store's `proxyConfigurations` reaches a live page, or whether the page must be reloaded.
7. **Wipe and backups (UI6).** Call `remove(forIdentifier:)` after a close, find the store's directory, and set `isExcludedFromBackup` on it.
8. **Memory and time (UI4).** On the iPhone, and on EI1's older model if there is one: the peak memory of the app and of `com.apple.WebKit.WebContent` during a first sync and during a `transfer` proof (which needs N2).

**Done when (go).**
- The page reaches `ready`, completes a Sepolia first sync, and reports the same `0zk` address as Rust.
- With Tor on, there are zero direct sockets, and every bridge connection is an allowlisted hostname on 443.
- A route change and a Tor failure fail closed.
- After the background, the page works again through a bridge that accepts connections (XI14).
- The wipe removes the store, and the store's directory is excluded from backups.
- A proof completes on the iPhone without the WebContent process being killed.

**No-go fallbacks** (record the choice as a deviation):
- **The custom scheme lacks IndexedDB or workers:** use the https-origin fallback (UI1).
- **WebKit resolves names locally, or bypasses the SOCKS proxy for some requests:** use the HTTP `CONNECT` mode (UI2). If that fails too, use Android D4's fallback on iOS: the page runs only while Tor is off (`privateUsdTorBlockedProvider`, A-ref §8.3).
- **The WebContent process dies while proving on a 4 GB phone:** add a minimum device to the availability check, or accept the failure with a clear error.
- **The page is throttled even inside the window:** accept slower syncs, and keep the screen on (A-plan U21).

**Traps.**

- **A `WKWebView` copies its configuration at init.** Set the store and its proxy, the scheme handler, the message handler and the rule list on the `WKWebViewConfiguration` before `WKWebView(frame:configuration:)`. Changing them afterwards does nothing.
- **`setURLSchemeHandler` raises an exception for schemes WebKit handles itself** (`http`, `https`, `file`, and others): only a custom scheme works.
- **`remove(forIdentifier:)` fails while a web view still uses the store.** Release the `WKWebView` and let WebKit tear its page down before removing the store.
- **The simulator is not evidence for memory, timing or radios.** It runs on the Mac's CPU, RAM and network.
- **Never read `railgun.js` or the `.wasm` files**, not even to debug a load failure; use Safari's Web Inspector on the debug harness.

### MI1. One bundle for both platforms

**Goal.** The production bundle, rebuilt once: E5's changes, the iOS transport, a Safari target and an output for each platform. Android's behaviour does not change.

**Needs.** MI0 go. E2 is not needed (the owner decided on no relicensing on 2026-10-14, Android progress). EI3 does not block building.

**Inputs.**
- iOS reference: §6.1, §6.2.
- Android reference: §6.1, §6.2, §8.7 (the bundle rows).
- Sources: `rw/` (source and build); `kt/RailgunProtocol.kt` and `kt/RailgunEndpoints.kt`; the Kotlin tests `RailgunProtocolTest` and `RailgunBoundaryTest`; `rust/src/railgun_bridge.rs:503-526`.

**Tasks.**

1. `rw/src/index.js`: the transport abstraction (§6.2). Android keeps the `MessagePort` hello (`event.source === null`, exactly one port), and iOS uses `railgunHost` and `__railgunHostDeliver`. `INIT` becomes `vizor-railgun-init` (E5, X2).
2. E5: `deleteWallet` (D15) and `WALLET_SOURCE = 'vizor'` (X2) in `rw/src/wallet.js`. **As built (VI-2):** `deleteWallet {network, mnemonic}` runs on a page of its own with only the database open (no provider, no screening nodes, so no network). It deletes the wallet's encrypted keys (`deleteWalletByID`) and also the notes syncs decrypted for it, which the engine keeps unencrypted. It joins the host method tables with a 1-minute timeout. Since progress VI-17 (BI-3, option (a)) an account deletion calls it, on a fresh page behind an offline bridge.
3. `rw/build.mjs`:
   - `target: ['chrome100', 'safari17']`
   - write the bundle to `android/app/src/main/assets/railgun` as today
   - then copy it, with `COPYING` and `railgun.js.LEGAL.txt`, to `ios/Runner/Railgun/railgun`
4. Kotlin: `RailgunProtocol.INIT`, and the tests that parse `index.js` (`theHelloIsThePageOwn`, `thePageAnswersEveryMethod`). `rw/dev/check.mjs` dispatches the new `INIT` (`:92`), and (as built) ends with a delete check: a fresh page deletes the synced wallet and every one of its IndexedDB keys is gone.
5. The Rust pin test also reads the iOS copy of `index.html` now, and `sw/RailgunEndpoints.swift` once MI2 adds it.
6. Optional (XI13): `rw/dev/check-webkit.mjs` in Playwright's WebKit.
7. An Android device round on the A35 with the new bundle: the A-plan M3 device checks.

**Done when.**
- The bundle builds reproducibly, and the iOS copy is byte-identical to the Android one.
- Chrome's `check.mjs` passes, and so do the Kotlin tests.
- The Android M3 round passes: first sync, address match, no direct sockets with Tor on, the lock closes the page, and the release build loads it.
- On Android, deleting an account deletes its Railgun wallet through `deleteWallet` (U15).

**Traps.**

- **`build.mjs` deletes its output directory** (`:34-35`). The iOS copy must be its own step after the Android write, and both outputs carry `COPYING`.
- **`WALLET_SOURCE` does not affect stored wallets** (settled in MI1, VI-3). The SDK writes it only into the encrypted annotations of the notes a wallet sends. The wallet's id is `sha256(seed ‖ index)` and its record is `['wallet', id]`, so existing Android wallets open as before, with no rescan (UI10).
- **`safari17` changes nothing in the output** (MI1, VI-4): a `chrome100`-only build of the same source is byte-identical. The A35 round still gates the source changes (UI11).
- **Never open `railgun.js`.** Compare builds by size and hash only.

### MI2. The Swift host

**Goal.** A Swift host that answers the Railgun channel contract exactly as Kotlin does, plus `supported` on both platforms.

**Needs.** MI1. EI2 for the device checks.

**Inputs.**
- iOS reference: §6.1–§6.5, §6.8, §8.1, §12 (the Kotlin-to-Swift map).
- Android reference: §6.2 (the contract, the error codes, threading).
- Sources: `kt/*.kt`; `ios/Runner/AppDelegate.swift:53-56` (channel registration) and `:427-465` (`excludeFromBackup`); `lib/src/features/private_usd/services/railgun_host_channel.dart`.

**Tasks.**

1. The `sw/` files of §3.6, with the bundle added as a folder reference to the Runner target's Copy Bundle Resources phase.
2. Register the method and event channels in `AppDelegate.didInitializeImplicitFlutterEngine`, beside the existing channels.
3. `supported` on both platforms:
   - **iOS** answers `#available(iOS 17, *)`.
   - **Android** answers `true` without loading the WebView package (minSdk 30; today's `UNAVAILABLE` from `load` stays for a phone whose WebView lacks `PROXY_OVERRIDE`).
4. Put the page in the window (XI7, following MI0's result), and move it when the scene's window changes. `webViewWebContentProcessDidTerminate` closes the page (`CLOSED`), like Android's `onRenderProcessGone`.
5. The bridge after the background (XI14), following MI0.6's result: on return, if the page is open, check that the bridge accepts connections. If it doesn't, restart the bridge, then either update the proxy or reload the page. **As built without MI0.6 (VI-8):** on iOS, when the app is shown again, Dart probes the bridge's port over loopback (`RailgunEngine.replaceDeadBridge`); one that refuses closes the page and stops the bridge, and the next use reopens the page on a new bridge (invariant 21). Updating a live page's proxy waits for MI0.6.
6. Swift tests:
   - the envelope: every message kind decodes; an unreadable reply fails its call; unknown events are dropped
   - the methods and timeouts table equals Kotlin's
   - the scheme handler serves only `railgun/` files, refuses path traversal, and uses the right MIME types
   - the content rule list compiles and allows exactly the scheme, `blob:`, `data:` and the nine hosts
   - replies stay exactly-once under close, timeout and termination

**Done when.**
- The Swift tests pass.
- On the simulator, Dart's `RailgunHostChannel` drives the Swift host through `load`, `call`, `close`, `wipe` and `isOpen`.
- The Rust pin test covers the Swift allowlist.
- Kotlin's `supported` has a test.

**Traps.**

- **The main actor.** `WKWebView` and `FlutterResult` live on the main thread. The timeouts are `Task`s that hop back to the main actor. The EventChannel sink is called on the main thread only.
- **`callAsyncJavaScript` returns when the delivery function returns,** not when the page's method finishes. Replies come back through `railgunHost` (XI5); never await a page method through `callAsyncJavaScript`.
- **The params splice.** As in Kotlin (`RailgunProtocol.kt:68-83`), `paramsJson` must be exactly one JSON object. Check it with `JSONSerialization` before sending.
- **Results can be any JSON value.** Re-encode a non-object result (a string or a number) exactly, with `.fragmentsAllowed`; this is the iOS form of the `org.json` traps in A-ref §8.7.
- **Never log params or results.** They can hold keyed RPC URLs, the mnemonic and proofs. Errors carry the method name only.
- **The handler must exist before Dart's bootstrap asks.** If the bootstrap's `supported` call meets a `MissingPluginException` on iOS, treat the answer as unknown and ask again after the first frame, rather than hiding the feature for the whole session.
- **The page outlives Flutter engines.** It is a process singleton, like `RailgunHostHandler.Pages` on Android, and the Dart engine already closes a leftover page when it starts (`railgun_engine.dart:163-166`).

### MI3. Availability, balance and lifecycle on iOS

**Goal.** On an iPhone with iOS 17 or later, a software account sees its private USD balance on home and on `/private-usd`, with its receive address, through every lifecycle event. Nothing spends yet.

**Needs.** MI2. EI1 and EI2 for the device round; EI7 (DI6) for the backups.

**Inputs.**
- iOS reference: §8.
- Android reference: §8.3–§8.5.
- Android plan: M3's tasks 5–10 and its Traps.
- Sources: `private_usd_available_provider.dart:26-59`; `private_usd_engine_provider.dart:55-73`; `lib/src/app_bootstrap.dart:254`; `integration_test/private_usd_device_test.dart`; `scripts/private-usd/*`.

**Tasks.**

1. The bootstrap field and the two gates (XI9), with tests for the matrix: iOS 16 hidden, iOS 17 shown, Android unchanged.
2. Backups (DI6): mark each `private_usd_*` directory when `getPrivateUsdDirPath` creates it, and the page's store directory after its first use, through the existing `excludeFromBackup` channel or a sibling of it. **As built (VI-11):** the channel's Dart helper moved to `lib/src/core/storage/device_backup.dart` and `getPrivateUsdDirPath` marks the directory whenever it makes it, and once per process; Swift makes and marks `Library/WebKit` before the store is first used and marks it again after every page load (VI-15), until MI0.7 finds the store's own directory.
3. Check the lifecycle on iOS against §3.5 items 14, 20 and 21: the lock, a route change, an account switch, the idle close, the background with XI14, and a reset (`wipe` removes the store).
4. The device test: replace its five `Platform.isAndroid` failures with a host-support check, and split the socket sampling by platform. **As built (VI-12):** a section the host could not sample comes back `measured: false`; the test then checks the page (`isOpen`) and its bridge (a loopback probe of every bridge port it saw) from the app, the iPhone's sockets are judged by the runner's capture, and on iOS the test removes the page's store itself for a true first sync.
5. `scripts/private-usd/ios/run_device_round.sh`, for the simulator or an iPhone (**as built, the M3 round only**, VI-13; its driver is `scripts/private-usd/ios/device_round_ios.py`):
   - it builds with the three defines and runs the device test;
   - it samples sockets: `lsof` on the Mac for the simulator, `rvictl` and `tcpdump` with sudo for an iPhone, classified like `check_sockets.py --onionoo`;
   - it refuses an iPhone whose installed Vizor is not a development build (XI11).
6. The iOS M3 round: the A-plan M3 device checks, on the iPhone.

**Done when.**
- The availability matrix passes.
- On the iPhone:
  - the strip shows "—" and no page starts before first use
  - `/private-usd` shows the first-sync percentage, then the balance
  - the address equals Rust's
  - with Tor on, there are no direct sockets
  - the lock closes the page and stops the bridge
  - after the background, the page works again (XI14)
  - a reset removes the store
  - a release build loads the page

**Traps.**

- **A first mainnet sync takes about 40 minutes** (A-ref §6.3), with the app in front and the screen on. The existing keep-awake (`com.zcash.wallet/screen_awake`, `AppDelegate.swift:560-584`) covers the key-using steps; extend it to a first sync, as on Android (A-plan U21). **Not done (VI-14):** Android has no first-sync keep-awake (`privateUsdKeepAwakeProvider` covers conversion progress only), and the shared Dart would change Android too; it is the owner's call.
- **`inactive` is not the background** (XI8). Trigger Face ID and pull down the notification shade in the middle of a sync.
- **The simulator shares the Mac's network.** Its socket checks say nothing about the iPhone's radios; the device round is the evidence.

### MI4. Forward conversion on iOS

**Goal.** ZEC to private USD end to end on an iPhone, safe under the lock, the background, a kill, an account switch and a deletion. No new engine code is expected, because the forward path never opens the page.

**Needs.** EI5 (E8) for the device round.

**Inputs.** Android plan: M5's **Done when** and its Traps. iOS device checklist: runs I-1 to I-3.

**Tasks.**

1. The iOS M5 round, the A-plan M5 device checks on the iPhone:
   - a small conversion reaches `Paid`
   - killed mid-confirmation, it resumes
   - locked, it uses no key
   - an account switch keeps it advancing
   - the delete warning shows the count
   - with the kill switch false mid-swap, the swap still finishes
2. The iOS interruptions:
   - swiped away in the app switcher mid-deposit
   - the power button (screen lock) mid-claim
   - an incoming call
   - Low Power Mode

**Done when.** The round passes, and no iOS interruption causes a second deposit.

**Traps.**

- **On iOS, the screen lock sends the app to the background within seconds** (XI8), and the 15-minute auto-lock applies on return (`BackgroundAutoLockHost`).

### MI5. Reverse conversion on iOS

**Goal.** Private USD to ZEC on an iPhone, including cancel, refund and rescue. This is the first time the funding proof runs in WebKit.

**Needs.** EI5 (E8, N2).

**Inputs.** Android plan: M6's **Done when** and its Traps.

**Tasks.**

1. The iOS M6 round:
   - a conversion reaches `COMPLETE`
   - cancelled before funding, one ends `CANCELLED`
   - cancelled after funding, one ends `REFUNDED`
   - a lock during the funding proof pays nothing
2. Measure the `prepareReverse` proof time and peak memory (UI4), and record them in §11.

**Done when.** The round passes, and the measurements are in §11.

**Traps.**

- **A funding proof takes minutes.** The background suspends the page mid-proof. The Dart side already drops a proof that finishes after a lock, the background or an engine change (A-plan M6 traps; Android progress D-72, D-81).

### MI6. Private send and withdraw on iOS

**Goal.** Send to a `0zk` address and withdraw to a `0x` address on an iPhone.

**Needs.** EI5 (N2), and a Sepolia `0x` address of the owner's.

**Inputs.** Android plan: M7's **Done when** and its Traps.

**Tasks.**

1. The iOS M7 round:
   - a send arrives at a second account's `0zk` address
   - a withdrawal lands at the `0x` address
   - killed between proving and the post, it resends the same bytes and never proves again
2. The proof time and memory for `transfer` and `unshield` (UI4).

**Done when.** The round passes, and the measurements are in §11.

### MI7. Tokens and App Attest (deferred)

**Goal.** An iPhone can get and spend issuer tokens. Build this only when a maker requires tokens (A-plan D20) and the issuer supports App Attest (EI6).

**Needs.** N1 (the `zecswap-tokens` decision, as Android's M4), EI6, DI5 and DI8.

**Inputs.**
- iOS reference: §8.6.
- Android reference: §5.9, §6.2 (the attestation channel).
- Android plan: M4.

**Tasks.**

1. Swift `PrivateUsdAttestationHandler` on `com.zcash.wallet/private_usd_attestation`, with iOS methods:
   - `appAttestSupported`
   - `attest {issuerName, clientDataHash}`: generate a key once per issuer, then `attestKey`
   - `assert {issuerName, clientDataHash}`: `generateAssertion`
2. The token protocol's attestation field gains an iOS form (`{platform: "ios", keyId, attestation | assertion}`), agreed with the issuer (EI6). Rust `tokens.rs` builds the message for each platform.
3. Dart: the attestation service picks the platform's method.

**Done when.** On the iPhone, the testnet issuer returns a batch of tokens, and a maker accepts one.

**Traps.**

- **App Attest does not run on the simulator** (`DCAppAttestService.isSupported` is false there), and Apple rate-limits it per device. Test on the iPhone.
- **Generate a key once and keep its `keyId`.** A lost `keyId` means a new key, which the issuer sees as a new device (the reasoning of A-plan X4).
- **The environment entitlement** `com.apple.developer.devicecheck.appattest-environment` is `development` for development builds and `production` for TestFlight and the App Store. The issuer must accept the right one.

### MI8. Hardening and release (App Store)

**Goal.** iOS release readiness on mainnet.

**Needs.** EI3, EI4, E6, E7, and the owner's sign-off.

**Inputs.**
- This file: §3.5, §11.
- Android plan: M8.
- The iOS device checklist.

**Tasks.**

1. Change the route during each phase on iOS: the A-plan M8.1 round, through the iOS runner.
2. The kill switch on iOS: A-plan M8.2's live check.
3. The keyed RPC never appears in a log or a file. Scan the device logs (`log collect`, then the Android scanner) and, in a development build, the app container (downloaded through Xcode), as A-plan M8.3 does.
4. Measurements: the IPA size (the bundle adds about 11.8 MB before compression), the first-sync time, the proof times, and the peak memory of the app and of WebContent. Update §11.
5. The iOS device checklist on mainnet (`docs/private-usd-ios-device-checklist.md`).
6. The release checks:
   - a privacy manifest (`PrivacyInfo.xcprivacy` is absent today; declare the required-reason APIs the app uses)
   - `ITSAppUsesNonExemptEncryption` (absent from `Info.plist` today)
   - the App Review notes (DI4)
   - the licensing decision (DI3)
7. AGENTS.md: the Private USD section gains the iOS host (the host files, `supported`, the custom scheme, the per-store proxy, the backups, the bridge after the background).
8. Turn `VIZOR_PRIVATE_USD_ENABLED` on for iOS release builds only after the owner signs off.

**Done when.** The iOS checklist passes on mainnet with the beta limits (`maxSwapUsdc` 50), DI3 and DI4 are settled, and the owner has signed off.

**Traps.**

- **Build release with all the defines:** `fvm flutter build ipa --release --dart-define=VIZOR_FORM_FACTOR=mobile --dart-define=VIZOR_PRIVATE_USD_ENABLED=true --dart-define-from-file=<rpc json>`.
- **Check that the IPA contains `railgun/`, with `COPYING`.** A folder reference ships as is; a group would not.
- **App Attest uses its production environment** in TestFlight and App Store builds (MI7).
- **The beta limits are enforced by the server.** Test above 50 USDC, and never hard-code the limit.

## 10. Test strategy

The owner's rule holds: end to end first, and unit tests only where they guard funds, keys or the host boundary. The shared Rust and Dart already carry the fund-safety tests (A-plan §10). iOS adds these.

**Unit tests.**

- **Swift** (`ios/RunnerTests/RailgunHostTests.swift`): the envelope, the method table, the scheme handler's path and MIME rules, the content rule list, and exactly-once replies.
- **Rust:** the pin test reads the Swift allowlist and both CSP copies.
- **Dart:** the availability and engine gates on iOS (supported or not), and the bootstrap field.
- **Kotlin:** `supported`.

Skip unit tests for the delegates' glue and the window placement; the device rounds cover them. The existing suites must keep passing: `cargo test`, `fvm flutter analyze`, `fvm flutter test`, the mobile lane and the Kotlin tests.

**End-to-end lanes.**

| Lane | What | When |
|---|---|---|
| Simulator smoke | The host on the iPhone 17 Pro simulator: a first sync on Sepolia, the address match, the lock, the wipe (the iOS checklist) | Every host change |
| iPhone rounds | `scripts/private-usd/ios/run_device_round.sh` with the M3, M5, M6, M7 and M8-route phases | After MI3, MI4, MI5 and MI6; on mainnet in MI8 |
| Android regression | The A35 M3 round | After MI1 (the shared bundle) |
| WebKit bundle smoke (optional) | `rw/dev/check-webkit.mjs` | Bundle changes |

**In every iPhone round:**

- **Tor on, no direct sockets.** An `rvictl` capture, classified against the Tor relay list.
- **Interruptions mid-flow:** the lock, the background, a kill and an account switch.
- **Memory** of the app and of `com.apple.WebKit.WebContent`.
- **The screen kept on.** Set Auto-Lock to "Never" for the round and restore it afterwards (iOS has no `svc power stayon`).
- **No real wallet on the phone** (XI11).

## 11. Risks and unverified items

| # | Item | How and when to verify | Fallback |
|---|---|---|---|
| UI1 | The bundle runs from a custom scheme: ES modules, WASM, IndexedDB persisted in an identified store, blob workers, `crypto` | MI0.3 | An https origin: an in-app loopback HTTPS server for a private name (for example `railgun.veylor.internal`), reached through `ProxyConfiguration.matchDomains`, with its self-signed certificate trusted only for that host in `webView(_:didReceive:completionHandler:)` |
| UI2 | WebKit sends every page request, workers included, to the SOCKS proxy as a hostname, and `allowFailover = false` holds | MI0.4 | An HTTP `CONNECT` mode in the bridge; failing that, the page runs only while Tor is off (Android D4's fallback) |
| UI3 | A hidden or detached `WKWebView` keeps its timers and workers at full speed | MI0.5 | In the window at 1×1, behind Flutter (XI7) |
| UI4 | Memory and proof time in WebKit on an iPhone. On the A35, Android peaked at 446 MB PSS for the app and 382 MB for the renderer (A-plan U14) | MI0.8, MI5, MI6 | A minimum device in the availability check; a clear error |
| UI5 | Pooled connections outlive a close (Android U19) | MI0.4 | Already handled: close, then a new bridge port (invariant 21) |
| UI6 | Where the identified store lives on disk, and that the backup exclusion on it sticks | MI0.7 | Exclude `Library/WebKit` as a whole (the app has no other web content) |
| UI7 | `WKContentRuleList` also applies to worker fetches | MI0.4 | None needed: the bridge's allowlist stays authoritative |
| UI8 | The loopback proxy hop raises no Local Network prompt and no ATS error | MI0.4 | None expected: it is loopback, and the tunnelled bytes are TLS |
| UI9 | A WebContent process killed in the background is reported, and the next use reopens cleanly | MI3 | — |
| UI10 | Changing `WALLET_SOURCE` (X2) keeps existing Android Railgun wallets readable. **Settled in MI1 (VI-3):** it only enters the encrypted annotations of sent notes; the wallet's id and record don't depend on it | MI1 | Keep `'zapp'` (A-plan U17) |
| UI11 | The bundle built with the `safari17` target still runs on the Android WebView. **The target itself is settled (VI-4):** it changes no byte of the output; MI1.7 still checks the source changes | MI1.7 | Separate builds per platform |
| UI12 | App Store acceptance (guideline 3.1.5, a privacy protocol) | MI8 | DI4: the kill switch; developer-only distribution |
| UI13 | GPL and AGPL code in an App Store binary | DI3 (legal review) | DI3's options |
| UI14 | The issuer accepts App Attest | MI7, EI6 | None needed while makers don't require tokens |
| UI15 | The first mainnet sync time on an iPhone (about 40 min on the A35) | MI3, on mainnet | A resumable sync; keep the screen on |
| UI16 | iOS reclaims a suspended app's listening socket (Apple TN2277), so the bridge may be dead after the background | MI0.6 | XI14: restart the bridge on return, then update the proxy or reload the page |

**Accepted risks.** Those of A-plan §11 apply. On iOS, also:

- **The no-auth loopback proxy** is reachable by other apps on the device while the page is open, though on iOS only apps running at that moment can reach it. The destination allowlist limits that to Railgun hosts on port 443, through veylor's route.
- **iOS suspends sooner than Android,** so foreground-only conversions are interrupted more often. The copy already says to keep Veylor open, and the keep-awake holds the screen on during key-using steps.
- **Below iOS 17 the feature is hidden** (DI2).
- **A restarted bridge after the background may cost an in-progress first sync** its unsaved progress if the page has to reload (UI16). A restarted sync resumes faster, because some progress persists (A-plan U21).
