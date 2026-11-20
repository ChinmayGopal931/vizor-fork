# Shielded USD (Private USD) on Linux

The Railgun page host for Veylor's Linux desktop app (2026-11-20), so Shielded
USD runs there as it does on the Mac: the same Dart screens and providers
(`docs/private-usd-macos.md`), the same Rust engine, and a host of its own. It
is Linux only; Windows still hides Shielded USD.

Read AGENTS.md's "Private USD" section and `docs/private-usd-android-plan.md`
§3.5 first: every invariant there holds on Linux, because the engine and the
Dart flows are the phones' and the Mac's own. What every Railgun page host must
do is [docs/private-usd-railgun-hosts.md](private-usd-railgun-hosts.md) (H1 to
H36, Android the reference); "Against the hosts checklist" below says where
Linux stands on each item.

## Why two processes

The page runs in `veylor-railgun-page`, a small program beside Veylor's
executable, not in Veylor's own process:

- **The AppImage's libraries.** AppRun puts the AppImage's `usr/lib` on
  `LD_LIBRARY_PATH`, and it holds Ubuntu 22.04's GStreamer 1.20 (for the QR
  scanner), orc, libdw and pipewire. A system WebKitGTK built against GStreamer
  1.24 can't load beside them: in the test VM it died at once on
  `libgstgl-1.0.so.0: undefined symbol: gst_video_is_dma_drm_caps`, and WebKit's
  own processes inherit the environment. Veylor starts the page process with a
  clean environment (`CleanEnvironment` in `railgun_host.cc`), so it and
  WebKit's processes load the system's libraries alone.
- **WebKit's sandbox.** WebKit aborts its process (`g_error`) when bubblewrap
  can't start. In a process of its own that abort ends the page, never Veylor.
- **Isolation.** WebKit's UI-process code never runs in the process that
  holds the wallet. The page process inherits no descriptor but its link
  (GSubprocess closes the rest).

## The host

**Veylor's side** (`linux/runner/private_usd/`) speaks the iOS and Mac hosts'
channel contract, method for method and code for code
(`com.zcash.wallet/railgun` and `/events`: `supported`, `load`, `call`, `close`,
`wipe`, `isOpen`):

- `railgun_host.cc`: the channels, one answer per call and `bad_args`; the
  sandbox check behind `supported`; one page at a time, each with its pending
  calls, their timeouts (a timeout closes the page) and the 30 s load timeout;
  the event buffer (256); the wipe; and the page's visibility. Memory pressure
  never closes the page, as on Android (H11).
- `railgun_protocol.h/.cc`: the methods and timeouts, the events, the request
  envelope (params spliced, never re-serialized) and the page's replies, read
  by `railgun_json.cc`, a strict reader that keeps every value as its text.
- `railgun_frames.h/.cc`: the link to the page process, a socket pair carrying
  length-prefixed frames (deliver, visible, quit; message, undelivered,
  closed). Neither end logs a payload.
- `private_usd_channels.cc`: Privacy Pass attestation (`unavailable`, as on
  iOS and the Mac), the keep-awake flag and the settlement reminder (below).
- `session_lifecycle.cc`: the session away (below).

Registration is `register_private_usd_channels` in `my_application.cc`'s
`activate`, before Dart's bootstrap can ask anything.

**The page process** (`linux/runner/railgun_page/`):

- `webkit_api.h/.cc`: WebKitGTK 4.1 (GTK 3's, as Flutter's runner uses),
  its JavaScriptCore and libsoup 3, `dlopen`ed at run time and every function
  resolved into a `decltype(&fn)` pointer. It is compiled against their headers
  and links none of them; no macro that calls a `*_get_type` function is used.
  WebKitGTK older than 2.44 is refused.
- `railgun_page.cc`: one page, as iOS's and the Mac's are:
  - Its context has a persistent data manager of its own, in the app's support
    directory beside the wallet, so each identity has its own:
    `$XDG_DATA_HOME/<application id>/railgun-page/` (`data`, `cache`,
    `filters`), or under the executable's name where path_provider named the
    support directory so (it does where it can't load libgio's development
    link, as on most machines).
    A `CACHEDIR.TAG` there keeps it out of backups that honour one (Déjà Dup,
    Borg, restic), as the Mac keeps its store out of Time Machine.
  - Its proxy is `socks5://127.0.0.1:<bridge port>`, with no direct route (the
    bridge is checked before any load).
  - The `veylor-railgun` scheme is registered as secure and CORS-enabled. It
    serves the bundle from `data/railgun/`, which CMake installs from
    `ios/Runner/Railgun/railgun/` (no third copy). It sends iOS's CSP header and
    answers only GET, only the page's types, and no path outside the folder.
  - The content filter is iOS's rule list, compiled from the same hosts by
    `WebKitUserContentFilterStore`, which takes Safari's JSON.
  - Messages arrive through the `railgunHost` script message handler and go out
    through `webkit_web_view_call_async_javascript_function`, the message an
    argument, never spliced into the script.
  - Navigation stops after the page's first load. Windows, dialogs, file
    pickers, downloads, notifications, printing, sign-ins and permissions are
    all refused.
  - The view is 1×1 in a `GtkOffscreenWindow`, so it takes no pointer,
    keyboard or focus, and the process runs with `NO_AT_BRIDGE=1`, out of
    accessibility. WebKit runs the page unthrottled while that window is
    shown, and treats it as hidden while it is not.
- `railgun_archive.h/.cc`: Anon's archive, as on Android and the Mac (below).
- `railgun_endpoints.h/.cc`: the hosts, the CSP and the content rules.

**The clean environment**: the session's display, D-Bus, locale, home and XDG
directories, with the AppImage's own entries removed from `XDG_DATA_DIRS` and
`PATH`, and `NO_AT_BRIDGE=1`. Nothing else, so no `LD_*`, no GStreamer paths, no
`http_proxy`, and no `WEBKIT_*` (which could turn the sandbox off).

## The sandbox is required

The page process always enables WebKit's sandbox, and the page never runs
outside it:

- **The check.** `supported` runs `veylor-railgun-page --probe` once per launch.
  It loads WebKitGTK, starts a sandboxed page, checks WebAssembly and IndexedDB,
  and checks that the web process is bubblewrap's child, not its own: a WebKit
  built without the sandbox would start it directly. WebKit's `g_error` for a
  sandbox that can't start becomes exit status 3 (a GLib log writer), never a
  crash report.
- **Every page checks it again.** On the page's hello, a web process outside
  bubblewrap closes the page as `unavailable`.
- **Where it fails**, `supported` is false and Shielded USD stays hidden, as
  below macOS 14.
- **Asked after the first frame.** On Linux the bootstrap does not wait for
  `supported` before the first frame (`app_bootstrap.dart`), so the check (a
  second or so) never delays the start. It starts once the first frame is up,
  `RailgunHostSupportedNotifier` takes its answer, and Shielded USD shows when
  the check passes.

**Ubuntu 23.10 and later** refuse user namespaces to programs no AppArmor
profile allows (`kernel.apparmor_restrict_unprivileged_userns=1`), so
bubblewrap fails there: `bwrap: setting up uid map: Permission denied`. Ubuntu
gives its own WebKitGTK apps a profile that allows them (Epiphany's, Geary's).
Veylor's .deb does the same for its page process. An AppImage can't, since its
programs run from a random `/tmp/.mount_*` path, so Ubuntu hides Shielded USD
in the AppImage. Fedora, Debian, Arch and openSUSE allow user namespaces, and
the AppImage runs the page there.

## Anon's archive on Linux

As on the Mac (`docs/private-usd-macos.md`, "Anon's archive on the Mac") and
the checklist's sections 4 and 5:

- **The prelude** (`kArchivePrelude`) is the Mac's. WebKit makes
  `window.webkit` non-configurable, so it hides the host by defining
  `messageHandlers` on the page's `webkit` object. It also holds that object on
  the global: WebKit makes a new one, with the real handlers, once nothing in
  the page refers to it, so a garbage collection before the `start` would show
  the host again and the page would skip the archive (H21). It re-hides the host
  on every run. The page's transport took the handler when it loaded, and keeps
  posting.
- **The fetch** (`ArchiveFetch`) is libsoup's, through a pool whose only route
  is `socks5://127.0.0.1:<bridge port>`, as Android's host fetches:
  - 16 MB and a minute an answer at most, a 20 s connect or read stall, and a
    502 for any failure;
  - no redirect, cache, cookie, credential, decoding or sniffing;
  - exactly Android's headers (H24): `Host`, `User-Agent: Mozilla/5.0`,
    `Accept-Encoding: identity` and `Connection: Keep-Alive`, with no
    `Accept-Language` (`accept-language-auto` off) and no cache directive.

  **Connections, as Android keeps them (H27).** Each request is HTTP/1.1, so a
  connection carries one at a time and a stalled connection costs only the try
  sent on it. libsoup offers HTTP/2 only on a direct connection, never through
  a proxy, so the bridge's route alone gives HTTP/1.1 (Ubuntu 22.04's 3.0,
  Debian 12's 3.2); from 3.4 the request also asks for it
  (`soup_message_set_force_http1`, resolved by name, since older headers lack
  it). The pool keeps five per host, each idle five minutes at most. An answer
  read whole leaves its connection for the next request. Any other end (a
  failure, a stall, the size cap, the deadline) closes its body cancelled, so
  libsoup never uses that connection again. A network change
  (`GNetworkMonitor`) starts a new pool for the next request, and the old one
  goes with its last request.

  WebKitGTK has no stop call for a scheme request, so a fetch the page
  abandons runs on to its end and its answer is dropped, as on Android (H28);
  the page's close cancels them all and aborts the pools.

`privateUsdArchiveAvailableProvider` offers the setting on Linux mainnet
wherever the host runs the page.

## Foreground and keep-awake on Linux

- **The window.** Flutter's Linux embedder reports `hidden` for a minimised or
  withdrawn window, `inactive` for one without focus, `resumed` otherwise
  (`fl_window_state_monitor.cc`). On Wayland, GTK 3 never learns that its
  window was minimised, so a minimised window is `inactive` there, and Private
  USD runs on, as it does in an unfocused window. A covered window is not
  detected either.
- **The session away.** `session_lifecycle.cc` says `hidden` on
  `flutter/lifecycle` while the user is away, as `MacSessionLifecycle` does.
  Like the Mac's notifications, it reacts to changes only, never to a state
  read at the start, which in an odd setup (another session's lock) could
  hide the app for good. It listens to these:
  - logind's `PrepareForSleep`;
  - the session's `LockedHint` and `Active`: the user's display session, else
    the process's own;
  - GNOME's or the freedesktop screensaver's `ActiveChanged`.

  While the user is away, every window-state change the embedder reports is
  followed by `hidden` again. Once nothing keeps the user away, it sends the
  state the embedder would report, and again a second later.
- **The page's window.** Veylor hides the page's offscreen window while its own
  window is minimised or withdrawn (where GTK says so) or the session is
  away, and shows it again after, so WebKit throttles the page as the Mac's
  WebKit suspends a page whose window can't be seen.
- **Keep-awake.** `com.zcash.wallet/screen_awake` holds
  `gtk_application_inhibit(…, GTK_APPLICATION_INHIBIT_IDLE)`, GNOME's session
  manager. Where that is refused, it falls back to
  `org.freedesktop.ScreenSaver.Inhibit` (KDE, Xfce). The session neither
  blanks, locks nor suspends on idle while it is held; the user can still lock
  or suspend. Dart takes it as on the Mac (`SyncKeepAwakeNativeHost`, Private
  USD only).
- **The settlement reminder.** `com.zcash.wallet/haptics`'s
  `settlementDeadline` sets the window's urgency hint until Veylor is active
  again (none while it is) and plays the desktop's alert sound
  (`gdk_window_beep`; on GNOME's Wayland, the shell's bell). Every other
  haptics call answers not implemented.

## Copy

The desktop messages that name the Mac have Linux twins that say "your
computer" (`privateUsd…Linux`, in English, Korean and Chinese), chosen on Linux
by `privateUsdLinuxWording`: the quote clock, the keep-visible row's tooltip,
the reverse bridge's proof note, and the send and withdraw proof steps.

## Packaging

- **The build** needs `libwebkit2gtk-4.1-dev` (and `libsoup-3.0-dev`) for the
  page process's headers. Without them the build has no page process, and
  Shielded USD stays hidden.
- **The AppImage.** `package-linux-appimage.sh` keeps the page process out of
  the AppDir while linuxdeploy runs, so linuxdeploy neither gives it an RPATH
  nor deploys anything for it. WebKitGTK, JavaScriptCore and libsoup are host
  libraries (`host-libraries.txt`), and `check_bundle.py` fails an AppDir
  where anything needs them. CI's `check_railgun_page.py` checks the bundle and
  the extracted AppImage with readelf.
- **The .deb** (`scripts/package-linux-deb.sh`):
  - Packages `veylor` (com.veylor.desktop) and `veylor-testnet`
    (com.veylor.desktop.testnet), which install side by side.
  - The bundle goes to `/opt/veylor` or `/opt/veylor-testnet`, with a
    `/usr/bin` link, the desktop entry and the icons.
  - A package has no AppRun to set `LD_LIBRARY_PATH`, so each bundled library
    that needs another, or carries the build tree's path, gets the RUNPATH
    `$ORIGIN` (`patchelf`): the QR scanner's plugin then finds ZXing beside it.
    CI checks with `ldd` that nothing in the installed package goes unfound.
  - Depends come from `dpkg-shlibdeps`. `libwebkit2gtk-4.1-0`, a Secret Service
    provider and GStreamer's plugins are Recommends, so the app installs
    without WebKit and Shielded USD is then hidden.
  - **The AppArmor profile** is for the page process alone:
    `/opt/<package>/veylor-railgun-page`, `flags=(unconfined)` with `userns,`,
    as Epiphany's is. The package ships it in `/usr/share/<package>/apparmor/`.
    Postinst puts it in `/etc/apparmor.d/<package>` and loads it where AppArmor
    4's `userns` rule exists (`/etc/apparmor.d/abi/4.0`): AppArmor 3 (Ubuntu
    22.04, Debian 12) can't parse it and needs none.
  - Removal unloads and deletes the profile, and purge deletes its `local/`
    file.

## Pins

The Rust tests in `rust/src/railgun_bridge.rs` hold Linux's lists to the
others'. `veylor-linux.yml`'s `pins` job runs them on CI:

- `kHosts` (`railgun_endpoints.h`) against the bridge's allowlist, Kotlin's and
  Swift's hosts and the page's CSP;
- `kArchiveHost` and the prelude against the page's `ARCHIVES`;
- `kEvents` and `kMethods` (`railgun_protocol.h`) against Kotlin's `EVENTS` and
  `RailgunMethod`.

## How it differs from the Mac

- **Two processes**, a link between them, and the sandbox checked rather than
  given. The Mac's WebKit sandboxes its content process by itself.
- **Ubuntu 23.10+ needs the .deb's AppArmor profile**, where the Mac needs
  macOS 14.
- **The page's window** is an offscreen window in its own process, hidden and
  shown by Veylor's host. The Mac places a 1×1 view in its own window.
- **Messages carry no frame or origin**, unlike WebKit on Apple. The page has no
  frames (its CSP allows none), the handler is in the page's world alone, and a
  message counts only while the view still shows the page's own URL.
- **An abandoned archive fetch** runs to its end (above).
- **Backups** are kept out by `CACHEDIR.TAG`, not a backup exclusion flag.
- **Minimise on Wayland and a covered window** don't pause Shielded USD.

## Against the hosts checklist

[docs/private-usd-railgun-hosts.md](private-usd-railgun-hosts.md), item by
item. Items not named here hold as on Android and the Mac.

- **H1.** The same contract. `supported` answers once the sandbox check has run,
  about a second, so on Linux the bootstrap asks it after the first frame rather
  than before it (kept: the check runs a process of its own).
- **H4.** Linux joins `privateUsdPlatformHostsPage` and
  `privateUsdArchiveAvailableProvider`, and `private_usd_archive_sync_test.dart`
  covers it. `replaceDeadBridge` stays iOS's: Linux keeps its sockets.
- **H6.** The scheme is registered secure. The sandbox check loads its page on
  that scheme and requires a secure context, `crypto.subtle`, WebAssembly,
  IndexedDB, `localStorage` and workers (fixed 2026-11-20).
- **H7.** WebKitGTK gives a script message no frame or origin (kept: there is no
  API for it). A message counts only while the view shows the page's own URL,
  the handler is in the page world alone, and the CSP allows no frames.
- **H9.** The store is in the app's support directory, beside the wallet, and
  is wiped whole (retried). Linux has no system backup flag: a `CACHEDIR.TAG`
  keeps the store out of the backup tools that honour one.
- **H10.** The offscreen window keeps the page unthrottled while Veylor's window
  shows, focused or not. Veylor hides it while its window is minimised or
  withdrawn or the session is away. On Wayland GTK never learns of a minimise,
  so the page runs on there (kept: GTK's limit).
- **H11.** Memory pressure never closes the page (fixed 2026-11-20).
- **H16.** libsoup, which WebKitGTK's network process uses, has no HTTP/3, so
  nothing goes around the bridge over QUIC.
- **H18.** The page's own requests carry a fixed User-Agent, `Mozilla/5.0 (X11;
  Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko)`, the same on every
  computer, as the Mac's WebKit names no model. WebKitGTK's default names the
  distribution, the processor and a release token (`Mozilla/5.0 (X11; Ubuntu;
  Linux aarch64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/60.5
  Safari/605.1.15` on the test VM) (fixed 2026-11-20).
- **H21, H24, H26, H27.** The prelude's hold, the exact headers, the buffer
  sized from a declared length, and the connection rules (above; fixed
  2026-11-20).
- **H22.** Not Linux's: no Chromium.
- **H28.** WebKitGTK doesn't tell the host when the page aborts a request, so
  the fetch runs to its own deadline and its answer is dropped, as on Android
  (kept).
- **H30.** The fetches run on the page process's main loop, never Veylor's.
- **H35.** The keep-awake flag is an idle inhibitor (above).

## What has run (2026-11-20)

In the test VM (Ubuntu 24.04.3 arm64, GNOME on Wayland, WebKitGTK 2.52.6).
No wallet was unlocked and nothing was spent: the page ran a public test
mnemonic, read-only.

- **Against the hosts checklist** (section 7, run 44796638369's arm64 .deb,
  libsoup 3.4.4). The VM's own network was down, so the stand-in for the bridge
  ran on the Mac and the VM reached it through an SSH tunnel; the page's traffic
  left only through it.
  - **The prelude under garbage collection (H21).** The real bundle, the
    prelude, then 30 rounds of garbage made in the page. With the earlier
    prelude, WebKit replaced the `webkit` object at the first collection, and
    the start's check saw the host in 30 of 30 rounds. With the held prelude it
    never did, though a full collection ran (an aged sentinel went in round 3),
    and the transport still posted.
  - **The archive path (7.1).** `load`, `start` with the archive, `openWallet`
    (BIP-39's test mnemonic, a random key) and `refresh`, eleven times, each on
    a fresh store. Every run read `digest.anon.inc` 2.3 to 2.5 s after the
    start's answer, on four connections that each carried 0.6 to 4.9 MB and
    stayed open to the end. With `"archive":false` (twice), no archive
    connection.
  - **A stalled connection (7.2).** The stand-in stopped forwarding on the
    second archive connection after 64 KB, leaving it open. libsoup gave it up
    20.0 s later and closed it, the page opened a new one six seconds after
    that, and the other three ran on throughout.
  - **The fetch's requests (H24, H27).** Three GETs through the stand-in sent
    exactly `Host`, `User-Agent: Mozilla/5.0`, `Accept-Encoding: identity` and
    `Connection: Keep-Alive`, each over HTTP/1.1 on the one connection.
  - **Sockets (section 3, H16).** During a run the page process and WebKit's
    network process held only TCP connections to the bridge's port, four of
    them the archive's, and no UDP socket.
  - **The User-Agent (H18).** A request from the page carried the fixed one.
  - **The sandbox check (H6).** The installed check passed from
    `/opt/veylor` in 0.23 to 0.45 s, on the page's secure scheme, and a copy
    outside the profile's path failed it (exit 3).
  - **The package.** Maintainer `Zapp LLC <hello@veylor.cash>`.

- **The spike.** The real bundle ran on WebKitGTK from the custom secure
  scheme:
  - origin `veylor-railgun://app`, `isSecureContext` true, WebAssembly;
  - a Sepolia `start`, `openWallet` and first sync to `synced` in about
    100 s, with POI proofs in the page;
  - IndexedDB still there after a restart (the same wallet reopened and
    synced);
  - the content filter blocking a host the CSP allows but the list doesn't;
  - every connection through the SOCKS5 proxy by hostname, port 443.
- **The sandbox check.** Without a profile: exit 3 after about a second
  ("Failed to fully launch dbus-proxy"), and no crash report. Under Ubuntu's
  Epiphany profile (`aa-exec`, no system change): passed in 0.55 s.
- **The page process**, driven over its link by a test script:
  - The page said ready in 1.1 to 3.7 s, and a Sepolia first sync reached
    `synced` in 100 s.
  - A mainnet `start` with the archive took the prelude, and the page read
    Anon's archive through the libsoup fetch and the proxy (351 MB stored in
    two minutes).
  - The web process ran inside bubblewrap, beside `xdg-dbus-proxy`.
  - Killing its parent took the page process and WebKit's processes down
    with it.
- **Veylor's side** (`railgun_host.cc`), driven through stand-in Flutter
  channels in place of the engine, built with ASan and UBSan:
  - `supported`, `load`, `call` (start, openWallet and refresh to `synced`),
    the events, `isOpen`, `close` and `wipe` all answered as on the Mac, as
    did a call after a close (`closed`) and bad arguments (`bad_args`).
  - Without a profile, `supported` was false and `load` `unavailable`.
  - A load straight after a load waited for the first page process, and a
    close dropped a load still waiting.
- **The session lifecycle**, through the same stand-ins: locking the VM's
  session (`loginctl lock-session`) sent `hidden`, and unlocking it sent
  `resumed`, then again a second later.
- **The CI packages** (runs 44783200926 and 44787126543):
  - Both .debs installed side by side, with both profiles loaded. Each
    installed page process passed the check from `/opt/<package>`.
  - Ubuntu 22.04's runner, on WebKitGTK 2.50.4, passed the check too, since
    22.04 allows user namespaces.
  - The first run's packaged app did not start (ZXing not found). The second
    fixed it, and CI now checks that nothing in the installed package goes
    unfound.
- **The apps themselves** (the second run's builds, on the owner's locked
  mainnet wallet, never unlocked):
  - The AppImage logged `Railgun page: unavailable (the check exited with 3)`
    a second after it started, so Shielded USD stays hidden there.
  - The .deb's Veylor and Veylor Testnet logged `Railgun page: WebKit's
    sandbox started; Shielded USD can run here`.

Not run: anything behind the unlock (the page in the app itself, the
bridge, sends, deposits, the archive in the app and the checklist's real sync
(7.3), Tor), the keep-awake hold and
the settlement reminder, X11 sessions, KDE and other desktops, Fedora, Debian
and Arch, and x86_64 machines (CI built and checked those packages, but no
desktop ran them).
