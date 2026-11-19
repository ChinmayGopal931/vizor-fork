# Shielded USD (Private USD) on macOS

Step 3a of the owner's desktop plan (2026-11-19): the Railgun page host on the
Mac, and desktop screens for everything but the bridge. The bridge (converting
ZEC and shielded USD both ways) is step 3b; until then desktop hides it.
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

**Around the host, as on iOS:** the page starts without Anon's archive
(`privateUsdArchiveAvailableProvider` is Android only); a reset wipes the page's
data store and an account deletion deletes its Railgun wallet through a page
behind an offline bridge (both shared Dart); a route change, a lock, an account
switch and the idle close close the page and stop the bridge (shared Dart).

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
- `privateUsdBridgeAvailableProvider` is false on desktop: Bridge is hidden,
  the bridge's routes go back to `/private-usd`, and desktop routes
  `/private-usd/refunds` and `/private-usd/conversion/…` there too.

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
  the same confirmation; desktop starts no bridge, so there are no conversion
  refunds); the Available, Processing (with its live line), Arriving (with its
  estimate) and Blocked rows; the assets; the activity (unfolding details);
  the info card.
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
  deposits, sends, withdrawals and what arrived: a click (or Enter) unfolds a
  row's details under it, as a tap does on the phone, and its transactions
  open on their explorers. Privacy mode masks their amounts and details as it
  does ZEC's. Bridge rows are left out until step 3b, and the wallet
  transactions they stand in for on the phone stay as ZEC rows; desktop starts
  no bridge, so a desktop wallet has none. Activity pages only the wallet's
  rows: a Shielded USD row shows once the loaded page reaches its time, as on
  the phone.
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
  URL as the phone's sheet does before saving it, and the relayer claims switch.
  Anon's archive is Android only and is not offered.

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
sleeps on idle and the screen does not lock under a Railgun first sync. It
never stops the user locking the screen or closing the lid. On desktop
`SyncKeepAwakeNativeHost` takes it only for Private USD
(`privateUsdKeepAwakeProvider`: a first sync, or a bridge, which desktop does
not start) while the window is not hidden; the wallet's own sync keeps running
hidden and needs none.

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

Untested, for the owner's session:

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
