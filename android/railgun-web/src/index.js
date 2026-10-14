// Over the host's one port: {id, method, params} in; {id, result}, {id, error: {code, message}} and {event, data} out.
import { RailgunError, errorCode } from './errors.js';
import { prepareReverse, reverseCost } from './reverse.js';
import * as transact from './transact.js';
import * as wallet from './wallet.js';

const INIT = 'zapp-railgun-init';
const handlers = {
  start: wallet.start,
  openWallet: wallet.openWallet,
  refresh: wallet.refresh,
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

let port;

const post = (message) => port.postMessage(JSON.stringify(message));

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

// The host hands its port over as soon as the page loads, and only the first port ever handed over is taken: that,
// not the missing source window (which a dispatched event lacks too), is what keeps anything else off it.
window.addEventListener('message', (event) => {
  if (port !== undefined || event.source !== null || event.data !== INIT || event.ports.length !== 1) return;
  [port] = event.ports;
  port.onmessage = ({ data }) => dispatch(data);
  emit('ready', null);
});
