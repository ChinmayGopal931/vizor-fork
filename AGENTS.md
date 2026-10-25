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
  `AppTypographyDesktop` / `AppTypographyMobile`,
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
  `AppWindowSizing`). `AppRadii` is per-mode only because of the neon
  redesign (`AppRadiiDesktop` / `AppRadiiMobile`; see "Mobile neon
  redesign").
- Form-factor branching in app code uses `kAppFormFactor` (const, so the
  dead branch is tree-shaken) — never `Platform.isIOS`-style checks.
  Runtime `Platform` checks remain only for OS-specific *behavior*
  (keychain, background sync), not for choosing UI metrics or layout
  shells.
- Widgetbook is exempt from the platform/define match check: previewing
  mobile tokens on a desktop host is legitimate —
  `fvm flutter run -t lib/widgetbook.dart --dart-define=VIZOR_FORM_FACTOR=mobile`.
  Only `lib/main.dart` asserts the match.

## Mobile neon redesign (Veylor)

The mobile form factor (iOS and Android) has its own look: true black, neon
red, white light, Gotham Thin and Light, and 45° cuts instead of rounded
corners, after the Tesla Roadster teaser frames, Tron and Cyberpunk 2077.
Desktop keeps the Figma design. The owner directs it on a device rather than
in Figma, so the Figma comparison rules above do not apply to these
surfaces. Behaviour is unchanged unless a bullet below says otherwise.

- **Palette.** Every semantic colour group has four named sets: `figmaDark`
  / `figmaLight` (desktop) and `neonDark` / `neonLight` (mobile), with
  `dark` / `light` selecting by `kAppFormFactor` (as `AppColors.dark`
  does). Tests that must pin one design regardless of lane read the named
  sets. The neon faces come from `NeonPrimitives` (`primitives.dart`).
  `AppNeonColors` (`colors.neon`) carries the lit elements' colours: the
  tube glow and its white-hot core on the page, the balance sign's light,
  the grid, and the white "headlight" frame. Light mode is brushed steel
  with the same red; the balance sign stays black in both. For now the
  mobile app is dark only (owner, 2026-10-17): `kThemeLockedToDark` pins
  the theme and hides Settings' Theme row, and iOS sets
  `UIUserInterfaceStyle` to Dark.
- **Shapes.** `AppRadiiMobile` is near-square (2 to 4 px, `full` is 4).
  `AppChamfer` sizes the 45° cuts drawn with `BeveledRectangleBorder`
  (`Neon.chamferBorder`, two-corner `Neon.wedgeBorder`). `AppButton` cuts
  its corners on mobile, and the primary slab casts a red glow;
  secondary buttons are glass with a hairline edge. `MobileSurfaceCard` is
  a glass panel with lit cut corners (`NeonGlassPanelPainter`). Avatars
  are cut-corner plates with a red edge.
- **Light.** `lib/src/core/theme/neon.dart`: `Neon.textGlow`,
  `Neon.boxGlow`, `Neon.strokeTube` (halo, glow and core: every lit line
  uses it), the shared painter recipes (`Neon.bead`, `Neon.perspectiveGrid`,
  `Neon.chamferCuts`, `Neon.strokeUnlit`), `kNeonHudCaptionStyle` and
  `kNeonPageTitleStyle` (the page title). Motion lives in
  `lib/src/core/widgets/mobile/neon_motion.dart`: `NeonIgnition` (a sign's
  switch-on flicker, with an optional delay, off under reduced motion) and
  the `NeonAppearMotion` mixin for one-shot entrances.
- **Type.** Gotham everywhere, lighter on mobile, and nothing on mobile is
  Book (400) or heavier. Headings are Thin (100): screen, step, page and
  sheet titles, a state's statement (Home's "We're importing your
  wallet..."), and display numerals. Everything else is Light (300):
  subtitles, body, labels, field and helper text, buttons, chips, rows,
  card titles and the HUD captions. Emphasis comes from colour and size,
  not weight. Every `AppTypographyMobile` token is Thin or Light
  (`bodyMediumStrong` and the code styles included), so mobile code leaves
  the token's weight alone. Widgets both form factors draw use
  `AppFontWeight` for a one-off emphasis weight (desktop keeps the Figma
  weight, mobile resolves it to Light; `AppFontWeight.heading` is the Thin
  heading weight); the legacy Material theme goes through it too, so
  unstyled mobile text is Light. There are no exceptions.
  Page titles (`MobileTopNav.back`) are spaced uppercase Thin; section heads
  (Settings groups, Activity dates, Home's recent activity) are uppercase
  red HUD captions. These uppercase captions are a deliberate exception to
  the sentence-case rule; the strings themselves stay sentence case and are
  upper-cased where drawn.
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
  Home. A Tron floor lies behind the content and flows only while
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
  FAILED`; the Tor ones are Home's): a first sync climbs, and a refresh of
  a wallet that synced before stays `RAILGUN SYNCED` while the floor flows,
  unless the page reports a long catch-up on Railgun's transaction list
  (1,000 or more behind): that climbs as `RAILGUN SYNC n%`, since screening a
  send's change waits on the list. Private USD's Processing row adds a live
  line (smaller, in the accent colour) saying what the screening work is
  doing: syncing that list, downloading proving files, building a proof, or
  waiting on the screening service (`privateUsdScreeningStatus`).
- **Tab bar.** Glyphs only: no slab, border or caption. `TronGlyph` draws
  the tab icons (and, on mobile, `AppIcon` draws its round icons —
  check, arrow-down, plus, warning, cancel, help — as angular glyphs). The active
  glyph is lit with a pool of light sliding under it; content fades to
  black beneath the bar. It has three tabs, Home, Activity and Settings
  (owner, 2026-10-19). Swap opens over them from a full-width button on
  Home, under Send and Receive, which split their row in half. Home has
  no Pay button.
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
- **Art.** The medieval illustrations are gone from mobile: empty states use
  `NeonHorizon` (a striped 80s sun over a grid floor), hero and status
  spots `NeonGlyphBadge`, and painted backgrounds are dropped. The account
  pictures are the seven neon portraits in `assets/profile_pictures/`
  (`pfp-01` to `pfp-07`, lossless WebP); ids of the retired knights
  (`pfp-08` to `pfp-15`) map onto them. Payment-link gift card designs are
  unchanged. `VizorWordmark` draws a VEYLOR wordmark in tube strokes on
  mobile (`VeylorWordmarkPainter`: lit red, or plain lines where a caller
  sets a colour); desktop keeps `vizor_logo.svg`.
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
  badge.
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
  numeric keyboard's Done check is neon red. Sheets keep 4 px top corners
  and, on iOS, bottom corners that follow the display's curve, which would
  clip square ones.

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

## Deep-link Host (VIZOR_DEEPLINK_BASE_URL)

The HTTPS origin Veylor claims for incoming links has **one** knob on
Android and Dart: `--dart-define=VIZOR_DEEPLINK_BASE_URL` (default
`https://link.vizor.cash`).

- Dart is the source of truth: `VizorDeepLink` reads the define through
  `String.fromEnvironment`.
- Gradle derives its value from the same place. Flutter forwards every
  dart-define as `-Pdart-defines=<base64("KEY=VALUE")>,...`, and
  `android/app/build.gradle.kts` decodes that property to fill the
  `vizorDeeplinkHost` manifest placeholder and `BuildConfig
  .VIZOR_DEEPLINK_HOST`. There is deliberately no separate Gradle
  property or environment variable — a second knob could disagree with
  the compiled-in Dart origin and silently break verified app links.
  Invoking Gradle directly (no dart-defines) falls back to the default.
- iOS is the exception: it keeps `VIZOR_DEEPLINK_HOST` in the Flutter
  xcconfigs (`ios/Flutter/{Debug,Profile,Release}.xcconfig`), which feed
  `Info.plist` and `Runner.entitlements`. Change the host there too.
- The Android intent-filter claims the host with no path constraint, so
  the bare origin (empty path on Android), `/`, and
  `/payment-links/open` all open the app. Path filtering belongs to
  Dart's `classifyIncomingLink`, which drops unknown paths on the origin
  silently.

## Mainnet Block-Time Table

On mainnet, wallet birthday conversions (import date to height, seed-phrase
screen height to date) never send lightwalletd a wallet-derived height. They
read `rust/src/wallet/block_times/mainnet_data.rs`, a generated table of
header times every 1,000 blocks. The only request left is the chain tip.

- The weekly `Update mainnet block times` workflow appends entries after two
  endpoints agree, and opens a PR for a person to merge.
- Bootstrap or refresh before a release cut with
  `scripts/update-mainnet-block-times.py` (needs `grpcurl`); validate offline
  with `--check`. Never edit the data file by hand.

## Image Assets

New raster image assets must be converted to lossless WebP before inclusion.
Preserve their dimensions and decoded pixels, and update app, Widgetbook, and
test references to `.webp`. For illustrations, use
`scripts/convert-illustrations-to-webp.py` (`--apply` writes verified conversions).

## Editing Figma

When the user explicitly asks you to modify a Figma file or design, read
`FIGMA-AI-FIX.md` completely before starting and use it as the instructions and
reference for that work.

## Figma Visual Verification

Use the widget-test capture as the default visual-comparison path in both
directions: when applying an existing Flutter implementation to Figma and when
implementing a Figma design in Flutter, then capturing the result to find and
correct differences from the design.

- Represent the required screen and state as a deterministic scenario in
  `lib/figma_compare/figma_compare_scenarios.dart`. Prefer reusing an existing
  Widgetbook fixture. The scenario must not depend on production wallet data,
  storage, network, or Rust state.
- Match the Figma reference's form factor, logical viewport, theme, locale,
  content, and component state. Use the widget-test renderer for normal
  desktop and mobile iterations:

  ```bash
  scripts/figma-compare.sh widget \
    --scenario <scenario> \
    --theme <dark|light>

  scripts/figma-compare.sh widget \
    --form-factor mobile \
    --scenario <mobile-scenario> \
    --theme <dark|light>
  ```

- Compare `content.widget.png` with the corresponding Figma capture side by
  side and, when practical, with an overlay or image diff. After implementing
  from Figma, correct the Flutter code and repeat the widget capture until no
  actionable visual difference remains. Do not use Widgetbook chrome as
  comparison evidence.
- For desktop typography, font weight can render differently across Figma,
  macOS, Windows, and Linux because platform font rasterization differs. Treat
  the weight as matching when Flutter's configured `fontWeight` value matches
  Figma's weight setting; do not choose a different weight solely to force
  pixel-level visual parity. Continue to verify font family, size, line height,
  letter spacing, wrapping, and positioning normally.
- If the required state is not registered, add a reusable deterministic
  capture scenario before falling back to a running platform app. Temporary
  production routes, bootstrap overrides, or provider changes are a last
  resort and must be removed before completion.
- Use native macOS or iOS Simulator captures only for a final check of behavior
  the widget-test renderer cannot represent, such as operating-system chrome,
  the real window shell, native insets, or a material platform-rendering
  difference. Keep the widget capture as the primary app-content comparison.
- A request to compare an implementation with Figma does not authorize any
  Figma mutation. Do not copy, move, or edit Figma nodes unless the user
  explicitly requests a Figma change. When they do, read `FIGMA-AI-FIX.md` in
  full and follow its target-approval, copy-only, and visual-parity workflow.

## Figma Layer Interpretation

When reading or implementing Figma designs, distinguish app UI from
operating-system chrome and presentation-only background layers.

- Ignore layers named `_MacOS Light Mode` and `_MacOS Dark Mode`. These are
  operating-system screenshots/images placed behind the design for presentation
  context only, and are not part of the app UI.
- In a `Screen` frame, ignore any `Controls` layer that is a sibling of
  `Window Contents`. This represents the native OS window title/status bar
  controls, not app content.
- If a Figma screen uses this structure, treat the meaningful app UI as starting
  inside `Window Contents`, specifically from the `Trailing Pane` layer onward.
- Do not recreate, style, test, or otherwise implement the ignored OS/background
  layers unless the user explicitly asks to work on native window chrome.

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
- This applies to interpolated labels too: `'$symbol deposit tx'`, not
  `'$symbol Deposit tx'`. The asset symbol carries its own casing; the rest of
  the label is sentence case.
- **Exception**: sidebar entries and screen titles may use Title Case (e.g.
  onboarding step labels `Secret Passphrase`, `Wallet Birthday Height`) — do
  not sentence-case them in copy sweeps.
- Existing rationale and full audit are in `qa-copy-review.csv` and
  `copy-review-20260528-1554.csv` at the repo root. Reference these before
  introducing new copy in this project.
- When editing existing copy, also update widgetbook fixtures
  (`lib/widgetbook/*.dart`) and tests (`test/`) that assert on the literal
  string — `find.text(...)` matchers, `expectedNextAction` fields, and
  `_tooltipWithMessage(...)` helpers will break otherwise.

## Release Notes

When asked to prepare user-facing release notes or a changelog for a release,
read `release_notes/README.md` and create `release_notes/vX.Y.Z.md`.
Unless the request explicitly says otherwise, draft desktop release notes for
Windows, Linux, and macOS from desktop user-facing changes only. Exclude
mobile-only changes.

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
  └── refreshAfterUnlock() refreshes balances/history before foreground sync recovery

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
  - Rust wallet DB via `list_accounts`
  - active-account DB data via `get_sync_status`, `get_balance`,
    `get_transaction_history(limit: 10)`
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
  initial balance/history hydration fails, in which case sync state falls back
  to empty and the live sync repopulates it.

### Sync Engine (Rust-only)

The entire sync loop runs in Rust (`rust/src/wallet/sync_engine.rs`). A single call from Dart (`startFullSync()`) triggers the full pipeline:

1. tonic gRPC → lightwalletd (TLS via `tls-ring`)
2. Download subtree roots (sapling + orchard, incremental with start_index optimization)
3. Download compact blocks into memory (in-memory `MemoryBlockSource`, no file I/O)
4. `scan_cached_blocks` from memory (100 blocks per batch)
5. Enhancement: process each work queue separately. Status observations come
   from `transaction_status_work()`, which routes each obligation to public
   `GetTransaction` or private Status PIR. Payload recovery comes from
   `transaction_enhancement_work()`. `transaction_data_requests()` feeds only
   transparent-address history (`TransactionsInvolvingAddress`). librustzcash
   persistently requests `GetStatus` only when compact-block scanning cannot
   observe the transaction's mined state. During recovery, Veylor separately
   excludes previously mined transactions from resubmission while a pending
   scan range can still restore their mined heights.
6. Progress streamed to Dart via FRB `StreamSink` per batch. Each event has a
   `kind` (`SyncEventKind` in `sync_engine/mod.rs`, which replaced the old
   `is_complete` flag): `Progress`, `Completed`, or `FollowupUpdated`.
7. After `Completed`, two follow-up loops run under the same cancellation and
   never fail the sync: private transparent recovery over the transparent PIR
   service (`transparent_followup`,
   `sync_engine/transparent_ledger.rs`, a no-op unless Private queries selects
   it) and transparent txid details (`sync_engine/transparent_details.rs`, over
   txid display PIR under private policy or gated `GetTransaction` otherwise).
   Background preparation syncs (mode 2) skip both. When one changes wallet
   data it reports `FollowupUpdated`, and Dart re-reads balances, history and
   open receipts without counting a second completion. The stream and the
   `SYNC_RUNNING` guard end only after the follow-ups (and the deferred
   inactive-account UTXO refresh) finish.

Single DB connection reused across entire sync (opened once, passed to all operations).

Progress percentage: `initial_total` (total blocks to scan) is captured once before the scan loop from `suggest_scan_ranges()`. After each batch, `remaining` unscanned blocks are recalculated, then `pct = 1.0 - remaining / initial_total`. Note: `suggest_scan_ranges()` does not return `Scanned` ranges, so per-batch `total` cannot be used as the denominator. Each progress event includes `has_new_tx` (from `ScanSummary` received/spent note counts) to trigger transaction history refresh only when needed.

Automatic retry: `run_sync_inner` wraps `run_sync_impl` with exponential backoff (3 retries, 2s/4s/8s). Cancel and mode-change are checked during retry wait. Both FRB and C FFI paths benefit.

All sync log messages include `[Xs]` elapsed time from sync start (set once in `run_sync_inner`, consistent across retries). Errors are logged via `log` crate (forwarded to os_log subsystem `frb_user` by FRB `setup_default_user_utils()`). Log level set to `Info` to filter verbose rustls TLS logs. Rust logs are NOT visible in `flutter run` terminal — use `log stream --predicate 'subsystem == "frb_user"' --level info` in a separate terminal.

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
│   │                    # Progress: initial_total based (remaining / initial_total)
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

### Tor and the network route

Tor covers the app's foreground traffic only. The desired route lives in Rust
process memory, applied by the Dart layer at startup and by the settings
toggle; every foreground lightwalletd and HTTP path goes through the
policy-aware openers and fails closed while Tor is starting or broken.

- **Voting SDK network clients are constructed only in**
  `rust/src/wallet/voting/network_clients.rs`. Chain, helper, PIR, and
  vote-tree are separate transport roles; injecting a chain transport does
  not configure the tree. Both tree pre-sync and the round executor must use
  the same shared routed transport. When upgrading the SDK, audit new
  network-capable entry points and extend the routing table and service tests
  in `rust/src/wallet/voting/README.md`. The Rust suite includes a supplemental
  constructor guard; it does not replace checking actual network behavior.
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

Mobile Home draws the chart's line as the balance sign's light trail, and a
tap on the sign opens the full chart at `/portfolio-chart`
(`lib/src/features/portfolio_chart/`). Its wallet side is read from the local
wallet DB alone: `getTransactionHistory`, `account_balance_delta` per mined
block, folded into a balance step function once a sync has completed (nothing
while locked, and a mask in privacy mode). Its market side is public ZEC/USD
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
  switches (the owner removed it on 2026-10-17).
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
  requested; only an already cached series is drawn. An empty, non-https or
  invalid `VIZOR_PRICING_ENGINE_BASE_URL` has the same effect for good: no
  price switch in Settings and no request.
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
Keep account-key verification before PCZT transmission and retain the
Orchard-to-Ironwood gate until the actual supported app passes its canary.

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
Normal app exit closes the proposal gate, requests sync cancellation, and hides
its desktop window before awaiting reservation cleanup. Rust allows 250ms to
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
   Store-then-broadcast leaves the wallet in an unrecoverable state if
   lightwalletd rejects the tx: DB thinks the notes are spent, network
   has no record of the tx, user has to manually rescue the wallet.

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
stores every restored birthday rounded down to one past a 10,000-block grid
point (`tree_states::restore_birthday`), so lightwalletd learns only the bucket.
When the grid point is a compiled checkpoint (`rust/src/wallet/tree_states.rs`)
the first scan batch reads its state locally instead of sending
`GetTreeState`; a restore newer than the table fetches the grid point's state.
Restores are the discovery import
(`import_software_wallet_with_account_discovery`), wallet-link import
(`import_software_account_at_index`), and hardware import
(`import_hardware_account`). Newly created accounts (`create_wallet`,
`add_account`, and `import_wallet` from onboarding's reveal-then-confirm
flow), payment-link claims (`import_wallet`), and Gift Card observers keep the
exact height; testnet, regtest, and masquerade builds are unchanged. Code that queries lightwalletd from a restored birthday must use the
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

### Dart Sync Provider

`lib/src/providers/sync_provider.dart` — Riverpod `AsyncNotifier`.

**Auto-sync lifecycle:**
- `build()` watches `accountProvider` via `ref.listen` (not `ref.watch` — avoids rebuild on switch/rename)
- Account count increase triggers `startSync()` + `_startPolling()` (both first account and additional accounts)
- `_checkAndSync()`: polls `getLatestBlockHeight` every 10s, re-syncs if tip > last synced height or previous sync incomplete (`percentage < 1.0`)
- `_checkAndSync()`, `_refreshBalance()`, and `_onSyncProgress()` all bail out while
  locked and discard late async completions via `_sensitiveStateEpoch`
- Polling stops during `_checkAndSync` execution to prevent concurrent overlap, restarts after
- Duplicate sync guard: `_isSyncing` (Dart-side bool) + `isSyncRunning()` (Rust AtomicBool)
- `startSync()` / `startSyncAnyway()` called while this notifier's own stream is
  still open (the Rust guard is held through post-sync follow-ups) queue one
  start (`_queueSyncStart`) instead of being dropped. Repeats coalesce: a
  forced request upgrades a plain one and the highest tip carries over. The
  queued start runs when the stream ends, unless the app is now in the
  background.

**startSync() is fire-and-forget:**
- Sets up FRB stream listener and returns immediately (no Completer, no await)
- `_syncGen` generation counter: incremented by `stopSync()`, checked in `.then()` callbacks to invalidate pending operations after user-initiated stop
- Stream `onDone` → `_onSyncDone()` (balance refresh + start polling), then any queued start
- `FollowupUpdated` event → `_onSyncFollowupUpdated()` (re-read balances and open receipts; not a new completion)
- Stream `onError` → sets error state + starts polling for auto-retry

**Sync control:**
- `stopSync()`: increments `_syncGen` + `cancelFullSync()` + `_stopPolling()`. Polling does not restart until next `onResume`
- `clearSensitiveStateForLock()`: increments `_syncGen`/`_sensitiveStateEpoch`,
  clears in-memory sync state, sends `setSyncMode(0)` + `cancelFullSync()`,
  and waits briefly for stale Rust sync / mempool work to stop
- `startSyncAnyway()`: unlock recovery path. If Rust is still running but already
  cancelling, waits for teardown before starting foreground sync; if teardown
  times out, it at least restores polling so a later retry can recover

**Lifecycle:**
- `onResume`: refreshes balance → `_checkAndSync()` (which starts polling)
- `onHide`: stops polling (no wasted network in background)
- `SyncState.recentTransactions`: latest 10 transactions, updated on `hasNewTx`, sync completion, and app resume
- All balance/history queries pass `activeAccountUuid` from `AccountProvider`

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

- `Scaffold.backgroundColor: Colors.transparent` is required anywhere the native acrylic/translucent shell should remain visible.
- Any opaque `Container`, `ColoredBox`, decoration color, or other filled background will cover the native effect in that region.
- Treat transparency as opt-in per region: only paint solid backgrounds where the UI should actually be solid.

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

## Private USD

A Railgun USDC ("private USD") balance, conversion both ways with shielded
ZEC by atomic swap (with refunds and rescue), and private send and withdraw.
It runs on Android, mobile form factor only. The iOS port (iOS 17 and later,
behind the same define) has its code in but has not yet run on a simulator
or an iPhone. Before changing it,
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
- Dart: `lib/src/features/private_usd/`,
  `lib/src/core/config/private_usd_feature_config.dart` and
  `lib/src/providers/private_usd_lifecycle_provider.dart`.
- Kotlin: `android/app/src/main/kotlin/com/keplr/vizor/railgun/`.
- Swift: `ios/Runner/Railgun/`.
- The Railgun page: `android/app/src/main/assets/railgun/`, built from
  `android/railgun-web/`; the same build copies it as is to
  `ios/Runner/Railgun/railgun/`.

**Defines (reference §7.3).** Each is a Dart define read once in
`private_usd_feature_config.dart`. Gradle needs none of them.

- `VIZOR_PRIVATE_USD_ENABLED` (default `false`) turns the feature on.
  Release builds turn it on only after the owner's sign-off.
- `VIZOR_ETHEREUM_RPC_URL_{MAINNET,SEPOLIA}` are the keyed RPC URLs. They
  are the only secrets: pass them only with
  `--dart-define-from-file=<gitignored json>`. Their host must be
  `eth-{mainnet,sepolia}.g.alchemy.com` or `{mainnet,sepolia}.infura.io`. Any
  other host needs a bundle rebuild and changes to the Kotlin, Swift and
  Rust allowlists. Users can set their own URL in Settings (Ethereum RPC),
  on the network's Alchemy, Infura or publicnode host; it replaces the
  build's keyed URL with no fallback, and is checked with `eth_chainId`
  before it is saved. Rust holds the engine to the same rule
  (`Deployment::rpc_url`, the network's `rpc_hosts`, https without
  credentials): a URL off them is `WrongDeployment`, never replaced. A
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
- Derive keys only after the seed-fingerprint check, and refuse a Railgun
  session whose address differs from Rust's.
- Deleting an account, or resetting, with a conversion under way warns with
  the count and waits for the user's explicit confirmation. Drain
  `privateUsdLifecycleProvider` first, and clean up only after the Rust
  delete succeeds.

**Deposits (plan M9).** Public USDC sent to the account's own deposit
addresses (`m/44'/60'|1'/(1000 + zip32)'/0/index`, from the seed) is
shielded into its private balance by an EIP-3009 authorization the relayer
sends (`rust/src/wallet/private_usd/deposits.rs`, zecSwap's
`docs/deposits.md`). The Receive sheet (`private_usd_receive_sheet.dart`)
switches, as ZEC's Receive does its pools (`NeonSwitchTabs`), between public
USDC at the deposit address (the default) and 0zkUSDC at the account's 0zk
address, for another Railgun wallet; it replaced the screen's 0zk card
(owner, 2026-10-19). Only a network with a Deposits pin shows the USDC side:
testnet and, since 2026-10-19, mainnet; elsewhere the sheet shows the 0zk
address alone. Send and Withdraw scan their recipient as ZEC Send does (the
shared `MobileScanAddressRow` and `MobileAddressScanCard`): Send takes a 0zk
address and Withdraw a 0x one (`privateUsdScanOutcome`); an `ethereum:`
request gives up its recipient, never its token, and one for another chain
is refused.

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
`com.zcash.wallet/private_usd_attestation`; its Swift twin answers
`unavailable`), Dart `services/private_usd_tokens_service.dart` and
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

**Network: Tor and the Railgun page.**

- All engine HTTP (maker, relayer, Ethereum RPC) goes through `routed_http`.
  It follows the route policy, fails closed while Tor starts or is broken,
  and never falls back to the clearnet.
- The Railgun page runs in a native Kotlin WebView host behind
  `com.zcash.wallet/railgun` (no Dart WebView plugin and no injected JS
  bridge). It loads only its own assets through `WebViewAssetLoader` and
  intercepts every subresource against a fixed host allowlist. The Kotlin
  and Swift allowlists (`RailgunEndpoints`), the Rust bridge's allowlist and
  the page's CSP must agree; a Rust test in `railgun_bridge.rs` pins them.
- On iOS a Swift `WKWebView` host behind the same channel serves the page
  from `veylor-railgun://app/`, in a data store of its own whose SOCKS5
  proxy is the bridge (no failover), with a `WKContentRuleList` allowlist
  (iOS reference §6).
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

**Local stand-ins.** `rust/Cargo.toml` carries two stand-ins for releases
that do not exist yet:

- `~/dev/zapp/zecSwap-zakura-windows`, a zecSwap `[patch]` outside the
  repository: `zecswap-core` of the pinned rev (the windows contract's) on
  Zakura Common v3 (E1). A clean clone builds only where that checkout
  exists.
- `rust/vendor/zakura-client-backend`, the published 0.1.0-rc9 with the
  `connect_stream` patch the Railgun bridge needs
  (`rust/vendor/zakura-client-backend.patch`, E4). Before every push,
  `diff -r` it against the published crate: only `src/tor.rs` may differ.
  Never run `cargo fmt --all`, which reformats it, and vendor it again for
  a new backend release.

The owner merged Private USD into the fork's `main` with the zecSwap
stand-in in place (2026-10-20). Replace it with a pushed zecSwap rev once E1
lands (progress B-6). Push to the owner's fork (`origin`) only when the owner
asks; never merge into `main` or open a PR unprompted, and never against
upstream.

## Testing

- Keep small Rust internal tests in the source file's `#[cfg(test)] mod tests`.
- When fixtures or scenarios obscure the implementation, split into `<module>/tests.rs`; do not split by line count alone.
- Put public-API integration tests in `rust/tests/`; do not widen production visibility for test placement.
- Rust unit tests: `cd rust && cargo test` — 11 tests covering key derivation, address encoding / Orchard-only UA derivation, determinism, and PROPOSAL_STORE lifecycle (idempotent discard, consume-on-entry, replay rejection). Tests that need a DB use `tempfile::tempdir()`.
- Dart unit tests: `fvm flutter test` (mobile-tagged tests auto-skip).
  Mobile-UI tests:
  `fvm flutter test --tags mobile --run-skipped --dart-define=VIZOR_FORM_FACTOR=mobile`.
  Lane rules in "Design Token Form Factor" above.
- Fonts: Gotham is the app's only family. It is a plain asset (`assets/fonts/`),
  not a pubspec `fonts:` family: Flutter takes a face's weight from the font
  file, and these files' OS/2 weight classes are off the CSS scale, so
  `FontWeight.w400` would resolve to the Bold file. `loadGothamFonts()`
  (`lib/src/core/theme/gotham_fonts.dart`) rewrites the weights in memory and
  registers the family; `initializeZcashWalletRuntime`, Widgetbook and the
  Figma-compare entry points call it. A widget test that needs real glyphs
  instead of the square test font calls `loadGothamFonts()` too, never a
  hand-rolled `FontLoader` over the `Gotham-*.otf` files. Gotham has no
  SemiBold (`w600` resolves to Bold) and no monospace face. The mobile serif
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

`tonic` 0.14 with `tls-ring` + `tls-webpki-roots` features for gRPC TLS. `rustls` 0.23+ requires explicit crypto provider — `tls-ring` provides this.

`log` 0.4 for Rust logging — forwarded to Flutter console via FRB. Level set to `Info` in `init_app()`.

Additional crates for multi-account: `uuid` 1.1, `zip32` 0.2, `jubjub` 0.10, `bls12_381` 0.8, `rand_core` 0.6.

## Ignored Paths

`onboarding/` — Developer onboarding documentation. Do not read or modify during normal development. Only update when explicitly asked.

`CLAUDE.md` intentionally contains only `@AGENTS.md`; update this file as the source of truth and keep this line as the final line.
