import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { IDLE_MS, PAUSE_MS, pauseMark, pausedSince, stopWatchingPauses } from '../src/page-clock.js';

test('a tick that comes late shows a pause of the page; ticks on time show none', () => {
  mock.timers.enable({ apis: ['setInterval'] });
  let clock = 0;
  const now = () => clock;
  try {
    const mark = pauseMark({ now, tickMs: 1_000 });
    for (let tick = 0; tick < 5; tick += 1) {
      clock += 1_000;
      mock.timers.tick(1_000);
    }
    assert.equal(pausedSince(mark), false);
    // The page stood still for a minute: the next tick comes 61 s after the last.
    clock += 61_000;
    mock.timers.tick(1_000);
    assert.equal(pausedSince(mark), true);
    const after = pauseMark({ now, tickMs: 1_000 });
    clock += 1_000 + PAUSE_MS;
    mock.timers.tick(1_000);
    assert.equal(pausedSince(after), false, 'a tick late by no more than the pause threshold');
  } finally {
    stopWatchingPauses();
    mock.timers.reset();
  }
});

test('the ticks run only while tries are marked, and start again from the next mark', () => {
  mock.timers.enable({ apis: ['setInterval'] });
  let clock = 0;
  const now = () => clock;
  try {
    pauseMark({ now, tickMs: 1_000 });
    for (let tick = 0; tick * 1_000 <= IDLE_MS; tick += 1) {
      clock += 1_000;
      mock.timers.tick(1_000);
    }
    // Stopped: an hour with no try marked shows no pause, and wakes the page for nothing.
    clock += 3_600_000;
    mock.timers.tick(3_600_000);
    const mark = pauseMark({ now, tickMs: 1_000 });
    clock += 1_000;
    mock.timers.tick(1_000);
    assert.equal(pausedSince(mark), false);
  } finally {
    stopWatchingPauses();
    mock.timers.reset();
  }
});
