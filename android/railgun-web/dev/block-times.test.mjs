import assert from 'node:assert/strict';
import { test } from 'node:test';
import { blockTimes, mainnetBlockTime } from '../src/block-times.js';
import { START, STEP, TIMES } from '../src/block-times-mainnet.js';

const table = { start: 1_000, step: 1_000, times: [10_000, 22_000, 36_000] };
const time = blockTimes(table);

test('a block on an entry has its time, and one between two is interpolated', () => {
  assert.equal(time(1_000), 10_000);
  assert.equal(time(2_000), 22_000);
  assert.equal(time(1_500), 16_000);
  assert.equal(time(2_250), 25_500);
  assert.equal(time(3_000), 36_000);
});

test('past the table a block is dated toward the newest block, and past that at 12 s a block', () => {
  const head = { blockNumber: 4_000, timestamp: 47_000 };
  assert.equal(time(3_500, head), 41_500);
  assert.equal(time(4_000, head), 47_000);
  assert.equal(time(4_010, head), 47_120);
  assert.equal(time(3_100), 37_200, 'without the newest block');
});

test('a block before the table, or not a block, has no time', () => {
  assert.equal(time(999), undefined);
  assert.equal(time(Number.NaN), undefined);
});

test("the shipped table starts before Railgun's first mainnet block and only goes forward", () => {
  // Railgun's first event on Ethereum, and the archive's first chunk, are at block 14,751,290.
  assert.ok(START <= 14_751_290);
  assert.equal(STEP, 1_000);
  for (let i = 1; i < TIMES.length; i += 1) {
    const average = (TIMES[i] - TIMES[i - 1]) / STEP;
    assert.ok(average >= 10 && average <= 20, `block ${START + i * STEP}: ${average} s a block`);
  }
  // The Merge, at block 15,537,394, after which a block comes every 12 s slot that isn't missed.
  const merge = mainnetBlockTime(15_601_000) - mainnetBlockTime(15_600_000);
  assert.ok(merge >= 12_000 && merge < 12_500, `${merge} s across 1,000 blocks after the Merge`);
});
