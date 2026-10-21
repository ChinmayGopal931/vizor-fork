//! Fakes for the swap engine's seams: one shared [`World`] behind a
//! [`ChainReader`], the maker and relayer as an [`HttpTransport`] routed by
//! path, the wallet's Zcash side and the clocks. The keys are real, the
//! maker's share and proof are real, and the store is a real `swaps.db` in a
//! temp dir. Nothing here reaches a network.

use std::cell::{Ref, RefCell, RefMut};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use http::Method;
use rand_0_10::{rand_core::UnwrapErr, rngs::SysRng};
use serde_json::{json, Value};
use tokio::sync::Notify;
use zecswap_core::{
    derive_maker_share, JointAccount, PublicShare, SecretShare, SpendKey, SwapContext, Terms,
};

use super::super::abi::keccak;
use super::super::deployment::{self, Deployment};
use super::super::engine::{Clock, MakerChecks, OpHandle};
use super::super::evm_rpc::{
    ChainReader, ConfirmedSwap, Head, PaidOut, ReverseChainState, SwapRead, SwapStage, SwapState,
    TransactionStatus,
};
use super::super::forward::{Forward, ForwardStep, ForwardWait, ForwardZcash, Quoted};
use super::super::joint::SwapTxStatus;
use super::super::keys::SwapKeyContext;
use super::super::models::{
    Direction, ForwardRecord, JointAccountId, ReverseReceiveEstimate, ReverseReceiveTransaction,
    ReverseRecord, StoredRecord, ZcashTransaction, ZcashTxId,
};
use super::super::reverse::{self, ProvedFunding, Reverse, ReverseQuoted, ReverseZcash};
use super::super::store::{self, SwapStore};
use super::super::terms::{reverse_swap_id, swap_id};
use super::super::transport::HttpTransport;
use super::super::{fail, ErrorCode, PrivateUsdNetwork, Result};
use crate::wallet::routed_http::{RoutedError, RoutedRequest, RoutedResponse};

pub(super) const NOW: u64 = 1_790_000_000;
pub(super) const DEPOSIT_ZAT: u64 = 202_021;
pub(super) const AMOUNT: u128 = 1_000_000;
pub(super) const RELAYER_FEE: u128 = 20_000;
pub(super) const DEPOSIT_FEE_ZAT: u64 = 10_000;
pub(super) const ZCASH_HEIGHT: u64 = 4_200_000;
pub(super) const NETWORK: PrivateUsdNetwork = PrivateUsdNetwork::Testnet;
pub(super) const QUOTE_ID: [u8; 32] = [0x22; 32];
// A reverse quote's deadlines (funding, ready and refund 1000, 3000 and
// 5000 s out), and the relayer's funding fee.
pub(super) const FUNDING: u64 = NOW + 1_000;
pub(super) const READY: u64 = NOW + 3_000;
pub(super) const REFUND: u64 = NOW + 5_000;
pub(super) const FUNDING_FEE: u128 = 250_000;
/// The maker's ZEC deposit into a reverse conversion's joint account.
pub(super) const REVERSE_DEPOSIT_ZAT: u64 = 100_000;
/// Railgun's unshield fee, as the Railgun page loads it.
const UNSHIELD_BPS: u128 = 25;

pub(super) fn pins() -> &'static Deployment {
    deployment::deployment(NETWORK)
}

/// The pinned windows contract.
pub(super) fn contract() -> [u8; 20] {
    pins().swap_contract().unwrap().address
}

/// The contract's `LATE_WINDOW`.
pub(super) fn late_window() -> u64 {
    pins().swap_contract().unwrap().late_window
}

/// The maker's secret share `e`, which a refund reveals.
pub(super) fn maker_secret() -> SecretShare {
    derive_maker_share(&[9; 32], 0).unwrap()
}

pub(super) fn maker_share() -> PublicShare {
    maker_secret().public()
}

/// A word with `value` in its last byte.
pub(super) fn word(value: u8) -> [u8; 32] {
    let mut word = [0u8; 32];
    word[31] = value;
    word
}

/// A transaction id named for what it is, so a test reads which one it means.
pub(super) fn tx_id(name: &str) -> ZcashTxId {
    let mut hex = hex::encode(name);
    hex.extend(std::iter::repeat_n('0', 64 - hex.len()));
    ZcashTxId::parse(&hex).unwrap()
}

pub(super) fn transaction(name: &str) -> ZcashTransaction {
    ZcashTransaction {
        tx_id: tx_id(name),
        raw: "00".into(),
        expiry_height: 4_200_040,
    }
}

/// The terms the contract hashes: eleven words, each share as its two
/// coordinates (`Terms::hash`'s encoding).
pub(super) fn terms_words(terms: &Terms) -> [[u8; 32]; 11] {
    let mut words = [[0u8; 32]; 11];
    words[0][12..].copy_from_slice(&terms.maker);
    words[1][12..].copy_from_slice(&terms.token);
    words[2][16..].copy_from_slice(&terms.amount.to_be_bytes());
    let maker = terms.maker_share.to_affine_bytes();
    words[3].copy_from_slice(&maker[..32]);
    words[4].copy_from_slice(&maker[32..]);
    let user = terms.user_share.to_affine_bytes();
    words[5].copy_from_slice(&user[..32]);
    words[6].copy_from_slice(&user[32..]);
    words[7][12..].copy_from_slice(&terms.user);
    words[8][24..].copy_from_slice(&terms.t0.to_be_bytes());
    words[9][24..].copy_from_slice(&terms.t1.to_be_bytes());
    words[10] = terms.payout_note;
    words
}

fn words_hash(words: &[[u8; 32]; 11]) -> [u8; 32] {
    let parts: Vec<&[u8]> = words.iter().map(|word| word.as_slice()).collect();
    keccak(&parts)
}

type Hook = Box<dyn FnMut(&mut State)>;

/// Everything the fakes share.
pub(super) struct State {
    // Clocks: the device's, and the chain head's.
    pub clock: u64,
    pub chain_now: u64,
    pub head_number: u64,

    // The contract.
    pub opened: bool,
    /// What the maker opened the swap with, from its accept.
    pub opened_terms: Option<Terms>,
    pub swap_id: Option<[u8; 32]>,
    pub stage: SwapStage,
    pub t0: u64,
    /// How long after `t0` the maker sets `t1`.
    pub t1_after: u64,
    /// The block a ready swap went ready in; `None`: long before the head.
    pub ready_block: Option<u64>,
    /// When the refund mined, as its event shows; `None`: no event found.
    pub refunded_at: Option<u64>,
    pub paid_out: bool,
    pub secret: [u8; 32],
    pub railgun_accepts: bool,
    /// Changes the words the contract hashes the opened terms from.
    pub tamper: Option<Box<dyn Fn(&mut [[u8; 32]; 11])>>,
    /// What a confirmed read shows instead of the swap at the tip.
    pub confirmed: Option<Box<dyn Fn(&State) -> Option<SwapState>>>,
    /// Runs before each confirmed read, with its number (1, 2, …).
    pub on_confirmed_read: Option<Box<dyn FnMut(&mut State, u32)>>,
    pub confirmed_reads: u32,
    /// Runs before each consistent read a reveal is decided on, with its
    /// number (1, 2, …).
    pub on_read: Option<Box<dyn FnMut(&mut State, u32)>>,
    pub reads: u32,
    /// The blocks the swap was read at below the head.
    pub depth_reads: Vec<u64>,
    pub payout_visible: bool,
    pub payout_hash: [u8; 32],
    pub payout_fee: u128,
    /// Swap ids an earlier use of their index left on chain.
    pub used_ids: Vec<[u8; 32]>,
    /// Swap ids an earlier use of their index left on a retired contract.
    pub used_before: Vec<[u8; 32]>,

    // A reverse escrow, open once funded, with the stage, payout and secret
    // above.
    pub escrow_terms: Option<Terms>,
    pub escrow_id: Option<[u8; 32]>,
    pub escrow_note: [u8; 32],
    pub funding_block: u64,
    /// The funding transaction as the node sees it.
    pub funding_status: TransactionStatus,
    pub vault: u128,
    pub rescue_nonce: u64,
    /// Runs before each reverse escrow read, with its number (1, 2, …).
    pub on_reverse_read: Option<Box<dyn FnMut(&mut State, u32)>>,
    pub reverse_reads: u32,

    // The maker.
    /// The amount every quote names, in token base units.
    pub amount: u128,
    pub quote_expires_at: u64,
    pub quote_requests: Vec<Value>,
    pub accept_status: u16,
    pub accept_code: Option<&'static str>,
    /// Holds the accept's answer until notified.
    pub hold_accept: Option<Arc<Notify>>,
    /// A reverse quote's funding, ready and refund deadlines.
    pub reverse_deadlines: (u64, u64, u64),
    pub reverse_accepts: u32,
    /// The late window an accept names; `None` names none.
    pub accepted_late_window: Option<u64>,
    /// What `/v1/info` adds: the contract's windows and kind.
    pub info_windows: Option<Value>,

    // The relayer.
    pub relayer: [u8; 20],
    pub relayer_fee: u128,
    pub fee_expires_at: Option<u64>,
    /// Payouts below this fee are refused `400 rejected`.
    pub least_fee: u128,
    pub claim_pays_out: bool,
    pub fee_after_claim: Option<u128>,
    /// A status and code every claim is refused with, sending nothing.
    pub claim_refusal: Option<(u16, &'static str)>,
    /// What `/v1/terms` adds: the contract's windows and kind.
    pub terms_windows: Option<Value>,
    /// Holds the answer to `/v1/terms` until notified.
    pub hold_terms: Option<Arc<Notify>>,
    /// A relayer path that never answers.
    pub unreachable: Option<&'static str>,
    /// The fee the relayer funds reverse escrows for; `None`: no sponsorship.
    pub funding_fee: Option<u128>,
    /// The transaction `/v1/reverse/fund` names; `None` names none (a
    /// matching escrow exists already).
    pub fund_hash: Option<[u8; 32]>,
    /// Holds the funding's answer until notified.
    pub hold_fund: Option<Arc<Notify>>,
    /// Every funding posted, answered or not, in order.
    pub fundings: Vec<Value>,
    /// Runs once at the next `/v1/terms` read.
    pub on_terms: Option<Hook>,

    // What was asked.
    pub paths: Vec<String>,
    pub bodies: HashMap<String, Value>,
    pub headers: HashMap<String, Vec<(String, String)>>,
    /// The fee of every payout posted with a claim or alone.
    pub posted_fees: Vec<u128>,

    // The wallet's Zcash side.
    pub synced: bool,
    pub deposit_fee: Option<u64>,
    pub unpayable: bool,
    pub deposits: Vec<(String, u64)>,
    /// The deposit the wallet created last, as its history shows it.
    pub created: Option<ZcashTransaction>,
    pub statuses: HashMap<ZcashTxId, SwapTxStatus>,
    pub submitted: Vec<ZcashTxId>,
    pub discarded: u32,
    pub crash: Option<Crash>,
    pub spendable: bool,
    pub sweeps: Vec<(u32, u64)>,
    pub forgotten: u32,
    /// The maker's ZEC in a reverse joint account, and its depth.
    pub paid_in: u64,
    pub deposit_confirmations: u32,
    /// The fee a reverse sweep's estimate names, and what a sweep pays.
    pub sweep_fee: u64,
    pub sweep_pays: u64,
    /// The fee cap each reverse sweep home was asked under.
    pub receive_caps: Vec<Option<u64>>,
    pub imports: u32,
    /// Proofs the Railgun page made.
    pub proofs: u32,
}

/// Where a crash cuts a deposit short: right after it is proposed, so the
/// save of `Started` never commits; or right after it is created, so the save
/// of its transaction never commits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Crash {
    AfterPropose,
    AfterCreate,
}

impl State {
    fn new() -> Self {
        let pins = pins();
        Self {
            clock: NOW,
            chain_now: NOW,
            head_number: 9_000_000,
            opened: false,
            opened_terms: None,
            swap_id: None,
            stage: SwapStage::Open,
            t0: NOW + 35 * 60,
            t1_after: 60 * 60,
            ready_block: None,
            refunded_at: None,
            paid_out: false,
            secret: [0; 32],
            railgun_accepts: true,
            tamper: None,
            confirmed: None,
            on_confirmed_read: None,
            confirmed_reads: 0,
            on_read: None,
            reads: 0,
            depth_reads: Vec::new(),
            payout_visible: true,
            payout_hash: word(0),
            payout_fee: RELAYER_FEE,
            used_ids: Vec::new(),
            used_before: Vec::new(),
            escrow_terms: None,
            escrow_id: None,
            escrow_note: [0; 32],
            funding_block: 0,
            funding_status: TransactionStatus::Unknown,
            vault: 0,
            rescue_nonce: 0,
            on_reverse_read: None,
            reverse_reads: 0,
            amount: AMOUNT,
            quote_expires_at: NOW + 300,
            quote_requests: Vec::new(),
            accept_status: 200,
            accept_code: None,
            hold_accept: None,
            reverse_deadlines: (FUNDING, READY, REFUND),
            reverse_accepts: 0,
            accepted_late_window: Some(late_window()),
            info_windows: None,
            relayer: pins.relayer,
            relayer_fee: RELAYER_FEE,
            fee_expires_at: None,
            least_fee: 0,
            claim_pays_out: true,
            fee_after_claim: None,
            claim_refusal: None,
            terms_windows: None,
            hold_terms: None,
            unreachable: None,
            funding_fee: Some(FUNDING_FEE),
            fund_hash: Some(word(8)),
            hold_fund: None,
            fundings: Vec::new(),
            on_terms: None,
            paths: Vec::new(),
            bodies: HashMap::new(),
            headers: HashMap::new(),
            posted_fees: Vec::new(),
            synced: true,
            deposit_fee: Some(DEPOSIT_FEE_ZAT),
            unpayable: false,
            deposits: Vec::new(),
            created: None,
            statuses: HashMap::new(),
            submitted: Vec::new(),
            discarded: 0,
            crash: None,
            spendable: true,
            sweeps: Vec::new(),
            forgotten: 0,
            paid_in: 0,
            deposit_confirmations: 10,
            sweep_fee: 10_000,
            sweep_pays: 10_000,
            receive_caps: Vec::new(),
            imports: 0,
            proofs: 0,
        }
    }

    pub(super) fn t1(&self) -> u64 {
        self.t0 + self.t1_after
    }

    /// The newest block, its hash named for its number.
    pub(super) fn head(&self) -> Head {
        let mut hash = [0u8; 32];
        hash[24..].copy_from_slice(&self.head_number.to_be_bytes());
        Head {
            number: self.head_number,
            timestamp: self.chain_now,
            hash,
        }
    }

    /// Time passes, on the device and on the chain alike.
    pub(super) fn pass(&mut self, seconds: u64) {
        self.clock += seconds;
        self.chain_now += seconds;
    }

    /// A reverse escrow as the contract keeps it: its terms only as the hash
    /// of what `openReverse` stored.
    pub(super) fn escrow_at(&self, id: &[u8; 32]) -> Option<SwapState> {
        if self.escrow_id.as_ref() != Some(id) {
            return None;
        }
        let terms = self.escrow_terms.as_ref()?;
        Some(SwapState {
            terms_hash: words_hash(&terms_words(terms)),
            stage: self.stage,
            paid_out: self.paid_out,
            secret: self.secret,
        })
    }

    /// What the contract keeps of the swap at the tip: its terms only as the
    /// hash of what it opened with.
    pub(super) fn swap_at_tip(&self, id: &[u8; 32]) -> Option<SwapState> {
        if self.used_ids.contains(id) {
            return Some(SwapState {
                terms_hash: [0xee; 32],
                stage: SwapStage::Open,
                paid_out: false,
                secret: [0; 32],
            });
        }
        if !self.opened || self.swap_id.as_ref() != Some(id) {
            return None;
        }
        let terms = self.opened_terms.as_ref()?;
        let mut words = terms_words(terms);
        if let Some(tamper) = &self.tamper {
            tamper(&mut words);
        }
        Some(SwapState {
            terms_hash: words_hash(&words),
            stage: self.stage,
            paid_out: self.paid_out,
            secret: self.secret,
        })
    }
}

/// `swap`, unless its terms hash to other than `terms`.
fn verified(swap: Option<SwapState>, terms: &Terms) -> Result<Option<SwapState>> {
    if swap
        .as_ref()
        .is_some_and(|swap| swap.terms_hash != terms.hash())
    {
        return fail(
            ErrorCode::Mismatch,
            "the swap on chain opened with other terms",
        );
    }
    Ok(swap)
}

/// The state every fake shares; single-threaded, as the engine's tests run.
#[derive(Clone)]
pub(super) struct World(Rc<RefCell<State>>);

impl World {
    pub(super) fn new() -> Self {
        Self(Rc::new(RefCell::new(State::new())))
    }

    pub(super) fn get(&self) -> Ref<'_, State> {
        self.0.borrow()
    }

    pub(super) fn set(&self) -> RefMut<'_, State> {
        self.0.borrow_mut()
    }

    /// The opened swap as a confirmed read would show it now.
    pub(super) fn snapshot(&self) -> Option<SwapState> {
        let state = self.get();
        let id = state.swap_id?;
        state.swap_at_tip(&id)
    }
}

// ---- the chain ----

pub(super) struct FakeChain(pub World);

impl ChainReader for FakeChain {
    async fn chain_id(&self) -> Result<u64> {
        Ok(pins().chain_id)
    }

    async fn head(&self) -> Result<Head> {
        Ok(self.0.get().head())
    }

    async fn swap(&self, id: &[u8; 32]) -> Result<Option<SwapState>> {
        Ok(self.0.get().swap_at_tip(id))
    }

    async fn confirmed_swap(&self, id: &[u8; 32], terms: &Terms) -> Result<ConfirmedSwap> {
        let read = {
            let mut state = self.0.set();
            state.confirmed_reads += 1;
            state.confirmed_reads
        };
        let hook = self.0.set().on_confirmed_read.take();
        if let Some(mut hook) = hook {
            hook(&mut self.0.set(), read);
            self.0.set().on_confirmed_read = Some(hook);
        }
        let state = self.0.get();
        let swap = match &state.confirmed {
            Some(confirmed) => confirmed(&state),
            None => state.swap_at_tip(id),
        };
        Ok(ConfirmedSwap {
            head: state.head(),
            swap: verified(swap, terms)?,
        })
    }

    /// The swap, or the reverse escrow, at the head, with the head.
    async fn read_swap(&self, id: &[u8; 32], terms: &Terms) -> Result<SwapRead> {
        let read = {
            let mut state = self.0.set();
            state.reads += 1;
            state.reads
        };
        let hook = self.0.set().on_read.take();
        if let Some(mut hook) = hook {
            hook(&mut self.0.set(), read);
            self.0.set().on_read = Some(hook);
        }
        let state = self.0.get();
        let swap = state.swap_at_tip(id).or_else(|| state.escrow_at(id));
        Ok(SwapRead {
            head: state.head(),
            swap: verified(swap, terms)?,
        })
    }

    /// A ready swap was still open before the block it went ready in.
    async fn swap_at(
        &self,
        id: &[u8; 32],
        terms: &Terms,
        number: u64,
    ) -> Result<Option<SwapState>> {
        self.0.set().depth_reads.push(number);
        let state = self.0.get();
        let swap = state.swap_at_tip(id).map(|mut swap| {
            if swap.stage == SwapStage::Ready
                && state.ready_block.is_some_and(|block| number < block)
            {
                swap.stage = SwapStage::Open;
            }
            swap
        });
        verified(swap, terms)
    }

    async fn maker_key_used(&self, _key: &[u8; 32]) -> Result<bool> {
        Ok(false)
    }

    async fn used_before(&self, id: &[u8; 32], _key: &[u8; 32]) -> Result<bool> {
        Ok(self.0.get().used_before.contains(id))
    }

    async fn reverse_state(&self, id: &[u8; 32], terms: &Terms) -> Result<ReverseChainState> {
        let read = {
            let mut state = self.0.set();
            state.reverse_reads += 1;
            state.reverse_reads
        };
        let hook = self.0.set().on_reverse_read.take();
        if let Some(mut hook) = hook {
            hook(&mut self.0.set(), read);
            self.0.set().on_reverse_read = Some(hook);
        }
        let state = self.0.get();
        let swap = state.escrow_at(id);
        if swap
            .as_ref()
            .is_some_and(|swap| swap.terms_hash != terms.hash())
        {
            return fail(
                ErrorCode::Mismatch,
                "the escrow on chain opened with other terms",
            );
        }
        let open = swap.is_some();
        Ok(ReverseChainState {
            head: state.head(),
            swap,
            refund_note: if open { state.escrow_note } else { [0; 32] },
            funding_block: if open { state.funding_block } else { 0 },
        })
    }

    async fn vault_balance(&self, _id: &[u8; 32]) -> Result<u128> {
        Ok(self.0.get().vault)
    }

    async fn rescue_nonce(&self, _id: &[u8; 32]) -> Result<u64> {
        Ok(self.0.get().rescue_nonce)
    }

    async fn railgun_accepts(&self) -> Result<bool> {
        Ok(self.0.get().railgun_accepts)
    }

    async fn confirmed_payout(&self, id: &[u8; 32], _since: u64) -> Result<Option<PaidOut>> {
        let state = self.0.get();
        let visible = state.paid_out && state.payout_visible && state.swap_id.as_ref() == Some(id);
        Ok(visible.then(|| PaidOut {
            transaction: state.payout_hash,
            relayer: pins().relayer,
            fee: state.payout_fee,
        }))
    }

    async fn confirmed_refund_time(&self, _id: &[u8; 32], _since: u64) -> Result<Option<u64>> {
        Ok(self.0.get().refunded_at)
    }

    async fn transaction_status(
        &self,
        _transaction: &[u8; 32],
        _confirmations: u32,
    ) -> Result<TransactionStatus> {
        Ok(self.0.get().funding_status)
    }
}

// ---- the maker and the relayer ----

/// The maker and the relayer, routed by path: what the services would answer,
/// and what their transactions would do to the contract.
pub(super) struct FakeServices(pub World);

fn answer(status: u16, body: Value) -> std::result::Result<RoutedResponse, RoutedError> {
    Ok(RoutedResponse {
        status,
        headers: vec![("content-type".into(), "application/json".into())],
        body: serde_json::to_vec(&body).unwrap(),
    })
}

fn hex0x(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

fn bytes<const N: usize>(value: &Value) -> [u8; N] {
    let text = value.as_str().unwrap();
    hex::decode(text.trim_start_matches("0x"))
        .unwrap()
        .try_into()
        .unwrap()
}

impl HttpTransport for FakeServices {
    async fn send(
        &self,
        request: RoutedRequest,
    ) -> std::result::Result<RoutedResponse, RoutedError> {
        let pins = pins();
        let (maker, path) = match request.url.strip_prefix(pins.maker_url) {
            Some(path) => (true, path.to_owned()),
            None => (
                false,
                request
                    .url
                    .strip_prefix(pins.relayer_url)
                    .expect("only the pinned maker and relayer are asked")
                    .to_owned(),
            ),
        };
        let body: Value = request
            .body
            .as_ref()
            .map(|body| serde_json::from_slice(body).unwrap())
            .unwrap_or(Value::Null);
        {
            let mut state = self.0.set();
            state.paths.push(path.clone());
            state.bodies.insert(path.clone(), body.clone());
            state.headers.insert(path.clone(), request.headers.clone());
            if path == "/v1/reverse/fund" {
                state.fundings.push(body.clone());
            }
        }
        let hold = if path.ends_with("/accept") {
            self.0.get().hold_accept.clone()
        } else if path == "/v1/reverse/fund" {
            self.0.get().hold_fund.clone()
        } else if path == "/v1/terms" {
            self.0.get().hold_terms.clone()
        } else {
            None
        };
        if let Some(hold) = hold {
            hold.notified().await;
        }
        if self.0.get().unreachable == Some(path.as_str()) {
            return Err(RoutedError {
                route_blocked: false,
                message: "no answer".into(),
            });
        }
        if maker {
            self.maker(&request.method, &path, &body)
        } else {
            self.relayer(&request.method, &path, &body)
        }
    }
}

impl FakeServices {
    fn maker(
        &self,
        method: &Method,
        path: &str,
        body: &Value,
    ) -> std::result::Result<RoutedResponse, RoutedError> {
        let pins = pins();
        match (method, path) {
            (&Method::GET, "/v1/info") => {
                let mut info = json!({
                    "apiVersion": 1,
                    "maker": hex0x(&pins.maker),
                    "chainId": pins.chain_id,
                    "contract": hex0x(&contract()),
                    "token": hex0x(&pins.token),
                    "zcashNetwork": "testnet",
                    "reverseEnabled": true,
                });
                if let Some(Value::Object(windows)) = &self.0.get().info_windows {
                    for (name, value) in windows {
                        info[name] = value.clone();
                    }
                }
                answer(200, info)
            }
            (&Method::POST, "/v1/quote") => {
                let context = SwapContext {
                    chain_id: pins.chain_id,
                    contract: contract(),
                    quote_id: QUOTE_ID,
                };
                let proof = context.prove_maker(&maker_secret(), UnwrapErr(SysRng));
                let mut state = self.0.set();
                state.quote_requests.push(body.clone());
                answer(
                    200,
                    json!({
                        "quoteId": hex0x(&QUOTE_ID),
                        "maker": hex0x(&pins.maker),
                        "makerShare": hex0x(&maker_share().to_affine_bytes()),
                        "makerProof": hex0x(&proof.to_bytes()),
                        "chainId": pins.chain_id,
                        "contract": hex0x(&contract()),
                        "token": hex0x(&pins.token),
                        "amount": state.amount.to_string(),
                        "depositZat": DEPOSIT_ZAT,
                        "expiresAt": state.quote_expires_at,
                    }),
                )
            }
            (&Method::POST, "/v1/reverse/quote") => {
                let context = SwapContext {
                    chain_id: pins.chain_id,
                    contract: contract(),
                    quote_id: QUOTE_ID,
                };
                let proof = context.prove_maker(&maker_secret(), UnwrapErr(SysRng));
                let mut state = self.0.set();
                state.quote_requests.push(body.clone());
                let (funding, ready, refund) = state.reverse_deadlines;
                answer(
                    200,
                    json!({
                        "terms": {
                            "quoteId": hex0x(&QUOTE_ID),
                            "maker": hex0x(&pins.maker),
                            "makerShare": hex0x(&maker_share().to_affine_bytes()),
                            "makerProof": hex0x(&proof.to_bytes()),
                            "chainId": pins.chain_id,
                            "contract": hex0x(&contract()),
                            "token": hex0x(&pins.token),
                            "amount": body["units"].as_u64().unwrap().to_string(),
                            "depositZat": REVERSE_DEPOSIT_ZAT,
                            "expiresAt": funding,
                        },
                        "user": body["user"],
                        "refundNote": body["refundNote"],
                        "fundingDeadline": funding,
                        "readyDeadline": ready,
                        "refundAfter": refund,
                    }),
                )
            }
            (&Method::POST, path) if path.starts_with("/v1/reverse/quote/") => {
                // The maker opens nothing yet: the user funds the escrow.
                let mut state = self.0.set();
                state.reverse_accepts += 1;
                let request = state.quote_requests.last().unwrap().clone();
                let id = reverse_swap_id(&bytes(&request["user"]), &maker_share());
                let (_, ready, refund) = state.reverse_deadlines;
                let mut accepted = json!({
                    "swapId": hex0x(&id),
                    "t0": ready,
                    "t1": refund,
                    "ticket": format!("{}.{}", hex0x(&id), "3f".repeat(32)),
                });
                if let Some(window) = state.accepted_late_window {
                    accepted["lateWindow"] = json!(window);
                }
                answer(200, accepted)
            }
            (&Method::POST, path) if path.ends_with("/accept") => {
                let mut state = self.0.set();
                if state.accept_status != 200 {
                    let mut headers = vec![("content-type".into(), "application/json".into())];
                    if state.accept_status == 401 {
                        headers.push((
                            "www-authenticate".into(),
                            r#"PrivateToken challenge="abc", token-key="def""#.into(),
                        ));
                    }
                    return Ok(RoutedResponse {
                        status: state.accept_status,
                        headers,
                        body: serde_json::to_vec(&json!({
                            "code": state.accept_code,
                            "error": "turned down",
                        }))
                        .unwrap(),
                    });
                }
                // The maker opens the swap with the quote it gave and our
                // share, paying our auth key into our note.
                let user_share =
                    PublicShare::from_affine_bytes(&bytes::<64>(&body["userShare"])).unwrap();
                let request = state.quote_requests.last().unwrap().clone();
                let id = swap_id(&pins.maker, &user_share);
                let t0 = state.t0;
                let t1 = state.t1();
                let amount = state.amount;
                state.opened_terms = Some(Terms {
                    maker: pins.maker,
                    token: pins.token,
                    amount,
                    maker_share: maker_share(),
                    user_share,
                    user: bytes(&request["payout"]),
                    t0,
                    t1,
                    payout_note: bytes(&request["payoutNote"]),
                });
                let opened = state.opened_terms.as_ref().unwrap();
                assert_eq!(
                    words_hash(&terms_words(opened)),
                    opened.hash(),
                    "the fake hashes terms as the contract does"
                );
                state.swap_id = Some(id);
                state.opened = true;
                let mut accepted = json!({
                    "swapId": hex0x(&id),
                    "t0": t0,
                    "t1": t1,
                    "ticket": format!("{}.{}", hex0x(&id), "3f".repeat(32)),
                });
                if let Some(window) = state.accepted_late_window {
                    accepted["lateWindow"] = json!(window);
                }
                answer(200, accepted)
            }
            _ => answer(404, json!({ "code": "notFound", "error": "no such path" })),
        }
    }

    fn relayer(
        &self,
        method: &Method,
        path: &str,
        body: &Value,
    ) -> std::result::Result<RoutedResponse, RoutedError> {
        let pins = pins();
        let rejected = || {
            answer(
                400,
                json!({ "code": "rejected", "error": "the fee is too low" }),
            )
        };
        match (method, path) {
            (&Method::GET, "/v1/terms") => {
                let hook = self.0.set().on_terms.take();
                if let Some(mut hook) = hook {
                    hook(&mut self.0.set());
                }
                let state = self.0.get();
                let mut terms = json!({
                    "relayer": hex0x(&state.relayer),
                    "chainId": pins.chain_id,
                    "contract": hex0x(&contract()),
                    "fee": state.relayer_fee.to_string(),
                });
                if let Some(expires_at) = state.fee_expires_at {
                    terms["feeExpiresAt"] = json!(expires_at);
                }
                if let Some(Value::Object(windows)) = &state.terms_windows {
                    for (name, value) in windows {
                        terms[name] = value.clone();
                    }
                }
                if let Some(fee) = state.funding_fee {
                    terms["reverseFunding"] = json!({
                        "relayAdapt": hex0x(&pins.relay_adapt),
                        "token": hex0x(&pins.token),
                        "maker": hex0x(&pins.maker),
                        "maxGasLimit": 4_000_000,
                        "maxGasPriceWei": "20000000000",
                        "maxCalldataBytes": 65_536,
                        "fee": fee.to_string(),
                    });
                }
                answer(200, terms)
            }
            (&Method::POST, "/v1/reverse/fund") => {
                let state = self.0.get();
                let sent: Vec<String> = state.fund_hash.iter().map(|hash| hex0x(hash)).collect();
                answer(200, json!({ "transactions": sent }))
            }
            (
                &Method::POST,
                "/v1/reverse/ready"
                | "/v1/reverse/refund"
                | "/v1/reverse/refund-payout"
                | "/v1/reverse/rescue",
            ) => answer(200, json!({ "transactions": [] })),
            (&Method::POST, "/v1/claim") => {
                let fee: u128 = body["payout"]["fee"].as_str().unwrap().parse().unwrap();
                let mut state = self.0.set();
                state.posted_fees.push(fee);
                if let Some((status, code)) = state.claim_refusal {
                    return answer(status, json!({ "code": code, "error": "not now" }));
                }
                if fee < state.least_fee {
                    return rejected();
                }
                state.stage = SwapStage::Claimed;
                if state.claim_pays_out {
                    state.paid_out = true;
                    state.payout_hash = word(1);
                    state.payout_fee = fee;
                }
                if let Some(fee) = state.fee_after_claim {
                    state.relayer_fee = fee;
                }
                answer(
                    200,
                    json!({ "transactions": [hex0x(&word(0)), hex0x(&word(1))] }),
                )
            }
            (&Method::POST, "/v1/payout") => {
                let fee: u128 = body["fee"].as_str().unwrap().parse().unwrap();
                let mut state = self.0.set();
                state.posted_fees.push(fee);
                if fee < state.least_fee {
                    return rejected();
                }
                state.paid_out = true;
                state.payout_hash = word(0);
                state.payout_fee = fee;
                answer(200, json!({ "transactions": [hex0x(&word(0))] }))
            }
            _ => answer(404, json!({ "code": "notFound", "error": "no such path" })),
        }
    }
}

// ---- the wallet's Zcash side ----

pub(super) struct FakeZcash(pub World);

/// A proposed deposit: where to, and how much.
pub(super) struct FakeProposal(String, u64);

impl ForwardZcash for FakeZcash {
    type Proposal = FakeProposal;

    async fn chain_height(&self) -> Result<u64> {
        Ok(ZCASH_HEIGHT)
    }

    async fn synced(&self) -> Result<bool> {
        Ok(self.0.get().synced)
    }

    async fn deposit_fee(&self, _address: &str, _zatoshi: u64) -> Result<Option<u64>> {
        Ok(self.0.get().deposit_fee)
    }

    async fn propose_deposit(
        &self,
        _index: u32,
        address: &str,
        zatoshi: u64,
        max_total: u64,
    ) -> Result<FakeProposal> {
        let state = self.0.get();
        if state.unpayable || zatoshi + DEPOSIT_FEE_ZAT > max_total {
            return fail(ErrorCode::DepositUnpayable, "short");
        }
        if state.crash == Some(Crash::AfterPropose) {
            store::crash_before_next_commit();
        }
        Ok(FakeProposal(address.to_owned(), zatoshi))
    }

    async fn create_deposit(&self, proposal: FakeProposal) -> Result<ZcashTransaction> {
        let mut state = self.0.set();
        state.deposits.push((proposal.0, proposal.1));
        let created = transaction(&format!("deposit{}", state.deposits.len()));
        state.created = Some(created.clone());
        if state.crash == Some(Crash::AfterCreate) {
            store::crash_before_next_commit();
        }
        Ok(created)
    }

    fn discard_deposit(&self, _proposal: FakeProposal) {
        self.0.set().discarded += 1;
    }

    async fn find_deposit(&self, _address: &str) -> Result<Option<ZcashTransaction>> {
        let state = self.0.get();
        Ok(state
            .created
            .clone()
            .filter(|created| state.statuses.get(&created.tx_id) != Some(&SwapTxStatus::Expired)))
    }

    async fn deposit_status(&self, deposit: &ZcashTransaction) -> Result<SwapTxStatus> {
        Ok(self.status(deposit))
    }

    async fn broadcast(&self, transaction: &ZcashTransaction) -> Result<()> {
        self.0.set().submitted.push(transaction.tx_id.clone());
        Ok(())
    }

    async fn prepare_sweep(
        &self,
        index: u32,
        _joint: &JointAccount,
        _key: &SpendKey,
        birthday: u64,
    ) -> Result<Option<ZcashTransaction>> {
        let mut state = self.0.set();
        if !state.spendable {
            return Ok(None);
        }
        state.sweeps.push((index, birthday));
        Ok(Some(transaction(&format!("sweep{}", state.sweeps.len()))))
    }

    async fn sweep_status(
        &self,
        _index: u32,
        _joint: &JointAccount,
        _birthday: u64,
        sweep: &ZcashTransaction,
    ) -> Result<SwapTxStatus> {
        Ok(self.status(sweep))
    }

    async fn forget_joint_account(&self, _index: u32) -> Result<()> {
        self.0.set().forgotten += 1;
        Ok(())
    }
}

impl ReverseZcash for FakeZcash {
    async fn chain_height(&self) -> Result<u64> {
        Ok(ZCASH_HEIGHT)
    }

    async fn import_account(
        &self,
        _index: u32,
        _joint: &JointAccount,
        _birthday: u64,
    ) -> Result<JointAccountId> {
        self.0.set().imports += 1;
        Ok(JointAccountId([0x0a; 16]))
    }

    async fn estimate_receive(
        &self,
        _index: u32,
        _joint: &JointAccount,
        _birthday: u64,
        confirmations: u32,
    ) -> Result<ReverseReceiveEstimate> {
        let state = self.0.get();
        let deep_enough = state.deposit_confirmations >= confirmations;
        Ok(ReverseReceiveEstimate {
            available_zat: if deep_enough { state.paid_in } else { 0 },
            fee_zat: state.sweep_fee,
        })
    }

    /// Refuses, as the wallet's proposal does, a sweep whose fee is above
    /// its cap.
    async fn prepare_receive(
        &self,
        _index: u32,
        _joint: &JointAccount,
        _key: &SpendKey,
        _birthday: u64,
        max_fee_zatoshi: Option<u64>,
    ) -> Result<Option<ReverseReceiveTransaction>> {
        let mut state = self.0.set();
        state.receive_caps.push(max_fee_zatoshi);
        if !state.spendable {
            return Ok(None);
        }
        let fee = state.sweep_pays;
        if max_fee_zatoshi.is_some_and(|cap| fee > cap) {
            return fail(ErrorCode::ZcashWallet, "the sweep's fee is over its limit");
        }
        let built = transaction(&format!("receive{}", state.receive_caps.len()));
        Ok(Some(ReverseReceiveTransaction {
            tx_id: built.tx_id,
            raw: built.raw,
            expiry_height: built.expiry_height,
            received_zat: state.paid_in - fee,
            fee_zat: fee,
        }))
    }

    async fn receive_status(
        &self,
        _index: u32,
        _joint: &JointAccount,
        _birthday: u64,
        receive: &ZcashTransaction,
    ) -> Result<SwapTxStatus> {
        Ok(self.status(receive))
    }

    async fn broadcast(&self, transaction: &ZcashTransaction) -> Result<()> {
        self.0.set().submitted.push(transaction.tx_id.clone());
        Ok(())
    }

    async fn forget(&self, _index: u32) -> Result<()> {
        self.0.set().forgotten += 1;
        Ok(())
    }
}

impl FakeZcash {
    fn status(&self, transaction: &ZcashTransaction) -> SwapTxStatus {
        self.0
            .get()
            .statuses
            .get(&transaction.tx_id)
            .copied()
            .unwrap_or(SwapTxStatus::Unmined)
    }
}

/// Mined `confirmations` deep.
pub(super) fn mined(confirmations: u32) -> SwapTxStatus {
    SwapTxStatus::Mined {
        height: 4_200_010,
        confirmations,
    }
}

// ---- the clock ----

pub(super) struct FakeClock(pub World);

impl Clock for FakeClock {
    fn now(&self) -> u64 {
        self.0.get().clock
    }

    async fn sleep(&self, _duration: Duration) {}
}

// ---- the harness ----

pub(super) type FakeForward<'a> = Forward<'a, FakeChain, FakeServices, FakeZcash, FakeClock>;

/// One account's forward swaps over the fakes, with a `swaps.db` of its own
/// or shared with another account of the same wallet.
pub(super) struct Harness {
    pub world: World,
    pub dir: Rc<tempfile::TempDir>,
    /// Unique per harness: driver locks and offers are process-wide.
    pub account: String,
    pub keys: SwapKeyContext,
    chain: FakeChain,
    services: FakeServices,
    zcash: FakeZcash,
    clock: FakeClock,
    makers: MakerChecks,
}

impl Harness {
    pub(super) fn new() -> Self {
        Self::with(Rc::new(tempfile::tempdir().unwrap()), &[7; 64])
    }

    /// Another account of the same wallet, with a seed of its own.
    pub(super) fn beside(other: &Harness) -> Self {
        Self::with(other.dir.clone(), &[8; 64])
    }

    /// An account on `network`'s deployment, over the same fakes.
    pub(super) fn on(network: PrivateUsdNetwork) -> Self {
        let mut harness = Self::new();
        harness.keys = SwapKeyContext::for_tests(&[7; 64], network, 0);
        harness
    }

    fn with(dir: Rc<tempfile::TempDir>, seed: &[u8]) -> Self {
        let world = World::new();
        Self {
            dir,
            account: uuid::Uuid::new_v4().to_string(),
            keys: SwapKeyContext::for_tests(seed, NETWORK, 0),
            chain: FakeChain(world.clone()),
            services: FakeServices(world.clone()),
            zcash: FakeZcash(world.clone()),
            clock: FakeClock(world.clone()),
            makers: MakerChecks::default(),
            world,
        }
    }

    pub(super) fn forward(&self) -> FakeForward<'_> {
        self.forward_with(None)
    }

    pub(super) fn forward_with<'a>(&'a self, op: Option<&'a OpHandle>) -> FakeForward<'a> {
        Forward::new(
            &self.account,
            &self.keys,
            &self.chain,
            &self.services,
            &self.zcash,
            &self.clock,
            &self.makers,
            op,
        )
    }

    pub(super) fn chain(&self) -> &FakeChain {
        &self.chain
    }

    pub(super) fn store(&self) -> SwapStore {
        SwapStore::open(self.dir.path()).unwrap()
    }

    pub(super) async fn quote(&self) -> Result<Quoted> {
        self.forward().quote(&mut self.store(), 1).await
    }

    /// A quote accepted, and the swap opened on chain.
    pub(super) async fn accepted(&self) -> ForwardRecord {
        let quoted = self.quote().await.unwrap();
        let max_total = quoted.offer.max_total_zatoshi().unwrap();
        self.forward()
            .accept(&mut self.store(), quoted.index, max_total)
            .await
            .unwrap();
        self.record()
    }

    /// Accepted, with its deposit created and sent.
    pub(super) async fn deposited(&self) -> ForwardRecord {
        self.accepted().await;
        assert_eq!(self.advance().await.unwrap(), self.confirming());
        self.record()
    }

    /// Deposited, with the deposit mined.
    pub(super) async fn mined_deposit(&self) -> ForwardRecord {
        let record = self.deposited().await;
        self.world
            .set()
            .statuses
            .insert(tx_id("deposit1"), mined(5));
        record
    }

    /// The maker refunds the swap, revealing `e`.
    pub(super) fn refund(&self) {
        let mut state = self.world.set();
        state.stage = SwapStage::Refunded;
        state.secret = maker_secret().to_be_bytes();
    }

    pub(super) async fn advance(&self) -> Result<ForwardStep> {
        self.forward().advance(&mut self.store(), 0).await
    }

    /// The record of swap 0, as `swaps.db` keeps it.
    pub(super) fn record(&self) -> ForwardRecord {
        self.record_of(0)
    }

    pub(super) fn record_of(&self, index: u32) -> ForwardRecord {
        match self
            .store()
            .find(&self.account, Direction::Forward, index)
            .unwrap()
        {
            Some(StoredRecord::Forward(record)) => *record,
            other => panic!("no forward record {index}: {other:?}"),
        }
    }

    /// Replaces the kept record, as an earlier run of the app left it.
    pub(super) fn keep(&self, record: &ForwardRecord) {
        self.store()
            .update(
                &self.account,
                &StoredRecord::Forward(Box::new(record.clone())),
            )
            .unwrap();
    }

    pub(super) fn paths(&self) -> Vec<String> {
        self.world.get().paths.clone()
    }

    pub(super) fn confirming(&self) -> ForwardStep {
        let state = self.world.get();
        ForwardStep::Waiting {
            wait: ForwardWait::Confirming,
            t0: Some(state.t0),
            t1: Some(state.t1()),
        }
    }
}

// ---- the reverse harness ----

pub(super) type FakeReverse<'a> = Reverse<'a, FakeChain, FakeServices, FakeZcash, FakeClock>;

impl Harness {
    pub(super) fn reverse(&self) -> FakeReverse<'_> {
        Reverse::new(
            &self.account,
            &self.keys,
            &self.chain,
            &self.services,
            &self.zcash,
            &self.clock,
            &self.makers,
            None,
        )
    }

    /// A reverse quote of `AMOUNT` for a fresh index, kept as a draft.
    pub(super) async fn reverse_quote(&self) -> Result<ReverseQuoted> {
        self.reverse().quote(&mut self.store(), AMOUNT as u32).await
    }

    /// The Railgun page's `reverseCost` for the escrow and the relayer's
    /// `fee`: Railgun's unshield fee on top (`fundingAmounts`).
    pub(super) fn page_cost(
        &self,
        fee: u128,
    ) -> (super::super::models::Amount, super::super::models::Amount) {
        let escrow = AMOUNT + fee;
        let debit = (escrow - 1) * 10_000 / (10_000 - UNSHIELD_BPS) + 1;
        (
            super::super::models::Amount(debit),
            super::super::models::Amount(debit - escrow),
        )
    }

    /// Quoted, priced, gone ahead with, accepted and its joint account
    /// imported: waiting for the user's payment.
    pub(super) async fn prepared(&self) -> ReverseRecord {
        let quoted = self.reverse_quote().await.unwrap();
        let (debit, railgun_fee) = self.page_cost(quoted.price.fee.0);
        let reverse = self.reverse();
        let index = quoted.record.index;
        reverse
            .view()
            .set_cost(&mut self.store(), index, debit, railgun_fee)
            .await
            .unwrap();
        reverse
            .view()
            .go_ahead(&mut self.store(), index)
            .await
            .unwrap();
        reverse.advance(&mut self.store(), index).await.unwrap()
    }

    /// The user pays: Rust's funding request, the page's proof of its
    /// calls, and the proof's submission. Once a funding is kept, the
    /// request says so and an advance follows instead.
    pub(super) async fn fund(&self) -> Result<ReverseRecord> {
        let reverse = self.reverse();
        let request = reverse
            .funding_request(&mut self.store(), 0, &self.keys.railgun_address().unwrap())
            .await?;
        if request.already_funded {
            return reverse.advance(&mut self.store(), 0).await;
        }
        let proved = self.prove(&request);
        reverse
            .view()
            .submit_funding(&mut self.store(), 0, proved)
            .await
    }

    /// The Railgun page's `prepareReverse`: a proof of the calls through the
    /// Relay Adapt, costed as `reverseCost` costs them.
    pub(super) fn prove(&self, request: &reverse::FundingRequest) -> ProvedFunding {
        self.world.set().proofs += 1;
        let (debit, railgun_fee) = self.page_cost(request.fee.0);
        let calls: Vec<u8> = request
            .calls
            .iter()
            .flat_map(|call| call.data.iter().copied())
            .collect();
        ProvedFunding {
            to: hex0x(&request.relay_adapt),
            data: hex0x(&calls),
            value: "0".into(),
            debit,
            railgun_fee,
        }
    }

    /// The funding landed: the escrow of swap 0 opens on chain as
    /// `openReverse` stores it, some blocks deep.
    pub(super) fn funded(&self) {
        let record = self.reverse_record(0);
        let terms = reverse::reverse_terms(&record).unwrap();
        let mut state = self.world.set();
        state.escrow_terms = Some(terms);
        state.escrow_id = Some(record.swap_id.0);
        state.escrow_note = record.quote.refund_note.0;
        state.funding_block = state.head_number - 5;
        state.stage = SwapStage::Open;
    }

    /// The maker claims the escrow, revealing `e`.
    pub(super) fn claimed(&self) {
        let mut state = self.world.set();
        state.stage = SwapStage::Claimed;
        state.secret = maker_secret().to_be_bytes();
    }

    pub(super) async fn advance_reverse(&self) -> Result<ReverseRecord> {
        self.reverse().advance(&mut self.store(), 0).await
    }

    /// The reverse record of swap `index`, as `swaps.db` keeps it.
    pub(super) fn reverse_record(&self, index: u32) -> ReverseRecord {
        match self
            .store()
            .find(&self.account, Direction::Reverse, index)
            .unwrap()
        {
            Some(StoredRecord::Reverse(record)) => *record,
            other => panic!("no reverse record {index}: {other:?}"),
        }
    }

    /// How many requests went to `path`.
    pub(super) fn posts(&self, path: &str) -> usize {
        self.paths().iter().filter(|posted| *posted == path).count()
    }
}
