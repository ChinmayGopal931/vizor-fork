//! Loopback SOCKS5 bridge that carries the Railgun page's traffic over the
//! wallet's network route (Private USD, `docs/private-usd-reference.md` §6.8).
//!
//! The page runs in an Android WebView, which cannot use the in-process Tor
//! client. The host points the WebView at this listener through androidx
//! `ProxyController`, so every page connection follows the route setting: an
//! isolated Tor circuit while Tor is on, a leased direct socket otherwise, and
//! nothing at all while Tor is starting or has failed. Only `CONNECT` to an
//! allowlisted host on port 443 is served; the tunnelled bytes are the page's
//! own TLS, so the bridge never sees a URL, let alone a keyed one.
//!
//! Chromium speaks SOCKS5 without authentication and sends hostnames (ATYP 3),
//! which are resolved on this side, so a Tor-routed page never touches local
//! DNS. Any app on the device can reach the loopback port while the page is
//! open; the allowlist limits that to the Railgun hosts, over the wallet's
//! route.
//!
//! A bridge keeps the route it started on. After a route change the caller
//! closes the page, stops the bridge and starts a new one: Chromium keeps its
//! pooled tunnels otherwise, and a bridge whose route no longer matches the
//! policy refuses every new connection.

use std::{future::Future, io, sync::OnceLock, time::Duration};

use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::{oneshot, Mutex},
    task::{JoinHandle, JoinSet},
};
use zcash_client_backend::tor::Client as TorClient;

use crate::network_privacy::{self, DirectRouteLease};
use crate::wallet::private_usd::deployment::RAILGUN_PAGE_HOSTS;

const HTTPS_PORT: u16 = 443;
/// A client that has not finished its handshake by then is dropped.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

const SOCKS_VERSION: u8 = 0x05;
const METHOD_NO_AUTH: u8 = 0x00;
const METHOD_NONE_ACCEPTABLE: u8 = 0xff;
const CMD_CONNECT: u8 = 0x01;
const ATYP_DOMAIN: u8 = 0x03;

/// RFC 1928 reply codes the bridge sends.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Reply {
    Succeeded = 0x00,
    GeneralFailure = 0x01,
    NotAllowed = 0x02,
    CommandNotSupported = 0x07,
    AddressTypeNotSupported = 0x08,
}

#[derive(Debug)]
enum HandshakeError {
    Io(io::Error),
    /// Not SOCKS5, or no acceptable method: closed without a request reply.
    Protocol,
    /// A well-formed request the bridge refuses with this reply.
    Refused(Reply),
}

impl From<io::Error> for HandshakeError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[derive(Debug, PartialEq, Eq)]
struct Target {
    host: String,
    port: u16,
}

/// The route a bridge was started on. It never changes: a route change makes
/// the bridge refuse new connections until the caller restarts it.
#[derive(Clone)]
enum Session {
    Direct,
    /// One isolated client for the whole page session, so the page's sockets
    /// share an isolation group instead of each building a fresh circuit.
    Tor(TorClient),
}

trait Tunnel: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Tunnel for T {}

struct BridgeState {
    port: u16,
    shutdown: oneshot::Sender<()>,
    task: JoinHandle<()>,
}

static BRIDGE: OnceLock<Mutex<Option<BridgeState>>> = OnceLock::new();

fn bridge() -> &'static Mutex<Option<BridgeState>> {
    BRIDGE.get_or_init(|| Mutex::new(None))
}

/// Starts the bridge, or returns the port of the one already running.
///
/// Fails closed: while Tor is on but bootstrapping (past the route wait),
/// failed or unavailable, there is no bridge and so no page traffic.
pub(crate) async fn start() -> Result<u16, String> {
    let mut state = bridge().lock().await;
    if let Some(state) = state.as_ref() {
        return Ok(state.port);
    }
    let session = match network_privacy::tor_client_for_route(true, || false).await? {
        Some(tor) => Session::Tor(tor),
        None => Session::Direct,
    };
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|error| format!("Bind Railgun bridge: {error}"))?;
    let port = listener
        .local_addr()
        .map_err(|error| format!("Read Railgun bridge address: {error}"))?
        .port();
    let (shutdown, shutdown_rx) = oneshot::channel();
    let task = tokio::spawn(run(listener, session, shutdown_rx));
    *state = Some(BridgeState {
        port,
        shutdown,
        task,
    });
    log::info!("network privacy: Railgun bridge started");
    Ok(port)
}

/// Stops the bridge and closes every tunnel it carries. Idempotent.
pub(crate) async fn stop() {
    let state = bridge().lock().await.take();
    if let Some(state) = state {
        let _ = state.shutdown.send(());
        let _ = state.task.await;
        log::info!("network privacy: Railgun bridge stopped");
    }
}

async fn run(listener: TcpListener, session: Session, mut shutdown: oneshot::Receiver<()>) {
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            _ = &mut shutdown => break,
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    let session = session.clone();
                    connections.spawn(async move {
                        let connect = |host, port| connect_upstream(session, host, port);
                        // Per-connection outcomes are not logged: they would
                        // record the page's activity.
                        let _ = serve(stream, &RAILGUN_PAGE_HOSTS, connect).await;
                    });
                }
                Err(error) => {
                    log::warn!("Railgun bridge accept failed: {error}");
                    break;
                }
            },
            // Reaps finished tunnels, so the set does not grow for the page's life.
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    connections.abort_all();
    while connections.join_next().await.is_some() {}
}

/// Serves one client: the handshake, the upstream connection, then the tunnel.
async fn serve<C, F>(mut client: TcpStream, allowed: &[&str], connect: C) -> Result<(), String>
where
    C: FnOnce(String, u16) -> F,
    F: Future<Output = Result<Box<dyn Tunnel>, Reply>>,
{
    let target =
        match tokio::time::timeout(HANDSHAKE_TIMEOUT, handshake(&mut client, allowed)).await {
            Ok(Ok(target)) => target,
            Ok(Err(HandshakeError::Refused(reply))) => {
                let _ = write_reply(&mut client, reply).await;
                return Err(format!("request refused ({reply:?})"));
            }
            Ok(Err(HandshakeError::Protocol)) => return Err("not a SOCKS5 no-auth client".into()),
            Ok(Err(HandshakeError::Io(error))) => return Err(format!("handshake: {error}")),
            Err(_) => return Err("handshake timed out".into()),
        };
    let mut upstream = match connect(target.host, target.port).await {
        Ok(upstream) => upstream,
        Err(reply) => {
            let _ = write_reply(&mut client, reply).await;
            return Err(format!("upstream refused ({reply:?})"));
        }
    };
    write_reply(&mut client, Reply::Succeeded)
        .await
        .map_err(|error| format!("reply: {error}"))?;
    tokio::io::copy_bidirectional(&mut client, &mut upstream)
        .await
        .map_err(|error| format!("tunnel: {error}"))?;
    Ok(())
}

/// Reads the greeting and one request. Only `CONNECT` to an allowlisted
/// hostname on port 443 passes.
async fn handshake<S>(stream: &mut S, allowed: &[&str]) -> Result<Target, HandshakeError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut greeting = [0u8; 2];
    stream.read_exact(&mut greeting).await?;
    if greeting[0] != SOCKS_VERSION {
        return Err(HandshakeError::Protocol);
    }
    let mut methods = vec![0u8; usize::from(greeting[1])];
    stream.read_exact(&mut methods).await?;
    if !methods.contains(&METHOD_NO_AUTH) {
        stream
            .write_all(&[SOCKS_VERSION, METHOD_NONE_ACCEPTABLE])
            .await?;
        return Err(HandshakeError::Protocol);
    }
    stream.write_all(&[SOCKS_VERSION, METHOD_NO_AUTH]).await?;

    let mut request = [0u8; 4];
    stream.read_exact(&mut request).await?;
    if request[0] != SOCKS_VERSION {
        return Err(HandshakeError::Protocol);
    }
    if request[1] != CMD_CONNECT {
        return Err(HandshakeError::Refused(Reply::CommandNotSupported));
    }
    // An IP address could only bypass the hostname allowlist.
    if request[3] != ATYP_DOMAIN {
        return Err(HandshakeError::Refused(Reply::AddressTypeNotSupported));
    }
    let mut length = [0u8; 1];
    stream.read_exact(&mut length).await?;
    let mut host = vec![0u8; usize::from(length[0])];
    stream.read_exact(&mut host).await?;
    let mut port = [0u8; 2];
    stream.read_exact(&mut port).await?;
    let port = u16::from_be_bytes(port);

    let host = String::from_utf8(host).map_err(|_| HandshakeError::Refused(Reply::NotAllowed))?;
    if port != HTTPS_PORT || !allowed.iter().any(|a| a.eq_ignore_ascii_case(&host)) {
        return Err(HandshakeError::Refused(Reply::NotAllowed));
    }
    Ok(Target { host, port })
}

async fn write_reply<S: AsyncWrite + Unpin>(stream: &mut S, reply: Reply) -> io::Result<()> {
    // BND.ADDR 0.0.0.0, BND.PORT 0: Chromium does not use them.
    stream
        .write_all(&[SOCKS_VERSION, reply as u8, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        .await
}

/// Opens the upstream socket on the session's route. A session whose route no
/// longer matches the process policy (a flip, or Tor no longer usable) is
/// refused rather than re-routed.
async fn connect_upstream(
    session: Session,
    host: String,
    port: u16,
) -> Result<Box<dyn Tunnel>, Reply> {
    match (session, network_privacy::try_tor_client_for_route(false)) {
        (Session::Tor(tor), Ok(Some(_))) => tor
            .connect_stream(&host, port)
            .await
            .map(|stream| Box::new(stream) as Box<dyn Tunnel>)
            .map_err(|_| Reply::GeneralFailure),
        (Session::Direct, Ok(None)) => {
            // The lease is taken before connecting, so a Tor enable that lands
            // mid-connect aborts the attempt too.
            let route = DirectRouteLease::new();
            let mut connecting = Box::pin(TcpStream::connect((host.as_str(), port)));
            let stream =
                std::future::poll_fn(|cx| route.poll(cx, |cx| connecting.as_mut().poll(cx)))
                    .await
                    .map_err(|_| Reply::GeneralFailure)?;
            Ok(Box::new(route.into_io(stream)))
        }
        _ => Err(Reply::NotAllowed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::network_privacy::test_route_policy::lock_route_policy;

    const HOST: &str = "rpc.example.test";

    async fn echo_server() -> std::net::SocketAddr {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let (mut read, mut write) = stream.split();
                    let _ = tokio::io::copy(&mut read, &mut write).await;
                });
            }
        });
        address
    }

    /// Serves one client through a fake upstream that records what it was asked
    /// for and connects to `upstream`, then returns the client side.
    async fn bridge_to(
        upstream: std::net::SocketAddr,
    ) -> (TcpStream, tokio::sync::oneshot::Receiver<Target>) {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        let (asked, asked_rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let connect = move |host: String, port| async move {
                let _ = asked.send(Target { host, port });
                TcpStream::connect(upstream)
                    .await
                    .map(|stream| Box::new(stream) as Box<dyn Tunnel>)
                    .map_err(|_| Reply::GeneralFailure)
            };
            let _ = serve(stream, &[HOST], connect).await;
        });
        (TcpStream::connect(address).await.unwrap(), asked_rx)
    }

    fn connect_request(atyp: u8, address: &[u8], port: u16) -> Vec<u8> {
        let mut request = vec![SOCKS_VERSION, CMD_CONNECT, 0x00, atyp];
        if atyp == ATYP_DOMAIN {
            request.push(u8::try_from(address.len()).unwrap());
        }
        request.extend_from_slice(address);
        request.extend_from_slice(&port.to_be_bytes());
        request
    }

    async fn greet(client: &mut TcpStream) {
        client
            .write_all(&[SOCKS_VERSION, 1, METHOD_NO_AUTH])
            .await
            .unwrap();
        let mut chosen = [0u8; 2];
        client.read_exact(&mut chosen).await.unwrap();
        assert_eq!(chosen, [SOCKS_VERSION, METHOD_NO_AUTH]);
    }

    async fn reply_code(client: &mut TcpStream) -> u8 {
        let mut reply = [0u8; 10];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply[0], SOCKS_VERSION);
        reply[1]
    }

    #[tokio::test]
    async fn tunnels_a_connect_to_an_allowlisted_host() {
        let (mut client, asked) = bridge_to(echo_server().await).await;
        greet(&mut client).await;
        client
            .write_all(&connect_request(ATYP_DOMAIN, HOST.as_bytes(), 443))
            .await
            .unwrap();
        assert_eq!(reply_code(&mut client).await, Reply::Succeeded as u8);
        assert_eq!(
            asked.await.unwrap(),
            Target {
                host: HOST.into(),
                port: 443
            }
        );

        client.write_all(b"ping").await.unwrap();
        let mut echoed = [0u8; 4];
        client.read_exact(&mut echoed).await.unwrap();
        assert_eq!(&echoed, b"ping");
    }

    async fn refused(request: Vec<u8>) -> (u8, bool) {
        let (mut client, asked) = bridge_to(echo_server().await).await;
        greet(&mut client).await;
        client.write_all(&request).await.unwrap();
        let code = reply_code(&mut client).await;
        (code, asked.await.is_ok())
    }

    #[tokio::test]
    async fn refuses_hosts_off_the_allowlist_ports_other_than_443_and_ip_addresses() {
        let off_list = connect_request(ATYP_DOMAIN, b"evil.example.test", 443);
        assert_eq!(refused(off_list).await, (Reply::NotAllowed as u8, false));
        let plain_http = connect_request(ATYP_DOMAIN, HOST.as_bytes(), 80);
        assert_eq!(refused(plain_http).await, (Reply::NotAllowed as u8, false));
        let ipv4 = connect_request(0x01, &[127, 0, 0, 1], 443);
        assert_eq!(
            refused(ipv4).await,
            (Reply::AddressTypeNotSupported as u8, false)
        );
    }

    #[tokio::test]
    async fn refuses_commands_other_than_connect() {
        let mut bind = connect_request(ATYP_DOMAIN, HOST.as_bytes(), 443);
        bind[1] = 0x02;
        assert_eq!(
            refused(bind).await,
            (Reply::CommandNotSupported as u8, false)
        );
    }

    #[tokio::test]
    async fn refuses_clients_that_require_authentication() {
        let (mut client, asked) = bridge_to(echo_server().await).await;
        // Username/password only.
        client.write_all(&[SOCKS_VERSION, 1, 0x02]).await.unwrap();
        let mut chosen = [0u8; 2];
        client.read_exact(&mut chosen).await.unwrap();
        assert_eq!(chosen, [SOCKS_VERSION, METHOD_NONE_ACCEPTABLE]);
        assert!(asked.await.is_err());
    }

    #[tokio::test]
    async fn a_direct_session_refuses_new_connections_once_tor_is_requested() {
        let _policy = lock_route_policy();
        network_privacy::begin_tor_enable();
        let refused = connect_upstream(Session::Direct, HOST.into(), 443).await;
        assert!(matches!(refused, Err(Reply::NotAllowed)));
    }

    #[tokio::test]
    async fn a_direct_tunnel_is_aborted_when_tor_is_requested() {
        let _policy = lock_route_policy();
        let route = DirectRouteLease::new();
        let stream = TcpStream::connect(echo_server().await).await.unwrap();
        let mut tunnel = route.into_io(stream);
        tunnel.write_all(b"ping").await.unwrap();
        let mut echoed = [0u8; 4];
        tunnel.read_exact(&mut echoed).await.unwrap();

        network_privacy::begin_tor_enable();
        let error = tunnel.read_exact(&mut echoed).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::ConnectionAborted);
    }

    /// Bootstraps the real Tor network into a temporary directory, then tunnels
    /// to an allowlisted host through a Tor-routed bridge (the `connect_stream`
    /// patch end to end). Run with `cargo test --lib railgun_bridge -- --ignored`.
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "bootstraps Tor over the network"]
    async fn a_tor_session_tunnels_to_an_allowlisted_host() {
        let _policy = lock_route_policy();
        let tor_dir = tempfile::tempdir().unwrap();
        network_privacy::enable_tor(tor_dir.path()).await.unwrap();
        let port = start().await.unwrap();

        let mut client = TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port))
            .await
            .unwrap();
        greet(&mut client).await;
        let host = "ethereum-sepolia-rpc.publicnode.com";
        assert!(RAILGUN_PAGE_HOSTS.contains(&host));
        client
            .write_all(&connect_request(ATYP_DOMAIN, host.as_bytes(), 443))
            .await
            .unwrap();
        assert_eq!(reply_code(&mut client).await, Reply::Succeeded as u8);
        // Plain text to a TLS port draws an answer (an HTTP 400 or a TLS
        // alert), which proves bytes cross the tunnel both ways.
        client
            .write_all(b"GET / HTTP/1.0\r\nHost: x\r\n\r\n")
            .await
            .unwrap();
        let mut answer = [0u8; 1];
        let read = tokio::time::timeout(Duration::from_secs(60), client.read(&mut answer))
            .await
            .expect("an answer through the tunnel")
            .unwrap();
        assert_eq!(read, 1);
        stop().await;
    }

    #[tokio::test]
    async fn start_is_idempotent_and_stop_releases_the_listener() {
        let _policy = lock_route_policy();
        let port = start().await.unwrap();
        assert_eq!(start().await.unwrap(), port);
        stop().await;
        assert!(TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port))
            .await
            .is_err());
        stop().await;
    }

    /// The bridge's allowlist is one of several copies of the page's hosts
    /// (reference §8.2, iOS plan XI10). A host missing from any copy fails
    /// silently on a device, so pin them together: Kotlin's
    /// `RailgunEndpoints.hosts`, and the CSP `connect-src` of the bundle's
    /// source, of the Android bundle and of its iOS copy.
    #[test]
    fn the_page_hosts_match_the_kotlin_filter_and_the_page_csp() {
        let mut expected = RAILGUN_PAGE_HOSTS.map(str::to_owned).to_vec();
        expected.sort();
        expected.dedup();
        assert_eq!(expected.len(), 9, "the allowlist has duplicates");

        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        let read = |path: &str| {
            std::fs::read_to_string(repo.join(path))
                .unwrap_or_else(|error| panic!("read {path}: {error}"))
        };

        let kotlin = kotlin_hosts(&read(
            "android/app/src/main/kotlin/com/keplr/vizor/railgun/RailgunEndpoints.kt",
        ));
        assert_eq!(kotlin, expected, "RailgunEndpoints.hosts");
        for page in [
            "android/railgun-web/src/index.html",
            "android/app/src/main/assets/railgun/index.html",
            "ios/Runner/Railgun/railgun/index.html",
        ] {
            assert_eq!(csp_connect_hosts(&read(page)), expected, "{page}");
        }
    }

    /// The string literals inside `val hosts = setOf(…)`, sorted.
    fn kotlin_hosts(source: &str) -> Vec<String> {
        let start = source
            .find("val hosts")
            .expect("`val hosts` in RailgunEndpoints.kt");
        let set = &source[start..];
        let open = set.find("setOf(").expect("`setOf(` after `val hosts`") + "setOf(".len();
        let body = &set[open..open + set[open..].find(')').expect("the end of `setOf(`")];
        let mut hosts: Vec<String> = body
            .split('"')
            .skip(1)
            .step_by(2)
            .map(str::to_owned)
            .collect();
        hosts.sort();
        hosts
    }

    /// The hosts of the CSP's `connect-src` sources other than `'self'`, each
    /// of which must be a bare `https://` origin; sorted.
    fn csp_connect_hosts(html: &str) -> Vec<String> {
        let start = html.find("connect-src").expect("a connect-src directive");
        let directive = &html[start..];
        let directive = &directive[..directive.find(';').expect("the end of connect-src")];
        let mut hosts: Vec<String> = directive
            .split_whitespace()
            .skip(1)
            .filter(|source| *source != "'self'")
            .map(|source| {
                let host = source
                    .strip_prefix("https://")
                    .unwrap_or_else(|| panic!("{source} is not an https origin"));
                assert!(
                    !host.contains(['/', ':', '*']),
                    "{source} is not a bare https origin"
                );
                host.to_owned()
            })
            .collect();
        hosts.sort();
        hosts
    }
}
