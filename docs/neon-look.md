# The neon look

Moved from AGENTS.md on 2026-11-22. AGENTS.md lists where every former section went.

Veylor has a look of its own on every form factor: true black, neon red,
white light, Gotham Thin and Light, and 45° cuts instead of rounded corners,
after the Tesla Roadster teaser frames, Tron and Cyberpunk 2077. The phones
(iOS and Android) came first; desktop (macOS, Linux, Windows) took the same
look on 2026-11-18, keeping upstream's desktop layouts, screens, flows, sizes
and keyboard handling (see "Desktop" below). The owner directs the look on a
phone and on the Mac rather than in Figma, so the Figma comparison rules
below do not apply to it. Behaviour is unchanged unless a bullet below says
otherwise.

- **Palette.** Every semantic colour group has four named sets: `figmaDark`
  / `figmaLight` (upstream's Figma design) and `neonDark` / `neonLight`,
  and `dark` / `light` select the neon sets on both form factors (as
  `AppColors.dark` does). The Figma sets stay for the tooling and tests
  that pin upstream's design. The neon faces come from `NeonPrimitives`
  (`primitives.dart`).
  `AppNeonColors` (`colors.neon`) carries the lit elements' colours: the
  tube glow and its white-hot core on the page, the balance sign's light,
  the grid, and the white "headlight" frame. Light mode is brushed steel
  with the same red; the balance sign stays black in both. For now Veylor
  is dark only (owner: mobile 2026-10-17, desktop 2026-11-18):
  `kThemeLockedToDark` pins the theme and hides the Theme row in both
  Settings screens, iOS sets `UIUserInterfaceStyle` to Dark, and the Mac
  window opens in the dark appearance.
- **Shapes.** `AppRadiiNeon` is near-square (2 to 4 px, `full` is 4).
  `AppChamfer` sizes the 45° cuts drawn with `BeveledRectangleBorder`
  (`Neon.chamferBorder`, two-corner `Neon.wedgeBorder`). `AppButton` cuts
  its corners, and the primary slab casts a red glow; secondary buttons
  are glass with a hairline edge. `MobileSurfaceCard` is a glass panel with
  lit cut corners (`NeonGlassPanelPainter`), and `NeonGlassPanel` is the
  same panel for desktop's cards. Avatars are cut-corner plates with a red
  edge.
- **Light.** `lib/src/core/theme/neon.dart`: `Neon.textGlow`,
  `Neon.boxGlow`, `Neon.strokeTube` (halo, glow and core: every lit line
  uses it), the shared painter recipes (`Neon.bead`, `Neon.perspectiveGrid`,
  `Neon.chamferCuts`, `Neon.strokeUnlit`), `kNeonHudCaptionStyle` and
  `kNeonPageTitleStyle` (the page title). Motion lives in
  `lib/src/core/widgets/mobile/neon_motion.dart`: `NeonIgnition` (a sign's
  switch-on flicker, with an optional delay, off under reduced motion) and
  the `NeonAppearMotion` mixin for one-shot entrances.
- **Type.** Gotham everywhere, Thin and Light, and nothing on either form
  factor is Book (400) or heavier. Headings are Thin (100): screen, step,
  page and sheet titles, a state's statement (Home's "We're importing your
  wallet..."), and display numerals. Everything else is Light (300):
  subtitles, body, labels, field and helper text, buttons, chips, rows,
  card titles and the HUD captions. Emphasis comes from colour and size,
  not weight. Every `AppTypographyMobile` and `AppTypographyDesktopNeon`
  token is Thin or Light (`bodyMediumStrong` and the code styles
  included), so code leaves the token's weight alone; desktop draws
  `AppTypographyDesktopNeon`, the Figma desktop metrics in those weights,
  and `AppTypographyDesktop` keeps the Figma desktop mode for tooling and
  tests. `AppFontWeight` names the Figma weight a one-off emphasis stands
  in for and resolves to Light on both form factors
  (`AppFontWeight.heading` is the Thin heading weight); the legacy
  Material theme goes through it too, so unstyled text is Light. Desktop
  code's one-off weights are tokens, never a heavier `FontWeight` literal:
  desktop-only code uses `AppFontWeight`, and code the phones also run uses
  `AppSharedFontWeight`, Light on desktop and the Figma weight the phone
  always drew, so Korean and Chinese render Light on desktop too. Desktop
  builds still register no Gotham face heavier than Light
  (`gothamHeaviestWeight` in `gotham_fonts.dart`), as a guard; mobile
  registers every face. There are no exceptions.
  Page titles (`MobileTopNav.back`) are spaced uppercase Thin; section heads
  (Settings groups, Activity dates, Home's recent activity, on both form
  factors) are uppercase red HUD captions. These uppercase captions are a
  deliberate exception to the sentence-case rule; the strings themselves
  stay sentence case and are upper-cased where drawn.
- **Home.** The balance is a frameless neon sign: Thin red digits with a
  glow, the privacy eye (a bare glyph) to their right, the fiat line
  above, and the portfolio chart's line as a light trail below
  (`NeonPlotPainter`). Toggling the eye re-encrypts the digits
  (`NeonScrambleText`). Tapping the sign opens the full chart at
  `/portfolio-chart` (`MobilePortfolioChartScreen`), with the holdings
  under it (`MobileHoldingsPanel`: the shielded holdings, Ironwood,
  Orchard and Sapling ZEC and Shielded USD "on Ethereum", then
  their total, in dollars at Home's price once Private USD is in it, then
  the transparent ZEC, each with what is pending); a hidden chart (off, or
  no history) leaves the sign inert. The
  account sits in the top-left
  corner as a portrait only: a tap decrypts the name beside it for a few
  seconds, a second tap (or a long press) opens the account switcher, and
  screen readers get the name and the switcher directly.
- **Shielding.** Home's Shield button opens upstream's immersive flow
  (`/home/shield`, `/home/keystone-shield`, `/home/ledger-shield`) over a
  frozen Home, in the neon look:
  - Black over Home's Tron floor, which flows only while the wallet works
    or the shield assembles.
  - The amount in the balance sign's light, and red particles that turn
    white-hot as they land.
  - A cut-corner glass slider whose `Neon.strokeTube` edge lights up to the
    pin.
  - Success as a `NeonDoneSign`. Complete is the primary slab and Cancel a
    ghost button.
  - The Keystone QR stays black on white with its quiet zone.
- **Sync line.** `NeonSyncBackdrop` replaces the top bar's sync label on
  Home (desktop Home's pane draws it too: see "Desktop"). A Tron floor
  lies behind the content and flows only while
  something scans (idle, nothing moves and no frame is drawn), and a red
  line at 85% of the width (Railgun's on the Private USD screen too, since
  2026-10-19) rises from the bottom with the progress,
  its head reading `SYNC n%`, `SYNCED`, `SYNC FAILED` or `TOR …`
  (`NeonSyncReadout`). It has two layers (`NeonSyncLineLayer`): while
  syncing the line is drawn over the content (`NeonSyncLayer.front`,
  ignoring touches); once synced it runs behind, and Home backs its blocks
  with solid black (`NeonSyncOcclude`) so the line shows only in the gaps.
  Its head, from just above it down past the readout, stays in the front
  layer (`NeonSyncLinePart.head`), so nothing between the layers (the top
  bar, a scroll fade) cuts the line beside its readout. Scrolled away from
  the top (`NeonSyncScrolled`), a synced line's head and readout fade and
  the whole line runs behind; it follows the list's metrics notifications
  as well as its scroll ones, since a list clamped back to its top when
  its content shrinks sends no scroll notification (a finished bridge's
  banner going away once left the readout hidden at the top).
  A scan that starts at most 20 blocks behind the tip counts as synced, so
  the line does not drop and re-climb every block. The Private USD screen
  draws Railgun's sync the same way (`privateUsdSyncLine`), with readouts
  that name Railgun (`RAILGUN SYNC n%`, `RAILGUN SYNCED`, `RAILGUN SYNC
  FAILED`; the Tor ones are Home's): a first sync climbs, and so does a
  refresh the user waits on (the refresh button, the screen's own on
  opening, a new RPC: `refresh(showProgress: true)`), with the page's
  `refresh` events (`refresh-progress.js`: a bar split over its steps, never
  going back). The automatic ones (once Railgun's head has moved, read every
  30 s, and at least every 10 min) keep a wallet that synced before at
  `RAILGUN SYNCED` while the floor
  flows, unless the page reports a long catch-up on Railgun's transaction
  list (1,000 or more behind): that climbs as `RAILGUN SYNC n%`, since
  screening a send's change waits on the list. The refresh arrow never spins
  and always takes a tap: during an automatic refresh, a tap shows that
  refresh's progress instead of starting another. Private USD's Processing
  row adds a live line (smaller, in the accent colour) saying what the
  screening work is doing: syncing that list, downloading proving files,
  building a proof, the screening service checking notes (`n of m`), or
  waiting on the screening service (`privateUsdScreeningStatus`). Its
  Arriving row estimates from the newest shield the page's history lists in
  screening, any wallet's, else from the account's own payouts.
- **Tab bar.** Glyphs only: no slab, border or caption. `TronGlyph` draws
  the tab icons (and, on mobile, `AppIcon` draws its round icons —
  check, arrow-down, plus, warning, cancel, help — as angular glyphs). The active
  glyph is lit with a pool of light sliding under it; content fades to
  black beneath the bar. It has three tabs, Home, Activity and Settings
  (owner, 2026-10-19). Swap opens over them from a full-width button on
  Home, under Send and Receive, which split their row in half. Home has
  no Pay button. iOS keeps this bar and its side rail too: upstream's native
  Liquid Glass tab bar (`ios_native_tab_bar*.dart`, `NativeTabBar.swift`)
  stays in the tree, switched off by `kIosNativeTabBarEnabled` in
  `app_mobile_tab_bar.dart`, so later merges carry it unchanged.
- **Wide window.** A landscape window with at least 568 pt of safe width,
  a foldable or a tablet shows the wallet in a 440 pt pane beside a
  sidebar (`MobileWalletSidebar`, upstream's adaptive frame).
  - The panel is neon glass (`MobileSidebarSurface`, painted by
    `NeonGlassPanelPainter`) with its top-left and bottom-right corners cut
    and lit. It follows no display curve.
  - Its destinations are the tab bar's three: Home, Activity and Settings,
    never Swap. Swap, the chart and Private USD open in the pane, with
    Home kept lit. They use the tab bar's glyphs (`NeonSidebarGlyph`)
    beside Light labels. The active row is lit rather than filled: its
    glyph and red label glow over a pool of light that crossfades to a
    newly selected row.
  - The panel's foot keeps a sync readout for the pages without a sync
    line (`NeonSidebarSyncReadout`): a short rising line beside a red HUD
    caption. `NeonSyncLine.wallet` builds both it and Home's line, so the
    two always read the same.
  - The stateful Private USD flows keep the sidebar veiled (Back only)
    until their exits are designed against the invariants.
  - The vertical tab rail, shown when iOS reports a system side edge,
    stands in the bottom bar's fade.
  - A nested sheet's floating Back is a cut-corner glass button.
- **Art.** The medieval illustrations are gone from mobile, and from
  desktop's main surfaces (see "Desktop"): empty states use `NeonHorizon` (a
  striped 80s sun over a grid floor), hero and status spots
  `NeonGlyphBadge`, and painted backgrounds are dropped. The account
  pictures, on both form factors, are the ten neon portraits in
  `assets/profile_pictures/`
  (`pfp-01` to `pfp-07` and `pfp-16` to `pfp-18`, 224 px lossless WebP);
  ids of the retired knights (`pfp-08` to `pfp-15`) map onto the first
  seven, so a new portrait takes the next number from `pfp-19`.
  Payment-link gift card designs are unchanged. `VizorWordmark` draws a
  VEYLOR wordmark in tube strokes on both form factors
  (`VeylorWordmarkPainter`: lit red, or plain lines where a caller sets a
  colour); upstream's `vizor_logo.svg` is no longer drawn.
- **Keys and money flows.** The passcode keys are cut-corner glass plates
  that light red under the finger. Private USD calls a conversion a bridge
  in every user-facing string (owner, 2026-10-19: "Bridge", "Bridging",
  "Bridge progress", "Bridged to ZEC", "Bridged to 0zkUSDC"); code, keys
  and routes keep `convert`. It calls itself Shielded USD, and what it
  holds the shielded balance (owner, 2026-10-22: "Shielded USD", "Sent",
  "Received", "Shielding…"); code, keys and routes keep `privateUsd`. Private USD's convert screens put red
  captions on their panels and a direction switch between them that keeps
  its place (dimmed while unavailable, its edge breathing while a quote is
  on its way); the estimate churns as cipher (`NeonCipherChurn`) until the
  quote decrypts in, and every ledger row stays on one line
  (`PrivateUsdLedgerRow`, smaller type, hairlines between rows). Swap and
  conversion progress (`mobile_swap_status_content.dart`) is a red
  timeline: lit checks for done steps, the spinner kept for the current
  one, and a packet of light running down the rail into it; a finished
  bridge keeps no step current (`SwapAnimatedProgressRoute` lets its index
  sit one past the last step). A bridge that finishes in view lights a
  "Bridged" sign (`PrivateUsdBridgedHero`): `NeonDoneSign`, the sync
  screen's done badge, with a shockwave of two lit rings (the send
  screen's ripple as neon) and the send success haptic; opened later, the
  sign is simply lit.
- **Receive.** The address and request codes sit in a lit cut-corner frame
  (`ReceiveQrFrame`), always dark modules on a light plate, with Veylor's
  helmet as the badge in place of the pool's; the pool switch names the
  pools without glyphs. A Keystone account's
  `ReceiveQrSurface(scanOptimized: true)` renders as before, but for the
  badge. Receive keeps its copy-and-share row and the ghost Request button
  (share stays out of the top nav, and the code stays 260 pt); Request ZEC is
  upstream's page (`MobileReceiveRequestScreen`), with its code in the same
  frame. Home's Receive button opens upstream's receive options sheet.
- **Sync privacy screen.** The screen over a kept-awake sync
  (`SyncKeepAwakePrivacyLockScreen`) draws the progress as a lit red ring
  (a `Neon.strokeTube` arc to a bright head, unlit ticks ahead of it) that
  switches on around Thin glowing numerals, done and paused as
  `NeonGlyphBadge`s, and every title, its passcode prompt's included, as
  the page title.
- **Chart card.** The chart is drawn as a neon trail on a Tron grid; a
  scrub reads the line under the finger (interpolated value and time), not
  the nearest data point. Neither the card nor Settings names the price
  server. Settings offers no default range: the saved one (a week unless
  changed before) still opens the chart.
- **iOS.** The sync and transaction Live Activities
  (`ios/SyncWidget/SyncWidgetLiveActivity.swift`) are black and neon red
  with thin type and a thin red progress line; nothing starts them yet
  (`DynamicIslandManager` has no callers). The launch screen paints the
  `LaunchBackground` colour (black in dark mode, steel in light), and the
  keyboard toolbar's Done check is neon red. Sheets keep 4 px top corners
  and, on iOS, bottom corners that follow the display's curve, which would
  clip square ones.
- **Desktop.** Upstream's desktop screens in the look above, through the
  tokens and a few shared pieces; their layouts, sizes, flows and keyboard
  handling are upstream's. Shared widgets that both form factors draw keep
  mobile exactly as it was: a desktop-only change in one is gated on
  `kDesktopFormFactor` (see "Rules for new code"), and the phones' release
  code is unchanged by it.
  - The window is true black: the Mac window opens in the dark appearance on
    black (`appWindowBackgroundColor`, `launchBrightness` in
    `MainFlutterWindow.swift`), Linux's view is black, and Flutter paints
    `macosUtility.window` behind everything.
  - Cards and panels are `NeonGlassPanel`: the sidebar
    (`AppDesktopSidebarSurface(glass: true)`, the main and onboarding
    sidebars), `AppModalCard` (opaque), `ReviewWrapCard`, Settings' groups,
    Home's recent activity, the Activity feed's months (sliver segments are
    slices of one panel), the unlock card, and the cards every screen draws
    itself (2026-11-19): Home's notice, migration call and setup reminders,
    the Settings sub-screens, Send, Receive, Request, Pay and Swap, Accounts
    and Contacts, Voting, the migration screens, the onboarding panels and
    the popovers (accounts, contacts, assets, mnemonic suggestions, context
    menus; opaque). A choice among others is a `NeonOptionPanel`, whose
    outline a selection strokes, with a `NeonOptionCheck` (a cut-corner
    check plate in place of upstream's round one); a card that is a
    `Container` the phones build too swaps only its decoration, for a
    `NeonGlassDecoration`. Badges, tags and indicators are cut-corner plates,
    and the receive and request QR plates are cut and lit (the Keystone
    scan-first plate is not). The pane and its modal scrim are near-square.
  - Settings' groups, Activity's months and Home's recent activity are
    headed by red HUD captions.
  - No painted backgrounds: Home, Settings' sub-screens, the onboarding
    steps, the import method picker and the auth screens (unlock, the
    migration lock, the Gift Card claim) draw on black. The Welcome sets the
    neon horizon beside its pane in place of upstream's video, the
    onboarding sidebars a small horizon in place of their art, the unlock
    card the lit wordmark, and Home's and the address book's empty states a
    horizon. The wallet link outcomes are `NeonGlyphBadge`s. Desktop-only
    art went the same way: the Ironwood announcement, intro banner,
    how-it-works steps, expectations and completion (glyph badges and a
    horizon; the Ironwood wordmark stays), the donation badges and success
    backdrop, the uninstall badge (a lit plate whose glyph fades), the
    custom endpoint card, the swap timeout, the voting beta label (a lit tag
    drawing the label's own text), the intro card's pattern, the decorative
    divider (a lit diamond bead) and the storage-unavailable backdrop (a
    horizon). The Welcome's buttons are `AppButton`'s slabs.
  - Page titles are the neon page title: `NeonPageTitle`
    (`neon_page_title.dart`) draws a screen's title in `kNeonPageTitleStyle`,
    upper-cased where drawn and read as written. Every desktop screen's
    title takes it, keeping upstream's position; content headings (a poll's
    title, a card's heading, an empty state's statement) keep the Thin
    tokens, and modal titles take `AppFontWeight.heading`.
  - The neon signature pieces (2026-11-19) are the phone's widgets placed in
    upstream's desktop screens; a phone widget that needed a desktop size or
    input took a parameter whose default keeps the phone as it was. Every
    desktop page builds its own sidebar, and Home is built again on each
    return to it, so `DesktopNeonSession` (`desktop_neon_session.dart`) keeps
    what their light needs between pages: the sidebar row lit last, and
    whether the balance sign has switched on since the unlock.
  - **Sync line.** Home's pane draws the phone's line in its two layers
    (`NeonSyncBackdrop` back and front around the pane's content, under
    `NeonSyncScrolled` on the pane's own scroll view), at 85% of the pane's
    width. Home's blocks (the balance sign and its transparent tray, the action
    buttons and the migration button, the recent activity) are backed by
    `NeonSyncOcclude`; the empty state and the setup cards are not, as on the
    phone. The phone's rules hold: the floor flows only while something scans
    and draws no frame idle, and a scan from at most 20 blocks behind reads as
    synced.
  - **Balance sign.** The balance card is the phone's frameless sign
    (`_HomeDesktopBalanceSign` in `home_screen.dart`): `NeonScrambleText`
    digits in the shared `kNeonBalanceAmountStyle` and
    `kNeonBalanceTickerStyle`, the fiat line in `kNeonSignCaptionStyle`, the
    privacy eye a bare glyph to their right, and `NeonBalanceTrail` (the
    chart's line, `NeonPlotPainter`) below; the styles and the trail live in
    `home/widgets/neon_balance_sign.dart`, which the phone's Home draws too.
    It flickers on (`NeonIgnition`) the first time Home shows after an
    unlock, not on every return. A click, or Enter with the sign focused,
    opens `/portfolio-chart` (`DesktopPortfolioChartScreen`: the phone's chart
    card, read under the pointer as well as by a drag, with range chips that
    take a click cursor and the keyboard, then `MobileHoldingsPanel`, under
    the pane's back link). Without Private USD the holdings are the shielded
    pools, their total and the transparent ZEC; with it (the Mac) they list
    Shielded USD as the phone's do, and the phone Home's Shielded USD strip
    sits under the transparent tray, opening `/private-usd`, with a bridge
    under way's banner under the buttons (see "Private USD"). A hidden chart (off, or no history) leaves the sign inert. The Send, Receive and Pay buttons under
    it are `AppButton`'s slab (the primary lit, the secondaries glass with
    an outside hairline), the Ironwood call a glass panel with a lit square
    beacon, and the transparent tray sits under a hairline of white light
    with "Shield now" lit red while it can shield. The end-to-end tests'
    keys stay: `home_desktop_balance_amount_text` is a plain `Text` of the
    amount once
    the digits settle (`NeonScrambleText.textKey`), and the ticker is its own
    `Text`.
  - **Chart settings.** Settings has a Portfolio chart block after Account
    with the phone card's two switches, "Show on home" and "Use market
    prices" (`PortfolioChartSettingsControl`), on the same settings and
    storage, so the same defaults; the prices switch shows only where market
    prices are available, and holds still while the chart is off. Where the
    phone's Settings shows its Shielded USD rows, a Shielded USD block after
    System has the Ethereum RPC row (its dialog checks a URL as the phone's
    sheet does) and the relayer claims switch.
  - **Sidebar.** The main sidebar's rows are lit, not filled
    (`AppSidebarItem`): the phone sidebar's `NeonSidebarGlyph` at upstream's
    20 px icon size beside Light labels, and the active glyph and red label
    glowing over a pool of light that crossfades from the row the last page
    lit. Home, Activity and Settings are the tab bar's glyphs and Swap its
    `TronGlyph` swap; Pay, Vote and Sign out are `TronGlyph`s drawn for
    desktop (`pay`, `vote`, `signOut`). The importing loader keeps its icon.
    Its foot is the phone sidebar's `NeonSidebarSyncReadout`, built by
    `NeonSyncLine.wallet` as Home's line is, in place of upstream's status
    row and its block height; its text keeps the `sidebar_sync_text` key,
    upper-cased. Where Shielded USD is available to the account, Railgun's
    sync, a separate one, has a second readout under it, built by the
    Shielded USD page's `privateUsdSyncLine` (`RAILGUN SYNC n%`, `RAILGUN
    SYNCED`, `RAILGUN SYNC FAILED`) and starting no sync; a wallet Railgun
    never synced has none until a sync starts (only the page starts a first
    one), and a balance kept from an earlier session reads as synced, as on
    the page. The accounts popover is an opaque glass panel headed by a
    red HUD caption, with cut-corner slabs for its two actions, and the
    migration rail is lit red.
  - Not yet neon on desktop, and why: the Gift Cards feature (unchanged by
    design); art the phones also draw (the Keystone scan error in the
    migration flow, the payment-request caution letter, the privacy
    overlay's #141818 grey, the welcome-only button tokens the mobile
    Welcome uses); the Windows title bar (it cannot be checked on a Mac);
    and `ReceiveDesktopPreview`, a Widgetbook-only preview.
