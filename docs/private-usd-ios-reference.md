# Private USD on iOS: reference

Reference material for `docs/private-usd-ios-plan.md`, numbered as the plan points to it:

- §6 the Railgun host on iOS
- §7 config on iOS
- §8 iOS integration
- §12 the source map from Kotlin to Swift

§5 (protocol and state machines) and §9 (UI and copy) are the Android reference's (`docs/private-usd-reference.md`, "A-ref" below), unchanged: the engine, the flows and the screens are shared.

Open a section only when a milestone's **Inputs** names it. Line numbers into veylor are at `feature/private-usd-android` `ef7b2e067`; confirm one before relying on it. The plan's §1 decisions win over anything here.

Prefixes:

- `kt/` is `android/app/src/main/kotlin/com/keplr/vizor/railgun/`
- `rw/` is `android/railgun-web/`
- `sw/` is `ios/Runner/Railgun/`

## 6. Railgun host on iOS

Port `kt/` to Swift (plan XI1). Read on 2026-10-17 from `kt/` at `ef7b2e067`.

### 6.1 Files, bundle and build

**Swift files.** All new, in `sw/`, about 900 lines in all.

| File | Job | Kotlin counterpart |
|---|---|---|
| `RailgunHostHandler.swift` | the method and event channels; exactly-once replies; argument checks | `RailgunHostHandler.kt:22-152` |
| `RailgunPageHost.swift` | the process singleton: the current page, the store, the rule list, the event buffer | `RailgunHostHandler.Pages` (`:138-151`) and `RailgunWebViewHost.kt:57-148` |
| `RailgunPage.swift` | one page: load, the ready wait, calls, delivery, close; its `WKNavigationDelegate`, `WKUIDelegate` and `WKScriptMessageHandler` | `RailgunWebViewHost.Page` (`:150-233`), `Client` (`:235-299`), `Chrome` (`:301-312`), `RailgunChannel.kt` |
| `RailgunSchemeHandler.swift` | serves `veylor-railgun://app/…` from the bundle | `OwnAssets` (`:315-321`) and `WebViewAssetLoader` |
| `RailgunContentRules.swift` | the allowlist as a `WKContentRuleList` | `RailgunRequests.route` (`:359-371`) |
| `RailgunProtocol.swift` | wire methods, timeouts, the envelope | `RailgunProtocol.kt:12-128` |
| `RailgunEndpoints.swift` | the ten hosts | `RailgunEndpoints.kt:9-26` |
| `RailgunError.swift` | error kinds, mapped to `FlutterError` codes | `RailgunException.kt` and `RailgunHostHandler.kt:123-134` |

**The bundle on iOS.** It is built once (plan DI7, MI1) by `rw/build.mjs`. The build writes `android/app/src/main/assets/railgun/`, then copies the same files to `sw/railgun/`. Today's Android build:

| File | Size (bytes) |
|---|---:|
| `railgun.js` | 9,767,606 |
| `poseidon_hash_wasm_bg.wasm` | 1,936,566 |
| `curve25519_scalarmult_wasm_bg.wasm` | 29,793 |
| `COPYING` | 35,147 |
| `railgun.js.LEGAL.txt` | 4,586 |
| `index.html` | 617 |

The MI1 rebuild changes these sizes; record the new ones in the progress doc. As built, only `railgun.js` changed (9,768,846 bytes), and the build reproduces byte for byte.

- **In Xcode.** Add `ios/Runner/Railgun/railgun` once, as a **folder reference** (a blue folder), to the Runner target's Copy Bundle Resources phase. The files then ship under `Runner.app/railgun/` with their names, and a rebuild needs no project edit. As a group (a yellow folder) every file would need its own project entry.
- **Not a Flutter asset**, exactly as on Android: never add it to `pubspec.yaml`.
- **Build changes** (`rw/build.mjs`):
  - `target: ['chrome100', 'safari17']`, so esbuild lowers the code for both engines (today: `chrome100` only, `:16-58`)
  - after the Android write (`:16-65`), `rm -rf` the iOS directory and copy the output, `COPYING` included
- **Licences** as in A-ref §6.1. The GPL-3.0 text ships beside the bundle on iOS too, as `Runner.app/railgun/COPYING`. Whether that is enough on the App Store is plan DI3.

### 6.2 Wire protocol on iOS

**The envelope** is unchanged from A-ref §6.2:

- request `{id, method, params}`
- reply `{id, result}`
- failure `{id, error: {code, message}}`
- event `{event, data}`

Amounts are decimal strings, unknown events are dropped, and an unreadable reply fails its call.

**The transport.**

| Step | Android | iOS |
|---|---|---|
| Hello | The host posts `WebMessage(INIT, [port])` to the page origin. The page takes the first port with `event.source === null` (`rw/src/index.js:53-58`). | At startup the page finds `globalThis.webkit.messageHandlers.railgunHost` and posts `{event: "ready", data: null}` through it, once. |
| Page to host | `port.postMessage(json)` | `webkit.messageHandlers.railgunHost.postMessage(json)`, as a string |
| Host to page | `port.postMessage(json)` | `webView.callAsyncJavaScript("__railgunHostDeliver(m)", arguments: ["m": json], in: nil, in: .page)`. As built (plan VI-9) the body is `__railgunHostDeliver(m); return true;`, so the completion always gets a value it can carry, and a delivery that fails fails its call `closed`. |

**The page side** (`rw/src/index.js`, MI1). A sketch; the real code keeps `index.js`'s dispatch (`:8-58`):

```js
const INIT = 'vizor-railgun-init';           // E5 (as built in MI1)

function connect(onMessage) {
  const ios = globalThis.webkit?.messageHandlers?.railgunHost;
  if (ios) {
    // The host delivers with callAsyncJavaScript arguments, never by
    // splicing JSON into script source. Defined once; it cannot be replaced.
    Object.defineProperty(globalThis, '__railgunHostDeliver', {
      value: (json) => onMessage(json), writable: false, configurable: false,
    });
    const send = (message) => ios.postMessage(JSON.stringify(message));
    send({ event: 'ready', data: null });
    return send;
  }
  // Android: the first port the host hands over (event.source === null).
  // …today's hello, unchanged…
}
```

**Host checks** on every `railgunHost` message (`userContentController(_:didReceive:)`). Drop anything that fails one:

- `message.frameInfo.isMainFrame`
- `message.frameInfo.securityOrigin.protocol == "veylor-railgun"` and `.host == "app"`
- `message.world == .page`
- `message.body` is a `String` (a JSON text); anything else is unreadable

**Ready.**

- After `webView.load(URLRequest(url: veylor-railgun://app/index.html))`, wait up to 30 s for `ready` (`LOAD_TIMEOUT`, as Kotlin `:175, :327`). A timeout fails `load` with `timeout` and closes the page.
- If one of the page's own files fails to load, close the page at once (`didFailProvisionalNavigation` and `didFail`), as Kotlin does (`:291-298`).

**The channel contract.**

- It is identical to the tables in A-ref §6.2: the methods `load`, `call`, `close`, `wipe` and `isOpen`; the codes `closed`, `timeout`, `unavailable`, `protocol`, `failed` and `bad_args`.
- Events are forwarded raw, and `log` only when `debug` is set.
- The method table and its timeouts are `kt/RailgunProtocol.kt:16-26`:
  - `start` 2 min
  - `openWallet` 1 min
  - `refresh` 2 h
  - `broadcasterFee` 2 min
  - `transfer` 10 min
  - `unshield` 10 min
  - `reverseCost` 30 s
  - `prepareReverse` 10 min
  - `deleteWallet` 1 min (new in MI1, VI-2; local only)

New on both platforms:

| Method | Args | Result | Notes |
|---|---|---|---|
| `supported` | — | `bool` | iOS answers `#available(iOS 17, *)`. Android answers `true` without loading the WebView package (minSdk 30); a phone whose WebView lacks `PROXY_OVERRIDE` still fails `load` with `unavailable`, as today. Dart asks once, from the bootstrap (plan XI9). |

**`load {proxyPort, debug}` on iOS**, in order:

1. Close any open page.
2. Require `1 ≤ proxyPort ≤ 65535` (else `bad_args`) and `supported` (else `unavailable`).
3. Set the store's proxy (§6.8).
4. Build the configuration: the store, the scheme handler, the message handler, the rule list and the preferences (§6.4).
5. Create the `WKWebView`, put it in the window (§6.3) and load the page.
6. Wait for `ready` and return `nil`.

**Threading.**

- Everything runs on the main actor.
- Each `call` registers a continuation under its `id`, plus a timeout `Task`. The task sleeps for the method's timeout, then fails the call `timeout` and closes the page, as `RailgunChannel.kt:33-47` does.
- `FlutterResult` is called exactly once per call; a per-call `replied` flag guards it (plan invariant 23).
- The EventChannel sink is called on the main thread only. With no listener, events go into a ring buffer of 256 that drops the oldest first (Kotlin `RailgunWebViewHost.kt:60-67`).

### 6.3 Lifecycle on iOS

- **Open, close, wipe and `isOpen`** behave as in Kotlin (A-ref §6.2; `kt/RailgunWebViewHost.kt:84-148`). The wipe is §6.5.
- **Where the page lives** (plan XI7, settled in MI0):
  - a 1×1 `WKWebView` added to the key window's root view at index 0, behind the Flutter view. As built (plan VI-7): inserted into the key window itself at index 0, beneath the root view controller's view, which covers it; a subview of the Flutter view would be drawn over Flutter's own content instead
  - `isUserInteractionEnabled = false`, `accessibilityElementsHidden = true`, `isAccessibilityElement = false`
  - the app uses scenes (`ios/Runner/SceneDelegate.swift`): when the key window changes, move the page to the new one; while there is no window (the app is in the background), leave it where it is
- **Termination.** `webViewWebContentProcessDidTerminate` closes the page. Its pending calls fail `closed`, and Dart reopens the page lazily (the `closed` row in A-ref §6.2). The bridge stops with the close (plan invariant 21).
- **App states.**
  - `inactive` (Face ID, Control Center, the app switcher): nothing changes.
  - `background`: Dart pauses the engine and polling (D9). The page stays, and iOS suspends its process along with the app.
  - Return: the page resumes, or reports its termination. Then the bridge check of plan XI14 runs (§6.8).
  - A memory warning while no call is pending closes the page, which reopens on next use.
- **Lock, account switch, route change, idle close, account delete and reset** are all driven from Dart and unchanged (A-ref §6.3, §8.4). Each host `close()` is followed by `stopRailgunBridge()` (`railgun_engine.dart:395-410`).

### 6.4 Host security on iOS

**The configuration** (`WKWebViewConfiguration`), all set before `WKWebView(frame:configuration:)`:

- `websiteDataStore`: `WKWebsiteDataStore(forIdentifier: RailgunPageHost.storeID)`, with its proxy (§6.8)
- `setURLSchemeHandler(RailgunSchemeHandler(), forURLScheme: "veylor-railgun")`
- `userContentController`:
  - `add(handler, contentWorld: .page, name: "railgunHost")`
  - `add(contentRuleList)`
  - **no `WKUserScript`**: nothing is injected into the page
- `defaultWebpagePreferences.allowsContentJavaScript = true`
- `preferences.javaScriptCanOpenWindowsAutomatically = false`
- `allowsInlineMediaPlayback = false` and `mediaTypesRequiringUserActionForPlayback = .all`
- `limitsNavigationsToAppBoundDomains` stays `false` (a custom scheme is not an app-bound domain)
- `webView.isInspectable = debug`, only under `#if DEBUG` (plan XI12; iOS 16.4+, so always present when the page runs)

**The scheme handler** (`RailgunSchemeHandler`):

- It serves `veylor-railgun://app/<path>` from `Bundle.main.url(forResource: "railgun", withExtension: nil)`.
- It resolves the path with `standardizedFileURL` and refuses anything outside that directory with 404. There are no directory listings, and only `GET` is answered.
- MIME types:
  - `.html`: `text/html; charset=utf-8`
  - `.js`: `text/javascript; charset=utf-8`
  - `.wasm`: `application/wasm`, which `WebAssembly.instantiateStreaming` requires
  - `.txt`: `text/plain`
  - anything else: 404
- Headers:
  - `Content-Security-Policy`: the page's meta CSP, the same string (A-ref §6.4)
  - `Cache-Control: no-store`
- `webView(_:stop:)` drops the task.

**The content rule list** (`RailgunContentRules`). It is compiled once with `WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "railgun-allowlist", encodedContentRuleList:)`, from `RailgunEndpoints`:

```json
[
  {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
  {"trigger": {"url-filter": "^veylor-railgun://app/"}, "action": {"type": "ignore-previous-rules"}},
  {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}},
  {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
  {"trigger": {"url-filter": "^https://ethereum-rpc\\.publicnode\\.com/"}, "action": {"type": "ignore-previous-rules"}}
]
```

The last line repeats once per host in `RailgunEndpoints`: the ten of A-ref §6.4, the artifact mirror `railgun-artifacts.pepeman931.workers.dev` included (progress VI-20), and since D-155 the RPC providers a user's own URL may name. A `*.` entry (`*.quiknode.pro`, `*.p2pify.com`) becomes `^https://([a-z0-9]+(-[a-z0-9]+)*\\.)+quiknode\\.pro/` (`RailgunContentRules.pattern`): one label or more, never the domain itself.

- WebKit's rule regexes are a subset of the full syntax: no alternation, and no `{n}` quantifiers. Keep one rule per host, and escape the dots.
- The identifier carries a version: change it whenever the hosts change, so a stale compiled list is never reused.
- The bridge's allowlist remains the authority (plan XI4). The rule list is defence in depth (UI7).

**Navigation and windows.**

- `decidePolicyFor navigationAction`: allow only the initial main-frame load of `veylor-railgun://app/index.html`, and cancel everything else (Kotlin's `shouldOverrideUrlLoading` returns `true`, `:257-260`).
- `createWebViewWith`: return `nil`, so there are no popups.
- JavaScript `alert`, `confirm` and `prompt` complete with their defaults; there is no UI.

**CSP and WebRTC.**

- The CSP (A-ref §6.4) is unchanged, and now also arrives as a response header.
- `shims.js:11-14` deletes `RTCPeerConnection`, `webkitRTCPeerConnection` and `RTCDataChannel` on iOS too. WebKit's WebRTC would otherwise send STUN traffic outside the proxy.

**The console.** `console` output reaches the host only as `log` events, and only when `debug` is set. A release build drops it, as Kotlin's `Chrome` does (`:301-312`). As built (plan VI-6): WebKit has no console callback, and hooking the console would mean injecting a script, which this section rules out. So the page's console never reaches the host; the engine's own `log` events still arrive from a page loaded with `debug`, and a debug build reads the console in Safari's Web Inspector (plan XI12).

### 6.5 Storage, artifacts and threading on iOS

- **The store.** `RailgunPageHost.storeID` is a fixed UUID constant. `WKWebsiteDataStore(forIdentifier:)` creates the store on first use and reopens it afterwards.
  - It holds the IndexedDB databases `railgun-mainnet` or `railgun-sepolia`, and `railgun-artifacts` (A-ref §6.5).
  - Proving artifacts download lazily, as on Android: from `ipfs-lb.com`, and from veylor's mirror `https://railgun-artifacts.pepeman931.workers.dev` when that fails (A-ref §6.5, progress VI-20).
- **The wipe.**
  1. Close the page and release the `WKWebView`.
  2. `try await WKWebsiteDataStore.remove(forIdentifier: storeID)`.
  3. WebKit refuses while the store is still in use, so retry up to 5 times, 500 ms apart.
  4. If it still fails, answer `failed`. Dart's reset logs a failed wipe and carries on (`account_provider.dart:2152-2165`).
- **Deleting one account** uses the page's `deleteWallet` (plan DI7, A-plan E5), as on Android. As built in MI1 (plan VI-2): `deleteWallet {network, mnemonic}` runs on a fresh page with only the database open, removes the wallet's encrypted record and the notes syncs decrypted for it (stored unencrypted), and needs no network. As built (progress VI-17, BI-3 option (a)): an account deletion derives the account's Railgun mnemonic before the Rust account delete, only for an account with a Railgun engine key; after it, the engine closes any open page, loads a fresh one behind an offline bridge (one that refuses every connection, so it never waits for Tor), calls `deleteWallet`, then closes the page and stops the bridge. Best effort: a failure leaves the wallet until a reset.
- **Backups** (plan DI6). After the store's first use, find its directory under `Library/WebKit/` (MI0.7 records the path) and set `isExcludedFromBackup` on it. Until MI0 confirms the path, exclude `Library/WebKit` as a whole: the app has no other web content. As built (plan VI-15): `load` makes `Library/WebKit` if it is missing and marks it before the store is first used, since a mark on a directory covers what WebKit creates inside it later, and marks it again after the load in case WebKit made it anew; a failed mark never blocks the load.
- **Threading.** The page's workers run inside WebKit's own process. The host does nothing off the main actor except its timeout tasks.

### 6.8 Tor bridge on iOS

**Unchanged in Rust** (A-ref §6.8), but for one fix (plan VI-16): `start()` replaces a bridge whose accept loop has ended. `start()`:

- resolves the route once
- binds `127.0.0.1:0`
- speaks SOCKS5 with no authentication
- accepts only `CONNECT` to an allowlisted hostname on 443
- re-checks the route for each connection
- then copies bytes both ways

`stop()` aborts everything.

**The WebKit side** (iOS 17+, the Network framework):

```swift
let store = WKWebsiteDataStore(forIdentifier: RailgunPageHost.storeID)
var proxy = ProxyConfiguration(
  socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!)
)
proxy.allowFailover = false   // the default; explicit, so a failed proxy never goes direct
store.proxyConfigurations = [proxy]
configuration.websiteDataStore = store
```

- **Per store, not per process.** Android's `ProxyController` override is process-wide. Here only the page's store uses the proxy, so nothing else in the app is affected and nothing needs clearing on close. Every `load` sets the proxy afresh, with the new port.
- **Hostnames.** The bridge refuses IP addresses.
  - If WebKit resolves names itself before the SOCKS handshake, every page request fails, and MI0 sees it at once (plan UI2).
  - The fix is `ProxyConfiguration(httpCONNECTProxy:)`, plus a small HTTP front end in the bridge that accepts only `CONNECT host:443` and applies the same allowlist and route checks (about 60 lines of Rust).
- **No DNS leak** follows from hostname `CONNECT`s: the Tor exit resolves the name, or the bridge resolves it under the direct-route lease.
- **A route change:** close the page, stop the bridge, start a new one (a new port), set the proxy, and reload (plan invariant 21).
- **After the background** (plan XI14, UI16). iOS may reclaim a suspended app's listening socket (Apple TN2277). On return, if the page is open, try a loopback connection to the bridge's port. As built (plan VI-8): Dart makes the probe when the app is shown again (`AppLifecycleListener.onShow`, iOS only), and a bridge that refuses takes the page down with it; the next use reopens both.
  - If it fails, stop and restart the bridge.
  - Then, following MI0.6's result, either assign the store a new `proxyConfigurations`, if WebKit honours that for a live page, or close and reload the page.
- **The residual risk** is as in A-ref §6.8: a no-auth loopback proxy, reachable by other running apps while the page is open, and limited to Railgun hosts on 443.
- **Precedent.** In-app loopback servers serving a `WKWebView` (for example `http://localhost` in older hybrid shells) are a known working pattern on iOS. WebKit's networking process can reach the app's loopback listener.

## 7. Config on iOS

- **Defines.** Unchanged (A-ref §7.3): `VIZOR_PRIVATE_USD_ENABLED`, `VIZOR_ETHEREUM_RPC_URL_{MAINNET,SEPOLIA}`, `VIZOR_PRIVATE_USD_FLAG_URL` and `VIZOR_SUPPORT_URL`.
  - Xcode needs none of them. Swift gets the proxy port from Dart, and the page gets its `rpcUrls` from Dart, as on Kotlin.
  - Don't add an xcconfig knob for any of them; this follows the rule against second knobs (AGENTS.md, "Deep-link Host").
- **Secrets.**
  - The keyed RPC URL sits in the IPA's Dart snapshot, as it sits in the APK. Use the same rate-capped keys (E6).
  - The page's requests carry `Origin: veylor-railgun://app` (Android: `https://railgun.appassets.androidplatform.net`). An Alchemy origin allowlist (A-plan U18) needs both.
- **Pins.** A-ref §7.1–§7.2, unchanged.
- **Build commands.**
  - Simulator and iPhone: plan "Commands".
  - Release: `fvm flutter build ipa --release --dart-define=VIZOR_FORM_FACTOR=mobile --dart-define=VIZOR_PRIVATE_USD_ENABLED=true --dart-define-from-file=<rpc json>`.

## 8. iOS integration

### 8.1 Registration and the app's lifecycle

- **Channels** are registered in `AppDelegate.didInitializeImplicitFlutterEngine` (`ios/Runner/AppDelegate.swift:53-56`), with the existing `FlutterMethodChannel(name:binaryMessenger:)` pattern. Register `RailgunHostHandler` there, its method and its event channel, and keep a strong reference to it.
- **The page host is a process singleton** (`RailgunPageHost.shared`), as Android's `RailgunHostHandler.Pages` is. The handler only binds the channel to it.
- **Scenes.** The app uses scenes (`ios/Runner/SceneDelegate.swift`). The page host finds the key window through the foreground-active `UIWindowScene` (§6.3).
- **Background modes** are `processing` and `fetch` (`Info.plist:5-9`), for the Ironwood work. Private USD adds none (D9).

### 8.2 Dart gates

- `privateUsdAvailableFor` (`private_usd_available_provider.dart:49-59`) and `privateUsdEngineEnabledFor` (`private_usd_engine_provider.dart:55-61`) gain a `hostSupported` argument. The rule becomes `platform == TargetPlatform.android || (platform == TargetPlatform.iOS && hostSupported)`. Android also passes its own `supported`, which is `true`.
- `hostSupported` comes from the bootstrap: `loadAppBootstrap()` (`lib/src/app_bootstrap.dart:254`), injected through `appBootstrapProvider`.
  - It makes one `supported` call before `runApp` (as built, only in builds with `VIZOR_PRIVATE_USD_ENABLED` and the mobile form factor; plan VI-10).
  - Any error or a missing plugin gives `false` (desktop has no host).
  - On iOS, a `MissingPluginException` means the handler was not registered yet: treat the answer as unknown and ask again after the first frame (plan MI2 traps).
- `RailgunHostChannel` (`railgun_host_channel.dart:113-197`) does not change: the same names, arguments and codes.
- The five `Platform.isAndroid` failures in `integration_test/private_usd_device_test.dart` (`:338, 368, 392, 410, 427`) become a host-support check (as built: `_requireRailgunHost`, over `queryRailgunHostSupported`).
- As built (MI3.1): `queryRailgunHostSupported` (`railgun_host_channel.dart`) answers `true`, `false`, or `null` for an iOS handler not registered yet; `railgunHostSupportedProvider` (`private_usd_available_provider.dart`) starts from the bootstrap's answer and asks again after the first frame when it was `null`; `privateUsdPlatformHostsPage` is the rule both gates share.

### 8.3 Lifecycle hooks

Unchanged from A-ref §8.4: the lock, the background, an account switch, a deletion and a reset, drained through `privateUsdLifecycleProvider`. Notes for iOS:

- On the way to the background iOS goes `inactive`, then `hidden`, then `paused`. `AppLifecycleListener.onHide` fires at `hidden`; `inactive` alone does not pause (plan XI8).
- `BackgroundAutoLockHost` locks after 15 minutes away (`background_auto_lock_host.dart:14, 76-95`), as on Android. The lock closes the page.
- The engine's idle close (10 minutes, `railgun_engine.dart:156, 412-425`) applies as on Android.

### 8.4 Backups

`com.zcash.wallet/network_privacy` `excludeFromBackup {path}` already exists (`AppDelegate.swift:427-465`). It creates the directory if needed and sets `isExcludedFromBackup`. Reuse it, or add a twin on a Private USD channel, for the items below. As built (plan VI-11) it is reused: its Dart helper is `excludeFromDeviceBackup` (`lib/src/core/storage/device_backup.dart`), and the page's store is marked from Swift (`RailgunPageHost.excludeWebDataFromBackup`, all of `Library/WebKit` until MI0.7, made and marked before the store's first use: plan VI-15).

- each `private_usd_<walletDbName>_<network>` directory, when `getPrivateUsdDirPath` creates it
- the token state's directory (MI7)
- the page store's directory (§6.5)

`isExcludedFromBackup` is set per item, and it survives app updates. It is lost when the directory is recreated, so set it again every time a directory is created.

### 8.5 Keep-awake

`NativeScreenAwakeBridge` (`lib/src/services/native_screen_awake.dart`; channel `com.zcash.wallet/screen_awake`, method `setEnabled`) already sets `UIApplication.shared.isIdleTimerDisabled` on iOS (`AppDelegate.swift:560-584`). Private USD's keep-awake (A-plan X8) works unchanged through `SyncKeepAwakeNativeHost`, combined with sync keep-awake (`sync_keep_awake_native_host.dart:69-70`). Since progress VI-18 it also holds through a Railgun first sync while the wallet is unlocked (`privateUsdFirstSyncKeepAwakeProvider`), on both platforms.

### 8.6 App Attest (MI7)

- **The API** is `DCAppAttestService.shared`:
  - `isSupported`: `false` on the simulator
  - `generateKey()`: returns a `keyId`
  - `attestKey(keyId, clientDataHash:)`: returns an attestation object (CBOR)
  - `generateAssertion(keyId, clientDataHash:)`: returns an assertion
- **The client data hash** for an issuance mirrors Android's signed message: `SHA-256("zecswap-issuer-v1" ‖ challenge ‖ SHA-256(blinded…))` (A-ref §5.9), subject to the issuer's iOS format (EI6).
- **Setup.**
  - The entitlement `com.apple.developer.devicecheck.appattest-environment` (`development` or `production`).
  - The App Attest capability on the App ID, under the owner's team (DI8).
- **Errors** keep the existing codes, so Dart's mapping does not change: a DeviceCheck error is `KEYSTORE`, and an argument error is `bad_args`.

### 8.7 Xcode project, Info.plist, entitlements and signing

- **The Runner target** gets the `Railgun/` Swift files and the `railgun` folder reference in Copy Bundle Resources.
- **The deployment target** stays 15.0 (plan DI2). Mark iOS 17 APIs `@available(iOS 17.0, *)` and branch on `if #available`.
- **`Info.plist`.**
  - No ATS exception is needed: the page uses https only, and the loopback hop is a proxy, not a URL load (confirm in MI0, UI8).
  - No `NSLocalNetworkUsageDescription` is expected, because the hop is loopback.
  - `ITSAppUsesNonExemptEncryption` is absent today (MI8).
- **Entitlements.** None new until MI7 (App Attest).
- **The privacy manifest** (MI8). `PrivacyInfo.xcprivacy` is absent today. When it is added, declare the app's required-reason APIs; this is an App Store requirement, not one specific to Private USD.
- **Signing for device rounds** (plan XI11, EI2). The project signs with team `SZTB68DXM4` as `com.keplr.vizor`, with `com.keplr.vizor.SyncWidget` and the app group `group.com.keplr.vizor` (`Runner.entitlements`, `SyncWidgetExtension.entitlements`). On a personal iPhone, change all of these together, for the build only, and never commit the change:
  - the `PRODUCT_BUNDLE_IDENTIFIER` of Runner and of SyncWidget
  - the app group in both entitlements files
  - the team

## 12. Source map (Kotlin to Swift)

| Kotlin (`kt/`) | Lines | Swift (`sw/`) | Notes |
|---|---|---|---|
| `RailgunHostHandler.kt` | 22-152 | `RailgunHostHandler.swift`, `RailgunPageHost.swift` | `reply()`, exactly once (`:98-117`), becomes a per-call `replied` flag |
| `RailgunWebViewHost.kt` `load`, `close`, `wipe` | 84-148 | `RailgunPageHost.swift` | The proxy moves from `ProxyController` to the store; the wipe moves from `deleteOrigin` to `remove(forIdentifier:)` |
| `Page` | 150-233 | `RailgunPage.swift` | |
| `Client`: `shouldInterceptRequest`, `shouldOverrideUrlLoading`, `onRenderProcessGone`, `onPageFinished`, a failed own asset | 235-299 | the `RailgunPage` delegates, `RailgunContentRules`, `RailgunSchemeHandler` | No per-request interception (plan XI4) |
| `Chrome` (the console) | 301-312 | none: no script is injected (plan VI-6) | The engine's own `log` events still arrive in debug |
| `OwnAssets` | 315-321 | `RailgunSchemeHandler` | |
| `RailgunRequests` | 345-372 | the `RailgunSchemeHandler` constants and `RailgunContentRules` | `PAGE_URL` becomes `veylor-railgun://app/index.html` |
| `RailgunChannel.kt` | 14-66 | `RailgunPage` (the pending calls) | |
| `RailgunProtocol.kt` | 12-128 | `RailgunProtocol.swift` | `org.json`'s traps (A-ref §8.7) become `JSONSerialization` with `.fragmentsAllowed` for results |
| `RailgunEndpoints.kt` | 9-26 | `RailgunEndpoints.swift` | Pinned by the Rust test (plan XI10) |
| `RailgunException.kt` | — | `RailgunError.swift` | |
| `MainActivity.kt` registration (`:164-175`) and `dispose(isFinishing)` (`:343-348`) | | `AppDelegate.swift:53-56` | iOS has no Activity recreation; the singleton outlives Flutter engines anyway |
| The Kotlin tests `RailgunBoundaryTest`, `RailgunProtocolTest`, `RailgunChannelTest` | | `ios/RunnerTests/RailgunHostTests.swift` | |
| `scripts/private-usd/run_device_round.sh`, `check_sockets.py`, `sample_device.sh` (adb) | | `scripts/private-usd/ios/run_device_round.sh` | `lsof` (simulator), `rvictl` and `tcpdump` (iPhone), Instruments for memory |
