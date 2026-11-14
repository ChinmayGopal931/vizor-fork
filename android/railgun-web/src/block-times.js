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

/** A mainnet block's time, as `blockTimes` reads the shipped table. */
export const mainnetBlockTime = blockTimes({ start: START, step: STEP, times: TIMES });
