// Over the host's transport: {id, method, params} in; {id, result}, {id, error: {code, message}} and {event, data} out.
// Android hands the page a MessagePort. WebKit has no way to hand a page a port, so Veylor's iOS host registers the
// `railgunHost` script message handler instead, and delivers with `__railgunHostDeliver`.
import { RailgunError, errorCode } from './errors.js';
import { prepareReverse, reverseCost } from './reverse.js';
import * as transact from './transact.js';
import * as wallet from './wallet.js';

const INIT = 'vizor-railgun-init';
const handlers = {
  start: wallet.start,
  openWallet: wallet.openWallet,
  refresh: wallet.refresh,
  deleteWallet: wallet.deleteWallet,
  broadcasterFee: transact.broadcasterFee,
  transfer: transact.transfer,
  unshield: transact.unshield,
  reverseCost,
  prepareReverse,
};
// Only an engine started with `debug` answers these, for dev/check.mjs.
const debugHandlers = {
  openNewWallet: wallet.openNewWallet,
};

// Set once, when the host's transport is found; nothing is posted before.
let post;

const emit = (event, data) => post({ event, data });

function handler(method) {
  if (Object.hasOwn(handlers, method)) return handlers[method];
  if (wallet.isDebug() && Object.hasOwn(debugHandlers, method)) return debugHandlers[method];
  throw new RailgunError('BAD_REQUEST', `unknown method ${method}`);
}

async function dispatch(raw) {
  let request;
  try {
    request = JSON.parse(raw);
  } catch {
    return;
  }
  const { id, method, params } = request ?? {};
  if (!Number.isSafeInteger(id)) return;
  try {
    post({ id, result: (await handler(method)(params ?? {}, emit)) ?? null });
  } catch (error) {
    post({ id, error: { code: errorCode(error), message: String(error?.message ?? error) } });
  }
}

// iOS. The host passes each message as a `callAsyncJavaScript` argument, never spliced into script source, and only
// from its own main frame and page world; the delivery is defined once and can't be replaced. It returns at once, so
// the host never waits on a method through it: replies come back over `railgunHost`.
function connectWebKit(host) {
  Object.defineProperty(globalThis, '__railgunHostDeliver', {
    value: (json) => {
      if (typeof json === 'string') dispatch(json);
    },
    writable: false,
    configurable: false,
    enumerable: false,
  });
  post = (message) => host.postMessage(JSON.stringify(message));
  emit('ready', null);
}

// Android. The host hands its port over as soon as the page loads, and only the first port ever handed over is taken:
// that, not the missing source window (which a dispatched event lacks too), is what keeps anything else off it.
function connectPort() {
  let port;
  window.addEventListener('message', (event) => {
    if (port !== undefined || event.source !== null || event.data !== INIT || event.ports.length !== 1) return;
    [port] = event.ports;
    post = (message) => port.postMessage(JSON.stringify(message));
    port.onmessage = ({ data }) => dispatch(data);
    emit('ready', null);
  });
}

// Only Veylor's iOS host registers the handler; Android's WebView has no `webkit` global.
const webkitHost = globalThis.webkit?.messageHandlers?.railgunHost;
if (webkitHost !== undefined) connectWebKit(webkitHost);
else connectPort();
