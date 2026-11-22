# Mobile UI standards

Moved from AGENTS.md on 2026-11-22. AGENTS.md lists where every former section went.

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

## Mobile Bottom Safe Area (iOS proportional padding)

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

## Mobile Page Footers

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

## Mobile Sheets and the Keyboard

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

## Mobile Cards

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
