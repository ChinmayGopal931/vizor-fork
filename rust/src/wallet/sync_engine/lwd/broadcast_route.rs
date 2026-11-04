//! The Nym broadcast route (added at Free Society Hack, 4 Nov 2026).
//!
//! With the Nym route on, every transaction broadcast opens a fresh Nym
//! mixnet tunnel through `lwd-nym` (github.com/ChinmayGopal931/veylor-nym)
//! instead of the isolated Tor or direct route. Sync and every other request
//! keep the route they had. It fails closed: when no Nym route opens, the
//! broadcast fails before anything is sent, with no fallback to Tor or direct.
//!
//! Each broadcast's route is kept in process memory by txid, so the UI can
//! say which address the light-wallet server saw. Nothing is written to disk,
//! and the user's own IP is never looked up.

use std::collections::VecDeque;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tonic::transport::Channel;
use zcash_primitives::transaction::Transaction;
use zcash_protocol::consensus::BranchId;

use super::super::SyncError;

static NYM_BROADCAST: AtomicBool = AtomicBool::new(false);
static ROUTES: Mutex<VecDeque<(String, BroadcastRoute)>> = Mutex::new(VecDeque::new());
const KEPT_ROUTES: usize = 64;

/// Turns the Nym broadcast route on or off for this process. Dart applies the
/// saved choice at startup, before anything can broadcast.
pub(crate) fn set_nym_broadcast(enabled: bool) {
    NYM_BROADCAST.store(enabled, Ordering::SeqCst);
    log::info!("broadcast route: Nym {}", if enabled { "on" } else { "off" });
}

pub(crate) fn is_nym_broadcast() -> bool {
    NYM_BROADCAST.load(Ordering::SeqCst)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RouteKind {
    Direct,
    Tor,
    Nym,
}

impl RouteKind {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            RouteKind::Direct => "direct",
            RouteKind::Tor => "tor",
            RouteKind::Nym => "nym",
        }
    }
}

/// The route one broadcast went out on.
#[derive(Clone, Debug)]
pub(crate) struct BroadcastRoute {
    pub kind: RouteKind,
    /// The Nym exit's address: what the server saw. `None` off Nym.
    pub exit_ip: Option<IpAddr>,
    pub exit_country: Option<String>,
    /// The server address, as resolved through the tunnel. `None` off Nym.
    pub server: Option<SocketAddr>,
    pub setup: Duration,
    /// Which Nym tunnel the route ran on (1 is the first). 0 off Nym.
    pub tunnel_attempt: u32,
    pub at_unix: u64,
}

impl BroadcastRoute {
    /// Keeps this as the route `raw_tx` was sent over.
    pub(crate) fn record(&self, raw_tx: &[u8]) {
        let Ok(tx) = Transaction::read(raw_tx, BranchId::Sapling) else {
            return;
        };
        let txid = tx.txid().to_string();
        let mut routes = ROUTES.lock().unwrap_or_else(|e| e.into_inner());
        routes.retain(|(id, _)| id != &txid);
        routes.push_back((txid, self.clone()));
        while routes.len() > KEPT_ROUTES {
            routes.pop_front();
        }
    }
}

/// The route `txid` (display hex) was last broadcast over in this process.
pub(crate) fn route_for_txid(txid: &str) -> Option<BroadcastRoute> {
    let txid = txid.trim().to_ascii_lowercase();
    let routes = ROUTES.lock().unwrap_or_else(|e| e.into_inner());
    routes
        .iter()
        .rev()
        .find(|(id, _)| *id == txid)
        .map(|(_, route)| route.clone())
}

/// The most recent broadcast's txid and route.
pub(crate) fn latest_route() -> Option<(String, BroadcastRoute)> {
    let routes = ROUTES.lock().unwrap_or_else(|e| e.into_inner());
    routes.back().cloned()
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Opens the transport for one transaction broadcast: a fresh Nym tunnel when
/// the Nym route is on, else the isolated route (a fresh Tor circuit, or
/// direct). A Nym failure is returned as is: the caller must not fall back.
pub(crate) async fn open_broadcast_lwd_transport(
    lightwalletd_url: &str,
) -> Result<(Channel, BroadcastRoute), SyncError> {
    let started = Instant::now();
    if is_nym_broadcast() {
        let config = lwd_nym::Config::new(lightwalletd_url)
            .map_err(|e| SyncError::net(format!("Nym route: {e}")))?;
        let route = lwd_nym::NymRoute::open(&config)
            .await
            .map_err(|e| SyncError::net(format!("Nym route unavailable: {e}")))?;
        let info = BroadcastRoute {
            kind: RouteKind::Nym,
            exit_ip: Some(route.exit_ip()),
            exit_country: route.exit().country.clone(),
            server: Some(route.server_addr()),
            setup: route.setup_time(),
            tunnel_attempt: route.attempt() as u32,
            at_unix: now_unix(),
        };
        log::info!(
            "broadcast route: Nym tunnel {} ready in {:.1}s, exit {}",
            info.tunnel_attempt,
            info.setup.as_secs_f64(),
            route.exit_ip()
        );
        // The channel's connector holds its own handle on the tunnel, which
        // shuts down once the channel is dropped. Tunnels are never reused.
        let channel = route.channel();
        drop(route);
        return Ok((channel, info));
    }
    let channel = super::open_lwd_transport_for_route(lightwalletd_url, true, || false).await?;
    let kind = if crate::network_privacy::is_tor_desired() {
        RouteKind::Tor
    } else {
        RouteKind::Direct
    };
    Ok((
        channel,
        BroadcastRoute {
            kind,
            exit_ip: None,
            exit_country: None,
            server: None,
            setup: started.elapsed(),
            tunnel_attempt: 0,
            at_unix: now_unix(),
        },
    ))
}
