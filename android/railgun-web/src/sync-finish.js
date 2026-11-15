// A refresh hands back the balances once the notes are scanned and screened. The rest of the sync runs on in the page:
// Railgun's transaction list catches up, then the wallet proves its own sends, which only that list allows. Until
// then the change from those sends is pending, never missing, and every other note is spendable.

/**
 * The rest of a sync, one at a time. `start(checkFailed)` begins one unless one runs, which the refresh then joins, and
 * answers `{syncing, rest}`: whether the user is to be told the sync goes on, the transaction list being far behind
 * (`behind()`, or when that can't be read) as on a first sync, and which rest it is, numbered from 1 up. A rest catches
 * up (`catchUp()`) and has the wallet prove its sends (`prove()`), again while refreshes join it, since their sends
 * need proving too. It ends with `synced`: its number, and the wallet's state as `state(failed)` reads it, `failed`
 * when the last refresh's own check (`checkFailed`), catch-up or proofs failed; just the number when that can't be
 * read.
 */
export function syncFinisher({ behind, catchUp, prove, state, emit, log = () => {} }) {
  let rests = 0;
  // The one running: `{rest, long, checkFailed, again, done}`.
  let running;

  async function finish(run) {
    for (;;) {
      run.again = false;
      let failed = run.checkFailed;
      try {
        await catchUp();
      } catch (error) {
        failed = true;
        log(`transaction list not caught up: ${error?.message ?? error}`);
      }
      // Proofs need only the transactions in the list, so a catch-up cut short still proves what it reached.
      try {
        await prove();
      } catch (error) {
        failed = true;
        log(`sends not proved: ${error?.message ?? error}`);
      }
      let read;
      try {
        read = await state(failed);
      } catch (error) {
        log(`wallet state not read: ${error?.message ?? error}`);
      }
      if (run.again) continue;
      // Over before a refresh can join it.
      if (running === run) running = undefined;
      emit('synced', { rest: run.rest, ...read });
      return;
    }
  }

  return {
    start(checkFailed) {
      if (running === undefined) {
        const run = { rest: (rests += 1), checkFailed, again: false };
        run.long = Promise.resolve()
          .then(behind)
          .catch(() => true);
        run.done = run.long
          .then(() => finish(run))
          .catch((error) => log(`sync not finished: ${error?.message ?? error}`))
          .finally(() => {
            if (running === run) running = undefined;
          });
        running = run;
      } else {
        running.checkFailed = checkFailed;
        running.again = true;
      }
      const { rest, long } = running;
      return long.then((syncing) => ({ syncing: syncing === true, rest }));
    },
    /** The end of the one running, if any. */
    get done() {
      return running?.done;
    },
  };
}
