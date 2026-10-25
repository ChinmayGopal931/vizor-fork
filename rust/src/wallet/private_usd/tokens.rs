//! Privacy Pass tokens for the makers' accepts (plan M4, reference §5.9).
//!
//! A maker that takes tokens answers an unpaid accept `401` with a
//! `WWW-Authenticate` challenge: the pinned issuer's name, its key and the UTC
//! day. The accept is posted again with a token the issuer signed blind for
//! that challenge, and asks for it back under the maker's return key; the
//! maker hands it back, blind-signed, once the user has paid in, so a device
//! walks away from a few conversions a day at most. Neither the issuer nor
//! the maker can tell which of this device's tokens paid for which swap.
//!
//! The state is one file per network, device-wide, never per account: the
//! tokens held, the requests for tokens back, the last challenge a maker
//! asked for, and whether the issuer had no more for this device today. It
//! is written atomically and read leniently (an unreadable file starts
//! empty). Every secret in it is `Redacted`, and nothing here logs more than
//! a status code.
//!
//! Issuance takes two phases around the phone's keystore (X11): `begin`
//! fetches the issuer's key and an attestation challenge and keeps the
//! blinded batch in memory under a session; Dart has the keystore sign the
//! message; `finish` posts the batch with the attestation and holds what
//! comes back. The first `403 rejected` gets one more signature over a fresh
//! attestation challenge (an expired one is refused the same way); the
//! second refuses the device.
//!
//! The maker's challenge is deterministic, `(issuer, "maker", day)`, so a
//! batch is fetched ahead for it as soon as the maker's `/v1/info` shows the
//! pinned return key (D-154): the fetch then never falls inside a quote's
//! window. A maker that asks for another challenge on its first `401` gets
//! paid for that one, and the batch fetched ahead is dropped.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zecswap_tokens::{day, read_www_authenticate, Challenge, Pending, Token, TokenKey};

use super::deployment::{Deployment, QUICK_TIMEOUT};
use super::models::{Direction, Redacted, Word};
use super::transport::{get_json, post_json, HttpTransport, Service, SwapErrorCode, SwapHttpError};
use super::{ErrorCode, PrivateUsdError, Result};

/// How far the maker's clock may be from ours around midnight, when the day
/// it asks tokens for turns.
pub(crate) const CLOCK_SKEW_SECONDS: u64 = 10 * 60;
/// The most one issuance asks for, whatever the issuer publishes.
const MAX_BATCH: u32 = 100;
/// How long an issuance session waits for the keystore's signature.
pub(crate) const SESSION_TTL_SECONDS: u64 = 5 * 60;
/// The origin every maker names in its challenge (`docs/tokens.md`,
/// "Running it", step 5).
const MAKER_ORIGIN: &str = "maker";
/// What the attestation signs, before the issuer's challenge and the batch's
/// digest.
const ATTESTATION_PREFIX: &[u8] = b"zecswap-issuer-v1";
const ATTESTATION_CHALLENGE_BYTES: usize = 32;

/// The issuer and keys this build takes tokens from, and nothing else: a
/// name, key or return key shown to some devices alone would mark their
/// tokens.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TokenPins {
    pub issuer_url: String,
    pub issuer_name: String,
    /// The issuer's key, base64url SPKI.
    pub token_key: String,
    /// The maker's return key, base64url SPKI.
    pub return_key: String,
}

impl TokenPins {
    pub(crate) fn of(pins: &Deployment) -> Self {
        Self {
            issuer_url: pins.issuer_url.into(),
            issuer_name: pins.issuer_name.into(),
            token_key: pins.issuer_token_key.into(),
            return_key: pins.maker_token_return_key.into(),
        }
    }
}

/// An unspent token, with the challenge and key it answers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HeldToken {
    /// The challenge, base64url of its encoding.
    challenge: String,
    /// The key it is under, base64url SPKI: the issuer's, or the return key.
    token_key: String,
    /// The token's encoding, base64url.
    token: Redacted<String>,
}

/// A paid accept's request for its token back: the client's half, which
/// finalizes the maker's signature. More than one for a swap whose accept
/// was tried again.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PendingReturn {
    swap_id: Word,
    /// Which status the swap's return is read from (`/v1/swaps/{id}` or
    /// `/v1/reverse/swaps/{id}`).
    direction: String,
    challenge: String,
    /// `Pending::to_bytes`, base64url: the blinding secret.
    pending: Redacted<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct TokenState {
    /// The last challenge a maker sent, base64url: tokens are fetched ahead
    /// for it, on the day the fetch is for.
    challenge: Option<String>,
    held: Vec<HeldToken>,
    /// The UTC day, counted from the epoch, on which the issuer had no more
    /// tokens for this device.
    exhausted_day: Option<u64>,
    returns: Vec<PendingReturn>,
    /// The issuer that refused this device's attestation when last asked;
    /// none once one has signed for it since.
    refused_by: Option<String>,
    /// The maker's `/v1/info` last showed the pinned return key: it takes
    /// tokens, and a batch is fetched ahead.
    maker_asks: bool,
}

/// The device's token state, as the file keeps it. Every change is written
/// before the call that made it returns.
pub(crate) struct TokenStore {
    path: Option<PathBuf>,
    pins: TokenPins,
    state: RefCell<TokenState>,
}

/// How many paid posts an accept makes before a `401` ends it: a token the
/// maker refuses, spent after all or no longer good, gives way to the next.
pub(crate) const PAID_TRIES: usize = 3;

/// Why a paid accept did not go through.
#[derive(Debug)]
pub(crate) enum AcceptError {
    /// The maker's answer, a `401` apart.
    Http(SwapHttpError),
    /// The maker wants a token and none is held for its challenge (`tried`:
    /// after the paid tries, which it all refused). Nothing opened: a `401`
    /// is answered before the quote is taken.
    TokensNeeded { tried: bool },
    /// Paying failed: a challenge off the pins, none left today, the store.
    Tokens(PrivateUsdError),
}

/// Posts an accept with `post`, paying for it when the maker asks: an unpaid
/// post first, then at most [`PAID_TRIES`] with a token for the challenge
/// each `401` names, settled by their answers. `post(None)` is the accept
/// as it is; `post(Some(payment))` carries the payment's `Authorization`
/// and its `tokenRequest`.
pub(crate) async fn accept_paying<F>(
    tokens: &TokenStore,
    now: u64,
    swap_id: Word,
    direction: Direction,
    post: F,
) -> std::result::Result<super::models::SwapAccepted, AcceptError>
where
    F: AsyncFn(Option<&Payment>) -> std::result::Result<super::models::SwapAccepted, SwapHttpError>,
{
    let mut answer = post(None).await;
    let mut tried = false;
    for _ in 0..PAID_TRIES {
        let Err(SwapHttpError::Refused(refusal)) = &answer else {
            break;
        };
        if refusal.code != Some(SwapErrorCode::TokenRequired) {
            break;
        }
        let Some(asked) = refusal.www_authenticate.as_deref() else {
            break;
        };
        let payment = match tokens.pay(asked, swap_id, direction, now) {
            Ok(payment) => payment,
            Err(error) if error.code == ErrorCode::TokensNeeded => {
                return Err(AcceptError::TokensNeeded { tried });
            }
            Err(error) => return Err(AcceptError::Tokens(error)),
        };
        tried = true;
        let sent = post(Some(&payment)).await;
        // A success that does not read still took the token; a request
        // that never went out left it.
        let status = match &sent {
            Ok(_) | Err(SwapHttpError::Unreadable { .. }) => Some(200),
            Err(SwapHttpError::Refused(refusal)) => Some(refusal.status),
            Err(SwapHttpError::Unreachable { .. } | SwapHttpError::Invalid(_)) => None,
        };
        if let Err(error) = tokens.settle(payment, status) {
            return Err(AcceptError::Tokens(error));
        }
        answer = sent;
    }
    match answer {
        Ok(accepted) => Ok(accepted),
        Err(SwapHttpError::Refused(refusal))
            if refusal.code == Some(SwapErrorCode::TokenRequired) =>
        {
            Err(AcceptError::TokensNeeded { tried })
        }
        Err(error) => Err(AcceptError::Http(error)),
    }
}

/// What an accept pays with: the `Authorization` header, the `tokenRequest`
/// for the token back, and what to settle once the maker answers.
#[derive(Clone, Debug)]
pub(crate) struct Payment {
    pub authorization: Redacted<String>,
    /// The blinded request for the token back, base64url.
    pub token_request: Redacted<String>,
    token: HeldToken,
    pending: PendingReturn,
}

/// What the device holds, for the screens.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct TokenStatus {
    /// Tokens held for today.
    pub held: u32,
    pub exhausted_today: bool,
    /// Swaps whose token is still to come back.
    pub awaiting_returns: u32,
    pub device_refused: bool,
    /// The maker takes tokens (its info shows the pinned return key).
    pub maker_asks: bool,
}

/// `GET /v1/token-key`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PublishedKey {
    issuer: String,
    token_key: String,
    tokens_per_day: u32,
}

/// `GET /v1/challenge`.
#[derive(Debug, Deserialize)]
struct AttestationChallenge {
    challenge: String,
}

/// `POST /v1/tokens`: exactly the issuer's fields, which refuses any other.
#[derive(Debug, Serialize)]
struct TokenRequests {
    attestation: Attestation,
    blinded: Vec<String>,
}

#[derive(Debug, Serialize)]
struct Attestation {
    challenge: String,
    chain: Vec<String>,
    signature: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TokenResponses {
    blind_signatures: Vec<String>,
}

/// An issuance waiting for the keystore's signature: the blinded batch and
/// the attestation challenge it is for.
struct Session {
    pins: TokenPins,
    challenge: Challenge,
    pendings: Vec<Vec<u8>>,
    blinded: Vec<Vec<u8>>,
    /// The issuer's attestation challenge, base64url as given.
    attestation: String,
    expires_at: u64,
    /// The first `403 rejected` was retried with a fresh challenge.
    retried: bool,
}

static SESSIONS: LazyLock<Mutex<HashMap<u64, Session>>> = LazyLock::new(Default::default);
static NEXT_SESSION: AtomicU64 = AtomicU64::new(1);

/// The first phase of an issuance: what the keystore signs.
#[derive(Clone, Debug)]
pub(crate) struct Issuance {
    pub session_id: u64,
    pub issuer_name: String,
    /// `"zecswap-issuer-v1" ‖ challenge ‖ SHA-256(blinded₁ ‖ … ‖ blindedₙ)`.
    pub message: Vec<u8>,
}

/// How the second phase ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Finished {
    /// Tokens are held; `short` when the issuer signed fewer than asked, so
    /// today is spent too.
    Issued { held: u32, short: bool },
    /// The issuer had none left for this device today.
    Exhausted,
    /// The first refusal: sign this message, for a fresh attestation
    /// challenge, and finish again with the same session.
    SignAgain { message: Vec<u8> },
}

fn sessions() -> std::sync::MutexGuard<'static, HashMap<u64, Session>> {
    SESSIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Forgets every issuance under way: the wallet locked.
pub(crate) fn clear_sessions() {
    sessions().clear();
}

fn encode_challenge(challenge: &Challenge) -> String {
    URL_SAFE_NO_PAD.encode(challenge.encode())
}

fn decode_challenge(encoded: &str) -> Option<Challenge> {
    Challenge::decode(&URL_SAFE_NO_PAD.decode(encoded).ok()?).ok()
}

/// The day an encoded challenge is for, if it reads.
fn challenge_day(encoded: &str) -> Option<u64> {
    decode_challenge(encoded).map(|challenge| challenge.day())
}

/// The first day a maker's clock may still be on.
fn earliest_day(now: u64) -> u64 {
    day(now.saturating_sub(CLOCK_SKEW_SECONDS))
}

fn refused(message: impl Into<String>) -> PrivateUsdError {
    PrivateUsdError::new(ErrorCode::TokensRefused, message)
}

fn unreachable(message: impl Into<String>) -> PrivateUsdError {
    PrivateUsdError::new(ErrorCode::TokensUnreachable, message)
}

fn key(encoded: &str, what: &str) -> Result<TokenKey> {
    TokenKey::from_base64(encoded).map_err(|_| refused(format!("the pinned {what} does not read")))
}

impl TokenStore {
    /// Opens the device's store at `path`, creating it on the first write.
    /// An unreadable file starts empty: tokens are a day's convenience, and
    /// the chain holds every swap.
    pub(crate) fn open(path: &Path, pins: TokenPins) -> Self {
        let state = fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            path: Some(path.to_owned()),
            pins,
            state: RefCell::new(state),
        }
    }

    /// A store kept in memory alone, for calls that neither pay nor
    /// collect.
    pub(crate) fn detached(pins: TokenPins) -> Self {
        Self {
            path: None,
            pins,
            state: RefCell::default(),
        }
    }

    pub(crate) fn pins(&self) -> &TokenPins {
        &self.pins
    }

    /// Writes the state as it stands: to a temporary file beside the store,
    /// synced, then renamed over it, so a crash leaves the old state whole.
    fn save(&self) -> Result<()> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        let bytes = serde_json::to_vec(&*self.state.borrow())
            .map_err(|error| store_error(format!("the token state does not encode: {error}")))?;
        let temporary = path.with_extension("json.tmp");
        let write = || -> std::io::Result<()> {
            let mut file = fs::File::create(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temporary, path)
        };
        write().map_err(|error| store_error(format!("the token store: {error}")))
    }

    fn update<R>(&self, change: impl FnOnce(&mut TokenState) -> R) -> Result<R> {
        let result = change(&mut self.state.borrow_mut());
        self.save()?;
        Ok(result)
    }

    /// Records whether the maker takes tokens.
    pub(crate) fn set_maker_asks(&self, asks: bool) -> Result<()> {
        if self.state.borrow().maker_asks == asks {
            return Ok(());
        }
        self.update(|state| state.maker_asks = asks)
    }

    pub(crate) fn maker_asks(&self) -> bool {
        self.state.borrow().maker_asks
    }

    pub(crate) fn status(&self, now: u64) -> TokenStatus {
        let state = self.state.borrow();
        let today = day(now);
        let earliest = earliest_day(now);
        TokenStatus {
            held: state
                .held
                .iter()
                .filter(|held| challenge_day(&held.challenge) == Some(today))
                .count() as u32,
            exhausted_today: state.exhausted_day == Some(today),
            awaiting_returns: state
                .returns
                .iter()
                .filter(|pending| {
                    challenge_day(&pending.challenge).is_some_and(|day| day >= earliest)
                })
                .fold(Vec::new(), |mut swaps, pending| {
                    if !swaps.contains(&pending.swap_id) {
                        swaps.push(pending.swap_id);
                    }
                    swaps
                })
                .len() as u32,
            device_refused: state.refused_by.as_deref() == Some(self.pins.issuer_name.as_str()),
            maker_asks: state.maker_asks,
        }
    }

    // ---- paying ----

    /// A token for what the maker's `WWW-Authenticate` asks, and the request
    /// for it back, kept before the token leaves. The issuer's tokens go
    /// first: a returned one spent soon after it came back could be tied to
    /// the swap that returned it, so it goes only once the issuer has none
    /// left today. `TokensRefused` for a challenge off the pins or another
    /// day; `TokensNeeded` when none is held and the issuer may still have
    /// some, with the challenge kept for the issuance; `NoTokensToday` once
    /// it has none and none came back.
    pub(crate) fn pay(
        &self,
        asked: &str,
        swap_id: Word,
        direction: Direction,
        now: u64,
    ) -> Result<Payment> {
        let (challenge, asked_key) = read_www_authenticate(asked)
            .map_err(|_| refused("the maker's token challenge does not read"))?;
        if challenge.issuer() != self.pins.issuer_name
            || asked_key.to_base64() != self.pins.token_key
        {
            return Err(refused(
                "the maker asks for tokens the pinned issuer does not sign",
            ));
        }
        let today = challenge.day();
        if !(earliest_day(now)..=day(now.saturating_add(CLOCK_SKEW_SECONDS))).contains(&today) {
            return Err(refused("the maker asks for tokens for another day"));
        }
        let encoded = encode_challenge(&challenge);
        let return_key = key(&self.pins.return_key, "return key")?;
        let taken = self.update(|state| {
            state.since(today);
            state.challenge = Some(encoded.clone());
            state.maker_asks = true;
            // A batch fetched ahead for another challenge of the same day
            // answers nothing the maker asks: it is dropped.
            state.held.retain(|held| {
                held.challenge == encoded || challenge_day(&held.challenge) != Some(today)
            });
            let issuer = state.held.iter().position(|held| {
                held.challenge == encoded && held.token_key == self.pins.token_key
            });
            let exhausted = state.exhausted_day == Some(today);
            let returned = || {
                state.held.iter().position(|held| {
                    held.challenge == encoded && held.token_key == self.pins.return_key
                })
            };
            match issuer.or_else(|| if exhausted { returned() } else { None }) {
                Some(at) => Ok(state.held.remove(at)),
                None if exhausted => Err(PrivateUsdError::new(
                    ErrorCode::NoTokensToday,
                    "this device's tokens for today are spent",
                )),
                None => Err(PrivateUsdError::new(
                    ErrorCode::TokensNeeded,
                    "no token is held for the maker's challenge",
                )),
            }
        })??;
        let token = Token::decode(
            &URL_SAFE_NO_PAD
                .decode(&taken.token.0)
                .map_err(|_| store_error("a held token does not read"))?,
        )
        .map_err(|_| store_error("a held token does not read"))?;
        let (pending, blinded) = Pending::new(&return_key, &challenge)
            .map_err(|error| unreachable(format!("the token request: {error}")))?;
        let pending = PendingReturn {
            swap_id,
            direction: direction.as_str().into(),
            challenge: encoded,
            pending: Redacted(URL_SAFE_NO_PAD.encode(pending.to_bytes())),
        };
        self.update(|state| state.returns.push(pending.clone()))?;
        Ok(Payment {
            authorization: Redacted(token.authorization()),
            token_request: Redacted(URL_SAFE_NO_PAD.encode(blinded)),
            token: taken,
            pending,
        })
    }

    /// Settles an accept paid with `payment` once the maker answered
    /// `status`, or none if the answer was lost. A token the maker took
    /// (`2xx`) is gone, and so is one it refused (`401`), whose request for
    /// it back it never saw either. Any other answer, or none, left the
    /// token spendable: it goes first next time, and a maker that kept it
    /// after all refuses it then.
    pub(crate) fn settle(&self, payment: Payment, status: Option<u16>) -> Result<()> {
        let Payment { token, pending, .. } = payment;
        match status {
            Some(401) => self.update(|state| state.returns.retain(|kept| *kept != pending)),
            Some(200..=299) => Ok(()),
            _ => self.update(|state| state.held.insert(0, token)),
        }
    }

    /// Whether a swap's token is still to come back.
    pub(crate) fn awaits_return(&self, swap_id: &Word, now: u64) -> bool {
        let earliest = earliest_day(now);
        self.state.borrow().returns.iter().any(|pending| {
            pending.swap_id == *swap_id
                && challenge_day(&pending.challenge).is_some_and(|day| day >= earliest)
        })
    }

    /// The swaps whose tokens are still to come back, with the direction
    /// each one's status is read from.
    pub(crate) fn pending_returns(&self, now: u64) -> Vec<(Word, Direction)> {
        let earliest = earliest_day(now);
        let mut swaps = Vec::new();
        for pending in &self.state.borrow().returns {
            if challenge_day(&pending.challenge).is_none_or(|day| day < earliest) {
                continue;
            }
            let direction = match pending.direction.as_str() {
                "reverse" => Direction::Reverse,
                _ => Direction::Forward,
            };
            if !swaps.contains(&(pending.swap_id, direction)) {
                swaps.push((pending.swap_id, direction));
            }
        }
        swaps
    }

    /// Holds the token the maker hands back for `swap_id`, under the return
    /// key, for its accept's challenge: the maker signed one of the swap's
    /// requests, the one its accept went through with. The swap's requests
    /// are dropped either way, a return for an earlier day unread. Whether a
    /// token is held now.
    pub(crate) fn collect(&self, swap_id: &Word, token_return: &str, now: u64) -> Result<bool> {
        let return_key = key(&self.pins.return_key, "return key")?;
        let earliest = earliest_day(now);
        let signature = URL_SAFE_NO_PAD.decode(token_return).ok();
        self.update(|state| {
            let (requests, kept): (Vec<_>, Vec<_>) = state
                .returns
                .drain(..)
                .partition(|pending| pending.swap_id == *swap_id);
            state.returns = kept;
            let Some(signature) = signature else {
                return false;
            };
            for request in requests {
                if challenge_day(&request.challenge).is_none_or(|day| day < earliest) {
                    continue;
                }
                let Some(token) = URL_SAFE_NO_PAD
                    .decode(&request.pending.0)
                    .ok()
                    .and_then(|bytes| Pending::from_bytes(&bytes).ok())
                    .and_then(|pending| pending.finalize(&return_key, &signature).ok())
                else {
                    continue;
                };
                state.held.push(HeldToken {
                    challenge: request.challenge,
                    token_key: self.pins.return_key.clone(),
                    token: Redacted(URL_SAFE_NO_PAD.encode(token.encode())),
                });
                return true;
            }
            false
        })
    }

    // ---- issuance ----

    /// The challenge a batch is fetched ahead for: the last a maker sent,
    /// moved to today, else the maker's deterministic one once its info
    /// showed it takes tokens. None while no maker asks.
    fn prefetch_challenge(&self, now: u64) -> Option<Challenge> {
        let state = self.state.borrow();
        let today = day(now);
        if let Some(last) = state.challenge.as_deref().and_then(decode_challenge) {
            return Some(last.on(today));
        }
        if !state.maker_asks {
            return None;
        }
        Challenge::new(&self.pins.issuer_name, MAKER_ORIGIN, today).ok()
    }

    /// Starts an issuance for today's challenge: `None` when nothing is
    /// needed (no maker asks, a token is held for it, or today is spent).
    /// Checks the key the issuer publishes against the pins, blinds the
    /// batch and fetches an attestation challenge, over `transport`, and
    /// keeps the batch under a session for the keystore's signature.
    pub(crate) async fn begin<T: HttpTransport>(
        &self,
        transport: &T,
        now: u64,
    ) -> Result<Option<Issuance>> {
        let Some(challenge) = self.prefetch_challenge(now) else {
            return Ok(None);
        };
        let encoded = encode_challenge(&challenge);
        {
            let mut state = self.state.borrow_mut();
            state.since(earliest_day(now));
            let held = state
                .held
                .iter()
                .any(|held| held.challenge == encoded && held.token_key == self.pins.token_key);
            if held || state.exhausted_day == Some(challenge.day()) {
                return Ok(None);
            }
        }
        self.save()?;
        let published: PublishedKey = get_json(
            transport,
            Service::Issuer,
            format!(
                "{}/v1/token-key",
                self.pins.issuer_url.trim_end_matches('/')
            ),
            |_| Ok(()),
        )
        .await
        .map_err(issuer_error)?;
        if published.issuer != self.pins.issuer_name || published.token_key != self.pins.token_key {
            return Err(refused(
                "the issuer publishes another key than the pinned one",
            ));
        }
        let token_key = key(&self.pins.token_key, "token key")?;
        let batch = published.tokens_per_day.clamp(1, MAX_BATCH);
        let mut pendings = Vec::with_capacity(batch as usize);
        let mut blinded = Vec::with_capacity(batch as usize);
        for _ in 0..batch {
            let (pending, request) = Pending::new(&token_key, &challenge)
                .map_err(|error| unreachable(format!("the token request: {error}")))?;
            pendings.push(pending.to_bytes());
            blinded.push(request);
        }
        let attestation = self.attestation_challenge(transport).await?;
        let message = attestation_message(&attestation, &blinded)?;
        let session_id = NEXT_SESSION.fetch_add(1, Ordering::Relaxed);
        sessions().retain(|_, session| session.expires_at > now);
        sessions().insert(
            session_id,
            Session {
                pins: self.pins.clone(),
                challenge,
                pendings,
                blinded,
                attestation,
                expires_at: now + SESSION_TTL_SECONDS,
                retried: false,
            },
        );
        Ok(Some(Issuance {
            session_id,
            issuer_name: self.pins.issuer_name.clone(),
            message,
        }))
    }

    /// Finishes the issuance `session_id` with the keystore's attestation:
    /// the key's certificate `chain` (leaf first, DER, base64url) and its
    /// `signature` over the session's message. Holds what the issuer signs.
    pub(crate) async fn finish<T: HttpTransport>(
        &self,
        transport: &T,
        session_id: u64,
        chain: Vec<String>,
        signature: String,
        now: u64,
    ) -> Result<Finished> {
        let session = sessions()
            .remove(&session_id)
            .filter(|session| session.expires_at > now);
        let Some(mut session) = session else {
            return Err(unreachable("the issuance ran out: begin again"));
        };
        if session.pins != self.pins {
            return Err(refused("the issuance is another network's"));
        }
        let request = TokenRequests {
            attestation: Attestation {
                challenge: session.attestation.clone(),
                chain,
                signature,
            },
            blinded: session
                .blinded
                .iter()
                .map(|request| URL_SAFE_NO_PAD.encode(request))
                .collect(),
        };
        let today = session.challenge.day();
        let answer: std::result::Result<TokenResponses, SwapHttpError> = post_json(
            transport,
            Service::Issuer,
            format!("{}/v1/tokens", self.pins.issuer_url.trim_end_matches('/')),
            &request,
            QUICK_TIMEOUT,
            &[],
            |_| Ok(()),
        )
        .await;
        let issued = match answer {
            Ok(issued) => issued,
            Err(SwapHttpError::Refused(refusal)) if refusal.status == 429 => {
                self.update(|state| state.exhausted_day = Some(today))?;
                return Ok(Finished::Exhausted);
            }
            Err(SwapHttpError::Refused(refusal))
                if refusal.status == 403 && refusal.code == Some(SwapErrorCode::Rejected) =>
            {
                if !session.retried {
                    // An attestation challenge that ran out is refused the
                    // same way: once more, over a fresh one.
                    session.attestation = self.attestation_challenge(transport).await?;
                    session.retried = true;
                    session.expires_at = now + SESSION_TTL_SECONDS;
                    let message = attestation_message(&session.attestation, &session.blinded)?;
                    sessions().insert(session_id, session);
                    return Ok(Finished::SignAgain { message });
                }
                self.update(|state| state.refused_by = Some(self.pins.issuer_name.clone()))?;
                return Err(PrivateUsdError::new(
                    ErrorCode::TokensDeviceRefused,
                    format!("the issuer refused this device: {}", refusal.reason),
                ));
            }
            Err(error) => return Err(issuer_error(error)),
        };
        let asked = session.pendings.len();
        if !(1..=asked).contains(&issued.blind_signatures.len()) {
            return Err(unreachable(format!(
                "the issuer signed {} tokens of {asked}",
                issued.blind_signatures.len()
            )));
        }
        let token_key = key(&self.pins.token_key, "token key")?;
        let encoded = encode_challenge(&session.challenge);
        let mut tokens = Vec::with_capacity(issued.blind_signatures.len());
        for (pending, signature) in session.pendings.iter().zip(&issued.blind_signatures) {
            let signature = URL_SAFE_NO_PAD
                .decode(signature)
                .map_err(|_| unreachable("the issuer's signature does not read"))?;
            let token = Pending::from_bytes(pending)
                .map_err(|_| unreachable("the pending token does not read"))?
                .finalize(&token_key, &signature)
                .map_err(|_| unreachable("the issuer's signature does not finalize"))?;
            token
                .verify(&token_key, &session.challenge)
                .map_err(|_| unreachable("the issuer's token does not verify"))?;
            tokens.push(HeldToken {
                challenge: encoded.clone(),
                token_key: self.pins.token_key.clone(),
                token: Redacted(URL_SAFE_NO_PAD.encode(token.encode())),
            });
        }
        let short = tokens.len() < asked;
        let held = self.update(|state| {
            state.held.extend(tokens);
            if short {
                state.exhausted_day = Some(today);
            }
            state.refused_by = None;
            state
                .held
                .iter()
                .filter(|held| held.challenge == encoded)
                .count() as u32
        })?;
        Ok(Finished::Issued { held, short })
    }

    /// `GET /v1/challenge`: good once, for minutes, so asked for right before
    /// each signature.
    async fn attestation_challenge<T: HttpTransport>(&self, transport: &T) -> Result<String> {
        let answer: AttestationChallenge = get_json(
            transport,
            Service::Issuer,
            format!(
                "{}/v1/challenge",
                self.pins.issuer_url.trim_end_matches('/')
            ),
            |_| Ok(()),
        )
        .await
        .map_err(issuer_error)?;
        let bytes = URL_SAFE_NO_PAD
            .decode(&answer.challenge)
            .map_err(|_| unreachable("the issuer's challenge does not read"))?;
        if bytes.len() != ATTESTATION_CHALLENGE_BYTES {
            return Err(unreachable("the issuer's challenge is not 32 bytes"));
        }
        Ok(answer.challenge)
    }
}

impl TokenState {
    /// Drops the tokens and requests of days before `day`: earlier days'
    /// tokens are refused, and so would be the tokens their requests become.
    fn since(&mut self, day: u64) {
        self.held
            .retain(|held| challenge_day(&held.challenge).is_some_and(|held| held >= day));
        self.returns
            .retain(|pending| challenge_day(&pending.challenge).is_some_and(|held| held >= day));
    }
}

/// What the keystore signs: the prefix, the attestation challenge's 32 bytes
/// and the digest of the blinded requests in order.
fn attestation_message(attestation: &str, blinded: &[Vec<u8>]) -> Result<Vec<u8>> {
    let challenge = URL_SAFE_NO_PAD
        .decode(attestation)
        .map_err(|_| unreachable("the issuer's challenge does not read"))?;
    let mut digest = Sha256::new();
    for request in blinded {
        digest.update(request);
    }
    let mut message = ATTESTATION_PREFIX.to_vec();
    message.extend(challenge);
    message.extend(digest.finalize());
    Ok(message)
}

fn store_error(message: impl Into<String>) -> PrivateUsdError {
    PrivateUsdError::new(ErrorCode::StoreUnreadable, message)
}

/// An issuer answer that is no issuance: unreachable, unless it refused the
/// request as malformed, which is a bug on this side.
fn issuer_error(error: SwapHttpError) -> PrivateUsdError {
    match &error {
        SwapHttpError::Refused(refusal) => {
            log::warn!(
                "private usd: the token issuer answered {} ({:?})",
                refusal.status,
                refusal.code
            );
        }
        SwapHttpError::Unreachable { .. } => {
            log::warn!("private usd: the token issuer is unreachable");
        }
        SwapHttpError::Unreadable { .. } | SwapHttpError::Invalid(_) => {
            log::warn!("private usd: the token issuer's answer does not read");
        }
    }
    unreachable(error.to_string())
}

#[cfg(test)]
pub(crate) mod test_support {
    //! A fake issuer's keys and the answers a token gate gives, for the
    //! driver tests and this module's.

    use zecswap_tokens::{www_authenticate, IssuerKey};

    use super::*;

    /// The issuer's signing key and the maker's return key, both generated,
    /// with pins naming them.
    pub(crate) struct FakeIssuer {
        pub key: IssuerKey,
        pub return_key: IssuerKey,
        pub name: String,
        pub url: String,
    }

    impl FakeIssuer {
        pub(crate) fn new(url: &str, name: &str) -> Self {
            Self {
                key: IssuerKey::generate().unwrap(),
                return_key: IssuerKey::generate().unwrap(),
                name: name.into(),
                url: url.into(),
            }
        }

        pub(crate) fn pins(&self) -> TokenPins {
            TokenPins {
                issuer_url: self.url.clone(),
                issuer_name: self.name.clone(),
                token_key: self.key.token_key().to_base64(),
                return_key: self.return_key.token_key().to_base64(),
            }
        }

        /// The maker's challenge for `day`.
        pub(crate) fn challenge(&self, day: u64) -> Challenge {
            Challenge::new(&self.name, MAKER_ORIGIN, day).unwrap()
        }

        /// What a maker asks an unpaid accept for `day` with.
        pub(crate) fn www_authenticate(&self, day: u64) -> String {
            www_authenticate(&self.challenge(day), self.key.token_key())
        }

        /// Whether `authorization` spends a token this issuer signed for
        /// `day`'s challenge, or one the maker handed back.
        pub(crate) fn accepts(&self, authorization: &str, day: u64) -> bool {
            let Ok(token) = Token::from_authorization(authorization) else {
                return false;
            };
            let challenge = self.challenge(day);
            token.verify(self.key.token_key(), &challenge).is_ok()
                || token
                    .verify(self.return_key.token_key(), &challenge)
                    .is_ok()
        }

        /// The blind signature of a `tokenRequest` under the return key:
        /// what a swap's status hands back.
        pub(crate) fn token_return(&self, token_request: &str) -> String {
            let blinded = URL_SAFE_NO_PAD.decode(token_request).unwrap();
            URL_SAFE_NO_PAD.encode(self.return_key.sign(&blinded).unwrap())
        }

        /// The issuer's blind signatures for the first `count` of `blinded`
        /// (base64url), as `POST /v1/tokens` answers.
        pub(crate) fn sign(&self, blinded: &[String], count: usize) -> Vec<String> {
            blinded
                .iter()
                .take(count)
                .map(|request| {
                    let request = URL_SAFE_NO_PAD.decode(request).unwrap();
                    URL_SAFE_NO_PAD.encode(self.key.sign(&request).unwrap())
                })
                .collect()
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use serde_json::{json, Value};

    use super::test_support::FakeIssuer;
    use super::*;
    use crate::wallet::private_usd::models::Hex;
    use crate::wallet::private_usd::transport::test_support::ScriptedTransport;
    use crate::wallet::routed_http::{RoutedError, RoutedRequest, RoutedResponse};

    const NOW: u64 = 20_000 * 86_400 + 3_600;
    const TODAY: u64 = 20_000;
    const ISSUER_URL: &str = "https://issuer.test/issuer";

    fn swap(id: u8) -> Word {
        Hex([id; 32])
    }

    fn store(issuer: &FakeIssuer) -> (tempfile::TempDir, TokenStore) {
        let dir = tempfile::tempdir().unwrap();
        let store = TokenStore::open(
            &dir.path().join("private_usd_tokens_testnet.json"),
            issuer.pins(),
        );
        (dir, store)
    }

    fn json_response(status: u16, body: Value) -> RoutedResponse {
        RoutedResponse {
            status,
            headers: vec![("content-type".into(), "application/json".into())],
            body: serde_json::to_vec(&body).unwrap(),
        }
    }

    /// The issuer's API over a scripted transport: `token-key` and
    /// `challenge` always answer; `tokens` answers per `answer`, which sees
    /// the posted body.
    fn issuer_transport(
        issuer: &FakeIssuer,
        tokens_per_day: u32,
        answer: impl Fn(&Value) -> RoutedResponse + 'static,
    ) -> ScriptedTransport<
        impl Fn(&RoutedRequest) -> std::result::Result<RoutedResponse, RoutedError>,
    > {
        let name = issuer.name.clone();
        let key = issuer.key.token_key().to_base64();
        let challenges = RefCell::new(0u8);
        ScriptedTransport::new(move |request: &RoutedRequest| {
            Ok(if request.url.ends_with("/v1/token-key") {
                json_response(
                    200,
                    json!({ "issuer": name, "tokenKey": key, "tokensPerDay": tokens_per_day }),
                )
            } else if request.url.ends_with("/v1/challenge") {
                *challenges.borrow_mut() += 1;
                let challenge = [*challenges.borrow(); 32];
                json_response(
                    200,
                    json!({ "challenge": URL_SAFE_NO_PAD.encode(challenge) }),
                )
            } else if request.url.ends_with("/v1/tokens") {
                let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
                answer(&body)
            } else {
                panic!("an unexpected request: {}", request.url)
            })
        })
    }

    fn blinded_of(body: &Value) -> Vec<String> {
        body["blinded"]
            .as_array()
            .unwrap()
            .iter()
            .map(|request| request.as_str().unwrap().to_owned())
            .collect()
    }

    /// Runs an issuance to the end on `transport`, signing nothing real
    /// (the fake issuer never checks the attestation).
    async fn issue<T: HttpTransport>(store: &TokenStore, transport: &T) -> Result<Finished> {
        let issuance = store
            .begin(transport, NOW)
            .await?
            .expect("an issuance is needed");
        assert_eq!(issuance.issuer_name, store.pins().issuer_name);
        store
            .finish(
                transport,
                issuance.session_id,
                vec!["leaf".into()],
                "sig".into(),
                NOW,
            )
            .await
    }

    fn asked(store: &TokenStore) {
        store.update(|state| state.maker_asks = true).unwrap();
    }

    #[tokio::test]
    async fn a_batch_is_fetched_ahead_once_the_maker_asks_and_held_for_its_challenge() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        let signing = issuer_transport(&issuer, 3, {
            let key = IssuerKeyHandle(issuer.key.to_pem().unwrap());
            move |body| {
                let signed = key.sign(&blinded_of(body), 3);
                json_response(200, json!({ "blindSignatures": signed }))
            }
        });
        // No maker asks: nothing is fetched, nothing asked.
        assert!(store.begin(&signing, NOW).await.unwrap().is_none());
        assert!(signing.sent.borrow().is_empty());

        asked(&store);
        assert_eq!(
            issue(&store, &signing).await.unwrap(),
            Finished::Issued {
                held: 3,
                short: false
            }
        );
        let status = store.status(NOW);
        assert_eq!(
            (status.held, status.exhausted_today, status.maker_asks),
            (3, false, true)
        );
        // Held for today's challenge: the next begin has nothing to do.
        assert!(store.begin(&signing, NOW).await.unwrap().is_none());

        // The requests: the key, the challenge, then the batch with exactly
        // the issuer's fields and the message it signs.
        let sent = signing.sent.borrow();
        let paths: Vec<&str> = sent
            .iter()
            .map(|request| request.url.rsplit('/').next().unwrap())
            .collect();
        assert_eq!(paths, ["token-key", "challenge", "tokens"]);
        let body: Value = serde_json::from_slice(sent[2].body.as_ref().unwrap()).unwrap();
        let keys = |value: &Value| {
            let mut keys: Vec<String> = value.as_object().unwrap().keys().cloned().collect();
            keys.sort();
            keys
        };
        assert_eq!(keys(&body), ["attestation", "blinded"]);
        assert_eq!(
            keys(&body["attestation"]),
            ["chain", "challenge", "signature"]
        );
        assert_eq!(body["attestation"]["chain"], json!(["leaf"]));
        assert_eq!(body["attestation"]["signature"], json!("sig"));
        assert_eq!(blinded_of(&body).len(), 3);
    }

    /// The message the keystore signs: the prefix, the challenge's 32 bytes
    /// and the digest of the blinded requests in order (the brief's vector).
    #[test]
    fn the_attestation_message_is_the_prefix_the_challenge_and_the_batchs_digest() {
        let challenge: Vec<u8> = (0u8..32).collect();
        let blinded = vec![vec![1u8; 256], vec![2u8; 256]];
        let message = attestation_message(&URL_SAFE_NO_PAD.encode(&challenge), &blinded).unwrap();
        assert_eq!(
            hex::encode(&message),
            format!(
                "7a6563737761702d6973737565722d7631{}{}",
                hex::encode(&challenge),
                "b9a2dbf19e3661e507906ce4b54e4a0280b6743ebc408de670a04603f786d350"
            )
        );
        // The key challenge an install attests with, for the two issuers.
        let key_challenge = |issuer: &str| {
            hex::encode(Sha256::digest(
                [ATTESTATION_PREFIX, issuer.as_bytes()].concat(),
            ))
        };
        assert_eq!(
            key_challenge("zecswap-testnet-issuer"),
            "f5cbc5e3281d0519f8ae7efb241c7c10b7d2d52f3bde46703d1ecd0fd5613488"
        );
        assert_eq!(
            key_challenge("zecswap-mainnet-issuer"),
            "468b7cbef07c884fec0ad6245b371dd8fc340b6d09d91fffd5b56b1ec5d942e6"
        );
    }

    #[tokio::test]
    async fn an_issuer_publishing_another_key_or_name_is_refused_before_anything_is_blinded() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        asked(&store);
        let other = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let other_key = issuer_transport(&other, 3, |_| {
            json_response(200, json!({ "blindSignatures": [] }))
        });
        let error = store.begin(&other_key, NOW).await.unwrap_err();
        assert_eq!(error.code, ErrorCode::TokensRefused);
        assert_eq!(other_key.sent.borrow().len(), 1, "only the key was asked");

        let mut renamed = issuer.pins();
        renamed.issuer_name = "someone-else".into();
        let dir = tempfile::tempdir().unwrap();
        let renamed_store = TokenStore::open(&dir.path().join("t.json"), renamed);
        asked(&renamed_store);
        let same_issuer = issuer_transport(&issuer, 3, |_| {
            json_response(200, json!({ "blindSignatures": [] }))
        });
        assert_eq!(
            store_code(renamed_store.begin(&same_issuer, NOW).await),
            ErrorCode::TokensRefused
        );
    }

    fn store_code<T>(result: Result<T>) -> ErrorCode {
        result.err().map(|error| error.code).expect("an error")
    }

    #[tokio::test]
    async fn a_short_batch_or_a_429_marks_today_spent() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        asked(&store);
        let short = issuer_transport(&issuer, 3, {
            let key = IssuerKeyHandle(issuer.key.to_pem().unwrap());
            move |body| {
                json_response(
                    200,
                    json!({ "blindSignatures": key.sign(&blinded_of(body), 2) }),
                )
            }
        });
        assert_eq!(
            issue(&store, &short).await.unwrap(),
            Finished::Issued {
                held: 2,
                short: true
            }
        );
        assert!(store.status(NOW).exhausted_today);

        let (_dir, store) = self::store(&issuer);
        asked(&store);
        let spent = issuer_transport(&issuer, 3, |_| {
            json_response(429, json!({ "code": "rejected" }))
        });
        assert_eq!(issue(&store, &spent).await.unwrap(), Finished::Exhausted);
        assert!(store.status(NOW).exhausted_today);
        assert!(
            store.begin(&spent, NOW).await.unwrap().is_none(),
            "nothing more today"
        );

        // Too many signatures, or none on a 2xx, is no issuance.
        let (_dir, store) = self::store(&issuer);
        asked(&store);
        let too_many = issuer_transport(&issuer, 2, {
            let key = IssuerKeyHandle(issuer.key.to_pem().unwrap());
            move |body| {
                let mut signed = key.sign(&blinded_of(body), 2);
                signed.push(signed[0].clone());
                json_response(200, json!({ "blindSignatures": signed }))
            }
        });
        assert_eq!(
            store_code(issue(&store, &too_many).await),
            ErrorCode::TokensUnreachable
        );
        assert_eq!(store.status(NOW).held, 0);
    }

    #[tokio::test]
    async fn a_refusal_is_signed_again_once_over_a_fresh_challenge_then_refuses_the_device() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        asked(&store);
        let refusing = issuer_transport(&issuer, 3, |_| {
            json_response(
                403,
                json!({ "code": "rejected", "error": "bootloader unlocked" }),
            )
        });
        let first = store.begin(&refusing, NOW).await.unwrap().unwrap();
        let again = store
            .finish(&refusing, first.session_id, vec![], "sig".into(), NOW)
            .await
            .unwrap();
        let Finished::SignAgain { message } = again else {
            panic!("{again:?}");
        };
        // The same batch, a new challenge.
        assert_ne!(message, first.message);
        assert_eq!(message[..17], first.message[..17]);
        assert_eq!(message[49..], first.message[49..], "the batch's digest");
        assert!(!store.status(NOW).device_refused);

        let error = store
            .finish(&refusing, first.session_id, vec![], "sig2".into(), NOW)
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::TokensDeviceRefused);
        assert!(error.message.contains("bootloader unlocked"));
        assert!(store.status(NOW).device_refused);
        {
            let sent = refusing.sent.borrow();
            let posts: Vec<Value> = sent
                .iter()
                .filter(|request| request.url.ends_with("/v1/tokens"))
                .map(|request| serde_json::from_slice(request.body.as_ref().unwrap()).unwrap())
                .collect();
            assert_eq!(posts.len(), 2);
            assert_eq!(blinded_of(&posts[0]), blinded_of(&posts[1]));
            assert_ne!(
                posts[0]["attestation"]["challenge"],
                posts[1]["attestation"]["challenge"]
            );
        }
        // The session died with the refusal, and an issuance that signs for
        // the device clears the refusal.
        assert_eq!(
            store_code(
                store
                    .finish(&refusing, first.session_id, vec![], "x".into(), NOW)
                    .await
            ),
            ErrorCode::TokensUnreachable
        );
        let signing = issuer_transport(&issuer, 3, {
            let key = IssuerKeyHandle(issuer.key.to_pem().unwrap());
            move |body| {
                json_response(
                    200,
                    json!({ "blindSignatures": key.sign(&blinded_of(body), 3) }),
                )
            }
        });
        issue(&store, &signing).await.unwrap();
        assert!(!store.status(NOW).device_refused);
    }

    #[tokio::test]
    async fn a_session_dies_after_five_minutes_and_on_clear_sessions() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        asked(&store);
        let signing = issuer_transport(&issuer, 3, |_| {
            json_response(200, json!({ "blindSignatures": [] }))
        });
        let issuance = store.begin(&signing, NOW).await.unwrap().unwrap();
        let late = NOW + SESSION_TTL_SECONDS;
        assert_eq!(
            store_code(
                store
                    .finish(&signing, issuance.session_id, vec![], "s".into(), late)
                    .await
            ),
            ErrorCode::TokensUnreachable
        );
        let issuance = store.begin(&signing, NOW).await.unwrap().unwrap();
        clear_sessions();
        assert_eq!(
            store_code(
                store
                    .finish(&signing, issuance.session_id, vec![], "s".into(), NOW)
                    .await
            ),
            ErrorCode::TokensUnreachable
        );
        assert_eq!(
            signing
                .sent
                .borrow()
                .iter()
                .filter(|r| r.url.ends_with("/v1/tokens"))
                .count(),
            0,
            "nothing was posted"
        );
    }

    fn held_for(store: &TokenStore, issuer: &FakeIssuer, day: u64, count: usize) {
        let challenge = issuer.challenge(day);
        store
            .update(|state| {
                for _ in 0..count {
                    let (pending, blinded) =
                        Pending::new(issuer.key.token_key(), &challenge).unwrap();
                    let token = pending
                        .finalize(issuer.key.token_key(), &issuer.key.sign(&blinded).unwrap())
                        .unwrap();
                    state.held.push(HeldToken {
                        challenge: encode_challenge(&challenge),
                        token_key: issuer.key.token_key().to_base64(),
                        token: Redacted(URL_SAFE_NO_PAD.encode(token.encode())),
                    });
                }
            })
            .unwrap();
    }

    #[tokio::test]
    async fn pay_spends_a_held_token_and_keeps_the_request_for_it_back_first() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        let asked = issuer.www_authenticate(TODAY);
        // Nothing held: the challenge is kept for the issuance.
        assert_eq!(
            store_code(store.pay(&asked, swap(1), Direction::Forward, NOW)),
            ErrorCode::TokensNeeded
        );
        assert!(store.maker_asks());
        assert_eq!(store.prefetch_challenge(NOW), Some(issuer.challenge(TODAY)));

        held_for(&store, &issuer, TODAY, 2);
        let payment = store.pay(&asked, swap(1), Direction::Forward, NOW).unwrap();
        assert!(issuer.accepts(&payment.authorization.0, TODAY));
        assert_eq!(store.status(NOW).held, 1, "the token left as it was paid");
        assert!(
            store.awaits_return(&swap(1), NOW),
            "kept before the token leaves"
        );
        assert_eq!(
            store.pending_returns(NOW),
            vec![(swap(1), Direction::Forward)]
        );
        assert_eq!(format!("{payment:?}").matches("<redacted>").count(), 4);

        // The maker took it: the token is gone, the request stays.
        store.settle(payment, Some(200)).unwrap();
        assert_eq!(store.status(NOW).held, 1);
        assert!(store.awaits_return(&swap(1), NOW));

        // Refused: the token is gone, and so is the request.
        let payment = store.pay(&asked, swap(2), Direction::Reverse, NOW).unwrap();
        store.settle(payment, Some(401)).unwrap();
        assert_eq!(store.status(NOW).held, 0);
        assert!(!store.awaits_return(&swap(2), NOW));

        // Any other answer, or none, leaves the token first in line.
        held_for(&store, &issuer, TODAY, 1);
        for status in [Some(400), Some(404), Some(503), None] {
            let payment = store.pay(&asked, swap(3), Direction::Forward, NOW).unwrap();
            let spent = payment.authorization.0.clone();
            store.settle(payment, status).unwrap();
            assert_eq!(store.status(NOW).held, 1, "{status:?}");
            let again = store.pay(&asked, swap(3), Direction::Forward, NOW).unwrap();
            assert_eq!(again.authorization.0, spent, "the same token, first");
            store.settle(again, None).unwrap();
        }
    }

    #[tokio::test]
    async fn pay_refuses_another_issuer_key_or_day() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        held_for(&store, &issuer, TODAY, 1);
        let other = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let renamed = FakeIssuer::new(ISSUER_URL, "another-issuer");
        for asked in [
            other.www_authenticate(TODAY),
            renamed.www_authenticate(TODAY),
            issuer.www_authenticate(TODAY - 1),
            issuer.www_authenticate(TODAY + 1),
            "Basic abc".into(),
        ] {
            assert_eq!(
                store_code(store.pay(&asked, swap(1), Direction::Forward, NOW)),
                ErrorCode::TokensRefused,
                "{asked}"
            );
        }
        assert_eq!(store.status(NOW).held, 1, "nothing left");
        assert!(!store.maker_asks());
        // Ten minutes either side of midnight the maker may be on the other
        // day: the challenge is taken (and tomorrow's finds nothing held).
        let midnight = (TODAY + 1) * 86_400;
        assert_eq!(
            store_code(store.pay(
                &issuer.www_authenticate(TODAY + 1),
                swap(1),
                Direction::Forward,
                midnight - 300
            )),
            ErrorCode::TokensNeeded
        );
        held_for(&store, &issuer, TODAY, 1);
        assert!(store
            .pay(
                &issuer.www_authenticate(TODAY),
                swap(2),
                Direction::Forward,
                midnight + 300
            )
            .is_ok());
    }

    #[tokio::test]
    async fn returned_tokens_go_only_once_the_issuer_has_none_left_today() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        let asked = issuer.www_authenticate(TODAY);
        held_for(&store, &issuer, TODAY, 1);
        let payment = store.pay(&asked, swap(1), Direction::Forward, NOW).unwrap();
        store.settle(payment.clone(), Some(200)).unwrap();
        // The swap hands the token back under the return key.
        assert!(store
            .collect(
                &swap(1),
                &issuer.token_return(&payment.token_request.0),
                NOW
            )
            .unwrap());
        assert!(!store.awaits_return(&swap(1), NOW));
        assert_eq!(store.status(NOW).held, 1);

        // Not spent while the issuer may still have some.
        assert_eq!(
            store_code(store.pay(&asked, swap(2), Direction::Forward, NOW)),
            ErrorCode::TokensNeeded
        );
        store
            .update(|state| state.exhausted_day = Some(TODAY))
            .unwrap();
        let returned = store.pay(&asked, swap(2), Direction::Forward, NOW).unwrap();
        assert!(issuer.accepts(&returned.authorization.0, TODAY));
        store.settle(returned, Some(200)).unwrap();
        assert_eq!(
            store_code(store.pay(&asked, swap(3), Direction::Forward, NOW)),
            ErrorCode::NoTokensToday
        );
    }

    #[tokio::test]
    async fn a_return_finalizing_none_of_the_swaps_requests_or_of_an_earlier_day_drops_them() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        held_for(&store, &issuer, TODAY, 2);
        let asked = issuer.www_authenticate(TODAY);
        let first = store.pay(&asked, swap(1), Direction::Forward, NOW).unwrap();
        store.settle(first, None).unwrap();
        let second = store.pay(&asked, swap(1), Direction::Forward, NOW).unwrap();
        store.settle(second.clone(), Some(200)).unwrap();
        assert_eq!(
            store.pending_returns(NOW).len(),
            1,
            "one swap, two requests"
        );
        // The maker signed the second request: the first finalizes nothing,
        // the second does, and both are dropped.
        assert!(store
            .collect(&swap(1), &issuer.token_return(&second.token_request.0), NOW)
            .unwrap());
        assert!(store.pending_returns(NOW).is_empty());

        held_for(&store, &issuer, TODAY, 1);
        let third = store.pay(&asked, swap(2), Direction::Reverse, NOW).unwrap();
        store.settle(third, Some(200)).unwrap();
        assert!(!store.collect(&swap(2), "AAAA", NOW).unwrap());
        assert!(store.pending_returns(NOW).is_empty());

        // A return for an earlier day is dropped unread: tomorrow, the
        // request is gone with it.
        held_for(&store, &issuer, TODAY, 1);
        let fourth = store.pay(&asked, swap(3), Direction::Forward, NOW).unwrap();
        store.settle(fourth.clone(), Some(200)).unwrap();
        let tomorrow = NOW + 86_400;
        assert!(!store.awaits_return(&swap(3), tomorrow));
        assert!(!store
            .collect(
                &swap(3),
                &issuer.token_return(&fourth.token_request.0),
                tomorrow
            )
            .unwrap());
        assert_eq!(store.status(tomorrow).held, 0);
    }

    #[tokio::test]
    async fn the_day_rolling_over_drops_yesterdays_tokens_and_the_file_survives_a_restart() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("private_usd_tokens_testnet.json");
        let store = TokenStore::open(&path, issuer.pins());
        held_for(&store, &issuer, TODAY, 2);
        let asked = issuer.www_authenticate(TODAY);
        let payment = store.pay(&asked, swap(1), Direction::Forward, NOW).unwrap();
        store.settle(payment, Some(200)).unwrap();
        drop(store);

        let reopened = TokenStore::open(&path, issuer.pins());
        assert_eq!(reopened.status(NOW).held, 1);
        assert!(reopened.awaits_return(&swap(1), NOW));
        assert_eq!(
            reopened.prefetch_challenge(NOW),
            Some(issuer.challenge(TODAY))
        );

        // Tomorrow the maker asks for tomorrow's: yesterday's token and
        // request go.
        let tomorrow = NOW + 86_400;
        assert_eq!(
            store_code(reopened.pay(
                &issuer.www_authenticate(TODAY + 1),
                swap(2),
                Direction::Forward,
                tomorrow
            )),
            ErrorCode::TokensNeeded
        );
        assert_eq!(reopened.status(tomorrow).held, 0);
        assert!(!reopened.awaits_return(&swap(1), tomorrow));
        assert_eq!(
            reopened.prefetch_challenge(tomorrow),
            Some(issuer.challenge(TODAY + 1)),
            "the last challenge, moved to today"
        );

        // An unreadable file starts empty.
        fs::write(&path, b"{not json").unwrap();
        let empty = TokenStore::open(&path, issuer.pins());
        assert_eq!(empty.status(NOW), TokenStatus::default());
        assert!(!path.with_extension("json.tmp").exists());
    }

    #[tokio::test]
    async fn a_maker_asking_for_another_challenge_than_the_one_fetched_ahead_is_paid_for_it() {
        let issuer = FakeIssuer::new(ISSUER_URL, "zecswap-testnet-issuer");
        let (_dir, store) = store(&issuer);
        held_for(&store, &issuer, TODAY, 3);
        // The maker names another origin: the batch answers nothing it asks.
        let other = Challenge::new(&issuer.name, "maker-2", TODAY).unwrap();
        let asked = zecswap_tokens::www_authenticate(&other, issuer.key.token_key());
        assert_eq!(
            store_code(store.pay(&asked, swap(1), Direction::Forward, NOW)),
            ErrorCode::TokensNeeded
        );
        assert_eq!(
            store.status(NOW).held,
            0,
            "the batch fetched ahead is dropped"
        );
        assert_eq!(
            store.prefetch_challenge(NOW),
            Some(other),
            "the next fetch is for the asked one"
        );
    }

    /// The issuer's key by its PEM, for a closure that outlives the fake.
    struct IssuerKeyHandle(String);

    impl IssuerKeyHandle {
        fn sign(&self, blinded: &[String], count: usize) -> Vec<String> {
            let key = zecswap_tokens::IssuerKey::from_pem(&self.0).unwrap();
            blinded
                .iter()
                .take(count)
                .map(|request| {
                    let request = URL_SAFE_NO_PAD.decode(request).unwrap();
                    URL_SAFE_NO_PAD.encode(key.sign(&request).unwrap())
                })
                .collect()
        }
    }
}
