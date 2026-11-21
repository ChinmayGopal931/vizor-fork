//! Anon's archive of Railgun's history, fetched for the Windows Railgun page
//! host (`windows/runner/railgun/railgun_archive.cpp`), which calls these
//! functions over a C ABI.
//!
//! The archive sends no CORS headers, so the page can't read it, and every
//! host fetches it for the page (docs/private-usd-railgun-hosts.md, sections 4
//! and 5; Android's `RailgunArchiveFetch.kt` is the reference). Windows's HTTP
//! stacks have no SOCKS5 client (WinHTTP has no SOCKS at all, WinINet only
//! SOCKS4, which looks the name up locally), so the Windows host's fetch is
//! this one, through the page's own bridge (`railgun_bridge.rs`) on loopback,
//! as Android's `HttpURLConnection` fetches through it:
//!
//! - **By name (H13, H14, H31).** Every connection is a SOCKS5 `CONNECT` to the
//!   archive's hostname on 443, unresolved (address type 3), so the bridge
//!   resolves it on the wallet's route (over Tor when Tor is on) and checks it
//!   against its allowlist. TLS is end to end, with the WebPKI roots.
//! - **Android's request (H24).** HTTP/1.1, with exactly `Host`,
//!   `User-Agent: Mozilla/5.0`, `Accept-Encoding: identity` and
//!   `Connection: Keep-Alive`: no `Accept-Language`, cookie, credential, cache
//!   directive or anything else, and the same for every wallet. No redirect is
//!   followed and nothing is decoded: the files are gzip, checked against the
//!   archive's checksums as served.
//! - **Android's limits (H25).** A connection (to the bridge, through it, and
//!   TLS) gets 20 s, a read that stalls 20 s fails, an answer gets 60 s in all,
//!   and a body past 16 MB (declared or read) is refused.
//! - **Android's answer (H26).** A 2xx, 4xx or 5xx goes to the page with its
//!   body and its type (no parameters); anything else, and any failure, is a
//!   502 with no body, which the page tries again. The whole answer is read
//!   before it is handed over.
//! - **Android's connections (H27).** One request per connection at a time
//!   (HTTP/1.1 only, never multiplexed); a connection whose answer was read
//!   whole is kept for the next request, five idle at most, five minutes each;
//!   one whose request failed, stalled, was refused for its size or abandoned
//!   is closed; a change of network drops every kept connection; and a kept
//!   connection the far end closed is replaced without costing a try.
//! - **Closed with the page (H29).** Closing a session ends its fetches
//!   unanswered and closes every connection, kept ones included.
//!
//! Nothing here logs: no URL, no status, no body.

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::io;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use bytes::Bytes;
use futures::FutureExt;
use http::{header, Request};
use http_body_util::{BodyExt, Empty};
use hyper::client::conn::http1;
use hyper_util::rt::TokioIo;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::TcpStream;
use tokio::task::AbortHandle;
use tokio::time::timeout;
use tokio_rustls::client::TlsStream;
use tokio_rustls::rustls;

/// Anon's archive: the host the page's `ARCHIVES` names, which the bridge's
/// allowlist and the page's CSP list. A test in `railgun_bridge.rs` pins it.
pub(crate) const ARCHIVE_HOST: &str = "digest.anon.inc";
/// Android's `RailgunRequests.USER_AGENT`, the same for every computer.
pub(crate) const USER_AGENT: &str = "Mozilla/5.0";
/// Android's `RailgunArchiveFetch.MAX_BYTES`.
pub(crate) const MAX_BYTES: usize = 16 * 1024 * 1024;
/// Android's `DEADLINE_MS`: the page gives up on a request after a minute too.
pub(crate) const DEADLINE: Duration = Duration::from_secs(60);
/// Android's `CONNECT_TIMEOUT_MS`.
pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
/// Android's `READ_TIMEOUT_MS`: a read that stalls this long fails.
pub(crate) const STALL: Duration = Duration::from_secs(20);
/// Android's connection pool (`ConfigAwareConnectionPool`'s defaults): five
/// idle at most, each kept five minutes at most.
pub(crate) const MAX_IDLE: usize = 5;
pub(crate) const KEEP_ALIVE: Duration = Duration::from_secs(5 * 60);

const BAD_GATEWAY: u16 = 502;
const HTTPS_PORT: u16 = 443;
/// How long a kept connection may take to show it is still ready.
const READY_WAIT: Duration = Duration::from_secs(1);
/// How often kept connections past their five minutes are let go.
const PRUNE_EVERY: Duration = Duration::from_secs(30);
/// The longest path the page asks for, far above the archive's.
const MAX_PATH: usize = 2048;

/// The archive's answer to one request, on one of this module's threads.
/// `content_type` and `body` are lent for the call only.
pub type ArchiveDone = extern "C" fn(
    context: *mut c_void,
    session: u64,
    request: u64,
    status: u16,
    content_type: *const c_char,
    body: *const u8,
    body_length: usize,
);

/// Where the archive is and how long things may take: the archive and
/// Android's limits in the app; a local server and shorter limits in tests.
#[derive(Clone)]
struct Settings {
    host: String,
    port: u16,
    tls: Option<Arc<rustls::ClientConfig>>,
    connect: Duration,
    stall: Duration,
    deadline: Duration,
    keep_alive: Duration,
    max_bytes: usize,
}

impl Settings {
    fn archive() -> Option<Self> {
        Some(Self {
            host: ARCHIVE_HOST.to_owned(),
            port: HTTPS_PORT,
            tls: Some(tls_config()?),
            connect: CONNECT_TIMEOUT,
            stall: STALL,
            deadline: DEADLINE,
            keep_alive: KEEP_ALIVE,
            max_bytes: MAX_BYTES,
        })
    }
}

/// TLS for the archive: the WebPKI roots, the ring provider (named here, so no
/// process-wide default is needed) and HTTP/1.1 alone in ALPN.
fn tls_config() -> Option<Arc<rustls::ClientConfig>> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let mut config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .ok()?
    .with_root_certificates(roots)
    .with_no_client_auth();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Some(Arc::new(config))
}

#[derive(Debug, PartialEq, Eq)]
struct Answer {
    status: u16,
    content_type: String,
    body: Vec<u8>,
}

impl Answer {
    fn bad_gateway() -> Self {
        Self {
            status: BAD_GATEWAY,
            content_type: "text/plain".to_owned(),
            body: Vec::new(),
        }
    }
}

/// The archive's connection: TLS in the app, plain in tests.
enum Stream {
    Plain(TcpStream),
    Tls(Box<TlsStream<TcpStream>>),
}

impl AsyncRead for Stream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Self::Plain(stream) => Pin::new(stream).poll_read(cx, buf),
            Self::Tls(stream) => Pin::new(stream.as_mut()).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Stream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            Self::Plain(stream) => Pin::new(stream).poll_write(cx, buf),
            Self::Tls(stream) => Pin::new(stream.as_mut()).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Self::Plain(stream) => Pin::new(stream).poll_flush(cx),
            Self::Tls(stream) => Pin::new(stream.as_mut()).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Self::Plain(stream) => Pin::new(stream).poll_shutdown(cx),
            Self::Tls(stream) => Pin::new(stream.as_mut()).poll_shutdown(cx),
        }
    }
}

fn failure(what: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::Other, what)
}

/// `CONNECT host:port` through the SOCKS5 bridge on `stream`, the name
/// unresolved (address type 3), as the bridge requires.
async fn socks5_connect(stream: &mut TcpStream, host: &str, port: u16) -> io::Result<()> {
    let name = u8::try_from(host.len()).map_err(|_| failure("the host is too long"))?;
    stream.write_all(&[5, 1, 0]).await?;
    let mut chosen = [0u8; 2];
    stream.read_exact(&mut chosen).await?;
    if chosen != [5, 0] {
        return Err(failure("the bridge refused the greeting"));
    }
    let mut request = vec![5, 1, 0, 3, name];
    request.extend_from_slice(host.as_bytes());
    request.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&request).await?;
    let mut head = [0u8; 4];
    stream.read_exact(&mut head).await?;
    if head[0] != 5 || head[1] != 0 {
        return Err(failure("the bridge refused the connection"));
    }
    let address = match head[3] {
        1 => 4,
        4 => 16,
        3 => {
            let mut length = [0u8; 1];
            stream.read_exact(&mut length).await?;
            usize::from(length[0])
        }
        _ => return Err(failure("the bridge's reply is unreadable")),
    };
    let mut rest = vec![0u8; address + 2];
    stream.read_exact(&mut rest).await?;
    Ok(())
}

/// A new connection to the archive through the bridge at `bridge_port`.
async fn connect(bridge_port: u16, settings: &Settings) -> io::Result<Stream> {
    let tcp = timeout(settings.connect, async {
        let mut stream = TcpStream::connect(("127.0.0.1", bridge_port)).await?;
        stream.set_nodelay(true)?;
        socks5_connect(&mut stream, &settings.host, settings.port).await?;
        Ok::<_, io::Error>(stream)
    })
    .await
    .map_err(|_| failure("connecting timed out"))??;
    let Some(config) = &settings.tls else {
        return Ok(Stream::Plain(tcp));
    };
    let name = rustls::pki_types::ServerName::try_from(settings.host.clone())
        .map_err(|_| failure("the host is not a name"))?;
    let tls = timeout(
        settings.stall,
        tokio_rustls::TlsConnector::from(config.clone()).connect(name, tcp),
    )
    .await
    .map_err(|_| failure("the TLS handshake stalled"))??;
    Ok(Stream::Tls(Box::new(tls)))
}

type Sender = http1::SendRequest<Empty<Bytes>>;

struct Idle {
    sender: Sender,
    since: Instant,
}

#[derive(Default)]
struct Pool {
    idle: Vec<Idle>,
    /// Bumped by every change of network: a connection of an older one is
    /// never kept.
    generation: u64,
    /// The connections' own tasks, aborted when the session closes.
    connections: Vec<AbortHandle>,
    closed: bool,
}

struct Session {
    bridge_port: u16,
    settings: Settings,
    pool: Mutex<Pool>,
    /// The fetches under way, by request; aborted when the session closes.
    fetches: Mutex<HashMap<u64, AbortHandle>>,
    /// Held while an answer is handed over, so none is after `close`.
    delivering: Mutex<bool>,
}

impl Session {
    fn new(bridge_port: u16, settings: Settings) -> Arc<Self> {
        Arc::new(Self {
            bridge_port,
            settings,
            pool: Mutex::new(Pool::default()),
            fetches: Mutex::new(HashMap::new()),
            delivering: Mutex::new(true),
        })
    }

    fn lock_pool(&self) -> std::sync::MutexGuard<'_, Pool> {
        self.pool
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// A kept connection that is still ready, or a new one; `true` with a kept
    /// one.
    async fn checkout(self: &Arc<Self>) -> io::Result<(Sender, u64, bool)> {
        loop {
            let kept = {
                let mut pool = self.lock_pool();
                if pool.closed {
                    return Err(failure("closed"));
                }
                let keep_alive = self.settings.keep_alive;
                pool.idle.retain(|idle| idle.since.elapsed() < keep_alive);
                pool.idle.pop().map(|idle| (idle.sender, pool.generation))
            };
            let Some((mut sender, generation)) = kept else {
                break;
            };
            // One the far end closed is replaced, and costs no try.
            if matches!(timeout(READY_WAIT, sender.ready()).await, Ok(Ok(()))) {
                return Ok((sender, generation, true));
            }
        }
        let (sender, generation) = self.connect_new().await?;
        Ok((sender, generation, false))
    }

    async fn connect_new(self: &Arc<Self>) -> io::Result<(Sender, u64)> {
        let generation = self.lock_pool().generation;
        let stream = connect(self.bridge_port, &self.settings).await?;
        let (sender, connection) = timeout(
            self.settings.stall,
            http1::Builder::new().handshake::<_, Empty<Bytes>>(TokioIo::new(stream)),
        )
        .await
        .map_err(|_| failure("the connection stalled"))?
        .map_err(|_| failure("the connection failed"))?;
        let task = tokio::spawn(async move {
            let _ = connection.await;
        });
        let mut pool = self.lock_pool();
        if pool.closed {
            task.abort();
            return Err(failure("closed"));
        }
        pool.connections.retain(|handle| !handle.is_finished());
        pool.connections.push(task.abort_handle());
        Ok((sender, generation))
    }

    /// A connection whose answer was read whole goes back for the next request.
    fn keep(&self, sender: Sender, generation: u64) {
        let mut pool = self.lock_pool();
        if pool.closed || generation != pool.generation || sender.is_closed() {
            return;
        }
        if pool.idle.len() >= MAX_IDLE {
            pool.idle.remove(0);
        }
        pool.idle.push(Idle {
            sender,
            since: Instant::now(),
        });
    }

    fn prune(&self) {
        let keep_alive = self.settings.keep_alive;
        self.lock_pool()
            .idle
            .retain(|idle| idle.since.elapsed() < keep_alive);
    }

    fn network_changed(&self) {
        let mut pool = self.lock_pool();
        pool.generation += 1;
        // Dropping a connection's sender ends its task, which closes it.
        pool.idle.clear();
    }

    fn close(&self) {
        {
            let mut pool = self.lock_pool();
            pool.closed = true;
            pool.idle.clear();
            for connection in pool.connections.drain(..) {
                connection.abort();
            }
        }
        for (_, fetch) in self
            .fetches
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .drain()
        {
            fetch.abort();
        }
        // Waits out an answer being handed over; none is after this.
        *self
            .delivering
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = false;
    }

    /// One GET of `path_and_query`, as Android's host makes it.
    async fn fetch(self: &Arc<Self>, path_and_query: &str) -> Answer {
        match timeout(self.settings.deadline, self.exchange(path_and_query)).await {
            Ok(Ok(answer)) => answer,
            _ => Answer::bad_gateway(),
        }
    }

    fn request(&self, path_and_query: &str) -> io::Result<Request<Empty<Bytes>>> {
        Request::get(path_and_query)
            .header(header::HOST, &self.settings.host)
            .header(header::USER_AGENT, USER_AGENT)
            .header(header::ACCEPT_ENCODING, "identity")
            .header(header::CONNECTION, "Keep-Alive")
            .body(Empty::new())
            .map_err(|_| failure("the request is malformed"))
    }

    async fn exchange(self: &Arc<Self>, path_and_query: &str) -> io::Result<Answer> {
        let stall = self.settings.stall;
        let (mut sender, mut generation, reused) = self.checkout().await?;
        let mut response = timeout(stall, sender.send_request(self.request(path_and_query)?))
            .await
            .map_err(|_| failure("the answer stalled"))?;
        if reused
            && matches!(&response, Err(error) if error.is_canceled() || error.is_closed() || error.is_incomplete_message())
        {
            // A kept connection the far end closed before answering: once more,
            // on a new one, at no cost to the page's tries.
            (sender, generation) = self.connect_new().await?;
            response = timeout(stall, sender.send_request(self.request(path_and_query)?))
                .await
                .map_err(|_| failure("the answer stalled"))?;
        }
        let response = response.map_err(|_| failure("the connection failed"))?;
        let status = response.status().as_u16();
        // A redirect, an informational status or anything else: never followed.
        if !(200..300).contains(&status) && !(400..600).contains(&status) {
            return Ok(Answer::bad_gateway());
        }
        let content_type = response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(';').next())
            .map(str::trim)
            .filter(|value| {
                !value.is_empty()
                    && value.bytes().all(|byte| {
                        byte.is_ascii_alphanumeric() || b"!#$%&'*+.^_`|~/-".contains(&byte)
                    })
            })
            .unwrap_or("application/octet-stream")
            .to_owned();
        let declared = response
            .headers()
            .get(header::CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok());
        let max_bytes = self.settings.max_bytes;
        if declared.is_some_and(|length| length > max_bytes as u64) {
            return Err(failure("the answer is too large"));
        }
        let mut body = Vec::with_capacity(declared.map_or(64 * 1024, |length| length as usize));
        let mut incoming = response.into_body();
        loop {
            let frame = timeout(stall, incoming.frame())
                .await
                .map_err(|_| failure("the answer stalled"))?;
            let Some(frame) = frame else { break };
            let frame = frame.map_err(|_| failure("the connection failed"))?;
            if let Ok(data) = frame.into_data() {
                if body.len() + data.len() > max_bytes {
                    return Err(failure("the answer is too large"));
                }
                body.extend_from_slice(&data);
            }
        }
        self.keep(sender, generation);
        Ok(Answer {
            status,
            content_type,
            body,
        })
    }
}

fn runtime() -> Option<&'static tokio::runtime::Runtime> {
    static RUNTIME: OnceLock<Option<tokio::runtime::Runtime>> = OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .thread_name("railgun-archive")
                .enable_all()
                .build()
                .ok()
        })
        .as_ref()
}

fn sessions() -> &'static Mutex<HashMap<u64, Arc<Session>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<u64, Arc<Session>>>> = OnceLock::new();
    SESSIONS.get_or_init(Default::default)
}

fn session(id: u64) -> Option<Arc<Session>> {
    sessions()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&id)
        .cloned()
}

/// Whether `path` is what the page asks the archive for: from `/`, printable
/// ASCII without spaces, no fragment.
fn path_ok(path: &str) -> bool {
    path.starts_with('/')
        && path.len() <= MAX_PATH
        && path
            .bytes()
            .all(|byte| (0x21..=0x7e).contains(&byte) && byte != b'#')
}

struct Callback {
    done: ArchiveDone,
    context: *mut c_void,
}

// The host's context pointer is opaque here and only handed back.
unsafe impl Send for Callback {}

impl Callback {
    fn deliver(&self, session: u64, request: u64, answer: &Answer) {
        let content_type = CString::new(answer.content_type.as_str()).unwrap_or_default();
        (self.done)(
            self.context,
            session,
            request,
            answer.status,
            content_type.as_ptr(),
            answer.body.as_ptr(),
            answer.body.len(),
        );
    }
}

fn open_with(bridge_port: u16, settings: Settings) -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let Some(runtime) = runtime() else { return 0 };
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let session = Session::new(bridge_port, settings);
    let pruned = Arc::downgrade(&session);
    runtime.spawn(async move {
        loop {
            tokio::time::sleep(PRUNE_EVERY).await;
            let Some(session) = pruned.upgrade() else {
                return;
            };
            if session.lock_pool().closed {
                return;
            }
            session.prune();
        }
    });
    sessions()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(id, session);
    id
}

fn fetch_with(session_id: u64, request: u64, path: &str, callback: Callback) -> bool {
    let (Some(runtime), Some(session)) = (runtime(), session(session_id)) else {
        return false;
    };
    if !path_ok(path) || session.lock_pool().closed {
        return false;
    }
    let path = path.to_owned();
    let fetching = session.clone();
    let mut fetches = session
        .fetches
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let task = runtime.spawn(async move {
        let answer = AssertUnwindSafe(fetching.fetch(&path))
            .catch_unwind()
            .await
            .unwrap_or_else(|_| Answer::bad_gateway());
        fetching
            .fetches
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&request);
        let open = fetching
            .delivering
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if *open {
            callback.deliver(session_id, request, &answer);
        }
        drop(open);
    });
    fetches.insert(request, task.abort_handle());
    true
}

/// A session of connections to the archive through the bridge on loopback
/// `bridge_port`, for one page; 0 when none can be made.
#[no_mangle]
pub extern "C" fn veylor_railgun_archive_open(bridge_port: u16) -> u64 {
    catch_unwind(|| {
        if bridge_port == 0 {
            return 0;
        }
        Settings::archive().map_or(0, |settings| open_with(bridge_port, settings))
    })
    .unwrap_or(0)
}

/// Fetches `path_and_query` (from `/`) from the archive, calling `done` once
/// with the answer, unless the session closes first. False when the request
/// was not taken; `done` is then never called.
///
/// # Safety
///
/// `path_and_query` is a NUL-terminated string, and `done` may be called on
/// any thread until `veylor_railgun_archive_close` returns.
#[no_mangle]
pub unsafe extern "C" fn veylor_railgun_archive_fetch(
    session: u64,
    request: u64,
    path_and_query: *const c_char,
    done: Option<ArchiveDone>,
    context: *mut c_void,
) -> bool {
    let (Some(done), false) = (done, path_and_query.is_null()) else {
        return false;
    };
    // SAFETY: the caller hands a NUL-terminated string.
    let Ok(path) = (unsafe { CStr::from_ptr(path_and_query) }).to_str() else {
        return false;
    };
    let callback = Callback { done, context };
    catch_unwind(AssertUnwindSafe(|| {
        fetch_with(session, request, path, callback)
    }))
    .unwrap_or(false)
}

/// The network changed: every kept connection of `session` goes.
#[no_mangle]
pub extern "C" fn veylor_railgun_archive_network_changed(session_id: u64) {
    let _ = catch_unwind(|| {
        if let Some(session) = session(session_id) {
            session.network_changed();
        }
    });
}

/// Ends every fetch of `session` unanswered and closes its connections; after
/// it returns, no `done` is called for it.
#[no_mangle]
pub extern "C" fn veylor_railgun_archive_close(session_id: u64) {
    let _ = catch_unwind(|| {
        let removed = sessions()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&session_id);
        if let Some(session) = removed {
            session.close();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use tokio::net::TcpListener;
    use tokio::sync::mpsc;

    const TEST_HOST: &str = "archive.test";

    /// A stand-in for the bridge: SOCKS5, a hostname only, which it sends to
    /// `upstream`; it counts the connections it made.
    async fn bridge(upstream: u16, connections: Arc<AtomicUsize>) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let (mut client, _) = listener.accept().await.unwrap();
                let connections = connections.clone();
                tokio::spawn(async move {
                    let mut greeting = [0u8; 3];
                    client.read_exact(&mut greeting).await.unwrap();
                    client.write_all(&[5, 0]).await.unwrap();
                    let mut head = [0u8; 5];
                    client.read_exact(&mut head).await.unwrap();
                    assert_eq!(head[3], 3, "a hostname, never an address");
                    let mut name = vec![0u8; usize::from(head[4]) + 2];
                    client.read_exact(&mut name).await.unwrap();
                    assert_eq!(&name[..name.len() - 2], TEST_HOST.as_bytes());
                    assert_eq!(&name[name.len() - 2..], &443u16.to_be_bytes());
                    client
                        .write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
                        .await
                        .unwrap();
                    connections.fetch_add(1, Ordering::SeqCst);
                    let mut server = TcpStream::connect(("127.0.0.1", upstream)).await.unwrap();
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
                });
            }
        });
        port
    }

    /// An HTTP/1.1 server that hands each request's head to `heads` and
    /// answers with what `answer` returns for its path.
    async fn server(heads: mpsc::UnboundedSender<String>, answer: fn(&str) -> Vec<u8>) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let (mut stream, _) = listener.accept().await.unwrap();
                let heads = heads.clone();
                tokio::spawn(async move {
                    let mut buffer = Vec::new();
                    loop {
                        let mut chunk = [0u8; 4096];
                        let Ok(read) = stream.read(&mut chunk).await else {
                            return;
                        };
                        if read == 0 {
                            return;
                        }
                        buffer.extend_from_slice(&chunk[..read]);
                        while let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                            let head = String::from_utf8(buffer[..end + 4].to_vec()).unwrap();
                            buffer.drain(..end + 4);
                            let path = head.split(' ').nth(1).unwrap_or("").to_owned();
                            let _ = heads.send(head);
                            let reply = answer(&path);
                            if reply.is_empty() {
                                // Stalls: never answers, never closes.
                                tokio::time::sleep(Duration::from_secs(3600)).await;
                            }
                            if stream.write_all(&reply).await.is_err() {
                                return;
                            }
                        }
                    }
                });
            }
        });
        port
    }

    fn reply(path: &str) -> Vec<u8> {
        match path {
            "/ok" => b"HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 2\r\n\r\n{}".to_vec(),
            "/missing" => b"HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: 4\r\n\r\ngone".to_vec(),
            "/moved" => b"HTTP/1.1 301 Moved\r\nLocation: https://elsewhere.test/\r\nContent-Length: 0\r\n\r\n".to_vec(),
            "/large" => b"HTTP/1.1 200 OK\r\nContent-Length: 2048\r\n\r\n".to_vec(),
            "/stall-body" => b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".to_vec(),
            _ => Vec::new(),
        }
    }

    struct Fixture {
        session: Arc<Session>,
        heads: mpsc::UnboundedReceiver<String>,
        connections: Arc<AtomicUsize>,
    }

    async fn fixture() -> Fixture {
        let (sender, heads) = mpsc::unbounded_channel();
        let upstream = server(sender, reply).await;
        let connections = Arc::new(AtomicUsize::new(0));
        let port = bridge(upstream, connections.clone()).await;
        let settings = Settings {
            host: TEST_HOST.to_owned(),
            port: 443,
            tls: None,
            connect: Duration::from_secs(5),
            stall: Duration::from_millis(500),
            deadline: Duration::from_secs(5),
            keep_alive: KEEP_ALIVE,
            max_bytes: 1024,
        };
        Fixture {
            session: Session::new(port, settings),
            heads,
            connections,
        }
    }

    /// Android's request, exactly (H24): the same four headers for every
    /// wallet, over HTTP/1.1, the path as the page asked.
    #[tokio::test]
    async fn asks_with_exactly_androids_headers_over_http_1_1() {
        let mut fixture = fixture().await;
        let answer = fixture.session.fetch("/ok?v=3").await;
        assert_eq!(answer.status, 502, "the fixture answers /ok only");
        let head = fixture.heads.recv().await.unwrap();
        let mut lines: Vec<&str> = head.trim_end().split("\r\n").collect();
        assert_eq!(lines.remove(0), "GET /ok?v=3 HTTP/1.1");
        let mut names: Vec<String> = lines.iter().map(|line| line.to_ascii_lowercase()).collect();
        names.sort();
        assert_eq!(
            names,
            [
                "accept-encoding: identity",
                "connection: keep-alive",
                "host: archive.test",
                "user-agent: mozilla/5.0",
            ]
        );
    }

    /// What the page gets (H26): a 2xx or 4xx with its body and its type, no
    /// parameters; a redirect is never followed and is a 502.
    #[tokio::test]
    async fn answers_successes_and_errors_and_refuses_redirects() {
        let fixture = fixture().await;
        let ok = fixture.session.fetch("/ok").await;
        assert_eq!(
            ok,
            Answer {
                status: 200,
                content_type: "application/json".to_owned(),
                body: b"{}".to_vec()
            }
        );
        let missing = fixture.session.fetch("/missing").await;
        assert_eq!((missing.status, missing.body), (404, b"gone".to_vec()));
        assert_eq!(fixture.session.fetch("/moved").await, Answer::bad_gateway());
    }

    /// Android's limits (H25): a body declared past the cap, a body that
    /// stalls and an answer that never comes are each a 502.
    #[tokio::test]
    async fn refuses_past_the_cap_and_fails_a_stall() {
        let fixture = fixture().await;
        assert_eq!(fixture.session.fetch("/large").await, Answer::bad_gateway());
        assert_eq!(
            fixture.session.fetch("/stall-body").await,
            Answer::bad_gateway()
        );
        assert_eq!(fixture.session.fetch("/never").await, Answer::bad_gateway());
    }

    /// Android's connections (H27): an answer read whole leaves its connection
    /// for the next request; a failed one closes its connection; a change of
    /// network drops the kept ones.
    #[tokio::test]
    async fn keeps_connections_as_android_does() {
        let fixture = fixture().await;
        assert_eq!(fixture.session.fetch("/ok").await.status, 200);
        assert_eq!(fixture.session.fetch("/ok").await.status, 200);
        assert_eq!(
            fixture.connections.load(Ordering::SeqCst),
            1,
            "kept and reused"
        );
        assert_eq!(fixture.session.fetch("/stall-body").await.status, 502);
        assert_eq!(fixture.session.fetch("/ok").await.status, 200);
        assert_eq!(
            fixture.connections.load(Ordering::SeqCst),
            2,
            "the stalled request's connection was not kept; the one before it was",
        );
        fixture.session.network_changed();
        assert_eq!(fixture.session.fetch("/ok").await.status, 200);
        assert_eq!(
            fixture.connections.load(Ordering::SeqCst),
            3,
            "a new network, a new connection"
        );
    }

    /// A path the page could never send is refused before anything is asked.
    #[test]
    fn takes_only_the_pages_paths() {
        assert!(path_ok("/v4/1/meta.json"));
        assert!(path_ok("/v4/1/chunk-index.json?v=243"));
        assert!(!path_ok("v4/1/meta.json"));
        assert!(!path_ok("/v4/1/meta.json#top"));
        assert!(!path_ok("/v4/1/meta json"));
        assert!(!path_ok("/v4/1/\r\nHost: elsewhere"));
    }
}
