// The browser names the phone's or computer's own languages in every request's Accept-Language, to every host the
// page reaches: the RPC, rail-squid, the screening nodes, the artifact gateway and its mirror. The page has no text to
// show, so every request it makes says the same instead, on every device and every host, as Windows's host has its
// page say (WebView2's environment language, en-US). A page may set the header itself: it is CORS-safelisted for this
// value, so no request gains a preflight. Its own requests are fetch and XMLHttpRequest (axios), from the page's main
// thread only: its workers make none.

/** What every request of the page names: Chromium's header for en-US. */
export const ACCEPT_LANGUAGE = 'en-US,en;q=0.9';

const HEADER = 'accept-language';

/**
 * Has `scope`'s `fetch` and `XMLHttpRequest` send `ACCEPT_LANGUAGE` with every request that names no language of its
 * own. Runs once, before any module takes `fetch`; the hosts' archive prelude wraps the fetch this leaves.
 */
export function pinAcceptLanguage(scope = globalThis) {
  const pageFetch = scope.fetch;
  if (typeof pageFetch === 'function' && typeof scope.Headers === 'function') {
    scope.fetch = function fetch(input, init) {
      const given = init?.headers ?? (input instanceof scope.Request ? input.headers : undefined);
      const headers = new scope.Headers(given);
      if (headers.has(HEADER)) return pageFetch.call(scope, input, init);
      headers.set(HEADER, ACCEPT_LANGUAGE);
      return pageFetch.call(scope, input, { ...init, headers });
    };
  }
  const Request = scope.XMLHttpRequest;
  if (typeof Request === 'function') {
    const { open, setRequestHeader, send } = Request.prototype;
    // The requests that named their own language since they were opened.
    const named = new WeakSet();
    Request.prototype.open = function (...args) {
      named.delete(this);
      return open.apply(this, args);
    };
    Request.prototype.setRequestHeader = function (name, value) {
      if (String(name).toLowerCase() === HEADER) named.add(this);
      return setRequestHeader.call(this, name, value);
    };
    Request.prototype.send = function (...args) {
      // Only where the header may still be set: a send in any other state throws as it would have.
      if (this.readyState === Request.OPENED && !named.has(this)) setRequestHeader.call(this, HEADER, ACCEPT_LANGUAGE);
      return send.apply(this, args);
    };
  }
}
