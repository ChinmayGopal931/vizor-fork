//! One HTTP executor for the services the wallet reaches outside lightwalletd
//! (Private USD's maker, relayer, token issuer and Ethereum RPC).
//!
//! Every request follows the process route policy (`crate::network_privacy`)
//! as it stands when the request starts: an isolated Tor circuit when the user
//! chose Tor, otherwise a direct connection held under a `DirectRouteLease`,
//! so a switch to Tor aborts it mid-flight. A Tor route that is still starting
//! is waited out within the request's own deadline; one that failed or is
//! unavailable refuses the request. Nothing ever falls back to the clearnet.
//!
//! Nothing here retries. A POST that may have landed (an accept, a relayer
//! request) is the caller's to reason about, through [`RoutedError::phase`].
//!
//! Generalized from the Enhance PIR transport
//! (`sync_engine/enhancement/transport/mod.rs`): arbitrary request headers,
//! response headers, non-2xx bodies and a dispatch phase on every error.
//!
//! Never log a request's URL, headers or body: a keyed Ethereum RPC URL
//! carries its API key in the path, relayer requests carry the swap's ticket,
//! and a claim carries the user's secret share.

use std::{
    fmt,
    sync::atomic::{AtomicU8, Ordering},
    time::Duration,
};

use bytes::Bytes;
use http::{HeaderName, HeaderValue, Method, Request, Uri};
use http_body_util::{BodyExt, Full};
use hyper::body::Body;
use hyper_rustls::HttpsConnectorBuilder;
use hyper_util::{client::legacy::Client, rt::TokioExecutor};
use tokio::time::Instant;

use crate::network_privacy;
use crate::wallet::sync_engine::DirectRouteConnector;

type DirectClient = Client<hyper_rustls::HttpsConnector<DirectRouteConnector>, Full<Bytes>>;

/// How far a request got, recorded as it goes so a failure reports its phase.
const STAGE_ROUTING: u8 = 0;
const STAGE_DISPATCHED: u8 = 1;
const STAGE_ANSWERED: u8 = 2;

/// Where a failed request stood: whether the service may have received it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RoutedPhase {
    /// Nothing left the device: no usable route, a refused connection or
    /// handshake, an invalid request, or cancelled before dispatch.
    BeforeDispatch,
    /// The request may have reached the service: a failure, timeout or
    /// cancellation once it was handed to the connection.
    AfterDispatch,
    /// The service answered, but its body could not be read in full.
    ResponseRead,
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct RoutedError {
    pub phase: RoutedPhase,
    pub message: String,
}

impl RoutedError {
    fn before(message: impl Into<String>) -> Self {
        Self {
            phase: RoutedPhase::BeforeDispatch,
            message: message.into(),
        }
    }

    fn after(message: impl Into<String>) -> Self {
        Self {
            phase: RoutedPhase::AfterDispatch,
            message: message.into(),
        }
    }

    fn response_read(message: impl Into<String>) -> Self {
        Self {
            phase: RoutedPhase::ResponseRead,
            message: message.into(),
        }
    }

    /// The error for a request that stopped at `stage`.
    fn at(stage: u8, message: impl Into<String>) -> Self {
        match stage {
            STAGE_ROUTING => Self::before(message),
            STAGE_DISPATCHED => Self::after(message),
            _ => Self::response_read(message),
        }
    }
}

impl fmt::Debug for RoutedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.phase, self.message)
    }
}

impl fmt::Display for RoutedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

/// One request. `timeout` covers route selection, the request and the whole
/// body; `max_body` bounds the body of every status.
#[derive(Clone)]
pub(crate) struct RoutedRequest {
    pub method: Method,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub timeout: Duration,
    pub max_body: usize,
}

impl RoutedRequest {
    pub(crate) fn get(url: impl Into<String>, timeout: Duration, max_body: usize) -> Self {
        Self {
            method: Method::GET,
            url: url.into(),
            headers: Vec::new(),
            body: None,
            timeout,
            max_body,
        }
    }

    pub(crate) fn post(
        url: impl Into<String>,
        body: Vec<u8>,
        timeout: Duration,
        max_body: usize,
    ) -> Self {
        Self {
            method: Method::POST,
            url: url.into(),
            headers: Vec::new(),
            body: Some(body),
            timeout,
            max_body,
        }
    }

    pub(crate) fn header(mut self, name: &str, value: impl Into<String>) -> Self {
        self.headers.push((name.to_owned(), value.into()));
        self
    }
}

/// Redacted: the URL may hold an API key, the headers a ticket, the body a secret.
impl fmt::Debug for RoutedRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RoutedRequest")
            .field("method", &self.method)
            .field("timeout", &self.timeout)
            .finish_non_exhaustive()
    }
}

/// An answer of any status, with its headers (names lowercase) and body.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct RoutedResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl RoutedResponse {
    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    pub(crate) fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

impl fmt::Debug for RoutedResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RoutedResponse")
            .field("status", &self.status)
            .field("body_bytes", &self.body.len())
            .finish_non_exhaustive()
    }
}

/// The executor. Its direct connections are pooled for its lifetime, so keep
/// one per operation, not per process: pooled connections stay governed by
/// their route lease, and the route is re-checked on every request.
pub(crate) struct RoutedHttp {
    direct: DirectClient,
}

impl RoutedHttp {
    pub(crate) fn new() -> Self {
        // Both rustls providers are compiled in, so none is the default until
        // one is installed. A routed request can be the process's first TLS
        // use, and unit tests never run `init_app`.
        static RUSTLS_INIT: std::sync::Once = std::sync::Once::new();
        RUSTLS_INIT.call_once(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
        });
        let builder = HttpsConnectorBuilder::new().with_webpki_roots();
        #[cfg(not(test))]
        let builder = builder.https_only();
        // Tests reach a plaintext loopback server; `endpoint_uri` admits
        // nothing else.
        #[cfg(test)]
        let builder = builder.https_or_http();
        let connector = builder
            .enable_http1()
            .wrap_connector(DirectRouteConnector::new());
        Self {
            // Cheap: nothing connects until the first direct request.
            direct: Client::builder(TokioExecutor::new()).build(connector),
        }
    }

    /// Sends `request` on the current route. Every failure says whether the
    /// service may have received it; `cancelled` stops the request.
    pub(crate) async fn send(
        &self,
        request: RoutedRequest,
        cancelled: impl Fn() -> bool,
    ) -> Result<RoutedResponse, RoutedError> {
        let stage = AtomicU8::new(STAGE_ROUTING);
        let deadline = Instant::now() + request.timeout;
        let exchange = self.exchange(request, &cancelled, &stage);
        tokio::pin!(exchange);
        tokio::select! {
            biased;
            _ = crate::wallet::sync_engine::watch_for_exit(&cancelled) => {
                Err(RoutedError::at(stage.load(Ordering::Acquire), "request cancelled"))
            }
            result = tokio::time::timeout_at(deadline, &mut exchange) => {
                result.unwrap_or_else(|_| {
                    let stage = stage.load(Ordering::Acquire);
                    Err(RoutedError::at(
                        stage,
                        if stage == STAGE_ROUTING {
                            "network route was not ready before the request deadline"
                        } else {
                            "request timed out"
                        },
                    ))
                })
            }
        }
    }

    async fn exchange(
        &self,
        request: RoutedRequest,
        cancelled: &impl Fn() -> bool,
        stage: &AtomicU8,
    ) -> Result<RoutedResponse, RoutedError> {
        if cancelled() {
            return Err(RoutedError::before("request cancelled"));
        }
        if !matches!(request.method, Method::GET | Method::POST) {
            return Err(RoutedError::before("only GET and POST are routed"));
        }
        let uri = endpoint_uri(&request.url)?;
        let headers = parse_headers(&request.headers)?;
        let body = Bytes::from(request.body.unwrap_or_default());
        // Re-checked per request: a route that changed since the last request
        // decides this one, and nothing falls back to direct.
        let route = network_privacy::tor_client_for_route(true, cancelled)
            .await
            .map_err(|error| RoutedError::before(format!("network route blocked: {error}")))?;
        let response = match route {
            Some(tor) => over_tor(&tor, request.method, uri, headers, body, stage).await?,
            None => {
                let mut builder = Request::builder().method(request.method).uri(uri);
                for (name, value) in headers {
                    builder = builder.header(name, value);
                }
                let request = builder
                    .body(Full::new(body))
                    .map_err(|error| RoutedError::before(format!("invalid request: {error}")))?;
                // The pooled client fuses connecting with sending, so from
                // here only a connect error proves nothing was sent.
                stage.store(STAGE_DISPATCHED, Ordering::Release);
                self.direct.request(request).await.map_err(|error| {
                    if error.is_connect() {
                        RoutedError::before(format!("could not connect: {error}"))
                    } else {
                        RoutedError::after(format!("request failed: {error}"))
                    }
                })?
            }
        };
        stage.store(STAGE_ANSWERED, Ordering::Release);
        read_response(response, request.max_body).await
    }
}

/// HTTPS only, on every route: Tor hides the client from the service, but the
/// exit-to-service hop is still the open network.
fn endpoint_uri(url: &str) -> Result<Uri, RoutedError> {
    let uri = url
        .parse::<Uri>()
        .map_err(|_| RoutedError::before("invalid service URL"))?;
    if uri.host().is_none() {
        return Err(RoutedError::before("service URL has no host"));
    }
    match uri.scheme_str() {
        Some("https") => Ok(uri),
        #[cfg(test)]
        Some("http") if matches!(uri.host(), Some("127.0.0.1" | "localhost")) => Ok(uri),
        _ => Err(RoutedError::before("service URL must be HTTPS")),
    }
}

fn parse_headers(
    headers: &[(String, String)],
) -> Result<Vec<(HeaderName, HeaderValue)>, RoutedError> {
    headers
        .iter()
        .map(|(name, value)| {
            let name = HeaderName::from_bytes(name.as_bytes())
                .map_err(|_| RoutedError::before("invalid request header name"))?;
            if name == http::header::HOST {
                return Err(RoutedError::before("the Host header follows the URL"));
            }
            let value = HeaderValue::from_str(value)
                .map_err(|_| RoutedError::before("invalid request header value"))?;
            Ok((name, value))
        })
        .collect()
}

async fn over_tor(
    tor: &zcash_client_backend::tor::Client,
    method: Method,
    uri: Uri,
    headers: Vec<(HeaderName, HeaderValue)>,
    body: Bytes,
    stage: &AtomicU8,
) -> Result<http::Response<hyper::body::Incoming>, RoutedError> {
    // librustzcash calls this only once the circuit, the TLS handshake and the
    // HTTP handshake are up, immediately before it builds and sends the
    // request: until it runs, nothing has left the device.
    let apply = |mut builder: http::request::Builder| {
        for (name, value) in &headers {
            builder = builder.header(name, value);
        }
        stage.store(STAGE_DISPATCHED, Ordering::Release);
        builder
    };
    // Returning the body unread exposes the status and headers of every answer;
    // `read_response` bounds the body.
    let parse = |incoming: hyper::body::Incoming| async move {
        Ok::<_, zcash_client_backend::tor::Error>(incoming)
    };
    // Retries are the caller's decision: ask arti for none.
    let result = if method == Method::POST {
        tor.http_post(uri, apply, Full::new(body), parse, 0, |_| None)
            .await
    } else {
        tor.http_get(uri, apply, parse, 0, |_| None).await
    };
    result.map_err(|error| classify_tor_error(error, stage.load(Ordering::Acquire)))
}

/// Separates Tor failures that prove nothing was sent from those that may
/// follow the request, as voting's `VizorRoute` does; a failure before the
/// header callback ran is always pre-dispatch.
fn classify_tor_error(error: zcash_client_backend::tor::Error, stage: u8) -> RoutedError {
    use zcash_client_backend::tor::{
        http::{HttpError, TimeoutPhase},
        Error,
    };

    let definitely_unsent = stage == STAGE_ROUTING
        || matches!(
            &error,
            Error::MissingTorDirectory
                | Error::Tor(_)
                | Error::Http(
                    HttpError::NonHttpUrl
                        | HttpError::Http(_)
                        | HttpError::Spawn(_)
                        | HttpError::Tls(_)
                        | HttpError::Timeout(TimeoutPhase::Connect),
                )
        );
    let message = format!("Tor request failed: {error}");
    if definitely_unsent {
        RoutedError::before(message)
    } else {
        RoutedError::after(message)
    }
}

async fn read_response<B>(
    response: http::Response<B>,
    max_body: usize,
) -> Result<RoutedResponse, RoutedError>
where
    B: Body<Data = Bytes> + Unpin,
    B::Error: fmt::Display,
{
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|value| (name.as_str().to_owned(), value.to_owned()))
        })
        .collect();
    let mut body = response.into_body();
    let mut bytes = Vec::new();
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|error| {
            RoutedError::response_read(format!("HTTP {status} body failed: {error}"))
        })?;
        if let Ok(data) = frame.into_data() {
            if bytes.len().saturating_add(data.len()) > max_body {
                return Err(RoutedError::response_read(format!(
                    "HTTP {status} body exceeded {max_body} bytes"
                )));
            }
            bytes.extend_from_slice(&data);
        }
    }
    Ok(RoutedResponse {
        status,
        headers,
        body: bytes,
    })
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;
    use std::time::Duration;

    use super::{RoutedHttp, RoutedPhase, RoutedRequest};
    use crate::network_privacy::{self, test_route_policy::lock_route_policy};

    /// A Tor route that is still starting, or that failed, refuses the
    /// request before anything is sent, and never reaches the clearnet.
    #[tokio::test]
    async fn fails_closed_before_dispatch_while_tor_is_not_ready() {
        let _policy = lock_route_policy();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/v1/info", listener.local_addr().unwrap());
        let http = RoutedHttp::new();

        network_privacy::begin_tor_enable();
        let started = std::time::Instant::now();
        let bootstrapping = http
            .send(
                RoutedRequest::get(&url, Duration::from_millis(100), 1024),
                || false,
            )
            .await
            .unwrap_err();
        assert_eq!(
            bootstrapping.phase,
            RoutedPhase::BeforeDispatch,
            "{bootstrapping:?}"
        );
        assert!(started.elapsed() < Duration::from_secs(2));

        network_privacy::fail_tor_enable();
        let failed = http
            .send(
                RoutedRequest::post(&url, b"{}".to_vec(), Duration::from_secs(5), 1024),
                || false,
            )
            .await
            .unwrap_err();
        assert_eq!(failed.phase, RoutedPhase::BeforeDispatch, "{failed:?}");

        listener.set_nonblocking(true).unwrap();
        assert!(listener.accept().is_err(), "a request reached the clearnet");
    }
}
