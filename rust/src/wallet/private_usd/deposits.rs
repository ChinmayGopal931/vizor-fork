//! Deposits: public USDC into the account's private balance.
//!
//! Each account has Ethereum deposit addresses of its own, derived from its
//! seed (`SwapKeyContext::deposit_keys`). Once one holds at least the
//! relayer's minimum, the wallet signs one EIP-3009 `receiveWithAuthorization`
//! of its whole balance to the pinned Deposits contract. The authorization's
//! nonce commits to the note (built here, for the account's own Railgun
//! wallet), the fee and the relayer's deposits account, so the relayer, which
//! sends it and keeps the fee, can delay a deposit but never redirect it. The
//! wallet never holds ETH.
//!
//! [`Deposits::pass`] advances a persisted state machine, as `sends` does: it
//! scans the addresses, posts again what was kept, follows what the relayer
//! named, and signs what is due, keeping every request in `swaps.db` before it
//! is posted and posting only what was kept. A pass killed at any point leaves
//! the store consistent: the next one posts the kept bytes again. Only the
//! chain settles a deposit: a mined receipt in which the pinned contract's
//! `DepositShielded` names the address and one of this wallet's notes. The
//! relayer's word alone is believed for nothing.
//!
//! Never log a request, a record, an address or a note: they carry
//! signatures and link the account. Logs carry codes and indices.

use std::collections::{HashMap, HashSet};
use std::fmt;
use std::path::Path;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use zecswap_core::{DepositsDomain, ReceiveAuthorization, RescueAuthorization, TokenDomain};
use zecswap_railgun::{ShieldCiphertext, ShieldNote};

use super::abi::{self, address_word, keccak, u128_word, WORD};
use super::deployment::{
    self, after_railgun_fee, require_within_fee_cap, Deployment, DepositsPin, BPS_MAX,
    MAX_RELAYER_FEE,
};
use super::engine::{self, AccountGuard, AccountLocks, Clock, OpHandle, SystemClock};
use super::evm_rpc::{DepositChain, EvmRpc, ReceiptLog, TransactionStatus};
use super::keys::SwapKeyContext;
use super::models::{
    decode_strict, is_false, is_zero, Address, Amount, Hex, RelayerTerms, Signature, SwapNote, Word,
};
use super::relayer_client::{retry_after, RelayerClient};
use super::store::{DepositRow, SwapStore};
use super::swap;
use super::transport::{HttpTransport, SwapHttpError};
use super::{fail, lock, with_operations, ErrorCode, PrivateUsdError, Result};
use crate::wallet::routed_http::RoutedHttp;

/// Addresses read per Multicall3 call; a scan stops after a window of this
/// many with none used.
pub(crate) const GAP: u32 = 20;
/// The most windows one scan reads: a node claiming every address is used
/// never keeps a pass going.
const MAX_WINDOWS: u32 = 50;
/// How long an authorization is valid once signed, where the relayer takes
/// that long.
const VALIDITY_SECONDS: u64 = 60 * 60;
/// How far this clock and the relayer's may differ.
const CLOCK_SLACK_SECONDS: u64 = 60;
/// A request still waiting to be posted is signed again once its
/// `validBefore` is less than this away: the relayer takes none with under
/// 15 minutes left to land.
const RESIGN_BEFORE_SECONDS: u64 = 16 * 60;
/// A `503` asking to wait this long or less is waited out in the pass and
/// the same bytes posted again...
const BUSY_WAIT_SECONDS: u64 = 30;
/// ...for at most this long in all.
const BUSY_PATIENCE_SECONDS: u64 = 90;
/// The first wait between posts nothing answered, doubling to
/// [`LONGEST_WAIT_SECONDS`].
const BACKOFF_SECONDS: u64 = 15;
const LONGEST_WAIT_SECONDS: u64 = 5 * 60;
/// An address refused twice is not signed for again before this, unless its
/// balance or the terms change: automatic shielding would otherwise post
/// into the same refusal every pass.
const REFUSED_PAUSE_SECONDS: u64 = 60 * 60;
/// The relayer holds an address back this long after a deposit of it
/// reverted.
const REVERTED_PAUSE_SECONDS: u64 = 60 * 60;
/// A transaction the relayer named that has not mined within this is posted
/// again, the same bytes: the relayer names it again while it can still land,
/// and sends the deposit anew once it cannot. Mainnet's relayer sends through
/// Flashbots Protect, which the node never sees before a transaction mines,
/// and which drops one it could not land in 10 blocks.
const REPOST_SECONDS: u64 = 60;
/// The most a deposit request may be (the relayer's limit).
const MAX_REQUEST_BODY: usize = 16 * 1024;
/// The deposit fee cap's percentage part: a deposit pays the relayer at most
/// [`MAX_RELAYER_FEE`] and this part of its value.
pub(crate) const CAP_FEE_BPS: u32 = 50;
/// How soon a pass asks to run again while a deposit is posted and not
/// mined.
const FOLLOW_EVERY: Duration = Duration::from_secs(10);
/// How soon a pass asks to run again while an address holds enough but
/// could not be signed for (the terms did not read, say).
const SIGN_RETRY: Duration = Duration::from_secs(60);

const DEPOSIT_SHIELDED_EVENT: &str = "DepositShielded(address,uint256,uint256,address,bytes32)";
const RESCUED_EVENT: &str = "Rescued(address,uint256,uint256,address,bytes32)";

// ---- fees ----

/// What a deposit of `value` pays the relayer: `fee` and its `fee_bps` part
/// of `value`, rounded up.
pub(crate) fn deposit_fee(fee: u128, fee_bps: u32, value: u128) -> u128 {
    fee.saturating_add(value.saturating_mul(fee_bps.into()).div_ceil(BPS_MAX))
}

/// The most this wallet lets the relayer keep of a deposit of `value`: 2 USDC
/// and 0.5% of it, so the cap grows with the deposit as the relayer's fee
/// does.
pub(crate) fn fee_cap(value: u128) -> u128 {
    deposit_fee(MAX_RELAYER_FEE, CAP_FEE_BPS, value)
}

/// The fee a deposit of `value` pays under the relayer's `fee` and
/// `fee_bps`, once it is within the cap and under the value; `RelayerFee`
/// otherwise.
pub(crate) fn capped_fee(fee: u128, fee_bps: u32, value: u128) -> Result<u128> {
    let fee = deposit_fee(fee, fee_bps, value);
    if fee > fee_cap(value) {
        return fail(
            ErrorCode::RelayerFee,
            "the relayer's deposit fee is above the cap",
        );
    }
    if fee >= value {
        return fail(
            ErrorCode::RelayerFee,
            "the relayer's deposit fee leaves nothing to shield",
        );
    }
    Ok(fee)
}

/// What reaches the private balance from a deposit of `value` paying `fee`.
pub(crate) fn arrives(value: u128, fee: u128) -> u128 {
    after_railgun_fee(value.saturating_sub(fee))
}

// ---- terms ----

/// The relayer's deposit terms, held to the pin.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DepositTerms {
    /// The relayer's deposits account (the pinned one).
    pub relayer: [u8; 20],
    /// Token base units of the fee before its percentage; a rescue pays it
    /// alone.
    pub fee: u128,
    pub fee_bps: u32,
    /// Until when an authorization signed with `fee` is taken, where gas
    /// prices the fee.
    pub fee_expires_at: Option<u64>,
    pub min_value: u128,
    /// The latest an authorization's `validBefore` may be, from now.
    pub max_validity: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireDepositTerms {
    contract: Address,
    relayer: Address,
    token: Address,
    fee: Amount,
    fee_bps: u32,
    fee_expires_at: Option<u64>,
    min_value: Amount,
    max_validity: u64,
}

/// `terms`' `deposits`, once they are the pin's: the pinned chain, Deposits
/// contract, deposits account and token (the nonce commits to the account,
/// so a tampered answer cannot take even the fee). Never followed otherwise:
/// `Unavailable` where nothing is pinned or the relayer takes no deposits (or
/// none this build can use), `WrongDeployment` for another deployment's.
pub(crate) fn pinned_terms(terms: &RelayerTerms, pins: &Deployment) -> Result<DepositTerms> {
    let Some(pin) = pins.deposits else {
        return fail(
            ErrorCode::Unavailable,
            "no Deposits contract is pinned here",
        );
    };
    if terms.chain_id != pins.chain_id {
        return fail(
            ErrorCode::WrongDeployment,
            "the relayer serves another chain",
        );
    }
    let Some(deposits) = terms.deposits.as_ref().filter(|value| !value.is_null()) else {
        return fail(ErrorCode::Unavailable, "the relayer takes no deposits");
    };
    let wire: WireDepositTerms = serde_json::from_value(deposits.clone())
        .map_err(|_| PrivateUsdError::new(ErrorCode::Unavailable, "unreadable deposit terms"))?;
    if wire.contract.0 != pin.contract || wire.relayer.0 != pin.relayer || wire.token.0 != pin.token
    {
        return fail(
            ErrorCode::WrongDeployment,
            "the relayer takes deposits for another deployment",
        );
    }
    let usable = wire.fee.is_swap_amount(false)
        && wire.min_value.is_swap_amount(true)
        && u128::from(wire.fee_bps) <= BPS_MAX
        // An authorization signed under these must outlive its re-signing.
        && wire.max_validity > RESIGN_BEFORE_SECONDS + CLOCK_SLACK_SECONDS;
    if !usable {
        return fail(
            ErrorCode::Unavailable,
            "the relayer's deposit terms are unusable",
        );
    }
    Ok(DepositTerms {
        relayer: wire.relayer.0,
        fee: wire.fee.0,
        fee_bps: wire.fee_bps,
        fee_expires_at: wire.fee_expires_at,
        min_value: wire.min_value.0,
        max_validity: wire.max_validity,
    })
}

/// How long to sign for: an hour, or what the relayer takes less a minute
/// if that is less.
fn validity(terms: &DepositTerms) -> u64 {
    VALIDITY_SECONDS.min(terms.max_validity.saturating_sub(CLOCK_SLACK_SECONDS))
}

// ---- notes and addresses ----

fn shield_note(note: &SwapNote) -> ShieldNote {
    ShieldNote {
        npk: note.npk.0,
        ciphertext: ShieldCiphertext {
            encrypted_bundle: note.encrypted_bundle.map(|word| word.0),
            shield_key: note.shield_key.0,
        },
    }
}

/// `address` as EIP-55 writes it: lowercase hex, each letter capitalized
/// where the keccak of that hex has a high nibble. Exchanges' withdrawal
/// forms check it.
pub(crate) fn eip55(address: &[u8; 20]) -> String {
    let lower = hex::encode(address);
    let hash = keccak(&[lower.as_bytes()]);
    let mut out = String::with_capacity(42);
    out.push_str("0x");
    for (i, c) in lower.chars().enumerate() {
        let nibble = if i % 2 == 0 {
            hash[i / 2] >> 4
        } else {
            hash[i / 2] & 0x0f
        };
        out.push(if nibble >= 8 {
            c.to_ascii_uppercase()
        } else {
            c
        });
    }
    out
}

// ---- records ----

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum DepositKind {
    /// An address's balance shielded on its EIP-3009 authorization.
    Shield,
    /// What Railgun sent back to an address's vault, shielded again.
    Rescue,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum DepositState {
    /// Kept, with no transaction named for it: posted (again) as the same
    /// bytes.
    Signed,
    /// The relayer named transactions for it, or for another deposit of the
    /// address: following the last.
    Sent,
    /// Mined, and believed: the pinned contract's event names the address
    /// and one of this wallet's notes.
    Landed,
    /// Refused (a shield twice, a rescue once): nothing was sent.
    Refused,
    /// Its transaction reverted: nothing moved. The relayer holds the
    /// address back for an hour.
    Reverted,
    /// Signed again in its place, or another deposit of the address took its
    /// funds: it can no longer land.
    Replaced,
    /// Its validity ran out before anything landed it.
    Expired,
}

impl DepositState {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Signed => "signed",
            Self::Sent => "sent",
            Self::Landed => "landed",
            Self::Refused => "refused",
            Self::Reverted => "reverted",
            Self::Replaced => "replaced",
            Self::Expired => "expired",
        }
    }

    pub(crate) fn finished(self) -> bool {
        !matches!(self, Self::Signed | Self::Sent)
    }
}

/// `POST /v1/deposits/shield`'s body: exactly these fields (the relayer
/// answers any other with `422`), `value` and `fee` as decimal strings.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ShieldRequest {
    pub chain_id: u64,
    pub contract: Address,
    pub from: Address,
    pub value: Amount,
    pub valid_after: u64,
    pub valid_before: u64,
    pub note: SwapNote,
    pub fee: Amount,
    pub signature: Signature,
}

/// `POST /v1/deposits/rescue`'s body, exactly.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RescueRequest {
    pub chain_id: u64,
    pub contract: Address,
    pub from: Address,
    pub note: SwapNote,
    pub fee: Amount,
    pub nonce: u64,
    pub deadline: u64,
    pub signature: Signature,
}

/// The terms a request was signed under: a refusal's pause holds only while
/// they stand, and a fee's honour window ends at `fee_expires_at`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SignedTerms {
    pub fee: Amount,
    pub fee_bps: u32,
    pub min_value: Amount,
    pub max_validity: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fee_expires_at: Option<u64>,
}

impl SignedTerms {
    fn of(terms: &DepositTerms) -> Self {
        Self {
            fee: Amount(terms.fee),
            fee_bps: terms.fee_bps,
            min_value: Amount(terms.min_value),
            max_validity: terms.max_validity,
            fee_expires_at: terms.fee_expires_at,
        }
    }

    /// The same terms, the fee's expiry aside.
    fn same(&self, terms: &DepositTerms) -> bool {
        self.fee.0 == terms.fee
            && self.fee_bps == terms.fee_bps
            && self.min_value.0 == terms.min_value
            && self.max_validity == terms.max_validity
    }
}

/// What the pinned contract recorded of a deposit or rescue that landed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Landing {
    /// None when only its used nonce proves it: the relayer named no
    /// transaction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tx: Option<Word>,
    /// What the contract shielded, before Railgun's fee (the event's
    /// `value`).
    pub shielded: Amount,
    pub fee: Amount,
    /// Unix seconds on this device's clock when it was seen landed.
    pub at: u64,
}

/// One signed deposit or rescue and where it stands. Kept before it is
/// posted; one per signing, so a replaced request stays and its note is
/// still recognized if it lands after all.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DepositRecord {
    /// `shield-<index>-<validBefore>` or `rescue-<index>-<nonce>-<deadline>`.
    pub id: String,
    pub kind: DepositKind,
    /// The deposit address's index.
    pub index: u32,
    pub state: DepositState,
    /// Unix seconds when it was signed and kept.
    pub created_at: u64,
    /// What it moves: a shield's authorized value, a rescue's vault balance
    /// when signed.
    pub value: Amount,
    pub terms: SignedTerms,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shield: Option<ShieldRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rescue: Option<RescueRequest>,
    /// A shield's EIP-3009 nonce: used on the token once it landed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nonce: Option<Word>,
    /// Signed again after a refusal: refused again, it is dropped.
    #[serde(default, skip_serializing_if = "is_false")]
    pub after_refusal: bool,
    /// Unix seconds of the last post.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub posted_at: Option<u64>,
    /// Unix seconds before which it is not posted again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<u64>,
    /// The wait before the next post nothing answers, in seconds.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub backoff: u64,
    /// The relayer asked to wait over 30 s, or could not be reached: the
    /// money waits safely at the deposit address.
    #[serde(default, skip_serializing_if = "is_false")]
    pub waiting: bool,
    /// The transactions the relayer named, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub transactions: Vec<Word>,
    /// They came with a `409`: another deposit of the address, believed only
    /// for one of this wallet's notes.
    #[serde(default, skip_serializing_if = "is_false")]
    pub conflict: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub landing: Option<Landing>,
    /// Unix seconds when it ended.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<u64>,
}

/// Redacted: a record holds a signature and the note.
impl fmt::Debug for DepositRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DepositRecord")
            .field("kind", &self.kind)
            .field("index", &self.index)
            .field("state", &self.state)
            .finish_non_exhaustive()
    }
}

impl DepositRecord {
    pub(crate) fn from(&self) -> [u8; 20] {
        match (&self.shield, &self.rescue) {
            (Some(shield), _) => shield.from.0,
            (_, Some(rescue)) => rescue.from.0,
            (None, None) => [0; 20],
        }
    }

    pub(crate) fn fee(&self) -> u128 {
        match (&self.shield, &self.rescue) {
            (Some(shield), _) => shield.fee.0,
            (_, Some(rescue)) => rescue.fee.0,
            (None, None) => 0,
        }
    }

    fn note(&self) -> Option<&SwapNote> {
        match (&self.shield, &self.rescue) {
            (Some(shield), _) => Some(&shield.note),
            (_, Some(rescue)) => Some(&rescue.note),
            (None, None) => None,
        }
    }

    /// The note's commitment, as the contract's events name it.
    pub(crate) fn commitment(&self) -> Option<[u8; 32]> {
        self.note().map(|note| shield_note(note).commitment())
    }

    /// The first second it can no longer land.
    pub(crate) fn expires_at(&self) -> u64 {
        match (&self.shield, &self.rescue) {
            (Some(shield), _) => shield.valid_before,
            (_, Some(rescue)) => rescue.deadline.saturating_add(1),
            (None, None) => 0,
        }
    }

    /// What reaches the private balance: the event's once it landed, else
    /// what the request should bring.
    pub(crate) fn arrives(&self) -> u128 {
        match &self.landing {
            Some(landing) => after_railgun_fee(landing.shielded.0),
            None => arrives(self.value.0, self.fee()),
        }
    }

    fn ended(mut self, state: DepositState, now: u64) -> Self {
        self.state = state;
        self.ended_at = Some(now);
        self.retry_at = None;
        self.waiting = false;
        self
    }

    /// The relayer named `transactions` (`conflict`: with a `409`).
    fn named(mut self, transactions: Vec<[u8; 32]>, conflict: bool, now: u64) -> Self {
        self.state = DepositState::Sent;
        self.transactions = transactions.into_iter().map(Hex).collect();
        self.conflict = conflict;
        self.posted_at = Some(now);
        self.retry_at = None;
        self.backoff = 0;
        self.waiting = false;
        self
    }

    /// Posted with no answer that names anything: the same bytes go again,
    /// with backoff, never sooner than the relayer asked.
    fn unanswered(mut self, after: Option<u64>, waiting: bool, now: u64) -> Self {
        self.state = DepositState::Signed;
        self.backoff = if self.backoff == 0 {
            BACKOFF_SECONDS
        } else {
            (self.backoff * 2).min(LONGEST_WAIT_SECONDS)
        };
        let wait = self.backoff.max(after.unwrap_or(0));
        self.posted_at = Some(now);
        self.retry_at = Some(now.saturating_add(wait));
        self.waiting = waiting;
        self
    }

    /// A named request posted again (its transaction not mined in a minute):
    /// still named, whatever the relayer answered, so it is never signed
    /// again while that transaction may land.
    fn asked_again(mut self, now: u64) -> Self {
        self.posted_at = Some(now);
        self
    }

    fn landed(mut self, landing: Landing, now: u64) -> Self {
        self.landing = Some(landing);
        self.ended(DepositState::Landed, now)
    }
}

/// An address's last scan, as `swaps.db` keeps it per account: the address
/// shown, and each used address.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DepositScan {
    pub showing: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub used: Vec<ScannedAddress>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ScannedAddress {
    pub index: u32,
    pub balance: Amount,
    #[serde(default, skip_serializing_if = "is_false")]
    pub deposited: bool,
}

impl DepositScan {
    fn balance(&self, index: u32) -> Option<u128> {
        self.used
            .iter()
            .find(|address| address.index == index)
            .map(|address| address.balance.0)
    }
}

/// The lowest index never shielded from: the one whose `deposited` is false.
/// One holding under the minimum stays the one shown.
fn showing(used: &[ScannedAddress]) -> u32 {
    let shielded: HashSet<u32> = used
        .iter()
        .filter(|address| address.deposited)
        .map(|address| address.index)
        .collect();
    (0..=u32::MAX)
        .find(|index| !shielded.contains(index))
        .unwrap_or(u32::MAX)
}

// ---- the store ----

/// The account's deposits, newest first. One that does not read makes them
/// all unreadable (`StoreUnreadable`), never a reset.
pub(crate) fn records(store: &SwapStore, account: &str) -> Result<Vec<DepositRecord>> {
    store.deposits(account)?.iter().map(decode_row).collect()
}

/// The account's last scan, if one was kept.
pub(crate) fn last_scan(store: &SwapStore, account: &str) -> Result<Option<(u64, DepositScan)>> {
    let Some((at, json)) = store.deposit_scan(account)? else {
        return Ok(None);
    };
    let scan = decode_strict(&json)
        .map_err(|message| PrivateUsdError::new(ErrorCode::StoreUnreadable, message))?;
    Ok(Some((at, scan)))
}

fn decode_row(row: &DepositRow) -> Result<DepositRecord> {
    let record: DepositRecord = decode_strict(&row.record_json)
        .map_err(|message| PrivateUsdError::new(ErrorCode::StoreUnreadable, message))?;
    let shape_reads = match record.kind {
        DepositKind::Shield => record.shield.is_some() && record.rescue.is_none(),
        DepositKind::Rescue => record.rescue.is_some() && record.shield.is_none(),
    };
    if record.id != row.deposit_id
        || record.index != row.address_index
        || record.state.name() != row.state
        || record.state.finished() != row.finished
        || !shape_reads
    {
        return fail(
            ErrorCode::StoreUnreadable,
            "a deposit is filed under another id, address or state",
        );
    }
    Ok(record)
}

/// Keeps `records` in one transaction: a request and the one it replaces
/// change together.
fn keep(store: &mut SwapStore, account: &str, records: &[&DepositRecord]) -> Result<()> {
    let rows = records
        .iter()
        .map(|record| {
            let record_json = serde_json::to_string(record).map_err(|_| {
                PrivateUsdError::new(ErrorCode::StoreUnreadable, "a deposit does not encode")
            })?;
            Ok(DepositRow {
                deposit_id: record.id.clone(),
                address_index: record.index,
                state: record.state.name().to_owned(),
                finished: record.state.finished(),
                created_at: record.created_at,
                record_json,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    with_operations(|| store.put_deposits(account, &rows))
}

fn keep_scan(store: &mut SwapStore, account: &str, at: u64, scan: &DepositScan) -> Result<()> {
    let json = serde_json::to_string(scan)
        .map_err(|_| PrivateUsdError::new(ErrorCode::StoreUnreadable, "a scan does not encode"))?;
    with_operations(|| store.put_deposit_scan(account, at, &json))
}

// ---- per-account passes ----

/// An account's deposit passes and rescues: two never run at once for one
/// account, and an account deletion waits for neither.
static DEPOSIT_LOCKS: AccountLocks = AccountLocks::new();

/// Takes `account`'s deposit lock, or `Busy` while a pass or rescue holds it.
pub(crate) fn lock_account(account: &str) -> Result<AccountGuard> {
    DEPOSIT_LOCKS.try_lock(account, "a deposit pass of this account is running")
}

/// Token domains read and checked this process, by chain and token: a
/// token's `name()` and `version()` never change.
static TOKEN_DOMAINS: LazyLock<Mutex<HashMap<(u64, [u8; 20]), (String, String)>>> =
    LazyLock::new(Default::default);

// ---- the pass ----

/// A used deposit address, as a pass shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AddressView {
    pub index: u32,
    pub address: [u8; 20],
    pub balance: u128,
    pub deposited: bool,
}

/// A vault holding more than a rescue's fee (`check_vaults`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Rescuable {
    pub index: u32,
    pub held: u128,
    pub fee: u128,
}

/// What a pass leaves: the address to show, the used ones, the account's
/// deposits, the terms as read, and when to run again.
#[derive(Debug)]
pub(crate) struct PassReport {
    pub showing: u32,
    pub showing_address: [u8; 20],
    pub used: Vec<AddressView>,
    pub records: Vec<DepositRecord>,
    /// The terms, or why they did not read: `Unavailable` and
    /// `WrongDeployment` hide deposits; anything else only the fees. `None`
    /// when the pass did not ask.
    pub terms: Option<std::result::Result<DepositTerms, ErrorCode>>,
    pub rescuable: Vec<Rescuable>,
    /// Whether this pass read the addresses from the chain (else they are
    /// the last scan's).
    pub scanned: bool,
    /// When the addresses were last read.
    pub scanned_at: Option<u64>,
    /// When to run again; none while nothing is posted or due.
    pub next_poll: Option<Duration>,
    /// The first step that failed, after the terms.
    pub problem: Option<ErrorCode>,
}

impl PassReport {
    /// The pass of an account that never scanned or kept a deposit, when
    /// nothing asked for one: address 0 to show, and nothing else.
    pub(crate) fn unused(showing_address: [u8; 20]) -> Self {
        Self {
            showing: 0,
            showing_address,
            used: Vec::new(),
            records: Vec::new(),
            terms: None,
            rescuable: Vec::new(),
            scanned: false,
            scanned_at: None,
            next_poll: None,
            problem: None,
        }
    }
}

/// What a pass knows while it advances one request.
struct PassContext<'c> {
    terms: Option<&'c DepositTerms>,
    /// The relayer's terms are the pin's (or could not be read): kept bytes
    /// may go to it. Never to a relayer that serves another deployment.
    may_post: bool,
    /// The addresses were read from the chain this pass.
    scan: Option<&'c DepositScan>,
}

impl PassContext<'_> {
    /// `index`'s balance as this pass read it, with the terms to sign under.
    fn signable(&self, index: u32) -> Option<(u128, &DepositTerms)> {
        let terms = self.terms?;
        let balance = self.scan?.balance(index)?;
        (balance >= terms.min_value).then_some((balance, terms))
    }
}

/// How the relayer answered a post.
enum Answer {
    /// `200`: these transactions send it.
    Sent(Vec<[u8; 32]>),
    /// `409`: the authorization is used, or another deposit of the address is
    /// on its way, in these of the relayer's (maybe none).
    Conflict(Vec<[u8; 32]>),
    /// `400`, `415` or `422`: nothing was sent, and nothing will be.
    Refused { status: u16 },
    /// Anything else: post the same bytes again later, no sooner than
    /// `after`. `waiting` when the relayer asked to wait long or did not
    /// answer.
    Retry { after: Option<u64>, waiting: bool },
}

/// One account's deposits, over the seams: the relayer, the chain, the clock.
pub(crate) struct Deposits<'a, T: HttpTransport, C: DepositChain, K: Clock> {
    pins: &'static Deployment,
    pin: DepositsPin,
    account: &'a str,
    keys: &'a SwapKeyContext,
    relayer: RelayerClient<'a, T>,
    chain: &'a C,
    clock: &'a K,
    op: Option<&'a OpHandle>,
}

impl<'a, T: HttpTransport, C: DepositChain, K: Clock> Deposits<'a, T, C, K> {
    /// `Unavailable` where no Deposits contract is pinned.
    pub(crate) fn new(
        pins: &'static Deployment,
        account: &'a str,
        keys: &'a SwapKeyContext,
        transport: &'a T,
        chain: &'a C,
        clock: &'a K,
        op: Option<&'a OpHandle>,
    ) -> Result<Self> {
        let Some(pin) = pins.deposits else {
            return fail(
                ErrorCode::Unavailable,
                "no Deposits contract is pinned here",
            );
        };
        Ok(Self {
            pins,
            pin,
            account,
            keys,
            relayer: RelayerClient::new(transport, pins.relayer_url),
            chain,
            clock,
            op,
        })
    }

    fn check_cancelled(&self) -> Result<()> {
        engine::check_cancelled(self.op)
    }

    /// The relayer's deposit terms, held to the pin.
    pub(crate) async fn terms(&self) -> Result<DepositTerms> {
        pinned_terms(&self.relayer.terms().await?, self.pins)
    }

    /// Deposit address `index`.
    pub(crate) fn address(&self, index: u32) -> Result<[u8; 20]> {
        Ok(self.keys.deposit_keys(index)?.key.address())
    }

    fn domain(&self) -> DepositsDomain {
        DepositsDomain {
            chain_id: self.pins.chain_id,
            contract: self.pin.contract,
        }
    }

    async fn require_chain(&self) -> Result<()> {
        if self.chain.node_chain_id().await? != self.pins.chain_id {
            return fail(ErrorCode::WrongDeployment, "the node serves another chain");
        }
        Ok(())
    }

    /// The token's EIP-712 domain, from its own `name()` and `version()`,
    /// once its `DOMAIN_SEPARATOR()` is theirs and the Deposits contract's
    /// `TOKEN()` is the pinned token. Never hardcoded: USDC's is
    /// `"USD Coin"`, `"2"`, tUSD's `"ZecSwap Test USD"`, `"2"`.
    async fn token_domain(&self) -> Result<TokenDomain> {
        let key = (self.pins.chain_id, self.pin.token);
        let cached = lock(&TOKEN_DOMAINS).get(&key).cloned();
        if let Some((name, version)) = cached {
            return Ok(TokenDomain {
                name,
                version,
                chain_id: self.pins.chain_id,
                token: self.pin.token,
            });
        }
        if self.chain.deposits_token(&self.pin).await? != self.pin.token {
            return fail(
                ErrorCode::WrongDeployment,
                "the Deposits contract takes another token",
            );
        }
        let (name, version, separator) = self.chain.token_domain(&self.pin.token).await?;
        let domain = TokenDomain {
            name,
            version,
            chain_id: self.pins.chain_id,
            token: self.pin.token,
        };
        if domain.separator() != separator {
            return fail(
                ErrorCode::WrongDeployment,
                "the token's domain separator is not its name and version's",
            );
        }
        lock(&TOKEN_DOMAINS).insert(key, (domain.name.clone(), domain.version.clone()));
        Ok(domain)
    }

    /// Every used address, scanned `GAP` at a time from index 0 until a
    /// window holds none used: an old address that gets USDC later is found
    /// and shielded to a note of its own.
    async fn scan(&self) -> Result<DepositScan> {
        let mut used = Vec::new();
        for window in 0..MAX_WINDOWS {
            self.check_cancelled()?;
            let first = window * GAP;
            let owners = (first..first + GAP)
                .map(|index| self.address(index))
                .collect::<Result<Vec<_>>>()?;
            let uses = self.chain.deposit_addresses(&self.pin, &owners).await?;
            if uses.len() != owners.len() {
                return fail(ErrorCode::ChainUnreadable, "a scan answered another count");
            }
            let before = used.len();
            for (index, address) in (first..).zip(&uses) {
                if address.used() {
                    used.push(ScannedAddress {
                        index,
                        balance: Amount(address.balance),
                        deposited: address.deposited,
                    });
                }
            }
            if used.len() == before {
                break;
            }
        }
        Ok(DepositScan {
            showing: showing(&used),
            used,
        })
    }

    /// One pass for the account (the caller holds its deposit lock): scan,
    /// then advance every request kept and not finished, then sign for each
    /// used address that holds at least the minimum and has none under way
    /// (`sign_new`; off while the kill switch hides the feature, which never
    /// stops a deposit already under way). With `check_vaults`, also reads
    /// which vaults can be rescued.
    pub(crate) async fn pass(
        &self,
        store: &mut SwapStore,
        sign_new: bool,
        check_vaults: bool,
    ) -> Result<PassReport> {
        let mut problem: Option<ErrorCode> = None;
        let mut note = |code: ErrorCode| {
            if problem.is_none() {
                problem = Some(code);
            }
        };

        let chain = self.require_chain().await;
        self.check_cancelled()?;
        let terms = self.terms().await;
        self.check_cancelled()?;
        let may_post = match &terms {
            Ok(_) => true,
            Err(error) => !matches!(
                error.code,
                ErrorCode::Unavailable | ErrorCode::WrongDeployment
            ),
        };

        let scan = match &chain {
            Ok(()) => match self.scan().await {
                Ok(scan) => {
                    keep_scan(store, self.account, self.clock.now(), &scan)?;
                    Some(scan)
                }
                Err(error) if error.code == ErrorCode::Cancelled => return Err(error),
                Err(error) => {
                    log::warn!("private usd: a deposit scan failed ({:?})", error.code);
                    note(error.code);
                    None
                }
            },
            Err(error) => {
                log::warn!(
                    "private usd: the deposit chain did not read ({:?})",
                    error.code
                );
                note(error.code);
                None
            }
        };
        let context = PassContext {
            terms: terms.as_ref().ok(),
            may_post,
            scan: scan.as_ref(),
        };

        // Kept requests first, oldest first. An address with one under way
        // now is not signed for again in this pass: its scanned balance may
        // be the one that request just moved.
        let mut kept = records(store, self.account)?;
        let under_way: HashSet<u32> = kept
            .iter()
            .filter(|record| !record.state.finished())
            .map(|record| record.index)
            .collect();
        kept.reverse();
        for record in kept.into_iter().filter(|record| !record.state.finished()) {
            self.check_cancelled()?;
            let index = record.index;
            let step = match record.state {
                DepositState::Sent if chain.is_ok() => self.follow(store, record, &context).await,
                DepositState::Signed => self.resend(store, record, &context).await,
                _ => Ok(()),
            };
            if let Err(error) = step {
                if error.code == ErrorCode::Cancelled {
                    return Err(error);
                }
                log::warn!(
                    "private usd: deposit of address {index} wasn't advanced ({:?})",
                    error.code
                );
                note(error.code);
            }
        }

        // Then what is due: an address holding enough, none under way.
        let mut unsigned = false;
        if let (true, Some(scan), Ok(terms)) = (sign_new, scan.as_ref(), terms.as_ref()) {
            let kept = records(store, self.account)?;
            let now = self.clock.now();
            for address in &scan.used {
                if under_way.contains(&address.index) || !due(&kept, address, terms, now) {
                    continue;
                }
                self.check_cancelled()?;
                if let Err(error) = self
                    .shield(store, address.index, address.balance.0, terms, &context)
                    .await
                {
                    if error.code == ErrorCode::Cancelled {
                        return Err(error);
                    }
                    log::warn!(
                        "private usd: address {} wasn't signed for ({:?})",
                        address.index,
                        error.code
                    );
                    unsigned = true;
                    note(error.code);
                }
            }
        }

        let rescuable = match (check_vaults, &chain, scan.as_ref(), terms.as_ref()) {
            (true, Ok(()), Some(scan), Ok(terms)) => match self.rescuable(scan, terms).await {
                Ok(rescuable) => rescuable,
                Err(error) if error.code == ErrorCode::Cancelled => return Err(error),
                Err(error) => {
                    note(error.code);
                    Vec::new()
                }
            },
            _ => Vec::new(),
        };

        // The addresses to show, from this scan or the last one kept.
        let (scanned, (scanned_at, view)) = match scan {
            Some(scan) => (true, (Some(self.clock.now()), scan)),
            None => (
                false,
                match last_scan(store, self.account)? {
                    Some((at, scan)) => (Some(at), scan),
                    None => (None, DepositScan::default()),
                },
            ),
        };
        let used = view
            .used
            .iter()
            .map(|address| {
                Ok(AddressView {
                    index: address.index,
                    address: self.address(address.index)?,
                    balance: address.balance.0,
                    deposited: address.deposited,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let records = records(store, self.account)?;
        let now = self.clock.now();
        let next_poll = next_poll(&records, now).or_else(|| {
            // An address that holds enough and could not be signed for is
            // tried again soon.
            let retry = match (&terms, unsigned) {
                (_, true) => true,
                (Ok(terms), false) => view
                    .used
                    .iter()
                    .any(|address| due(&records, address, terms, now)),
                // Terms that did not read for now (never ones that are
                // unavailable or not the pin's): tried again soon.
                (Err(_), false) => {
                    may_post && view.used.iter().any(|address| address.balance.0 > 0)
                }
            };
            (retry && sign_new).then_some(SIGN_RETRY)
        });
        Ok(PassReport {
            showing: view.showing,
            showing_address: self.address(view.showing)?,
            used,
            records,
            terms: Some(terms.map_err(|error| error.code)),
            rescuable,
            scanned,
            scanned_at,
            next_poll,
            problem,
        })
    }

    /// Signs a shield of address `index`'s whole `value` under `terms`, keeps
    /// it, and posts it.
    async fn shield(
        &self,
        store: &mut SwapStore,
        index: u32,
        value: u128,
        terms: &DepositTerms,
        context: &PassContext<'_>,
    ) -> Result<()> {
        let record = self.sign_shield(index, value, terms, false, 0).await?;
        keep(store, self.account, &[&record])?;
        if context.may_post {
            self.post_kept(store, record, context).await?;
        }
        Ok(())
    }

    /// A signed shield of `value`, as a record to keep: the fee within the
    /// cap, valid for an hour (or what the relayer takes less a minute, and
    /// after `after_valid_before`), to a note of the account's own Railgun
    /// wallet, under the token's own domain.
    async fn sign_shield(
        &self,
        index: u32,
        value: u128,
        terms: &DepositTerms,
        after_refusal: bool,
        after_valid_before: u64,
    ) -> Result<DepositRecord> {
        let fee = capped_fee(terms.fee, terms.fee_bps, value)?;
        let token = self.token_domain().await?;
        let keys = self.keys.deposit_keys(index)?;
        let from = keys.key.address();
        let now = self.clock.now();
        // Each signing has its own `validBefore`, so its own note and nonce.
        let valid_before = (now + validity(terms)).max(after_valid_before.saturating_add(1));
        let note = self
            .keys
            .railgun_keys()?
            .note(&keys.shield_entropy(valid_before))
            .map_err(|error| {
                PrivateUsdError::new(ErrorCode::Other, format!("deposit note: {error}"))
            })?;
        // The five words a deposit's nonce commits to; their keccak is the
        // note's commitment, which signing checks.
        let words = note.words();
        let parts: Vec<&[u8]> = words.iter().map(|word| &word[..]).collect();
        if keccak(&parts) != note.commitment() {
            return fail(ErrorCode::Other, "the note's words are not its commitment");
        }
        let nonce = self.domain().deposit_nonce(&words, fee, &terms.relayer);
        let digest = token.receive_with_authorization(&ReceiveAuthorization {
            from,
            to: self.pin.contract,
            value,
            valid_after: 0,
            valid_before,
            nonce,
        });
        let request = ShieldRequest {
            chain_id: self.pins.chain_id,
            contract: Hex(self.pin.contract),
            from: Hex(from),
            value: Amount(value),
            valid_after: 0,
            valid_before,
            note: SwapNote::from(&note),
            fee: Amount(fee),
            signature: Hex(keys.key.sign(&digest)),
        };
        check_body(&request)?;
        Ok(DepositRecord {
            id: format!("shield-{index}-{valid_before}"),
            kind: DepositKind::Shield,
            index,
            state: DepositState::Signed,
            created_at: now,
            value: Amount(value),
            terms: SignedTerms::of(terms),
            shield: Some(request),
            rescue: None,
            nonce: Some(Hex(nonce)),
            after_refusal,
            posted_at: None,
            retry_at: None,
            backoff: 0,
            waiting: false,
            transactions: Vec::new(),
            conflict: false,
            landing: None,
            ended_at: None,
        })
    }

    /// A kept request with no transaction named: posted again when due, or
    /// signed again first once its validity or fee went stale (a shield only;
    /// a rescue is the user's to sign again).
    async fn resend(
        &self,
        store: &mut SwapStore,
        record: DepositRecord,
        context: &PassContext<'_>,
    ) -> Result<()> {
        let now = self.clock.now();
        let expired = now > record.expires_at().saturating_add(CLOCK_SLACK_SECONDS);
        if record.kind == DepositKind::Shield {
            let stale = record.expires_at() < now.saturating_add(RESIGN_BEFORE_SECONDS)
                || record.terms.fee_expires_at.is_some_and(|at| now >= at);
            if stale {
                if let (true, Some((balance, terms))) =
                    (context.may_post, context.signable(record.index))
                {
                    let after = record
                        .shield
                        .as_ref()
                        .map_or(0, |shield| shield.valid_before);
                    let fresh = self
                        .sign_shield(record.index, balance, terms, record.after_refusal, after)
                        .await?;
                    let replaced = record.ended(DepositState::Replaced, now);
                    keep(store, self.account, &[&replaced, &fresh])?;
                    return self.post_kept(store, fresh, context).await;
                }
                if expired {
                    let ended = record.ended(DepositState::Expired, now);
                    return keep(store, self.account, &[&ended]);
                }
                return Ok(());
            }
        } else if expired {
            let ended = record.ended(DepositState::Expired, now);
            return keep(store, self.account, &[&ended]);
        }
        if !context.may_post || record.retry_at.is_some_and(|at| now < at) {
            return Ok(());
        }
        self.post_kept(store, record, context).await
    }

    /// Posts `record`'s kept bytes and notes the answer before acting on it.
    /// A refused shield is signed again once from fresh terms and a fresh
    /// balance; refused again, it is dropped.
    async fn post_kept(
        &self,
        store: &mut SwapStore,
        mut record: DepositRecord,
        context: &PassContext<'_>,
    ) -> Result<()> {
        loop {
            self.check_cancelled()?;
            let answer = self.post(&record).await;
            let now = self.clock.now();
            // A request the relayer already named a transaction for stays
            // named: it is never signed again while that one may land, and
            // only the chain (or its expiry) ends it.
            let named_before = record.state == DepositState::Sent;
            match answer {
                Answer::Sent(transactions) => {
                    let named = record.named(transactions, false, now);
                    return keep(store, self.account, &[&named]);
                }
                Answer::Conflict(transactions) if !transactions.is_empty() => {
                    let named = record.named(transactions, true, now);
                    return keep(store, self.account, &[&named]);
                }
                Answer::Conflict(_) => {
                    let posted = if named_before {
                        record.asked_again(now)
                    } else {
                        record.unanswered(None, false, now)
                    };
                    keep(store, self.account, &[&posted])?;
                    return self.unnamed_conflict(store, posted).await;
                }
                Answer::Retry { .. } | Answer::Refused { .. } if named_before => {
                    return keep(store, self.account, &[&record.asked_again(now)]);
                }
                Answer::Retry { after, waiting } => {
                    let posted = record.unanswered(after, waiting, now);
                    return keep(store, self.account, &[&posted]);
                }
                Answer::Refused { status } => {
                    log::warn!(
                        "private usd: the relayer refused the deposit of address {} (HTTP {status})",
                        record.index
                    );
                    if record.kind == DepositKind::Shield && !record.after_refusal {
                        // Signed again once, from fresh terms and balance.
                        // A signing that fails here drops the request: the
                        // address then waits out the refusal's pause.
                        match self.sign_after_refusal(&record, context).await {
                            Ok(Some(fresh)) => {
                                let replaced = record.ended(DepositState::Replaced, now);
                                keep(store, self.account, &[&replaced, &fresh])?;
                                record = fresh;
                                continue;
                            }
                            Ok(None) => {}
                            Err(error) if error.code == ErrorCode::Cancelled => return Err(error),
                            Err(error) => log::warn!(
                                "private usd: address {} wasn't signed for again ({:?})",
                                record.index,
                                error.code
                            ),
                        }
                    }
                    let refused = record.ended(DepositState::Refused, now);
                    return keep(store, self.account, &[&refused]);
                }
            }
        }
    }

    /// A refused shield, signed again once from the terms and the balance
    /// read now; none when the address no longer holds enough.
    async fn sign_after_refusal(
        &self,
        record: &DepositRecord,
        context: &PassContext<'_>,
    ) -> Result<Option<DepositRecord>> {
        if !context.may_post {
            return Ok(None);
        }
        let terms = self.terms().await?;
        let uses = self
            .chain
            .deposit_addresses(&self.pin, &[record.from()])
            .await?;
        let [address] = uses[..] else {
            return fail(
                ErrorCode::ChainUnreadable,
                "a balance read answered another count",
            );
        };
        if address.balance < terms.min_value {
            return Ok(None);
        }
        let after = record
            .shield
            .as_ref()
            .map_or(0, |shield| shield.valid_before);
        self.sign_shield(record.index, address.balance, &terms, true, after)
            .await
            .map(Some)
    }

    /// A `409` naming no transaction: the authorization is used, or another
    /// deposit of the address is on its way. The chain tells which: a used
    /// nonce is this request landed (only the Deposits contract can use it,
    /// for this note, fee and relayer); a balance under its value means its
    /// funds went in another deposit, so it can never land; else it waits.
    async fn unnamed_conflict(&self, store: &mut SwapStore, record: DepositRecord) -> Result<()> {
        let now = self.clock.now();
        let from = record.from();
        let landed = match (record.kind, record.nonce) {
            (DepositKind::Shield, Some(nonce)) => {
                self.chain
                    .authorization_used(&self.pin.token, &from, &nonce.0)
                    .await?
            }
            (DepositKind::Rescue, _) => {
                let nonce = record
                    .rescue
                    .as_ref()
                    .map_or(u64::MAX, |rescue| rescue.nonce);
                self.chain.deposit_rescue_nonce(&self.pin, &from).await? > nonce
            }
            _ => false,
        };
        if landed {
            let fee = record.fee();
            let landing = Landing {
                tx: None,
                shielded: Amount(record.value.0.saturating_sub(fee)),
                fee: Amount(fee),
                at: now,
            };
            return keep(store, self.account, &[&record.landed(landing, now)]);
        }
        if record.kind == DepositKind::Shield {
            let uses = self.chain.deposit_addresses(&self.pin, &[from]).await?;
            let [address] = uses[..] else {
                return fail(
                    ErrorCode::ChainUnreadable,
                    "a balance read answered another count",
                );
            };
            if address.balance < record.value.0 {
                return keep(
                    store,
                    self.account,
                    &[&record.ended(DepositState::Replaced, now)],
                );
            }
        }
        Ok(())
    }

    /// A request the relayer named transactions for: the last, followed on
    /// the chain. Mined and believed, it landed; mined and not believed, it
    /// is posted again later; reverted, the address waits an hour.
    async fn follow(
        &self,
        store: &mut SwapStore,
        record: DepositRecord,
        context: &PassContext<'_>,
    ) -> Result<()> {
        let Some(transaction) = record.transactions.last().map(|tx| tx.0) else {
            let posted = record.unanswered(None, false, self.clock.now());
            return keep(store, self.account, &[&posted]);
        };
        let status = self.chain.deposit_status(&transaction).await?;
        let now = self.clock.now();
        match status {
            TransactionStatus::Confirmed => {
                match self.landing(store, &record, &transaction, now).await? {
                    Some(landing) => keep(store, self.account, &[&record.landed(landing, now)]),
                    None => {
                        log::warn!(
                            "private usd: a transaction named for the deposit of address {} is not its deposit",
                            record.index
                        );
                        let mut unbelieved = record.unanswered(None, false, now);
                        unbelieved.transactions.clear();
                        unbelieved.conflict = false;
                        keep(store, self.account, &[&unbelieved])
                    }
                }
            }
            TransactionStatus::Reverted => {
                log::warn!(
                    "private usd: the deposit of address {} reverted",
                    record.index
                );
                keep(
                    store,
                    self.account,
                    &[&record.ended(DepositState::Reverted, now)],
                )
            }
            TransactionStatus::Unknown
                if now > record.expires_at().saturating_add(CLOCK_SLACK_SECONDS) =>
            {
                // Not on chain and past its validity: it can never land.
                keep(
                    store,
                    self.account,
                    &[&record.ended(DepositState::Expired, now)],
                )
            }
            TransactionStatus::Unknown | TransactionStatus::Pending
                if context.may_post
                    && now.saturating_sub(record.posted_at.unwrap_or(0)) >= REPOST_SECONDS =>
            {
                // Not mined in a minute: the same bytes again, and the
                // relayer names what sends them now.
                self.post_kept(store, record, context).await
            }
            TransactionStatus::Unknown | TransactionStatus::Pending => Ok(()),
        }
    }

    /// The pinned contract's record of `record`'s deposit in `transaction`'s
    /// receipt: its `DepositShielded` (a rescue's `Rescued`) naming this
    /// address, with this request's note, or with a `409` any note of this
    /// wallet's: one of the address's kept requests, or one Railgun's
    /// `Shield` in the same receipt recorded and the account's Railgun keys
    /// open.
    async fn landing(
        &self,
        store: &SwapStore,
        record: &DepositRecord,
        transaction: &[u8; 32],
        now: u64,
    ) -> Result<Option<Landing>> {
        let Some(logs) = self.chain.receipt_logs(transaction).await? else {
            return Ok(None);
        };
        let event = keccak(&[match record.kind {
            DepositKind::Shield => DEPOSIT_SHIELDED_EVENT.as_bytes(),
            DepositKind::Rescue => RESCUED_EVENT.as_bytes(),
        }]);
        let from = address_word(&record.from());
        let mut own: HashSet<[u8; 32]> = record.commitment().into_iter().collect();
        if record.conflict {
            own.extend(
                records(store, self.account)?
                    .iter()
                    .filter(|kept| kept.index == record.index && kept.kind == record.kind)
                    .filter_map(DepositRecord::commitment),
            );
        }
        for log in &logs {
            let ours_shape = log.address == self.pin.contract
                && log.topics.len() == 2
                && log.topics[0] == event
                && log.topics[1] == from
                && log.data.len() == 4 * WORD;
            if !ours_shape {
                continue;
            }
            let words = abi::words(&log.data, 4)?;
            let note = words[3];
            let believed =
                own.contains(&note) || (record.conflict && self.railgun_shielded(&logs, &note)?);
            if !believed {
                continue;
            }
            let (Ok(shielded), Ok(fee)) = (u128_word(&words[0]), u128_word(&words[1])) else {
                continue;
            };
            return Ok(Some(Landing {
                tx: Some(Hex(*transaction)),
                shielded: Amount(shielded),
                fee: Amount(fee),
                at: now,
            }));
        }
        Ok(None)
    }

    /// Whether Railgun's `Shield` in `logs` recorded a note with
    /// `commitment` that the account's Railgun keys open.
    fn railgun_shielded(&self, logs: &[ReceiptLog], commitment: &[u8; 32]) -> Result<bool> {
        let topic = keccak(&[abi::RAILGUN_SHIELD_EVENT.as_bytes()]);
        let notes: Vec<ShieldNote> = logs
            .iter()
            .filter(|log| {
                log.address == self.pins.railgun_proxy && log.topics.first() == Some(&topic)
            })
            .filter_map(|log| abi::decode_railgun_shield(&log.data).ok())
            .flatten()
            .filter(|note| note.commitment() == *commitment)
            .collect();
        if notes.is_empty() {
            return Ok(false);
        }
        let railgun = self.keys.railgun_keys()?;
        Ok(notes.iter().any(|note| railgun.open(note).is_some()))
    }

    /// Posts `record`'s request: the same bytes again, waiting out a `503`
    /// that asks 30 s or less for up to 90 s in all.
    async fn post(&self, record: &DepositRecord) -> Answer {
        let mut waited = 0u64;
        loop {
            if self.check_cancelled().is_err() {
                return Answer::Retry {
                    after: None,
                    waiting: false,
                };
            }
            let answer = match (&record.shield, &record.rescue) {
                (Some(shield), _) => self.relayer.deposit_shield(shield).await,
                (_, Some(rescue)) => self.relayer.deposit_rescue(rescue).await,
                (None, None) => return Answer::Refused { status: 0 },
            };
            let refusal = match answer {
                Ok(sent) if !sent.transactions.is_empty() => {
                    return Answer::Sent(sent.transactions.iter().map(|tx| tx.0).collect())
                }
                // An empty list names nothing: no answer.
                Ok(_) => {
                    return Answer::Retry {
                        after: None,
                        waiting: false,
                    }
                }
                Err(SwapHttpError::Refused(refusal)) => refusal,
                // The request does not encode: nothing went, nor will.
                Err(SwapHttpError::Invalid(_)) => return Answer::Refused { status: 0 },
                Err(_) => {
                    return Answer::Retry {
                        after: None,
                        waiting: true,
                    }
                }
            };
            match refusal.status {
                409 => return Answer::Conflict(refusal.transactions),
                400 | 415 | 422 => {
                    return Answer::Refused {
                        status: refusal.status,
                    }
                }
                503 => {
                    if let Some(after) = refusal.retry_after_secs {
                        let wait = after.max(1);
                        if after <= BUSY_WAIT_SECONDS && waited + wait <= BUSY_PATIENCE_SECONDS {
                            self.wait(wait).await;
                            waited += wait;
                            continue;
                        }
                    }
                    return Answer::Retry {
                        after: retry_after(&refusal),
                        waiting: true,
                    };
                }
                _ => {
                    return Answer::Retry {
                        after: retry_after(&refusal),
                        waiting: true,
                    }
                }
            }
        }
    }

    /// Waits `seconds`, a second at a time, stopping early once cancelled.
    async fn wait(&self, seconds: u64) {
        for _ in 0..seconds {
            if self.check_cancelled().is_err() {
                return;
            }
            self.clock.sleep(Duration::from_secs(1)).await;
        }
    }

    /// Which used addresses' vaults hold more than a rescue's fee (the terms'
    /// `fee` alone, at most the cap).
    async fn rescuable(&self, scan: &DepositScan, terms: &DepositTerms) -> Result<Vec<Rescuable>> {
        if require_within_fee_cap(terms.fee).is_err() {
            return Ok(Vec::new());
        }
        let deposited: Vec<u32> = scan
            .used
            .iter()
            .filter(|address| address.deposited)
            .map(|address| address.index)
            .collect();
        if deposited.is_empty() {
            return Ok(Vec::new());
        }
        let owners = deposited
            .iter()
            .map(|index| self.address(*index))
            .collect::<Result<Vec<_>>>()?;
        let held = self.chain.vault_balances(&self.pin, &owners).await?;
        if held.len() != owners.len() {
            return fail(
                ErrorCode::ChainUnreadable,
                "a vault read answered another count",
            );
        }
        Ok(deposited
            .into_iter()
            .zip(held)
            .filter(|(_, held)| *held > terms.fee)
            .map(|(index, held)| Rescuable {
                index,
                held,
                fee: terms.fee,
            })
            .collect())
    }

    /// Shields again what Railgun sent back to address `index`'s vault, the
    /// user's action behind a confirmation: signed with a fresh nonce and
    /// deadline, kept, then posted. It pays the terms' `fee` alone, at most
    /// the cap. `Unavailable` when the vault holds no more than the fee;
    /// `Busy` while a rescue of the address is under way.
    pub(crate) async fn rescue(&self, store: &mut SwapStore, index: u32) -> Result<DepositRecord> {
        self.require_chain().await?;
        let terms = self.terms().await?;
        let fee = terms.fee;
        require_within_fee_cap(fee)?;
        if records(store, self.account)?.iter().any(|record| {
            record.kind == DepositKind::Rescue && record.index == index && !record.state.finished()
        }) {
            return fail(ErrorCode::Busy, "a rescue of this address is on its way");
        }
        let keys = self.keys.deposit_keys(index)?;
        let from = keys.key.address();
        let vaults = self.chain.vault_balances(&self.pin, &[from]).await?;
        let [held] = vaults[..] else {
            return fail(
                ErrorCode::ChainUnreadable,
                "a vault read answered another count",
            );
        };
        if held <= fee {
            return fail(
                ErrorCode::Unavailable,
                "the vault holds nothing to rescue beyond the fee",
            );
        }
        let nonce = self.chain.deposit_rescue_nonce(&self.pin, &from).await?;
        let note = self
            .keys
            .railgun_keys()?
            .note(&keys.rescue_entropy(nonce))
            .map_err(|error| {
                PrivateUsdError::new(ErrorCode::Other, format!("rescue note: {error}"))
            })?;
        let now = self.clock.now();
        let deadline = now + validity(&terms);
        let digest = self.domain().rescue(
            &from,
            &note.commitment(),
            &terms.relayer,
            fee,
            RescueAuthorization { nonce, deadline },
        );
        let request = RescueRequest {
            chain_id: self.pins.chain_id,
            contract: Hex(self.pin.contract),
            from: Hex(from),
            note: SwapNote::from(&note),
            fee: Amount(fee),
            nonce,
            deadline,
            signature: Hex(keys.key.sign(&digest)),
        };
        check_body(&request)?;
        let record = DepositRecord {
            id: format!("rescue-{index}-{nonce}-{deadline}"),
            kind: DepositKind::Rescue,
            index,
            state: DepositState::Signed,
            created_at: now,
            value: Amount(held),
            terms: SignedTerms::of(&terms),
            shield: None,
            rescue: Some(request),
            nonce: None,
            after_refusal: false,
            posted_at: None,
            retry_at: None,
            backoff: 0,
            waiting: false,
            transactions: Vec::new(),
            conflict: false,
            landing: None,
            ended_at: None,
        };
        keep(store, self.account, &[&record])?;
        let context = PassContext {
            terms: Some(&terms),
            may_post: true,
            scan: None,
        };
        let id = record.id.clone();
        self.post_kept(store, record, &context).await?;
        records(store, self.account)?
            .into_iter()
            .find(|kept| kept.id == id)
            .ok_or_else(|| {
                PrivateUsdError::new(ErrorCode::StoreUnreadable, "the rescue is not kept")
            })
    }
}

/// An account's deposits over routed HTTP, the pinned contracts and the
/// keyed or keyless RPC.
pub(crate) type WalletDeposits<'a> = Deposits<'a, RoutedHttp, EvmRpc<'a, RoutedHttp>, SystemClock>;

/// Runs `step` on the account's deposits and `swaps.db`; cancelling `op`
/// stops its requests and the pass. The caller holds the account's deposit
/// lock.
pub(crate) async fn run<R>(
    store_dir: &Path,
    keys: &SwapKeyContext,
    account: &str,
    eth_rpc_url: &str,
    op: Option<&OpHandle>,
    step: impl AsyncFnOnce(&WalletDeposits<'_>, &mut SwapStore) -> Result<R>,
) -> Result<R> {
    let transport = swap::transport(op);
    let pins = deployment::deployment(keys.network());
    let chain = EvmRpc::new(&transport, pins, eth_rpc_url)?;
    let clock = SystemClock;
    let deposits = Deposits::new(pins, account, keys, &transport, &chain, &clock, op)?;
    let mut store = SwapStore::open(store_dir)?;
    step(&deposits, &mut store).await
}

/// A request's body, held to the relayer's 16 KiB.
fn check_body<B: Serialize>(request: &B) -> Result<()> {
    let body = serde_json::to_vec(request)
        .map_err(|_| PrivateUsdError::new(ErrorCode::Other, "the request does not encode"))?;
    if body.len() > MAX_REQUEST_BODY {
        return fail(
            ErrorCode::Other,
            "the request is larger than the relayer takes",
        );
    }
    Ok(())
}

/// Whether `address` is due a deposit: it holds at least the minimum, none
/// of its requests is under way, and it is not paused.
fn due(
    records: &[DepositRecord],
    address: &ScannedAddress,
    terms: &DepositTerms,
    now: u64,
) -> bool {
    address.balance.0 >= terms.min_value
        && !records
            .iter()
            .any(|record| record.index == address.index && !record.state.finished())
        && !paused(records, address.index, address.balance.0, terms, now)
}

/// Whether address `index` waits before it is signed for again: refused
/// within the hour with the same balance and terms, or reverted within the
/// hour. Only its newest request decides.
fn paused(
    records: &[DepositRecord],
    index: u32,
    balance: u128,
    terms: &DepositTerms,
    now: u64,
) -> bool {
    let Some(newest) = records
        .iter()
        .find(|record| record.index == index && record.kind == DepositKind::Shield)
    else {
        return false;
    };
    let since = now.saturating_sub(newest.ended_at.unwrap_or(0));
    match newest.state {
        DepositState::Refused => {
            since < REFUSED_PAUSE_SECONDS && newest.value.0 == balance && newest.terms.same(terms)
        }
        DepositState::Reverted => since < REVERTED_PAUSE_SECONDS,
        _ => false,
    }
}

/// When a pass should run again for `records`: soon while one is posted,
/// at its retry while one waits to be posted again.
fn next_poll(records: &[DepositRecord], now: u64) -> Option<Duration> {
    records
        .iter()
        .filter_map(|record| match record.state {
            DepositState::Sent => Some(FOLLOW_EVERY),
            DepositState::Signed => Some(Duration::from_secs(
                record
                    .retry_at
                    .map_or(BACKOFF_SECONDS, |at| at.saturating_sub(now))
                    .max(1),
            )),
            _ => None,
        })
        .min()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::wallet::private_usd::PrivateUsdNetwork;
    use crate::wallet::private_usd::{abi::hex0x, deployment};

    fn hex_bytes(text: &str) -> Vec<u8> {
        hex::decode(text.trim_start_matches("0x")).unwrap()
    }

    /// The addresses ethers derives from known seeds and paths: any wallet
    /// that takes a derivation path finds them. Both networks, accounts above
    /// 0 and indices above 0, through the account's ZIP-32 index, as EIP-55
    /// writes them.
    #[test]
    fn deposit_addresses_are_the_ones_other_wallets_derive() {
        let seed_a = "0x9dfc3c64c2f8bede1533b6a79f8570e5943e0b8fd1cf77107adf7b72cef42185d564a3aee24cab43f80e3c4538087d70fc824eabbad596a23c97b6ee8322ccc0";
        let seed_b = "0x5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4";
        let seed_c = "0x4ad883f4bd38fb5f190bba027d1d1905397e1f22dd05c0fb0000471522789e05";
        let vectors = [
            (
                seed_a,
                PrivateUsdNetwork::Mainnet,
                0,
                0,
                "0xA94C82a5Cd0a5104B6abd66cbB127c6B1a81250D",
            ),
            (
                seed_a,
                PrivateUsdNetwork::Mainnet,
                0,
                19,
                "0xc0DE0cf2c15baB02b4F47bE6F4f405AaD33EC816",
            ),
            (
                seed_a,
                PrivateUsdNetwork::Mainnet,
                7,
                3,
                "0x34c5711759A6691910b4C52811162DE0E8df0b41",
            ),
            (
                seed_a,
                PrivateUsdNetwork::Testnet,
                0,
                1,
                "0xAE45E0bfc615883482B75FcCa02277f5fc34571f",
            ),
            (
                seed_a,
                PrivateUsdNetwork::Testnet,
                1,
                0,
                "0xDC882eD150675aCc5895a301D0dE76E7Ee59d41F",
            ),
            (
                seed_b,
                PrivateUsdNetwork::Mainnet,
                1,
                0,
                "0x714D8792D3D58376d720aDf326835A8F37cADc10",
            ),
            (
                seed_b,
                PrivateUsdNetwork::Testnet,
                0,
                0,
                "0xe7132b3e464d4AAa4CD7361c82fed5Ae2B889d8A",
            ),
            (
                seed_b,
                PrivateUsdNetwork::Testnet,
                7,
                3,
                "0x032e44DC477cd0f4c277e7d3a32069eF7a8f87fe",
            ),
            (
                seed_c,
                PrivateUsdNetwork::Mainnet,
                0,
                1,
                "0x90c45459351cCe09CE90818B6C358370076255a0",
            ),
            (
                seed_c,
                PrivateUsdNetwork::Testnet,
                0,
                19,
                "0x66CF8f802376C8afCA2888805477EEf02244199d",
            ),
        ];
        for (seed, network, account, index, expected) in vectors {
            let keys = SwapKeyContext::for_tests(&hex_bytes(seed), network, account);
            let address = keys.deposit_keys(index).unwrap().key.address();
            assert_eq!(eip55(&address), expected, "{network:?} {account}/{index}");
        }
    }

    /// The notes the Android wallet builds for the same deposit address and
    /// Railgun wallet (zecSwap's `crates/zecswap-jni/tests/deposits.rs` and
    /// `AtomicSwapTest.depositNotes`): a shield for an authorization valid
    /// before 1 790 000 000, and the vault's first rescue. The Railgun keys
    /// are a seed's of its own, as libzecswap takes them; signing composes
    /// the account's deposit keys with them the same way.
    #[test]
    fn deposit_notes_are_the_ones_the_android_wallet_builds() {
        let context = SwapKeyContext::for_tests(&[7; 64], PrivateUsdNetwork::Testnet, 0);
        let keys = context.deposit_keys(0).unwrap();
        let railgun = zecswap_railgun::Keys::from_seed(&[8; 64], 0);

        let shield = railgun.note(&keys.shield_entropy(1_790_000_000)).unwrap();
        assert_eq!(
            shield.words().map(|word| hex0x(&word)),
            [
                "0x15f85d1d25c867703e280aca9580d5e32936dab954250744893bf967f9b86758",
                "0x8da3b2fca02e90a1ff4e8c84d2997579485257500db5935a9d39f1480650a2d5",
                "0x6d9e51f2199703b7ae13b6435d63e1e232ba0c4cb64ac4f7d5cfcd8d1b5e55c7",
                "0x1881c394f5d1926107f78fc402ade1354aa2d2a70021868691fd74d50dcc9298",
                "0xdfd7ff431856fb4cfb9de4047e42f9481270266327a4c11361abe5f8b648a6dd",
            ]
        );
        assert_eq!(
            hex0x(&shield.commitment()),
            "0x7544c517c31d651b094aa7d6eae02d4265f711a56cc4e0e11533cac7539bfa14"
        );

        let rescue = railgun.note(&keys.rescue_entropy(0)).unwrap();
        assert_eq!(
            rescue.words().map(|word| hex0x(&word)),
            [
                "0x2cb930fd875166de6013f1de6c85b7e3c8f92e056e397580a3353ca93c61de45",
                "0xbc4c816d390cea4ce439b2bb5de87e6d2627b2c25f332248750a614e1c4a7ad6",
                "0xbb1a50eaa74ed61b1fa7c0f40cfe709fb4176642e6939bb743d1b35dc8ab920b",
                "0xd7fa1977849a1bf55fa460e415909e3390aaef0c894d8836a693f4629c16ecfa",
                "0x2b19ea4d15e10221fba6ef9f984a38405dfb7affa618116f4bb16b537dd0ba1e",
            ]
        );
        assert_eq!(
            hex0x(&rescue.commitment()),
            "0xc3eee5aa58bc19bf3b51b253422437ef3f85202c73154981583fcd619f0b329d"
        );
    }

    /// The relayer's cases for `deposit_fee`, and the cap: over it refused, a
    /// fee of the whole value or more refused, and the cap grows with the
    /// deposit.
    #[test]
    fn the_fee_cap_grows_with_the_deposit_and_refuses_above_it() {
        assert_eq!(deposit_fee(100_000, 10, 25_000_000), 125_000);
        assert_eq!(deposit_fee(100_000, 10, 1), 100_001);
        assert_eq!(deposit_fee(0, 10, 9_999), 10);
        assert_eq!(deposit_fee(0, 10, 10_000), 10);
        assert_eq!(deposit_fee(100_000, 0, 25_000_000), 100_000);
        assert_eq!(deposit_fee(u128::MAX, 10, u128::MAX), u128::MAX);

        // The hosted terms: $0.10 and 0.1%.
        assert_eq!(capped_fee(100_000, 10, 5_000_000).unwrap(), 105_000);
        assert_eq!(arrives(5_000_000, 105_000), 4_882_763);
        // The cap is 2 USDC and 0.5% of the value, rounded up.
        assert_eq!(fee_cap(0), 2_000_000);
        assert_eq!(fee_cap(1_000_000_000), 7_000_000);
        assert_eq!(fee_cap(1), 2_000_001);
        assert_eq!(capped_fee(2_000_000, 50, 1_000_000_000).unwrap(), 7_000_000);
        assert_eq!(
            capped_fee(2_000_001, 50, 1_000_000_000).unwrap_err().code,
            ErrorCode::RelayerFee
        );
        assert_eq!(
            capped_fee(0, 51, 1_000_000_000_000).unwrap_err().code,
            ErrorCode::RelayerFee
        );
        // A fee that grows with the value stays under a cap that grows too:
        // 2 USDC and 0.6% is over it for a large deposit, not a small one.
        assert!(capped_fee(1_000_000, 60, 10_000_000).is_ok());
        assert_eq!(
            capped_fee(1_000_000, 60, 1_000_000_000_000)
                .unwrap_err()
                .code,
            ErrorCode::RelayerFee
        );
        // Not under the value: nothing would be shielded.
        assert_eq!(
            capped_fee(100_000, 0, 100_000).unwrap_err().code,
            ErrorCode::RelayerFee
        );
        assert_eq!(
            capped_fee(100_000, 0, 99_999).unwrap_err().code,
            ErrorCode::RelayerFee
        );
        assert!(capped_fee(100_000, 0, 100_001).is_ok());
    }

    /// The terms are the pin's or refused: another chain, Deposits contract,
    /// deposits account or token is never followed, and a relayer without
    /// deposits has none. Mainnet's pin is checked against its live terms.
    #[test]
    fn terms_that_are_not_the_pins_are_refused() {
        let pins = deployment::deployment(PrivateUsdNetwork::Testnet);
        let pin = pins.deposits.unwrap();
        let hosted = json!({
            "relayer": hex0x(&pins.relayer),
            "chainId": pins.chain_id,
            "contract": hex0x(&pins.swap_contract().unwrap().address),
            "fee": "100000",
            "deposits": {
                "contract": hex0x(&pin.contract),
                "relayer": hex0x(&pin.relayer),
                "token": hex0x(&pin.token),
                "fee": "100000",
                "feeBps": 10,
                "feeExpiresAt": 1_792_371_546u64,
                "minValue": "2000000",
                "maxValidity": 86_400,
                "maxGasPriceWei": "50000000000",
                "laterField": true,
            },
        });
        let read = |terms: &serde_json::Value| {
            let terms: RelayerTerms = serde_json::from_value(terms.clone()).unwrap();
            pinned_terms(&terms, pins)
        };
        assert_eq!(
            read(&hosted).unwrap(),
            DepositTerms {
                relayer: pin.relayer,
                fee: 100_000,
                fee_bps: 10,
                fee_expires_at: Some(1_792_371_546),
                min_value: 2_000_000,
                max_validity: 86_400,
            }
        );
        let other = hex0x(&[0x77; 20]);
        for (field, value) in [
            ("contract", other.clone()),
            ("relayer", other.clone()),
            ("token", other.clone()),
            // The top-level relayer, which payouts are signed for, is not
            // the deposits account.
            ("relayer", hex0x(&pins.relayer)),
            // The retired test token.
            ("token", "0x5764d0044bef5aa839e0ddafe2073421101b9ed8".into()),
        ] {
            let mut edited = hosted.clone();
            edited["deposits"][field] = json!(value);
            assert_eq!(
                read(&edited).unwrap_err().code,
                ErrorCode::WrongDeployment,
                "{field}"
            );
        }
        let mut chain = hosted.clone();
        chain["chainId"] = json!(1);
        assert_eq!(read(&chain).unwrap_err().code, ErrorCode::WrongDeployment);
        let mut none = hosted.clone();
        none.as_object_mut().unwrap().remove("deposits");
        assert_eq!(read(&none).unwrap_err().code, ErrorCode::Unavailable);
        let mut unreadable = hosted.clone();
        unreadable["deposits"]["minValue"] = json!(2_000_000);
        assert_eq!(read(&unreadable).unwrap_err().code, ErrorCode::Unavailable);
        // Mainnet's live terms name its pin; testnet's, relabelled as
        // mainnet's, do not.
        let mainnet = deployment::deployment(PrivateUsdNetwork::Mainnet);
        let live = json!({
            "relayer": "0xcbcb5f57c79c88a0e4bb450289de2088958a017f",
            "chainId": 1,
            "contract": "0x4708d7d36992b7e33ad97a1ab0a31c3ac6c4fe6d",
            "fee": "500000",
            "deposits": {
                "contract": "0xebc7508e20bd4467491ee7e7589d5c7d4c5e8cb6",
                "relayer": "0x6ae40b34c32d3feaa0eef53d7e4724160b7a2135",
                "token": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
                "fee": "103843",
                "feeBps": 10,
                "feeExpiresAt": 1_792_386_913u64,
                "minValue": "1000000",
                "maxValidity": 86_400,
                "maxGasPriceWei": "20000000000",
            },
        });
        let on_mainnet = |terms: &serde_json::Value| {
            let terms: RelayerTerms = serde_json::from_value(terms.clone()).unwrap();
            pinned_terms(&terms, mainnet)
        };
        assert_eq!(
            on_mainnet(&live).unwrap(),
            DepositTerms {
                relayer: hex_bytes("0x6ae40b34c32d3feaa0eef53d7e4724160b7a2135")
                    .try_into()
                    .unwrap(),
                fee: 103_843,
                fee_bps: 10,
                fee_expires_at: Some(1_792_386_913),
                min_value: 1_000_000,
                max_validity: 86_400,
            }
        );
        assert_eq!(
            on_mainnet(&chain).unwrap_err().code,
            ErrorCode::WrongDeployment
        );
    }
}
