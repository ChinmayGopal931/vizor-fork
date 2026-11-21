# Shielded USD (Private USD) on Windows

The Railgun page host for Veylor's Windows desktop app (2026-11-21), so Shielded
USD runs there as it does on the Mac and Linux: the same Dart screens and
providers (`docs/private-usd-macos.md`), the same Rust engine, and a host of its
own, on WebView2.

Read AGENTS.md's "Private USD" section and `docs/private-usd-android-plan.md`
§3.5 first: every invariant there holds on Windows, because the engine and the
Dart flows are the phones' and the Mac's own. What every Railgun page host must
do is [docs/private-usd-railgun-hosts.md](private-usd-railgun-hosts.md) (H1 to
H37, Android the reference); "Against the hosts checklist" below says where
Windows stands on each item.

## Why WebView2

WebView2 is Chromium, as Android's WebView is, so the page runs on the engine
the reference was tested on: Android's transport (a `MessagePort`), its
archive path (no prelude: the page finds no WebKit host and reads the archive,
and the host answers its requests) and Chromium's storage rules. It ships with
Windows 11 and comes to Windows 10 through Edge's updates (the Evergreen
WebView2 Runtime); the app links the SDK's static loader and ships no
runtime. Where the runtime is missing (an old Windows 10), `supported` is false
and Shielded USD stays hidden.

## The host

Everything runs in Veylor's process, on the UI thread, in `windows/runner/`:

- `railgun/railgun_host_channels.cpp`: the channels, the iOS, Mac and Linux
  hosts' contract method for method and code for code
  (`com.zcash.wallet/railgun` and `/events`: `supported`, `load`, `call`,
  `close`, `wipe`, `isOpen`), one answer per call, `bad_args`; `debug` counts
  only in a Debug build.
- `railgun/railgun_page_host.cpp`: the process-wide page, one at a time; its
  environment, its store, the wipe, the event buffer (256), and its visibility.
- `railgun/railgun_page.cpp`: one page in WebView2: the transport, the filter,
  the page's own files, the locks (navigation, windows, dialogs, downloads,
  permissions, external schemes, sign-ins, context menus), and its 1×1 window.
- `railgun/railgun_channel.cpp`: the pending calls, their timeouts (a timeout
  closes the page) and the 30 s load timeout: the Mac's `RailgunChannel`.
- `railgun/railgun_requests.cpp`: where each request goes (Android's
  `RailgunRequests.route`), the allowlist, and the bundle's files.
- `railgun/railgun_archive.cpp`: the archive's requests, answered through the
  wallet library's fetch (below).
- `railgun/railgun_dispatch.cpp`, `railgun_network.cpp`: the UI thread's timers
  and posted work, the bridge's loopback check, and the network watch.
- `private_usd_channels.cpp`: Privacy Pass attestation (`unavailable`, as on
  iOS, the Mac and Linux), the keep-awake flag and the settlement reminder.
- `session_lifecycle.cpp`: the session away (below).

Linux's portable files are compiled unchanged: the protocol and its method and
event tables (`linux/runner/private_usd/railgun_protocol.*`), the JSON reader
(`railgun_json.*`) and the hosts and CSP (`linux/runner/railgun_page/
railgun_endpoints.*`), so the Rust tests that pin Linux's lists pin Windows's
too. Keep them free of GLib and GTK.

Registration is `PrivateUsdChannels` in `FlutterWindow::OnCreate`, before
Dart's bootstrap asks `supported`. `supported` reads the runtime's version
(the stable channel only, 120 or later) without starting it, so the bootstrap
asks it before the first frame, as on the Mac.

## The page

- **An environment per page.** WebView2's proxy is its browser process's, set
  when the environment is made (`--proxy-server=socks5://127.0.0.1:<bridge
  port>`), so every load makes an environment on the bridge it is given, once
  the last page's browser process has exited (`BrowserProcessExited`, 20 s at
  most, then retried while the store is still held). No pooled socket outlives
  a route (H17).
- **Nothing around the bridge.** `<-loopback>` drops Chromium's direct route to
  loopback, every name Chromium would look up itself resolves to nothing
  (`--host-resolver-rules`), and QUIC, WebRTC's UDP, background networking,
  component updates, domain reliability, pings, tracking prevention's lists and
  extensions are off. Chromium hands a SOCKS5 proxy the hostname unresolved.
- **The page's origin.** `veylor-railgun://app`, registered secure with an
  authority, the iOS, Mac and Linux origin, so its requests carry the same
  `Origin` (an Alchemy origin allowlist needs it). `WebResourceRequested`
  serves the bundle from `data\railgun` beside the executable (installed from
  `ios/Runner/Railgun/railgun/`, no third copy), GET only, only the page's
  types, no path outside it, with the page's CSP as a header.
- **The filter.** `WebResourceRequested` sees every request, the page's
  workers' included: the page's files, a GET of Anon's archive (answered by the
  host), https to the allowlisted hosts on the default port (out through the
  bridge), `blob:` and `data:`, and a 403 for anything else.
- **The transport.** The page takes Android's `MessagePort` when it finds no
  WebKit host (`index.js`), and WebView2 can hand a page no port. A script that
  runs before the page's own (`AddScriptToExecuteOnDocumentCreated`) keeps one
  end of a `MessageChannel` and relays it to and from `chrome.webview`
  (WebView2's message API), and once the page has loaded hands the other end
  over as Android's `postWebMessage` does, in a `message` event with
  `vizor-railgun-init` and no source window. The page is unchanged. Only the
  page's own main frame's messages count, while it still shows the page's URL;
  replies go back with `PostWebMessageAsString`, the request spliced as on the
  other hosts.
- **Headers that name nothing.** The page's User-Agent is Android's
  `Mozilla/5.0` (`put_UserAgent`), and DevTools' override of the string alone
  turns off the User-Agent client hints WebView2 would still send
  (`Sec-CH-UA*`, which name Windows and the runtime's version), as Android's
  WebView turns them off for a page whose User-Agent its host set. Every
  computer sends `Accept-Language: en-US` (the environment's language).
  SmartScreen is off, so no URL goes to Microsoft.
- **Out of sight.** The page's window is 1×1 at the top left of Veylor's
  window, beneath the Flutter view, which covers it, and disabled, so neither
  the pointer nor the keyboard reaches it; focus that does goes back to the
  Flutter view. The renderer builds no accessibility tree, so a screen reader
  finds nothing. Chromium's own occlusion tracking is off, so a page under the
  Flutter view runs unthrottled.
- **The store.** WebView2's user data folder,
  `%LOCALAPPDATA%\<company>\<product>\railgun-page` (`com.veylor\Veylor`,
  `com.veylor\Veylor Testnet`): the identity's local data, named by the version
  resource as path_provider and the uninstaller name it, so each identity has
  its own, no roaming profile carries it and File History skips it. The
  uninstaller deletes it with the rest of the app's data. A crash's dump stays
  in it (custom crash reporting), never sent to Microsoft.
- **Never closed for memory** (H11): only Dart closes the page, and a call that
  timed out or a renderer or browser process that died.

## Anon's archive on Windows

As on Android: no prelude (H22). The page finds no `webkit` and reads the
archive, and the host answers every GET of `https://digest.anon.inc/…` on the
default port from `WebResourceRequested`, through the request's deferral, with
`Access-Control-Allow-Origin: veylor-railgun://app` and `Cache-Control:
no-store` (H26).

The fetch itself is the wallet library's (`rust/src/railgun_archive.rs`,
compiled for Windows only, over a C ABI that `railgun_archive.cpp` finds by name
in `rust_lib_zcash_wallet.dll`): Windows's HTTP stacks have no SOCKS5 client
(WinHTTP has no SOCKS at all, WinINet only SOCKS4, which looks the name up
locally). It is Android's fetch, item by item:

- through the page's own bridge on loopback, by hostname (SOCKS5 address type
  3), so the bridge resolves it on the wallet's route and checks it against its
  allowlist; TLS end to end with the WebPKI roots, and `http/1.1` alone in ALPN;
- exactly Android's headers (H24): `Host`, `User-Agent: Mozilla/5.0`,
  `Accept-Encoding: identity` and `Connection: Keep-Alive`; no redirect
  followed, nothing decoded, no cookie, cache or credential;
- Android's limits (H25): 20 s to connect through the bridge, 20 s for TLS, a
  read that stalls 20 s, 60 s and 16 MB (declared or read) an answer; a failure
  is a 502 with no body;
- Android's connections (H27): one request per connection at a time (HTTP/1.1,
  never multiplexed); one whose answer was read whole is kept, five idle at
  most, five minutes each; one whose request failed, stalled or was refused for
  its size is closed; a change of network (`NotifyIpInterfaceChange`) drops the
  kept ones; a kept one the far end closed is replaced at no cost to the page's
  tries;
- closed with the page (H29): every fetch ends unanswered and every connection
  closes.

The answers come back on the library's threads and are handed to the UI thread,
where the deferral completes. WebView2 doesn't say when the page aborts a
request, so a fetch the page abandoned runs to its own end and its answer is
dropped, as on Android (H28). Without the library's fetch every archive request
is a 502, and the page leaves the archive for rail-squid.

`privateUsdArchiveAvailableProvider` offers the setting on Windows mainnet
wherever the host runs the page.

## Foreground and keep-awake on Windows

- **The window.** Flutter's embedder reports `hidden` for a minimised or hidden
  window, `inactive` for one without focus and `resumed` otherwise
  (`windows_lifecycle_manager.cc`). A covered window is not detected, so
  Shielded USD runs on behind other windows, as on Linux.
- **The session away.** `session_lifecycle.cpp` says `hidden` on
  `flutter/lifecycle` while the user is away, as `MacSessionLifecycle` and
  Linux's do, reacting to changes only:
  - the session locked (`WTS_SESSION_LOCK` until `WTS_SESSION_UNLOCK`);
  - another session on the console, or a remote session disconnected (fast
    user switching, RDP);
  - the computer asleep (`PBT_APMSUSPEND` until its resume);
  - the display off (`GUID_CONSOLE_DISPLAY_STATE`), as the Mac's displays
    asleep: modern standby sends no suspend.

  While the user is away, every window-state change the embedder reports is
  followed by `hidden` again (100 ms after it, past the embedder's own run-loop
  turn). Once nothing keeps the user away, it sends the state the embedder
  would report, and again a second later.
- **The page's visibility.** The page is shown while Veylor's window shows and
  the session is not away, and hidden (`put_IsVisible(FALSE)`, which WebView2
  throttles) otherwise, as WebKit suspends the Mac's page whose window can't be
  seen.
- **Keep-awake.** `com.zcash.wallet/screen_awake` holds
  `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED |
  ES_DISPLAY_REQUIRED)`: neither the display nor the computer sleeps on idle
  while it is held, and the user can still lock or sleep. Dart takes it as on
  the Mac (`SyncKeepAwakeNativeHost`, Private USD only).
- **The settlement reminder.** `com.zcash.wallet/haptics`'s
  `settlementDeadline` flashes the window's taskbar button until Veylor is in
  front again (none while it is: `FLASHW_TIMERNOFG`) and plays the default
  sound (`MessageBeep`). Every other haptics call answers not implemented.

## Copy

Windows uses the desktop messages' "your computer" twins that Linux uses
(`privateUsd…Linux`, in English, Korean and Chinese), chosen by
`privateUsdComputerWording`: the quote clock, the keep-visible row's tooltip
(minimised, locked or asleep: a covered window doesn't pause the bridge), the
reverse bridge's proof note, and the send and withdraw proof steps.

## Failure codes

Windows's host messages are read as Linux's and the Mac's are
(`private_usd_diagnostics.dart`): "the page did not load", "loading the page
timed out", "the page's renderer stopped", "the bridge is not running" and the
rest. Two are Windows's own: `os_unsupported` for "Shielded USD needs the
WebView2 Runtime", and `webview_failed` when WebView2 or the page's window would
not start.

## Packaging

- **The build** is upstream's: `scripts/package-windows-velopack.ps1` with
  `-ApplicationId com.veylor.desktop` (or `.testnet`), as `fastlane windows
  package` passes it. For Veylor's identity it now names the executable
  `Veylor.exe` (`VeylorTestnet.exe`) once it is built, as its version
  resource's original file name, and the package's authors Zapp LLC, so nothing
  the package installs names Vizor; `flutter run` still finds `Vizor.exe`. It
  passes `VIZOR_PRIVATE_USD_ENABLED` and a build number when they are given.
- **The WebView2 SDK** comes from NuGet, pinned by version and SHA-256
  (`windows/runner/webview2_sdk.cmake`); only its headers and static loader are
  used.
- **CI** (`.github/workflows/veylor-windows.yml`) builds both identities for
  x64 (windows-latest) and ARM64 (windows-11-arm), unsigned and with no update
  feed, stamped `0.9.0-internal.<run>` (or `0.9.0` on a dispatch with
  `public_release`), and keeps the Velopack installer and package as artifacts
  (`Veylor-windows-x64`, `Veylor-Testnet-windows-arm64`, …).
  `scripts/check-veylor-windows-package.py` checks each: the defines it
  compiled with (no keyed RPC URL), the executable's name and version resource,
  the page's bundle, and the installer's and package's names and manifest.
  The job then installs Veylor Testnet silently and checks what Windows shows
  of it: Apps & features names it Veylor Testnet and its publisher Zapp LLC, the
  Start menu's shortcut is Veylor Testnet (none names Vizor), and the app keeps
  running, its window titled Veylor Testnet, with no WebView2 of its own before
  an unlock. Upstream's packaging checks run on fixtures first, under
  PowerShell 7.

## Pins

The Rust tests in `rust/src/railgun_bridge.rs` hold Windows to the others:
Linux's `kHosts`, events and methods (which Windows compiles) against the
bridge's allowlist, Kotlin's and Swift's lists and the page's CSP; and
`the_windows_host_fetches_the_archive_and_hands_over_the_port_as_android_does`
holds `kArchiveHost` and `railgun_archive`'s host, limits, User-Agent and pool
to Android's, `kUserAgent` to Android's, and the transport's hello to
`RailgunProtocol.INIT` and the page's. `railgun_archive`'s own tests check its
headers, limits and connection rules against a local stand-in.
`veylor-windows.yml`'s `pins` job runs both.

## How it differs from the Mac and Linux

- **Chromium, not WebKit.** Android's transport and archive path, so no
  prelude; the transport needs a script of the host's own, which the page
  doesn't know is there.
- **An environment per page**, where the Mac sets a store's proxy and Linux
  starts a process: WebView2's proxy is its browser's.
- **The archive's fetch is the wallet library's**, over a C ABI, where the Mac
  uses `URLSession` and Linux libsoup.
- **A covered window** doesn't pause Shielded USD (as on Linux; the Mac's
  engine reports occlusion).
- **The page's window** sits beneath the Flutter view in Veylor's window, as
  the Mac's web view does; Linux's is an offscreen window in another process.
- **Backups**: the store is in local app data, which neither roaming profiles
  nor File History carry; there is no exclusion flag to set.
- **Accessibility**: the renderer builds no accessibility tree, where the Mac's
  view refuses VoiceOver and Linux's process runs without the bridge.

## Against the hosts checklist

[docs/private-usd-railgun-hosts.md](private-usd-railgun-hosts.md), item by
item. Items not named here hold as on Android.

- **H1.** The same contract. `supported` is the runtime's registration, read
  without starting it (stable channel, version 120 or later).
- **H4.** Windows joins `privateUsdPlatformHostsPage` and
  `privateUsdArchiveAvailableProvider`, and `private_usd_archive_sync_test.dart`
  covers it. `replaceDeadBridge` stays iOS's.
- **H5, H6.** The page's own origin, registered secure, served by the host with
  its types and the CSP header; the check program checks a secure context,
  `crypto.subtle`, WebAssembly, IndexedDB, `localStorage` and a module worker
  from `blob:`.
- **H7.** Android's `MessagePort`, handed over by the host's own script (above);
  only the main frame's messages, from the page's URL.
- **H8.** Locked down: one navigation, nothing else; a renderer or browser
  process that dies closes the page.
- **H9.** One store, the environment's user data folder, wiped whole once the
  browser process has exited (retried). Chromium enforces an origin's quota at
  60% of the disk, as on Android. The page's own `navigator.storage.estimate()`
  reports its usage plus 10 GiB whatever the disk (Chromium's StaticStorageQuota,
  since 133), so the check program reads the enforced quota from DevTools.
- **H10.** The page runs unthrottled under the Flutter view while the window
  shows (the check program counts its timers), and is hidden while the window
  is minimised or the session away.
- **H11.** Never closed for memory.
- **H12.** `blob:` workers run (the check program's Sepolia sync reports them).
- **H13, H14, H16.** The environment's proxy is the bridge, with no direct
  route and no local lookup; Chromium sends a SOCKS5 proxy the hostname, and
  runs no QUIC through one.
- **H15.** The filter, `kHosts` and the page's CSP; a host the CSP allows but
  the filter refuses gets a 403 and is never dialled (the check program).
- **H17.** A new environment per page, after the last one's browser has exited.
- **H18.** A fixed `Mozilla/5.0`, no client hints, and `Accept-Language: en-US`.
- **H21.** Not Windows's: no WebKit.
- **H22–H31.** The host's fetch is the wallet library's (above).
- **H28.** WebView2 doesn't say when the page aborts a request: the fetch runs to
  its own end and its answer is dropped, as on Android.
- **H30.** The fetches run on the wallet library's own threads (two), and their
  answers are handed to the UI thread.
- **H35.** The keep-awake flag is `SetThreadExecutionState`.
- **H37.** Windows's host messages read as the others', with two of their own.

## What has run (2026-11-21)

On GitHub's runners only: no Windows machine, no wallet and nothing spent. The
page ran BIP-39's public test wallet, read-only, through a SOCKS5 stand-in for
the bridge (`scripts/windows-railgun/check_railgun_page.py`) that accepts what
the bridge accepts and logs each `CONNECT`.

- **The spike, on the host's own code** (`veylor-windows.yml`'s Railgun page
  jobs, the check program; x64 on Windows Server 2025, ARM64 on Windows 11
  25H2, WebView2 Runtime 157):
  - **The page.** It loaded from `veylor-railgun://app` and said it was ready
    in 0.8 to 2.4 s (5 to 6 s for the runtime's first start on a fresh x64
    runner): a
    secure context, `crypto.subtle`, WebAssembly (instantiated under
    `'wasm-unsafe-eval'`), IndexedDB, `localStorage` and a module worker from
    `blob:`; `document.visibilityState` visible and 493 timer turns in 2 s
    under the stand-in for the Flutter view, so unthrottled.
  - **The transport.** `start`, `openWallet`, `refresh` and the debug page's
    `noteKeys` answered, and the `scan`, `refresh`, `screening` and `synced`
    events came through; no `log` event from a page loaded without debug.
  - **A Sepolia first sync** reached `synced` in 44 to 45 s on x64 and 53 to
    55 s on ARM64 (the refresh answered after 21 s and 25 to 26 s), with the
    note-key workers' 12,253 of 12,287 points prepared in two workers (four
    cores). Opened again on the same store, the engine's IndexedDB
    (`level-js-railgun-sepolia`) was there before `start`, and the refresh
    answered in 1.6 to 3.3 s.
  - **Every connection through the stand-in, by name.** Every `CONNECT` was a
    hostname (SOCKS5 type 3) on 443 (publicnode's Sepolia RPC, the screening
    node and the Sepolia list), and the stand-in refused none. With Windows's
    firewall blocking the WebView2 Runtime's program from every address but
    loopback, the sync went through as before; sampled during it, the page's
    own processes (the check program's browser process and its children, six)
    held only loopback TCP connections (38 seen on x64), and no UDP socket.
    The Windows 11 runner also ran another app's WebView2, which talked to
    Microsoft directly; the sampler counts those apart since 2026-11-21.
  - **The filter and the CSP.** A host the CSP allows but the filter was told
    to refuse failed in the page and was never dialled, and so did one off the
    CSP. Anon's archive answered for the page's origin: without the wallet
    library, a readable 502, never dialled.
  - **Headers.** On the wire (DevTools' `requestWillBeSentExtraInfo`), every
    request's User-Agent was `Mozilla/5.0` and its `Accept-Language` en-US,
    with no `Sec-CH-UA*`, and `navigator.userAgentData` had no brands. The
    first run, before DevTools' override, sent `Sec-CH-UA*` on every request
    (fixed 2026-11-21).
  - **The quota.** Chromium enforces 60% of the volume for the page's origin
    (DevTools' `Storage.getUsageAndQuota`); the page's own estimate reported its
    usage plus 10 GiB, which the first run took for the quota.
  - **The archive.** A mainnet `start` with the archive asked the host for it
    (ten requests in 90 s), and without the wallet library none was dialled.
  - **The wipe** removed the store whole once the browser process had exited.
  - **A new page on another bridge**, as after a route change, a lock or the
    idle close: a page closed and loaded again in the same process on a second
    stand-in was ready 1.1 to 1.2 s later (the last browser process exited and
    a new environment was made); its request to the RPC went through the second
    stand-in with a `CONNECT` of its own, and nothing went through the first
    once its page had closed, so no pooled socket outlived the route (U19).

- **The packages** (`veylor-windows.yml`'s Package jobs, runs 44871895018 and
  44874351505, the first run green throughout, x64 and ARM64): both identities
  built as `Veylor.exe` and `VeylorTestnet.exe`,
  their version resources naming Veylor or Veylor Testnet, `com.veylor` and
  Zapp LLC, with the page's bundle in `data\railgun`; the installers are
  `com.veylor.desktop-win-<arch>-mainnet-Setup.exe` and
  `com.veylor.desktop.testnet-win-<arch>-testnet-Setup.exe`, and no output,
  file of the app or manifest field names Vizor.
- **Installed.** Veylor Testnet's installer ran silently; Apps & features
  names it Veylor Testnet and its publisher Zapp LLC, the Start menu's
  shortcut is Veylor Testnet, and the app kept running with its window titled
  Veylor Testnet and no WebView2 before an unlock. (The first install's window
  read Veylor: Dart titled it over the runner. Fixed 2026-11-21.)
- **The archive through the wallet library**: the check program with the
  app's own `rust_lib_zcash_wallet.dll`, a mainnet first sync reading the
  archive for 90 s. On x64 the page asked for 180 files and 179 came back (one
  was in flight when it stopped), over five connections, then 144 of 144; on
  ARM64 110 of 110, over four, both times. Every connection went to `digest.anon.inc` through the stand-in by
  name, and none failed. (An earlier run's check passed without the library,
  whose dependencies it hadn't found; the check now requires it.)

Not run: anything with a wallet in the app (the page in Veylor itself, behind
the unlock: the real bridge, Tor, sends, deposits and bridges, the archive in
the app and the checklist's real sync, 7.3), the keep-awake hold, the
settlement reminder, the session lifecycle (lock, sleep, display off, fast user
switching), a covered or minimised window's throttling, a screen reader, and
Windows 10.

## Trying it on a Windows 11 ARM computer (or VM)

Nothing here needs a wallet with funds; a testnet wallet is enough.

1. **Install.** From a `Veylor Windows` run's artifacts take
   `Veylor-Testnet-windows-arm64` (or `Veylor-windows-arm64` for mainnet), unzip
   it and run `com.veylor.desktop.testnet-win-arm64-testnet-Setup.exe`. The
   installer is unsigned: SmartScreen says "Windows protected your PC" until
   "More info", then "Run anyway". Velopack installs per user, in
   `%LOCALAPPDATA%\com.veylor.desktop.testnet`, with Start menu and desktop
   shortcuts named Veylor Testnet, and starts the app. The x64 packages run
   too, emulated, but the ARM64 ones are native.
2. **Shielded USD shows** only where the WebView2 Runtime is (Windows 11 has
   it): after the unlock, Home's Shielded USD strip sits under the transparent
   tray. Opening it starts Railgun's first sync, which the sidebar's second
   readout then follows; on Sepolia a new wallet's takes about a minute.
3. **The page's processes.** Task Manager shows WebView2's processes
   (`msedgewebview2.exe`) under Veylor Testnet while the page is open. Other
   apps run WebView2 too, so to see only Veylor's connections, in PowerShell:

   ```powershell
   $veylor = (Get-Process VeylorTestnet).Id
   $all = Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'"
   $browser = @($all | Where-Object ParentProcessId -eq $veylor)
   $page = @($all | Where-Object { $_.ProcessId -in $browser.ProcessId -or $_.ParentProcessId -in $browser.ProcessId })
   Get-NetTCPConnection -OwningProcess $page.ProcessId | Format-Table LocalAddress, RemoteAddress, RemotePort, State
   Get-NetUDPEndpoint -OwningProcess $page.ProcessId -ErrorAction SilentlyContinue
   ```

   Every connection is to `127.0.0.1` (the bridge) and there is no UDP
   endpoint; `VeylorTestnet.exe` itself holds the connections out.
4. **The lifecycle.** Lock (Win+L) during a first sync and unlock: the sync
   goes on from where it was, and nothing fails. Minimise and restore the same
   way. `powercfg /requests` (as administrator) lists `VeylorTestnet.exe` under
   DISPLAY and SYSTEM while Shielded USD keeps the computer awake (a first
   sync, a bridge with a key step to come), and not otherwise.
5. **The settlement reminder.** With a USD → ZEC bridge waiting on "Authorize
   settlement" and another app in front, Veylor's taskbar button flashes and
   the default sound plays.
6. **The failure codes**, if something fails:
   `%APPDATA%\com.veylor\Veylor Testnet\diagnostics\private-usd-*.jsonl` (or
   Settings, which copies them).
7. **Remove** from Settings > Apps: the uninstaller deletes the app's data,
   the Railgun page's store (`%LOCALAPPDATA%\com.veylor\Veylor Testnet\
   railgun-page`) with it.
