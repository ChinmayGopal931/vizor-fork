# Shielded USD (Private USD) on macOS

Step 3a of the owner's desktop plan (2026-11-19): the Railgun page host on the
Mac, and desktop screens for everything but the bridge. Step 3b (2026-11-19):
the bridge, converting ZEC and shielded USD both ways with its refunds and
rescue, on the phone's engine and providers ("The bridge" below).
Windows and Linux get hosts of their own later and hide Shielded USD until then.

Read AGENTS.md's "Private USD" section and `docs/private-usd-android-plan.md`
§3.5 first: every invariant there holds on the Mac, because the Rust engine and
the Dart flows are the phones' own. The iOS host, which this one follows, is in
`docs/private-usd-ios-reference.md` §6.

## What was ported

**The host** speaks the iOS host's channel contract, method for method and code
for code (`com.zcash.wallet/railgun` and `/events`: `supported`, `load`,
`call`, `close`, `wipe`, `isOpen`).

- `macos/Runner/Railgun/`, written for AppKit and FlutterMacOS:
  - `RailgunHostHandler.swift`: the channels, one answer per call, `bad_args`.
  - `RailgunPageHost.swift`: the process-wide page, its data store
    (`WKWebsiteDataStore(forIdentifier:)`, iOS's fixed identifier) and its
    SOCKS5 proxy, the Rust bridge's loopback port with no failover; the event
    buffer; the wipe (`WKWebsiteDataStore.remove(forIdentifier:)`, retried).
  - `RailgunPage.swift`: one `WKWebView` page and `RailgunChannel`, the pending
    calls and their exactly-once answers (iOS keeps both in one file, which
    imports UIKit).
  - `RailgunError.swift`: the error kinds and their channel codes.
- iOS's platform-neutral files, referenced from the macOS target unchanged:
  `ios/Runner/Railgun/RailgunEndpoints.swift` (so the Rust pin test's read of
  `static let hosts` covers the Mac), `RailgunContentRules.swift` (the same
  `WKContentRuleList`), `RailgunProtocol.swift` and `RailgunSchemeHandler.swift`
  (the page served from `veylor-railgun://app/`).
- The bundle: the macOS target references `ios/Runner/Railgun/railgun/`, the
  folder `android/railgun-web/build.mjs` writes for iOS, as a folder reference
  in Copy Bundle Resources. There is no third copy, and the bundle did not
  change.
- `macos/Runner/PrivateUsdAttestationHandler.swift`: Privacy Pass attestation
  answers `unavailable`, as on iOS.
- Registration: `MainFlutterWindow.registerPrivateUsdChannels`, in
  `awakeFromNib`, before Dart's bootstrap asks `supported`.

**Around the host, as on iOS:** a reset wipes the page's data store and an
account deletion deletes its Railgun wallet through a page behind an offline
bridge (both shared Dart); a route change, a lock, an account switch and the
idle close close the page and stop the bridge (shared Dart). Unlike iOS, the
page can read Anon's archive ("Anon's archive on the Mac" below).

**The gates** (`private_usd_feature_config.dart`,
`private_usd_available_provider.dart`):

- `kPrivateUsdBuildEnabled` is the define alone, so a desktop build with
  `VIZOR_PRIVATE_USD_ENABLED` has the feature. Phone builds are unchanged.
- `privateUsdPlatformHostsPage` takes the form factor: the phones as before;
  desktop only on macOS with `supported` (macOS 14 and later). Windows and Linux
  have no handler, so the bootstrap's `supported` reads no
  (`MissingPluginException`) and the feature stays hidden.
- The other gates hold: hardware accounts, accounts without ZIP-32 metadata,
  regtest (no deployment) and the kill switch.
- `privateUsdBridgeAvailableProvider` follows the deployment's windows
  contract on desktop as on the phones (step 3b): where the network pins one,
  Bridge shows and its routes are real; elsewhere the shared redirect sends
  `/private-usd/convert…` back to `/private-usd`.

**The screens** (`lib/src/features/private_usd/screens/desktop/`,
`widgets/desktop/`): desktop layouts on the phone's providers and copy, with
the phone's widgets and painters where they fit.

- `/private-usd` (`DesktopPrivateUsdScreen`): the balance with its ZEC worth,
  age or first-load note and the RPC errors with their actions; the refresh
  (it never spins, and a click during an automatic refresh shows that
  refresh's progress); Railgun's sync line in the pane
  (`privateUsdSyncLine`, `NeonSyncLineLayer` back and front, the `RAILGUN
  SYNC` readouts); Send, Withdraw and Receive with the spending note and a
  payment in flight; the deposits, and any deposit Railgun's screening sent
  back to its vault with Recover (the phone's Refunds rows for deposits, after
  the same confirmation; step 3b moved them to Refunds, as on the phone); the
  Available, Processing (with its live line), Arriving (with its estimate) and
  Blocked rows; the assets; the activity (unfolding details); the info card.
- `/private-usd/receive`: public USDC at the deposit address (the default) and
  0zkUSDC at the 0zk address, behind the phone's switch (`NeonSwitchTabs`),
  each as a code on a lit plate (dark modules on light, and no badge: the
  desktop receive badges name ZEC's pools) with its address and a copy button,
  and for USDC the token and network it takes, the minimum, both fees and the
  deposits so far.
- `/private-usd/send` and `/private-usd/withdraw`, their reviews and
  `/private-usd/send/status`: the phone's flow and its provider, so the spend
  guard (one outgoing payment at a time) and the relayer fee caps apply as on
  the phone. The recipient is typed or pasted (a paste button beside the
  field); there is no camera scan. While a send proves and posts, the back
  link is gone and the sidebar is veiled and takes neither the pointer nor the
  keyboard, as the phone's wide-window sidebar is: an account switch or a
  sign-out would close the Railgun page mid-proof.
- Home: a Shielded USD strip under the balance sign's transparent tray (the
  phone Home's `PrivateUsdHomeStrip`, with a click cursor and the keyboard),
  opening `/private-usd`; the chart page's holdings list Shielded USD as on the
  phone (`MobileHoldingsPanel`, already shared). The sidebar keeps Home lit on
  the Shielded USD pages, as it does on the chart.
- Activity: Home's recent activity and `/activity` list the phone's Shielded
  USD rows among the ZEC rows, newest first, and Activity groups them into the
  same weeks and months (`desktopPrivateUsdFeedEntries`, on
  `privateUsdActivityProvider` and `privateUsdFeedEntries`). They are the
  bridges, deposits, sends, withdrawals and what arrived: a bridge's row opens
  its progress (a refunded one can open Refunds), the others unfold their
  details under them on a click (or Enter), as a tap does on the phone, and
  their transactions open on their explorers. The wallet transactions a bridge
  row stands in for (its deposit and sweeps, `PrivateUsdActivity.txids`) are
  left out of both feeds, as on the phone. Privacy mode masks their amounts and
  details as it does ZEC's. Activity pages only the wallet's rows: a Shielded
  USD row shows once the loaded page reaches its time, as on the phone.
- The sidebar's foot: under the wallet's sync readout, Railgun's, in the same
  style (`NeonSidebarSyncReadout`), built by the page's `privateUsdSyncLine`
  from the balance's state, so it reads `RAILGUN SYNC n%`, `RAILGUN SYNCED`,
  `RAILGUN SYNC FAILED` and the Tor readouts as the page's line does. It shows
  only while Shielded USD is available to the account, and starts no sync.
  Before Railgun's first sync of the session, a balance kept from an earlier
  one reads `RAILGUN SYNCED` (the page's rule for a balance it shows, the
  screen reader hearing when it was updated); a wallet Railgun never synced
  has no Railgun line until a sync starts, since only the page starts a first
  sync and its line would stand at 0% until then.
- Settings: a Shielded USD block, shown when the phone shows its rows
  (`privateUsdRpcSettingVisibleProvider`): Ethereum RPC, whose dialog checks a
  URL as the phone's sheet does before saving it, the relayer claims switch,
  and on mainnet "Sync history from Anon's archive" (below).

## Anon's archive on the Mac (2026-11-19)

Railgun's sync reads history from Anon's archive before rail-squid, as on
Android: mainnet only, behind Settings' "Sync history from Anon's archive"
(`privateUsdArchiveSyncProvider`, on by default, the phone's setting and
storage), which `privateUsdArchiveAvailableProvider` offers on the Mac wherever
its host runs the page (macOS 14 and later). iOS still starts the page without
it. The page and its rules are Android's, unchanged (AGENTS.md, "Anon's
archive"); only the host is new (`macos/Runner/Railgun/RailgunArchive.swift`).

- **Why the host fetches it.** The archive sends no CORS headers, so the page
  can't read it, and WebKit can't intercept `https` as Android's
  `shouldInterceptRequest` does. The page's bundle can't change (the Mac uses
  iOS's copy), and the page reads the archive only where it finds no WebKit
  host (`webkit.messageHandlers.railgunHost`).
- **The prelude.** Before a `start` whose params ask for the archive, the Mac
  runs `RailgunArchive.prelude` in the page's world (`callAsyncJavaScript`, a
  constant script; nothing spliced in). It routes the page's archive GETs
  (`https://digest.anon.inc/…`) to `/anon-archive/…` on the page's own origin,
  where CSP's `'self'` and the content rules let them through, and hides the
  WebKit host from what the page reads later, so its start reads the archive
  as Android's does. The page's transport took the host when it loaded and
  stays as it was. A prelude that does not take leaves the page as on iOS:
  rail-squid alone. It runs on every page that starts with the archive, and
  is idempotent.
- **The fetch.** `RailgunPageSchemeHandler` answers `/anon-archive/` (iOS's
  `RailgunSchemeHandler` the rest), only once the prelude took: the same path
  and query on `https://digest.anon.inc`, GET only, through a `URLSession`
  whose only route is the page's bridge (`ProxyConfiguration`, SOCKS5 at
  `127.0.0.1:<bridge port>`, no failover), so the bridge resolves the name on
  the wallet's route (over Tor when Tor is on) and checks it against its
  allowlist, never directly. Android's limits: 16 MB an answer (declared or
  read), a minute an answer, a 20 s stall, no redirect followed, no cache,
  cookie or credential store, `Accept-Encoding: identity` (the files are
  checked against the archive's checksums as served) and `User-Agent:
  Mozilla/5.0`. A failure is a 502, which the page retries and then leaves for
  rail-squid; a page that aborts a request cancels its fetch. The session goes
  with its page: a route change, a lock or an account switch closes both.
- **The pins.** `RailgunArchive.host` is read by the Rust test that pins the
  page's `ARCHIVES` host to Kotlin's `ARCHIVE_HOST` and the bridge's
  allowlist (`railgun_bridge.rs`); the host was already in every allowlist and
  the page's CSP.
- **Not run yet.** Only `swiftc -typecheck` and the Dart and Rust tests ran.
  To try it: a mainnet build with `VIZOR_PRIVATE_USD_ENABLED=true` (and the
  keyed RPC JSON, as for Android), then a Railgun first sync of a wallet far
  behind; sync only, nothing is spent. The archive is read only by a sync that
  starts more than four days behind the newest block, so a wallet synced
  lately won't ask it. Like Android's host, the Mac logs nothing of it: a
  first sync that reads it is far quicker than rail-squid's, and in a debug
  build a page loaded with `debug` is inspectable, where Safari's Web
  Inspector lists the `/anon-archive/` requests. Unchecked on a Mac: that
  WebKit lets the page's `webkit` global be redefined (if not, the prelude
  says so and the page syncs from rail-squid, as before), and that
  `URLSession` hands the bridge the hostname, as WebKit's own requests do (the
  bridge refuses an IP address, so a fetch would fail, never go around it).

## Foreground and keep-awake on the Mac

Plan D9 (key steps and polling only while unlocked and in the foreground) reads
the Flutter lifecycle, as on the phones. On the Mac the foreground is a shown
window, focused or not:

- A minimised or hidden window, a hidden app, or a window fully covered by
  others is `AppLifecycleState.hidden`: Flutter's engine reports it from the
  app's occlusion. The engine pauses (cancelling the Rust step), the balance and
  deposit polling stop, and `appInForegroundProvider` turns false.
- A locked screen, displays asleep, a Mac going to sleep, and another user's
  session in front are `hidden` too: `macos/Runner/MacSessionLifecycle.swift`
  says so on the engine's `flutter/lifecycle` channel, since macOS does not
  promise an occlusion change for each, and once nothing keeps the Mac away
  sends the state the engine would report then (and again a second later). An
  app that becomes active clears it whatever was missed.
- An unfocused window (another app in front, the window still showing) is
  `inactive`, and Private USD runs on, as the phones run on while inactive.
- WebKit suspends the page while its window is not visible, as iOS suspends it
  in the background: a sync waits, and resumes when the window shows again.
- The kill switch's retries wait for the foreground on desktop too
  (`privateUsdKillSwitchWorkPolicyProvider`), as on the phones; desktop's other
  app-process work keeps running while the window is hidden.

**Keep-awake.** `com.zcash.wallet/screen_awake` (`setEnabled`) has a macOS
handler (`macos/Runner/ScreenAwakeChannel.swift`): an IOKit
`PreventUserIdleDisplaySleep` assertion, so neither the display nor the Mac
sleeps on idle and the screen does not lock under a Railgun first sync or a
bridge. It never stops the user locking the screen or closing the lid. On
desktop `SyncKeepAwakeNativeHost` takes it only for Private USD
(`privateUsdKeepAwakeProvider`) while the window is not hidden; the wallet's
own sync keeps running hidden and needs none. "The bridge" below says when a
bridge holds it.

## The bridge (step 3b)

Every invariant of plan §3.5 holds on the Mac: the engine (Rust, and the
shared Dart providers and flows) is the phones'. Desktop adds layouts and a few
desktop hooks, all behind `kDesktopFormFactor` or in desktop-only code.

**The screens** (`screens/desktop/desktop_private_usd_convert_screens.dart`,
`desktop_private_usd_conversion_screens.dart`,
`desktop_private_usd_refunds_screen.dart`, `widgets/desktop/
desktop_private_usd_bridge_widgets.dart`), with the phone's bridge widgets and
painters, never its screens:

- `/private-usd/convert` (`?to=zec` for shielded USD → ZEC): the phone's panels
  (`PrivateUsdAmountPanel`, `PrivateUsdEstimatePanel` with `NeonCipherChurn`),
  the direction switch (`PrivateUsdDirectionToggle(desktopInput: true)`: a
  click cursor, Tab then Enter or Space, its edge fully lit while focused; the
  phone's plate is built as before), the ledger and the quote's countdown, and
  Review pinned at the foot of the pane (`DesktopPrivateUsdPage.action`, on
  upstream's `AppPaneFloatingBar`). Quotes are the phone flows': 700 ms after
  typing stops, Max once the balance is Rust's, a replacement for one that ran
  out on the amount step, never per keystroke or on opening (every quote
  spends a swap index). A bridge under way opens instead, one per account.
- `/private-usd/convert/review` (`extra`: the direction): the header, ledger,
  how long the quote holds, the keep-open note (the relayer's while relayer
  claims are on), and Bridge or New quote, pinned. Back and the sidebar are
  held while it accepts. Accepted, its progress replaces the convert screen.
- `/private-usd/conversion/:direction/:index`: the progress with the phone's
  red timeline and details (`MobileSwapStatusContent`), the result or the
  Bridged sign (`PrivateUsdBridgedHero`, its shockwave when it finishes in
  view; no haptic on the Mac), the problem card, the call-off, the keep-open
  card and the main action pinned: View balance or Try again, Pay {debit}, and
  Authorize settlement. Settlement and the call-off (behind a confirmation)
  hold back and veil the sidebar, as the phone holds its screen. While the
  page proves and posts the payment, back stays, as on the phone (the proof
  outlives the screen), and only the sidebar is veiled
  (`DesktopPrivateUsdPage.holdsSidebar`), as the phone's wide window veils
  it: an account switch or a sign-out would close the page mid-proof.
- `/private-usd/refunds`: the refunded bridges with Recover, behind a
  confirmation that names the relayer fee cap (2 USDC), and the deposits
  Railgun's screening sent back, with theirs. Refunds recover one at a time
  and a deposit waits for any recovery, holding back meanwhile, as on the
  phone.
- The Shielded USD page: Bridge (the main action; Send turns secondary, as on
  the phone) or the bridge under way, its banner
  (`DesktopPrivateUsdConversionBanner`, the phone's with a click cursor and the
  keyboard), and Refunds beside the activity once a bridge was refunded or a
  deposit sent back. Home shows the banner under its buttons.

**Keep Veylor open, with its window showing.** WebKit suspends the Railgun page
while the window is not visible, and a shielded USD → ZEC payment is proved in
the page; a hidden window also pauses the engine (the foreground is a shown
window). So in place of the phone's keep-open card, desktop shows one slim row
(`DesktopPrivateUsdKeepVisibleRow`, the owner's call): a display glyph whose
tooltip says that a covered or minimised window or a sleeping Mac pauses the
bridge (`privateUsdKeepVisibleDetailDesktop`), the line "Keep Veylor visible
until the bridge is done." (`privateUsdKeepVisibleDesktop`), and the switch at
its right; the proof's note (`privateUsdReverseProvingNoteDesktop`) and the Pay
step ("Click Pay", `privateUsdReverseStepPayDetailDesktop`) say the same of the
Mac, chosen in the shared reverse presentation behind `kDesktopFormFactor`. A
ZEC → USD bridge the relayer is to claim shows no row: its note still says to
keep Veylor open until the market maker confirms the deposit, then leave.

**Keep-awake.** The row's "Keep display awake" is the phone's "Keep screen on"
switch
(`privateUsdScreenMaySleepProvider`): on by default, it keeps the IOKit
assertion through a bridge with a key step to come, whichever screen shows, by
the phone's rules (`privateUsdBridgeKeepAwakeProvider`): never once the relayer
holds the claim, never locked, and only while the window is not hidden.

**The settlement reminder.** The phones buzz when "Authorize settlement" is
first offered and two minutes before it closes
(`privateUsdSettlementReminderProvider`, `AppHaptics.settlementDeadline`). On
the Mac the haptics channel's `settlementDeadline` has a handler
(`macos/Runner/SettlementAttentionChannel.swift`) that asks for the user's
attention instead: `NSApp.requestUserAttention(.criticalRequest)`, which
bounces the Dock icon until Veylor is active (nothing when it is already), and
the user's alert sound (`NSSound.beep()`). It needs no permission and shows
nothing. The timing rules are the shared provider's, unchanged: foreground (a
window showing, focused or not) and unlocked only, once per offer and once per
closing; a step offered while the window was hidden asks on its return. Every
other haptics call answers not implemented, as before.

**Nothing covers "Authorize settlement".** The phones' sync privacy lock
(`SyncKeepAwakePrivacyLockHost`) and the 15-minute background auto-lock are
mobile only. Desktop's one idle cover is the Ironwood migration's privacy lock
(`IronwoodMigrationPrivacyLockHost`, ten idle minutes while a migration runs):
it is not eligible while a bridge awaits the user
(`privateUsdBridgeAwaitsUserProvider`, from the accept until settlement is
authorized, with its screen kept on), and a return after an absence does not
lock then either; once the bridge no longer waits, the idle window starts
again. A lock shown before stays until unlocked, as on the phone.

**Removing an account or resetting** (plan §3.5 invariant 15). Desktop's
removal dialog (`AccountRemoveModal`, the last account's reset included),
Settings' reset (`SettingsUninstallScreen`) and the lost-password reset warn
with the number of unfinished bridges, or that they could not be checked, as
the phone's sheets do: warned, never blocked. The removal dialog waits for the
count and its button reads "Delete anyway" or "Reset anyway"; Settings' reset
warns on the first click and goes on with the second. The count goes to
`removeAccount` / `resetWallet`, which drain `privateUsdLifecycleProvider` and
recheck it: more bridges, or a recheck that failed, stops the removal and asks
again (`privateUsdRemoveMoreUnfinished`, `privateUsdRemoveRecheckFailed`). The
locked lost-password reset warns only, as the phone's forgot-passcode sheet
does.

## Checked against the phone (2026-11-19)

Every bridge, refund and send action on the Mac was compared with the phone's,
action by action: convert, quote and review, accept, the progress and its
steps, Pay, Authorize settlement, the call-off, the problem card, the Bridged
sign, Refunds' Recover and the deposit recovery, the relayer-claim notes, the
keep-open card, and Send and Withdraw. Each calls the same provider method with
the same arguments, guards, confirmations and disabled states. Three
differences were brought to the phone's behaviour: back during the payment's
proof (above); a refund's Recover no longer waits for a deposit's recovery; and
the page's info lists Refunds without the bridge too, since Refunds also holds
the deposits Railgun sent back.

What stays different is the Mac's: the layout (pinned actions, glass panels,
and the sidebar veiled only while a step runs, where the phone's wide window
veils it through every Private USD flow); the mouse and keyboard (click cursors,
Tab with Enter or Space, Enter sending a send's form, a paste button and no
camera scan); the Mac's own behaviour (the IOKit assertion, the Dock bounce and
alert sound for the settlement reminder, no haptics, the keep-visible row);
and the Mac wording.

**"Preparing your receiving account".** It is the first of the reverse steps
on both. Both reach the progress at the same moment, before the acceptance
ends: Rust's go-ahead puts the bridge under way, the unfinished set refreshes
the router, and a refresh rebuilds every pushed route without its typed `extra`
(go_router decodes the stack and has no codec for it). The review's route then
builds its fallback, a convert screen, which finds the bridge under way and
replaces itself with the progress while the maker's acceptance and the joint
account's import still run. So the progress arrives with that step live, on
the phone as on the Mac, until the acceptance ends and the records are read
again, and Pay goes live. Nothing on the Mac changes that, so nothing was
changed. Two side effects are the phone's too and were left: the review's push
never completes, so the convert screen stays under the progress, still in its
confirming step, and Back from the progress lands on it rather than on
`/private-usd`.

## How it differs from iOS

- **macOS 14**, not iOS 17, for the store and its proxy; below it `supported`
  is false and the feature stays hidden. The app's deployment target stays 12.0.
- **The page's place.** The 1×1 web view sits in the window's content view
  below the Flutter view (iOS: in the key window beneath the root view). The
  app has one window, so it never moves. AppKit has no
  `isUserInteractionEnabled`: the view is a `WKWebView` subclass that refuses
  first responder, the key view loop, the pointer and VoiceOver.
- **Memory pressure** (a `DispatchSource` at warning or critical) closes an
  idle page, standing in for iOS's memory warning.
- **No bridge check after the background.** iOS may reclaim a suspended app's
  listening socket; the Mac app keeps running (App Nap is off), so Dart's
  check stays iOS only.
- **Backups.** The container's `Library/WebKit` is marked excluded from backups
  before and after each load, as on iOS; on the Mac that keeps it out of Time
  Machine. The wallet database and the `private_usd_*` directories are not
  marked on the Mac (`excludeFromDeviceBackup` is iOS only), as before.
- **A file picker** (`runOpenPanelWith`) is refused; WebKit offers it only on
  the Mac.
- **The page's requests** carry `Origin: veylor-railgun://app`, as on iOS (an
  Alchemy origin allowlist needs it).

## What has run (2026-11-19)

On this Mac (macOS 26, Apple silicon), a debug build with Veylor's identity,
through a temporary entry point (not committed) that drove the real host and
bridge without the wallet UI (no wallet could be unlocked here):

- `supported` answered true; the bridge started; the page loaded and said it
  was ready in 1.2 to 2.6 s; `start` (Sepolia, keyless publicnode) and
  `openWallet` (a throwaway wallet) succeeded; a first sync completed in 38 s
  with `scan`, `refresh` and `screening` events; `wipe` removed the store.
- The WebKit networking process held only loopback connections to the bridge's
  port; every outbound connection was the app's own (the Rust bridge).
- A page whose window never showed stopped about ten seconds into its first
  sync and did not go on: WebKit suspends a page that is not visible.
- `swiftc -typecheck` of the host passed; the debug build signed and ran, and
  the release build for the owner built and signed.

Step 3b ran only as code: `fvm flutter analyze` (clean), the desktop and
mobile test lanes (the desktop lane fails only where main does: RenderFlex
overflows in the endpoint screen and the Gift Card ledger hint, and the
endpoint use case that stalls the end of the run), and `swiftc -typecheck` of
the attention handler. No new tests were written, no bridge has run on the Mac,
no release build was made (Veylor was running), and no funds were spent.

Untested, for the owner's session (3b):

- A small testnet bridge both ways (Sepolia): the convert screen and its quote,
  the review, the progress to the Bridged sign, Pay and its proof in the page,
  Authorize settlement, a call-off and a refund, Refunds' Recover, and the
  relayer claims on and off.
- The Mac during a bridge: `pmset -g assertions` while one runs and once it no
  longer needs Veylor; "Keep display awake" off; the Dock bounce and the alert
  sound when Authorize settlement is offered and two minutes before it closes,
  with Veylor in front and behind another app; a minimised window pausing it
  and resuming on return.
- The Ironwood privacy lock staying off while a bridge awaits the user.
- The removal and reset warnings with a bridge under way.

Untested, for the owner's session (3a):

- Everything with a wallet: the screens, a refresh from the page, Receive,
  deposits and a deposit's recovery, a send and a withdrawal (Sepolia),
  Settings' RPC dialog and the relayer claims switch, the Shielded USD rows in
  Home's recent activity and in Activity, and the sidebar's Railgun readout.
- The lifecycle on the Mac: minimise, hide, a covered window, a locked screen,
  sleep and wake (that the engine pauses and resumes, and that the page resumes
  its sync), and the keep-awake assertion through a first sync
  (`pmset -g assertions`).
- Tor: the page over an isolated circuit, a route change mid-sync, and Tor
  failing closed.
- An account deletion (the offline page's `deleteWallet`) and a reset (the
  wipe) from the UI.
- macOS 14 and 15 (only macOS 26 ran), and an Intel Mac.
