# Private USD (iOS): progress

Tracks `docs/private-usd-ios-plan.md` §4. A task is done only when its line is checked. Each milestone also has a gate line:

- its **Done when** holds;
- `cargo test`, `fvm flutter analyze`, `fvm flutter test`, the mobile lane and the Swift tests pass;
- Android's Kotlin tests still pass;
- its Traps have been re-read against the diff.

## Where things stand (2026-10-17; read this first)

- **MI1 to MI3's code is done** (2026-10-17, VI-1: no simulator or device ran): one bundle for both platforms (MI1), the Swift host (MI2), and the iOS gates, backups, device test and runner (MI3). With `VIZOR_PRIVATE_USD_ENABLED`, an iOS 17 build now shows Private USD to a software account. Android's state is in `docs/private-usd-progress.md`.
- **Owner decisions, 2026-10-17.** All three are shared Dart, so Android gets them too, and none has run on a phone yet.
  - BI-3 resolved as (a): deleting an account deletes its Railgun wallet through a page of its own, best effort, behind a bridge that needs no Tor (VI-17).
  - VI-14 resolved as (a), on both platforms: a Railgun first sync keeps the screen on while the app is in the foreground and unlocked (VI-18).
  - A new request: the Private USD screen draws Railgun's sync as Home's sync line, with the same timing (VI-19).
  - Checks after all three: `fvm flutter analyze` clean; the mobile lane 2,337 passed; the desktop lane 6,061 passed, 166 skipped and 13 failed, the same 13 as before (MI3 evidence); Rust `railgun_bridge` 11 passed, 1 ignored. Kotlin and Swift did not change.
- **The neon floor** never moved, on Home either. The owner chose on 2026-10-17 that it flows only while something scans, and it now does (VI-19).
- **The first device session** owes: MI0's checks, MI1.7 (the A35 round with the new bundle), the Swift tests and the simulator drive of MI2, MI3.3 and MI3.6, then MI4 to MI6.
- **Decisions.** The owner confirmed DI2 (hide below iOS 17), DI6 (exclude from backups) and DI7 (the full rebuild) on 2026-10-17. DI1, DI3–DI5 and DI8 are still proposals; their defaults hold. DI3, the licensing review, blocks only external distribution.
- **Order (owner, 2026-10-17; VI-1).** Code first: MI1–MI3 without any simulator or device run. The MI0 checks, the device parts of MI1–MI3 and the Swift test runs wait for the first session with a phone connected. If space runs short, the Android Rust cache (`build/rust_lib_zcash_wallet/build/aarch64-linux-android`, about 3.5 GB) may be deleted; nothing else.
- **Deliverables.** EI1 (a test iPhone) and EI2 (signing for device builds) gate every device step. The simulator covers MI0's function checks.
- **Simulator.**
  - The iPhone 17 Pro simulator (iOS 26.5), UDID `2F355481-7C3B-47C9-ACBD-A9E08938C039`, already runs the app with the neon redesign: testnet, with a wallet created on 2026-10-17.
  - Private USD was hidden there, as the platform gate was Android-only. Since MI3 a build with the define shows it on iOS 17 and later; nothing has run on it yet (VI-1).
- **No iPhone yet.**
- **Disk.** About 10 GB was free after `rust/target` was deleted on 2026-10-17, and an iOS simulator build needs 5–6 GB of it. Check before each build. After MI1–MI3's builds (the bundle's `node_modules`, `rust/target` for the bridge tests, the simulator build in DerivedData) about 20 GB was free; after VI-17's bridge tests grew `rust/target`, about 11 GB.
- **Next.** The first device session (above), where VI-17 to VI-19 are checked too (on the A35 as well). The owner rules on DI8 before the first device build.

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
- [x] MI1.2 E5: `deleteWallet`, `WALLET_SOURCE = 'vizor'` (the page side; since VI-17 an account deletion calls it)
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

- [x] MI2.1 The `ios/Runner/Railgun/` files and the folder reference (the project file edited by hand: VI-5)
- [x] MI2.2 Channel registration in `AppDelegate`
- [x] MI2.3 `supported` on iOS and Android (with a Kotlin test)
- [x] MI2.4 The page in the window; handling a terminated page (VI-7)
- [x] MI2.5 The bridge after the background (XI14): the reload path; the live proxy update waits for MI0.6 (VI-8)
- [x] MI2.6 Swift tests (`RailgunHostTests.swift`): written and compiled; they run in the first device session (VI-1)

MI2 evidence (2026-10-17, code only):

- `xcodebuild build-for-testing -workspace ios/Runner.xcworkspace -scheme Runner -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` succeeds: the eight host files and `RailgunHostTests.swift` compile with no warning, and `Runner.app/railgun/` holds the bundle byte for byte, `COPYING` included. Nothing was booted and no test ran.
- The first compile stopped at `[CP] Check Pods Manifest.lock`: the untracked `ios/Pods/Manifest.lock` said `COCOAPODS: 1.15.2` (a local `pod install`), the committed `Podfile.lock` 1.16.2. Only that line of the untracked manifest was aligned; no tracked file changed.
- Kotlin railgun tests: 22 of 22 pass (one new, `RailgunHostHandlerTest`). Rust `railgun_bridge`: 8 pass, 1 ignored; the pin test now reads `RailgunEndpoints.swift` too.
- Dart: `railgun_engine_test.dart`, 8 of 8 (four new: the bridge after the background).
- Invariant 20 holds in Swift too: `load` refuses with `UNAVAILABLE` unless the bridge's port accepts a loopback connection, before the store's proxy is set and the web view made (`RailgunPageHost.loopbackAccepts`, with a Swift test).
- [ ] MI2 gate

## MI3. Availability, balance and lifecycle on iOS

- [x] MI3.1 The bootstrap's `hostSupported`; both gates; the availability-matrix tests (VI-10)
- [x] MI3.2 Backup exclusion (DI6): the `private_usd_*` directories, and `Library/WebKit` after each page load (VI-11)
- [ ] MI3.3 Lifecycle checks: lock, route change, account switch, idle close, background, reset: deferred to the first device session (VI-1)
- [x] MI3.4 The device test's platform checks (VI-12)
- [x] MI3.5 `scripts/private-usd/ios/run_device_round.sh`, the M3 round (VI-13)
- [ ] MI3.6 iOS M3 device round (iPhone): deferred to the first device session (VI-1)

MI3 evidence (2026-10-17, code only):

- The gates: `privateUsdAvailableFor` and `privateUsdEngineEnabledFor` take the host's answer through `privateUsdPlatformHostsPage` (Android, or iOS with `supported`). The matrix passes: iOS 16 hidden, iOS 17 shown, Android unchanged whatever its answer, desktop platforms hidden (`private_usd_available_provider_test.dart`, 11 of 11, seven new, with the bootstrap's answer, the ask after the first frame, and the query's three outcomes).
- Backups: `private_usd_dir_backup_test.dart`, 2 of 2 (the mark when the directory is made, once per process, again after a reset, and a failed mark that never blocks).
- The device test and the iOS runner are analyzer- and shellcheck-clean; the driver's helpers were checked on sample data. Nothing ran on a simulator or an iPhone.
- The Swift side of MI3.2 (`excludeWebDataFromBackup`) is in MI2's commit.
- Full lanes after MI3: `fvm flutter analyze` clean; the mobile lane 2,328 passed; the desktop lane 6,043 passed, 165 skipped and 13 failed, the 13 that predate this work, none in Private USD or the files these milestones touch: `app_main_sidebar_test` (the error tooltip), `ironwood_migration_flow_screen_test` (two private-status cases), `lost_password_screen_test` (the Gift Card refusal), `payment_link_ledger_ui_test` (the entry hint, dark and light), `settings_seed_phrase_screen_test` (four incoming-link cases), `figma_compare_test` (`ironwood-migration-complete`) and `settings_use_cases_test` (the endpoint header, the wallet-link CTA).
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

  `check.mjs` gained a delete check, which passes in Chrome. Dart does not call `deleteWallet` yet: when and how is the owner's choice (BI-3; resolved 2026-10-17, VI-17). Plan MI1 tasks 2 and 4 and §3.6, iOS reference §6.2 and §6.5, the Android reference's §6.2 method table and the A-plan's E5 and U15 rows updated.
- **VI-3 (MI1.2): `WALLET_SOURCE` does not touch stored wallets.** The plan left it unverified (UI10, A-plan U17) and the owner accepted that the A35's wallet might rescan. The SDK writes the wallet source only into the encrypted annotations of the notes a wallet sends (AES under the sender's viewing key). The wallet's id is `sha256(seed ‖ index)` and its record `['wallet', id]`, neither of which depends on it, so existing wallets open unchanged and nothing rescans. Plan MI1 Traps and UI10, and the A-plan's U17 row, updated.
- **VI-4 (MI1.3): the `safari17` target changes nothing.** The plan expected it might change esbuild's lowering for Android (UI11). A `chrome100`-only build of the same source is byte-identical to the `chrome100` + `safari17` build, so Android gets exactly the code it would get without the Safari target. The A35 round (MI1.7) still gates the source changes. Plan MI1 Traps and UI11 updated.
- **VI-5 (MI2.1): the project file is edited by hand.** The brief was to add the files with the `xcodeproj` gem. The only copies here (1.24.0, system and CocoaPods' own) cannot open the project: its SyncWidget folder is a `PBXFileSystemSynchronizedRootGroup`, which xcodeproj supports from 1.25. So `project.pbxproj` gained its entries by a script with asserted anchors, using readable ids in the repository's style (`RAILGUNIOS…`, as `LEDGERIOS…` and `OUTBOX…`): the `Railgun` group with the eight sources and the `railgun` folder reference (Copy Bundle Resources), and `RailgunHostTests.swift` in RunnerTests. `plutil -lint` and `xcodebuild -list` read it, and the build uses it. No plan text changes.
- **VI-6 (MI2.1): no console hook.** Reference §12 mapped Kotlin's `Chrome` to "a page console hook, as `log` events in debug", while §6.4 rules out injecting any script, and WebKit has no console callback. No script is injected: the page's console never reaches the host, the engine's own `log` events still arrive from a page loaded with `debug`, and a debug build reads the console in Safari's Web Inspector. Reference §6.4 and §12 updated.
- **VI-7 (MI2.4): where the page sits.** Reference §6.3 said "the key window's root view at index 0, behind the Flutter view". A subview of the Flutter view is drawn over Flutter's own content, not behind it, so the page is inserted into the key window itself at index 0, beneath the root view controller's view, which covers it. It moves when another window becomes key, and a memory warning closes an idle page. Reference §6.3 updated.
- **VI-8 (MI2.5): the bridge after the background, without MI0.6.** The plan left the choice between updating a live page's proxy and reloading it to MI0.6. Built now, the reload path, which needs nothing unverified: on iOS, when the app is shown again, Dart probes the bridge's port over loopback; a refusal closes the page and stops the bridge, and the next use reopens the page on a new bridge (invariant 21). A page interrupted mid-sync starts it again (plan §11's accepted risk). Plan MI2.5 and reference §6.8 updated.
- **VI-9 (MI2.1): the delivery returns a value.** The plan's delivery is `callAsyncJavaScript("__railgunHostDeliver(m)", …)`. A body that returns nothing may reach the completion as an unsupported result, so the body is `__railgunHostDeliver(m); return true;`, and a delivery that fails fails its call `CLOSED` (Kotlin's failed post). Reference §6.2 updated.
- **VI-10 (MI3.1): only builds with Private USD ask.** The plan had `loadAppBootstrap()` ask `supported` once. As built, only builds with `VIZOR_PRIVATE_USD_ENABLED` and the mobile form factor ask (the gates are constant `false` in the rest), so desktop and builds without the define make no channel call. An iOS answer still unknown (`MissingPluginException`) counts as no until `railgunHostSupportedProvider` asks again after the first frame. Plan XI9 and reference §8.2 updated.
- **VI-11 (MI3.2): how the backup marks are made.** The plan named the `excludeFromBackup` channel or a twin. As built, its Dart helper moved from `network_privacy_provider.dart` to `lib/src/core/storage/device_backup.dart`, unchanged, and `getPrivateUsdDirPath` uses it: it marks the directory whenever it makes it, and once per process for one made earlier (the mark goes with the directory). A failed mark is tried again on the next call and never stops the call: a conversion under way must not stall for a weaker backup posture, so invariant 25's "before the first write" holds whenever the mark can be set. Swift marks all of `Library/WebKit` after every page load, before any call can bring the wallet in, until MI0.7 finds the store's own directory. Plan MI3.2 and invariant 25, and reference §8.4, updated.
- **VI-12 (MI3.4): how the device test splits by platform.** The plan said to split the socket sampling by platform. As built: the five Android-only failures are one host-support check (`_requireRailgunHost`); a checkpoint section the host could not sample comes back `measured: false`, and the test then asks the page host whether the page runs and probes from the app every bridge port it has seen (the engine's `bridgePort`); per-sample socket counts that an iPhone's host can't take are left to the runner's capture and noted as unsampled in the results; on iOS the test removes the page's store itself for a true first sync (a Mac can't reach an iPhone's files), and it posts `tor-off` events so the capture knows its Tor windows. Android's checkpoints are all measured, so its round is unchanged. Plan MI3.4 updated.
- **VI-13 (MI3.5): the runner covers the M3 round.** The device checklist expected Android's flags. As built, `scripts/private-usd/ios/run_device_round.sh` runs the M3 round on a booted simulator (`--simulator`) or an iPhone (`--device`), with its driver `scripts/private-usd/ios/device_round_ios.py`; `--m5` to `--m8-route` and `--keyed-rpc` stop with a message. The M5 and M7 rounds kill the app between two `flutter test` runs, and AGENTS.md notes that on the simulator each run reinstalls the app, so they wait for MI4 to MI6. An iPhone reaches the driver over the local network, under a random token (iOS has no `adb reverse`); its sockets are judged from an rvictl capture, which sees the whole iPhone, so only connections to a Railgun host or DNS queries for one while Tor was on fail the round, and other remotes are listed for review. The release-build check, the screen and an iPhone's memory stay manual. Plan MI3.5 and the device checklist updated.
- **VI-14 (MI3 trap): no first-sync keep-awake yet.** The plan's MI3 trap says to extend the keep-awake to a first sync "as on Android". Android has none: `privateUsdKeepAwakeProvider` covers a conversion's progress only, and the Dart is shared, so adding it would change Android too. Left for the owner; the device checklist already keeps the screen on through Auto-Lock for rounds. Plan MI3 Traps updated. (Resolved 2026-10-17: VI-18.)
- **VI-15 (review of MI3.2): the web data is out of backups before its first use.** As first built (VI-11), Swift marked `Library/WebKit` only after a load, and only if the directory existed. If WebKit makes it lazily, on the first IndexedDB open during `start`, `openWallet` or `refresh`, the wallet's data, the unencrypted notes included (VI-2), would stay unmarked until the next load, and the page stays open in the background, within reach of a nightly iCloud backup. Now `load` makes `Library/WebKit` if it is missing and marks it before the store is first used (a mark on a directory covers what is created inside it later), and marks it again after the load in case WebKit made it anew. A failed mark still never blocks the load. `excludeWebDataFromBackup(library:)` takes the library URL, and a Swift test pins it on a temporary directory (compiled only, VI-1). Plan MI3.2 and reference §6.5 and §8.4 updated.
- **VI-16 (review of MI2.5): the bridge replaces itself when its accept loop has ended.** The plan reused the Rust bridge unchanged. Its `start()` handed back the running bridge's port whenever one was recorded, even after `run`'s accept loop had broken on an accept error, which is what an iOS socket reclaim causes (UI16). Dart's `replaceDeadBridge` and `_open`'s cleanup recover from that already; now `start()` also replaces a bridge whose task has finished instead of returning a port nothing listens on, with a Rust test. On Android this changes only that failure case. Plan §3.1 and reference §6.8 updated.
- **VI-17 (owner, 2026-10-17: BI-3 resolved as (a)): deleting an account deletes its Railgun wallet through a page.** BI-3 left when Dart calls `deleteWallet` to the owner, who chose (a). As built, in the shared Dart, so on Android too:
  - **Which accounts.** Only one with a Railgun engine key, which the page's first opening of its wallet makes: an account that used Private USD. An account without one derives nothing and loads no page.
  - **Before the Rust account delete,** its Railgun mnemonic is derived through the path that checks the seed fingerprint (Rust can't derive it afterwards). It is a Dart string, which can't be zeroed, so only its reference is held, until the page call, and it is dropped if the deletion stops. Nothing logs it.
  - **After the Rust delete,** as the deletion's last step (the account list already saved), the engine (`RailgunEngine.deleteWallet`) closes any open page, starts a bridge, loads a fresh page on it, calls `deleteWallet {network, mnemonic}`, then closes the page and stops the bridge. It is one use of the engine, run while the lifecycle fence still holds it drained, so it never runs beside another page; the engine is built for it if no use built one yet. The drain-first, clean-up-after-the-Rust-delete order (A-plan invariant 15) holds, and the full reset is unchanged.
  - **No Tor wait.** The bridge is a new offline kind (`start_offline_railgun_bridge`): it refuses every `CONNECT`, the page's own hosts included, so it needs no route and starts at once even while Tor bootstraps. The page still loads only behind its proxy (invariant 20) and nothing can leave. A bridge keeps its kind; asking for the other stops it first. Rust tests cover both.
  - **Best effort, bounded.** A seed that can't be read (locked), a derivation or page that fails, or the 2-minute bound is logged by type only and never fails the deletion; the wallet then stays, unreadable without its deleted key, until a reset, as before.
  - **A race fixed on the way.** A page's bridge now starts only once every close under way has stopped its own; before, a close still stopping the old bridge could stop the new one (invariant 21). The deletion builds the engine during the drain, whose close runs beside it, which is where it showed.
  - **Tests.** Dart, with a fake host: the engine's deletion (the offline bridge, an open page closed first, while drained, a page failure, a close meanwhile, the timeout) and the account deletion (derive, then the Rust delete, then the page delete; no page for an account that never used Private USD; a failed derivation or page never blocks). Rust: the offline bridge refuses every `CONNECT` without waiting for Tor, and asking for the other kind replaces the bridge.

  Plan MI1 task 2, iOS reference §6.5, the Android reference's §6.3, §6.8 and §8.4, and the A-plan's E5 row updated.
- **VI-18 (owner, 2026-10-17: VI-14 resolved as (a), on both platforms): a Railgun first sync keeps the screen on.** VI-14 left the MI3 trap's keep-awake to the owner, because the Dart is shared and Android had none either. As built:
  - **What counts.** A first sync is the sync of a wallet that never completed one: the balance notifier starts a refresh with no balance shown, cached or synced (the same test that gives it the 2-hour first-sync timeout). It registers the sync in `privateUsdFirstSyncsProvider` and ends it when the sync completes or fails (the timeout counts as failing), or as soon as a cached balance shows the wallet synced before. The sync goes on in the page whichever screen started it, so leaving the Private USD screen does not let go.
  - **The rule.** `privateUsdFirstSyncKeepAwakeProvider` is true while one runs and the wallet is unlocked. `privateUsdKeepAwakeProvider` ORs it with the conversion progress (A-plan X8) into the one native flag `SyncKeepAwakeNativeHost` owns, which lets go in the background and takes it again in the foreground. A lock lets go at once, and the lock closes the page, which ends the sync.
  - **Tests.** The provider: on through a first sync until it completes; a failure and a lock let go; a refresh of a wallet that synced before keeps nothing on; conversion progress as before. The host: on in the foreground, off in the background and when the sync ends.

  Plan MI3 Traps, iOS reference §8.5, the iOS device checklist's screen note, the A-plan's X8 and U21 rows and the Android reference's §9.5 updated.
- **VI-19 (owner request, 2026-10-17): Railgun's sync on the Private USD screen, drawn like Home's.** New: the plans had the screen show the sync as text (the first-load percentage, "Updating…", the errors) beside its refresh button. As built, with Home's look and the same timing (no auto-sync; Railgun still syncs on open and on refresh), shared Dart, so on both platforms:
  - **One line, two sources.** `neon_sync_backdrop.dart` now splits what a line shows (`NeonSyncLine`) from how it is layered (`NeonSyncLineLayer`, Home's two layers), keeps Home's readouts in one place (`NeonSyncReadout`, sentence case and drawn uppercase), and makes Home's block backing public as `NeonSyncOcclude`. Home's `NeonSyncBackdrop` builds its line from the Zcash sync exactly as before. `privateUsdSyncLine` builds one from the balance state, and the screen layers it as Home does: the Tron floor and the synced line behind, the blocks backed solid so that line shows only in the gaps, and the climbing line with its readout in front, ignoring touches. The painter is shared, not copied.
  - **The states.** A first sync (no balance yet) climbs with its percentage (`SYNC n%`, on a stub at 0% before the engine's first report), or reads `TOR …` while Tor is the route and still connecting: the page waits for its bridge, which waits for Tor. A wallet that synced before stays `SYNCED` through a refresh, full height and behind the content, and only its floor flows (the view gained `floorFlows`). This is Home's 20-block rule; Railgun has no block gap to read, so any wallet that synced before counts. A failure reads `SYNC FAILED`, or `TOR OFFLINE` when Tor failed, as on Home.
  - **The card.** The percentage and "Updating…" left it. It keeps what a first load takes (the first-load line without its percentage), the balance's time and the errors. Screen readers hear the card's old text from the line's live region (the first-load progress, "Updating…", the time or the failure), and the card's own lines are excluded, so nothing is read twice. Reduced motion holds the floor still, as on Home.
  - **The device test** reads a first sync's percentages from the line's readout. The Android round's release check (`scripts/private-usd/device_round.py`) still finds the status and the errors, now through the line's label.
  - **Tests.** Mobile-lane widget tests for each state: the layers, the occluded blocks, the semantics, and a tap through the climbing line. The screen test that asserted the percentage text now asserts the readout. A widget-test capture of the first-load and default scenarios looked right.
  - **Found on the way: the floor never moved, on Home either.** `_syncFlow` called `repeat()` and then set `value`, and setting `value` stops an `AnimationController`, so no frame was ever scheduled: the floor and the line's pulse stood still. A floor that always flows would repaint a full-screen layer every frame while Home or this screen shows, and hang every widget test that settles on it.
  - **The owner's choice (2026-10-17): it flows only while something scans.** Idle, the floor stands still and nothing is drawn. While a sync climbs, the floor flows (one cycle in 2.25 s, the old scanning speed) and the pulse climbs the line; while a synced Private USD wallet refreshes, the floor flows under the still line. A layer moves only when it draws a moving part (the readout-only front layer of a synced line never ticks), `repeat()` resumes from where it stopped, and reduced motion still holds everything still. A widget test pins each case.

  Android reference §9.4 S2 and AGENTS.md's "Sync line" updated.

## Blocked

- **BI-1. A test iPhone (EI1) and signing for device builds (EI2).** Every device step waits on them. The simulator covers MI0.2 to MI0.7's function checks. MI0.6 and MI0.8 need the iPhone for real numbers.
- **BI-2. The licensing decision (EI3, DI3).** It blocks external TestFlight and the App Store; nothing before MI8 waits on it.
- **BI-3. Resolved 2026-10-17 (owner): option (a), as built in VI-17.** The question was when Dart deletes an account's Railgun wallet: (a) at deletion, through a page; (b) deferred to the page's next use; (c) never, leaving it until a reset.
