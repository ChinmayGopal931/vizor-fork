import assert from 'node:assert/strict';
import { test } from 'node:test';
import { refreshProgress } from '../src/refresh-progress.js';
import { PUBLISH_MS } from '../src/screening-activity.js';

// A tracker whose clock and timers the test runs, and what it published.
function tracker() {
  let time = 0;
  const timers = new Map();
  let next = 0;
  const sent = [];
  const progress = refreshProgress((share) => sent.push(Number(share.toFixed(4))), {
    now: () => time,
    schedule: (run, ms) => {
      next += 1;
      timers.set(next, { run, at: time + ms });
      return next;
    },
    cancel: (id) => timers.delete(id),
  });
  const tick = (ms) => {
    time += ms;
    for (const [id, { run, at }] of [...timers]) {
      if (at > time) continue;
      timers.delete(id);
      run();
    }
  };
  return { progress, sent, tick, timers };
}

test('a refresh starts at 0, and each step starts where its part of the bar does', () => {
  const { progress, sent } = tracker();
  progress.begin();
  progress.step('notes');
  progress.step('txids');
  progress.step('checks');
  progress.step('finishing');
  assert.deepEqual(sent, [0, 0.05, 0.6, 0.8, 0.95]);
});

test("a step's share runs over its part of the bar, and only the running step's counts", () => {
  const { progress, sent, tick } = tracker();
  progress.begin();
  progress.update('notes', 0.5);
  progress.step('notes');
  tick(PUBLISH_MS);
  progress.update('notes', 0.5);
  tick(PUBLISH_MS);
  progress.update('checks', 0.5);
  assert.deepEqual(sent, [0, 0.05, 0.325]);
});

test('the bar never goes back: not for a smaller share, nor for a step it passed', () => {
  const { progress, sent, tick } = tracker();
  progress.begin();
  progress.step('notes');
  tick(PUBLISH_MS);
  progress.update('notes', 1);
  tick(PUBLISH_MS);
  progress.update('notes', 0.03);
  progress.step('start');
  progress.step('txids');
  progress.step('notes');
  assert.deepEqual(sent, [0, 0.05, 0.6]);
});

test('a finished step starts the next one, and only while it runs', () => {
  const { progress, sent } = tracker();
  progress.begin();
  progress.done('notes');
  assert.deepEqual(sent, [0], 'notes was not running yet');
  progress.step('notes');
  progress.done('notes');
  progress.step('txids');
  assert.deepEqual(sent, [0, 0.05, 0.6]);
});

test('shares go out at most every PUBLISH_MS, the latest one when the wait ends', () => {
  const { progress, sent, tick } = tracker();
  progress.begin();
  progress.step('checks');
  progress.update('checks', 0.2);
  progress.update('checks', 0.4);
  assert.deepEqual(sent, [0, 0.8]);
  tick(PUBLISH_MS);
  assert.deepEqual(sent, [0, 0.8, 0.86]);
});

test('nothing goes out once the refresh ends, a share it was waiting to send included', () => {
  const { progress, sent, tick, timers } = tracker();
  progress.begin();
  progress.step('notes');
  progress.update('notes', 0.5);
  progress.end();
  tick(PUBLISH_MS);
  progress.update('notes', 1);
  progress.step('txids');
  assert.deepEqual(sent, [0, 0.05]);
  assert.equal(timers.size, 0);
});

test('overlapping refreshes share the bar until the last one ends, and the next starts over', () => {
  const { progress, sent } = tracker();
  progress.begin();
  progress.step('notes');
  progress.begin();
  progress.step('txids');
  progress.end();
  progress.step('checks');
  progress.end();
  progress.step('finishing');
  progress.begin();
  assert.deepEqual(sent, [0, 0.05, 0.6, 0.8, 0]);
});
