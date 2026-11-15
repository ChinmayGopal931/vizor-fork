// Ethereum mainnet block times without asking for them: the page dates the records it reads from Anon's archive by a
// table shipped with it (block-times-mainnet.js, from scripts/update-railgun-block-times.py), whose entries are 1,000
// blocks apart, and past the table's end by the chain's newest block, which is the same request for every wallet.
import { START, STEP, TIMES } from './block-times-mainnet.js';

// Ethereum's slot time, for a block past the table when the newest block isn't known. A slot can pass without a
// block, so a block dated this way can be late by the slots missed.
const SECONDS_PER_BLOCK = 12;

/**
 * The block time function of a table (`start`, `step`, `times`): a block's time in whole seconds, between the two
 * entries around it, past the last toward `head` (`{blockNumber, timestamp}`, the newest block) when given, else at
 * 12 s a block. Undefined before the table starts.
 */
export function blockTimes({ start, step, times }) {
  const last = start + (times.length - 1) * step;
  const end = times[times.length - 1];
  return (blockNumber, head) => {
    if (!Number.isSafeInteger(blockNumber) || blockNumber < start || times.length === 0) return undefined;
    if (blockNumber <= last) {
      const index = Math.floor((blockNumber - start) / step);
      if (index === times.length - 1) return end;
      const into = (blockNumber - (start + index * step)) / step;
      return Math.round(times[index] + (times[index + 1] - times[index]) * into);
    }
    if (head !== undefined && head.blockNumber > last && head.timestamp > end) {
      if (blockNumber > head.blockNumber) return head.timestamp + (blockNumber - head.blockNumber) * SECONDS_PER_BLOCK;
      return Math.round(end + ((head.timestamp - end) * (blockNumber - last)) / (head.blockNumber - last));
    }
    return end + (blockNumber - last) * SECONDS_PER_BLOCK;
  };
}

/**
 * The block of a table (`start`, `step`, `times`) at `seconds`, a Unix time past its end, at 12 s a block: the newest
 * block from the clock alone, a little ahead by the slots missed since the table ends.
 */
export function blockAt({ start, step, times }, seconds) {
  const last = start + (times.length - 1) * step;
  return last + Math.max(0, Math.floor((seconds - times[times.length - 1]) / SECONDS_PER_BLOCK));
}

/**
 * The newest entry of a table (`start`, `step`, `times`) made by `seconds`, a Unix time: a block known to be no later
 * than it. Past the table's end that is the last entry, since nothing later is known; undefined before the table.
 */
export function blockAtOrBefore({ start, step, times }, seconds) {
  if (!Number.isFinite(seconds) || times.length === 0 || seconds < times[0]) return undefined;
  let low = 0;
  let high = times.length - 1;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (times[middle] <= seconds) low = middle;
    else high = middle - 1;
  }
  return start + low * step;
}

const MAINNET = { start: START, step: STEP, times: TIMES };

/** A mainnet block's time, as `blockTimes` reads the shipped table. */
export const mainnetBlockTime = blockTimes(MAINNET);

/** The mainnet block at `seconds`, as `blockAt` reads the shipped table. */
export const mainnetBlockAt = (seconds) => blockAt(MAINNET, seconds);

/** A mainnet block made by `seconds`, as `blockAtOrBefore` reads the shipped table. */
export const mainnetBlockAtOrBefore = (seconds) => blockAtOrBefore(MAINNET, seconds);
