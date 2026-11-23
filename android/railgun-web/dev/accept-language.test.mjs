import assert from 'node:assert/strict';
import test from 'node:test';
import { ACCEPT_LANGUAGE, pinAcceptLanguage } from '../src/accept-language.js';

// A page's scope with a fetch that records what it was handed.
function fetchScope() {
  const sent = [];
  const scope = {
    Headers,
    Request,
    fetch(input, init) {
      sent.push({ input, init, self: this });
      return Promise.resolve('answer');
    },
  };
  pinAcceptLanguage(scope);
  return { scope, sent };
}

// XMLHttpRequest as far as the page's calls go: the headers each request was sent with.
class StandInRequest {
  static OPENED = 1;
  readyState = 0;
  headers = [];
  sent = false;
  open() {
    this.readyState = StandInRequest.OPENED;
    this.headers = [];
  }
  setRequestHeader(name, value) {
    if (this.readyState !== StandInRequest.OPENED) throw new Error('InvalidStateError');
    this.headers.push([name.toLowerCase(), value]);
  }
  send() {
    if (this.readyState !== StandInRequest.OPENED) throw new Error('InvalidStateError');
    this.sent = true;
  }
}

test('every fetch names the same language, and keeps what it asked for', async () => {
  const { scope, sent } = fetchScope();
  assert.equal(await scope.fetch('https://ethereum-rpc.publicnode.com', { method: 'POST', body: '{}' }), 'answer');
  await scope.fetch('https://rail-squid.squids.live/graphql', { headers: { 'content-type': 'application/json' } });
  await scope.fetch(new Request('https://ppoi.fdi.network/', { headers: { 'x-kept': 'yes' } }));
  const [rpc, squid, screening] = sent;
  assert.equal(rpc.input, 'https://ethereum-rpc.publicnode.com');
  assert.equal(rpc.init.method, 'POST');
  assert.equal(rpc.init.body, '{}');
  assert.equal(rpc.self, scope);
  for (const { init } of sent) assert.equal(init.headers.get('accept-language'), ACCEPT_LANGUAGE);
  assert.equal(squid.init.headers.get('content-type'), 'application/json');
  assert.equal(screening.init.headers.get('x-kept'), 'yes');
});

test('a fetch that names its own language is sent as it is', async () => {
  const { scope, sent } = fetchScope();
  const init = { headers: { 'Accept-Language': 'de' } };
  await scope.fetch('https://ipfs-lb.com/ipfs/x', init);
  assert.equal(sent[0].init, init);
});

test('every XMLHttpRequest names the same language, unless it named its own', () => {
  const scope = { XMLHttpRequest: StandInRequest };
  pinAcceptLanguage(scope);
  const plain = new scope.XMLHttpRequest();
  plain.open('GET', 'https://ipfs-lb.com/ipfs/x');
  plain.setRequestHeader('Accept', 'application/json');
  plain.send();
  assert.deepEqual(plain.headers, [
    ['accept', 'application/json'],
    ['accept-language', ACCEPT_LANGUAGE],
  ]);
  plain.open('GET', 'https://ipfs-lb.com/ipfs/y');
  plain.setRequestHeader('Accept-Language', 'de');
  plain.send();
  assert.deepEqual(plain.headers, [['accept-language', 'de']]);
  // Opened again, a request names the page's language again.
  plain.open('GET', 'https://ipfs-lb.com/ipfs/z');
  plain.send();
  assert.deepEqual(plain.headers, [['accept-language', ACCEPT_LANGUAGE]]);
  // A send that was never opened fails as it would have.
  assert.throws(() => new scope.XMLHttpRequest().send(), /InvalidStateError/);
});
