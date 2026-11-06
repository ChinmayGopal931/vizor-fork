//! Anonymous Ethereum RPC: the one gateway every Ethereum JSON-RPC request
//! of Private USD passes through while the mode is on.
//!
//! The anonymizing itself happens in a hash-pinned anon-rpc worker
//! (<https://ethereum.github.io/anon-rpc/>) that the app's second hidden page
//! runs in the browser harness: the worker's keccak hash lives in a specifier
//! contract on chain, and the page checks the bundle against it before running
//! a byte of it. Rust never sees the worker. What Rust owns is the path to it
//! and the rule around it:
//!
//! - [`relay`] hands a request to Dart over an FRB stream and waits for the
//!   answer. The swap engine's chain reads go through it as a transport
//!   (`transport::AnonRpcTransport`), the Railgun page's provider traffic
//!   through the loopback relay below.
//! - **Fail closed.** With the mode on, a request that has no Dart subscriber,
//!   whose page is down or whose worker failed is refused as `route_blocked`,
//!   exactly like a Tor route that is still starting. Nothing here falls back
//!   to a direct connection. Off, the engine uses `RoutedHttp` as before and
//!   nothing here is called.
//! - The loopback relay ([`proxy_start`]) is a plain HTTP/1 server on
//!   `127.0.0.1` that forwards each `POST` body to the one RPC URL it was
//!   started with, through [`relay`]. The Railgun page's ethers providers
//!   point at it, so the page needs no fetch hook and keeps WebRTC deleted.
//!
//! Never log a request's URL, headers or body: the RPC URL may carry a key.

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};
use std::time::Duration;

use http::header::CONTENT_TYPE;
use http::{Method, StatusCode, Uri};
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use rand::RngCore;
use sha3::{Digest, Keccak256};
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::task::{JoinHandle, JoinSet};

use crate::api::anon_rpc::{ApiAnonRpcHeader, ApiAnonRpcRequest};
use crate::wallet::routed_http::{RoutedError, RoutedRequest, RoutedResponse};

/// How Dart receives a request. `Err` means the stream is gone.
pub(crate) type Sink = Box<dyn Fn(ApiAnonRpcRequest) -> Result<(), ()> + Send + Sync>;

/// A page's JSON-RPC body, and the engine's: ethers batches a few calls.
const MAX_RELAY_BODY: usize = 1 << 20;
/// What a relayed page request may wait: a worker still building its
/// circuit, then the request over several hops.
const RELAY_TIMEOUT: Duration = Duration::from_secs(90);
/// The page's reads can be `eth_getLogs` over the engine's window.
const MAX_RELAY_ANSWER: usize = 8 << 20;
/// The loopback relay's `connect-src` source in the Railgun page's CSP, and
/// the one `http:` origin its route table admits. Pinned by the bridge's
/// host-list test.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) const LOOPBACK_RELAY_SOURCE: &str = "http://127.0.0.1:*";

/// On by default: the saved preference, applied at startup, can only turn it
/// off. A build that never applies one anonymizes.
static ENABLED: AtomicBool = AtomicBool::new(true);
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static GATEWAY: LazyLock<Mutex<Gateway>> = LazyLock::new(Default::default);
/// Isolation keys are salted per process, so a worker that saw them could
/// not tie them to an account id, and two launches never repeat one.
static SALT: LazyLock<[u8; 32]> = LazyLock::new(|| {
    let mut salt = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut salt);
    salt
});
static PROXY: LazyLock<tokio::sync::Mutex<Option<Proxy>>> = LazyLock::new(Default::default);

type Answer = Result<RoutedResponse, RoutedError>;

#[derive(Default)]
struct Gateway {
    sink: Option<Sink>,
    pending: HashMap<u64, oneshot::Sender<Answer>>,
    relayed: u64,
    failed: u64,
}

/// The gateway as Settings shows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Stats {
    pub enabled: bool,
    pub connected: bool,
    pub pending: u64,
    pub relayed: u64,
    pub failed: u64,
}

pub(crate) fn set_enabled(enabled: bool) {
    ENABLED.store(enabled, Ordering::Release);
    log::info!("anon rpc: mode {}", if enabled { "on" } else { "off" });
}

pub(crate) fn enabled() -> bool {
    ENABLED.load(Ordering::Acquire)
}

fn gateway() -> MutexGuard<'static, Gateway> {
    GATEWAY.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Dart is listening. Whatever was pending went to a stream nobody reads now,
/// so it fails; the new subscriber starts clean.
pub(crate) fn connect(sink: Sink) {
    let mut gateway = gateway();
    fail_all(&mut gateway, "anonymous RPC reconnected");
    gateway.sink = Some(sink);
    log::info!("anon rpc: connected");
}

/// Dart stopped listening (a pause, a lock, the engine stopping): every
/// pending request fails closed, and so does every one until [`connect`].
pub(crate) fn disconnect() {
    let mut gateway = gateway();
    if gateway.sink.take().is_some() {
        log::info!("anon rpc: disconnected");
    }
    fail_all(&mut gateway, "anonymous RPC disconnected");
}

fn fail_all(gateway: &mut Gateway, message: &str) {
    for (_, sender) in gateway.pending.drain() {
        let _ = sender.send(Err(RoutedError {
            route_blocked: true,
            message: message.to_owned(),
        }));
    }
}

/// The worker's answer to request `id`. `false` for an id no one waits for
/// any more: a late answer is dropped.
pub(crate) fn respond(id: u64, status: u16, headers: Vec<ApiAnonRpcHeader>, body: Vec<u8>) -> bool {
    let sender = gateway().pending.remove(&id);
    sender.is_some_and(|sender| {
        sender
            .send(Ok(RoutedResponse {
                status,
                headers: headers
                    .into_iter()
                    .map(|header| (header.name.to_ascii_lowercase(), header.value))
                    .collect(),
                body,
            }))
            .is_ok()
    })
}

/// The worker, the page or Dart could not make request `id`. `blocked` says
/// the path is down (the page closed, the worker failed) rather than the
/// service having answered badly.
pub(crate) fn fail(id: u64, message: String, blocked: bool) -> bool {
    let sender = gateway().pending.remove(&id);
    sender.is_some_and(|sender| {
        sender
            .send(Err(RoutedError {
                route_blocked: blocked,
                message,
            }))
            .is_ok()
    })
}

pub(crate) fn stats() -> Stats {
    let gateway = gateway();
    Stats {
        enabled: enabled(),
        connected: gateway.sink.is_some(),
        pending: gateway.pending.len() as u64,
        relayed: gateway.relayed,
        failed: gateway.failed,
    }
}

/// The isolation key for `label` (an account id, or the page): calls under
/// different keys are not to be linkable, so tor-js gives each its own
/// circuits. Salted per process; the key never leaves the device.
pub(crate) fn isolation_key_for(label: &str) -> String {
    let mut hasher = Keccak256::new();
    hasher.update(*SALT);
    hasher.update(label.as_bytes());
    hex::encode(&hasher.finalize()[..16])
}

/// Sends `request` through the anon-rpc worker and waits for the answer,
/// within the request's own timeout; `cancel` stops the wait. Fails closed
/// (`route_blocked`) while nothing can carry it.
pub(crate) async fn relay(
    request: RoutedRequest,
    isolation_key: &str,
    cancel: Option<&Arc<AtomicBool>>,
) -> Answer {
    let cancelled = || cancel.is_some_and(|flag| flag.load(Ordering::Acquire));
    let failed = |message: &str| RoutedError {
        route_blocked: false,
        message: message.to_owned(),
    };
    let blocked = |message: &str| RoutedError {
        route_blocked: true,
        message: message.to_owned(),
    };
    if !enabled() {
        return Err(failed("anonymous RPC is off"));
    }
    if !matches!(request.method, Method::GET | Method::POST) {
        return Err(failed("only GET and POST are relayed"));
    }
    check_target(&request.url).map_err(|message| failed(&message))?;
    if cancelled() {
        return Err(failed("request cancelled"));
    }

    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let (sender, receiver) = oneshot::channel();
    let wire = ApiAnonRpcRequest {
        id,
        url: request.url.clone(),
        method: request.method.as_str().to_owned(),
        headers: request
            .headers
            .iter()
            .map(|(name, value)| ApiAnonRpcHeader {
                name: name.clone(),
                value: value.clone(),
            })
            .collect(),
        body: request.body.clone().unwrap_or_default(),
        isolation_key: isolation_key.to_owned(),
        timeout_ms: request.timeout.as_millis() as u64,
    };
    {
        let mut gateway = gateway();
        if gateway.sink.is_none() {
            gateway.failed += 1;
            return Err(blocked("anonymous RPC is not connected"));
        }
        // Registered before it is sent, under the lock an answer needs.
        gateway.pending.insert(id, sender);
        let delivered = gateway.sink.as_ref().map_or(Err(()), |sink| sink(wire));
        if delivered.is_err() {
            // The stream went away without a disconnect.
            gateway.sink = None;
            gateway.pending.remove(&id);
            fail_all(&mut gateway, "anonymous RPC disconnected");
            gateway.failed += 1;
            return Err(blocked("anonymous RPC disconnected"));
        }
    }

    let outcome = tokio::select! {
        biased;
        _ = crate::wallet::sync_engine::watch_for_exit(&cancelled) => Err(failed("request cancelled")),
        answer = tokio::time::timeout(request.timeout, receiver) => match answer {
            Ok(Ok(answer)) => answer,
            Ok(Err(_)) => Err(blocked("anonymous RPC dropped the request")),
            Err(_) => Err(failed("request timed out")),
        },
    };

    let mut gateway = gateway();
    // Whatever arrives from now on is late, and dropped.
    gateway.pending.remove(&id);
    match outcome {
        Ok(response) if response.body.len() > request.max_body => {
            gateway.failed += 1;
            Err(failed("answer too large"))
        }
        Ok(response) => {
            gateway.relayed += 1;
            Ok(response)
        }
        Err(error) => {
            gateway.failed += 1;
            Err(error)
        }
    }
}

/// HTTPS with a host, as `routed_http` requires: the worker's exit to the
/// service is the open network.
fn check_target(url: &str) -> Result<(), String> {
    let uri = url
        .parse::<Uri>()
        .map_err(|_| "invalid RPC URL".to_string())?;
    if uri.host().is_none() {
        return Err("RPC URL has no host".into());
    }
    match uri.scheme_str() {
        Some("https") => Ok(()),
        #[cfg(test)]
        Some("http") if matches!(uri.host(), Some("127.0.0.1" | "localhost")) => Ok(()),
        _ => Err("RPC URL must be HTTPS".into()),
    }
}

// ---- the loopback relay ----

struct Proxy {
    shutdown: oneshot::Sender<()>,
    task: JoinHandle<()>,
}

/// Starts the loopback relay towards `target_url` (the page's Ethereum RPC
/// URL: the user's own, the build's keyed one or publicnode) and returns its
/// port. A running relay is replaced: its target may have changed.
pub(crate) async fn proxy_start(target_url: String) -> Result<u16, String> {
    check_target(&target_url)?;
    let mut proxy = PROXY.lock().await;
    if let Some(running) = proxy.take() {
        shut_down(running).await;
    }
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|error| format!("Bind anon RPC relay: {error}"))?;
    let port = listener
        .local_addr()
        .map_err(|error| format!("Read anon RPC relay address: {error}"))?
        .port();
    let (shutdown, shutdown_rx) = oneshot::channel();
    let task = tokio::spawn(serve(listener, Arc::from(target_url), shutdown_rx));
    *proxy = Some(Proxy { shutdown, task });
    log::info!("anon rpc: loopback relay started");
    Ok(port)
}

/// Stops the relay and ends its connections. Idempotent.
pub(crate) async fn proxy_stop() {
    let running = PROXY.lock().await.take();
    if let Some(running) = running {
        shut_down(running).await;
        log::info!("anon rpc: loopback relay stopped");
    }
}

async fn shut_down(running: Proxy) {
    let _ = running.shutdown.send(());
    let _ = running.task.await;
}

async fn serve(listener: TcpListener, target: Arc<str>, mut shutdown: oneshot::Receiver<()>) {
    // The page's reads share one key, apart from every account's.
    let key: Arc<str> = Arc::from(isolation_key_for("railgun-page"));
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            accepted = listener.accept() => match accepted {
                Ok((stream, peer)) => {
                    if !peer.ip().is_loopback() {
                        continue;
                    }
                    let target = target.clone();
                    let key = key.clone();
                    connections.spawn(async move {
                        let service = service_fn(move |request| handle(request, target.clone(), key.clone()));
                        // Per-connection outcomes are not logged: they would record the page's activity.
                        let _ = http1::Builder::new()
                            .keep_alive(true)
                            .serve_connection(TokioIo::new(stream), service)
                            .await;
                    });
                }
                Err(error) => {
                    log::warn!("anon rpc: loopback relay accept failed: {error}");
                    break;
                }
            },
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    connections.abort_all();
    while connections.join_next().await.is_some() {}
}

async fn handle(
    request: Request<Incoming>,
    target: Arc<str>,
    key: Arc<str>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    Ok(match *request.method() {
        // The page is another origin: its browser asks first. Chromium also
        // asks before reaching a loopback address from a public page.
        Method::OPTIONS => with_cors(plain(StatusCode::NO_CONTENT, "")),
        Method::POST => with_cors(forward(request, &target, &key).await),
        _ => with_cors(plain(StatusCode::METHOD_NOT_ALLOWED, "POST only")),
    })
}

async fn forward(request: Request<Incoming>, target: &str, key: &str) -> Response<Full<Bytes>> {
    let content_type = request
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("application/json")
        .to_owned();
    let Ok(body) = Limited::new(request.into_body(), MAX_RELAY_BODY)
        .collect()
        .await
    else {
        return plain(StatusCode::PAYLOAD_TOO_LARGE, "body too large");
    };
    let routed = RoutedRequest::post(target, body.to_bytes().to_vec(), RELAY_TIMEOUT, MAX_RELAY_ANSWER)
        .header("content-type", content_type);
    match relay(routed, key, None).await {
        Ok(answer) => {
            log::info!("anon rpc: loopback relay answered {}", answer.status);
            let content_type = answer
                .header("content-type")
                .unwrap_or("application/json")
                .to_owned();
            let status = StatusCode::from_u16(answer.status).unwrap_or(StatusCode::BAD_GATEWAY);
            Response::builder()
                .status(status)
                .header(CONTENT_TYPE, content_type)
                .body(Full::new(Bytes::from(answer.body)))
                .unwrap_or_else(|_| plain(StatusCode::BAD_GATEWAY, "bad answer"))
        }
        // The text names no URL and no cause; the page only needs to fail.
        Err(error) if error.route_blocked => {
            log::info!("anon rpc: loopback relay refused: {}", loggable(&error.message));
            plain(StatusCode::SERVICE_UNAVAILABLE, "anonymous RPC unavailable")
        }
        Err(error) => {
            log::info!("anon rpc: loopback relay failed: {}", loggable(&error.message));
            plain(StatusCode::BAD_GATEWAY, "anonymous RPC failed")
        }
    }
}

/// A failure's text for the log: the codes Dart and this module write, never
/// anything that could carry a URL.
fn loggable(message: &str) -> &str {
    if message.contains("://") {
        "(redacted)"
    } else {
        message
    }
}

fn plain(status: StatusCode, body: &'static str) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, "text/plain")
        .body(Full::new(Bytes::from_static(body.as_bytes())))
        .expect("a static response builds")
}

fn with_cors(mut response: Response<Full<Bytes>>) -> Response<Full<Bytes>> {
    let headers = response.headers_mut();
    headers.insert("access-control-allow-origin", "*".parse().expect("a header value"));
    headers.insert(
        "access-control-allow-methods",
        "POST, OPTIONS".parse().expect("a header value"),
    );
    headers.insert(
        "access-control-allow-headers",
        "content-type".parse().expect("a header value"),
    );
    headers.insert(
        "access-control-allow-private-network",
        "true".parse().expect("a header value"),
    );
    headers.insert("access-control-max-age", "86400".parse().expect("a header value"));
    response
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::Duration;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;

    use super::*;

    // The gateway is process-wide, so these tests take turns.
    static TURN: Mutex<()> = Mutex::new(());

    fn take_turn() -> std::sync::MutexGuard<'static, ()> {
        let turn = TURN.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        set_enabled(true);
        disconnect();
        turn
    }

    /// A sink that hands every request to the test.
    fn capturing_sink() -> (Sink, mpsc::Receiver<ApiAnonRpcRequest>) {
        let (sender, receiver) = mpsc::channel();
        let sink: Sink = Box::new(move |request| sender.send(request).map_err(|_| ()));
        (sink, receiver)
    }

    fn get(url: &str) -> RoutedRequest {
        RoutedRequest::get(url, Duration::from_secs(5), 1024)
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn fails_closed_without_a_subscriber() {
        let _turn = take_turn();
        let before = stats();
        let error = relay(get("https://rpc.example/"), "k", None).await.unwrap_err();
        assert!(error.route_blocked, "{error:?}");
        let after = stats();
        assert_eq!(after.failed, before.failed + 1);
        assert_eq!(after.relayed, before.relayed);
        assert!(!after.connected);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_answer_reaches_its_caller_and_a_late_one_is_dropped() {
        let _turn = take_turn();
        let (sink, requests) = capturing_sink();
        connect(sink);
        let relayed = tokio::spawn(relay(
            RoutedRequest::post(
                "https://rpc.example/",
                b"{\"id\":1}".to_vec(),
                Duration::from_secs(5),
                1024,
            )
            .header("content-type", "application/json"),
            "account-key",
            None,
        ));
        let request = requests.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(request.url, "https://rpc.example/");
        assert_eq!(request.body, b"{\"id\":1}");
        assert_eq!(request.isolation_key, "account-key");
        assert_eq!(request.headers.len(), 1);
        assert!(respond(
            request.id,
            200,
            vec![ApiAnonRpcHeader {
                name: "Content-Type".into(),
                value: "application/json".into(),
            }],
            b"{\"result\":1}".to_vec(),
        ));
        let answer = relayed.await.unwrap().unwrap();
        assert_eq!(answer.status, 200);
        assert_eq!(answer.header("content-type"), Some("application/json"));
        assert_eq!(answer.body, b"{\"result\":1}");
        assert!(!respond(request.id, 200, Vec::new(), Vec::new()));
        assert!(!fail(request.id, "late".into(), false));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_disconnect_fails_what_is_pending_as_blocked() {
        let _turn = take_turn();
        let (sink, requests) = capturing_sink();
        connect(sink);
        let relayed = tokio::spawn(relay(get("https://rpc.example/"), "k", None));
        requests.recv_timeout(Duration::from_secs(5)).unwrap();
        disconnect();
        let error = relayed.await.unwrap().unwrap_err();
        assert!(error.route_blocked, "{error:?}");
        assert!(!stats().connected);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_cancel_and_an_oversize_answer_fail_the_request() {
        let _turn = take_turn();
        let (sink, requests) = capturing_sink();
        connect(sink);
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        let relayed = tokio::spawn(async move { relay(get("https://rpc.example/"), "k", Some(&flag)).await });
        let request = requests.recv_timeout(Duration::from_secs(5)).unwrap();
        cancel.store(true, Ordering::Release);
        let error = relayed.await.unwrap().unwrap_err();
        assert_eq!(error.message, "request cancelled");
        assert!(!respond(request.id, 200, Vec::new(), Vec::new()));

        let relayed = tokio::spawn(relay(get("https://rpc.example/"), "k", None));
        let request = requests.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(respond(request.id, 200, Vec::new(), vec![0; 2048]));
        let error = relayed.await.unwrap().unwrap_err();
        assert_eq!(error.message, "answer too large");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn only_https_targets_with_a_host_are_relayed() {
        let _turn = take_turn();
        let (sink, _requests) = capturing_sink();
        connect(sink);
        for url in ["http://rpc.example/", "https:///", "not a url"] {
            let error = relay(get(url), "k", None).await.unwrap_err();
            assert!(!error.route_blocked, "{url}: {error:?}");
        }
        set_enabled(false);
        let error = relay(get("https://rpc.example/"), "k", None).await.unwrap_err();
        assert_eq!(error.message, "anonymous RPC is off");
        set_enabled(true);
    }

    #[test]
    fn isolation_keys_are_per_label_and_opaque() {
        let a = isolation_key_for("account-a");
        let b = isolation_key_for("account-b");
        assert_ne!(a, b);
        assert_eq!(a, isolation_key_for("account-a"));
        assert_eq!(a.len(), 32);
        assert!(!a.contains("account"));
    }

    /// One `Connection: close` exchange: the server ends the connection after
    /// its answer. The client never half-closes first, as hyper's default
    /// treats a client EOF mid-request as the connection ending.
    async fn http(port: u16, request: &str) -> (u16, Vec<(String, String)>, Vec<u8>) {
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).await.unwrap();
        stream.write_all(request.as_bytes()).await.unwrap();
        let mut raw = Vec::new();
        tokio::time::timeout(Duration::from_secs(10), stream.read_to_end(&mut raw))
            .await
            .expect("an answer")
            .unwrap();
        let text = String::from_utf8_lossy(&raw).into_owned();
        let (head, body) = text.split_once("\r\n\r\n").expect("a header block");
        let mut lines = head.lines();
        let status: u16 = lines.next().unwrap().split_whitespace().nth(1).unwrap().parse().unwrap();
        let headers = lines
            .filter_map(|line| line.split_once(": "))
            .map(|(name, value)| (name.to_ascii_lowercase(), value.to_owned()))
            .collect();
        (status, headers, body.as_bytes().to_vec())
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_loopback_relay_forwards_posts_and_refuses_the_rest() {
        let _turn = take_turn();
        let (sink, requests) = capturing_sink();
        connect(sink);
        // Answers every relayed request off the gateway lock.
        std::thread::spawn(move || {
            while let Ok(request) = requests.recv() {
                assert_eq!(request.url, "https://rpc.example/v1");
                assert_eq!(request.method, "POST");
                assert_eq!(request.body, b"{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"eth_chainId\"}");
                assert!(request
                    .headers
                    .iter()
                    .any(|header| header.name == "content-type" && header.value == "application/json"));
                respond(
                    request.id,
                    200,
                    vec![ApiAnonRpcHeader {
                        name: "content-type".into(),
                        value: "application/json".into(),
                    }],
                    b"{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"0x1\"}".to_vec(),
                );
            }
        });
        let port = proxy_start("https://rpc.example/v1".into()).await.unwrap();

        let body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"eth_chainId\"}";
        let (status, headers, answer) = http(
            port,
            &format!(
                "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            ),
        )
        .await;
        assert_eq!(status, 200);
        assert_eq!(answer, b"{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"0x1\"}");
        assert!(headers.contains(&("access-control-allow-origin".to_owned(), "*".to_owned())));

        let (status, headers, _) = http(
            port,
            "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://railgun.appassets.androidplatform.net\r\nConnection: close\r\n\r\n",
        )
        .await;
        assert_eq!(status, 204);
        assert!(headers.contains(&("access-control-allow-private-network".to_owned(), "true".to_owned())));

        let (status, _, _) = http(port, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n").await;
        assert_eq!(status, 405);

        let oversize = "x".repeat(MAX_RELAY_BODY + 1);
        let (status, _, _) = http(
            port,
            &format!(
                "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{oversize}",
                oversize.len()
            ),
        )
        .await;
        assert_eq!(status, 413);

        disconnect();
        let (status, _, _) = http(
            port,
            &format!(
                "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            ),
        )
        .await;
        assert_eq!(status, 503, "fails closed once nothing carries the request");

        proxy_stop().await;
        assert!(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).await.is_err());
        proxy_stop().await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_relay_only_takes_an_https_target() {
        let _turn = take_turn();
        proxy_stop().await;
        assert!(proxy_start("ftp://rpc.example/".into()).await.is_err());
        assert!(PROXY.lock().await.is_none());
    }
}
