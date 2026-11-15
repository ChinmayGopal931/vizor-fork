// The page's event loop stands still while the phone sleeps or the app is put away: no timer fires, and a request in
// flight may never be answered. Timers that came due meanwhile fire as soon as the page runs again, so a try that
// fails across such a pause says nothing about the server it waited on. A tick that comes late shows a pause, and the
// page's retries don't count a try that one cut through: it is made again at once.

const TICK_MS = 1_000;
/** How much later than due a tick must come to count as a pause. */
export const PAUSE_MS = 2_000;

let pauses = 0;
let watch;

/** Counts a pause, as the watch does when a tick comes late. */
export function notePause() {
  pauses += 1;
}

/** Starts noticing pauses, once a page. `now` and `tickMs` are the clock and the tick it is read at. */
export function watchPauses({ now = Date.now, tickMs = TICK_MS } = {}) {
  if (watch !== undefined) return;
  let last = now();
  watch = setInterval(() => {
    const at = now();
    if (at - last > tickMs + PAUSE_MS) notePause();
    last = at;
  }, tickMs);
}

/** Stops the watch, so a test's process can end. */
export function stopWatchingPauses() {
  clearInterval(watch);
  watch = undefined;
}

/** A mark of the pauses so far, for `pausedSince`. */
export const pauseMark = () => pauses;

/** Whether the page has paused since `mark` was taken. */
export const pausedSince = (mark) => pauses !== mark;
