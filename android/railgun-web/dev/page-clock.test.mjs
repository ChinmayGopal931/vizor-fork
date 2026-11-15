import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { PAUSE_MS, pauseMark, pausedSince, stopWatchingPauses, watchPauses } from '../src/page-clock.js';

test('a tick that comes late shows a pause of the page; ticks on time show none', () => {
  mock.timers.enable({ apis: ['setInterval'] });
  let clock = 0;
  try {
    watchPauses({ now: () => clock, tickMs: 1_000 });
    const mark = pauseMark();
    for (let tick = 0; tick < 5; tick += 1) {
      clock += 1_000;
      mock.timers.tick(1_000);
    }
    assert.equal(pausedSince(mark), false);
    // The page stood still for a minute: the next tick comes 61 s after the last.
    clock += 61_000;
    mock.timers.tick(1_000);
    assert.equal(pausedSince(mark), true);
    const after = pauseMark();
    clock += 1_000 + PAUSE_MS;
    mock.timers.tick(1_000);
    assert.equal(pausedSince(after), false, 'a tick late by no more than the pause threshold');
  } finally {
    stopWatchingPauses();
    mock.timers.reset();
  }
});
