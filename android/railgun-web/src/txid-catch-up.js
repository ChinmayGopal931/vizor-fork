/**
 * Syncs txids again while the last sync added some, at most `passes` times. `before` is the latest txid index from
 * before the catch-up's first sync. A sync the engine started itself, after new notes, makes `sync` return at once, so
 * each count waits for the running one to end first.
 *
 * A sync that adds nothing ends the catch-up once the list has reached `target()`, the index the screening nodes have
 * validated, or when they have validated none. Short of it, or when it can't be read, the sync failed (the engine drops
 * a batch whose root check could not reach the screening node, and says nothing, and the read goes the same way), so it
 * is tried again after `retryWait(attempt)`, up to `retries` times, and then the catch-up fails. So does one whose
 * passes run out short of the target.
 */
export async function catchUpTxids({ before, latest, sync, isScanning, wait, passes, target, retries = 0, retryWait }) {
  const settled = async () => {
    while (isScanning()) await wait();
    return latest();
  };
  const goal = () =>
    target().then(
      (index) => ({ index }),
      (error) => ({ error }),
    );
  let now = await settled();
  let stalled = 0;
  for (let pass = 0; pass < passes; pass += 1) {
    if (now === before) {
      const { index, error } = await goal();
      if (error === undefined && (index === undefined || !(now < index))) return;
      stalled += 1;
      if (stalled > retries) {
        throw new Error(error === undefined ? `the txid list stopped at ${now} of ${index}` : `the validated txid index can't be read: ${error?.message ?? error}`);
      }
      await retryWait(stalled);
    } else {
      stalled = 0;
    }
    before = now;
    await sync();
    now = await settled();
  }
  const { index } = await goal();
  if (index !== undefined && now < index) throw new Error(`the txid list stopped at ${now} of ${index} after ${passes} syncs`);
}
