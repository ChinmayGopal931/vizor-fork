import assert from 'node:assert/strict';
import { test } from 'node:test';
import { syncFinisher } from '../src/sync-finish.js';

/** A finisher whose steps the test releases one by one, and the log of what ran and what it sent. */
function finisher({ behind = async () => true, catchUpFails = false, proveFails = false } = {}) {
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
    state: async (failed) => ({ balances: { Spendable: [] }, screening: failed ? 'failed' : 'ok' }),
    emit: (event, data) => log.push([event, data.screening]),
  });
  const release = async (name) => {
    while (gates[name] === undefined) await new Promise((resolve) => setImmediate(resolve));
    gates[name].resolve();
    delete gates[name];
  };
  return { finish, log, release };
}

test("a refresh starts the rest of the sync and answers whether it's long, without waiting for it", async () => {
  const { finish, log, release } = finisher();
  assert.equal(await finish.start(false), true);
  assert.deepEqual(log, ['catchUp']);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log, ['catchUp', 'prove', ['synced', 'ok']]);
});

test("a refresh while one runs starts no other, and hears the running one's answer", async () => {
  const { finish, log, release } = finisher();
  const [first, second] = await Promise.all([finish.start(false), finish.start(false)]);
  assert.deepEqual([first, second], [true, true]);
  await release('catchUp');
  assert.equal(await finish.start(false), true);
  await release('prove');
  await finish.done;
  assert.deepEqual(log, ['catchUp', 'prove', ['synced', 'ok']]);
});

test('once one ends, the next refresh starts another', async () => {
  const { finish, log, release } = finisher({ behind: async () => false });
  assert.equal(await finish.start(false), false);
  await release('catchUp');
  await release('prove');
  await finish.done;
  await finish.start(false);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log, ['catchUp', 'prove', ['synced', 'ok'], 'catchUp', 'prove', ['synced', 'ok']]);
});

test('a catch-up cut short still proves what it reached, and the sync ends as failed', async () => {
  const { finish, log, release } = finisher({ catchUpFails: true });
  await finish.start(false);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log, ['catchUp', 'prove', ['synced', 'failed']]);
});

test('proofs that fail end the sync as failed', async () => {
  const { finish, log, release } = finisher({ proveFails: true });
  await finish.start(false);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log.at(-1), ['synced', 'failed']);
});

test("the refresh's own failed check carries into the end of the sync", async () => {
  const { finish, log, release } = finisher();
  await finish.start(true);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log.at(-1), ['synced', 'failed']);
});

test("a list whose distance can't be read isn't long, and the sync still runs", async () => {
  const { finish, log, release } = finisher({
    behind: async () => {
      throw new Error('the screening node is down');
    },
  });
  assert.equal(await finish.start(false), false);
  await release('catchUp');
  await release('prove');
  await finish.done;
  assert.deepEqual(log.at(-1), ['synced', 'ok']);
});
