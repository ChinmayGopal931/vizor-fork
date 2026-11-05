//! Anonymous Ethereum RPC: Dart's end of the gateway in `crate::anon_rpc`.
//!
//! Rust asks, Dart answers. [`anon_rpc_requests`] is the stream of requests
//! the engine and the Railgun page's loopback relay want made through the
//! anon-rpc worker; Dart makes each through the worker's page and answers
//! with [`anon_rpc_respond`] or [`anon_rpc_fail`]. While no stream is open
//! Rust fails every request closed.
//!
//! Never log a request: its URL may carry an RPC key.

use std::fmt;

use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;

pub struct ApiAnonRpcHeader {
    pub name: String,
    pub value: String,
}

/// One request to make through the worker: `fetch(url, {method, headers,
/// body, anonOptions: {isolationKey}})`, within `timeout_ms`.
pub struct ApiAnonRpcRequest {
    pub id: u64,
    /// May carry an RPC key. Never log it.
    pub url: String,
    /// `GET` or `POST`.
    pub method: String,
    pub headers: Vec<ApiAnonRpcHeader>,
    pub body: Vec<u8>,
    /// Calls under different keys are not to be linkable (anon-rpc §9.3).
    pub isolation_key: String,
    pub timeout_ms: u64,
}

/// Redacted: the URL may carry a key, the body is the page's activity.
impl fmt::Debug for ApiAnonRpcRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApiAnonRpcRequest")
            .field("id", &self.id)
            .field("method", &self.method)
            .field("body_bytes", &self.body.len())
            .finish_non_exhaustive()
    }
}

pub struct ApiAnonRpcStats {
    /// The mode: on anonymizes every Ethereum request and fails closed
    /// without a worker; off is the routed connection as before.
    pub enabled: bool,
    /// Whether Dart is listening on the request stream.
    pub connected: bool,
    pub pending: u64,
    pub relayed: u64,
    pub failed: u64,
}

/// Applies the saved preference. On by default; apply off before the engine's
/// first request only when the user chose it.
#[frb(sync)]
pub fn anon_rpc_set_enabled(enabled: bool) {
    crate::anon_rpc::set_enabled(enabled);
}

#[frb(sync)]
pub fn anon_rpc_enabled() -> bool {
    crate::anon_rpc::enabled()
}

/// The requests to make through the worker. One listener at a time: a new
/// one fails whatever the previous one left pending. Cancelling the stream
/// without [`anon_rpc_disconnect`] is noticed at the next request.
pub fn anon_rpc_requests(sink: StreamSink<ApiAnonRpcRequest>) {
    crate::anon_rpc::connect(Box::new(move |request| sink.add(request).map_err(|_| ())));
}

/// Stops listening: every pending request fails closed at once, and so does
/// every one until the next [`anon_rpc_requests`].
#[frb(sync)]
pub fn anon_rpc_disconnect() {
    crate::anon_rpc::disconnect();
}

/// The worker's answer to request `id`. `false` when nothing waits for it.
#[frb(sync)]
pub fn anon_rpc_respond(id: u64, status: u16, headers: Vec<ApiAnonRpcHeader>, body: Vec<u8>) -> bool {
    crate::anon_rpc::respond(id, status, headers, body)
}

/// Request `id` could not be made. `blocked` for a path that is down (the
/// page closed, the worker not ready or failed), which the engine treats as
/// a route problem to wait out; false for a bad answer. `message` names no
/// URL.
#[frb(sync)]
pub fn anon_rpc_fail(id: u64, message: String, blocked: bool) -> bool {
    crate::anon_rpc::fail(id, message, blocked)
}

/// Starts the loopback JSON-RPC relay the Railgun page's providers point at
/// (`http://127.0.0.1:<port>/`), towards `target_url`: the page's Ethereum
/// RPC URL. Replaces a running relay. The URL may carry a key.
pub async fn anon_rpc_proxy_start(target_url: String) -> Result<u16, String> {
    crate::anon_rpc::proxy_start(target_url).await
}

/// Stops the relay. Idempotent.
pub async fn anon_rpc_proxy_stop() {
    crate::anon_rpc::proxy_stop().await;
}

#[frb(sync)]
pub fn anon_rpc_stats() -> ApiAnonRpcStats {
    let stats = crate::anon_rpc::stats();
    ApiAnonRpcStats {
        enabled: stats.enabled,
        connected: stats.connected,
        pending: stats.pending,
        relayed: stats.relayed,
        failed: stats.failed,
    }
}
