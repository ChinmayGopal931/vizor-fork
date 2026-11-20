# Railgun page hosts: what each one must do

Shielded USD runs Railgun in a hidden web page (`android/railgun-web/src/`,
built into one bundle that every host loads). A host is the native code that
runs that page: Android's (Kotlin, `android/app/src/main/kotlin/com/keplr/vizor/railgun/`),
iOS's (`ios/Runner/Railgun/`), the Mac's (`macos/Runner/Railgun/`, with four
of iOS's files), and Linux's (in progress). This is the list of what a host
must do so that the page syncs Railgun as fast and as reliably as it does on
Android, which was tested and reviewed in depth and is the reference
throughout. It was written on 2026-11-20 from the Android and Mac code at
`fix/archive-parity`, while bringing the Mac to parity.

Each item says what to do, why, where Android does it, and how the Mac does
it. Items marked **(WebKit)** apply to a host built on WebKit (the Mac, iOS,
WebKitGTK on Linux); **(Chromium)** to one built on Chromium (Android's
WebView, CEF, WebView2). Read AGENTS.md's "Private USD" section first: its
invariants hold on every host, because the engine (Rust) and the flows (Dart)
are shared.

Prefixes below: `kt/` is the Android host's directory, `rw/` is
`android/railgun-web/`, `mac/` is `macos/Runner/Railgun/`, `ios/` is
`ios/Runner/Railgun/`.

## 1. The channel Dart talks to

- **H1. Two channels, one contract.** `com.zcash.wallet/railgun` (methods)
  and `com.zcash.wallet/railgun/events` (a stream of strings). Every host
  answers the same methods with the same codes, so Dart treats them alike:
  - `supported`: whether the page can run here. Android: always (minSdk 30).
    Mac: macOS 14 and later (the store's proxy API). Register the handler
    before Dart's bootstrap asks (`queryRailgunHostSupported` in
    `lib/src/features/private_usd/services/railgun_host_channel.dart`): a
    missing handler reads as no host, except on iOS.
  - `load {proxyPort, debug}`: close any page, load a fresh one whose every
    connection goes through the bridge at `proxyPort`, answer once the page
    said `ready` (30 s, else close it and fail). A port outside 1 to 65535
    is `bad_args`. `debug` counts only in a debug build.
  - `call {method, paramsJson}`: one page call; the answer is the result's
    raw JSON text. Unknown methods are `bad_args`.
  - `close` (idempotent), `wipe` (close, then delete everything the page
    stored), `isOpen` (a loaded page that is still open).
  - Error codes: `closed`, `timeout`, `unavailable`, `protocol`, `failed`,
    `rpc_failed`, `bad_args`. Any other failure gets a fixed message: the
    page's own text can quote a keyed RPC URL.
  - Exactly one answer per call, on the platform thread the channel wants.
- **H2. Call timeouts.** A call that outlives its time closes the page (the
  engine may be stuck) and fails `timeout`: `start` 2 min, `openWallet`
  1 min, `refresh` 2 h (a first mainnet sync reads all of Railgun's history),
  `deleteWallet` 1 min, `transfer` and `unshield` 10 min, `broadcasterFee`
  2 min, `reverseCost` 30 s, `prepareReverse` 10 min. Kotlin's
  `RailgunMethod` (`kt/RailgunProtocol.kt`) and Swift's
  (`ios/RailgunProtocol.swift`) are the same table.
- **H3. Events.** Forward the page's unasked messages as their raw JSON:
  `scan`, `proof`, `screening`, `refresh`, `synced`, and `log` only from a
  page loaded with `debug`. Drop any other name. Keep up to 256 while nobody
  listens (Android drops them with no collector; Dart listens before it
  loads a page, so either works). The page's `log` lines and console can
  quote anything the engine saw: never print them outside debug.
- **H4. Dart's gates for a new platform.** A new host needs its platform
  added where Dart decides a page can run:
  `privateUsdPlatformHostsPage` (`private_usd_available_provider.dart`),
  `privateUsdArchiveAvailableProvider` (`private_usd_archive_sync_provider.dart`,
  which also decides whether Settings shows "Sync history from Anon's
  archive"), and anything gated on `TargetPlatform.iOS` that the platform
  shares (only `replaceDeadBridge`, for iOS's reclaimed sockets). Add the
  platform to `test/features/private_usd/private_usd_archive_sync_test.dart`.

## 2. The page and its transport

- **H5. The page's files, and nothing else.** Serve the bundle's own files
  (`index.html`, `railgun.js` and the two `.wasm` files load) with their
  types (`application/wasm` for WASM: `instantiateStreaming` needs it), on an
  origin of the page's own: Android
  `https://railgun.appassets.androidplatform.net/assets/railgun/`
  (`WebViewAssetLoader`), the Mac and iOS `veylor-railgun://app/`
  (`ios/RailgunSchemeHandler.swift`). No path outside the bundle, no
  directory, GET only. The Mac also sends the page's CSP as a header.
- **H6. A secure context.** The page needs `crypto.subtle` (the archive's
  checksums), IndexedDB, `localStorage`, module Web Workers from `blob:`, and
  WebAssembly under `'wasm-unsafe-eval'`. The Mac's custom scheme is a secure
  context. **(WebKitGTK)** register the page's scheme as secure
  (`webkit_security_manager_register_uri_scheme_as_secure`) and check
  `crypto.subtle` exists before anything else.
- **H7. The transport.** Two kinds, chosen by the page at load (`rw/src/index.js`):
  - **(Chromium)** a `MessagePort`: post `vizor-railgun-init` with one port
    to the page's origin once it loads (`kt/RailgunWebViewHost.kt`,
    `handshake`); the page takes the first port only.
  - **(WebKit)** a script message handler named `railgunHost` in the page
    world; deliver each request as a `callAsyncJavaScript` argument to
    `__railgunHostDeliver(m)`, never spliced into script; take messages only
    from the page's own main frame, page world and origin
    (`mac/RailgunPage.swift`, `receive`).
  - The envelope: requests `{"id","method","params"}` with `params` exactly
    one JSON object, spliced so large numbers keep every digit; replies
    `{id, result}` or `{id, error: {code, message}}`; `BAD_REQUEST` is
    `protocol`, `RPC_FAILED` is `rpc_failed`, anything else `failed`, an
    unreadable reply `protocol`.
- **H8. Locked down.** No navigation after the first load (Android
  `shouldOverrideUrlLoading`, the Mac's `decidePolicyFor`), no new windows,
  dialogs or file pickers, no file or content access, no WebRTC (the page
  deletes it, `rw/src/shims.js`). A page whose own file fails before it is
  ready is closed rather than waited out. A renderer or content process that
  dies closes the page (Android `onRenderProcessGone`, the Mac
  `webViewWebContentProcessDidTerminate`); Dart reopens it on the next use.
- **H9. One store, fixed, wiped whole.** The page keeps everything in one
  persistent store: IndexedDB `level-js-railgun-<network>` (the engine's
  database, 2 GB on a mainnet first sync, notes unencrypted),
  `railgun-artifacts` (circuit artifacts), and `localStorage`
  `railgun-tree-recovery:<network>` (tree rebuilds and the archive's week
  off). Give it a fixed identity so `wipe` finds it again (the Mac's
  `WKWebsiteDataStore(forIdentifier:)`, retried while WebKit lets go of it;
  Android's `WebStorage.deleteOrigin`). Keep it out of backups where the OS
  backs up (Android `allowBackup="false"`, the Mac and iOS exclude
  `Library/WebKit`).
- **H10. Keep the page running while it is shown.** A sync runs for minutes
  in the page, and so does the rest of one (section 6). **(WebKit)** a web
  view that is not in a visible window is suspended: the Mac keeps the 1×1
  view in its window's content view, below the Flutter view, and WebKit
  suspends the page soon after the window stops being visible (covered,
  minimised, another Space: the owner's log shows "View was recently
  visible", then the suspension), as iOS suspends it in the background.
  That is the foreground rule (AGENTS.md, "Foreground and unlocked only").
  A page that can't be seen while the app's window is shown would stop its
  sync for no reason.
- **H11. Never close the page for memory.** Android's host never does, and
  the rest of a sync runs with no call waiting, so a page that looks idle may
  be the one syncing. The Mac closed an idle page on a memory-pressure
  warning (carried over from iOS) until 2026-11-20; warnings are routine
  beside a 500 to 800 MB page. Only iOS, whose memory warning comes before
  the system ends the app, closes it. Dart closes a page nobody uses after
  ten minutes.
- **H12. Workers.** The page works a notes scan's keys out in up to six Web
  Workers (`rw/src/note-keys.js`, one per core but two,
  `navigator.hardwareConcurrency`). They need `worker-src blob:` (the CSP
  has it) and `blob:` let through the host's filter. On a debug page, the
  page's `noteKeys` call shows whether they ran (`workers` above 0): the
  Mac's WebKit ran six, with 12,237 of 12,271 points prepared, on a Sepolia
  first sync on 2026-11-20.

## 3. Every connection goes through the bridge

- **H13. The bridge is the only way out.** The Rust bridge
  (`rust/src/railgun_bridge.rs`) is a loopback SOCKS5 server, one per page,
  that serves only `CONNECT` to an allowlisted hostname on 443, over Tor when
  Tor is on (one isolated Tor client for the page's session) and directly
  otherwise. Point every page connection at `127.0.0.1:<proxyPort>`, set
  before the page exists (Android's process-wide proxy override waits until
  it is in force; the Mac sets the store's `proxyConfigurations` before
  making the web view), with no failover to a direct connection
  (`allowFailover = false` on the Mac). Check the bridge accepts before
  loading (the Mac's `loopbackAccepts`).
- **H14. Hostnames, never addresses.** Hand the bridge the hostname
  unresolved (SOCKS5 address type 3), so it resolves on the wallet's route: a
  host that looks a name up itself leaks it to the local resolver and is
  refused by the bridge (`AddressTypeNotSupported`). Chromium and WebKit do
  this for the page. For a host's own fetches: Android's `HttpURLConnection`
  with a SOCKS `Proxy`, the Mac's `URLSession` with a SOCKSv5
  `ProxyConfiguration` (both checked against a stand-in). With libcurl use
  `socks5h://`, never `socks5://`; with GIO and libsoup a `socks5://` proxy
  resolver sends the name, which a stand-in should confirm.
- **H15. The allowlist in every place.** The bridge's
  `RAILGUN_PAGE_HOSTS`, the host's own filter, the page's CSP and the host's
  endpoint list name the same hosts, a `*.` entry meaning one label or more:
  Android filters every request in `shouldInterceptRequest`
  (`RailgunRequests.route`: its assets, allowlisted https on the default
  port, `blob:` and `data:`, else 403); WebKit has no per-request hook, so the
  Mac and iOS block everything with a `WKContentRuleList` and let those
  through (`ios/RailgunContentRules.swift`). A Rust test pins Kotlin's and
  Swift's lists and the CSP together
  (`the_page_hosts_match_the_host_filters_and_the_page_csp`): add the new
  host's list to it.
- **H16. Nothing around the proxy.** Several page hosts advertise HTTP/3
  (rail-squid, ipfs-lb, the screening node and publicnode send
  `alt-svc: h3`; Anon's archive doesn't). QUIC can't go through the bridge.
  On the Mac, during a mainnet sync through a stand-in, WebKit's networking
  process held only loopback TCP connections to the bridge, and no UDP
  socket: check the same of a new host (its processes' sockets while it
  syncs).
- **H17. A new route is a new page.** A route change (Tor on or off, Tor
  failing), a lock, an account switch, a new Ethereum RPC or archive setting,
  and the idle close all close the page and stop its bridge (Dart,
  `railgun_engine_provider.dart`); the next use loads a page on a new bridge.
  The bridge of an old route refuses new tunnels, and browsers keep pooled
  sockets, hence the new page. A host closes every connection of its own (the
  archive's) when its page closes. Deleting an account's Railgun wallet loads
  a page of its own behind an offline bridge that refuses every connection,
  and calls `deleteWallet` alone; the host treats it as any page.
- **H18. Headers that name nothing.** Requests the host makes itself carry
  the same headers on every device of its kind: Android's archive fetch sends
  `User-Agent: Mozilla/5.0`, not the phone's. So do the page's own requests
  on Android: the WebView's User-Agent names the phone's model and its
  Android build, so the host sets the page's to the same `Mozilla/5.0`
  (`RailgunRequests.USER_AGENT`, `kt/RailgunWebViewHost.kt`, since
  2026-11-20), which every host the page reaches answers (section 8). WebKit's
  on the Mac freezes the OS version (`Macintosh; Intel Mac OS X 10_15_7`) and
  names no model, and the Mac keeps it. **(Chromium)** set the page's
  User-Agent before it loads; check what it names on a host whose engine's
  own isn't frozen.

## 4. Anon's archive: whether the page reads it

On mainnet a sync far behind reads Railgun's history from Anon's archive
(`digest.anon.inc/v4/1`) before rail-squid: commitments and the transaction
list, a few times faster (AGENTS.md, "Anon's archive"). The archive sends no
CORS headers, so the page can't read it itself, and every host fetches it for
the page (section 5).

- **H19. The start says so.** Dart's `start` params carry
  `"archive": true` only on mainnet, with the Settings switch on (by
  default), where the platform's host fetches the archive
  (`privateUsdArchiveSyncOf`). A setting that can't be read starts without
  it.
- **H20. The page's own rules** (`rw/src/wallet.js`, `archive-sync.js`,
  `archive-txids.js`, `tree-recovery.js`): it builds an archive reader only
  when `start` asks and `globalThis.webkit?.messageHandlers?.railgunHost` is
  undefined, the check that keeps iOS off it; it asks the archive only for a
  quick sync more than 28,800 blocks (about four days) behind the newest
  block (the RPC's, else the clock and the shipped block table), so a fresh
  store does; and never while the archive is off for a week after a tree
  rebuild or a misrecorded send (`archiveOffUntil` in `localStorage`).
- **H21. (WebKit) The prelude.** A WebKit host's page sees its own
  `railgunHost`, so before every `start` that reads the archive the host runs
  a fixed script in the page world (`RailgunArchive.prelude` in
  `mac/RailgunArchive.swift`, through `callAsyncJavaScript`, nothing spliced
  in) that:
  1. routes the page's GETs of `https://digest.anon.inc/…` (a string URL) to
     `/anon-archive/…` on the page's own origin, where the host answers
     them; everything else is untouched;
  2. hides the host from the start's check by replacing
     `webkit.messageHandlers` with a frozen empty object: `window.webkit` is
     non-configurable, and the page's transport took `railgunHost` at load,
     so it goes on posting;
  3. **holds the `webkit` object it changed** on the global object. WebKit
     makes that object anew once nothing in the page refers to it, and the
     new one has the real `messageHandlers`: a garbage collection between
     the prelude and the start showed the start the host again, and the page
     synced from rail-squid alone. 0.9.0's first mainnet sync never asked the
     archive, the signature of this (its log shows no archive request at
     all); 6 of 15 test starts of the same code did the same, none of 15
     since. WebKitGTK shares WebKit's bindings: hold it there too;
  4. hides the host again on every run (idempotent) and answers whether it
     is hidden. Only then does the host let `/anon-archive/` through
     (404 before).

  Check it: after the prelude, have the page make garbage until it
  collects (a few hundred thousand objects, a few times) and read the check
  again; it must stay hidden.
- **H22. (Chromium)** No prelude: the page finds no `webkit` and reads the
  archive; the host intercepts its requests to the archive's host (section 5).

## 5. Anon's archive: what the host answers

Android's `kt/RailgunArchiveFetch.kt` is the reference; the Mac's
`RailgunArchiveFetch` in `mac/RailgunArchive.swift` follows it item by item.

- **H23. Only the archive.** Answer only a GET of
  `https://digest.anon.inc/…` on the default port (Android
  `RailgunArchiveFetch.handles`), the path and query as the page asked
  (`?v=` busts the archive's CDN where the page needs it). **(WebKit)** only
  under `/anon-archive/` on the page's own origin, only once the prelude
  took, and no path that escapes it (`RailgunArchive.upstream`).
- **H24. The request.** The headers Android sends: `Host`,
  `User-Agent: Mozilla/5.0`, `Accept-Encoding: identity`, `Connection:
  Keep-Alive` (HTTP/1.1's), and nothing else of the page's or the
  platform's (the Mac's `URLSession` adds `Accept: */*`, the same
  everywhere): no `Accept-Language` (the Mac's
  `URLSession` adds the Mac's own languages, so it sends `*`), no cookie, no
  credential, no cache read or written, and no cache directive (the Mac's
  `reloadIgnoringLocalAndRemoteCacheData` sent `Cache-Control: no-cache` to
  the CDN until 2026-11-20). Never follow a redirect. Never decode the
  answer: the files are gzip, checked against the archive's checksums as
  served. (`URLSession` would decode a `Content-Encoding` it knows whatever
  was asked; the archive's CDN sends none to `identity`, checked
  2026-11-20.)
- **H25. The limits.** Connecting 20 s, a read that stalls 20 s, 60 s an
  answer in all (the page gives up after a minute too), 16 MB declared or
  read (far above the largest file, about 0.5 MB). Android checks its
  deadline between reads; the Mac's session has a 60 s resource timeout.
- **H26. The answer.** A 2xx, 4xx or 5xx goes to the page with its body and
  its type (no parameters). Anything else (a redirect, 1xx, no status) and
  any failure of the host's own is a 502 with an empty body, never a 4xx: the
  page tries a 502 again and leaves the archive on a 4xx at once. Buffer the
  whole answer before answering, as Android does, so a failure partway is
  still a 502; size the buffer from a declared length and grow it in place
  (the Mac copied a growing body on every read until 2026-11-20).
  **(Chromium)** add `Access-Control-Allow-Origin: <page origin>`;
  everyone `Cache-Control: no-store`. The page reads no reason phrase
  (Android's WebView throws on an empty or non-ASCII one).
- **H27. Connections, as Android keeps them.** Android's `HttpURLConnection`
  speaks HTTP/1.1 only (AOSP's `HttpsHandler`), and its pool
  (`ConfigAwareConnectionPool`) gives these rules, which every host must keep:
  1. one request per connection at a time; requests in flight together go
     out on connections of their own (the page keeps four chunks in flight);
  2. a connection whose answer was read whole is kept for the next request:
     at most five idle, each for five minutes at most;
  3. a connection whose request failed, timed out, was refused for its size
     or was aborted is closed, never used again, so the page's next try goes
     out on another connection;
  4. a change of network drops every kept connection: the tunnels the bridge
     opened on the old network may be dead without having closed;
  5. a kept connection the far end closed is replaced without costing a try
     (OkHttp retries on a new one; so does `URLSession`).

  Never multiplex the archive's requests on one HTTP/2 connection. The Mac
  did, on one `URLSession`: a connection that stops answering without
  closing (a stalled Tor circuit, a network that drops packets) then took
  every try the page sent, for as long as `URLSession` kept it, 72 to 100 s
  in tests, nearly all five of the page's tries at each request. It now keeps
  a session per connection by the rules above (`take`, `keep`, an
  `NWPathMonitor` for 4), and a stalled connection costs the one try sent on
  it. A fresh connection per request, as a cure, is safe but slow: 2.3 times
  slower over 20 chunks at a 265 ms round trip, where keeping connections
  matched one shared connection's speed. **(libsoup)** a session pools
  connections; force HTTP/1.1 per message (`soup_message_set_force_http1`),
  check that a failed message's connection is not reused, and remove the
  session's content decoder, if it has one.
  **(libcurl)** HTTP/1.1, a share or multi handle for the
  pool (`CURLMOPT_MAXCONNECTS` 5, `CURLOPT_MAXAGE_CONN` 300), no
  `CURLOPT_ACCEPT_ENCODING`, `CURLOPT_FOLLOWLOCATION` 0, `CURLOPT_LOW_SPEED_TIME`
  20 with `CURLOPT_LOW_SPEED_LIMIT` 1, `CURLOPT_TIMEOUT` 60, and the size
  cap in the write callback.
- **H28. Aborts.** The page aborts a request after 60 s, and when it closes.
  If the engine tells the host (WebKit's `webView(_:stop:)`), end the fetch,
  close its connection, and never answer it (WebKit throws). Android's
  WebView doesn't tell its host: the fetch runs to its own deadline and its
  answer is dropped.
- **H29. Close with the page.** Closing the page ends every fetch unanswered
  and closes every connection, kept ones included; nothing is fetched for a
  closed page. The bridge stops right after (Dart), which would end them
  anyway.
- **H30. Threads.** Android fetches on the WebView's request thread, blocking
  it; the Mac does everything on the main thread (WebKit calls its scheme
  handler there, and its sessions' delegate queue is the main queue), which
  costs little: about four answers of 0.5 MB in flight.
- **H31. Privacy.** Through the bridge only, by name (H13, H14); the same
  request for every wallet (paths depend on the chain alone); nothing logged,
  no URL, no body, no status (Android's and the Mac's log nothing of it).

**The page's retries the host must fit** (`rw/src/archive.js`,
`archive-sync.js`, `archive-txids.js`): a request gets five tries, 1, 2, 4
and 8 s apart, each aborted after 60 s; a 408, 425, 429, 5xx or network
failure is tried again, any other 4xx leaves the archive at once; a try cut
through by a pause of the page is free (`page-clock.js`). The notes' sync,
when the archive is out of reach or rail-squid's lists fail beside it, asks
both again in three rounds, 20 then 40 s apart, before it leaves the archive;
bad data of the archive's own leaves it at once. The transaction list leaves
the archive for the rest of the page at its first failure. A first mainnet
sync makes about a thousand archive requests (244 sealed chunks on
2026-11-20, a chunk's meta and one file each, once for the notes and once for
the list).

## 6. The rest of a sync, and the Dart around it

Shared Dart and the shared page do all of this; a host must only let it run.

- **H32. The rest of a sync runs in the page.** `refresh` answers once the
  notes are scanned and screened; Railgun's transaction list and the wallet's
  proofs then go on in the page (`rw/src/sync-finish.js`), with no call
  waiting, and end with a `synced` event that Dart matches by its `rest`
  number. Forward `synced`; don't close a page because no call waits (H11).
- **H33. Refreshes.** Dart asks for Railgun's head every 30 s, refreshes once
  it moved and at least every 10 minutes, only while the balance is watched,
  the app in the foreground and the wallet unlocked
  (`private_usd_balance_provider.dart`); a refresh the user waits on shows the
  page's `refresh` events. Forward `refresh`, `scan` and `screening`.
- **H34. Idle close.** Dart closes the page ten minutes after its last use,
  counting the page's events while a rest runs (`railgun_engine.dart`). The
  host closes it only when asked (and on H2, H8).
- **H35. Keep-awake.** Through a first sync, a long rest and a bridge that
  needs the app, Dart sets `com.zcash.wallet/screen_awake`: Android keeps the
  screen on; the Mac takes an IOKit display assertion while its window is not
  hidden (`macos/Runner/ScreenAwakeChannel.swift`). **(Linux)** an idle
  inhibitor (`gtk_application_inhibit` with `IDLE`, or the desktop's
  `ScreenSaver.Inhibit`), released when Dart says so.
- **H36. `rpc_failed`.** A sync that fails while the RPC doesn't answer, or
  answers 403 or 429, and a screening node does, fails as `RPC_FAILED`
  (`rw/src/rpc-probe.js`); map it to `rpc_failed`, and Dart offers another
  RPC.

## 7. Checking a host without spending

Nothing here spends: the page only reads public chain data.

1. **The archive path, outside the app.** Serve the real bundle
   (`ios/Runner/Railgun/railgun/`) from the host's code in a test program, with
   a stand-in for the bridge: a SOCKS5 server that accepts what the bridge
   accepts (no auth, `CONNECT`, a hostname on 443, the page's hosts) and logs
   each `CONNECT`. Drive it as Dart does: `load`, `start` with
   `{"network":"mainnet","rpcUrls":["https://ethereum-rpc.publicnode.com"],
   "poiNodeUrls":["https://ppoi.fdi.network/"],"archive":true,"debug":false}`,
   `openWallet` with a random 32-byte hex `encryptionKey` and BIP-39's public
   test mnemonic ("abandon" eleven times, then "about"), then `refresh`.
   Within seconds of the quick sync's start (block 14,737,691 for a fresh
   store) the stand-in shows `digest.anon.inc`, on four connections kept for
   the next requests; with `"archive":false`, none. Run it ten times or more:
   the Mac's failure hit two starts in five. The Mac's programs for this
   (Swift command-line tools that compiled the host's own files, a stub for
   the FlutterMacOS half of `RailgunError`, an in-memory store, and WebKit's
   private preferences that keep a windowless page from being suspended)
   were not committed.
2. **A stalled connection.** Have the stand-in stop forwarding on one
   connection partway through a file, without closing it: the page loses one
   try (about 20 s) and carries on, on another connection.
3. **On a real sync.** A mainnet build, a wallet whose Railgun store is new
   or months behind. Watch the app's process's connections (`lsof -i -n -P
   -p <pid>` on a Mac, `ss -tnp` on Linux) for the archive's addresses
   (Cloudflare `104.26.4.215`, `104.26.5.215` and `172.67.69.80` on
   2026-11-20: resolve `digest.anon.inc` first). On the Mac the unified log
   shows the page's custom-scheme loads (`WebURLSchemeTaskProxy::startLoading`
   under the app's PID) during the quick sync, and `URLSession` tasks with
   `timeouts(20.0, 60.0)`.

## 8. Found on the way, in the shared page or on Android

Both fixed on 2026-11-20 (`fix/railgun-page-archive-tip`):

- **The archive's tip was refused.** `archive.js` took the tip only when it
  started the block after the last sealed chunk ends (`meta.startBlock !==
  after + 1`). But the archive names a sealed chunk's blocks, and the tip's,
  from the first with an event to the last: it seals the tip's oldest events
  into a chunk, whole blocks at a time, and the tip goes on at its next event.
  On 2026-11-20 chunk 243 ended at block 26,439,999, its last event's, and
  the tip started at 26,440,026, its first's. A tip that starts at the block
  right after is as rare as two sealed chunks that meet (5 of 243 seams), so
  every sync far behind, Android's and the Mac's, read the sealed chunks from
  the archive and the tip's days from rail-squid (18,105 blocks then: 2,029
  leaves and 947 transactions, under 1% of the history), and the transaction
  list left the archive for the rest of the page there. The page now takes a
  tip that starts after the last sealed chunk, as it takes each sealed chunk
  after the one before: what shows that nothing is missing between them is
  what the events carry, the commitments' tree positions and the
  transactions' verification hashes (`rw/dev/archive-sync.test.mjs` and
  `archive-txids.test.mjs` drop a batch and a transaction there). Run against
  the live archive, the page's reader went from chunk 243 into the tip: 3,485
  leaves on by tree position from chunk 242's end, and 1,613 transactions
  chained from chunk 242's last. Anon's own wallet (the Chrome extension,
  0.14.1, read for this only) takes the tip the same way, as everything after
  the last sealed chunk's end, and never compares the tip's first block with
  it: its notes sync reads the tip's files by the manifest's checksum after
  the sealed chunks, and its transaction list joins the two by sequence and
  the verification hashes, holding at a break rather than leaving the
  archive. It checks less than the page: no checksum of the tip's event
  files, and nothing of the commitments running on by tree position.
- **Android's page named the phone.** Its own requests (the RPC, rail-squid,
  the screening node, the artifacts) carried the WebView's default
  User-Agent, with the phone's model and Android build. The page now sends
  the archive fetch's `Mozilla/5.0` (H18). Asked from the Mac with the page's
  origin, the keyless RPCs (publicnode on both networks, dRPC, BlockPI,
  Tenderly, Pocket, MEV Blocker), rail-squid on both networks, the Sepolia
  list, the screening node, the IPFS gateway and the mirror answered it as
  they answer the WebView's own, preflights included; OnFinality's and
  Ankr's keyless endpoints turn every User-Agent away alike (a rate limit, a
  key), and the keyed providers serve clients of every kind.

Still open:

- **A tree's last batches.** Nothing in the events shows where a notes tree
  ended. The archive's position check takes a batch at the next tree's start
  whatever the last tree's end (`archiveCommitments`), at every seam, and the
  page checks no positions of rail-squid's; a tree that ends at a batch has a
  root the contract recorded, which the end-of-scan check accepts. So
  a tree's last batches missing would go unseen, and a wallet would miss its
  notes there. Railgun starts a new tree only for a batch that doesn't fit in
  the last (`Commitments.insertLeaves`), so the page could require, where a
  batch starts the next tree, that the last tree's end plus that batch's
  leaves exceed 65,536. That holds at all four of mainnet's rollovers (trees
  of 65,536, 65,535, 65,536 and 65,536 leaves, then first batches of 1, 2, 2
  and 1), and would show any missing tail as long as the new tree's first
  batch, or longer.
