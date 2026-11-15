// The page's event loop stands still while the phone sleeps or the app is put away: no timer fires, and a request in
// flight may never be answered. Timers that came due meanwhile fire as soon as the page runs again, so a try that
// fails across such a pause says nothing about the server it waited on. A tick that comes late shows a pause, and the
// page's retries don't count a try that one cut through, though it still waits its turn: a page hidden in the
// background, its timers only slowed, looks paused too. The ticks run only while tries are being made.

const TICK_MS = 1_000;
/** How much later than due a tick must come to count as a pause. */
export const PAUSE_MS = 2_000;
/** The ticks stop once no try has been marked for this long. */
export const IDLE_MS = 2 * 60_000;

let pauses = 0;
let watch;
let marked = 0;

/** Counts a pause, as the watch does when a tick comes late. */
export function notePause() {
  pauses += 1;
}

/**
 * A mark of the pauses so far, taken before a try, for `pausedSince`; the ticks run while marks are taken. `now` and
 * `tickMs` are the clock and the tick it is read at.
 */
export function pauseMark({ now = Date.now, tickMs = TICK_MS } = {}) {
  marked = now();
  if (watch === undefined) {
    let last = marked;
    watch = setInterval(() => {
      const at = now();
      if (at - last > tickMs + PAUSE_MS) notePause();
      last = at;
      if (at - marked > IDLE_MS) stopWatchingPauses();
    }, tickMs);
    watch.unref?.();
  }
  return pauses;
}

/** Stops the ticks until the next mark. */
export function stopWatchingPauses() {
  clearInterval(watch);
  watch = undefined;
}

/** Whether the page has paused since `mark` was taken. */
export const pausedSince = (mark) => pauses !== mark;
