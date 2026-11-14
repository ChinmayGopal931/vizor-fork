// A refresh hands back the balances once the notes are scanned and screened. The rest of the sync runs on in the page:
// Railgun's transaction list catches up, then the wallet proves its own sends, which only that list allows. Until
// then the change from those sends is pending, never missing, and every other note is spendable.

/**
 * The rest of a sync, one at a time. `start(checkFailed)` begins it unless one runs, and answers whether the user is
 * to be told the sync goes on: the transaction list is far behind (`behind()`), as on a first sync. It catches up
 * (`catchUp()`), has the wallet prove its sends (`prove()`), then sends `synced` with the wallet's state as
 * `state(failed)` reads it: `failed` when the refresh's own check (`checkFailed`), the catch-up or the proofs failed.
 */
export function syncFinisher({ behind, catchUp, prove, state, emit, log = () => {} }) {
  // `{long, done}`: whether the one running is to be told, and its end.
  let running;

  async function finish(checkFailed) {
    let failed = checkFailed;
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
    emit('synced', await state(failed));
  }

  return {
    start(checkFailed) {
      if (running === undefined) {
        const long = Promise.resolve()
          .then(behind)
          .catch(() => false);
        const done = long
          .then(() => finish(checkFailed))
          .catch((error) => log(`sync not finished: ${error?.message ?? error}`))
          .finally(() => {
            if (running?.done === done) running = undefined;
          });
        running = { long, done };
      }
      return running.long;
    },
    /** The end of the one running, if any. */
    get done() {
      return running?.done;
    },
  };
}
