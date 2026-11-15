import assert from 'node:assert/strict';
import { test } from 'node:test';
import { syncFinisher } from '../src/sync-finish.js';

/** A finisher whose steps the test releases one by one, and the log of what ran and what it sent. */
function finisher({ behind = async () => true, catchUpFails = false, proveFails = false, stateFails = false } = {}) {
  const log = [];
  const gates = {};
  const gate = (name) =>
    new Promise((resolve, reject) => {
      gates[name] = { resolve, reject };
    });
  const step = (name, fails) => async () => {
    log.push(name);
    await gate(name);
    if (fails) throw new Error(`${name} failed`);
  };
  const finish = syncFinisher({
    behind,
    catchUp: step('catchUp', catchUpFails),
    prove: step('prove', proveFails),
    state: async (failed) => {
      if (stateFails) throw new Error('the store is gone');
      return { balances: { Spendable: [] }, screening: failed ? 'failed' : 'ok' };
    },
    emit: (event, data) => log.push([event, data.rest, data.screening]),
  });
  const release = async (name) => {
    while (gates[name] === undefined) await new Promise((resolve) => setImmediate(resolve));
    gates[name].resolve();
    delete gates[name];
  };
  return { finish, log, release };
}

test("a refresh starts the rest of the sync and answers whether it's long, and which rest, without waiting for it", async () => {
  const { finish, log, release } = finisher();
  assert.deepEqual(await finish.start(false), { syncing: true, rest: 1 });
  assert.deepEqual(log, ['catchUp']);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log, ['catchUp', 'prove', ['synced', 1, 'ok']]);
});

test("a refresh while one runs joins it, and one joining partway sends the rest round again, for its sends", async () => {
  const { finish, log, release } = finisher();
  // Two at once share the round they start.
  const [first, second] = await Promise.all([finish.start(false), finish.start(false)]);
  assert.deepEqual([first, second], [{ syncing: true, rest: 1 }, { syncing: true, rest: 1 }]);
  await release('catchUp');
  // A third joins while the round proves: its sends may be past what the round's catch-up reached.
  assert.deepEqual(await finish.start(true), { syncing: true, rest: 1 });
  await release('prove');
  await release('catchUp');
  await release('prove');
  await finish.done;
  // One `synced`, carrying the last refresh's failed check.
  assert.deepEqual(log, ['catchUp', 'prove', 'catchUp', 'prove', ['synced', 1, 'failed']]);
});

test('once one ends, the next refresh starts another, numbered on', async () => {
  const { finish, log, release } = finisher({ behind: async () => false });
  assert.deepEqual(await finish.start(false), { syncing: false, rest: 1 });
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(await finish.start(false), { syncing: false, rest: 2 });
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log, ['catchUp', 'prove', ['synced', 1, 'ok'], 'catchUp', 'prove', ['synced', 2, 'ok']]);
});

test('a catch-up cut short still proves what it reached, and the sync ends as failed', async () => {
  const { finish, log, release } = finisher({ catchUpFails: true });
  await finish.start(false);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log, ['catchUp', 'prove', ['synced', 1, 'failed']]);
});

test('proofs that fail end the sync as failed', async () => {
  const { finish, log, release } = finisher({ proveFails: true });
  await finish.start(false);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log.at(-1), ['synced', 1, 'failed']);
});

test("the refresh's own failed check carries into the end of the sync", async () => {
  const { finish, log, release } = finisher();
  await finish.start(true);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log.at(-1), ['synced', 1, 'failed']);
});

test("a list whose distance can't be read counts as long, and the sync still runs", async () => {
  const { finish, log, release } = finisher({
    behind: async () => {
      throw new Error('the screening node is down');
    },
  });
  assert.deepEqual(await finish.start(false), { syncing: true, rest: 1 });
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log.at(-1), ['synced', 1, 'ok']);
});

test("a rest whose state can't be read still ends, with its number alone", async () => {
  const { finish, log, release } = finisher({ stateFails: true });
  await finish.start(false);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log.at(-1), ['synced', 1, undefined]);
  // And the next refresh starts afresh.
  assert.deepEqual((await finish.start(false)).rest, 2);
});
