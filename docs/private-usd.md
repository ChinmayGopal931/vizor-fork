# Shielded USD (Private USD)

Moved from AGENTS.md on 2026-11-22. AGENTS.md lists where every former section went.

A Railgun USDC ("private USD") balance, conversion both ways with shielded
ZEC by atomic swap (with refunds and rescue), and private send and withdraw.
It runs on Android. The iOS port (iOS 17 and later, behind the same define)
has its code in but has not yet run on a simulator or an iPhone. The macOS
desktop app hosts it too (macOS 14 and later, behind the same define): step 3a
(2026-11-19) brought the Railgun host and desktop screens, and step 3b the
bridge with its refunds and rescue, on the same engine and providers, in
desktop layouts that place the phone's bridge widgets (never its screens).
Linux hosts it too (2026-11-20): the page runs in a process of its own on the
system's WebKitGTK 4.1, always in WebKit's sandbox, and where that can't start
(no WebKitGTK, or Ubuntu 23.10+ without the .deb's AppArmor profile) Shielded
USD stays hidden; `docs/private-usd-linux.md` has the host and what has run.
Windows hosts it too (2026-11-21): the page runs in WebView2, Chromium as
Android's WebView is, on the system's Evergreen runtime, and where that is
missing Shielded USD stays hidden; `docs/private-usd-windows.md` has the host
and what has run. Desktop Home's recent activity and
Activity list the phone's Shielded USD rows, bridges included, and leave out
the wallet transactions a bridge row stands in for
(`desktopPrivateUsdFeedEntries`). Desktop follows the phone's flows action for
action (checked 2026-11-19): the same provider calls, guards, confirmations
and states, differing only in layout, mouse and keyboard, the Mac's own
behaviour and wording. The Mac's host, the bridge's desktop screens and hooks,
what desktop keeps different, how it differs from iOS's and what has run are in
`docs/private-usd-macos.md`. What every Railgun page host must do (the channel,
the page, the bridge, Anon's archive and its connections), item by item against
Android's, is in `docs/private-usd-railgun-hosts.md`: read it before changing a
host or writing a new one. Before changing it,
read `docs/private-usd-android-plan.md`: §3.5 lists the invariants and why
each one exists. The pinned config and defines are in
`docs/private-usd-reference.md` §7. Progress and deviations are in
`docs/private-usd-progress.md`, and the device runs in
`docs/private-usd-device-checklist.md`. The iOS port follows
`docs/private-usd-ios-plan.md`, with its reference, progress and device
checklist beside it (`docs/private-usd-ios-*.md`); its progress doc says what
has run.

Code:

- Rust: `rust/src/wallet/private_usd/`, `rust/src/api/private_usd.rs`,
  `rust/src/wallet/routed_http.rs` and `rust/src/railgun_bridge.rs`.
- Dart: `lib/src/features/private_usd/` (the desktop screens in
  `screens/desktop/` and `widgets/desktop/`),
  `lib/src/core/config/private_usd_feature_config.dart` and
  `lib/src/providers/private_usd_lifecycle_provider.dart`.
- Kotlin: `android/app/src/main/kotlin/com/keplr/vizor/railgun/`.
- Swift: `ios/Runner/Railgun/`. The macOS target compiles four of its files
  unchanged (`RailgunEndpoints`, `RailgunContentRules`, `RailgunProtocol` and
  `RailgunSchemeHandler`, referenced from `ios/`) beside its own AppKit and
  FlutterMacOS versions of the rest in `macos/Runner/Railgun/` (`RailgunPage`
  with `RailgunChannel`, `RailgunPageHost`, `RailgunHostHandler` and
  `RailgunError`), with `macos/Runner/ScreenAwakeChannel.swift` and
  `MacSessionLifecycle.swift`. Keep the shared four free of UIKit and Flutter
  imports.
- C++ (Linux): `linux/runner/private_usd/` (Veylor's side: the channels, the
  page's link, the session lifecycle, keep-awake and the settlement reminder)
  and `linux/runner/railgun_page/` (`veylor-railgun-page`, the page process:
  WebKitGTK loaded at run time, the page, the archive fetch and the hosts);
  `scripts/package-linux-deb.sh` makes the .deb with its AppArmor profile.
- C++ (Windows): `windows/runner/railgun/` (the channels, the page host and
  its WebView2 page, the request filter and the archive's deferrals),
  `private_usd_channels.cpp` and `session_lifecycle.cpp`, which compile
  Linux's `railgun_protocol`, `railgun_json` and `railgun_endpoints`
  unchanged: keep those three free of GLib and GTK. The archive's fetch is
  `rust/src/railgun_archive.rs` (Windows only, over a C ABI).
  `windows/runner/tests/railgun_page` is the host's check program (not
  shipped), which `scripts/windows-railgun/check_railgun_page.py` runs
  against a stand-in for the bridge on CI.
- The Railgun page: `android/app/src/main/assets/railgun/`, built from
  `android/railgun-web/`; the same build copies it as is to
  `ios/Runner/Railgun/railgun/`, which the macOS target references as a folder
  and the Linux and Windows builds install into the bundle's `data/railgun`
  (no third copy).
- Copy: ARB messages whose keys start with `privateUsd` (the chart's
  `portfolioChart`, the sync line's `neonSync`), in Korean and Chinese
  too. `PrivateUsdCopy` keeps only what is never translated and the few
  messages that choose between keys. A provider or a result keeps its
  text as a `PrivateUsdText` that the widget resolves. The Korean and
  Chinese are a first pass for a native reviewer; the terms they use are
  in `docs/private-usd-reference.md` §9.6.

**Defines (reference §7.3).** Each is a Dart define read once in
`private_usd_feature_config.dart`. Gradle needs none of them.

- `VIZOR_PRIVATE_USD_ENABLED` (default `false`) turns the feature on, in a
  mobile or a desktop build (`kPrivateUsdBuildEnabled`); where no host runs
  the page, `privateUsdPlatformHostsPage` keeps it hidden. Release builds turn
  it on only after the owner's sign-off.
- `VIZOR_ETHEREUM_RPC_URL_{MAINNET,SEPOLIA}` are the keyed RPC URLs. They
  are the only secrets: pass them only with
  `--dart-define-from-file=<gitignored json>`. Their host must be one of
  the network's RPC providers (`Deployment::rpc_hosts` in
  `rust/src/wallet/private_usd/deployment.rs`: publicnode, Alchemy, Infura,
  QuickNode, Chainstack, Ankr, dRPC, BlockPI, Tenderly, NodeReal, GetBlock,
  OnFinality, Pocket Network and MEV Blocker; a `*.` entry takes any
  subdomain, one label or more of letters, digits and inner hyphens, for
  QuickNode's endpoint names and Chainstack's dedicated nodes). Every one
  is in `RAILGUN_PAGE_HOSTS`, which the Kotlin and Swift `RailgunEndpoints`,
  Linux's `kHosts` (`linux/runner/railgun_page/railgun_endpoints.h`), the
  page's CSP (and its two bundle copies of `index.html`) and the Rust bridge
  repeat and a Rust test pins together: a new provider goes into all
  of them, and only a provider that serves every call the engine and the
  page make belongs (`eth_call` at a block hash and `eth_getLogs` over the
  engine's 5,000-block window included; a transaction RPC such as Flashbots
  Protect forwards no `eth_call`). Users can set their own URL in Settings
  (Ethereum RPC) on the same providers (`ApiDeployment.rpcHosts`); it
  replaces the build's keyed URL with no fallback, and is checked with
  `eth_chainId`, then `eth_getBlockByNumber` and `eth_call`
  (`tokenBlocklist(address)` on Railgun's proxy at the head's hash, the
  engine's pinned read), then `eth_getLogs` over that window on the windows
  contract (a provider's plan may cap the range lower, which would leave a
  bridge waiting on its payout), before it is saved; a rate limit reads as
  unreachable, never as a verdict. A Rust test holds the Dart copy of the
  window and of the read's selector to the engine's. Rust holds the engine
  to the same rule (`Deployment::rpc_url`, the network's `rpc_hosts`, https
  without credentials): a URL off them is `WrongDeployment`, never
  replaced. A
  Railgun sync that fails while the RPC does not answer, or answers 403 or
  429, and a screening node still answers, fails as `rpc_failed` (the page
  asks both as the sync fails, `rpc-probe.js`), and the balance offers
  another RPC; a connection that is down is never put on the RPC. A page's
  `start` is told apart the same way: its provider load (Railgun's fees,
  read from the RPC) that fails, or has no answer in 75 s, inside the host's
  two minutes (review, 2026-11-22).
- `VIZOR_PRIVATE_USD_FLAG_URL` is the kill switch. Only an explicit `false`
  hides the feature. A missing key or a failed fetch keeps the last value,
  which defaults to available. Even `false` never stops conversions already
  under way. It is read at start and again every 30 minutes while the app is
  in the foreground (`kPrivateUsdKillSwitchRereadInterval`; one that falls
  due in the background goes on the return), so a `false` reaches an open
  app. Every Veylor pipeline takes the URL from one file
  (`docs/releases.md`, "Shielded USD kill switch"), which names none yet:
  the owner chooses and hosts it.
- `VIZOR_SUPPORT_URL` is optional.

**Foreground and unlocked only (plan D9).**

- Every key-using step runs only while the app is unlocked and in the
  foreground. That covers the deposit, claim, payout signature, refund,
  sweep and Railgun proving.
- Relayer claims (Settings, on by default; each ZEC → USD bridge keeps the
  choice it began with) let the user leave once the market maker has
  confirmed the deposit, a few minutes after tapping Bridge. On the first
  step that reads the swap ready at its confirmation depth, Veylor signs and
  keeps the payout, marks the hand-over (`claim_hold`), then posts the
  claim, `z` with it, to the pinned relayer's `/v1/claim/hold`, which sends
  it when the window opens. Not before the ready: until then the maker may
  cancel the swap, and its cancel reveals `e` on chain, with which the `z`
  the relayer holds spends the deposit. An open swap the maker never made
  ready Veylor claims itself from `t0`, handing nothing over. If Veylor is
  open when the window opens, it posts a handed-over claim itself only once
  the window has been open a minute (five blocks for a ready before `t0`)
  with nothing landed. A post with no answer goes again with the same bytes;
  a 404 or a refusal leaves that bridge to claim without the relayer
  (`claim_declined`). A refund's sweep still needs Veylor open.
- There is no worker, alarm or notification, and no per-swap key is stored.
- Background cancels the Rust step and stops polling, but leaves the
  Railgun page open.
- Lock cancels the step, closes the page and drops Dart-held secrets. The
  user's own steps run under an op id too, so a lock stops them as it stops
  an advance: "Authorize settlement" (before it signs, or after the `ready`
  is kept, which the loop then sends), the rescues of a refund, a payout or
  a deposit, and a reverse "Cancel", whose request is kept whatever comes and
  whose advance stops (review, 2026-11-22).
- Screen-off means background, so while unlocked the screen stays on
  through a bridge with a key step to come, whichever screen shows (not
  once the relayer holds the claim), and through a Railgun first sync or
  the catch-up of a balance last synced more than a week ago, which also
  gets the first sync's two hours rather than a refresh's five minutes
  (`privateUsdKeepAwakeProvider`, through `SyncKeepAwakeNativeHost`'s one
  native flag, foreground only; review, 2026-11-22). A bridge's progress says so in a card that
  slides in while the bridge needs Veylor (`PrivateUsdKeepOpenCard`, either
  direction; a ZEC → USD bridge the relayer is to claim says instead to stay
  until the market maker confirms the deposit), with "Keep screen on": on
  by default, and off lets
  that bridge's screen sleep (`privateUsdScreenMaySleepProvider`, in memory).
  While a USD → ZEC bridge still needs the user's approval, now or next
  (from its accept until settlement is authorized), with its screen kept on
  (`privateUsdBridgeAwaitsUserProvider`), the wallet sync's idle privacy
  lock (`SyncKeepAwakePrivacyLockHost`) does not cover the app, so
  "Authorize settlement" never shows behind it; once it no longer does, the
  idle minute starts again. From the authorization on, a bridge runs on
  under the lock.
- On a USD → ZEC conversion the phone buzzes when "Authorize settlement" is
  first offered (the user's turn), and again two minutes before it closes if
  still unauthorized, once when the two fall together: it holds, then fades
  out (`privateUsdSettlementReminderProvider`, `AppHaptics.settlementDeadline`;
  on Android under the install-time `VIBRATE` permission). It too needs the
  app in the foreground and unlocked, so a closed app cannot buzz; a step
  offered while the app was away buzzes on its return.
- While unlocked, the engine (`PrivateUsdEngineHost` in `lib/app.dart`)
  advances the conversions of every software account, not only the active
  one (D14). It runs where the page runs, and also where the host says it
  can't (a Linux sandbox check that failed, macOS below 14, Windows without
  the WebView2 Runtime) while `swaps.db` holds a bridge under way (`privateUsdBridgesUnderWayProvider`): every step
  but the reverse funding's proof is Rust's, so those bridges still finish or
  come back (review, 2026-11-22).
- Hardware accounts, accounts without ZIP-32 metadata, and regtest hide the
  feature.
- **On the Mac** the foreground is a shown window, focused or not: a window
  shown again resumes Private USD at once (`onShow`), without waiting for
  focus. A minimised or hidden window, a hidden app or a window fully covered
  by others is `AppLifecycleState.hidden` (the engine's occlusion), and so are
  a locked screen, displays asleep, a Mac going to sleep and another user's
  session in front (`MacSessionLifecycle` says so on `flutter/lifecycle`, and once nothing
  keeps the Mac away sends the state the engine would report). WebKit
  suspends the page while its window is not visible, as iOS does in the
  background. The keep-awake flag is an IOKit `PreventUserIdleDisplaySleep`
  assertion (`ScreenAwakeChannel`), which desktop's
  `SyncKeepAwakeNativeHost` takes only for Private USD (a Railgun first sync,
  or a bridge by the phone's rules) while the window is not hidden. A
  USD → ZEC payment is proved in the page, so in place of the keep-open card
  desktop shows one slim row (`DesktopPrivateUsdKeepVisibleRow`): "Keep Veylor
  visible until the bridge is done.", what pauses it in the glyph's tooltip,
  and the phone's switch as "Keep display awake"; a relayer-claimed ZEC → USD
  bridge still says the user may leave once the maker confirms the deposit. The settlement reminder asks for the
  user's attention instead of buzzing: the haptics channel's
  `settlementDeadline` has a macOS handler (`SettlementAttentionChannel`:
  `NSApp.requestUserAttention(.criticalRequest)` and the alert sound), on the
  shared provider's timing, foreground and unlocked only. Desktop's one idle
  cover, the Ironwood migration's privacy lock, is not eligible while
  `privateUsdBridgeAwaitsUserProvider` holds, so "Authorize settlement" never
  shows behind it. The bridge screens' pinned action
  (`DesktopPrivateUsdPage.action`) keeps it in view however far the progress
  scrolls.
- **On Linux** the foreground is the same, with what GTK reports: a minimised
  or withdrawn window is `hidden` (Flutter's embedder; on Wayland GTK never
  learns of a minimise, so it stays `inactive` and Private USD runs on), and a
  locked or blanked screen, a computer going to sleep and another session in
  front are `hidden` too (`session_lifecycle.cc`, from logind and the
  screensaver, on `flutter/lifecycle`). Veylor hides the page's offscreen
  window meanwhile, so WebKit throttles the page as the Mac's suspends it. The
  keep-awake flag is an idle inhibitor (`gtk_application_inhibit`, else
  `org.freedesktop.ScreenSaver`), and the settlement reminder the window's
  urgency hint and the desktop's alert sound. Desktop messages that name the
  Mac say "your computer" on Linux and Windows (`privateUsd…Linux`,
  `privateUsdComputerWording`).
- **On Windows** the foreground is the same, with what the embedder reports: a
  minimised or hidden window is `hidden`, a covered one is not detected (so
  Private USD runs on behind other windows, as on Linux), and a locked
  session, another session in front, a computer going to sleep and the
  display off are `hidden` too (`session_lifecycle.cpp`, from the session's and
  the power notifications, on `flutter/lifecycle`). The page is hidden
  meanwhile (`put_IsVisible`), so WebView2 throttles it. The keep-awake flag is
  `SetThreadExecutionState`, and the settlement reminder flashes the taskbar
  button and plays the default sound.

**Separate databases.** Rust owns both, in
`<support>/private_usd_<walletDbName>_<network>/` (`getPrivateUsdDirPath`):

- `swaps.db` holds the swap index counters, the swap records, the
  joint-account index and the Railgun send log. Records decode strictly: an
  unreadable record is an error, never a reset.
- `joint.db` is a librustzcash DB for the short-lived joint accounts.

The directory stays out of every backup the platform makes: iOS marks it out
of iCloud and device backups and the Mac out of Time Machine
(`excludeFromDeviceBackup`, `isExcludedFromBackup`), before anything is
written in it, and Android leaves every app file out of a device transfer
(`data_extraction_rules.xml`; its cloud backup is off), since the directory's
name, from the generated wallet database's, can't be listed there (review,
2026-11-22).

Never put joint accounts in `zcash_wallet.db`: hidden accounts would leak
into account lists, sync, voting, PIR and the migration. Never let losing
`joint.db` take `swaps.db` with it. Account deletion removes that account's
rows, but never an index counter: indices are counted per seed and ZIP-32
index (`swap_indices`, keyed by `SwapKeyContext::index_space`), so an
account imported again from the same seed goes on where the seed left off.
A full reset removes the whole directory (`deletePrivateUsdDirectories`)
and the page's WebView origin.

Account deletion also deletes the account's Railgun wallet from the page's
storage, best effort, if it has a Railgun engine key. Its mnemonic is
derived before the Rust delete (Rust checks the seed only while the account
exists). After it, a fresh page behind an offline bridge
(`start_offline_railgun_bridge`: it refuses every connection, so no Tor wait)
calls `deleteWallet`. A failure leaves the wallet until a reset.

**The windows contract.** Swaps settle on zecSwap's windows contract, where
at every moment one side at most may reveal its share, by the clock and the
swap's stage; there are no locks. Testnet pins
`0x459b0a69e0f736666b66a3ffe0fc17c11f05980d` (`MIN_WINDOW` 1800 s,
`LATE_WINDOW` 3600 s, deployed at block 11958709). Mainnet pins
`0xeB3A00bcB6c9fF626fE57a5dBbDCf01730e7898f` (`MIN_WINDOW` 3600 s,
`LATE_WINDOW` 86400 s, deployed at block 26250774 on 2026-10-22), where the
relayer sends claims and refunds, and the maker its reveals, through
Flashbots Protect. A network without one would refuse quotes and
conversions (`ApiDeployment.bridgeAvailable` false) and keep the balance,
deposits, send and withdraw. The reveal rules are `swap::claim_window`, `swap::may_sign_ready` and
`swap::may_refund`, held to the vectors of zecSwap's port oracle
(`rust/src/wallet/private_usd/tests/windows_vectors.json`).

**The open fee (zecSwap's `docs/open-fee.md`).** A ZEC → USD quote may carry
`openFee {zat, address}`: the maker's gas for opening the swap (and for
cancelling it if no deposit follows), paid in ZEC before the maker opens it
and never refunded. Testnet asks it since 2026-11-21 (20,000 zatoshis);
mainnet asks none yet, and a quote without it takes the old path unchanged.
`open_fee.rs` and `forward.rs` hold the rules:

- Refused at the quote with nothing paid (the index is spent all the same):
  `zat` of 0 or above the deployment's `max_open_fee_zat` (500,000 on both
  networks; mainnet's is a placeholder until its gas-priced fee is known), an
  address that is not a canonical unified address of our network with one
  Orchard receiver and nothing else (`orchard_only`, which the pinned
  zecswap-core lacks), or a quote offered for less than 30 s
  (`OPEN_FEE_LEAST_REVIEW_SECONDS`) or living more than
  `open_fee_max_quote_life_seconds` (30 minutes). A fee quote is offered
  until `openFeePayBy`, Rust's alone: the deployment's
  `open_fee_min_quote_life_seconds` (180 s: time for a 75-second block to
  mine the fee) and 20 s for the tap (`OPEN_FEE_OFFER_MARGIN_SECONDS`)
  before its end, so it must live at least 230 s. Mainnet's quotes live 2
  minutes today, so its maker must lengthen them before it asks a fee.
- Paid only with that least life left, judged before it is proposed and
  again right before it is created: a stored payment is one the wallet's own
  sync sends again, so creation is the point of no return. The review offers
  a fee quote until `openFeePayBy` and then asks for a new one, so nobody
  bridges on terms they have not seen; on the amount step an expired fee
  quote is replaced once, then waits for the user, since every quote spends
  a swap index and shows the maker a payout address.
- Paid only by a wallet at the tip: an accept of a fee quote whose main
  wallet's scan trails the tip by more than 3 blocks
  (`OPEN_FEE_MAX_SCAN_LAG_BLOCKS`) is refused `WALLET_SYNCING`, nothing
  saved or paid, the offer still held; a fee the engine pays itself waits
  (`ZcashSyncing`) and ends `QUOTE_EXPIRED`, nothing paid, if the quote runs
  out first. Dart offers no Bridge on a fee quote, and asks for no fee quote
  once the maker asked one, until the wallet is within those blocks
  (`kPrivateUsdOpenFeeScanLagBlocks`, which a Rust test holds to Rust's),
  and says so on the review. A quote without a fee is as before. The accept checks first
  that the spendable Orchard and Ironwood ZEC cover the fee, the deposit and
  both network fees; the deposit's approved total allows one logical action
  more (`marginal_fee`), since the fee can take a note the deposit counted on.
  The accept runs under an op id, so a lock or the background stops the fee
  before it is saved, as any key step; nothing else answers that cancel, so
  an accept's post, fee or not, always completes.
- One payment of exactly `zat`, no memo (send flow
  `private-usd-open-fee:{account}:{index}`): the record is saved with the
  payment started before it is created (`openFeeAttempted`), the payment kept
  before it is first sent (`openFeePayment`), found again in the wallet after
  an interruption, and never built twice. It expires two blocks past the
  last one its quote's end expects (`deadline_expiry_height`), not 40 or 120
  on, and is not created with under a minute of the quote left. Veylor
  sends it, and again every 30 s while no block has it, only while that
  minute is left (a failed send waits its 30 s too); the wallet's sync stops
  sending it once its bridge ended or its quote is in that last minute
  (`withheld_fee_txids`), a payment created but not yet kept included (the
  account's sent transaction to the fee's address). "Call it off" refuses a
  bridge whose fee started.
- The accept goes from the engine loop, only once Veylor's wallet shows the
  fee mined. `402 feeRequired`, a `5xx` or no answer post the same accept
  again after `Retry-After` (else 5 s, or 12 s unanswered; at least 1 s the
  first time and 12 s after, at most 30 s), and never once `expiresAt` has
  passed. A refusal that says nothing opened ends the bridge, and the fee is
  lost; one that may follow an open is posted again until `expiresAt`. A
  quote that expires with the fee unseen ends `FEE_NOT_HONOURED`, once the
  chain shows no swap: a fee shown unmined may have opened one in a block a
  reorg took back. An accept whose answer was lost goes on from the chain:
  once the quote is over, the swap's confirmed `Opened` event gives its `t0`
  and `t1`, which the confirmed read holds to the terms hash before any
  deposit. An accept refused `QUOTE_EXPIRED` after its record was saved (a
  fee Rust could not create in time) shows that bridge, under way until the
  engine ends it. After a post whose answer is unknown (lost, a `5xx`, or
  made before a restart: the record's `acceptPosted`, `swaps.db` 9), an
  unknown quote, a `400` or a `404` is no word that nothing opened: the maker
  may answer so the second accept of a quote the first opened. The accept is
  posted again as an unanswered one is, and the chain decides at the quote's
  end; a quote without a fee, accepted again, likewise (review, 2026-11-22).
- A bridge that paid the fee waits for its change (`FundsPending`) rather
  than fail its deposit. Its fee transaction folds into its row in Activity,
  a paid or refunded bridge's details show the fee as not refunded (a
  refunded one's result says the maker keeps it), and a bridge that ended
  unstarted after its fee was mined keeps a row for the fee lost. A bridge
  with a fee payment is never titled "Nothing was sent". While an ended
  bridge's fee payment may still be mined (`openFeePending`), the engine
  reads that account's records again as the wallet scans, so its outcome
  catches up once the fee's block is scanned. Schema 7 added these record
  fields.

**Invariants (plan §3.5).** Each one guards funds or privacy. Keep them, and
keep the tests that pin them, in `rust/src/wallet/private_usd/tests/` and
`test/features/private_usd/`.

- Commit `next_index + 1` before any quote leaves the device, under the
  seed and ZIP-32 index the keys derive from (never the account UUID, which
  a re-import changes), and never reuse a swap index (a shared `z` hands
  that swap to its maker).
- Save the record before accept, and treat an accept that timed out or
  failed in transport as maybe opened, and so a refusal of a later post that
  may follow its open (an unknown quote, a `400`, a `404`).
- Never pay a deposit twice. Save `Started` before building it and the bytes
  before the first broadcast. Rebuild only once the old one is proven
  expired.
- Derive the deposit address from the on-chain shares, never from the API.
- Trust no swap read until the contract answers `MIN_WINDOW()` and
  `LATE_WINDOW()` as pinned and reverts `LOCK_DURATION()`. Refuse a maker or
  relayer that names other windows. Skip a swap index a retired lock
  contract shows in use.
- Reveal `z` only in its window, decided on one consistent read (the swap at
  the newest block's hash, with that block's number and time) of a fresh
  head, and again immediately before the post. A window opens by the block's
  time and closes by the later of it and the device clock. A head three
  minutes behind the device's clock is no fresh head (`ChainLagging`, shown as
  Ethereum out of reach), unless the node's own answers, by their HTTP
  `Date`, put the device's clock over two minutes ahead: then it is
  `ClockOff`, and the copy asks for the phone's, Mac's or computer's clock to
  be set (`privateUsdConvert{Error,Problem}Clock*`). A forward claim
  goes once the swap is ready (2 blocks deep before `t0`) or from `t0`, with
  more than 300 s left before `t1`, or for good from `t1 + LATE_WINDOW`; in
  between, the swap unwinds through the maker's refund. A reverse refund goes
  on an open escrow once the chain is past every `ready` deadline signed (or
  at `t0`), on a ready one from `t1`. Never `eth_call` or `eth_estimateGas`
  anything carrying a share. The one exception is a claim handed to the
  relayer: `z` goes once, to the pinned relayer alone, which reveals it on
  chain in the window, and only once the swap is ready at its confirmation
  depth. Never on an open swap: the maker may still cancel one, and its
  cancel reveals `e`, which with `z` spends the deposit, so the relayer
  alone could sweep it before the app does. On a ready swap the relayer
  alone can take the deposit only by withholding the claim until the maker
  refunds from `t1`, which the owner, who runs the relayer, accepts.
- Only confirmed reads authorize a deposit or the end.
- A reverse escrow's claim is swept home from its first block: `e` is
  public once the claim is in a block, and a reorg only has the maker claim
  again with it. The revealed share must open the joint account before the
  record keeps it (`revealed_share`) and moves; the sweep then goes on from
  the kept share whatever a later look shows, and the conversion stays
  settled, never refunded. Never build or prove the sweep before the claim:
  a sweep held from `ready` carries that moment on chain in its anchor and
  expiry.
- Offer a reverse refund (`ReverseRecord::cancellable`) only while calling
  off gets the dollars back: never once the user's `ready` is out, which
  leaves a ready escrow the maker's to claim until `t1` (its refund then
  goes by itself), unless the `ready` lapsed with the escrow still open, and
  never once a refund was posted. A `ready` the newest block shows has
  landed, never lapsed; it lapses only on one consistent read of a fresh
  head past its deadline that shows the escrow still open, and a refund
  that cannot land yet waits in the phase that read supports.
- Never prove a second reverse funding because a response was lost. Only
  a refusal of a funding's first post drops it for the user to pay again; a
  refusal of a later post keeps it, since an earlier post whose answer was
  lost may still land, and the chain ends it (review, 2026-11-22). Sign
  `ready` only before `t0` (its deadline, the head plus 120 s, before it),
  keep that deadline first, and never sign or send one once a refund was
  posted. Never re-sign `ready` after a restart; resend it.
- Keep every signed payout, refund payout, `ready` and Railgun send proof
  before posting it, and a claim or refund as posted, or a claim as handed
  over, before it goes. Cap every relayer fee at 2 USDC.
- Forget a kept send only when its first post is refused: nothing of it went.
  Once it was posted, a refusal keeps it (`refusedAt`, `swaps.db` 9) and only
  the chain ends it: its transaction in a block or every nullifier spent
  (landed), or some spent by another proof (it never can). Meanwhile it goes
  again, the same bytes, every 15 minutes, and the account's next payment
  waits. A reverted transaction is forgotten only when its nullifiers are not
  all spent (`sends.rs`; review, 2026-11-22).
- Joint sweeps broadcast before they store. `PROPOSAL_STORE` is
  consume-on-entry with an idempotent discard, as in the hardware invariants.
- Joint sweeps use Discard OVK, while the deposit uses the sender's OVK.
- A joint sweep pays at most its reviewed fee (a reverse sweep's estimate,
  approved with the settlement; a forward refund's 64 marginal fees), raised
  to ZIP 317's fee for the joint account's notes where the review fell short:
  notes paid in since, a sweep from one pool into the other, each bundle
  padded to two actions (`joint::sweep_fee_limit`). That is never more than
  four actions above the notes', and never the whole balance. Until
  2026-11-22 a sweep over its cap failed every step, and the ZEC waited in
  the joint account.
- Import joint accounts at the exact birthday, never the rounded restore
  birthday.
- Run one conversion at a time per account, and one outgoing Railgun payment
  at a time per wallet (the spend guard).
- The chain is the only evidence; the maker's status API never is.
- Never quote per keystroke. Every quote spends a swap index.
- A Railgun wallet decrypts from a creation block only when Veylor generated
  its seed (`AccountInfo.generatedSeed`): the seed's birthday, rounded down
  on both chains' block tables, a day early. Its mnemonic is the standard
  BIP-85 child, which any BIP-85 tool derives, so a restored, imported or
  claimed seed may have notes from before. The floor changes decryption
  only; every request a sync makes stays the same.
- Automatic balance refreshes follow Railgun's head (rail-squid's newest
  events, read every 30 s with the same request by every wallet) and a
  10-minute backstop, never what the wallet expects: a faster cadence while
  funds arrive told rail-squid, the RPC and the screening nodes when.
- Derive keys only after the seed-fingerprint check, and refuse a Railgun
  session whose address differs from Rust's.
- Deleting an account, or resetting, with a conversion under way warns with
  the count and waits for the user's explicit confirmation: the phones'
  sheets, and on desktop the removal dialog, Settings' reset and the
  lost-password reset. Drain `privateUsdLifecycleProvider` first, and clean up
  only after the Rust delete succeeds.

**Deposits (plan M9).** Public USDC sent to the account's own deposit
addresses (`m/44'/60'|1'/(1000 + zip32)'/0/index`, from the seed) is
shielded into its private balance by an EIP-3009 authorization the relayer
sends (`rust/src/wallet/private_usd/deposits.rs`, zecSwap's
`docs/deposits.md`). The Receive screen (`/private-usd/receive`,
`mobile_private_usd_receive_screen.dart`) switches, as ZEC's Receive does its
pools (`NeonSwitchTabs`), between public USDC at the deposit address (the
default) and 0zkUSDC at the account's 0zk address, for another Railgun
wallet; it replaced the screen's 0zk card (owner, 2026-10-19). It is a page
like the other Private USD screens, not a sheet, so the iOS edge swipe goes
back from it (owner, 2026-11-15). Only a network with a Deposits pin shows
the USDC side: testnet and, since 2026-10-19, mainnet; elsewhere the screen
shows the 0zk address alone. Send and Withdraw scan their recipient as ZEC
Send does (the shared `MobileScanAddressRow` and `MobileAddressScanCard`):
Send takes a 0zk address and Withdraw a 0x one (`privateUsdScanOutcome`); an
`ethereum:` request gives up its recipient, never its token, and one for
another chain is refused.

- Pin the Deposits contract, the relayer's deposits account (not the
  top-level relayer) and the token; refuse terms that differ, never follow
  them. Read the token's EIP-712 domain from the token and check its
  `DOMAIN_SEPARATOR()`.
- Sign only within the cap: `fee ≤ 2 USDC + ⌈value × 0.5%⌉` and
  `fee < value` (D23); a rescue pays the terms' `fee` alone, at most 2 USDC.
- Keep every request in `swaps.db` before posting it, post only what was
  kept, and re-sign one only while the relayer named no transaction for
  it. Only a mined receipt with the pinned contract's event for this
  address and one of this wallet's notes settles a deposit.
- Post the same bytes again when a named transaction has not mined in a
  minute: mainnet's relayer sends through Flashbots Protect, which the node
  never sees before a transaction mines and which drops one it cannot land.
- The deposit key signs only the authorization and a rescue: never
  delegate a deposit address (EIP-7702) or use one otherwise.
- Deposits follow the active account only, in the foreground and unlocked,
  on a lane of their own in the engine; the kill switch stops new ones,
  never one under way. `swaps.db` gained deposits at schema 2 and the windows
  contract's records at 3: a build that knows an older schema refuses it as
  newer.

**No Privacy Pass tokens (owner, 2026-11-21).** The open fee replaces the
token client (plan M4), which is gone; reference §5.9 and progress D-161 say
what went. A maker that answers an accept `401`, whatever its code, refused
it: nothing opened or paid, and the accept is never posted again (forward
`NothingSent(MAKER_REFUSED)`, reverse `CANCELLED`). `swaps.db` 8 dropped the
token issuer reverse records pinned. Private USD's start and a full reset
delete the token store earlier builds wrote
(`deleteLegacyPrivateUsdTokenStores`); Android's Keystore attestation keys
stay, unused.

**Railgun's sync (the page).**

- A refresh answers once the notes are scanned and checked. Railgun's
  transaction list and the proofs of the wallet's own sends then finish in
  the page (`sync-finish.js`), and end with a `synced` event. The refresh's
  `syncing` says that rest is long (or that its length can't be read), and
  `rest` numbers it within the page; `synced` carries the number, and Dart
  matches the two (`RailgunEngine`), never a count. A refresh while a rest
  runs joins it and sends it round again. The screen shows the balance with
  a line naming the change that waits, the idle close counts the page's
  events as use meanwhile, and the screen stays on through a first sync
  and any long rest after it. A rest's end restates the sync it followed:
  same time, and a refresh that failed since still stands. A send's own
  proofs never need that list.
- Every event the page emits must be in the hosts' lists (Kotlin's
  `RailgunProtocol.EVENTS`, Swift's beside it), or Dart never hears it; a
  Kotlin test reads the page's sources for them.
- The list's catch-up ends at a sync that adds nothing only once it has
  reached the screening nodes' validated index (`txid-catch-up.js`): the
  engine drops a batch whose root check failed without saying so, so short
  of that index, or while it can't be read, the sync is tried again, and
  then the catch-up fails.
- The page answers the engine's quick sync (`quick-sync.js`): rail-squid's
  pages through the SDK's own client and formatters, each stored as it
  comes, a page's unshields and nullifiers before its commitments (the
  engine resumes from its newest stored commitment). Rail-squid's lists are
  whole only up to its newest block when asked: one that ended before a
  page of commitments was asked for is read on first. A page it didn't
  answer is asked four more times over 15 s, as an archive request is. The
  commitments go into the trees 20,000 leaves at a time: the engine asks the
  contract about every insert's root, one call at a time, and a quick sync
  ignores the answer (a write can end inside an on-chain batch, at a root
  the contract never recorded), though a call that fails stops the write.
  What holds the trees to the chain is the check of every tree's root at
  the end of each scan: a wrong one fails the scan, never a balance. The
  engine goes on from a quick sync that failed by reading Railgun's events
  from the RPC itself, 500 blocks a read: more than 100,000 blocks behind
  the newest block (about two weeks; a first sync is over 11 million),
  the scan fails instead, saying the indexer didn't answer, rather than
  read for hours. Leaves the trees still lack once that read is done,
  written once more, fail the scan too (`guardQuickSync`): the end-of-scan
  check would pass the trees short of them. Not sooner: the engine's
  listener queues the newest blocks' leaves as they come, and rail-squid,
  behind the RPC, can leave a stretch that only the engine's read fills
  (review, 2026-11-22).
- `engine-hooks-plugin.mjs` holds every rewrite of the engine's code: the
  unshield watermark (`unshield-events.js`), the archive's leaf hashing
  (`archive-txids.js`), the txid sync's record updates
  (`txid-updates.js`), held until the txid tree has a group's root accepted
  and written in one batch just before the group, through a hook in
  `Merkletree.insertLeaves`, and, for `tree-recovery.js`, the end-of-scan
  root check reporting the root it refuses and a full rescan without its
  txid list reset (the page's rebuild runs the rescan's steps itself; the
  SDK's rescan still calls it). Each names the exact source of the pinned
  engine and fails the build against any other: re-check them when
  bumping it.
- **Anon's archive** (Android, iOS, the Mac, Linux and Windows, mainnet,
  Settings, on by default; `archive*.js`):
  - It gives commitments and the transaction list only. Unshields and
    nullifiers come from rail-squid: the archive drops a nullifier spent
    again in another tree, and a missing unshield stops the txid sync at its
    transaction for good.
  - Every file must match its published SHA-256, and the manifest is read
    again before the tip. Commitments must run on by tree position, each
    batch within its tree, and are stored only as far as rail-squid's lists
    show it has come. Positions are read as the engine places notes, by
    global tree position (tree × 65,536 + index): rail-squid and the archive
    both number the first leaf of mainnet's tree 1 as tree 0's leaf 65,536,
    and records keep that number. Transactions come in sequence, each
    verification hash continuing the chain: the chain, not the sequence,
    shows none is missing, so a sequence that skips a number is kept. A
    sealed chunk names its blocks, and so does the tip, from its first
    event's to its last's, so each mostly starts some blocks after the one
    before ends: the tip is taken when it starts after the last sealed chunk,
    as each chunk is after the one before. The positions and the chain, not
    the block numbers, show that nothing between them is missing, but for a
    tree's last batches: nothing in the events shows where a tree ended,
    from the archive or from rail-squid.
  - Times come from the shipped block table, never the archive. Records
    carry no archive railgunTxid; a transaction's leaf is hashed from the
    archive's, which the screening node's root check then vouches for. That
    root binds only the railgunTxid, and a wallet proves its sends from the
    record's fields: before proving, the page works out the railgunTxid of
    each send it is to prove, and when one doesn't match it clears the list
    and syncs all of it again from rail-squid, with the archive off for a
    week. Never react to a wallet's own transaction during a sync, or go
    back only as far as it: where the sync left the archive, or what it
    asked rail-squid for, would show them which transaction is the
    wallet's.
  - Never copy a tree's nodes from a file: a root check vouches only for
    what was hashed. (The archive's prebuilt trees were dropped for this.)
  - A notes tree whose root the contract has never had (a leaf stored
    wrong) fails every scan at the engine's end-of-scan root check, which
    reports the root it refuses. Once it has refused the same tree three
    times, whatever its root (new notes move a tree's root on with the bad
    leaf still under it), ten minutes or more apart in all, with no scan
    completing between, the page rebuilds every tree from the start with
    the archive off for a week, at most once a day from when the last
    rebuild completed (`tree-recovery.js`); a root an RPC hasn't caught up
    to passes by then. A refusal by an RPC whose newest block is not five
    blocks past the refused tree's newest leaf counts for nothing (the scan
    fails, saying the RPC is behind): rail-squid's lists can run ahead of an
    RPC that lags, which would otherwise rebuild the trees once a day
    (review, 2026-11-22). A scan that broke before that check counts for
    nothing: its store can end inside an on-chain batch, at a root the
    contract never had. The rebuild clears the transaction list first
    (rebuilt notes lack the railgunTxids its sync gave them, which proofs
    need), never begins while the engine syncs either or while the rest
    of a sync runs (which would read and hand on the balances it clears),
    and the list syncs again after the next scan that completes. It is
    kept unfinished from when its clearing begins until it ends: a page
    closed while clearing clears again, before its first scan, when it
    reopens, and one closed while the trees were built again goes on
    building them at its next scan, never clearing them again.
  - On anything unexpected the sync goes on from rail-squid where the
    archive left off. A request that fails on the way is sent four more
    times over 15 s (a phone's DNS can drop lookups for seconds), and a txid
    batch the engine kept nothing of is given three times. Rail-squid's
    lists failing beside the archive, or the archive out of reach (every
    try at a request failed or turned away), have the lists and the archive
    asked again from where they were stored, three rounds in all, 20 and
    40 s apart, before the archive is left: an HTTP/2 connection that stops
    answering fails every try sent on it until the browser gives it up, two
    minutes on a phone, and a phone's network can drop every connection for
    a minute. The archive's own data failing leaves it at once. A txid
    batch the archive ends partway through is handed over whole as far as
    the archive went when rail-squid fails to fill it. A sync
    within four days of the newest block (the most the archive's tip holds;
    from the clock and the block table when the RPC can't say) never asks
    the archive.
  - Android's host fetches the archive for the page through the page's
    bridge (`RailgunArchiveFetch`: 16 MB and a minute an answer at most, a
    fixed User-Agent), and so does the Mac's (`RailgunArchive.swift`, the
    same limits and headers): WebKit can't intercept `https`, so before a
    `start` that reads the archive the Mac runs a fixed prelude in the page,
    which sends archive GETs to the page's own origin (`/anon-archive/`,
    answered through the bridge) and hides the WebKit host from the start's
    archive check (the page reads the archive only where it finds none; its
    transport took the host at load). The prelude holds the `webkit` object
    it changes: WebKit makes it anew after a garbage collection, which showed
    the start the host again and kept 0.9.0's first mainnet sync off the
    archive. Linux's page process does the same (`railgun_archive.cc`: the
    prelude defines `messageHandlers` on the page's `webkit` object and holds
    that object; libsoup through the bridge, with the same limits and
    headers). iOS compiles the Mac's `RailgunArchive.swift` unchanged and
    runs its prelude and fetch the same way (since 2026-11-22; until then
    iOS started the page without the archive). Windows's page is Chromium,
    as Android's, so it needs no prelude: the host answers the page's archive
    GETs from WebView2's `WebResourceRequested`, through the wallet library's
    fetch (`railgun_archive.rs`; Windows's HTTP stacks have no SOCKS5
    client), with the same limits, headers and connections. Every archive
    request depends on the chain's state alone. What every host must do:
    `docs/private-usd-railgun-hosts.md`.
  - A host keeps the archive's connections as Android's `HttpURLConnection`
    does: one request at a time on each (HTTP/1.1), kept only after an answer
    read whole (five idle, five minutes), closed when its request fails, and
    all dropped when the network changes. Never multiplex the requests on one
    HTTP/2 connection: one that stops answering would take every try the page
    sends (`docs/private-usd-railgun-hosts.md`, H27).

**Network: Tor and the Railgun page.**

- All engine HTTP (maker, relayer, Ethereum RPC) goes through `routed_http`.
  It follows the route policy, fails closed while Tor starts or is broken,
  and never falls back to the clearnet.
- The Railgun page runs in a native Kotlin WebView host behind
  `com.zcash.wallet/railgun` (no Dart WebView plugin and no injected JS
  bridge). It loads only its own assets through `WebViewAssetLoader` and
  intercepts every subresource against a fixed host allowlist. The Kotlin
  and Swift allowlists (`RailgunEndpoints`), Linux's (`kHosts`, which Windows
  compiles), the Rust bridge's allowlist and the page's CSP must agree; Rust
  tests in `railgun_bridge.rs` pin them, Linux's events and methods to
  Kotlin's, and Windows's archive fetch, User-Agent and transport hello to
  Android's (CI's `pins` jobs in `veylor-linux.yml` and
  `veylor-windows.yml`).
  Its User-Agent is a fixed `Mozilla/5.0` (`RailgunRequests.USER_AGENT`),
  the archive fetch's too: the WebView's own names the phone's model and its
  Android build to every host the page reaches. On every host the page's
  requests also name one language, `en-US,en;q=0.9`, which the page sets on
  each `fetch` and `XMLHttpRequest` itself (`accept-language.js`): the
  engine's own Accept-Language names the device's languages.
- On iOS a Swift `WKWebView` host behind the same channel serves the page
  from `veylor-railgun://app/`, in a data store of its own whose SOCKS5
  proxy is the bridge (no failover), with a `WKContentRuleList` allowlist
  (iOS reference §6) and Android's `Mozilla/5.0` as the page's User-Agent:
  WebKit's own on iOS names the device's kind and its iOS version. The macOS host is the same on AppKit (macOS 14 and
  later): the same files serve the page, the same store identifier, proxy and
  rule list, and the 1×1 web view sits in the window's content view below the
  Flutter view, refusing the pointer, the keyboard and VoiceOver. Because the
  Mac compiles iOS's `RailgunEndpoints.swift`, the Rust pin test covers it.
- On Linux the page runs in `veylor-railgun-page`, which Veylor starts with a
  clean environment (the AppImage's GStreamer would break the system's
  WebKitGTK, and WebKit aborts a process whose sandbox can't start) and drives
  over a socket pair on the same channel contract. It loads WebKitGTK 4.1 and
  libsoup 3 at run time (nothing in the bundle links them) and serves the page
  from `veylor-railgun://app/` in a data manager under the identity's data
  directory, whose proxy is the bridge (no direct route), with a content
  filter of the same rules and a 1×1 view in an offscreen window. WebKit's
  sandbox is required: `supported` checks it in a process of its own (the web
  process must be bubblewrap's child), after the first frame, and every page
  checks it again; where it can't start, Shielded USD stays hidden. Ubuntu
  23.10 and later allow bubblewrap's user namespace only under an AppArmor
  profile, which the .deb installs for the page process (`/opt/veylor`) and
  an AppImage can't.
- On Windows the page runs in WebView2 in Veylor's own process: an
  environment per page, whose browser's only proxy is the bridge
  (`--proxy-server`, no loopback bypass, every local lookup resolving to
  nothing, no QUIC), made once the last page's browser process has exited.
  The page loads from `veylor-railgun://app/` (registered secure, with an
  authority), its store is the environment's user data folder in the
  identity's local app data, and `WebResourceRequested` serves its files,
  answers the archive and refuses everything off the allowlist. A script of
  the host's, run before the page's own, hands the page Android's
  `MessagePort` bridged to `chrome.webview`, so the page is unchanged. Its
  User-Agent is `Mozilla/5.0` with no client hints (DevTools' override), its
  environment's language en-US, whose header is the one the page sets itself
  (`en-US,en;q=0.9`), SmartScreen is off, and its 1×1 window sits
  under the Flutter view, disabled, with no accessibility tree. Where the
  Evergreen WebView2 Runtime is missing, `supported` is false.
- The page's traffic leaves only through the Rust loopback SOCKS5 bridge
  (`railgun_bridge.rs`), which uses arti when Tor is on. Its direct
  connections try IPv6 and IPv4 side by side (hyper-util's connector, as
  every other direct path): a network that hands out IPv6 it cannot carry
  otherwise stalls the page on its first IPv6 address.
- The page downloads Railgun's circuit artifacts from ipfs-lb.com and falls
  back to our mirror (`android/railgun-web/src/artifact-mirror.js`); the
  mirror's tooling is in `scripts/private-usd/artifacts-mirror/`. The SDK
  checks every file against its pinned hashes but a circuit's verification
  key, which only checks the page's own proofs before they go out: a proof
  the key refuses drops every kept key (`withKeysDroppedOnRefusal`), so one
  served wrong fails that proof, not every proof of its circuit for good
  (review, 2026-11-22).
- The POI nodes verify only proofs from the POI circuits wallet 11.2.0 ships
  (older ones get `Invalid proof`). A wallet bump that changes circuit
  artifacts needs the mirror refreshed and deployed first: every send and
  withdrawal proves POIs too, so a build the mirror cannot serve cannot send.
- On Sepolia the page reads Railgun's indexer (the transaction list and the
  quick-sync events) through our worker `railgun-sepolia-list`
  (`scripts/private-usd/sepolia-list/`, `sepolia-list-plugin.mjs`):
  - **Why.** The indexer's verification-hash chain breaks at transaction
    4188, which stops a wallet's transaction-ID sync and with it the
    screening of its own relayed sends.
  - **What it does.** The worker relays every query unchanged and
    recomputes only the broken hashes. It keeps no logs and stores nothing.
  - **When to drop it.** Its `X-Verification-Hashes` header reads `intact`
    once Railgun mends the indexer: then drop the worker, its host and the
    plugin.

  Mainnet reads the indexer directly.
- On any route change, close the page and stop the bridge, then reopen on a
  new bridge: Chromium keeps pooled sockets (plan U19). The page also
  closes on lock, on an account switch, and after 10 idle minutes.
- The bundle is GPL-3.0 and ships as a separately licensed asset with its
  notices. Never read `railgun.js` or the `.wasm` files into context.

**Never log secrets, and keep each one in its own store.**

- The keyed RPC URL is never logged or stored: a swap record pins only the
  keyless URL.
- Relayer tickets stay in `swaps.db` and are never logged.
- The mnemonic and the Railgun encryption key live only in secure storage.

How the code keeps to this:

- Rust's Private USD logs carry error codes and indices, never URLs,
  headers or bodies. Dart's debug lines carry runtime types.
- The page's console lines are never printed. Page error text is redacted
  (`redactRailgunMessage`) before any debug print.
- `RailgunStartParams.toString` hides `rpcUrls`.
- `run_device_round.sh --keyed-rpc` checks the logs and files on the device.

**Failure codes (desktop only).** Release builds print nothing, so the
desktop apps keep a short coded record of what failed in Shielded USD
(`private_usd_diagnostics.dart`): rotating JSONL in
`<support>/diagnostics/private-usd-*.jsonl`, 8 files of 256 KB, each opened by
a session line (version, build, network, OS).

- A line keeps only the op, the host's `RailgunHostErrorCode` or Rust's
  `ApiPrivateUsdErrorCode`, a reason from a fixed table
  (`PrivateUsdFailureReason`) that the page's or host's message is matched
  against, Dart's outcome (timeout, interrupted, paused, dropped, flow
  gone…), `n` (how many times this run) and the UTC minute. Never the message
  or any text, a URL, an address, an amount, a txid, an index, an account id
  or a key. The same failure again within its minute is only counted.
- Every hook is one call gated on `kDesktopFormFactor`, and
  `initializeZcashWalletRuntime` enables the recorder on desktop builds with
  Private USD: the phones record nothing and keep none of it, and tests
  write nothing.
- The records stay on the computer. Desktop Settings' "Copy failure codes"
  (the Shielded USD block) copies the newest 64 KB to the clipboard.
- A new failure path takes a hook; a page or host message worth telling
  apart takes a pattern in the table (an unmatched one reads `unknown`).

**Device rounds.** Use the Galaxy A35 over USB, never an emulator, and run
`ANDROID_SERIAL=RZCX40721QZ scripts/private-usd/run_device_round.sh`:

1. Run it with no flags first: this M3 round creates the testnet wallet.
2. Fund that wallet with testnet ZEC.
3. Run it again with
   `--m5 --m6 --m7 --m7-to 0x… [--m8-route] [--keyed-rpc <json>]`.

The rounds are heavy and need the owner's funds and services, so run them
only when asked. The checklist maps each flag to what it checks. The iOS
rounds use `scripts/private-usd/ios/run_device_round.sh` (the M3 round so
far), per `docs/private-usd-ios-device-checklist.md`.

**Pinned zecSwap and a local stand-in.** `zecswap-core` comes from
`ChinmayGopal931/zecSwap`'s `veylor/zakura-v5` branch, its build on Zakura
Common 5.4 (E1; `veylor/zakura-v4` was the Common v4 build), and
`zecswap-railgun` from its `main` (PR #18), which uses no Zcash crate. Veylor hands zecswap-core PCZT bytes (`sign_pczt_bytes`), so it
must sit on the wallet's exact libraries: a wallet move to new Zcash crates
needs a matching build on that branch first, and two Common versions side by
side are not acceptable even when they compile. `rust/Cargo.toml` also carries
one stand-in for a release that does not exist yet:

- `rust/vendor/zakura-client-backend`, the published 0.1.0-rc9.8 as `cargo
  vendor` writes it (the extracted `.crate`), with the `connect_stream` patch
  the Railgun bridge needs (`rust/vendor/zakura-client-backend.patch`, E4).
  The `[patch.crates-io]` entry keeps one backend in the graph: the SQLite,
  PIR, voting and private swap crates reach it from crates.io too. Before
  every push, `diff -r` it against the published crate: only `src/tor.rs`
  may differ. Never run `cargo fmt --all`, which reformats it. When the
  wallet moves to another backend release, vendor that one the same way
  (its `.crate` without `.cargo-checksum.json`, then the patch), and drop
  both once a release carries `connect_stream`.

Push to the owner's fork (`origin`) only when the owner asks; never merge
into `main` or open a PR unprompted, and never against upstream.
