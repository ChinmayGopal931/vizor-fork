//! The Railgun send log and its settlement.
//!
//! Dart prices and proves a send or withdrawal on the Railgun page. Rust
//! keeps the proof before anything goes out ([`keep`]), posts only what it
//! kept ([`Sends::transact`]), and settles it from the chain
//! ([`Sends::settle_all`]): its transaction's receipt, or the nullifiers it
//! spends. A send still being proved is never written: nothing left the
//! wallet for it.
//!
//! The log is also the spend guard's memory across restarts: an
//! `unconfirmed` row blocks the account's next payment until the chain
//! settles it, and a log that does not read keeps spending blocked.
//!
//! Never log a record or a request: they hold the proof.

use std::fmt;

use serde::{Deserialize, Serialize};

use super::abi::hex0x;
use super::deployment::{require_within_fee_cap, Deployment};
use super::engine::{AccountLocks, Clock};
use super::evm_rpc::{SendChain, TransactionStatus};
use super::models::{decode_strict, Address, Amount, Hex, RailgunTransactRequest, Word};
use super::relayer_client::{RailgunBroadcast, RelayerClient};
use super::store::{SendRow, SendState, SwapStore};
use super::transport::HttpTransport;
use super::{fail, railgun_keys, with_operations, ErrorCode, PrivateUsdError, Result};

/// A send still out is asked about again after this.
const ASK_AGAIN_AFTER_SECONDS: u64 = 3 * 60;
/// A send whose notes the relayer called spent, while the chain shows none
/// of them spent, is posted again after this.
const SPENT_RECHECK_AFTER_SECONDS: u64 = 15 * 60;
/// The most the relayer takes in one post.
const MAX_TRANSACT_BODY: usize = 132 * 1024;
/// A send id is the UUID Dart made when the send began.
const MAX_SEND_ID_CHARS: usize = 64;

/// One Railgun transaction of a proof, and the nullifiers it spends.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct RailgunSpend {
    pub tree: u32,
    pub nullifiers: Vec<Word>,
}

/// A kept proof, and when the relayer last answered about it.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Relay {
    pub request: RailgunTransactRequest,
    pub spends: Vec<RailgunSpend>,
    /// Unix seconds of the last post.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub posted_at: Option<u64>,
    /// Unix seconds of the last answer that a note it spends is spent, which
    /// the chain then settles.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spent_at: Option<u64>,
    /// The relayer's own transactions that answer named as spending them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub spent_in: Vec<Word>,
    /// Unix seconds before which the relayer asked not to be posted again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<u64>,
}

/// One send or withdrawal: `relay` while it is unconfirmed, none once it
/// landed.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SendRecord {
    pub id: String,
    pub token: Address,
    /// Base units taken from the private balance, the relayer's fee aside.
    pub amount: Amount,
    /// The relayer's fee in the deployment token's base units, paid on top.
    pub fee: Amount,
    /// A `0zk` address (a send) or a `0x` one (a withdrawal).
    pub to: String,
    /// Unix seconds when it was kept.
    pub sent_at: u64,
    /// The relayer's transaction, once it named one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tx_hash: Option<Word>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay: Option<Relay>,
}

/// Redacted: the relay holds the proof.
impl fmt::Debug for SendRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SendRecord")
            .field("id", &self.id)
            .field("tx_hash", &self.tx_hash)
            .field("confirmed", &self.confirmed())
            .finish_non_exhaustive()
    }
}

impl SendRecord {
    /// Seen in a block, or its nullifiers were.
    pub(crate) fn confirmed(&self) -> bool {
        self.relay.is_none()
    }

    pub(crate) fn withdraw(&self) -> bool {
        self.to.starts_with("0x")
    }

    /// The relayer sent the request in `transaction`.
    fn submitted(mut self, transaction: Word, at: u64) -> Self {
        self.tx_hash = Some(transaction);
        if let Some(relay) = &mut self.relay {
            relay.posted_at = Some(at);
            relay.spent_at = None;
            relay.spent_in.clear();
            relay.retry_at = None;
        }
        self
    }

    /// Posted without an answer that settles anything; posted again no
    /// sooner than `retry_at`.
    fn posted(mut self, at: u64, retry_at: Option<u64>) -> Self {
        if let Some(relay) = &mut self.relay {
            relay.posted_at = Some(at);
            relay.retry_at = retry_at;
        }
        self
    }

    /// The relayer answered that a note it spends is spent, by `transactions`
    /// of its own where it named any.
    fn spent(mut self, at: u64, transactions: Vec<Word>) -> Self {
        if let Some(relay) = &mut self.relay {
            relay.posted_at = Some(at);
            relay.spent_at = Some(at);
            relay.spent_in = transactions;
            relay.retry_at = None;
        }
        self
    }

    /// It landed, in `transaction` when that is known.
    fn landed(mut self, transaction: Option<Word>) -> Self {
        self.tx_hash = transaction;
        self.relay = None;
        self
    }

    /// The same proved send, whatever became of it since.
    fn same_send(&self, other: &Self) -> bool {
        let proof = |send: &Self| {
            send.relay
                .as_ref()
                .map(|relay| (relay.request.clone(), relay.spends.clone()))
        };
        let proofs_agree = match (proof(self), proof(other)) {
            (Some(mine), Some(theirs)) => mine == theirs,
            _ => true,
        };
        self.id == other.id
            && self.token == other.token
            && self.amount == other.amount
            && self.fee == other.fee
            && self.to == other.to
            && proofs_agree
    }
}

/// A proved send as Dart hands it over: the page's `transfer` or `unshield`
/// result, unchanged, and what it pays.
pub(crate) struct ProvedSend<'a> {
    pub id: &'a str,
    pub token: Address,
    pub amount: Amount,
    pub fee: Amount,
    pub to: &'a str,
    /// `{chainId, to, data, value, spends: [{tree, nullifiers}], …}`.
    pub proof_json: &'a str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PageProof {
    chain_id: u64,
    to: Address,
    data: String,
    value: String,
    spends: Vec<PageSpend>,
}

#[derive(Deserialize)]
struct PageSpend {
    tree: u32,
    nullifiers: Vec<String>,
}

/// Keeps `send` before it goes out: a send this fails for must not go. The
/// proof must be this deployment's (its chain, Railgun's proxy, no value,
/// nullifiers in every spend) and pay the relayer no more than the cap
/// (`RelayerFee`). `Busy` while another payment of the account is unsettled
/// or a conversion is under way: one outgoing payment at a time, across
/// restarts. The same send kept again is the send already kept; another
/// proof under its id is `Mismatch`, never kept.
pub(crate) fn keep(
    store: &mut SwapStore,
    pins: &Deployment,
    account: &str,
    send: &ProvedSend<'_>,
    now: u64,
) -> Result<SendRecord> {
    let record = proved_record(pins, send, now)?;
    with_operations(|| {
        let kept = records(store, account)?;
        if let Some(earlier) = kept.iter().find(|earlier| earlier.id == record.id) {
            return if earlier.same_send(&record) {
                Ok(earlier.clone())
            } else {
                fail(ErrorCode::Mismatch, "another send is kept under this id")
            };
        }
        if kept.iter().any(|earlier| !earlier.confirmed()) {
            return fail(ErrorCode::Busy, "an earlier payment is not settled yet");
        }
        if store.unfinished_count(account)? > 0 {
            return fail(ErrorCode::Busy, "a conversion is under way");
        }
        write(store, account, &record)?;
        Ok(record)
    })
}

/// The account's sends, newest first. One that does not read makes the
/// whole log unreadable (`StoreUnreadable`), which keeps spending blocked.
pub(crate) fn records(store: &SwapStore, account: &str) -> Result<Vec<SendRecord>> {
    store.sends(account)?.iter().map(decode_row).collect()
}

/// Per-account passes: a post and a settlement never run at once for one
/// account.
static SEND_LOCKS: AccountLocks = AccountLocks::new();

/// How many of a proof's nullifiers are spent. One transact spends all of
/// its nullifiers or none of them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Nullifiers {
    Unspent,
    PartlySpent,
    AllSpent,
}

/// The relayer side of an account's sends: posting kept requests and
/// settling them.
pub(crate) struct Sends<'a, T: HttpTransport, K: Clock> {
    relayer: RelayerClient<'a, T>,
    clock: &'a K,
    account: &'a str,
}

impl<'a, T: HttpTransport, K: Clock> Sends<'a, T, K> {
    pub(crate) fn new(transport: &'a T, relayer_url: &str, clock: &'a K, account: &'a str) -> Self {
        Self {
            relayer: RelayerClient::new(transport, relayer_url),
            clock,
            account,
        }
    }

    /// Posts `send_id`'s kept request, never bytes from the caller, and notes
    /// the answer. A send not kept is an error and nothing goes out; one that
    /// landed meanwhile answers `Spent` without a post.
    pub(crate) async fn transact(
        &self,
        store: &mut SwapStore,
        send_id: &str,
    ) -> Result<RailgunBroadcast> {
        let lock = SEND_LOCKS.of(self.account);
        let _pass = lock.lock().await;
        let Some(send) = find(store, self.account, send_id)? else {
            return fail(ErrorCode::Other, "no such send");
        };
        let Some(relay) = send.relay else {
            return Ok(RailgunBroadcast::Spent(
                send.tx_hash
                    .map(|transaction| transaction.0)
                    .into_iter()
                    .collect(),
            ));
        };
        Ok(self.post(store, send_id, &relay.request).await)
    }

    /// Settles the account's unconfirmed sends, oldest first: each is
    /// confirmed, dropped, or asked about again. A pass asked for while one
    /// runs has nothing left to do. One send's failure leaves it for the next
    /// pass. Returns the sends after the pass.
    pub(crate) async fn settle_all<C: SendChain>(
        &self,
        store: &mut SwapStore,
        chain: &C,
    ) -> Result<Vec<SendRecord>> {
        let lock = SEND_LOCKS.of(self.account);
        if let Ok(_pass) = lock.try_lock() {
            let mut unconfirmed: Vec<SendRecord> = records(store, self.account)?
                .into_iter()
                .filter(|send| !send.confirmed())
                .collect();
            unconfirmed.reverse();
            for send in unconfirmed {
                if let Err(error) = self.settle(store, chain, &send).await {
                    log::warn!(
                        "private usd: send {} wasn't settled ({:?})",
                        send.id,
                        error.code
                    );
                }
            }
        }
        records(store, self.account)
    }

    /// An answer that its notes are spent settles from the chain; a named
    /// transaction from its receipt; anything else is posted again.
    async fn settle<C: SendChain>(
        &self,
        store: &mut SwapStore,
        chain: &C,
        send: &SendRecord,
    ) -> Result<()> {
        let Some(relay) = &send.relay else {
            return Ok(());
        };
        let now = self.clock.now();
        match (relay.spent_at, send.tx_hash) {
            (Some(spent_at), _) => {
                self.settle_spent(store, chain, &send.id, relay, now.saturating_sub(spent_at))
                    .await
            }
            (None, Some(transaction)) => {
                self.settle_transaction(store, chain, &send.id, transaction, relay, now)
                    .await
            }
            (None, None) => {
                self.post_again(store, &send.id, relay).await;
                Ok(())
            }
        }
    }

    /// The same bytes again, though no sooner than the relayer asked: it
    /// holds the notes of a send that reverted.
    async fn post_again(&self, store: &mut SwapStore, id: &str, relay: &Relay) {
        if relay
            .retry_at
            .is_some_and(|retry_at| self.clock.now() < retry_at)
        {
            return;
        }
        self.post(store, id, &relay.request).await;
    }

    /// A reverted send moved nothing. One still out is asked about again
    /// after a while: the same bytes answer with the transaction now sending
    /// them, a new one if the first was forgotten.
    async fn settle_transaction<C: SendChain>(
        &self,
        store: &mut SwapStore,
        chain: &C,
        id: &str,
        transaction: Word,
        relay: &Relay,
        now: u64,
    ) -> Result<()> {
        match chain.send_status(&transaction.0).await? {
            TransactionStatus::Confirmed => change(store, self.account, id, |send| {
                send.landed(Some(transaction))
            }),
            TransactionStatus::Reverted => remove(store, self.account, id),
            TransactionStatus::Pending | TransactionStatus::Unknown => {
                if now.saturating_sub(relay.posted_at.unwrap_or(0)) >= ASK_AGAIN_AFTER_SECONDS {
                    self.post_again(store, id, relay).await;
                }
                Ok(())
            }
        }
    }

    /// Its notes are spent, by a transaction of the relayer's it named or by
    /// one it does not know. One of those that succeeded means it landed.
    /// Otherwise the nullifiers tell: all spent means it landed in some
    /// transaction; some means another proof took part of its notes, and it
    /// never can; none means the relayer's transaction is still out, and the
    /// relayer looks again when asked after a while.
    async fn settle_spent<C: SendChain>(
        &self,
        store: &mut SwapStore,
        chain: &C,
        id: &str,
        relay: &Relay,
        since: u64,
    ) -> Result<()> {
        for transaction in &relay.spent_in {
            if chain.send_status(&transaction.0).await? == TransactionStatus::Confirmed {
                let landed = *transaction;
                return change(store, self.account, id, |send| send.landed(Some(landed)));
            }
        }
        match spent_nullifiers(chain, &relay.spends).await? {
            Nullifiers::AllSpent => change(store, self.account, id, |send| send.landed(None)),
            Nullifiers::PartlySpent => remove(store, self.account, id),
            Nullifiers::Unspent => {
                if since >= SPENT_RECHECK_AFTER_SECONDS {
                    self.post_again(store, id, relay).await;
                }
                Ok(())
            }
        }
    }

    /// Posts `request` and notes what the answer says before it is acted on.
    /// Once a send is kept the log is a record, not a gate:
    /// a note that fails is logged, and the answer stands. A refusal forgets
    /// the send, since nothing from it went or ever will.
    async fn post(
        &self,
        store: &mut SwapStore,
        id: &str,
        request: &RailgunTransactRequest,
    ) -> RailgunBroadcast {
        let answer = self.relayer.railgun_transact(request).await;
        let now = self.clock.now();
        let noted = match &answer {
            RailgunBroadcast::Sent(transaction) => {
                let transaction = Hex(*transaction);
                change(store, self.account, id, |send| {
                    send.submitted(transaction, now)
                })
            }
            RailgunBroadcast::Refused { status } => {
                log::warn!("private usd: the relayer refused send {id} (HTTP {status})");
                remove(store, self.account, id)
            }
            RailgunBroadcast::Spent(transactions) => {
                let transactions: Vec<Word> = transactions.iter().copied().map(Hex).collect();
                change(store, self.account, id, |send| {
                    send.spent(now, transactions)
                })
            }
            RailgunBroadcast::Retry { retry_after_secs } => {
                log::warn!("private usd: the relayer's answer for send {id} is unknown");
                let retry_at = retry_after_secs.map(|seconds| now.saturating_add(seconds));
                change(store, self.account, id, |send| send.posted(now, retry_at))
            }
        };
        if let Err(error) = noted {
            log::warn!(
                "private usd: the send log wasn't updated ({:?})",
                error.code
            );
        }
        answer
    }
}

async fn spent_nullifiers<C: SendChain>(chain: &C, spends: &[RailgunSpend]) -> Result<Nullifiers> {
    let mut total = 0usize;
    let mut spent = 0usize;
    for spend in spends {
        for nullifier in &spend.nullifiers {
            total += 1;
            if chain.nullifier_spent(spend.tree, &nullifier.0).await? {
                spent += 1;
            }
        }
    }
    Ok(if spent == 0 {
        Nullifiers::Unspent
    } else if spent == total {
        Nullifiers::AllSpent
    } else {
        Nullifiers::PartlySpent
    })
}

/// `send` as a record, once it is this deployment's: the page's own checks on
/// a proof, again.
fn proved_record(pins: &Deployment, send: &ProvedSend<'_>, now: u64) -> Result<SendRecord> {
    let mismatch = |message: &str| PrivateUsdError::new(ErrorCode::Mismatch, message);
    let id_reads = !send.id.is_empty()
        && send.id.len() <= MAX_SEND_ID_CHARS
        && send
            .id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-');
    if !id_reads {
        return Err(mismatch("the send id is malformed"));
    }
    if !pins
        .usd_tokens
        .iter()
        .any(|token| token.address == send.token.0)
    {
        return Err(mismatch("the token is not this deployment's"));
    }
    if !send.amount.is_swap_amount(true) {
        return Err(mismatch("the amount is out of range"));
    }
    require_within_fee_cap(send.fee.0)?;
    if !is_destination(send.to) {
        return Err(mismatch("the destination is not a 0zk or 0x address"));
    }
    let proof: PageProof =
        serde_json::from_str(send.proof_json).map_err(|_| mismatch("the proof does not read"))?;
    if proof.chain_id != pins.chain_id || proof.to.0 != pins.railgun_proxy || proof.value != "0" {
        return Err(mismatch(
            "the proof is not for this deployment's Railgun proxy",
        ));
    }
    let data =
        calldata(&proof.data).ok_or_else(|| mismatch("the proof's calldata is malformed"))?;
    let spends = proof
        .spends
        .iter()
        .map(|spend| {
            let nullifiers = spend
                .nullifiers
                .iter()
                .map(|text| nullifier(text))
                .collect::<Option<Vec<_>>>()?;
            (!nullifiers.is_empty()).then_some(RailgunSpend {
                tree: spend.tree,
                nullifiers,
            })
        })
        .collect::<Option<Vec<_>>>()
        .filter(|spends| !spends.is_empty())
        .ok_or_else(|| mismatch("the proof's nullifiers are malformed"))?;
    let request = RailgunTransactRequest {
        chain_id: proof.chain_id,
        to: proof.to,
        data,
        value: "0".into(),
    };
    let body = serde_json::to_vec(&request).map_err(|_| mismatch("the request does not encode"))?;
    if body.len() > MAX_TRANSACT_BODY {
        return Err(mismatch("the proof is larger than the relayer takes"));
    }
    Ok(SendRecord {
        id: send.id.to_owned(),
        token: send.token,
        amount: send.amount,
        fee: send.fee,
        to: send.to.to_owned(),
        sent_at: now,
        tx_hash: None,
        relay: Some(Relay {
            request,
            spends,
            posted_at: None,
            spent_at: None,
            spent_in: Vec::new(),
            retry_at: None,
        }),
    })
}

/// A `0zk` address, or a `0x` one other than zero.
fn is_destination(to: &str) -> bool {
    if to.starts_with("0x") {
        Address::parse(to).is_some_and(|address| address.0 != [0; 20])
    } else {
        railgun_keys::is_valid_railgun_address(to)
    }
}

/// `0x` and at least a selector of hex, lowercased.
fn calldata(text: &str) -> Option<String> {
    let bytes = hex::decode(text.strip_prefix("0x")?).ok()?;
    (bytes.len() >= 4).then(|| hex0x(&bytes))
}

/// 32 bytes of hex, `0x` optional.
fn nullifier(text: &str) -> Option<Word> {
    let digits = text.strip_prefix("0x").unwrap_or(text);
    if digits.len() != 64 {
        return None;
    }
    let mut bytes = [0u8; 32];
    hex::decode_to_slice(digits, &mut bytes).ok()?;
    Some(Hex(bytes))
}

fn find(store: &SwapStore, account: &str, id: &str) -> Result<Option<SendRecord>> {
    Ok(records(store, account)?
        .into_iter()
        .find(|send| send.id == id))
}

/// Changes `id`, if it is still kept: one read and one write by the only
/// writer, so a deleted account's send never comes back.
fn change(
    store: &mut SwapStore,
    account: &str,
    id: &str,
    transform: impl FnOnce(SendRecord) -> SendRecord,
) -> Result<()> {
    with_operations(|| {
        let Some(send) = find(store, account, id)? else {
            return Ok(());
        };
        write(store, account, &transform(send))
    })
}

/// Forgets `id`, which moved nothing.
fn remove(store: &mut SwapStore, account: &str, id: &str) -> Result<()> {
    with_operations(|| store.remove_send(account, id))
}

/// One row, one SQLite transaction, inside `with_operations`.
fn write(store: &mut SwapStore, account: &str, record: &SendRecord) -> Result<()> {
    let record_json = serde_json::to_string(record).map_err(|error| {
        PrivateUsdError::new(
            ErrorCode::StoreUnreadable,
            format!("a send does not encode: {error}"),
        )
    })?;
    store.put_send(
        account,
        &SendRow {
            send_id: record.id.clone(),
            created_at: record.sent_at,
            state: if record.confirmed() {
                SendState::Confirmed
            } else {
                SendState::Unconfirmed
            },
            record_json,
        },
    )
}

/// A kept row, strictly: unreadable, or filed under another id or state, is
/// an error.
fn decode_row(row: &SendRow) -> Result<SendRecord> {
    let record: SendRecord = decode_strict(&row.record_json)
        .map_err(|message| PrivateUsdError::new(ErrorCode::StoreUnreadable, message))?;
    let state = if record.confirmed() {
        SendState::Confirmed
    } else {
        SendState::Unconfirmed
    };
    if record.id != row.send_id || state != row.state {
        return fail(
            ErrorCode::StoreUnreadable,
            "a send is filed under another id or state",
        );
    }
    Ok(record)
}
