import { PUBLISH_MS } from './screening-activity.js';

// Each step's part of the bar, in the order a refresh runs them: reading how far the txid list is behind, the notes
// scan, the txid catch-up (the notes scan's own txid sync included), the screening nodes' check of the notes, then the
// balances and the history.
const STEPS = {
  start: [0, 0.05],
  notes: [0.05, 0.6],
  txids: [0.6, 0.8],
  checks: [0.8, 0.95],
  finishing: [0.95, 1],
};
const ORDER = Object.keys(STEPS);

/**
 * How far a refresh has come, 0 to 1, for the sync line. Steps only move forward, each running over its part of the
 * bar as its own share comes in, and the whole never goes back. A step starting goes out through `publish` at once, a
 * share at most every PUBLISH_MS, the latest one when the wait ends. Refreshes that overlap share the bar; nothing goes
 * out once the last one ends.
 */
export function refreshProgress(publish, { now = Date.now, schedule = setTimeout, cancel = clearTimeout } = {}) {
  let running = 0;
  let step;
  let progress = 0;
  let sent;
  let published = -Infinity;
  let timer;

  const stopTimer = () => {
    if (timer !== undefined) cancel(timer);
    timer = undefined;
  };

  const flush = () => {
    stopTimer();
    if (running === 0 || progress === sent) return;
    published = now();
    sent = progress;
    publish(progress);
  };

  const advance = (to, atOnce) => {
    if (to > progress) progress = to;
    else if (!atOnce) return;
    const waited = now() - published;
    if (atOnce || waited >= PUBLISH_MS) flush();
    else timer ??= schedule(flush, PUBLISH_MS - waited);
  };

  const start = (name) => {
    if (running === 0 || ORDER.indexOf(name) <= ORDER.indexOf(step)) return;
    step = name;
    advance(STEPS[name][0], true);
  };

  return {
    /** A refresh starts. */
    begin() {
      running += 1;
      if (running > 1) return;
      step = ORDER[0];
      progress = 0;
      sent = undefined;
      advance(0, true);
    },
    /** The refresh moved on to `name`; a step it already passed is ignored. */
    step: start,
    /** `name`'s own share done, 0 to 1; ignored unless `name` runs now. */
    update(name, share) {
      if (running === 0 || name !== step || !Number.isFinite(share)) return;
      const [from, to] = STEPS[name];
      advance(from + (to - from) * Math.min(1, Math.max(0, share)), false);
    },
    /** `name` finished, so the next step starts; ignored unless `name` runs now. */
    done(name) {
      if (name === step) start(ORDER[ORDER.indexOf(name) + 1]);
    },
    /** A refresh ended. */
    end() {
      running = Math.max(0, running - 1);
      if (running === 0) stopTimer();
    },
  };
}
