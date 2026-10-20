//! The engine's HTTP seam and the swap services' JSON exchange.
//!
//! The maker, relayer and Ethereum clients send through [`HttpTransport`];
//! [`RoutedTransport`] is the real one, over `crate::wallet::routed_http`, so
//! every request follows the route policy and fails closed on Tor. Engine
//! fakes (M5, M6) implement the trait. It is used through generics, never
//! `dyn`.
//!
//! A swap service's failure is a [`SwapHttpError`]: no answer, an answer that
//! does not read, or a refusal. Branch on the code and status, never on the
//! service's text, and use [`SwapHttpError::may_have_sent`] to tell a refused
//! request from one that may have landed.

use std::fmt;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

use serde::{de::DeserializeOwned, Deserialize, Serialize};

use super::deployment::{MAX_SERVICE_BODY, QUICK_TIMEOUT};
use super::{ErrorCode, PrivateUsdError};
use crate::wallet::routed_http::{
    RoutedError, RoutedHttp, RoutedPhase, RoutedRequest, RoutedResponse,
};

/// How much of an error body that is not zecSwap's JSON a refusal keeps.
const ERROR_EXCERPT_CHARS: usize = 200;

pub(crate) trait HttpTransport {
    async fn send(&self, request: RoutedRequest) -> Result<RoutedResponse, RoutedError>;
}

/// The real transport. Make one per operation: its direct connections are
/// pooled for its lifetime.
pub(crate) struct RoutedTransport {
    http: RoutedHttp,
    cancel: Option<Arc<AtomicBool>>,
}

impl RoutedTransport {
    pub(crate) fn new() -> Self {
        Self {
            http: RoutedHttp::new(),
            cancel: None,
        }
    }

    /// Requests stop once `cancel` is set.
    pub(crate) fn cancellable(cancel: Arc<AtomicBool>) -> Self {
        Self {
            http: RoutedHttp::new(),
            cancel: Some(cancel),
        }
    }
}

impl HttpTransport for RoutedTransport {
    async fn send(&self, request: RoutedRequest) -> Result<RoutedResponse, RoutedError> {
        let cancel = self.cancel.clone();
        self.http
            .send(request, move || {
                cancel
                    .as_ref()
                    .is_some_and(|cancel| cancel.load(Ordering::Acquire))
            })
            .await
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Service {
    Maker,
    Relayer,
}

impl Service {
    fn label(self) -> &'static str {
        match self {
            Self::Maker => "maker",
            Self::Relayer => "relayer",
        }
    }
}

/// zecSwap's error codes (`zapi/service.rs`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SwapErrorCode {
    InvalidRequest,
    Rejected,
    UnknownQuote,
    UnknownSwap,
    Unavailable,
    WatchtowerUnavailable,
    Internal,
    NotFound,
    MethodNotAllowed,
    /// A note the transaction spends is spent on chain, or by a transaction
    /// the relayer already sent.
    AlreadySpent,
    /// Spend a token from the issuer the `WWW-Authenticate` challenge names.
    TokenRequired,
    /// A deposit's authorization is used, or another deposit of the same
    /// address is on its way (`409`, M9).
    Conflict,
}

impl SwapErrorCode {
    /// The code a service named, or `None` for one this build does not know.
    fn named(name: &str) -> Option<Self> {
        Some(match name {
            "invalidRequest" => Self::InvalidRequest,
            "rejected" => Self::Rejected,
            "unknownQuote" => Self::UnknownQuote,
            "unknownSwap" => Self::UnknownSwap,
            "unavailable" => Self::Unavailable,
            "watchtowerUnavailable" => Self::WatchtowerUnavailable,
            "internal" => Self::Internal,
            "notFound" => Self::NotFound,
            "methodNotAllowed" => Self::MethodNotAllowed,
            "alreadySpent" => Self::AlreadySpent,
            "tokenRequired" => Self::TokenRequired,
            "conflict" => Self::Conflict,
            _ => return None,
        })
    }
}

/// A non-2xx answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Refusal {
    pub service: Service,
    pub status: u16,
    /// `None` when the service sent no code this build knows.
    pub code: Option<SwapErrorCode>,
    /// The service's `error`, or an excerpt of a body that is not its JSON.
    pub reason: String,
    /// Transactions the refusal names (`409 alreadySpent`).
    pub transactions: Vec<[u8; 32]>,
    /// How long the service asked to wait (`Retry-After` delay-seconds).
    pub retry_after_secs: Option<u64>,
    /// RFC 9577's challenge, on a refusal a token would pay for.
    pub challenge: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SwapHttpError {
    /// No answer.
    Unreachable {
        service: Service,
        phase: RoutedPhase,
        message: String,
    },
    /// A success that does not read or fails its checks: the service did act
    /// on the request.
    Unreadable {
        service: Service,
        message: String,
    },
    Refused(Refusal),
}

impl SwapHttpError {
    pub(crate) fn service(&self) -> Service {
        match self {
            Self::Unreachable { service, .. } | Self::Unreadable { service, .. } => *service,
            Self::Refused(refusal) => refusal.service,
        }
    }

    /// Whether the service can have acted on the request. A refusal below
    /// 500 and a failure before dispatch sent nothing; a failure after
    /// dispatch, a 5xx or a success that does not read may have.
    pub(crate) fn may_have_sent(&self) -> bool {
        match self {
            Self::Unreachable { phase, .. } => *phase != RoutedPhase::BeforeDispatch,
            Self::Unreadable { .. } => true,
            Self::Refused(refusal) => refusal.status >= 500,
        }
    }

    /// The refusal's code, if the service refused.
    pub(crate) fn code(&self) -> Option<SwapErrorCode> {
        match self {
            Self::Refused(refusal) => refusal.code,
            _ => None,
        }
    }
}

impl fmt::Display for SwapHttpError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unreachable {
                service, message, ..
            } => write!(f, "the {} is unreachable: {message}", service.label()),
            Self::Unreadable { service, message } => {
                write!(
                    f,
                    "the {} sent an unreadable answer: {message}",
                    service.label()
                )
            }
            Self::Refused(refusal) => write!(
                f,
                "the {} answered {}: {}",
                refusal.service.label(),
                refusal.status,
                refusal.reason
            ),
        }
    }
}

/// The step's problem when nothing more specific applies; the engine (M5,
/// M6) maps codes per step.
impl From<SwapHttpError> for PrivateUsdError {
    fn from(error: SwapHttpError) -> Self {
        let code = match (&error, error.service()) {
            (SwapHttpError::Refused(refusal), Service::Maker) => match refusal.code {
                Some(SwapErrorCode::Unavailable | SwapErrorCode::WatchtowerUnavailable) => {
                    ErrorCode::MakerBusy
                }
                Some(SwapErrorCode::UnknownQuote) => ErrorCode::QuoteExpired,
                Some(SwapErrorCode::TokenRequired) => ErrorCode::TokensNeeded,
                _ => ErrorCode::MakerUnavailable,
            },
            (SwapHttpError::Refused(_), Service::Relayer) => ErrorCode::RelayerRefused,
            (_, Service::Maker) => ErrorCode::MakerUnavailable,
            (_, Service::Relayer) => ErrorCode::RelayerUnreachable,
        };
        PrivateUsdError::new(code, error.to_string())
    }
}

/// A swap service's error body: `{code, error, transactions?}`. The code stays
/// a string, so one this build does not know still leaves the reason.
#[derive(Deserialize)]
struct ServiceError {
    code: Option<String>,
    error: Option<String>,
    transactions: Option<Vec<String>>,
}

/// `GET url`, read as `T` once `check` accepts it.
pub(crate) async fn get_json<T: HttpTransport, R: DeserializeOwned>(
    transport: &T,
    service: Service,
    url: String,
    check: impl FnOnce(&R) -> Result<(), String>,
) -> Result<R, SwapHttpError> {
    let request = RoutedRequest::get(url, QUICK_TIMEOUT, MAX_SERVICE_BODY)
        .header("accept", "application/json");
    exchange(transport, service, request, check).await
}

/// `POST url` with `body` as JSON and the given extra headers.
pub(crate) async fn post_json<T: HttpTransport, B: Serialize, R: DeserializeOwned>(
    transport: &T,
    service: Service,
    url: String,
    body: &B,
    timeout: Duration,
    headers: &[(&str, &str)],
    check: impl FnOnce(&R) -> Result<(), String>,
) -> Result<R, SwapHttpError> {
    let body = serde_json::to_vec(body).map_err(|error| SwapHttpError::Unreachable {
        service,
        phase: RoutedPhase::BeforeDispatch,
        message: format!("could not encode the request: {error}"),
    })?;
    let mut request = RoutedRequest::post(url, body, timeout, MAX_SERVICE_BODY)
        .header("content-type", "application/json")
        .header("accept", "application/json");
    for (name, value) in headers {
        request = request.header(name, *value);
    }
    exchange(transport, service, request, check).await
}

async fn exchange<T: HttpTransport, R: DeserializeOwned>(
    transport: &T,
    service: Service,
    request: RoutedRequest,
    check: impl FnOnce(&R) -> Result<(), String>,
) -> Result<R, SwapHttpError> {
    let response = transport
        .send(request)
        .await
        .map_err(|error| SwapHttpError::Unreachable {
            service,
            phase: error.phase,
            message: error.message,
        })?;
    if !response.is_success() {
        return Err(SwapHttpError::Refused(refusal(service, &response)));
    }
    let answer: R =
        serde_json::from_slice(&response.body).map_err(|error| SwapHttpError::Unreadable {
            service,
            message: error.to_string(),
        })?;
    check(&answer).map_err(|message| SwapHttpError::Unreadable { service, message })?;
    Ok(answer)
}

fn refusal(service: Service, response: &RoutedResponse) -> Refusal {
    let error = serde_json::from_slice::<ServiceError>(&response.body).ok();
    let reason = error
        .as_ref()
        .and_then(|error| error.error.clone())
        .unwrap_or_else(|| {
            String::from_utf8_lossy(&response.body)
                .chars()
                .take(ERROR_EXCERPT_CHARS)
                .collect()
        });
    let code = error
        .as_ref()
        .and_then(|error| error.code.as_deref())
        .and_then(SwapErrorCode::named);
    let transactions = error
        .and_then(|error| error.transactions)
        .unwrap_or_default()
        .iter()
        .filter_map(|hash| super::models::Word::parse(hash).map(|hash| hash.0))
        .collect();
    Refusal {
        service,
        status: response.status,
        code,
        reason,
        transactions,
        retry_after_secs: response.header("retry-after").and_then(delay_seconds),
        challenge: response.header("www-authenticate").map(str::to_owned),
    }
}

/// RFC 9110's delay-seconds; an HTTP-date reads as no wait asked for.
fn delay_seconds(value: &str) -> Option<u64> {
    value.trim().parse().ok()
}

#[cfg(test)]
pub(crate) mod test_support {
    //! A loopback HTTP server for client tests, and a scripted transport.

    use std::cell::RefCell;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use super::HttpTransport;
    use crate::wallet::routed_http::{RoutedError, RoutedRequest, RoutedResponse};

    /// What the server does with one connection.
    pub(crate) enum Reply {
        /// Answers with this status, these headers and this body.
        Http {
            status: u16,
            headers: Vec<(&'static str, String)>,
            body: String,
        },
        /// Reads the request and closes the connection without answering.
        Hangup,
    }

    impl Reply {
        pub(crate) fn json(status: u16, body: &str) -> Self {
            Self::Http {
                status,
                headers: vec![("content-type", "application/json".into())],
                body: body.into(),
            }
        }
    }

    /// A request as the server received it.
    #[derive(Clone, Debug)]
    pub(crate) struct Received {
        pub method: String,
        pub path: String,
        pub headers: Vec<(String, String)>,
        pub body: Vec<u8>,
    }

    impl Received {
        pub(crate) fn header(&self, name: &str) -> Option<&str> {
            self.headers
                .iter()
                .find(|(key, _)| key.eq_ignore_ascii_case(name))
                .map(|(_, value)| value.as_str())
        }
    }

    /// Serves `replies` in order, one per connection, then stops.
    pub(crate) struct TestServer {
        pub url: String,
        received: Arc<Mutex<Vec<Received>>>,
    }

    impl TestServer {
        pub(crate) fn start(replies: Vec<Reply>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            let received = Arc::new(Mutex::new(Vec::new()));
            let log = received.clone();
            std::thread::spawn(move || {
                for reply in replies {
                    let deadline = Instant::now() + Duration::from_secs(10);
                    let mut stream = loop {
                        match listener.accept() {
                            Ok((stream, _)) => break stream,
                            Err(_) if Instant::now() < deadline => {
                                std::thread::sleep(Duration::from_millis(5))
                            }
                            Err(_) => return,
                        }
                    };
                    stream.set_nonblocking(false).unwrap();
                    let Some(request) = read_request(&mut stream) else {
                        continue;
                    };
                    log.lock().unwrap().push(request);
                    if let Reply::Http {
                        status,
                        headers,
                        body,
                    } = reply
                    {
                        let mut head = format!(
                            "HTTP/1.1 {status} X\r\ncontent-length: {}\r\nconnection: close\r\n",
                            body.len()
                        );
                        for (name, value) in headers {
                            head.push_str(&format!("{name}: {value}\r\n"));
                        }
                        head.push_str("\r\n");
                        let _ = stream.write_all(head.as_bytes());
                        let _ = stream.write_all(body.as_bytes());
                    }
                }
            });
            Self { url, received }
        }

        pub(crate) fn received(&self) -> Vec<Received> {
            self.received.lock().unwrap().clone()
        }
    }

    fn read_request(stream: &mut std::net::TcpStream) -> Option<Received> {
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .ok()?;
        let mut data = Vec::new();
        let mut chunk = [0u8; 4096];
        let head_end = loop {
            if let Some(end) = data.windows(4).position(|window| window == b"\r\n\r\n") {
                break end + 4;
            }
            let read = stream.read(&mut chunk).ok()?;
            if read == 0 {
                return None;
            }
            data.extend_from_slice(&chunk[..read]);
        };
        let head = String::from_utf8_lossy(&data[..head_end]).to_string();
        let mut lines = head.split("\r\n");
        let mut start = lines.next()?.split(' ');
        let method = start.next()?.to_string();
        let path = start.next()?.to_string();
        let headers: Vec<(String, String)> = lines
            .filter_map(|line| line.split_once(':'))
            .map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim().to_string()))
            .collect();
        let length = headers
            .iter()
            .find(|(name, _)| name == "content-length")
            .and_then(|(_, value)| value.parse::<usize>().ok())
            .unwrap_or(0);
        while data.len() < head_end + length {
            let read = stream.read(&mut chunk).ok()?;
            if read == 0 {
                break;
            }
            data.extend_from_slice(&chunk[..read]);
        }
        Some(Received {
            method,
            path,
            headers,
            body: data[head_end..].to_vec(),
        })
    }

    /// Answers every request from `answer`, recording it.
    pub(crate) struct ScriptedTransport<F> {
        answer: F,
        pub sent: RefCell<Vec<RoutedRequest>>,
    }

    impl<F> ScriptedTransport<F>
    where
        F: Fn(&RoutedRequest) -> Result<RoutedResponse, RoutedError>,
    {
        pub(crate) fn new(answer: F) -> Self {
            Self {
                answer,
                sent: RefCell::new(Vec::new()),
            }
        }
    }

    impl<F> HttpTransport for ScriptedTransport<F>
    where
        F: Fn(&RoutedRequest) -> Result<RoutedResponse, RoutedError>,
    {
        async fn send(&self, request: RoutedRequest) -> Result<RoutedResponse, RoutedError> {
            let answer = (self.answer)(&request);
            self.sent.borrow_mut().push(request);
            answer
        }
    }

    /// A JSON-RPC 2.0 answer carrying `result`.
    pub(crate) fn rpc_result(result: serde_json::Value) -> RoutedResponse {
        RoutedResponse {
            status: 200,
            headers: Vec::new(),
            body: serde_json::to_vec(&serde_json::json!({
                "jsonrpc": "2.0",
                "id": 1,
                "result": result,
            }))
            .unwrap(),
        }
    }

    /// A JSON-RPC 2.0 error answer.
    pub(crate) fn rpc_error(code: i64, message: &str) -> RoutedResponse {
        RoutedResponse {
            status: 200,
            headers: Vec::new(),
            body: serde_json::to_vec(&serde_json::json!({
                "jsonrpc": "2.0",
                "id": 1,
                "error": { "code": code, "message": message },
            }))
            .unwrap(),
        }
    }
}
