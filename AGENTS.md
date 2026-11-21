# AGENTS.md

## Commands

```bash
# Always use fvm, never bare flutter
fvm flutter run
fvm flutter test      # mobile-tagged tests auto-skip (dart_test.yaml)
fvm flutter analyze

# Unless the task explicitly requires a visible window, run macOS E2E with the
# app window hidden. The scripts do this by default; opt out only when the
# window is needed for debugging or visual verification.
VIZOR_E2E_HIDDEN_WINDOW=false scripts/e2e/flutter-macos-regtest-import-sync.sh

# Mobile form factor: mobile-targeted runs and tests pass the token
# define. Details in the "Design Token Form Factor" section below.
fvm flutter run --dart-define=VIZOR_FORM_FACTOR=mobile
fvm flutter test --tags mobile --run-skipped --dart-define=VIZOR_FORM_FACTOR=mobile

# Rust tests (run from project root or rust/)
cd rust && cargo test

# After changing Rust API files (rust/src/api/*.rs). Use the wrapper;
# bare flutter_rust_bridge_codegen fails on rustc's expanded `super let`.
scripts/generate-rust-bridge.sh

# Clear app from iOS simulator (keychain + state + uninstall)
./clear-app.sh

# View Rust logs (log::info!, log::error!, etc.)
# FRB routes Rust logs to os_log (subsystem "frb_user"), not Flutter console.
# Run in a separate terminal:
log stream --predicate 'subsystem == "frb_user"' --level info

```

## Design Token Form Factor (VIZOR_FORM_FACTOR)

UI design tokens (typography, component sizing) are selected at **build
time**, not runtime. The Figma `Sizing` and `Fonts` variable collections
have Desktop and Mobile modes; both are compiled in as const sets, and
`--dart-define=VIZOR_FORM_FACTOR=desktop|mobile` (default: `desktop`)
decides which one the unsuffixed token classes (`AppTypography.*`,
`AppInputSizing.*`, ...) resolve to. The unused set is tree-shaken from
release builds. Source of truth:
`lib/src/core/layout/app_form_factor.dart` (`kAppFormFactor`).

### When the define is required

- **Every mobile-targeted invocation** — `run`, `build`, `test`, and
  `drive` alike. The test binary is compiled per-lane like any other
  build, so widget tests that assert mobile-mode UI need the define too
  (full lane command in "Test lanes" below).
- Desktop (macOS) runs, widgetbook, and plain `fvm flutter test` need no
  flag — the default is `desktop`.

### What happens when you forget it

- **Debug app run on a phone**: fails fast at startup (assert in
  `lib/main.dart`) with the exact flag to pass.
- **Tests**: the default lane never runs mobile-tagged tests (they
  auto-skip — see "Test lanes" below), so the only risk is the mobile
  lane itself: `--run-skipped` without the define resolves desktop
  values. `test/mobile_lane_sanity_test.dart` fails first, by name, in
  that case.
- **Release builds**: no guard either — release/CI lanes for iOS/Android
  must hardcode the define or they ship desktop tokens.

### Test lanes

A single `flutter test` invocation compiles exactly one form factor —
the define cannot vary per test. Mobile-UI tests are opt-in via the
`mobile` tag:

- A test file that asserts mobile-mode UI MUST start with
  `@Tags(['mobile'])`.
- `dart_test.yaml` marks the `mobile` tag as skipped by default, so the
  plain desktop lane (`fvm flutter test`, no flags) never runs them —
  they report as skipped with the mobile-lane command as the reason.
- The mobile lane re-enables them:
  `fvm flutter test --tags mobile --run-skipped --dart-define=VIZOR_FORM_FACTOR=mobile`
  (`--tags mobile` scopes the run to mobile tests, `--run-skipped`
  lifts the tag's default skip, the define compiles the mobile token
  set). Note `--run-skipped` lifts every skip inside the selected
  tests, so don't use `skip:` to park a broken mobile test — comment it
  out or fix it.
- `test/mobile_lane_sanity_test.dart` (tagged `mobile`) asserts the
  define, so a mobile-lane run missing `--dart-define` fails loudly by
  name instead of as confusing metric mismatches.

### Assets in widget tests

- The mobile token lane automatically filters app `assets/**/desktop/`
  artwork out of both asset loads and the asset manifest through
  `test/flutter_test_config.dart`. It forwards allowed loads to the original
  bundle; it does not copy assets or add a test wrapper command.
- A desktop-only asset request fails the mobile test even when an image
  `errorBuilder` consumes the error. Shared artwork belongs outside `desktop/`.
  Keep asset references and the relevant mobile/desktop screen tests together
  when adding, moving, or renaming files.
- `test/core/platform_asset_contract_test.dart` checks that desktop artwork is
  limited to Linux/macOS/Windows/web and that other runtime assets remain
  shared. A new subdirectory needs its own pubspec declaration. Run this test
  after changing assets or pubspec. The mobile-tagged
  `test/core/mobile_asset_bundle_test.dart` also runs these contracts and the
  filter regressions, so both normal test lanes validate them.
- Native video player mocks must check the selected asset against
  `AssetManifest.loadFromAssetBundle(rootBundle)`; a successful mock decoder
  alone does not prove availability. Native integration tests use the actual
  device bundle, not the host-test filter.

Untagged tests may run in either lane and must be lane-agnostic:

- Compare against token constants, not literal numbers:
  `expect(style, AppTypography.bodyMedium)` passes in both lanes;
  `expect(style.fontSize, 14)` passes only in the desktop lane.
- To pin one mode regardless of lane, reference the explicit sets:
  `AppTypographyDesktopNeon` / `AppTypographyMobile` (what each form
  factor draws; `AppTypographyDesktop` is upstream's Figma desktop mode),
  `AppAssetSizeDesktop` / `AppAssetSizeMobile`,
  `AppButtonSizingDesktop` / `AppButtonSizingMobile`,
  `AppInputSizingDesktop` / `AppInputSizingMobile`.
- `test/core/theme/design_tokens_test.dart` follows these rules and
  passes in both lanes — use it as the reference.

### Rules for new code

- App code uses only the unsuffixed selectors. Reference the
  `*Desktop` / `*Mobile` sets directly only in tooling that must show
  both modes inside one binary (widgetbook galleries, token tests).
- New tokens with per-mode values follow the same pattern: a `*Desktop`
  + `*Mobile` const namespace pair plus a const selector in the
  unsuffixed class. The `Spacing`, `Units`, and `Window` groups are
  identical across Figma modes and stay single-mode (`AppSpacing`,
  `AppWindowSizing`). `AppRadii` is single-mode too: both form factors
  draw the near-square `AppRadiiNeon`, and `AppRadiiDesktop` keeps
  upstream's Figma scale for tooling and tests (see "Neon look").
  Colours do not depend on the form factor either: both draw the neon
  sets.
- Form-factor branching in app code uses `kAppFormFactor` (const, so the
  dead branch is tree-shaken) — never `Platform.isIOS`-style checks. A
  desktop-only branch in code the phones also run is gated on the constant
  `kDesktopFormFactor` (`app_form_factor.dart`), as a conditional
  expression or an early return: the front end folds it before
  whole-program analysis, while an inline
  `kAppFormFactor == AppFormFactor.desktop` is not folded there and keeps a
  desktop-only class (and the type facts it changes) in the phone builds.
  A collection `if` changes how its list is built even when folded, so a
  gated list element is a conditional expression instead.
  Runtime `Platform` checks remain only for OS-specific *behavior*
  (keychain, background sync), not for choosing UI metrics or layout
  shells.
- Widgetbook is exempt from the platform/define match check: previewing
  mobile tokens on a desktop host is legitimate —
  `fvm flutter run -t lib/widgetbook.dart --dart-define=VIZOR_FORM_FACTOR=mobile`.
  Only `lib/main.dart` asserts the match.

## Neon look (Veylor)

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

## Google Play opt-out (VIZOR_DEGOOGLED)

Android builds include Google Play integrations by default. Direct APK and
F-Droid builds explicitly pass `--dart-define=VIZOR_DEGOOGLED=true`; the
reproducible APK builder exposes this as `--degoogled`. Dart and Gradle read
the same define. When enabled, Android review scheduling is disabled and the
Google Play review SDK and implementation are excluded from the build. iOS
reviews and desktop behavior are unaffected. F-Droid's wrapper always passes
`--degoogled` to match deployment's direct APK build inputs.

Mobile review eligibility is classified once from the first successful startup
snapshot and persisted in `vizor_app_review_history_v1`. Existing wallet users
skip the three-launch wait; new users retain it even after creating a wallet.
Both require explicit usage and two idle seconds on home, with at most two API
attempts and a seven-day retry interval. Legacy history keeps its attempt budget
and dates when the classification field is added. Blocked startup must not be
classified as a new user; retry recovery supplies the successful snapshot.

## Android Package (VIZOR_APPLICATION_ID)

Google Play lists Veylor as `com.veylor.app`; the tree's development id is
`com.keplr.vizor`. A Play bundle passes
`--dart-define=VIZOR_APPLICATION_ID=com.veylor.app`, which Gradle reads from
the forwarded dart-defines like `VIZOR_DEGOOGLED`; without it the build keeps
the development id. Never edit `applicationId` in place for a release. The
Play bundle is otherwise `flutter build appbundle --release` with
`--target-platform android-arm64,android-arm,android-x64` (every ABI the
plugins ship, or Play serves some devices a build without the core), signed
with the upload keystore through the `ANDROID_KEYSTORE_*` variables, a build
number above the last upload, and the keyed RPC JSON through
`--dart-define-from-file`. Keystore and attestation aliases do not depend on
the id, but app-link verification (`assetlinks.json`) and zecSwap's token
issuer allowlist name the shipped id.

## Android direct APK (verifiable)

Veylor's APK for direct download, beside Google Play, is the same app
(`com.veylor.app`), built so that anyone can check it comes from this
repository's code. Play's copy carries Google's Play App Signing key and this
one Veylor's APK-only key, so neither updates the other; a user switches by
uninstalling.

- **What it compiles.** The Play build's settings plus `VIZOR_DEGOOGLED=true`:
  `scripts/build-android-reproducible.sh --flavor veylor --universal
  --build-name 1.0.3 --build-number 10 --signing unsigned --degoogled`. The
  flavor defines `VIZOR_FORM_FACTOR=mobile`, `VIZOR_PRIVATE_USD_ENABLED=true`,
  `ZCASH_DEFAULT_NETWORK=main` and `VIZOR_APPLICATION_ID=com.veylor.app`, and
  nothing else: the price and wallet-link URLs keep their defaults, and there
  is no keyed RPC file (a build anyone can reproduce holds no secret). Neither
  build defines `VIZOR_RELEASE_VERSION`, so both show v0.0.0 in Settings; pass
  `--release-version` here once the Play build does. Upstream's builds keep
  `--flavor vizor`, the default, unchanged (`scripts/test_fdroid_tools.py`
  pins both commands).
- **One universal APK** with all three ABIs, versionCode the Play build's
  number: one file for the website to link and for a user to check. It costs
  size: 1.0.3 is 299 MB (arm64 alone would be about 123 MB), and a phone keeps
  the whole file, the other ABIs' libraries too. Without `--universal` the
  builder still makes one APK per ABI.
- **The build.** `.github/workflows/veylor-android.yml`, dispatched with
  `version` and `build_number` (`gh workflow run veylor-android.yml --ref main
  -f version=1.0.3 -f build_number=10`), builds the APK twice from scratch, on
  ubuntu-22.04 and ubuntu-24.04, from different checkout and toolchain paths,
  with no caches. Each build installs the pinned toolchain with
  `scripts/veylor-android-release/install-toolchain.sh`: Temurin JDK, the
  Android SDK packages, Flutter at `scripts/release-config/flutter-sdk.json`,
  Rust at `android-reproducible-rust-version.txt`. Only when the two APKs are
  byte-identical does the run attest the APK
  (`actions/attest-build-provenance`) and keep it as the artifact
  `veylor-<version>-<build>-unsigned`; otherwise it lists what differs
  (`scripts/veylor-android-release/compare_apks.py`, then diffoscope) and
  fails. The run signs and publishes nothing.
- **Signing, on the owner's Mac.** `gh run download <run> -n
  veylor-1.0.3-10-unsigned -D <dir>`, then `scripts/sign-veylor-apk.sh
  --unsigned <dir>/veylor-1.0.3-10-unsigned.apk`. The script:
  - checks the APK's attestation and contents, then signs a copy with
    apksigner (v3, the build's alignment kept; apksigner leaves v2 out, since
    minSdkVersion 30 verifies v3 on every device that installs it);
  - uses `~/keys/veylor/veylor-apk.jks` (PKCS12, alias `apk`), whose password
    lives only in the login Keychain ("Veylor Android APK keystore", account
    `veylor-apk`) and reaches apksigner in its environment, never a command
    line or a log; the key never goes to GitHub;
  - refuses any certificate but the one in
    `scripts/release-config/veylor-android-certificate-sha256.txt`;
  - checks with apksigcopier (pinned with hashes in
    `scripts/veylor-android-release/requirements.txt`) that the signed APK is
    the unsigned one plus the signature, byte for byte;
  - writes `veylor-X.Y.Z-N.apk`, `veylor-X.Y.Z-N-unsigned.apk` and
    `SHA256SUMS` to `dist/veylor-android/vX.Y.Z/`.
- **Publishing.** A release `veylor-android/vX.Y.Z` at the commit the
  attestation names, with those three files and the notes from
  `release_notes/veylor-android-vX.Y.Z.md`; the script prints the
  `gh release create` command. Never latest (`--latest=false`): the Mac's DMG
  link and update feed resolve through "latest". The website links the files
  by their tag.
- **Paths.** Both flavors build under `/tmp/vizor-android-reproducible`: each
  `libapp.so` embeds the canonical source path (Dart's plugin registrant), so a
  rebuild must build there too, and the Rust library carries its cargo home
  only as the remapped `/vizor/cargo`. Nothing of the checkout's, the
  toolchain's or the home directory's location reaches the APK (the
  `/home/runner` in the Railgun page's curve25519 wasm comes with that
  committed file); each CI build reports what it found (`host-paths-*.txt` in
  the artifact).

What a user runs to check a download (the release notes carry this):

1. `gh attestation verify veylor-1.0.3-10-unsigned.apk --repo
   ChinmayGopal931/vizor-fork --signer-workflow
   ChinmayGopal931/vizor-fork/.github/workflows/veylor-android.yml`: this
   repository's workflow built the file. Outside a terminal it prints nothing
   and only its exit status tells; `--format json --jq
   '.[].verificationResult.signature.certificate.sourceRepositoryDigest'`
   prints the commit, which must be the release tag's.
2. `apksigcopier compare veylor-1.0.3-10.apk --unsigned
   veylor-1.0.3-10-unsigned.apk` (`pip install apksigcopier`, with the Android
   SDK's `apksigner` on PATH): the signed APK is that build plus a signature,
   as F-Droid checks reproducible builds.
3. `apksigner verify --print-certs veylor-1.0.3-10.apk`: `Signer #1
   certificate SHA-256 digest:
   83f16e2037b09e731e51b3472466db43c4a962ada1fb4e40eaa4c3215a2174f5`
   (`83:F1:6E:20:…:21:74:F5`), Veylor's APK key.
4. To rebuild it on Linux x86_64: check out the release's tag, run
   `scripts/veylor-android-release/install-toolchain.sh --prefix <dir>
   --accept-android-sdk-licenses` and `. <dir>/env.sh`, then the builder
   command above. `build/app/outputs/flutter-apk/app-release.apk` has the
   unsigned APK's SHA-256, and `apksigcopier compare` takes it in place of the
   downloaded unsigned APK.

## Desktop identity (VIZOR_APPLICATION_ID)

Veylor's desktop apps are `com.veylor.desktop` ("Veylor") and
`com.veylor.desktop.testnet` ("Veylor Testnet", built with
`--dart-define=ZCASH_DEFAULT_NETWORK=test`), with the phone's icon (master:
the 1024 px image in `ios/Runner/Assets.xcassets/AppIcon.appiconset`). As on
the phones, the tracked files keep upstream's identity (`com.keplr.vizor`;
`app.keplr.vizor` on Linux) and a build-time switch selects Veylor's. Desktop
builds cannot read dart-defines natively, so each platform takes the id its
own way, and a malformed or unknown id fails the build:

- **macOS**: `scripts/macos-identity.sh com.veylor.desktop` writes the ignored
  `macos/Runner/Configs/FlavorOverrides.xcconfig` (name, bundle id,
  `VeylorAppIcon`, copyright, signing). It stays until
  `scripts/macos-identity.sh --clear`, and a fastlane run replaces it. Then
  `fvm flutter run -d macos` or `fvm flutter build macos --release`.
  - **Signing:** Veylor builds sign with Zapp LLC's team (`63UVRFCV97`): its
    Apple Development certificate and the Mac development profile "Veylor
    Desktop Mac Development". The profile lists the Macs a build runs on. To
    add a Mac, register it and regenerate the profile through the App Store
    Connect API. With `--release`, Release builds sign for distribution
    instead and compile Sparkle in ("Veylor macOS release" below).
  - **Testnet:** the testnet id has no profile yet.
  - **Where signing lives:** the Runner target's signing is set in
    `AppInfo.xcconfig`, not the project file, so the overrides can replace it.
    Upstream's release lane still writes its own settings into the project.
- **Linux**: `VIZOR_APPLICATION_ID=com.veylor.desktop fvm flutter run -d linux`
  (or `fvm flutter build linux --release`). CMake sets the GTK application id,
  the desktop entry, the hicolor icons (named by the id) and the executable
  `veylor`, which a `vizor` link serves to `flutter run` (`BINARY_NAME` stays a
  literal). The rename keeps the data apart: path_provider_linux names the
  support directory after the executable when it cannot load `libgio-2.0.so`,
  as on most machines without development packages.
  - **Builds run on GitHub Actions** (`.github/workflows/veylor-linux.yml`, on
    the fork, for pushes to `feat/linux-desktop` and on demand), never on the
    Mac. Each architecture builds on its own runner, x86_64 on `ubuntu-22.04`
    and ARM64 on `ubuntu-24.04-arm`, through upstream's lane:
    `fastlane linux release` with `VIZOR_LINUX_FLAVORS=veylor`, which runs
    `scripts/build-linux-release.sh` and `scripts/package-linux-appimage.sh`.
  - **What it builds:** mainnet, the desktop form factor, and
    `VIZOR_PRIVATE_USD_ENABLED=true`, which the build script passes on as a
    define. Shielded USD stays hidden until Linux has a Railgun host
    (`privateUsdPlatformHostsPage`). Flutter comes from `.fvmrc` through fvm,
    checked against `scripts/release-config/flutter-sdk.json`; Rust is stable,
    as cargokit picks it. After the build, the job reads the defines back from
    Flutter's generated config and fails unless they are those, with the
    `veylor` flavor and no keyed RPC URL.
  - **What it keeps:** `Veylor-linux-<arch>.AppImage` and its `.sha256`, as a
    workflow artifact for 30 days. Nothing is published.
  - **Signing:** the AppImages are unsigned. `LINUX_APPIMAGE_UNSIGNED=true` is
    the switch (`fastlane/linux/README.md`); an AppImage that embeds update
    information refuses it.
  - **Caches:** the Cargo registry and pub caches (shared by both
    architectures) and an sccache directory per architecture, each saved once
    per lockfile. Cargokit's target directory lies under `build/linux`, which
    the build script deletes first, so sccache is what carries Rust across
    runs.
- **Windows**: `$env:VIZOR_APPLICATION_ID = "com.veylor.desktop"`, then
  `fvm flutter run -d windows` (or `fvm flutter build windows --release`).
  CMake sets the version resource (company `com.veylor`, product `Veylor`,
  copyright Zapp LLC), the
  window title, `veylor_app_icon.ico` and the storage prefix `Veylor`, and
  fails if an inherited `VIZOR_WINDOWS_STORAGE_PREFIX`, `_COMPANY_NAME` or
  `_PRODUCT_NAME` disagrees. `Vizor.exe` keeps its name.

Every store follows from the identity, never from a renamed key, so nothing is
shared with an installed Vizor: the macOS container and Keychain access group,
the support directory (wallet DB and companions, Tor, Private USD,
diagnostics, Linux and Windows preferences), libsecret's
`<id>/FlutterSecureStorage` schema, the Windows Credential Manager prefix, and
the single-instance locks (D-Bus name and `$XDG_RUNTIME_DIR` lock on Linux, the
`%LOCALAPPDATA%` lock and activation message on Windows). Both apps register
`zcash:`; the OS hands a link to one of them. Code identifiers (`vizor_*` keys,
`VIZOR_*` flags, `Vizor*` names, `vizor.cash` domains) stay.

Packaging follows the same switch: the `veylor` and `veylor-testnet` flavors of
`fastlane mac|linux|windows` (`VIZOR_MACOS_FLAVOR`, `VIZOR_LINUX_FLAVOR`,
`VIZOR_WINDOWS_FLAVOR`), `scripts/build-linux-release.sh --flavor veylor` and
`scripts/package-windows-velopack.ps1 -ApplicationId com.veylor.desktop` make
`Veylor-macos.dmg`, `Veylor-linux-<arch>.AppImage` and the
`com.veylor.desktop` Velopack package; `scripts/package-linux-deb.sh` makes the
`veylor` and `veylor-testnet` .debs (`/opt/<package>`, side by side, with the
AppArmor profile Shielded USD needs on Ubuntu), which Veylor's Linux CI builds
beside each AppImage. Those packages have no updates: the
fastlane builds leave Sparkle out, the Linux check is off, and Windows hides
its updater in a build without a feed key. The lanes keep upstream's signing,
Apple team, match and release targets, and the macOS lane refuses to sign a
Veylor flavor. Veylor's macOS release has its own signing, notarization and
update feed, and Linux's comes from CI (both below); Windows has no Veylor
release yet.

### Veylor macOS release

`scripts/release-veylor-macos.sh --version 0.9.0 --build-number 1` builds a
release from a clean tree and publishes nothing:

- **Identity and signing.** For the build it selects
  `scripts/macos-identity.sh com.veylor.desktop --release`, then restores the
  earlier overrides. Release then signs with "Developer ID Application: Zapp
  LLC (63UVRFCV97)" and the "Veylor Desktop Developer ID" profile
  (MAC_APP_DIRECT), which grants the application identifier and keychain
  entitlements. The Runner target's Release settings add the hardened runtime
  and a secure timestamp. The script refuses any identity but Zapp LLC's.
- **Build.** Mainnet, Shielded USD on, the public RPC (no keyed RPC file):
  `ZCASH_DEFAULT_NETWORK=main`, `VIZOR_PRIVATE_USD_ENABLED=true`,
  `VIZOR_RELEASE_VERSION`, and `VIZOR_RELEASE_REPOSITORY` set to the fork.
  The version comes from `--build-name` and `--build-number`, never
  pubspec's, which the phones use. `flutter build macos --config-only` and
  `xcodebuild` build into `build/veylor-release`, so a Veylor running from
  `build/macos` keeps its bundle.
- **Sparkle.** `SPARKLE_ENABLED` is compiled in. A staged copy of the app gets
  `SUFeedURL`
  (`https://github.com/ChinmayGopal931/vizor-fork/releases/latest/download/appcast.xml`),
  `SUPublicEDKey`, a required feed signature and verification before
  extraction, as upstream's lane sets them. Sparkle's helpers and the app are
  then signed again. Upstream's update-over-Tor handling is unchanged.
- **Notarization.** `notarytool` with the App Store Connect key named in
  `~/dev/zapp/ios-zapp/fastlane/.env`, read in place (never copied, printed
  or committed). The app and the DMG are notarized, stapled, and checked with
  `spctl --assess` and `stapler validate`. Apple can take hours over a new
  team's first submissions: the script waits up to 12 hours, and if it stops
  first, the same command with `--resume` waits on the same submissions
  without signing again.
- **DMG.** `Veylor-macos.dmg`, volume "Veylor", with the neon background in
  `macos/Packaging/DMG/veylor/` (drawn by `render-background.swift`). dmgbuild
  (pinned with hashes in `scripts/veylor-macos-release/requirements.txt`)
  writes the window layout itself; nothing scripts Finder.
- **Appcast.** `generate_appcast` and `sign_update` with Veylor's EdDSA key:
  the login Keychain's `veylor-desktop` account, backed up (mode 600) in
  `~/keys/veylor/sparkle/`, which the script uses first. Never print or
  commit it. `check_appcast.py` checks the feed before it ships.

The assets land in `dist/veylor-macos/vX.Y.Z/`: `Veylor-macos.dmg`,
`appcast.xml`, `Veylor-macos.md` (the Sparkle release notes, from
`release_notes/veylor-macos-vX.Y.Z.md`), `SHA256SUMS`, `release-info.txt` and
the logs. Publish the first three unchanged to a release on the fork tagged
`veylor-macos/vX.Y.Z`, as a full release, not a pre-release or a draft: the
website's `releases/latest/download/Veylor-macos.dmg` and the feed resolve
through "latest", so any later release that becomes latest carries
`appcast.xml` too. The DMG's name never carries the version, and each release
takes a higher build number.

### Veylor Linux release

`gh workflow run veylor-linux.yml --ref main -f public_release=true` builds
`VEYLOR_VERSION` (set in the workflow) for x86_64 and aarch64 and publishes it.
A run without `public_release` stays `-internal.<run>` and publishes nothing.

- **Attested.** Every AppImage and .deb gets signed build provenance
  (`actions/attest-build-provenance`): its SHA-256 bound to this repository,
  the commit and the workflow run.
- **Published by the run.** The `publish` job checks each mainnet file's
  attestation and writes `SHA256SUMS`. It then creates the release
  `veylor-linux/vX.Y.Z`, tagged at the commit it built, with the notes from
  `release_notes/veylor-linux-vX.Y.Z.md`. The files on a release are the ones
  the run built; none passes through a computer.
- **A published version keeps its files.** A release already there takes
  files only from a run of its tag's commit (a publish that failed partway, run
  again). Anything else takes a new version: new files under a published name
  would fail the SHA-256 check of everyone who downloaded the old ones.
- **Never cancelled.** A push cancels the CI run before it, but a
  `public_release` run has a concurrency group of its own.
- **Never latest** (`--latest=false`): the Mac's DMG link and update feed
  resolve through "latest". The website links the Linux files by their tag.
- **Anyone checks a download:**
  `gh attestation verify <file> --repo ChinmayGopal931/vizor-fork`.
- **Not yet:** the AppImages are unsigned (`LINUX_APPIMAGE_UNSIGNED`), the .debs
  come from no repository, and nothing updates itself.

### Hardware Wallet QR Codes

Hardware-wallet PCZT QR codes prioritize scan reliability over Figma parity.
Use black-on-white square modules with an explicit quiet zone. Do not apply
decorative QR treatments to codes that Keystone devices need to scan.

The receive-address QR of a Keystone account is one of those codes: the device
scans it to verify rotating addresses. `ReceiveQrSurface(scanOptimized: true)`
draws it black-on-white with square modules in every theme and keeps the pool
badge. Its quiet zone is the white card's padding rather than modules inside
the bitmap; a Keystone device scans it at the current geometry. Software and
Ledger accounts keep the decorative dot style.

## UI Copy Conventions

- **Sentence case is the project default for all user-facing strings**: button
  labels, nav items, tab titles, toasts, dialog titles/bodies, sidebar items,
  tooltips, error messages, status labels, form labels, picker headers, empty
  states, page titles. Only capitalize the first word and proper nouns. Keep
  proper-noun acronyms in their canonical form (`ZEC`, `USDC`, `USDT`, `NEAR`,
  `Veylor`, `Keystone`, `Zcash`, `Ethereum`).
- Figma-authored display headings may keep title case.
- **Which brand.** Copy names the app Veylor on mobile and desktop alike:
  desktop now ships as Veylor (see "Desktop identity"). Only the links to
  upstream's GitHub and website keep Vizor (`aboutOpenGithub`,
  `aboutOpenWebsite`). Donations go to the owner's address
  (`kVizorDonationAddress`, kept equal to README.md's by a test); only
  desktop Settings offers them, and their copy says Veylor. Strings live in
  the ARB files (`lib/l10n`) and both forms are do-not-translate glossary
  terms. When an upstream merge brings a string that names the app, make it
  Veylor in English, Korean and Chinese, unless it links to upstream.
  Native copy that names the app follows the build's identity instead where
  it can (Windows message boxes and window title, macOS menus), and the
  macOS permission prompts say Veylor.
- This applies to interpolated labels too: `'$symbol deposit tx'`, not
  `'$symbol Deposit tx'`. The asset symbol carries its own casing; the rest of
  the label is sentence case.
- **Exception**: sidebar entries and screen titles may use Title Case (e.g.
  onboarding step labels `Secret Passphrase`, `Wallet Birthday Height`) — do
  not sentence-case them in copy sweeps.
- English copy lives in `lib/l10n/app_en.arb`, where each key's description
  says where it appears. Check `lib/l10n/glossary.yaml` for the shared terms
  before introducing new copy.
- When editing existing copy, also update widgetbook fixtures
  (`lib/widgetbook/*.dart`) and tests (`test/`) that assert on the literal
  string — `find.text(...)` matchers, `expectedNextAction` fields, and
  `_tooltipWithMessage(...)` helpers will break otherwise.

## Privacy Mode

Before adding or changing UI that shows an amount, read `docs/privacy-mode.md` (the hide-balance toggle).

On mobile, turning the phone screen-down also hides amounts from any wallet
page (flip to hide, `FlipToHideBalanceHost`); `docs/privacy-mode.md` has its
rules. It only switches privacy mode, so a screen that masks correctly needs
nothing more.

## Release Notes

When asked to prepare user-facing release notes or a changelog for a release,
read `release_notes/README.md` and create `release_notes/vX.Y.Z.md`.
Unless the request explicitly says otherwise, draft desktop release notes for
Windows, Linux, and macOS from desktop user-facing changes only. Exclude
mobile-only changes. Veylor's macOS releases use
`release_notes/veylor-macos-vX.Y.Z.md` ("Veylor macOS release").

### clear-app.sh

Removes the app from the booted iOS simulator including Keychain data. This is necessary when testing wallet creation/import because the mnemonic is stored in iOS Keychain via `flutter_secure_storage`, which persists even after a normal app uninstall.

## Architecture

Flutter + Rust FFI via `flutter_rust_bridge` v2. All Zcash cryptography and sync run in Rust (`librustzcash` crates). Dart handles UI, state management (Riverpod), and secure storage only. Supports iOS, Android, and macOS.

### Multi-Account Model

Single DB (`zcash_wallet.db`) holds multiple accounts from different seeds. Single sync loop decrypts notes for all accounts simultaneously via `scan_cached_blocks` (uses all UFVKs). UI shows one "active account" at a time.

**Account creation strategy** (due to `zcash_client_sqlite` constraints):
- **First account**: `create_account()` → `AccountSource::Derived`. Uses `init_wallet_db(Some(seed))` so the seed fingerprint is pinned to the DB and future seed-requiring migrations can verify relevance.
- **Additional accounts (even if derived from a known software mnemonic)**: `import_account_ufvk(AccountPurpose::Spending { derivation })` → `AccountSource::Imported`. We have to go through this path because `create_account` enforces a single-seed fingerprint per DB, so the second software account with a different mnemonic would be rejected. Derivation metadata (`Zip32Derivation { seed_fp, account_index }`) is attached to the `Imported` record so the account's origin is at least known, but librustzcash never stores the seed itself for imported accounts.
- **DB init after the first account**: remains `init_wallet_db(None)`. Calling `init_wallet_db(Some(other_seed))` after the first account would fail the seed relevance check if `other_seed` doesn't match the pinned `Derived` account.

**Multi-account migration limitation.** librustzcash `init_wallet_db` docs explicitly state:

> *"Note that currently only one seed can be provided; as such, wallets containing accounts derived from several different seeds are unsupported, and will result in an error."*
>
> *"We do not check whether the seed is relevant to any imported account, because that would require brute-forcing the ZIP 32 account index space. Consequentially, seed-requiring migrations cannot be applied to imported accounts."*

What this means for our DB shape:
- **Software bootstrap account** (`Derived`, known seed): future seed-requiring migrations run correctly for this account when the wallet was created through the software create/import path.
- **Imported accounts** (`Imported`, different seed fingerprint): the DB holds derivation metadata but not the seed, and librustzcash's migration machinery cannot distinguish "software account with a second seed we happen to know" from "external account imported from another wallet entirely." Both look like `AccountSource::Imported` with a non-matching fingerprint. The hardware (Keystone) case is a special instance of this general pattern, not a separate problem.
- What happens to 2nd+ accounts during a seed-requiring migration depends entirely on how the individual migration is written. Schema-only migrations (the common case) apply unchanged. UFVK-based re-derivation migrations also work. Migrations that strictly need the per-account seed for an `Imported` record either skip the step, run a best-effort fallback, or — in the worst case — refuse to complete.
- The correct mental model: **our wallet behaves as a multi-seed wallet inside librustzcash's officially-unsupported envelope**. Everything works today because current migrations tolerate `Imported` accounts. A future migration that doesn't is a real risk, and there is no clean in-library escape hatch because `create_account` cannot be called on a DB that already holds unrelated `Imported` accounts.

**Hardware-first wallet policy** (Keystone). Keystone accounts are allowed to be the first account. `importKeystoneAccount` in `lib/src/providers/account_provider.dart` routes a fresh install through password setup and then imports the hardware UFVK, and `import_hardware_account` in `rust/src/wallet/keys.rs` does not require an existing `Derived` account. This improves Keystone-only onboarding but accepts the known librustzcash tradeoff:
- A Keystone-first wallet can be `Imported`-only from DB creation time. Additional software accounts are also imported through UFVK metadata, so they do not automatically turn the wallet into a `Derived`-account DB.
- Current schema and UFVK-tolerant migrations should continue to work. A future seed-requiring migration that refuses `Imported`-only wallets may require a product recovery path, such as warning the user and re-importing/rescanning from the Keystone account birthday.
- Calling `create_account()` later is not a clean rescue mechanism for an `Imported`-only DB because that path itself depends on seed-aware initialization and seed relevance.

**Account deletion and reset invariants.** Per-account deletion is allowed for
any listed account while another account remains, including the initial
`Derived` seed-anchor account. Deleting that account can leave the wallet DB
containing only `Imported` accounts, which is the same migration tradeoff
accepted for Keystone-first onboarding: current schema and UFVK-tolerant
migrations should work, but a future seed-requiring migration may need a product
recovery path. Deleting the last remaining account is not a per-account delete;
the Accounts UI treats it as a full wallet reset, clearing the wallet DB, secure
storage, active account state, and routing back to onboarding. Dart
`AccountNotifier.removeAccount` and Rust `delete_account` still validate the
target account exists before removing account-scoped wallet rows.
Voting background work that can write account state or secure storage must
register with the destructive-operation drain before its first asynchronous
step, and account deletion/reset must await that work before clearing data.
Ledger outbox operations and their caller-side result persistence must register
with `ledgerOperationLifecycleProvider` before their first asynchronous step.
Account deletion/reset block new Ledger work and drain accepted operations before
invalidating the secret session or deleting wallet data. Keep the lease through
swap/pay metadata persistence and outbox acknowledgement; do not cancel a
broadcast after submission merely to unblock deletion. Device approval remains
outside this durable-operation lease. Ledger account import uses the same
`runMutation` boundary as software and Keystone imports. That boundary
(`runWithSyncPausedForAccountMutation` in
`lib/src/providers/wallet_mutation_guard.dart`) serializes account mutations,
a reset, and the Private queries toggle on every platform; only its keyring
interception is Linux-specific.
Each account's private transparent recovery companions live in the
`{dbPath}.tpir` directory beside the wallet DB. Rust `delete_account` removes
that account's companions after releasing the wallet write lock (a leftover is
removed at the next sync start); a full reset deletes the whole directory with
the DB and any `*.tpir` directory left by an earlier wallet. On iOS the
directory is excluded from iCloud and device backups, since it records which
transparent addresses had activity.

**Account identification**: `AccountUuid` (UUID string like `"550e8400-e29b-41d4-a716-446655440000"`). Passed as `String` between Dart and Rust via `Uuid::parse_str()` / `Uuid::to_string()`.

**Mnemonic storage**: Per-account in Flutter secure storage (`zcash_account_mnemonic_{uuid}`). Account list stored as JSON in `zcash_accounts` key. Active account in `zcash_active_account` key.

### Wallet Password Policy

- The local wallet setup/unlock password is **ASCII-only**. Accept only printable
  English letters, numbers, and symbols (`0x21`-`0x7E`).
- Do **not** implement keyboard-layout or IME normalization for passwords
  (for example, treating Korean 2-beolsik input as QWERTY). Passwords are
  compared as exact strings under this ASCII-only policy.
- Reuse the shared Dart helper in
  `lib/src/core/security/password_policy.dart` for all password validation.
- The charset validation message must stay exactly:
  `Use only English letters, numbers, and symbols.`
- **Mobile passcode**: the mobile form factor sets and unlocks the wallet
  with a 6-digit passcode instead of a typed password. The digit string
  is stored verbatim as the wallet password through the same
  `appSecurityProvider` prepare/commit path — there is no separate
  credential model. `kWalletPasswordMinLength` is form-factor dependent
  (6 on mobile, 8 on desktop) because the security provider enforces it
  on commit; the mobile passcode screens additionally require exactly
  6 digits (`kMobilePasscodeLength`).
- The passcode keypad's `?` help action resets the wallet and must appear only
  on the app-start `/unlock` screen. Never show it in any other passcode keypad
  context.

### Account Creation and Home Setup

Ordinary software creation and Gift Card creation defer secret-passphrase backup
and Zcash education to Home. First ordinary accounts generate their mnemonic only
after password/passcode confirmation; additional accounts create from Welcome with
the unlocked credential. Imports retain account customisation. Ordinary creation
uses `createAccountForDeferredSetup`, journaling the unseen seed in encrypted
storage before first or additional account mutations. Recovery must preserve the
seed, persona and account-specific `setupPending` / `giftEducationPending` flags.
The existing Home cards share backup snooze/completion and education completion
with Gift creation; education completion never marks a seed backed up.

A separate mobile reminder that asks new users to back up later is still being
built (Tony Yoon’s version). Integrate it at `TODO(backup-reminder)` in
`mobile_home_screen.dart`, beside the NU7 announcement host, and record its
rules here when it lands.

### Mobile Screen Privacy

Mobile screen privacy applies only while secret material is visible. Keep
`SensitivePrivacyOverlay` on seed creation/import/review, settings seed, and
viewing-key screens. It covers exposed secrets when the app loses foreground
interaction and uses `NativeSensitiveContentBridge` for selective native capture
exclusion (Android `FLAG_SECURE`, iOS `SecureScreenshotShield`). Ordinary screens
and access gates with no exposed secret must remain uncovered in the app
switcher; do not add app-wide native lifecycle covers.

Keep `RouteCoverageAware` on import screens so capture exclusion survives route
transitions and releases only after full coverage. Keep biometric prompt
suppression around sensitive access gates, and exclude shielded content from
screen-reader semantics without unmounting it. Desktop continues to use
`SensitivePrivacyOverlay`.

The mobile keep-awake lock owns system Back before payment cards and routes.
Back may return from passcode entry to the lock status screen, but never acts
on the covered app or interrupts authentication. Its idle deadline counts
pointer, keyboard and deliberate platform semantics actions; automatic focus
notifications do not extend it. Remove global input listeners on disposal.

### Dart Provider Structure

```
AccountProvider (account_provider.dart)
  ├── Manages account list, active account, per-account mnemonics
  ├── createAccount() — first: create_wallet, additional: generateMnemonic + addAccount
  ├── importAccount() — first: import_wallet, additional: addAccount
  ├── importKeystoneAccount() — hardware UFVK import; may be first account
  │                              (Keystone-first accepts Imported-only DB risk)
  ├── switchAccount() — updates active, refreshes address
  ├── renameAccount() — AccountInfo.copyWith (preserves isHardware)
  ├── clearSensitiveStateForLock() — preserves account list/active UUID, clears in-memory address
  ├── restoreAfterUnlock() — rehydrates active account UA from Rust after unlock
  ├── getActiveMnemonic() — reads from secure storage only while unlocked (null for hardware/locked)
  └── isActiveAccountHardware — routes send flow to PCZT pipeline when true

WalletProvider (wallet_provider.dart)
  ├── Watches AccountProvider
  ├── Exposes hasWallet, unifiedAddress, activeAccountUuid
  └── Propagates errors (does NOT mask as empty state)

SyncProvider (sync_provider.dart)
  ├── Listens to AccountProvider (ref.listen, not watch) — auto-starts sync on account creation
  ├── startSync() is fire-and-forget with _syncGen generation counter
  ├── startSync() no-ops while wallet is locked (`appSecurityProvider.requiresUnlock`)
  ├── clearSensitiveStateForLock() — clears in-memory sync state, cancels Rust work, stops polling
  ├── clearCachedWalletDbPath() — must be called after wallet reset/deleteAll()
  │   so the next sync resolves the newly generated DB name instead of using the
  │   deleted wallet's cached path
  ├── startSyncAnyway() — unlock recovery path for cancelled-but-still-unwinding Rust sync
  ├── Polls getLatestBlockHeight every 10s after sync completes
  ├── Checks at once when the mempool observer reports a new block
  ├── Re-syncs automatically when new blocks detected or previous sync incomplete
  ├── Duplicate sync guard: _isSyncing (Dart) + isSyncRunning() (Rust)
  ├── A start requested while its own stream still holds the Rust guard (its
  │   post-sync follow-ups included) is queued and runs when the stream ends;
  │   repeats coalesce, and a queued start is dropped if the app went background
  ├── `_sensitiveStateEpoch` discards late balance/progress updates after lock/sign-out
  ├── Passes activeAccountUuid to getBalance, getTransactionHistory
  ├── Sync itself is account-agnostic (covers all accounts)
  ├── Polling pauses on app background (onHide), resumes on foreground (onResume)
  ├── refreshAfterSend() called after account switch for immediate update
  ├── refreshAfterUnlock() restores the stored sync status, then the selected account's
  │   persisted display balance; it reads no wallet summary or history
  └── refreshHomeInBackground() refreshes live balance/history after sync starts; each publishes independently

SyncDisplayPercentageProvider (sync_display_progress_provider.dart)
  ├── Owns the 20 ms UI-only interpolation timer between Rust progress events
  ├── Watches only authoritative progress targets from SyncProvider
  ├── Exposes raw interpolated progress only to smooth progress indicators
  └── Exposes whole percentages to labels so unrelated UI does not rebuild per tick
```

### App Bootstrap

`main()` does a one-shot bootstrap before `runApp()` and injects it via
`appBootstrapProvider`. This snapshot is the startup source of truth for the
first frame and avoids the old `/welcome -> /home` jump plus the "empty home
until sync callback arrives" flash.

- `loadAppBootstrap()` reads:
  - secure storage (`zcash_accounts`, `zcash_active_account`, `zcash_wallet_network`)
  - Rust wallet DB metadata via `list_accounts` (one projection; no viewing-key
    decoding or address reads)
  - the selected account's receive address and persisted display balance, only
    when unlocked; no live balance summary or transaction history before `runApp`
- If the wallet is locked, bootstrap does **not** hydrate active address or
  initial balance/history; it routes straight to `/unlock` and lets the unlock
  flow repopulate that state.
- Router uses `bootstrap.initialLocation` instead of always starting at `/`.
- `AccountProvider` starts from `bootstrap.initialAccountState`.
- `WalletProvider` falls back to bootstrap values while `accountProvider` is
  still loading.
- `SyncProvider` starts from `bootstrap.initialSyncSnapshot` (balances, recent
  txs, scanned/tip heights) and then kicks off the normal live sync flow.
- Bootstrap is best-effort: route/account bootstrap can still succeed even if
  initial address/cache hydration fails, in which case sync state falls back
  to empty and the live sync repopulates it.

### Sync

The sync engine (`rust/src/wallet/sync_engine/`) and the Dart sync provider
(`lib/src/providers/sync_provider.dart`) are described in `docs/sync.md`.
Read it before changing either, and update it when their behaviour changes.

### Rust Module Structure

```
rust/src/
├── lib.rs              # pub mod api, ffi, wallet, frb_generated
├── api/
│   ├── mod.rs          # pub mod simple, sync, wallet, keystone
│   ├── simple.rs       # init_app() with setup_default_user_utils() + log level filter
│   ├── wallet.rs       # FRB: create_wallet, import_wallet, add_account, list_accounts,
│   │                    # delete_account,
│   │                    # generate_mnemonic, get_unified_address(account_uuid),
│   │                    # get_transparent_address(account_uuid), get_latest_block_height,
│   │                    # import_hardware_account (Keystone UFVK-only)
│   ├── sync.rs         # FRB: start_full_sync(StreamSink, mode), cancel_full_sync(),
│   │                    # set_sync_mode(), get_sync_mode(), is_sync_running(),
│   │                    # is_sync_cancel_requested(),
│   │                    # get_balance(account_uuid), get_transaction_history(account_uuid),
│   │                    # propose_send(account_uuid), estimate_fee(account_uuid),
│   │                    # execute_proposal, get_next_available_address(account_uuid),
│   │                    # create_pczt_from_proposal, add_proofs_to_pczt,
│   │                    # prepare_pczt_for_keystone_batch,
│   │                    # store_and_broadcast_pczts_with_keystone_signatures_for_proposal,
│   │                    # discard_proposal (hardware-wallet PCZT pipeline),
│   │                    # DESIRED_SYNC_MODE, SYNC_RUNNING, SYNC_CANCEL globals
│   └── keystone.rs     # FRB: encode_pczt_to_ur, decode_ur_to_pczt, encode_pczt_ur_parts,
│                        # encode_zcash_sign_batch_ur_parts,
│                        # decode_zcash_batch_sign_response,
│                        # decode_ur_part, reset_ur_session (#[frb(sync)]),
│                        # decode_accounts_from_cbor, decode_pczt_from_cbor,
│                        # decode_accounts_ur. Keystone UX is QR-only.
│                        # Re-exports KeystoneAccountInfo, UrDecodeResult from
│                        # crate::wallet::keystone via `pub use`.
├── ffi.rs              # Thin, read-only C adapter for iOS Ironwood migration
│                        # inspection and observable preparation-txid listing.
├── migration_preparation.rs
│                       # Platform-neutral mobile preparation core. iOS C FFI
│                       # uses only its read-only inspect, proof-readiness, and
│                       # observable txid reads. Its operation lifecycle,
│                       # preparation-only sync, advance, and cancellation have
│                       # had no native caller since the Android adapter was
│                       # removed (459a8565b).
│                       # Located outside api/ to avoid FRB codegen picking it up.
├── wallet/
│   ├── mod.rs          # pub mod keys, sync, sync_engine, keystone
│   ├── keys.rs         # Key derivation, mnemonic, account creation (Derived + Imported),
│   │                    # list_accounts, ensure_db_initialized, parse_account_uuid,
│   │                    # delete_account with account existence check and row cleanup,
│   │                    # init_db_and_create_account (software first-account bootstrap),
│   │                    # import_hardware_account (Keystone UFVK import;
│   │                    # Keystone-first is allowed)
│   ├── sync/           # Per-account wallet operations (balance, send, history, etc.)
│   │                    # All per-account functions take account_uuid parameter
│   │                    # NoOp Sapling provers for Orchard-only software TXs
│   │                    # TX broadcast via gRPC SendTransaction
│   │                    # PROPOSAL_STORE: in-memory HashMap<u64, StoredProposal>
│   │                    #   populated by propose_send, consume-on-entry from
│   │                    #   execute_proposal / create_pczt_from_proposal,
│   │                    #   explicit discard_proposal for cancel paths.
│   │                    # Hardware PCZT pipeline:
│   │                    #   create_pczt_from_proposal → add_proofs_to_pczt +
│   │                    #   prepare_pczt_for_keystone_batch → compact signatures →
│   │                    #   store_and_broadcast_pczts_with_compact_signatures_for_proposal
│   │                    #   (see "Hardware Wallet (Keystone) Send Flow" above for
│   │                    #   the broadcast-before-store and Sapling-params invariants)
│   ├── sync_engine.rs  # run_sync_inner() — retry wrapper (3 retries, 2/4/8s backoff)
│   │                    # run_sync_impl() — single sync attempt
│   │                    # MemoryBlockSource (BlockSource trait impl)
│   │                    # Single DB connection reused across entire sync
│   │                    # Checks cancel + mode mismatch after each download/scan/batch
│   │                    # Progress: work-unit fraction of a persisted sync job
│   │                    # has_new_tx from ScanSummary note counts
│   └── keystone.rs     # Keystone hardware wallet integration:
│                        # - UR (Uniform Resources) encode/decode for animated QR:
│                        #   batch-sign encode/decode, decode_ur_part, reset_ur_session
│                        #   (ur::Decoder directly, not KeystoneURDecoder, to avoid
│                        #   URType registry issues with `zcash-accounts`)
│                        # - Single-part UR helpers retained for compatibility
│                        # - QR-only product flow; USB transport is intentionally absent
│                        # - Global UR_SESSION: Mutex<Option<UrSession>>, auto-reset
│                        #   on type change / completion, caller resets via
│                        #   reset_ur_session() on scan-screen entry
└── frb_generated.rs    # Auto-generated by flutter_rust_bridge
```

### Foreground Sync and Platform-Specific Migration Preparation

Normal wallet sync has one path: Dart calls `start_full_sync()` through
`flutter_rust_bridge` and consumes `Stream<ApiSyncProgressEvent>`.
`DESIRED_SYNC_MODE`, `SYNC_CANCEL`, and `SYNC_RUNNING` belong to that foreground
path.

Only iOS has native background migration work. Android has none: commit
`459a8565b` removed its preparation and outbox WorkManager workers, their
Kotlin bridge, and `rust/src/android_jni.rs`. The private (denomination
preparation) mobile migration is iOS-only, and on Android its routes
redirect to the fast migration (`supportsPrivateMobileIronwoodMigration`).
The iOS contract:

```
Swift BackgroundMigrationPreparationManager
    → submit user-visible BGContinuedProcessingTask
    → read-only C FFI inspect / observable preparation txids
    → native lightwalletd GetLatestBlock + GetTransaction queries
    → update system task progress until every executed preparation tx has
      3 confirmations
    → record the foreground continuation and post a "step confirmed" alert
    → complete the continued-processing task successfully for that wave
    → leave sync / migration advance to foreground
```

- iOS submits `BGContinuedProcessingTaskRequest` only while denomination
  preparation is active. Its normal polling loop only queries the lightwalletd
  tip and each materialized preparation tx. It never runs a wallet sync or
  advances migration state.
- The iOS C-FFI inspection path opens SQLite with `SQLITE_OPEN_READ_ONLY` and
  queries only the run phase and stage counts it needs. It must not call
  `migration_status`, stage helpers that run `ensure_schema`, or any schema
  upgrade path. Missing or incompatible preparation tables are a foreground
  recovery signal, never a reason to repair the DB from the system task.
- The iOS task treats `NotFound` and mempool as zero confirmations, derives
  mined confirmation depth from the queried chain tip, and waits until every
  observable tx in the current wave reaches 3 confirmations. It then records
  the foreground continuation, posts a distinct "step confirmed" notification,
  and completes the continued-processing task successfully. One task tracks one
  wave; it never idles waiting for the user. Expiration of a mid-wave tracking
  pass is reported as pause-and-re-arm, never as failure. Foreground reentry
  owns the wallet sync, denomination advance, and submission of a fresh
  read-only task for the next wave.
- Android has no background worker and no native preparation or outbox path.
  Its migration runs in the foreground only.
- `rust/src/migration_preparation.rs` still owns a preparation operation's
  cancel token and desired mode, which foreground `cancelFullSync()` does not
  cancel; such an operation would share `SYNC_RUNNING` with the sync engine so
  two wallet scans cannot run concurrently. Nothing starts one today: the iOS
  task is read-only.
- The iOS already-signed migration outbox transport remains background-capable.
  It may query the chain tip and broadcast exact signed bytes, but it never
  scans the wallet.
- Account DB mutations quiesce and drain native migration work before changing
  the wallet DB.
- The removed general iOS background-sync identifier
  `com.keplr.vizor.sync` is cancelled once at launch as a tombstone for requests
  submitted by older builds; no handler is registered for it.

### Network Upgrades

Read [docs/network-upgrades.md](docs/network-upgrades.md) before changing send
expiry or block-time and wait-time estimates. It covers what the wallet refuses
around an upgrade, where those rules live
(`rust/src/wallet/network_upgrade.rs`), and NU7's block spacing.

### Tor and the network route

Tor covers the app's foreground traffic only. The desired route lives in Rust
process memory, applied by the Dart layer at startup and by the settings
toggle; every foreground lightwalletd and HTTP path goes through the
policy-aware openers and fails closed while Tor is starting or broken. Upstream
exempts a sync's large block download; Veylor does not (below).

- **Veylor keeps large block downloads on Tor.** Upstream lets a sync with
  Tor and Private queries on download its main-scan batches over a direct
  connection once the estimate reaches `DIRECT_BLOCK_DOWNLOAD_MIN_BYTES`.
  Veylor turns that route off (`DIRECT_BLOCK_DOWNLOADS` in
  `rust/src/wallet/sync_engine/mod.rs`): the direct session shows the server
  the device's IP address and resume height, and timing ties it to the Tor
  session. Keep it off. Upstream's rules, should the route come back:
  - Only the batches `batch_uses_direct_connection` allows use it. Every
    request that carries an address, txid or transaction stays on Tor.
  - Never dial an onion server directly (`block_download_can_go_direct`).
  - The session opens its Tor route first and fails closed with it; a direct
    failure sends the batch over Tor.
  - HTTP/2 pings only on a multi-threaded runtime (`keep_alive_fits_runtime`).
  - Settings copy says Vizor uses Tor to protect the IP address; it does not
    promise that every request goes through Tor.

  How it opens, falls back and reconnects, and what the server learns from it:
  "Direct block connection" in `docs/sync.md`.
- **Voting SDK network clients are constructed only in**
  `rust/src/wallet/voting/network_clients.rs`. Chain, helper, PIR, and
  vote-tree are separate transport roles; injecting a chain transport does
  not configure the tree. Both tree pre-sync and the round executor must use
  the same shared routed transport. When upgrading the SDK, audit new
  network-capable entry points and extend the routing table and service tests
  in `rust/src/wallet/voting/README.md`. The Rust suite includes a supplemental
  constructor guard; it does not replace checking actual network behavior.
- **A Tor connection that could not open is a `SocketException` in Dart.**
  The Rust Tor HTTP bridge retries an exit's DNS failure or Arti's
  `RemoteNetworkTimeout` once on a fresh circuit (`tor_stream_open_recovery`),
  then marks any stream-opening failure so `RustTorHttpBridge` rethrows it as
  the direct route would. Voting retry, vote-server failover, and config-mirror
  classification depend on that type; a raw Tor error string skips them all.
- **iOS background migration transport is pinned direct**
  (`open_background_direct_lwd_channel`), bypassing the route policy as a
  product decision. A background pass never brings Tor up or borrows the
  foreground's client, so routing that lane through the policy would only
  convert it into failures on a Tor wallet. The mobile settings card
  discloses this. Nothing in the foreground may use the pinned opener.
- **The saved route may be stricter than the enforced route, never laxer.**
  The saved preference is all a fresh launch has to go on, so a toggle
  persists in whichever order keeps this true at every intermediate point:
  enabling writes before the runtime switch (a failed write aborts a toggle
  that has not happened yet), disabling writes after it (a failed write
  leaves the stricter Tor value behind). `networkPrivacyPersistedRouteIsSafe`
  is the executable statement of this rule.

Key files:
- `rust/src/migration_preparation.rs` — shared mobile preparation core
- `rust/src/ffi.rs` — iOS read-only inspection and query adapter
- `ios/Runner/zcash_sync.h` — matching C header
- `ios/Runner/BackgroundMigrationPreparationManager.swift` — continued-task
  confirmation tracker and foreground-handoff owner
- `lib/src/providers/wallet_mutation_guard.dart` — mutation ordering fence
- `lib/src/features/migration/services/ironwood_migration_service.dart` —
  foreground preparation recovery

### Home portfolio chart

Home draws the chart's line as the balance sign's light trail on both form
factors, and a tap (a click on desktop) on the sign opens the full chart at
`/portfolio-chart` (`lib/src/features/portfolio_chart/`:
`MobilePortfolioChartScreen`, and `DesktopPortfolioChartScreen` on desktop).
Its wallet side is read from the local
wallet DB alone: `getAccountBalanceDeltas`, each mined transaction's
`account_balance_delta` once (Activity rows will not do: a transaction can show
as two rows with its whole delta each, and a ZIP 320 funding step as none),
folded per block into a balance step function once a sync has completed
(nothing while locked, and a mask in privacy mode). Its market side is public ZEC/USD
daily price history from the zapp pricing engine, `GET /v1/prices` on
`VIZOR_PRICING_ENGINE_BASE_URL` (default
`https://zapp-pricing-engine.majorworker.workers.dev`), through
`NetworkHttpClient`, so it follows the Tor route and fails closed. The Home
price is separate and stays on CoinGecko (`VIZOR_COINGECKO_PRICE_BASE_URL`);
the chart no longer reads that define.

- **Opt-in.** "Show on home" is on by default; "Use market prices" is off, so a
  fresh install makes no chart request and the chart is the ZEC balance. A
  saved choice is kept as written, and an unreadable "Use market prices" reads
  as off. The mobile settings card has no explanatory text under its
  switches (the owner removed it on 2026-10-17), and desktop Settings'
  Portfolio chart block has none either.
- **What a request carries.** The coin (`asset=ZEC`), the currency
  (`fiat=USD`), `resolution=1d`, two UTC dates (`from`, `to`) and `limit=1000`,
  in that order (the order is part of the server's cache key), and nothing
  else. The dates are whole UTC days ending at the last completed UTC day
  (yesterday, or the day before in the first ten minutes of a UTC day) over a
  fixed window per chip: 7, 30, 90 or 365 days, or for All from the server's own
  first day (`availableFrom`, learned from the 1w answer, as zapp does, so All
  costs one more fixed request; at most the newest 4,000 days), so every device
  sends the same request on a given day. Never put an address, key, seed,
  balance, account, wallet identifier, wallet-derived date or wallet-derived
  timing in it; balances and prices are joined on the device.
  `pricingEnginePricesUri` is the only place the request is built, and
  `test/features/portfolio_chart/portfolio_chart_history_test.dart` pins its
  keys and values.
- **When it may leave the device.** `portfolioPriceRequestsAllowedProvider` is
  the one gate in front of the price source: "Use market prices" is on, the
  chart is shown on Home, market prices are shown at all
  (`zecMarketDataAvailableProvider`, the Home price's own gate, which follows
  the active account through Private USD) and there is a usable server, the
  wallet is unlocked, privacy mode is off, and the app is in the foreground
  (`appInForegroundProvider`). While any of these does not hold nothing is
  requested; only an already cached series is drawn. On desktop the
  foreground is a window on screen, focused or not (`inactive` counts); a
  window that is minimised, hidden or on another Space is `hidden`, and from
  then the gate stays shut until the app is active again (`resumed`), however
  many syncs complete meanwhile. Locking ("Sign out") shuts it too. An
  empty, non-https or invalid `VIZOR_PRICING_ENGINE_BASE_URL` has the same
  effect for good: no price switch in Settings and no request.
- **The answer is untrusted data.** `parsePricingEnginePage` and
  `assemblePriceSeries` accept a series only when it is the documented
  document for the same asset, currency, resolution and dates; its
  availability is whole UTC days; every price is finite, positive and
  consistent; and its timestamps are UTC midnights, ascending, one day apart,
  inside the window and the availability. A page that is not `complete`
  follows its `nextCursor` (its UTC date becomes the next `from`, as in zapp)
  for at most four pages, and a series that would need more, or whose cursor
  repeats or goes back, is refused rather than drawn short. https only, 30 s
  per request and 90 s in all, 512 KiB per page.
- **Fallback and cache.** Any failure falls back to the ZEC balance with
  "Prices unavailable" on the card and a five minute cool-down. Prices are
  cached in memory only, per range and window (a window moves at UTC
  midnight); a window the server had not finished is asked again after 30
  minutes; a series more than a day behind is marked "Older prices".
- **Valuation.** The balance side is exact (block times) and the prices are
  daily, so `buildPortfolioChart` draws every price of the window and places a
  balance change between two prices at its own time, valued on the straight
  line between them. Do not sample the balance at the price timestamps alone:
  that draws a receipt as a day-long slope and gives a wallet funded since the
  last price no chart. A daily price is dated by its UTC day when scrubbed.

### iOS Preparation Confirmation Tracking

`BGContinuedProcessingTask`
(`com.keplr.vizor.ironwood-preparation`) polls lightwalletd every 60 seconds
while an executed denomination preparation waits for confirmations.

- `BackgroundMigrationPreparationManager.swift` owns the task, reads observable
  txids through C FFI, updates the system task `Progress`, and advances its
  progress heartbeat every 15 seconds.
- `NativeLightwalletdClient.swift` uses only `GetLatestBlock` and
  `GetTransaction`; it checks both txid byte orientations.
- `NotFound`, mempool height `0`, and fork height `UInt64.max` contribute zero
  confirmations. A normal mined height contributes
  `tip - minedHeight + 1`, capped at 3.
- A preparation transaction the tracker saw broadcast while the next block
  was still before a network upgrade, and that the server reports `NotFound`
  on two consecutive passes once it is past, was dropped at activation (nodes
  clear old-branch transactions, ZIP 200). The wave goes to the foreground
  without failing the task, since only the foreground can stop the run.
  Transactions first seen later may target the new branch and are not judged.
  The check reads `zcash_next_upgrade_activation_height` and process memory,
  not the wallet DB.
- Reaching 3 confirmations finishes only the current observation wave. The
  manager stores a foreground-continuation token, posts an “Open Veylor”
  notification under its own `confirmedWaveReady` kind so healthy copy never
  reuses failure copy, and immediately completes that system task successfully
  without opening the wallet DB for sync or advance. It does not wait for the
  user; a completed wave leaves nothing for a read-only task to observe.
- Foreground reentry acknowledges the token before syncing and advancing the
  durable run. If another transaction wave is materialized, it submits a fresh
  read-only continued-processing task.
- A foreground handoff records continuations only for runs that genuinely need
  the foreground — never for a run the read-only task could still finish. A
  multi-account task otherwise parks an account that is merely mid-wave, and
  that account stops being re-armed until the user makes it active. The
  "is a preparation bound to this request" boolean stays broader than the
  recorded set on purpose: it gates cancellation of the pending request, so
  deriving it from the recorded set would cancel healthy mid-wave runs.
- OS expiration is completed without a failure presentation and re-arms
  background tracking, because it interrupts one execution opportunity rather
  than proving the migration failed. Expiry posts no notification of its own:
  scopes whose waves already confirmed keep their earlier step-confirmed
  alert, and the interrupted wave resumes when the re-armed task runs.
- While private queries are on, the task does not track
  confirmations. A background pass cannot advance the wallet's scanned
  state, so it can never accept a Status PIR anchor, and it must not fall back
  to a public `GetTransaction`. `migrationPreparationContinuedTaskDisposition`
  maps a continued-processing target to `.foregroundOnly`, so the task is not
  submitted (`blocked_private_recovery`) and a launched task hands off to the
  foreground. Dart sends the effective setting through the
  `setPrivateRecovery` channel method at startup and on every toggle. Native
  treats a value it never received as private. Dart likewise resolves an
  unreadable saved preference to private for that launch without writing it
  back, and a blocked bootstrap applies no setting at all.

### Send Flow

2-step: `propose_send(account_uuid)` → confirmation dialog (shows fee) → `execute_proposal()` → broadcast via `SendTransaction` gRPC.

- Integer-only ZEC-to-zatoshi parsing (no floating-point)
- Real fee estimation via `estimate_fee(account_uuid)` on each keystroke
- No-op Sapling provers for Orchard-only TXs (avoids 50MB param download)
- Post-send: `refreshAfterSend()` for immediate pending TX display
- Friendly error messages via `_friendlyError()` pattern matching

### Ledger Device-App Limits

Before changing a Ledger send, Gift Card, shielding, swap, or voting flow, read
`docs/ledger/limitations.md`. **32 actions per pool does not mean 32 recipients:**
the device can review only **4 external shielded outputs across both pools**;
internal change is excluded. Numeric limits live in `rust/src/wallet/ledger/limits.rs`.
Keep account-key verification before PCZT transmission. Apps before 3.10.0
reject the NU7 branch and an Orchard spend into Ironwood; `LedgerAppSupport`
carries what the connected app can sign, and the serializer refuses the rest.

### Signing Cancellation

Keep desktop and mobile consistent when cancelling signing, not merely closing the QR scanner:

- Send / Gift Card: preserve inputs, return to Review, and refresh balance and fees before retry.
- Swap / Pay: return to the composer without preserving inputs; obtain a new quote on the next Review.
- Vote: preserve saved partial signatures and resume unsigned bundles.
- For transaction proposals, finish input-lock release and balance refresh before allowing retry.

Send proposal reservations are process-scoped until a signed outbox checkpoint
or the first broadcast attempt. Wallet-owned PCZTs carry the reservation owner;
strip that metadata from device signer views. Ledger checkpoint insertion and
reservation transfer must commit in the same SQLite transaction. Keystone marks
retention before the first network submission, including TEX's first round.
A hardware TEX request's ZIP 320 ephemeral address follows the same boundary:
releasing the request before that boundary returns the address, so cancelled
approvals cannot exhaust the ephemeral gap limit; after it the address stays
reserved.
Normal app exit closes the proposal gate and requests sync cancellation.
Desktop exits hide the window before awaiting reservation cleanup, except on
Linux. Linux keeps the window visible during the same bounded cleanup, then
calls `exit(0)` instead of GTK hide/destroy teardown to avoid the compositor
shutdown crash. Rust allows 250ms to
acquire the wallet write lock and drain accepted DB creators, then releases only
unsubmitted reservations without waiting on SQLite contention. Once the budget
expires, it starts no further cleanup; unfinished work is left for startup
recovery. It does not interrupt an active DB operation. Dart bounds its cleanup
wait at 300ms. On macOS, the exit-only `desktop_exit` channel orders the window
out synchronously and suppresses last-window auto-quit while Dart is preparing
its exit reply; ordinary window visibility still uses `window_manager`.
Backgrounding or hiding a window by itself does not end the session, except
that mobile returning after 15 minutes in the background locks it through the
sign-out sequence (`BackgroundAutoLockHost`).
Before the first balance read after restart, the DB migration gate recovers
abandoned process-scoped reservations without network access. Legacy retained,
signed, and ambiguous-broadcast reservations keep their expiry-based recovery.
Never clear all account locks: migration owners and durable outbox work are
outside cancellation cleanup.

Android Ledger device work must use `LedgerMobileHandler.launchOperation`,
including app queries and app-opening approval, not only signing APDUs. Register
ownership before dispatch, settle each MethodChannel result once, and retain the
SDK-wide exclusion until the job actually completes after cancellation. Discovery
and disconnect cleanup also participate in exclusion across Activity recreation.
Dart preparation uses `ledgerDeviceRequestsProvider`: capture before the first
await and check before starting the next stage or publishing a result. Do not
apply this cancellable device policy to already-submitted durable broadcasts.

### Hardware Wallet (Keystone) Send Flow

Normal hardware sends use Keystone's signatures-only batch protocol, even for
one transaction. The device cannot generate ZK proofs (proving keys are too
big for the device), and the phone cannot sign (the spending key lives on the
device), so Veylor retains the proof PCZT and applies only the compact
Orchard/Ironwood signatures returned by Keystone.

```
1. createPcztFromProposal                         → base PCZT (phone)
   (IO-finalized, no proofs, no signatures)
      │
      ├── 2a. addProofsToPczt(base, params?)      → pcztWithProofs
      │       (Orchard or Ironwood proof; Sapling output proofs if the
      │        proposal has needsSaplingParams=true)
      │
      └── 2b. preparePcztForKeystoneBatch(base)   → compact redacted PCZT
              → zcash-sign-batch QR
              → device signs Orchard/Ironwood spend_auth_sig
              → zcash-batch-sig-result QR         → signatures only
                                                         ↓
3. storeAndBroadcastPcztsWithKeystoneSignaturesForProposal(
     pcztWithProofs, signatureBlobs,
     spend_params?, output_params?,
   )                                                → txid
```

Roles in the split:

| Step | PCZT role | Runs on | Needs what |
|------|-----------|---------|------------|
| 1 | Creator + IoFinalizer | phone | wallet DB |
| 2a | Prover | phone | proving params (Orchard or Ironwood; Sapling ~50MB if the target recipient is Sapling) |
| 2b | Batch redactor | phone | wallet-owned base PCZT |
| sign | Signer | device | spend authorization derivation (device holds USK) |
| 3 | Signer application + TransactionExtractor | phone | wallet-owned proof PCZT, compact signatures, verifying keys, and wallet DB |

The v1 `BatchSignResponse` can represent only Orchard and Ironwood spend
authorization signatures. It cannot represent transparent-input or Sapling
spend signatures. Therefore hardware TEX sends and hardware transparent
shielding still use the full-PCZT signer response until the Keystone batch
protocol gains transparent signatures. Normal sends and ZEC swap deposits must
not fall back to the full-PCZT response.

One batch round can return at most 96 spend signatures, and one PCZT cannot be
split across rounds. `prepare_pczt_for_keystone_batch` therefore rejects a
transaction requiring more than 96 signatures before the request QR is shown.
Callers surface an actionable smaller-amount message and must not fall back to
the full-PCZT response.

**Critical invariants** (each of these was a real bug at some point in
development; breaking them is a correctness or data-loss regression):

1. **The hardware completion path must broadcast before it persists.**
   The function order is: `TransactionExtractor::extract()` (in-memory, no
   DB) → `send_transaction` gRPC → *only then* `extract_and_store_transaction_from_pczt`.
   Storing first would mark notes spent by a transaction no server holds.
   Once the server has the whole transaction, a nonzero `SendResponse` is no
   proof it was dropped: Zebra and Zakura re-queue rejected transactions for
   later blocks. A rejected transaction is stored like an unknown result, so
   its inputs stay spent until its expiry height; for a TEX payment round,
   sync keeps resubmitting it after the funding round. A transaction without
   an expiry height still fails outright, and
   so does a rejected TEX first round: it pays only the wallet's ephemeral
   address, and keeping it would drop the signed payment round.

2. **Local storage failure after a successful broadcast must not surface
   as a send failure.** The primary store path is
   `extract_and_store_transaction_from_pczt` (preserves rich PCZT
   recipient/memo metadata). On failure, fall back to
   `decrypt_and_store_transaction` — the same path sync uses when it
   discovers one of our sent txs on-chain. Correctness is preserved
   (spent notes get marked spent via nullifier matching) at the cost of
   some PCZT-only display metadata. Only if both paths fail do we
   return an error, and the error message must tell the user the tx is
   on the network and not to retry.

3. **Sapling params must be passed to BOTH `add_proofs_to_pczt` AND
   the hardware completion path whenever the PCZT contains a Sapling
   bundle.** `add_proofs_to_pczt` needs `LocalTxProver` to build Sapling
   output proofs; the completion path needs `LocalTxProver
   ::verifying_keys()` (a) to validate the extracted transaction and
   (b) to let `extract_and_store_transaction_from_pczt` store it. Both
   functions share the `Option<&str>` / `Option<&str>` signature. If
   the caller supplied paths to `add_proofs_to_pczt` but passed `None`
   here, extraction bails with `SaplingRequired` and the user sees a
   cryptic error after already downloading 50MB of params and
   approving on the device. `send_screen.dart` threads the same
   `proposal.needsSaplingParams ? spendPath : null` into both FFI
   calls — keep it that way.

4. **`PROPOSAL_STORE` is consume-on-entry for both execute paths, plus
   explicit discard on cancel.**
   - `create_pczt_from_proposal` and `execute_proposal` both call
     `.remove()` at the top (dropping the store lock before any DB
     work). A second call with the same `proposal_id` returns
     `"Proposal not found (expired or already consumed)"`.
   - Dart `_send()` runs the whole flow inside a `try/finally`
     with a `proposalConsumed` flag that flips to true immediately
     after the consume call. The `finally` block calls
     `discardProposal(proposalId)` when the flag is still false —
     this covers confirmation-dialog cancel, Sapling-params-dialog
     cancel, exceptions during Sapling download, and any error
     before the consume call. `discardProposal` is idempotent.
   - If you add a new entry point that reads a stored proposal,
     follow the same "consume on entry, idempotent discard on any
     non-consuming exit" pattern. Silently reading without
     consuming (`.get()`) reintroduces the memory-leak /
     replayable-ID bugs that a prior revision of this branch had.

The Dart flow in `lib/src/features/send/screens/send_screen.dart`
implements this pipeline end-to-end; the Rust side lives in
`rust/src/wallet/sync/pczt.rs::{create_pczt_from_proposal,
add_proofs_to_pczt, prepare_pczt_for_keystone_batch,
store_and_broadcast_pczts_with_compact_signatures_for_proposal,
discard_proposal}` with FRB wrappers in `rust/src/api/sync.rs`.

**Transparent inputs under Private queries.** Every hardware broadcast path
(Ledger outbox, Keystone compact and full batches, legacy PCZT) re-checks its
transparent inputs just before `SendTransaction`
(`rust/src/wallet/sync/hardware_authority.rs`). Under a private policy the
check targets the wallet's own tip + 1, so a block that lands while the device
signs does not refuse the signature. Until private recovery covers the
wallet's latest scanned block the refusal is `CatchingUp`; the broadcast waits
up to 30 s (`CATCH_UP_WAIT`) for it, and a busy wallet DB is waited out the
same way. If it still cannot dispatch, the refusal is retryable and the caller
keeps the signed transaction rather than releasing it. Under Private queries,
Ledger accounts recover privately from their stored birthday like other
accounts (`docs/ledger/transparent-recovery.md`). A birthday later than the
account's first activity can omit earlier transparent history; existing public
records that private recovery cannot explain block activation, and turning
the setting off restores public discovery from height 0.

### Wallet Creation

`create_wallet()` fetches chain tip from lightwalletd as birthday height before creating the account. This prevents new wallets from doing a full chain scan. Birthday fetch failure blocks wallet creation (network required).

On mainnet, the wallet API (`rust/src/api/wallet.rs`, `restored_birthday`)
stores every restored birthday rounded down to one past a grid point
(`tree_states::restore_birthday`), so lightwalletd learns only the bucket. The
grid is every 10,000 blocks before NU7 and every 30,000 from it, about 8.7 days
in both eras, and the bucket containing the activation starts at the last grid
point before it. It is a height grid, not a calendar, so every app version
draws the same buckets.
When the grid point is a compiled checkpoint (`rust/src/wallet/tree_states.rs`)
the first scan batch reads its state locally instead of sending
`GetTreeState`; a restore newer than the table fetches the grid point's state.
Restores are the discovery import
(`import_software_wallet_with_account_discovery`), wallet-link import
(`import_software_account_at_index`), and hardware import
(`import_hardware_account`). Newly created accounts (`create_wallet`,
`add_account`, and `import_wallet` from onboarding's reveal-then-confirm
flow), payment-link claims (`import_wallet`), and Gift Card observers keep the
exact height; testnet and regtest are unchanged. Code that queries lightwalletd from a restored birthday must use the
rounded value, never the exact requested height. The weekly
`update-mainnet-chain-tables.yml` workflow appends checkpoints.

### Rust API Design Constraint

FRB codegen works best with simple types. Keep the `rust/src/api/` surface limited to primitives, `String`, and flat structs. Do all complex Zcash type manipulation inside `rust/src/wallet/` and return simple results through `rust/src/api/`.

All per-account API functions take `account_uuid: String`. Sync-level operations (`start_full_sync`, etc.) operate on all accounts and do NOT take account_uuid.

### Key Security Model

`zcash_client_sqlite` intentionally does NOT store spending keys in the DB — only viewing keys (UFVK).

**Software accounts**: the mnemonic/seed lives in Flutter's `flutter_secure_storage` (iOS Keychain / Android Keystore) per-account (`zcash_account_mnemonic_{uuid}`) and is passed to Rust only when needed for transaction signing. Seed is scoped in a block and dropped before network I/O (broadcast).

**Hardware (Keystone) accounts**: no seed ever reaches the phone. On import the phone receives only the UFVK via QR/UR; the USK stays on the device. There is no corresponding `zcash_account_mnemonic_{uuid}` entry, and `getActiveMnemonic()` returns null for hardware accounts. Transaction signing happens inside the device via the PCZT handoff (see "Hardware Wallet (Keystone) Send Flow"), so the phone never holds spending key material for these accounts at any point.

### WalletDb Initialization

`WalletDb::for_path()` requires 4 params: `(path, Network, SystemClock, OsRng)`. `init_wallet_db()` must be called before `create_account()` — it runs schema migrations.

Seed-relevance rule:
- **Software bootstrap account**: `init_db_and_create_account` calls `init_wallet_db(Some(seed))` then `create_account` → `AccountSource::Derived`. This pins the seed fingerprint so future seed-requiring migrations can verify relevance.
- **Subsequent opens**: `ensure_db_initialized` calls `init_wallet_db(None)`. Calling `init_wallet_db(Some(other_seed))` after the first account would fail the relevance check when any `Imported` account exists.
- **Hardware-first bootstrap is allowed**: `import_hardware_account` initializes without a local seed and imports the Keystone UFVK. This can produce an `Imported`-only DB, so seed-requiring migration recovery must be handled at the product layer if such a migration appears.

### Desktop Window Bootstrap

Desktop window appearance is managed by the external [`desktop_window_bootstrap`](https://github.com/chainapsis/desktop_window_bootstrap) package plus `window_manager`, with a strict responsibility split:

- `desktop_window_bootstrap` owns window appearance and titlebar overlap handling.
  - On macOS this means the transparent titlebar / full-size content-view shell is applied natively before the window is shown, via `macos/Runner/MainFlutterWindow.swift`.
  - The app calls `DesktopWindowBootstrap.initialize()` in `lib/main.dart` after `initializeDesktopWindow()` has created the OS window but before `showDesktopWindow()` reveals it.
  - `DesktopWindowTitlebarSafeArea` in `lib/app.dart` pads Flutter content below the macOS traffic-light/titlebar area. Keep it wrapped around the app root.
- `window_manager` owns sizing/lifecycle only.
  - `lib/src/core/layout/app_layout.dart` should remain responsible for initial size, minimum size, aspect ratio, `show()`, `focus()`, and layout-mode reconciliation from window events.
  - Do not reintroduce `TitleBarStyle` ownership or other appearance writes through `window_manager`; that overlaps with `desktop_window_bootstrap`.

Current startup order for desktop platforms:

```text
WidgetsFlutterBinding.ensureInitialized()
→ RustLib.init()
→ initializeDesktopWindow()      // window_manager creates the OS window
→ DesktopWindowBootstrap.initialize()
→ showDesktopWindow()
→ runApp()
```

### Figma comparison tooling

For deterministic code-to-Figma screenshots, use the widget-test capture as
the normal iteration path. It renders the same `FigmaCompareApp` and registered
scenario without building Rust, CocoaPods, Xcode, or a macOS app:

```bash
scripts/figma-compare.sh widget --scenario pay-recipient --theme dark
```

Use the native entry point only for final macOS window-shell and restoration
verification:

```bash
scripts/figma-compare.sh native --scenario pay-recipient --theme dark
```

Registered states live in
`lib/figma_compare/figma_compare_scenarios.dart` and must use deterministic
dev-only mocks. Outputs go below the app sandbox's `vizor-figma-compare`
temporary directory: `content.widget.png` is the fast app-content reference;
`content.png` and `content.window.png` are the real-engine and native-window
final evidence. The native entry point reuses production macOS window
initialization without starting Rust, storage, sync, wallet, or network state,
automatically restores a minimized window before capture, and returns it and
the previously foreground app to their original states afterward. Full
workflow, mobile capture, and cleanup rules are in `FIGMA-AI-FIX.md`.

Important desktop design rule:

- The shell is opaque and true black, with no acrylic: the native window
  (`DesktopWindowVisualStyle.opaque`) and Flutter's root (`macosUtility.window`)
  are the neon look's black, and the Mac window opens in the dark appearance
  so nothing light shows before the first frame.
- Screens leave `Scaffold.backgroundColor: Colors.transparent` over that black
  and paint solid fills only where the UI should actually be solid.

## Mobile UI Standards

Follow these whenever you build or change mobile UI, and especially when there
is no Figma design for it. They record decisions already made for the app, so
a screen that follows them looks and behaves like the rest. When you add a
reusable mobile component or settle a new visual rule, add it here in the same
change. The subsections below this list carry the detailed rules.

These are upstream's rules for its Figma mobile design. On Veylor's mobile
the neon look above wins where they disagree: colour, type weight (no
Book or heavier; shared components take `AppFontWeight`), shapes, the tab bar,
art and page titles. The shared components and the behaviour rules still
apply.

**Start from the shared pieces.** Don't rebuild a private copy of any of these:

- Page route: `_mobilePage` in `mobile_routes.dart` (`MobilePage` plus
  `MobilePageViewport`).
- Page header: `MobileTopNav.back`.
- Sheet: `showAppMobileSheet` with a `MobileModalScaffold` body. A flow
  with steps of its own (type an amount, then hand over a result) is a page
  instead, like Pay and Request ZEC: `MobileTopNav.back` over the step, its
  buttons docked at `kMobileFooterGap`, Back returning a step at a time.
- Card surface: `MobileSurfaceCard`. Titled list group: `MobileSection` with
  `MobileSectionRows` and `MobileListRow`.
- Single choice: `MobileRadioCard`. An option that starts an action:
  `MobileActionCard`.
- Floating bottom button: `MobileStickyBottomAction`. A list page's add
  action (Accounts' Add account, Contacts' Add contact) is this button, not
  a top-right "+".
- A two-way choice on a page (Receive's pools, the viewing key's QR code and
  Text): `AppSegmentedControl` set up as on Receive, 320 by 44, 20px icons,
  `labelLarge` w500, the selected pill `background.inverse`.
- Whose page it is (the viewing key choice, the secret passphrase):
  `MobileAccountHeader` with `mobileAccountHeaderBalance`. It shows the
  account's `AppProfilePicture` (`xLarge`) above its name in `bodyLarge` w600
  `text.accent`, then its balance in `bodyLarge` `text.secondary` (masked in
  privacy mode; left out when unknown), centered, 32 above the content. On
  the secret passphrase it is optional, a proposal rather than a
  requirement: it signals that the words are this wallet's master key, so
  the user treats the screen with care. Removing it there is acceptable.
- Success, pending and failure screen: `MobileTransactionProgressScreen`.
- Typing an amount: `MobileAmountCard`, Pay's card (its header row holds
  Pay's asset picker; Request ZEC leaves it out and the amount centres in
  the same minimum 240 height). Its amount/conversion rows and header grow with
  scaled text; narrow Pay headers and actions reflow before labels are clipped.
  Adding a message (memo):
  `showMobileMemoSheet`, Send's sheet, opened from a line under the card;
  pass a title, hint and `sanitize` for a flow with its own rules.
  Memo labels, errors and buttons grow with text; the input keeps an internal
  scroll view. Its scrollbar has a 24px hit area and a 6px visible thumb.
- Buttons `AppButton`, icons `AppIcon(AppIcons.x)`, toasts `showAppToast`,
  haptics `AppHaptics`.

**Layout and spacing**

- Spacing comes from `AppSpacing` (4, 8, 12, 16, 24, 32, 48, 64) and radii
  from `AppRadii` (8, 12, 16, 24, 32). Don't write a literal where a token
  exists.
- Pages use `kMobilePageMargin` (20) at the sides. Sheets, card insides,
  toasts and the tab bar keep 16.
- 12 between stacked buttons and between stacked cards, 24 between sections,
  24 from a sheet's body to its buttons.
- Bottom buttons sit `kMobileFooterGap` above the safe-area inset (see
  "Mobile Page Footers").
- Rows and labels that hold text take a minimum height, never a fixed one, so
  large text grows instead of clipping.
- A page with a fixed layout (Receive) fits a 393×852 screen without
  scrolling. Receive keeps its QR at 228 for that, still easy for a camera;
  check the fit there before growing anything on such a page.

**Pages**

- Register every pushed screen through `_mobilePage`. It gives the window
  background, the side constraints, the scroll edge fades, the fade-and-zoom
  entrance (320ms, `Cubic(0.23, 1, 0.32, 1)`), the edge-swipe back and the page
  haptic. Button Back slides out over 400ms, restoring the previous page from
  1.03 scale to 1 with the same progress; a back swipe follows the finger and
  settles over 350ms. Both exits keep the page opaque and at full size, so the
  page below shows beside it. Under Reduce Motion button Back only fades.
  A pop during entry reverses that entry without jumping to a slide. A route
  outside it (onboarding, the Gift Card claim) installs
  `MobileScrollEdgeFades(color: window, bottomHeight: AppSpacing.xl)` itself.
- Onboarding steps enter instantly: `_mobileOnboardingPage` uses
  `MobilePageTransition.onboarding`. Back slides out over 400ms (fades under
  Reduce Motion); a back swipe stays opaque and follows the finger, then
  completes or cancels over 350ms. The previous page stays still. Keep entry
  duration zero and use the shared policy rather than per-screen transitions.
  Unlock, tab roots and the wallet root shell retain `NoTransitionPage`.
- Every step with a progress bar uses `MobileTopNav.steps` with its default
  geometry (`kMobileTopNavHeight`, no `progressOffset`, the default track
  color), directly under the safe area. Don't give one step its own height,
  offset or track, or the bar jumps between pages.
- An onboarding step that shows the citadel art passes
  `MobileOnboardingCitadelBackground` as the scaffold's `background`, the
  unlock screen's asset; the step then scrolls without edge fades.
- Inner pages keep `MobileTopNav.back`'s default `headlineSmall` title. Only
  the four tab roots (Home, Swap, Activity, Settings) pass
  `AppTypography.headlineLarge`, the serif. Don't pass `titleStyle` on an
  inner page.
- The four tab roots share one top: the nav (`kMobileTopNavHeight`) right at
  the safe-area top, nothing above it, and the first card `AppSpacing.s`
  under it. Switching tabs then moves neither the header nor the first card.

**Scrolling and fades**

- Every vertical scroll view under a page or sheet fades its cut edges by
  itself (`MobileScrollEdgeFades`); one that fits shows none. Don't add a
  private fade and don't clip rows flat.
- The fades paint the surface color. Where an image or gradient sits behind
  the scroll view (the castle engraving on records and success screens), wrap
  that body in `MobileScrollEdgeFades.off`.
- A scroll area that needs a taller, tuned fade (tab roots, a list under a
  floating button) uses `MobileTabRootScrollFades`, `MobileTopScrollFade` or
  `MobileBottomScrollFade`; each turns the standard edge off below it.
- Content that scrolls under a floating button gets its bottom padding from
  `MobileStickyBottomAction.contentInset`.

**Sheets**

- `MobileModalScaffold` is the one template: a `bodyLarge` w600 `text.accent`
  title, the shared close button, 32 top, 16 sides, 16 from title to body, 24
  bottom. Don't override its paddings without a stated reason.
- The scaffold scrolls a body taller than the room left (keyboard, large
  text). Pass `constrainBody: true` only for a body that brings its own
  scroll view.
- A field focused on open calls `focusWhenMobileSheetOpens` from a post-frame
  callback instead of `autofocus`, so the keyboard waits for the sheet.
- One decision per sheet. A setting with options shows as a Settings-style
  row (label left, the current value and a chevron right) that opens its own
  sheet one level down; there a tap marks an option and one primary Update
  applies it. Adding or editing an item (a custom source or server) opens a
  further sheet, so no sheet mixes a list with a form. Vote config is the
  example (`mobile_voting_config_settings_sheet.dart`).

**Surfaces, cards and lists**

- Cards are `MobileSurfaceCard`: ground fill with the `mobileSurfaceShadows`
  lift and no stroke. Borders mark structure (hairlines, a selected choice,
  inputs), never elevation.
- A titled group is a `MobileSection`: a 16px `text.secondary` label, 12
  above the card, sections 24 apart, rows split by `MobileSectionDivider`
  (0.5px `border.subtle`).
- Row icons are `icon.accent`; trailing chevrons are `icon.muted`.
- A list that runs longer than a screenful of choices (networks, tokens) gets
  a search field at its top, the Contacts search field or the Swap asset
  picker's, filtering on name and ticker, with the list holding its height
  while it filters and a "No … found" line when nothing matches.

**Typography**

- Mobile text is at least 16px: use `labelLarge`, `bodyMedium` and
  `codeMedium` at mobile call sites. The 13 and 14px tokens are for desktop or
  for spots with no room (seed-word grids, badges).
- Readable secondary text is `text.secondary`. `text.muted` fails 4.5:1, so
  keep it for disabled or decorative text.
- Amounts, balances and list dates use tabular figures (`withTabularFigures`).
- A page's hero amount is Young Serif at the Send amount's size (48, its
  ticker 38) inside `FittedBox(fit: BoxFit.scaleDown)`, so a long amount
  shrinks to fit between the page margins instead of clipping or wrapping.
- An amount shown with its QR (Request ZEC's result) uses the Home balance
  card's serif (`kMobileSerifAmountStyle`, its ticker
  `kMobileSerifTickerStyle`) with the `PoolBadge` under it, and the QR,
  amount and badge sit centred together between the header and the buttons.
- A large serif amount that privacy mode masks (Home's balance, a record's
  hero amount) builds its span with `serifPrivacyMaskSpan`: Young Serif sets
  the bullet a digit wide, and the helper pulls the dots to about half a dot
  apart.
- Copy follows "UI Copy Conventions" (sentence case, the glossary).

**Transaction records**

- The top shows only the type icon in liquid metal (a Gift Card shows its
  card art, without the amount), then the hero amount and its dollar value.
- Everything else is a row of the detail card, the status first, in the
  card's two columns: a `text.secondary` label and its value on the right.
- The castle engraving sits behind the record and the status screens in both
  themes; the art is a translucent grey that reads on light and dark.

**Color, icons and amounts**

- Colors come from `context.colors` tokens; no hex values in feature code.
- A shielded pool is the filled shield (`AppIcons.shieldKeyhole`); there is
  no outline version.
- An icon cast in liquid metal (a record's hero, the onboarding intro's
  shield) is `LiquidMetal` over `SvgShapeImage('assets/icons/<name>.svg')`
  with a transparent `colorBack`, `softness: 1` and `scale: 1`, as
  `TransactionTypeHero` sets it, wrapped in `ExcludeSemantics`.
- A line that names an address's or a payment's pool is `PoolBadge`: the
  crimson shield (or the muted transparent glyph) and "Shielded" or
  "Transparent" in `text.secondary`, on mobile drawn exactly as the activity
  rows draw it: the 16px regular label and the `icon.brandCrimson` /
  `icon.muted` glyph colors (the text crimson is a lighter pink in dark mode).
  Don't tint the word itself or pair it with another icon color.
- A value that opens or expands (a message) shows `AppIcons.expand`, the
  vertical chevrons. The up-down arrows (`AppIcons.doubleArrowVertical`)
  only switch units, such as ZEC and dollars.
- A viewing key is the eye (`AppIcons.eye`): the full key, the Settings row
  and "Show viewing key". The incoming-only key is the receive arrow
  (`AppIcons.arrowDownCircle`). Request ZEC is the speech bubble with the Z
  (`AppIcons.request`), not the link icon.
- Received amounts show "+", sent amounts no sign, both in the row's accent
  tone. Amounts follow privacy mode (`docs/privacy-mode.md`).

**Controls**

- `AppButton`: one primary (black accent) action per view, secondary for
  alternatives, ghost for Cancel; full width (`expand: true`) at the bottom of
  a page. Disabled buttons are solid (`button.disabled`), so a floating button
  never shows content through it.
- Toggles have no outline: the off track is `background.overlay` and the thumb
  carries `appSurfaceShadow`.
- Every custom tap target is wrapped in `Semantics(button: true, label: ...)`
  and is at least 24pt.
- A copy confirms with a toast (`showAppToast`, "... copied"; a failure uses
  the destructive tone), not by changing the button's label.
- Menu items that reveal a secret say "Show ...": "Show secret phrase",
  "Show viewing key".
- A Settings on/off setting is a card like Keep screen awake and Flip to hide:
  a `MobileSection` title, a row with its icon, label and the shared
  `_SettingsToggle`, and a `bodyMedium` `text.secondary` explanation under it.
  The switch ticks `selection()` as it flips, and a failed save shows a toast.
- The Flutter fallback tab bar (`AppMobileTabBar`) has 52 by 72 items in a
  60-high bar (`kMobileTabBarHeight`), hugging its tabs, with 24px icons. Code that
  clears it reads `kMobileTabBarHeight` or
  `MobileNavigationScope.bottomClearanceOf`, never a literal.
  Its horizontal bar previews the touched tab over 100ms, adding finger travel
  during that arrival; navigation commits only on tap/drag release. Cancel
  restores the actual selection. Keep the first pointer in control, one haptic
  per selection boundary, and instant arrivals under Reduce Motion. The vertical
  bar retains its selected-tab drag origin.
  Raw drag recognizers inherit `MediaQuery` gesture settings and require the
  horizontal threshold before accepting a drag. A tab's tap rejection only
  releases its icon press; it must not discard a pending drag preview. Cover
  device touch slop and diagonal movement in gesture regressions.
- iOS 26+ uses the native Liquid Glass tab bar when available. Preserve the
  native root host, registration and `nativeBar` precedence in `AppMobileShell`.
  UIKit owns its sizing, safe area, selection lens, motion and press haptics;
  Flutter fallback metrics, icon flourishes and surrounding touch blocker do
  not wrap the native lane. See `docs/ios-native-tab-bar.md`.
- A host that toasts from any wallet page (flip to hide) sits in the wallet's
  root shell route (`buildMobileRoutes`), so its toast shows in the root
  overlay. Mounted above the router it would draw into the tab shell's toast
  host, under any pushed page.

**Motion**

- Gate every animation on `MediaQuery.disableAnimationsOf(context)`; iOS
  Reduce Motion reaches it through `PlatformReduceMotionScope`. Under reduced
  motion keep fades and drop movement, scale and rotation.
- Curves: `Cubic(0.23, 1, 0.32, 1)` for entrances, `Cubic(0.77, 0, 0.175, 1)`
  for movement on screen, `Cubic(0.32, 0.72, 0, 1)` for iOS-style sheets and
  pagers.
- Keep interaction motion short (pages 320ms in and 400ms out, toasts 350ms in
  and 200ms out, sheets about 200ms). Longer motion is for one-off moments
  only, such as the tab icon flourishes and the 1,950ms success ripple. Frequent actions
  (typing, row taps) don't animate.
- Passcode keys fire on touch and dim to 50% while held: at once on the
  touch, fading back over 150ms on release (`_PasscodeKey` in
  `passcode_widgets.dart`). The fade never delays the next digit.

**Haptics**

- Use `AppHaptics`, not `HapticFeedback`:
  - `action()` on a button that starts a flow, before the push. Routes play
    `pageTransition()` themselves.
  - `selection()` the moment a toggle, radio or segmented control flips, not
    after its save finishes. `AppSegmentedControl` ticks it on a tap itself;
    a pager that switches the same choice by swipe (Receive's pools) ticks
    it on its page change, so each switch ticks once.
  - `tabSwitch()` (medium) for the Flutter fallback tab bar, `copy()`, and
    `error()` for a rejected passcode.
  - `sendSuccess()` or `sendFailure()` once, when a transaction's outcome
    arrives while its screen is open.

**Check a new mobile screen**

- Add a deterministic capture scenario (`figma_compare_scenarios.dart`,
  ideally from a Widgetbook use case) and look at it in light and dark:
  `scripts/figma-compare.sh widget --form-factor mobile --scenario <id>
  --theme <light|dark>`.
- Tag its tests `mobile` and compare against tokens, not literal numbers.

### Mobile Bottom Safe Area (iOS proportional padding)

Mobile bottom-sheet bodies and the floating tab bar wrap their bottom
edge in `MobileBottomSafeArea`
(`lib/src/core/layout/mobile/mobile_bottom_safe_area.dart`), not raw
`SafeArea(top: false)`.

- The rule: on iOS, when the wrapped content's own bottom padding is
  `kIosHomeIndicatorClearance` (16) or more, the bottom safe-area inset
  is skipped so the bottom gap equals the side padding. Android always
  honors the inset — navigation-bar modes vary per device.
- Why: the iOS home indicator is an overlay occupying only the bottom
  ~13pt of the screen (8pt offset + 5pt bar), so it floats inside 16px
  of empty padding; stacking the 34pt inset on top of that padding
  makes the bottom gap visually heavier than the sides.
- `bottomPadding` must equal the bottom padding the wrapped content
  actually provides below its last control — when changing a sheet's
  padding token, update the argument with it.
- Tab bar (`AppMobileShell`): the gap below the bar is 16 on iOS
  (matching its 16px side margins) and the Figma 12 + inset on Android.
- Keyboard avoidance is unaffected — `viewInsets` is a separate channel
  from the `viewPadding` this consumes.
- Platform branching uses `defaultTargetPlatform` (overridable in
  widget tests), not `dart:io` `Platform` checks.
- New sheets follow `MobileBottomSafeArea(bottomPadding: token)` >
  `Padding(...)`; both platform geometries are pinned in
  `test/core/layout/mobile/mobile_bottom_safe_area_test.dart`.

### Mobile Page Footers

Every mobile page's bottom buttons sit `kMobileFooterGap` (12) above the
bottom safe-area inset: 46pt from the bottom edge on a current iPhone, the
Send flow's distance. The token lives in
`lib/src/core/layout/mobile/mobile_sticky_bottom_action.dart`.

- A footer docked under a page's scroll view, in a bottom `SafeArea`, pads
  its buttons' bottom by `kMobileFooterGap`.
- A button floating over the scroll view uses `MobileStickyBottomAction`
  (its `bottomOffset` adds the inset, which drops to the gap above a raised
  keyboard).
- A page body wrapped in `MobileBottomSafeArea` passes
  `bottomPadding: kMobileFooterGap`; that is under the iOS clearance, so the
  inset always applies and the page matches the others. The iOS
  proportional rule above stays for sheets and the tab bar only.

### Mobile Sheets and the Keyboard

Mobile sheets are root-navigator routes, and a text field in one raises the
keyboard over the whole window. Keep a keyboard animation from rebuilding or
laying out more than the sheet itself:

- Routes beneath a sheet hold still. `CoveredRouteKeyboardHold`
  (`lib/src/core/layout/mobile/covered_route_keyboard_hold.dart`) wraps every
  `MobilePage` and the wallet shell route: a covered route whose keyboard was
  down sees none until the keyboard rises for it again. Wrap any new
  root-level page type the same way.
- Sheet bodies sized to the room above the keyboard use
  `MobileKeyboardAwareHeight` instead of reading `MediaQuery` in their own
  build. Only its builder runs per keyboard frame; pass the body as `child`.
- Elsewhere, read the narrow lookups (`MediaQuery.viewInsetsOf`,
  `sizeOf`, `paddingOf`) rather than `MediaQuery.of`, and keep any
  `MediaQuery.of` read out of the app-root `builder`.

### Mobile Cards

Mobile option and action cards share one surface, `MobileSurfaceCard`
(ground fill with `mobileSurfaceShadows`, no stroke). Build new ones from
the shared components in `lib/src/core/widgets/mobile/` instead of a
private copy:

- `MobileRadioCard` — one choice in a single-choice list (Figma `Radio
  Card`): optional icon, title, detail lines or a description paragraph, a
  badge beside the title, action buttons before the trailing round check,
  and a dimmed disabled state. Only the selected card carries the 2px strong
  stroke. Stack them 12px apart.
- `MobileActionCard` — a card that starts an action: round badge in the
  primary button's colours, title, description (the Home Receive sheet).

## Private USD

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
Windows has no host and hides it. Desktop Home's recent activity and
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
  `RailgunError`), with `macos/Runner/PrivateUsdAttestationHandler.swift`,
  `ScreenAwakeChannel.swift` and `MacSessionLifecycle.swift`. Keep the shared
  four free of UIKit and Flutter imports.
- C++ (Linux): `linux/runner/private_usd/` (Veylor's side: the channels, the
  page's link, the session lifecycle, keep-awake and the settlement reminder)
  and `linux/runner/railgun_page/` (`veylor-railgun-page`, the page process:
  WebKitGTK loaded at run time, the page, the archive fetch and the hosts);
  `scripts/package-linux-deb.sh` makes the .deb with its AppArmor profile.
- The Railgun page: `android/app/src/main/assets/railgun/`, built from
  `android/railgun-web/`; the same build copies it as is to
  `ios/Runner/Railgun/railgun/`, which the macOS target references as a folder
  and the Linux build installs into the bundle's `data/railgun` (no third
  copy).
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
  another RPC; a connection that is down is never put on the RPC.
- `VIZOR_PRIVATE_USD_FLAG_URL` is the kill switch. Only an explicit `false`
  hides the feature. A missing key or a failed fetch keeps the last value,
  which defaults to available. Even `false` never stops conversions already
  under way.
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
- Lock cancels the step, closes the page and drops Dart-held secrets.
- Screen-off means background, so while unlocked the screen stays on
  through a bridge with a key step to come, whichever screen shows (not
  once the relayer holds the claim), and through a Railgun first sync
  (`privateUsdKeepAwakeProvider`, through `SyncKeepAwakeNativeHost`'s one
  native flag, foreground only). A bridge's progress says so in a card that
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
  one (D14).
- Hardware accounts, accounts without ZIP-32 metadata, and regtest hide the
  feature.
- **On the Mac** the foreground is a shown window, focused or not. A
  minimised or hidden window, a hidden app or a window fully covered by others
  is `AppLifecycleState.hidden` (the engine's occlusion), and so are a locked
  screen, displays asleep, a Mac going to sleep and another user's session in
  front (`MacSessionLifecycle` says so on `flutter/lifecycle`, and once nothing
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
  Mac say "your computer" on Linux (`privateUsd…Linux`,
  `privateUsdLinuxWording`).

**Separate databases.** Rust owns both, in
`<support>/private_usd_<walletDbName>_<network>/` (`getPrivateUsdDirPath`):

- `swaps.db` holds the swap index counters, the swap records, the
  joint-account index and the Railgun send log. Records decode strictly: an
  unreadable record is an error, never a reset.
- `joint.db` is a librustzcash DB for the short-lived joint accounts.

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

**Invariants (plan §3.5).** Each one guards funds or privacy. Keep them, and
keep the tests that pin them, in `rust/src/wallet/private_usd/tests/` and
`test/features/private_usd/`.

- Commit `next_index + 1` before any quote leaves the device, under the
  seed and ZIP-32 index the keys derive from (never the account UUID, which
  a re-import changes), and never reuse a swap index (a shared `z` hands
  that swap to its maker).
- Save the record before accept, and treat an accept that timed out or
  failed in transport as maybe opened.
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
  time and closes by the later of it and the device clock. A forward claim
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
- Never prove a second reverse funding because a response was lost. Sign
  `ready` only before `t0` (its deadline, the head plus 120 s, before it),
  keep that deadline first, and never sign or send one once a refund was
  posted. Never re-sign `ready` after a restart; resend it.
- Keep every signed payout, refund payout, `ready` and Railgun send proof
  before posting it, and a claim or refund as posted, or a claim as handed
  over, before it goes. Cap every relayer fee at 2 USDC.
- Joint sweeps broadcast before they store. `PROPOSAL_STORE` is
  consume-on-entry with an idempotent discard, as in the hardware invariants.
- Joint sweeps use Discard OVK, while the deposit uses the sender's OVK.
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

**Privacy Pass tokens (plan M4, reference §5.9).** A maker that takes
tokens answers an unpaid accept `401` with a `WWW-Authenticate` challenge;
the client is built and dormant until a maker does, so no app release is
needed then. Code: `rust/src/wallet/private_usd/tokens.rs`, the Kotlin
`PrivateUsdAttestationHandler` (channel
`com.zcash.wallet/private_usd_attestation`; its Swift twins, iOS's and
the Mac's, answer `unavailable`), Dart `services/private_usd_tokens_service.dart` and
`private_usd_attestation.dart`.

- **What is stored where.** The device-wide state is one file per network,
  `<support>/private_usd_tokens_<network>.json`
  (`getPrivateUsdTokenStorePath`), written atomically and read leniently:
  the tokens held, the requests for tokens back (with the swap and its
  direction), the last challenge a maker sent, the day the issuer ran out,
  and whether the maker asks. Never per account. A full reset deletes it;
  the Keystore attestation key (`vizor_privateusd_attest_<issuerName>`) is
  never deleted and is remade only once a certificate in its chain expired:
  a new key would be a fresh allowance (X4). Every secret in the file is
  `Redacted`; log nothing but status codes.
- **The pins.** Only the deployment's issuer name, token key and the
  maker's return key are honoured (`TokenPins`): a challenge naming others,
  or a day outside today ± 600 s, is `TokensRefused`, and `/v1/info` with
  another return key refuses the maker at the quote.
- **The 401 rule.** An accept posts unpaid first; with tokens on, a `401`
  is answered before the quote is taken, so re-posting is safe. With a
  token held it posts again with `Authorization: PrivateToken` and the
  body's `tokenRequest` (only on a paid post; never on an unpaid one, and
  never kept on a reverse record), at most 3 paid tries, settling each by
  its answer: `2xx` and `401` drop the token, `401` its pending return too,
  anything else or no answer keeps the token first in line. Issuer tokens
  go before returned ones, which go only once today is spent. No token
  held is `TokensNeeded`: Dart runs the issuance once and accepts the same
  index again, else abandons.
- **Issuance (X11)** is two FRB phases around the keystore:
  `private_usd_tokens_issuance_begin` (the maker's `/v1/info` first, then
  `GET /v1/token-key` against the pins, the blinded batch, `GET
  /v1/challenge`, a 5-minute session) and `…_finish` (`POST /v1/tokens`,
  the first `403 rejected` signed again once over a fresh challenge, the
  second `TokensDeviceRefused`; `429` or a short batch mark today spent).
  Sessions die on finish, expiry and `private_usd_clear_sessions`.
- **The prefetch.** The maker's challenge is deterministic, so a batch is
  fetched ahead whenever its info shows the pinned return key: on the
  convert screen, after every conversion ends and from a resumed accept
  turned away at the gate. Without the return key nothing is asked of the
  issuer. Returns are collected on every step once the deposit is out (or
  the escrow funded) and during each prefetch pass.
- **Route.** Issuer requests go through `routed_http` like every other,
  over Tor when Tor is on; with Tor off the review screens disclose that
  the issuer and the maker see one connection.

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
  the end of each scan: a wrong one fails the scan, never a balance.
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
- **Anon's archive** (Android, the Mac and Linux, mainnet, Settings, on by
  default; `archive*.js`):
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
    to passes by then. A scan that broke before that check counts for
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
    headers). iOS starts the page without it. Every archive request depends
    on the chain's state alone. What every host must do:
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
  and Swift allowlists (`RailgunEndpoints`), Linux's (`kHosts`), the Rust
  bridge's allowlist and the page's CSP must agree; Rust tests in
  `railgun_bridge.rs` pin them, and Linux's events and methods to Kotlin's
  (CI's `pins` job in `veylor-linux.yml`).
  Its User-Agent is a fixed `Mozilla/5.0` (`RailgunRequests.USER_AGENT`),
  the archive fetch's too: the WebView's own names the phone's model and its
  Android build to every host the page reaches.
- On iOS a Swift `WKWebView` host behind the same channel serves the page
  from `veylor-railgun://app/`, in a data store of its own whose SOCKS5
  proxy is the bridge (no failover), with a `WKContentRuleList` allowlist
  (iOS reference §6). The macOS host is the same on AppKit (macOS 14 and
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
- The page's traffic leaves only through the Rust loopback SOCKS5 bridge
  (`railgun_bridge.rs`), which uses arti when Tor is on. Its direct
  connections try IPv6 and IPv4 side by side (hyper-util's connector, as
  every other direct path): a network that hands out IPv6 it cannot carry
  otherwise stalls the page on its first IPv6 address.
- The page downloads Railgun's circuit artifacts from ipfs-lb.com and falls
  back to our mirror (`android/railgun-web/src/artifact-mirror.js`); the
  mirror's tooling is in `scripts/private-usd/artifacts-mirror/`.
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
- Relayer tickets and token blinding secrets stay in `swaps.db` and the
  token state, and are never logged.
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
`zecswap-railgun` and `zecswap-tokens` from its `main` (PR #18), which use no
Zcash crate. Veylor hands zecswap-core PCZT bytes (`sign_pczt_bytes`), so it
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

## Testing

- Keep small Rust internal tests in the source file's `#[cfg(test)] mod tests`.
- When fixtures or scenarios obscure the implementation, split into `<module>/tests.rs`; do not split by line count alone.
- Put public-API integration tests in `rust/tests/`; do not widen production visibility for test placement.
- Rust unit tests: `cd rust && cargo test` — 11 tests covering key derivation, address encoding / Orchard-only UA derivation, determinism, and PROPOSAL_STORE lifecycle (idempotent discard, consume-on-entry, replay rejection). Tests that need a DB use `tempfile::tempdir()`.
- Dart unit tests: `fvm flutter test` (mobile-tagged tests auto-skip).
  Mobile-UI tests:
  `fvm flutter test --tags mobile --run-skipped --dart-define=VIZOR_FORM_FACTOR=mobile`.
  Lane rules in "Design Token Form Factor" above.
- Fonts: Gotham is the app's only Latin family. It is a plain asset (`assets/fonts/`),
  not a pubspec `fonts:` family: Flutter takes a face's weight from the font
  file, and these files' OS/2 weight classes are off the CSS scale, so
  `FontWeight.w400` would resolve to the Bold file. `loadGothamFonts()`
  (`lib/src/core/theme/gotham_fonts.dart`) rewrites the weights in memory and
  registers the family; `initializeZcashWalletRuntime`, Widgetbook and the
  Figma-compare entry points call it. A widget test that needs real glyphs
  instead of the square test font calls `loadGothamFonts()` too, never a
  hand-rolled `FontLoader` over the `Gotham-*.otf` files. Gotham has no
  SemiBold (`w600` resolves to Bold) and no monospace face. Desktop builds
  register no face heavier than Light (`gothamHeaviestWeight`), so every
  heavier weight renders Light there. Korean and Chinese
  text falls back to upstream's generated subsets, the pubspec families
  `Vizor Korean UI` and `Vizor Chinese UI` (`locale_typography.dart`). The mobile serif
  headline tokens are set below the Figma sizes for it (see `_headlineLMobile`).
- Integration tests: `fvm flutter test integration_test/` (requires device/simulator)
- Flutter regtest E2E notes:
  - Run app tests with `--dart-define=ZCASH_DEFAULT_NETWORK=regtest`; do not use the old `ZCASH_USE_E2E_STORAGE` path. Secure storage and wallet DB names are network-scoped.
  - Cleanup code should guard on `kZcashDefaultNetworkName == ZcashNetwork.regtest.name`, then delete `getWalletDbName()` plus its `-shm` / `-wal` files.
  - Use `ZCASH_E2E_LIGHTWALLETD_URL` only as the endpoint override, and keep Rust API calls on the same network as `kZcashDefaultNetworkName`.
  - Mempool receive E2E should use external zcashd/lightwalletd funding when testing true inbound tx discovery, not another in-app account.
  - To prove mempool behavior while sync is active, pre-mine enough regtest blocks and pass the debug-only Rust throttle env vars inline: `ZCASH_E2E_SYNC_BATCH_SIZE` and `ZCASH_E2E_SYNC_BATCH_DELAY_MS`.
- Mobile (iOS simulator) regtest E2E:
  - One-shot runner: `./scripts/e2e/flutter-ios-regtest-mobile-full.sh`; per-scenario runners are `scripts/e2e/flutter-ios-regtest-mobile-*.sh`. Same heaviness rule as desktop: do not run unless explicitly asked.
  - Tests live in `integration_test/regtest_mobile_*_test.dart` and share `integration_test/support/mobile_regtest_flow.dart` (pump/tap helpers, regtest-guarded cleanup, mobile flow primitives). Desktop regtest tests keep their per-file helpers; do not merge them.
  - Mobile runs need THREE defines: `VIZOR_FORM_FACTOR=mobile`, `ZCASH_DEFAULT_NETWORK=regtest`, `ZCASH_E2E_LIGHTWALLETD_URL` — `run_mobile_e2e` in `scripts/e2e/lib-mobile.sh` injects them. Gift Card scenarios need a fourth, `VIZOR_PAYMENT_LINK_REGTEST_ENABLED=true` (payment links stay gated off without it), plus `VIZOR_DEEPLINK_BASE_URL`; the runner passes both to `run_mobile_e2e` as extra defines rather than `run_mobile_e2e` injecting them.
  - Device selection: `SIMULATOR_UDID` env wins; otherwise the single booted simulator. The runner refuses to pick among multiple booted sims.
  - Each `flutter test integration_test` invocation reinstalls the app: the wallet DB dies with the container while the iOS Keychain persists until the reinstalled app's first launch clears it, so in-test `cleanupE2eWalletState()` (deleteAll + db files, regtest-guarded) runs at test start AND teardown. Cross-invocation wallet reuse needs `--no-uninstall`: the Ironwood restart runners pass it to their prepare phase so the resume phase reopens the same install. Gift Card scenarios pair it with `cleanupMobileE2ePaymentLinkClaimWallets()`, the regtest-guarded claim-wallet sweep — claim wallets from every network share one support directory, so the sweep is scoped to regtest names. Scenarios that leave the pasteboard populated clear it in teardown too; the simulator pasteboard outlives the app container.
  - The simulator shares the host loopback: `127.0.0.1` URLs, the in-test lightwalletd proxy, and the python E2E driver all work unchanged. Android emulators would need `10.0.2.2` and are out of scope.
  - Desktop scenarios without mobile counterparts (feature gaps, add when the features land): custom-endpoint privacy (no mobile endpoint settings UI), mempool during-sync / expiry variants.
  - Payment-request round trip and payment-URI locked-send: desktop runners only. The mobile receive pane has its own request sheet, so this is a harness gap rather than a feature gap.
  - Gift Card restart recovery and reorg retry: desktop runners only. The Gift Card round trip has a mobile counterpart driving the **Redeem a card → Paste card link** path; mobile claiming over a universal link still needs a publicly reachable HTTPS origin — see `scripts/e2e/README.md`. The payment-URI send also has a mobile counterpart, which instead pushes an `onUris` call over the `com.zcash.wallet/payment_uri` MethodChannel to raise the payment-request card.
- Zcash regtest Rust integration tests:
  - One-shot runner from repo root: `./run-regtest-rust-tests.sh`
  - The runner always starts by tearing down any existing regtest containers and resetting `.regtest/`, so each run starts from the same clean chain/wallet state.
  - The runner writes its terminal log to `.regtest-logs/regtest-rust-tests.log`, which is intentionally separate from `.regtest/` so the log survives the default final cleanup.
  - Sapling proving params are cached separately at `~/.zcash-params` by default, so they survive `scripts/regtest/reset.sh`. Override with `SAPLING_PARAMS_DIR=/custom/path ./run-regtest-rust-tests.sh` if needed.
  - By default the runner also does a final `down/reset` cleanup after the tests finish. Use `./run-regtest-rust-tests.sh --keep` if you want to keep the regtest state around for debugging.
  - These regtest scenarios are slow and heavy. Do not run them unless the user explicitly asks for regtest/integration execution.
  - Manual flow:
    - Start services: `./scripts/regtest/up.sh`
    - Run individual scenario tests: `cd rust && cargo test --test regtest_receive_sync -- --ignored --nocapture --test-threads=1`
    - Other available targets: `regtest_send`, `regtest_import`, `regtest_multi_account`
    - Stop services: `./scripts/regtest/down.sh`
  - The one-shot runner streams the full test output to the terminal and also saves a copy to `.regtest-logs/regtest-rust-tests.log`.
- `scripts/regtest/` utilities:
  - `up.sh` — starts the Dockerized `zcashd + lightwalletd` regtest stack, waits for both services to become ready, and ensures the faucet state exists.
  - `down.sh` — stops the regtest Docker compose stack.
  - `reset.sh` — destroys the regtest containers/volumes and clears `.regtest/` state, then recreates a clean local chain on the next `up.sh`.
  - `mine.sh <count>` — mines `<count>` new regtest blocks through `zcash-cli`.
  - `fund-wallet.sh <unified_address> <amount_zec> [confirmations]` — sends shielded funds from the local faucet to the given UA, then mines enough blocks for confirmation. Example: `./scripts/regtest/fund-wallet.sh <ua> 1.25 10`
  - `lib.sh` — shared helper functions used by the other regtest scripts; source it from scripts, do not run it directly.
- Regtest prerequisites:
  - Docker Desktop / `docker compose` must be available.
  - `grpcurl` is optional but recommended. If installed, the scripts use it to wait for `lightwalletd` gRPC readiness and chain-tip propagation; otherwise they fall back to a simpler TCP port check.
- Debug vs Release: Rust crypto is ~5-10x slower in debug (`opt-level=0`). Use `--release` for realistic sync performance.

## Crate Versions

Constrained in `rust/Cargo.toml` and resolved in `rust/Cargo.lock`. Key crates: `zcash_client_backend` 0.22.0, `zcash_client_sqlite` 0.20.2, `orchard` 0.13.1, `sapling-crypto` 0.7.0. These must stay compatible — check librustzcash releases before bumping.

The zakura wallet crates come from their crates.io releases. Veylor patches only the vendored backend and, until its branch is pushed, zecswap-core (see "Pinned zecSwap and a local stand-in" under Private USD). A release that adds a wallet migration makes the database unreadable to builds with an older release.

`tonic` 0.14 with `tls-ring` + `tls-webpki-roots` features for gRPC TLS. `rustls` 0.23+ requires explicit crypto provider — `tls-ring` provides this.

`log` 0.4 for Rust logging — forwarded to Flutter console via FRB. Level set to `Info` in `init_app()`.

Additional crates for multi-account: `uuid` 1.1, `zip32` 0.2, `jubjub` 0.10, `bls12_381` 0.8, `rand_core` 0.6.

## Ignored Paths

`onboarding/` — Developer onboarding documentation. Do not read or modify during normal development. Only update when explicitly asked.

`CLAUDE.md` intentionally contains only `@AGENTS.md`; update this file as the source of truth and keep this line as the final line.
