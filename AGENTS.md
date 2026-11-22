# AGENTS.md

Veylor is a private Zcash wallet, a fork of upstream Vizor, with a neon look and
Shielded USD: USDC held privately on Railgun and bridged to and from shielded
ZEC through zecSwap. Flutter with Rust through `flutter_rust_bridge` v2: all
Zcash cryptography and sync run in Rust (librustzcash crates); Dart holds the UI
(Riverpod) and secure storage. It ships on Android, iOS, macOS and Linux;
Windows is in progress.

This file holds what every task needs. Before changing an area, read its doc.

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

## Read before changing

| Area | Read first |
| --- | --- |
| Design tokens, the form factor define, test lanes, assets in widget tests | `docs/form-factor.md` |
| The neon look: palette, type, shapes, light, motion, desktop | `docs/neon-look.md` |
| Mobile UI: shared components, pages, sheets, footers, haptics | `docs/mobile-ui.md` |
| UI copy | `docs/copy.md`, `lib/l10n/glossary.yaml` |
| Amounts and privacy mode (flip to hide included) | `docs/privacy-mode.md` |
| Accounts, keys, passwords, providers, bootstrap, Rust modules, Tor, the chart, sending, Keystone, Ledger, signing cancellation, the wallet DB, crate versions | `docs/architecture.md` |
| The sync engine and `SyncProvider` | `docs/sync.md` |
| Send expiry, block times, network upgrades | `docs/network-upgrades.md` |
| Ledger send, Gift Card, shielding, swap and voting flows | `docs/ledger/limitations.md` |
| Shielded USD (Private USD): invariants, the open fee, Railgun's page and sync | `docs/private-usd.md`, then `docs/private-usd-android-plan.md` §3.5 |
| A Railgun page host (Android, iOS, Mac, Linux, Windows) | `docs/private-usd-railgun-hosts.md` |
| App identities, Google Play, the direct APK, the macOS and Linux releases | `docs/releases.md` |
| Release notes or a changelog | `release_notes/README.md` |
| Tests, regtest, E2E, `clear-app.sh` | `docs/testing.md` |

## Rules for every change

- **Toolchain.** Always `fvm flutter`, never bare `flutter`. After changing
  `rust/src/api/*.rs`, run `scripts/generate-rust-bridge.sh`.
- **Form factor.** Tokens are chosen at build time: every mobile-targeted run,
  build and test passes `--dart-define=VIZOR_FORM_FACTOR=mobile`; desktop is
  the default. App code uses the unsuffixed token classes and branches on
  `kAppFormFactor`/`kDesktopFormFactor`, never `Platform` checks for UI. A test
  that asserts mobile UI is tagged `mobile`; untagged tests compare against
  token constants, not literals.
- **The phones.** A desktop-only change in shared code is gated on
  `kDesktopFormFactor`, so Android and iOS stay as they were. Changes that do
  reach the phones need the owner's approval, and the mobile lane run.
- **The look.** Gotham Thin (100) and Light (300) only, nothing Book or
  heavier; colours from `context.colors`; dark only for now
  (`kThemeLockedToDark`).
- **Copy.** Sentence case. Strings live in the ARB files (`lib/l10n`, English,
  Korean and Chinese, each with a description). The app is Veylor in copy;
  identifiers keep Vizor's (`VIZOR_*`, `vizor_*` keys, `Vizor*` names,
  domains). When copy changes, update the widgetbook fixtures and the tests
  that assert it.
- **Rust API.** `rust/src/api/` takes primitives, `String` and flat structs;
  per-account calls take `account_uuid`. Complex Zcash types stay in
  `rust/src/wallet/`.
- **Secrets.** Never log or store seeds, keys, keyed RPC URLs, relayer tickets
  or request bodies. Never read `railgun.js` or the `.wasm` files into context.
- **Funds.** Shielded USD's invariants guard funds and privacy: read
  `docs/private-usd.md` before changing `lib/src/features/private_usd`,
  `rust/src/wallet/private_usd` or a Railgun host, and keep the tests that pin
  them. The hardware-wallet send invariants are in `docs/architecture.md`.
- **Vendored backend.** `rust/vendor/zakura-client-backend` may differ from the
  published crate only in `src/tor.rs`: `diff -r` it before every push, and
  never run `cargo fmt --all`.
- **Heavy runs.** Regtest, E2E and device rounds run only when asked.
- **Git.** Push to the owner's fork (`origin`) only when the owner asks; never
  open a PR or merge into `main` unprompted, and never push to upstream.
- **`onboarding/`** is developer onboarding documentation: don't read or
  change it unless asked.

## Where the former sections went

AGENTS.md used to hold everything. A comment or doc that points to one of these
sections by name now means:

- `docs/form-factor.md`: Design Token Form Factor (VIZOR_FORM_FACTOR); When the define is required; What happens when you forget it; Test lanes; Assets in widget tests; Rules for new code.
- `docs/neon-look.md`: Neon look (Veylor).
- `docs/mobile-ui.md`: Mobile UI Standards; Mobile Bottom Safe Area (iOS proportional padding); Mobile Page Footers; Mobile Sheets and the Keyboard; Mobile Cards.
- `docs/private-usd.md`: Private USD.
- `docs/architecture.md`: Architecture; Multi-Account Model; Wallet Password Policy; Account Creation and Home Setup; Mobile Screen Privacy; Dart Provider Structure; App Bootstrap; Sync; Rust Module Structure; Foreground Sync and Platform-Specific Migration Preparation; Network Upgrades; Tor and the network route; Home portfolio chart; iOS Preparation Confirmation Tracking; Send Flow; Ledger Device-App Limits; Signing Cancellation; Hardware Wallet (Keystone) Send Flow; Wallet Creation; Rust API Design Constraint; Key Security Model; WalletDb Initialization; Desktop Window Bootstrap; Figma comparison tooling; Hardware Wallet QR Codes; Crate Versions.
- `docs/releases.md`: Google Play opt-out (VIZOR_DEGOOGLED); Android Package (VIZOR_APPLICATION_ID); Android direct APK (verifiable); Desktop identity (VIZOR_APPLICATION_ID); Veylor macOS release; Veylor Linux release; Release Notes.
- `docs/testing.md`: Testing; clear-app.sh.
- `docs/copy.md`: UI Copy Conventions.

`CLAUDE.md` intentionally contains only `@AGENTS.md`; update this file as the source of truth and keep this line as the final line.
