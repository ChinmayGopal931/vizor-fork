// Over the host's transport: {id, method, params} in; {id, result}, {id, error: {code, message}} and {event, data} out,
// the Railgun page's protocol (android/railgun-web/src/index.js). Android hands the page a MessagePort; only the first
// port ever handed over is taken.
import * as host from './worker-host.js';

const INIT = 'vizor-anon-rpc-init';
const handlers = {
  start: host.start,
  awaitReady: host.awaitReady,
  fetch: host.fetchThrough,
  status: host.status,
  stop: host.stop,
};

// Set once, when the host's transport is found; nothing is posted before.
let post;

const emit = (event, data) => post({ event, data });

function handler(method) {
  if (Object.hasOwn(handlers, method)) return handlers[method];
  throw new host.PageError('BAD_REQUEST', `unknown method ${method}`);
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
    const code = error instanceof host.PageError ? error.code : 'FAILED';
    post({ id, error: { code, message: String(error?.message ?? error) } });
  }
}

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

connectPort();
