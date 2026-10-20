//! One HTTP executor for the services Private USD reaches outside
//! lightwalletd: the maker, the relayer and Ethereum RPC.
//!
//! Requests go through the voting executor, [`VizorRoute`], so each follows
//! the process route policy as it stands when the request starts: an isolated
//! Tor circuit when the user chose Tor, otherwise a direct connection held
//! under a `DirectRouteLease`, so a switch to Tor aborts it mid-flight. A Tor
//! route that is still starting is waited out within the request's own
//! deadline; one that failed or is unavailable refuses the request. Nothing
//! ever falls back to the clearnet, and nothing here retries.
//!
//! Never log a request's URL, headers or body: a keyed Ethereum RPC URL
//! carries its API key in the path, relayer requests carry the swap's ticket,
//! and a claim carries the user's secret share.

use std::{
    fmt,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};

use http::{HeaderName, HeaderValue, Method, Uri};
use tokio::time::Instant;
use zcash_voting::{RouteHttp, RouteRequest};

use crate::network_privacy;
use crate::wallet::voting::route::VizorRoute;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct RoutedError {
    /// Tor was the selected route and not usable when the request failed:
    /// starting, failed or unavailable.
    pub route_blocked: bool,
    pub message: String,
}

impl fmt::Debug for RoutedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.route_blocked {
            f.write_str("route blocked: ")?;
        }
        f.write_str(&self.message)
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

/// Redacted: the URL may hold an API key, the headers a ticket, the body a
/// secret.
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
    route: VizorRoute,
    cancel: Option<Arc<AtomicBool>>,
}

impl RoutedHttp {
    pub(crate) fn new() -> Self {
        Self {
            route: VizorRoute::new(),
            cancel: None,
        }
    }

    /// Requests stop once `cancel` is set.
    pub(crate) fn cancellable(cancel: Arc<AtomicBool>) -> Self {
        Self {
            route: VizorRoute::new(),
            cancel: Some(cancel),
        }
    }

    /// Sends `request` on the current route.
    pub(crate) async fn send(&self, request: RoutedRequest) -> Result<RoutedResponse, RoutedError> {
        let cancelled = || {
            self.cancel
                .as_ref()
                .is_some_and(|cancel| cancel.load(Ordering::Acquire))
        };
        let deadline = Instant::now() + request.timeout;
        let result = tokio::select! {
            biased;
            _ = crate::wallet::sync_engine::watch_for_exit(&cancelled) => {
                Err("request cancelled".to_string())
            }
            result = tokio::time::timeout_at(deadline, self.exchange(request, &cancelled)) => {
                result.unwrap_or_else(|_| Err("request timed out".to_string()))
            }
        };
        result.map_err(|message| RoutedError {
            // The executor fails closed while the selected route is unusable;
            // the policy, read now, tells that apart from a failing service.
            route_blocked: network_privacy::try_tor_client_for_route(false).is_err(),
            message,
        })
    }

    async fn exchange(
        &self,
        request: RoutedRequest,
        cancelled: &impl Fn() -> bool,
    ) -> Result<RoutedResponse, String> {
        if cancelled() {
            return Err("request cancelled".into());
        }
        let RoutedRequest {
            method,
            url,
            headers,
            body,
            timeout,
            max_body,
        } = request;
        if !matches!(method, Method::GET | Method::POST) {
            return Err("only GET and POST are routed".into());
        }
        require_https(&url)?;
        check_headers(&headers)?;
        let response = self
            .route
            .execute(
                RouteRequest {
                    method,
                    url: &url,
                    headers: &headers,
                    body: body.unwrap_or_default(),
                    timeout,
                    connect_timeout: None,
                    max_response_bytes: max_body,
                },
                &|| {},
            )
            .await
            .map_err(|error| error.message)?;
        Ok(RoutedResponse {
            status: response.status,
            headers: response.headers,
            body: response.body,
        })
    }
}

/// HTTPS only, on every route: Tor hides the client from the service, but the
/// exit-to-service hop is still the open network.
fn require_https(url: &str) -> Result<(), String> {
    let uri = url
        .parse::<Uri>()
        .map_err(|_| "invalid service URL".to_string())?;
    if uri.host().is_none() {
        return Err("service URL has no host".into());
    }
    match uri.scheme_str() {
        Some("https") => Ok(()),
        // Tests reach a plaintext loopback server.
        #[cfg(test)]
        Some("http") if matches!(uri.host(), Some("127.0.0.1" | "localhost")) => Ok(()),
        _ => Err("service URL must be HTTPS".into()),
    }
}

/// Header names and values a request can carry, and no `Host`: it follows the
/// URL.
fn check_headers(headers: &[(String, String)]) -> Result<(), String> {
    for (name, value) in headers {
        let name = HeaderName::from_bytes(name.as_bytes())
            .map_err(|_| "invalid request header name".to_string())?;
        if name == http::header::HOST {
            return Err("the Host header follows the URL".into());
        }
        HeaderValue::from_str(value).map_err(|_| "invalid request header value".to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;
    use std::time::Duration;

    use super::{RoutedHttp, RoutedRequest};
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
            .send(RoutedRequest::get(&url, Duration::from_millis(100), 1024))
            .await
            .unwrap_err();
        assert!(bootstrapping.route_blocked, "{bootstrapping:?}");
        assert!(started.elapsed() < Duration::from_secs(2));

        network_privacy::fail_tor_enable();
        let failed = http
            .send(RoutedRequest::post(
                &url,
                b"{}".to_vec(),
                Duration::from_secs(5),
                1024,
            ))
            .await
            .unwrap_err();
        assert!(failed.route_blocked, "{failed:?}");

        listener.set_nonblocking(true).unwrap();
        assert!(listener.accept().is_err(), "a request reached the clearnet");
    }
}
