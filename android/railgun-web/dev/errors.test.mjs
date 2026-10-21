import assert from 'node:assert/strict';
import { test } from 'node:test';
import { RailgunError, badRequest, errorCode } from '../src/errors.js';

test('only failures the page names keep their code', () => {
  assert.equal(errorCode(badRequest('no wallet is open')), 'BAD_REQUEST');
  assert.equal(errorCode(new RailgunError('BAD_REQUEST', 'unknown method')), 'BAD_REQUEST');
  assert.equal(errorCode(new Error('the RPC timed out')), 'FAILED');
  assert.equal(errorCode('a string'), 'FAILED');
});
