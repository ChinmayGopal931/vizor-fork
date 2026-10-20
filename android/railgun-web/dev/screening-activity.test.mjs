import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PUBLISH_MS, screeningActivity } from '../src/screening-activity.js';

// An activity whose clock the test moves, and what it published.
function activity() {
  let time = 0;
  const sent = [];
  const tracker = screeningActivity((state) => sent.push(state), () => time);
  return { tracker, sent, tick: (ms) => (time += ms) };
}

test('a step starting or ending goes out at once, with the whole state', () => {
  const { tracker, sent } = activity();
  tracker.txids(0.1);
  tracker.proving({ index: 1, count: 3, progress: 0 });
  tracker.txids(null);
  assert.deepEqual(sent, [
    { txids: { progress: 0.1 }, download: null, proving: null },
    { txids: { progress: 0.1 }, download: null, proving: { index: 1, count: 3, progress: 0 } },
    { txids: null, download: null, proving: { index: 1, count: 3, progress: 0 } },
  ]);
});

test('progress goes out at most every PUBLISH_MS, carrying the latest', () => {
  const { tracker, sent, tick } = activity();
  tracker.proving({ index: 1, count: 1, progress: 0.1 });
  tick(PUBLISH_MS - 1);
  tracker.proving({ index: 1, count: 1, progress: 0.2 });
  assert.equal(sent.length, 1);
  tick(1);
  tracker.proving({ index: 1, count: 1, progress: 0.3 });
  assert.equal(sent.length, 2);
  assert.deepEqual(sent[1].proving, { index: 1, count: 1, progress: 0.3 });
});

test("downloads add up across files until each ends, and a file without a length makes the share unknown", () => {
  const { tracker, sent, tick } = activity();
  tracker.download('zkey', 0, 800);
  assert.deepEqual(sent.at(-1).download, { progress: 0 });
  tick(PUBLISH_MS);
  tracker.download('wasm', 100, 200);
  assert.deepEqual(sent.at(-1).download, { progress: 0.1 });
  tick(PUBLISH_MS);
  tracker.download('vkey', 10, undefined);
  assert.deepEqual(sent.at(-1).download, { progress: null });
  tracker.download('vkey');
  tracker.download('wasm');
  tick(PUBLISH_MS);
  tracker.download('zkey', 800, 800);
  assert.deepEqual(sent.at(-1).download, { progress: 1 });
  tracker.download('zkey');
  assert.equal(sent.at(-1).download, null);
});
