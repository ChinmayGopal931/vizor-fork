# Design tokens and the form factor

Moved from AGENTS.md on 2026-11-22. AGENTS.md lists where every former section went.

UI design tokens (typography, component sizing) are selected at **build
time**, not runtime. The Figma `Sizing` and `Fonts` variable collections
have Desktop and Mobile modes; both are compiled in as const sets, and
`--dart-define=VIZOR_FORM_FACTOR=desktop|mobile` (default: `desktop`)
decides which one the unsuffixed token classes (`AppTypography.*`,
`AppInputSizing.*`, ...) resolve to. The unused set is tree-shaken from
release builds. Source of truth:
`lib/src/core/layout/app_form_factor.dart` (`kAppFormFactor`).

## When the define is required

- **Every mobile-targeted invocation** — `run`, `build`, `test`, and
  `drive` alike. The test binary is compiled per-lane like any other
  build, so widget tests that assert mobile-mode UI need the define too
  (full lane command in "Test lanes" below).
- Desktop (macOS) runs, widgetbook, and plain `fvm flutter test` need no
  flag — the default is `desktop`.

## What happens when you forget it

- **Debug app run on a phone**: fails fast at startup (assert in
  `lib/main.dart`) with the exact flag to pass.
- **Tests**: the default lane never runs mobile-tagged tests (they
  auto-skip — see "Test lanes" below), so the only risk is the mobile
  lane itself: `--run-skipped` without the define resolves desktop
  values. `test/mobile_lane_sanity_test.dart` fails first, by name, in
  that case.
- **Release builds**: no guard either — release/CI lanes for iOS/Android
  must hardcode the define or they ship desktop tokens.

## Test lanes

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

## Assets in widget tests

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

## Rules for new code

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
