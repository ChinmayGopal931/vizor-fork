# Neon motion plan (mobile)

Three moments of the Veylor neon look get motion: opening the app, unlocking
into it, and the sync privacy screen's "Sync complete". The owner approved the
direction on 2026-10-17 and asked for a quick prototype first (iOS, on the
owner's iPhone, no new tests); the hardening below comes once the owner likes
it.

## The look: one line of light

Two 80s effects told as one story.

- **CRT.** A screen switching on: a dot, then a horizontal line, then the
  picture opening out of it. Off is the reverse.
- **Light cycle.** That line running along a path, a white-hot head with a red
  trail fading behind it, drawing the VEYLOR letters, a check or a button's
  cut outline.

Each moment: the CRT line appears, becomes a light cycle, draws something, and
the thing switches on with `NeonIgnition`'s flicker.

## 1. Opening the app (cold start, locked wallet)

The iOS launch screen is already black, so Flutter picks up with no seam.

| Time | What happens |
|---|---|
| 0–120 ms | Black. A red dot fades in where the wordmark will be. |
| 120–380 ms | CRT on: the dot stretches into a full-width red scanline. |
| 380–1250 ms | Light cycle: the line pulls in and its head traces V-E-Y-L-O-R stroke by stroke, leaving the lit tube behind. |
| 1250–1550 ms | Ignition: the wordmark flickers on and settles; the lock glyph fades in. |

Face ID is never delayed. The prompt fires when it does today and the intro
plays behind it. A cancel or failure jumps the intro to its end state.

## 2. Unlock into the app (Face ID or passcode)

After a successful unlock the app rehydrates the account, refreshes sync and
starts it, then switches screen. That wait already exists; the animation fills
it.

1. **Charging** (during that work): the wordmark brightens to full; it holds
   if the work is slow (no spinner, no loop).
2. **Handoff** (one frame): just before the route change an app-level curtain
   appears, drawn like the unlock backdrop, so Home builds unseen beneath it.
3. **Reveal** (~550 ms): the wordmark collapses into a horizontal red line
   across the screen; the black splits along it and the halves slide apart to
   show Home.
4. **Landing:** Home's balance sign does its own ignition; a light haptic tick.

## 3. Sync complete (the keep-awake privacy screen)

- When sync finishes the ring collapses into a line (CRT off), the line
  becomes a light cycle that draws the check, "SYNC COMPLETE" decrypts in
  (`NeonScrambleText`), then the light traces the Unlock button's 45° outline
  and the button switches on.
- Then nothing moves (battery). Against OLED burn-in the content drifts 1–2 px
  every minute.
- Dismissing it plays CRT off and reveals the app (today it vanishes).
- Later, optional: the light-cycle wordmark as the progress itself, so the
  5% → 95% burst reads as the cycle tearing across the letters.

## Engineering

**Foundation.**

- `NeonMotion` tokens: every duration and curve in one place.
- One trail painter: any `Path` plus progress 0–1. Path metrics measured once
  and cached; the painter repaints from the animation (`repaint:`), no widget
  rebuilds per frame.
- The VEYLOR geometry pulled out of `VeylorWordmarkPainter` into a reusable
  path, so the finished trail equals today's static wordmark.
- CRT from clip, scale and a drawn line. No fragment shaders and no
  full-screen blur, so nothing differs between Impeller backends and nothing
  compiles on first run.

**Rules.**

1. Never add a wait. Face ID and the unlock work run when they do today; after
   the app is ready the reveal adds at most ~550 ms.
2. Never trap the user. The curtain removes itself after 2 s whatever happens.
3. Lock or background wins at once: the animation jumps to its end or is
   removed, and never resumes halfway later.
4. The curtain only ever appears after a successful unlock, and is opaque.
5. Reduced motion (iOS Reduce Motion, Android Remove animations) shows end
   states, and the reveal becomes a 150 ms cut.
6. Nothing loops forever; every controller finishes and stops ticking, or the
   suite's `pumpAndSettle` calls hang.
7. Decorative only: excluded from semantics; existing labels stay.
8. Clock-driven, so a dropped frame skips ahead; the intro starts after the
   first frame is rasterized so startup cannot eat its opening.

**Cases.** Face ID cancelled, failed or biometrics changed; wrong passcode;
lock during the reveal; background during the intro; resume after the 15
minute auto-lock (a short version); a pending payment link landing on
`/payment-links` or a payment request card raised during the reveal; the other
privacy lock hosts above the app; storage unavailable; no wallet (welcome) is
out of scope for now.

## Order

1. Quick prototype on iOS (owner's iPhone): foundation, unlock reveal,
   cold-open intro, sync complete. No new tests.
2. Owner reviews on the phone and decides what stays.
3. Hardening: the rules and cases above, widget tests for the timeout, lock
   during reveal, reduced motion and the painter at 0 and 1; existing unlock,
   keep-awake and mobile E2E suites pass; Android device check.
