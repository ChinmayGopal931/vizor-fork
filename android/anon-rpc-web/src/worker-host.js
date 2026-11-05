// One anon-rpc worker at a time, as the host drives it: started for a specifier, asked to fetch, stopped.
import { AnonRpcWorker } from '@anon-rpc/browser-harness';
import { fromBase64, redact, toBase64 } from './bytes.js';

/** How long the one unanonymized read (the specifier's hash and resolvers) may take. */
const BOOTSTRAP_TIMEOUT_MS = 20_000;
/** The worker's last lines, kept for `status`, for a failure's explanation. */
const KEPT_LOG_LINES = 20;

/** The page's error codes, besides the protocol's `BAD_REQUEST`. */
export const codes = {
  notStarted: 'NOT_STARTED',
  workerFailed: 'WORKER_FAILED',
  timeout: 'TIMEOUT',
  fetchFailed: 'FETCH_FAILED',
};

let current;

/**
 * The one JSON-RPC read the harness makes outside the worker, to learn the worker's hash and where its bytes are:
 * `eth_call` on the specifier contract, as any public client would read it.
 */
function bootstrapProvider(url) {
  return {
    async request({ method, params }) {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(BOOTSTRAP_TIMEOUT_MS),
      });
      if (!response.ok) throw new Error(`the bootstrap RPC answered ${response.status}`);
      const { result, error } = await response.json();
      if (error) throw new Error(`the bootstrap RPC refused the read (${error.code ?? 'error'})`);
      return result;
    },
  };
}

class Host {
  constructor({ specifier, bootstrapRpcUrl, config, debug }, emit) {
    this.specifier = specifier;
    this.phase = 'starting';
    this.lastError = null;
    this.lines = [];
    this.requests = 0;
    this.failures = 0;
    this.worker = new AnonRpcWorker({
      address: specifier,
      config,
      preExisting: { rpcProvider: bootstrapProvider(bootstrapRpcUrl) },
      // The page's CSP has no 'unsafe-inline', so the harness cannot build its null-origin frame from `srcdoc`.
      iframeUrl: new URL('sandbox.html', location.href).href,
    });
    this.ready = this.worker.ready.then(
      () => {
        this.phase = 'ready';
        emit('status', this.status());
      },
      (error) => {
        this.phase = 'failed';
        this.lastError = redact(error?.message ?? error);
        emit('status', this.status());
      },
    );
    this.#pumpLogs(emit, debug);
  }

  /** The worker's log lines, redacted: kept for `status`, and sent on in a debug page. */
  async #pumpLogs(emit, debug) {
    try {
      for (;;) {
        const { level, args } = await this.worker.acceptLog();
        const text = args.map((arg) => (typeof arg === 'string' ? arg : JSON.stringify(arg))).join(' ');
        const line = `${level}: ${redact(text)}`;
        this.lines.push(line);
        if (this.lines.length > KEPT_LOG_LINES) this.lines.shift();
        if (debug) emit('log', line);
      }
    } catch {
      // The worker failed or closed, and its kept lines are drained.
    }
  }

  status() {
    return {
      phase: this.phase,
      specifier: this.specifier,
      requests: this.requests,
      failures: this.failures,
      lastError: this.lastError,
      lines: this.lines,
    };
  }

  /** `worker.fetch` as the host asks for it; failures come back as `{ ok: false, code, message }`, never thrown. */
  async fetch({ url, method, headers, bodyBase64, isolationKey, timeoutMs }) {
    this.requests += 1;
    try {
      const response = await this.worker.fetch(url, {
        method,
        headers,
        body: bodyBase64 ? fromBase64(bodyBase64) : undefined,
        signal: AbortSignal.timeout(timeoutMs),
        anonOptions: { isolationKey },
      });
      const body = new Uint8Array(await response.arrayBuffer());
      const answered = [];
      response.headers.forEach((value, name) => answered.push([name, value]));
      return { ok: true, status: response.status, headers: answered, bodyBase64: toBase64(body) };
    } catch (error) {
      this.failures += 1;
      const code =
        error?.name === 'AbortError' || error?.name === 'TimeoutError'
          ? codes.timeout
          : this.phase === 'failed'
            ? codes.workerFailed
            : codes.fetchFailed;
      return { ok: false, code, message: redact(error?.message ?? error) };
    }
  }

  close() {
    this.phase = 'idle';
    this.worker.close();
  }
}

/** Starts a worker for `specifier`, replacing one for another specifier; one for the same keeps running. */
export function start(params, emit) {
  if (typeof params?.specifier !== 'string' || typeof params?.bootstrapRpcUrl !== 'string') {
    throw badRequest('specifier and bootstrapRpcUrl are required');
  }
  if (current !== undefined && current.specifier === params.specifier && current.phase !== 'failed') {
    return current.status();
  }
  current?.close();
  current = new Host(params, emit);
  return current.status();
}

/** Waits for the worker to be ready; a worker that failed reports the failure instead. */
export async function awaitReady() {
  if (current === undefined) throw pageError(codes.notStarted, 'no worker is started');
  await current.ready;
  if (current.phase !== 'ready') throw pageError(codes.workerFailed, current.lastError ?? 'the worker failed');
  return current.status();
}

export function fetchThrough(params) {
  if (current === undefined) return { ok: false, code: codes.notStarted, message: 'no worker is started' };
  if (typeof params?.url !== 'string' || typeof params?.method !== 'string') {
    throw badRequest('url and method are required');
  }
  return current.fetch({
    url: params.url,
    method: params.method,
    headers: Array.isArray(params.headers) ? params.headers : [],
    bodyBase64: typeof params.bodyBase64 === 'string' ? params.bodyBase64 : '',
    isolationKey: typeof params.isolationKey === 'string' ? params.isolationKey : undefined,
    timeoutMs: Number.isFinite(params.timeoutMs) && params.timeoutMs > 0 ? params.timeoutMs : 60_000,
  });
}

export function status() {
  return current?.status() ?? { phase: 'idle', specifier: null, requests: 0, failures: 0, lastError: null, lines: [] };
}

export function stop() {
  current?.close();
  current = undefined;
  return null;
}

export class PageError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const pageError = (code, message) => new PageError(code, message);
const badRequest = (message) => new PageError('BAD_REQUEST', message);
