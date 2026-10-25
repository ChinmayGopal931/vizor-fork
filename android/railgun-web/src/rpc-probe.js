// What a sync's failure says about the Ethereum RPC, asked of the network after the fact. The engine swallows its
// provider's errors and reports a scan as incomplete or stuck, which says nothing about which service failed; the
// host tells the user to try another RPC only when the RPC is the one at fault.
import { RailgunError } from './errors.js';

/** How long each probe waits for an answer. */
export const PROBE_TIMEOUT_MS = 10_000;

const BLOCK_NUMBER = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_blockNumber', params: [] });

/** The HTTP status `url` answers a POST of `body` with, or null when nothing answers in time. */
async function status(fetch, url, body, timeoutMs) {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body,
      signal: abort.signal,
    });
    return response.status;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * A failed sync's `cause` as the host should see it: an `RPC_FAILED` error when the first RPC URL turns requests
 * away (403 or 429: rate limited) or does not answer `eth_blockNumber` with 200 while a screening node still
 * answers, so the connection carries; `cause` itself otherwise, the connection or the engine being at fault, or
 * nothing to compare the RPC against. The message never carries a URL: the RPC's can hold a key.
 */
export async function syncFailure(
  cause,
  { rpcUrls, poiNodeUrls, fetch = globalThis.fetch, timeoutMs = PROBE_TIMEOUT_MS },
) {
  const rpc = rpcUrls?.[0];
  if (rpc === undefined) return cause;
  const rpcStatus = await status(fetch, rpc, BLOCK_NUMBER, timeoutMs);
  if (rpcStatus === 200) return cause;
  const reason = rpcStatus === null ? 'does not answer' : `answers ${rpcStatus}`;
  if (rpcStatus === 403 || rpcStatus === 429) return rpcFailed(reason, cause);
  const poi = poiNodeUrls?.[0];
  if (poi === undefined || (await status(fetch, poi, '{}', timeoutMs)) === null) return cause;
  return rpcFailed(reason, cause);
}

const rpcFailed = (reason, cause) =>
  new RailgunError('RPC_FAILED', `the Ethereum RPC ${reason}: ${cause?.message ?? cause}`);
