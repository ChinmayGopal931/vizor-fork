import { MerkletreeScanStatus } from '@railgun-community/shared-models';

/**
 * Syncs txids again while the last sync added some, at most `passes` times. `before` is the latest txid index from
 * before the notes scan, whose own txid sync is the first. A sync the engine started itself, after new notes, makes
 * `sync` return at once, so each count waits for the running one to end first.
 */
export async function catchUpTxids({ before, latest, sync, isScanning, wait, passes }) {
  const settled = async () => {
    while (isScanning()) await wait();
    return latest();
  };
  let now = await settled();
  for (let pass = 0; now !== before && pass < passes; pass += 1) {
    before = now;
    await sync();
    now = await settled();
  }
}

/**
 * Holds back the txid scan's Completes while catch-ups run. Each sync of a catch-up ends with one, which would read as
 * the end of the whole catch-up, so only the last waits for the last catch-up's end. Any other report drops it.
 */
export function txidCompleteHold() {
  let running = 0;
  let held;
  return {
    /** Whether `event` goes out now. */
    pass(event) {
      if (running > 0 && event.status === MerkletreeScanStatus.Complete) {
        held = event;
        return false;
      }
      held = undefined;
      return true;
    },
    begin() {
      running += 1;
    },
    /** The Complete held back, once the last catch-up running ends. */
    end() {
      running -= 1;
      if (running > 0 || held === undefined) return undefined;
      const event = held;
      held = undefined;
      return event;
    },
  };
}
