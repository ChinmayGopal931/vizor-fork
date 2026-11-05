import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fromBase64, redact, toBase64 } from '../src/bytes.js';

test('bodies round-trip through base64, large ones included', () => {
  const bytes = new Uint8Array(200_000).map((_, i) => (i * 7) & 0xff);
  assert.deepEqual(fromBase64(toBase64(bytes)), bytes);
  assert.equal(toBase64(new Uint8Array()), '');
});

test('redaction removes every URL, keyed ones included', () => {
  assert.equal(
    redact('fetch https://eth-mainnet.g.alchemy.com/v2/SECRETKEY failed; see kps://1.2.3.4:1/x'),
    'fetch <url> failed; see <url>',
  );
});
