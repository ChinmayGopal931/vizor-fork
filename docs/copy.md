# UI copy conventions

Moved from AGENTS.md on 2026-11-22. AGENTS.md lists where every former section went.

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
