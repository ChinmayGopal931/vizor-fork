//! A forward conversion, ZEC → private USD (reference §5.6), and its refund
//! (§5.8); a port of zapp's `of/AtomicSwapDriver.kt`, `AtomicSwapDeposits.kt`
//! and `ZcashTransactions.kt`.
//!
//! Every step reads the chain first, so any of them can run again after an
//! interruption. Only a confirmed read authorizes a deposit, a reveal or the
//! end (§3.5 item 6). The record is saved before the user's share leaves the
//! device, a deposit is marked started before it is created and kept before
//! it is first sent, and a payout is kept before it is posted (items 2, 3,
//! 8). `z` is revealed only under a claim lock with more than
//! `REVEAL_MARGIN_SECONDS` left, re-read from a fresh head immediately
//! before sending (item 5).
//!
//! The driver runs over seams: [`ChainReader`], [`HttpTransport`],
//! [`ForwardZcash`] (the wallet's side, [`WalletZcash`] over the M2
//! operations), [`Clock`] and [`TokenSource`]. Engine tests fake them all.

use std::path::Path;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use zcash_primitives::transaction::TxId;
use zcash_protocol::consensus::Parameters;
use zecswap_core::{JointAccount, NetworkType, SecretShare, SpendKey, SwapContext, Terms};
use zeroize::Zeroizing;

use super::deployment::{
    Deployment, MAX_RELAYER_FEE, MAX_SECONDS_TO_T0, RAILGUN_FEE_BPS, REVEAL_MARGIN_SECONDS,
    SIGNATURE_TTL_SECONDS,
};
use super::engine::{
    self, Activity, Clock, MakerChecks, NoTokens, Offer, OpHandle, SystemClock, TokenSource,
};
use super::evm_rpc::{ChainReader, EvmRpc, SwapStage, SwapState};
use super::joint::{self, SwapTxStatus};
use super::keys::SwapKeyContext;
use super::maker_client::MakerClient;
use super::models::{
    Amount, DepositState, Direction, ForwardOutcome, ForwardRecord, Hex, NothingSentCause,
    RefundCause, StoredRecord, SwapAcceptance, SwapAuthorization, SwapNote, SwapPayout, SwapQuote,
    SwapZcashNetwork, ZcashTransaction, ZcashTxId,
};
use super::relayer_client::RelayerClient;
use super::store::{JointAccountRow, SwapStore};
use super::transport::{HttpTransport, Refusal, RoutedTransport, SwapErrorCode, SwapHttpError};
use super::{fail, indices, terms, ErrorCode, PrivateUsdError, Result, OPERATIONS};
use crate::wallet::network::WalletNetwork;
use crate::wallet::sync::{self, CreatedTransaction};
use crate::wallet::{keys, sync_engine};

/// The joint accounts of one wallet's conversions, beside `swaps.db`.
pub(crate) const JOINT_DB_FILE: &str = "joint.db";
/// The maker API version this build speaks.
const MAKER_API_VERSION: u32 = 1;
/// A maker's open can queue behind others; past this after the quote's
/// expiry it is not coming, or too late to deposit into.
const OPEN_GRACE_SECONDS: u64 = 5 * 60;
/// `caught_up` polls a confirmed read this often, this many times.
const CATCH_UP_POLLS: u32 = 30;
const CATCH_UP_INTERVAL: Duration = Duration::from_secs(2);
/// Lock reasoning is refused on a head this much older than the device's
/// clock (`freshHead`): a lapsed lock would look held.
const MAX_HEAD_LAG_SECONDS: u64 = 3 * 60;
/// A refund sweep pays at most this fee (zapp `MAX_SWEEP_FEE_ZAT`).
const MAX_SWEEP_FEE_ZAT: u64 = 320_000;
/// ZIP 317's least fee: a sweep that cannot pay it is not authorized.
const MIN_SWEEP_FEE_ZAT: u64 = 10_000;
const BPS_MAX: u128 = 10_000;

/// Why a forward swap waits, with nothing for the user to do (zapp
/// `AtomicSwapWait`, plus `ZcashSyncing`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ForwardWait {
    /// The maker has not opened the swap on chain, or not deep enough yet.
    Opening,
    /// The deposit is out; the maker has not marked the swap ready.
    Confirming,
    /// The maker called the swap off while the deposit was unmined: it comes
    /// home if it is mined.
    DepositUnsettled,
    /// The refunded deposit is on its way home.
    Refunding,
    /// The main wallet has not scanned to the chain's tip: no deposit is
    /// built on a stale wallet.
    ZcashSyncing,
}

/// One look at a forward swap.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ForwardStep {
    Waiting {
        wait: ForwardWait,
        t0: Option<u64>,
        t1: Option<u64>,
    },
    Finished(ForwardOutcome),
}

fn waiting(wait: ForwardWait) -> ForwardStep {
    ForwardStep::Waiting {
        wait,
        t0: None,
        t1: None,
    }
}

/// How long the engine loop naps after a wait (zapp
/// `AtomicSwapRepository.pollInterval`).
pub(crate) fn nap(wait: ForwardWait) -> Duration {
    match wait {
        ForwardWait::Opening => Duration::from_secs(5),
        ForwardWait::Confirming => Duration::from_secs(20),
        ForwardWait::DepositUnsettled | ForwardWait::Refunding => Duration::from_secs(30),
        ForwardWait::ZcashSyncing => engine::RETRY_DELAY,
    }
}

/// How an accept went.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AcceptOutcome {
    /// The maker opened the swap, or is opening it: the engine follows it.
    Accepted,
    /// The maker wants a Privacy Pass token, and none is held. Nothing
    /// opened; the record waits, unanswered, for a paid accept (M4) or to be
    /// abandoned.
    TokensNeeded,
    /// Over before anything was sent.
    NothingSent(NothingSentCause),
}

/// A quote for a fresh index, held in memory until accepted or expired.
#[derive(Clone, Debug)]
pub(crate) struct Quoted {
    pub index: u32,
    pub offer: Offer,
}

/// A step's result as the engine loop takes it: a failure is a problem to
/// show after a minute, not an error (reference §5.8).
#[derive(Clone, Debug)]
pub(crate) struct AdvanceReport {
    pub record: ForwardRecord,
    pub wait: Option<ForwardWait>,
    pub next_poll: Duration,
    pub problem: Option<ErrorCode>,
}

/// The wallet's Zcash side of a forward swap (zapp `AtomicSwapZcash`).
pub(crate) trait ForwardZcash {
    /// A stored deposit proposal: consumed by `create_deposit`, else released
    /// by `discard_deposit`.
    type Proposal;

    /// The chain's height now: a new swap's joint account is born there.
    async fn chain_height(&self) -> Result<u64>;
    /// Whether the main wallet has scanned to the chain's live tip.
    async fn synced(&self) -> Result<bool>;
    /// The deposit's network fee from the wallet now, or `None` unless one
    /// transaction can pay it. Nothing is locked.
    async fn deposit_fee(&self, address: &str, zatoshi: u64) -> Option<u64>;
    /// Proposes paying `zatoshi` to `address` in one transaction costing at
    /// most `max_total` in all, and locks its inputs.
    async fn propose_deposit(
        &self,
        index: u32,
        address: &str,
        zatoshi: u64,
        max_total: u64,
    ) -> Result<Self::Proposal>;
    /// Signs and stores the proposed deposit without sending it.
    async fn create_deposit(&self, proposal: Self::Proposal) -> Result<ZcashTransaction>;
    fn discard_deposit(&self, proposal: Self::Proposal);
    /// A deposit to `address` the wallet created that may still land.
    async fn find_deposit(&self, address: &str) -> Result<Option<ZcashTransaction>>;
    async fn deposit_status(&self, deposit: &ZcashTransaction) -> Result<SwapTxStatus>;
    /// Sends a kept transaction once more.
    async fn broadcast(&self, transaction: &ZcashTransaction) -> Result<()>;
    /// The refunded deposit's sweep home with the combined `key`: an earlier
    /// one that may still land, else a new one once every note is spendable;
    /// `None` until then.
    async fn prepare_sweep(
        &self,
        index: u32,
        joint: &JointAccount,
        key: &SpendKey,
        birthday: u64,
    ) -> Result<Option<ZcashTransaction>>;
    async fn sweep_status(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
        sweep: &ZcashTransaction,
    ) -> Result<SwapTxStatus>;
    /// Forgets swap `index`'s joint account once its sweep is final.
    async fn forget_joint_account(&self, index: u32) -> Result<()>;
}

/// A stored deposit proposal, released unless it was created
/// (`PROPOSAL_STORE` is consume-on-entry; §3.5 item 10).
struct ProposedDeposit<'z, Z: ForwardZcash> {
    zcash: &'z Z,
    proposal: Option<Z::Proposal>,
}

impl<Z: ForwardZcash> ProposedDeposit<'_, Z> {
    fn take(mut self) -> Z::Proposal {
        self.proposal.take().expect("a proposal is taken once")
    }
}

impl<Z: ForwardZcash> Drop for ProposedDeposit<'_, Z> {
    fn drop(&mut self) {
        if let Some(proposal) = self.proposal.take() {
            self.zcash.discard_deposit(proposal);
        }
    }
}

enum Deposit {
    /// A deposit is out, or kept to be sent again.
    Kept,
    /// None is out, and none may be paid.
    Unpayable(NothingSentCause),
    /// None is out, and the wallet must scan to the tip first.
    Syncing,
}

#[derive(Clone, Copy)]
enum PayoutPost {
    /// `/v1/claim`: reveals `z` under the claim lock, then pays out.
    Claim,
    /// `/v1/payout`, after a claim that revealed but did not pay out.
    Payout,
}

/// A payout post that failed: turned down (nothing was sent), or otherwise.
enum Posted {
    Refused(Refusal),
    Failed(PrivateUsdError),
}

impl From<Posted> for PrivateUsdError {
    fn from(posted: Posted) -> Self {
        match posted {
            Posted::Refused(refusal) => SwapHttpError::Refused(refusal).into(),
            Posted::Failed(error) => error,
        }
    }
}

/// The relayer's terms, once they are the pinned relayer's.
struct RelayerFee {
    fee: Amount,
    expires_at: Option<u64>,
}

/// One account's forward swaps, over the seams.
pub(crate) struct Forward<'a, C, T, Z, K, S>
where
    T: HttpTransport,
{
    pins: &'static Deployment,
    account: &'a str,
    keys: &'a SwapKeyContext,
    chain: &'a C,
    maker: MakerClient<'a, T>,
    relayer: RelayerClient<'a, T>,
    zcash: &'a Z,
    clock: &'a K,
    tokens: &'a S,
    makers: &'a MakerChecks,
    op: Option<&'a OpHandle>,
}

impl<'a, C, T, Z, K, S> Forward<'a, C, T, Z, K, S>
where
    C: ChainReader,
    T: HttpTransport,
    Z: ForwardZcash,
    K: Clock,
    S: TokenSource,
{
    pub(crate) fn new(
        account: &'a str,
        keys: &'a SwapKeyContext,
        chain: &'a C,
        transport: &'a T,
        zcash: &'a Z,
        clock: &'a K,
        tokens: &'a S,
        makers: &'a MakerChecks,
        op: Option<&'a OpHandle>,
    ) -> Self {
        let pins = super::deployment::deployment(keys.network());
        Self {
            pins,
            account,
            keys,
            chain,
            maker: MakerClient::new(transport, pins.maker_url),
            relayer: RelayerClient::new(transport, pins.relayer_url),
            zcash,
            clock,
            tokens,
            makers,
            op,
        }
    }

    // ---- quote and accept ----

    /// Quotes `units` of the token for a fresh index, which counts as spent
    /// from here on (§3.5 item 1). The offer stays in memory until accepted
    /// or expired; it is never persisted.
    pub(crate) async fn quote(&self, store: &mut SwapStore, units: u32) -> Result<Quoted> {
        let session = engine::session();
        self.require_none_under_way(store)?;
        self.check_maker().await?;
        let index = indices::take_index(
            store,
            &[(self.chain, self.pins.maker)],
            self.keys,
            self.account,
        )
        .await?;
        let note = self.keys.note(index)?;
        let quote = self
            .maker
            .quote(units, self.keys.auth_address(index)?, note.commitment())
            .await
            .map_err(quote_error)?;
        if !serves(self.pins, &quote) {
            return fail(
                ErrorCode::WrongDeployment,
                "the quote is for another deployment",
            );
        }
        let relayer = self.relayer_fee().await?;
        // D11: a fee above the cap is refused before anything is accepted.
        if relayer.fee.0 > MAX_RELAYER_FEE {
            return fail(
                ErrorCode::RelayerFee,
                "the relayer's fee is above the 2 USDC cap",
            );
        }
        let receives = payout_after_fees(quote.amount, relayer.fee);
        // The preview pays the quote's share; the deposit itself goes to the
        // joint address of the confirmed on-chain terms.
        let address = self
            .keys
            .joint(index, &terms::quote_maker_share(&quote)?)?
            .unified_address(self.zcash_network());
        let deposit_fee_zat = self.zcash.deposit_fee(&address, quote.deposit_zat).await;
        let offer = Offer {
            network: self.keys.network(),
            quote,
            relayer_fee: relayer.fee,
            fee_expires_at: relayer.expires_at,
            receives,
            deposit_fee_zat,
        };
        engine::put_offer(
            self.account,
            index,
            offer.clone(),
            self.clock.now(),
            session,
        );
        Ok(Quoted { index, offer })
    }

    /// Accepts the offer held for `index`, saving the record before the
    /// maker sees our share, so an accept cut short is still known (§3.5
    /// item 2). Again for an index already saved, unfinished and unanswered,
    /// it posts the saved quote once more and never takes another index.
    pub(crate) async fn accept(
        &self,
        store: &mut SwapStore,
        index: u32,
        max_total_zat: u64,
    ) -> Result<AcceptOutcome> {
        if let Some(record) = find(store, self.account, index)? {
            return self.accept_again(store, record).await;
        }
        self.require_none_under_way(store)?;
        let now = self.clock.now();
        let offer =
            engine::offer(self.account, index, self.keys.network(), now).ok_or_else(|| {
                PrivateUsdError::new(
                    ErrorCode::QuoteExpired,
                    "the quote is no longer held: quote again",
                )
            })?;
        let quote = offer.quote;
        require_payout_fee(quote.amount, offer.relayer_fee)?;
        if offer.deposit_fee_zat.is_none() {
            return fail(
                ErrorCode::DepositUnpayable,
                "the deposit does not fit one transaction from this wallet",
            );
        }
        if max_total_zat < quote.deposit_zat {
            return fail(
                ErrorCode::DepositUnpayable,
                "the approved total does not cover the deposit",
            );
        }
        require_time_to_accept(&quote, now)?;
        let acceptance = self.acceptance(index, &quote)?;
        let swap_id = terms::swap_id(&self.pins.maker, &self.keys.user_share(index)?);
        let record = ForwardRecord {
            index,
            quote,
            swap_id: Hex(swap_id),
            zcash_height: self.zcash.chain_height().await?,
            accepted_at: self.clock.now(),
            receives: offer.receives,
            relayer_fee: offer.relayer_fee,
            deposit_attempted: false,
            outcome: None,
            finished_at: None,
            payout_tx: None,
            max_total_zat: Some(max_total_zat),
            deposit: None,
            sweep: None,
            payout: None,
            t0: None,
            t1: None,
            fee_expires_at: offer.fee_expires_at,
            ticket: None,
        };
        write(store, self.account, &record, true)?;
        engine::remove_offer(self.account, index);
        self.post_accept(store, record, &acceptance).await
    }

    async fn accept_again(
        &self,
        store: &mut SwapStore,
        record: ForwardRecord,
    ) -> Result<AcceptOutcome> {
        match &record.outcome {
            Some(ForwardOutcome::NothingSent { cause }) => {
                return Ok(AcceptOutcome::NothingSent(*cause))
            }
            Some(_) => return Ok(AcceptOutcome::Accepted),
            None => {}
        }
        // Answered: under way; the engine follows it.
        if record.t0.is_some() {
            return Ok(AcceptOutcome::Accepted);
        }
        // Too late to post again; the engine gives an unanswered accept up
        // once its quote is long expired.
        require_time_to_accept(&record.quote, self.clock.now())?;
        let acceptance = self.acceptance(record.index, &record.quote)?;
        self.post_accept(store, record, &acceptance).await
    }

    async fn post_accept(
        &self,
        store: &mut SwapStore,
        record: ForwardRecord,
        acceptance: &SwapAcceptance,
    ) -> Result<AcceptOutcome> {
        let authorization = self.tokens.accept_authorization();
        let accepted = match self
            .maker
            .accept(&record.quote.quote_id, acceptance, authorization.as_deref())
            .await
        {
            Ok(accepted) => accepted,
            // Turned away at the token gate. A refusal sends nothing, so
            // nothing opened; without a held token there is no paid retry.
            Err(SwapHttpError::Refused(refusal))
                if refusal.code == Some(SwapErrorCode::TokenRequired) =>
            {
                self.tokens.token_required(refusal.challenge.as_deref());
                return Ok(AcceptOutcome::TokensNeeded);
            }
            Err(SwapHttpError::Refused(refusal)) => match accept_refusal(&refusal) {
                Some(cause) => {
                    self.finish(
                        store,
                        &record,
                        ForwardOutcome::NothingSent { cause },
                        None,
                        None,
                    )?;
                    return Ok(AcceptOutcome::NothingSent(cause));
                }
                // A refusal that may follow an open: the record stays, maybe
                // opened.
                None => return Err(SwapHttpError::Refused(refusal).into()),
            },
            // No answer, or one that does not read: maybe opened.
            Err(error) => return Err(error.into()),
        };
        let mut opened = record;
        opened.t0 = Some(accepted.t0);
        opened.t1 = Some(accepted.t1);
        opened.ticket = accepted.ticket_for(&opened.swap_id);
        write(store, self.account, &opened, false)?;
        if accepted.swap_id != opened.swap_id {
            self.finish(
                store,
                &opened,
                ForwardOutcome::NothingSent {
                    cause: NothingSentCause::Mismatch,
                },
                None,
                None,
            )?;
            return Ok(AcceptOutcome::NothingSent(NothingSentCause::Mismatch));
        }
        Ok(AcceptOutcome::Accepted)
    }

    fn acceptance(&self, index: u32, quote: &SwapQuote) -> Result<SwapAcceptance> {
        let (Some(quote_id), Some(proof)) = (quote.quote_id_bytes(), quote.maker_proof_bytes())
        else {
            return fail(ErrorCode::Mismatch, "the quote's id or proof is malformed");
        };
        let context = SwapContext {
            chain_id: quote.chain_id,
            contract: self.pins.contract,
            quote_id,
        };
        self.keys
            .acceptance(index, context, &terms::quote_maker_share(quote)?, &proof)
    }

    // ---- advance ----

    /// One look at the chain for swap `index`, then at most one key-using
    /// step (deposit, claim, payout or sweep). The engine loop's view: a
    /// failed step is a problem, and a cancelled one an error.
    pub(crate) async fn advance_report(
        &self,
        store: &mut SwapStore,
        index: u32,
    ) -> Result<AdvanceReport> {
        load(store, self.account, index)?;
        let step = self.advance(store, index).await;
        if self.op.is_some_and(OpHandle::cancelled) {
            return Err(engine::cancelled());
        }
        let record = load(store, self.account, index)?;
        Ok(match step {
            Ok(ForwardStep::Finished(_)) => AdvanceReport {
                record,
                wait: None,
                next_poll: Duration::ZERO,
                problem: None,
            },
            Ok(ForwardStep::Waiting { wait, .. }) => AdvanceReport {
                record,
                wait: Some(wait),
                next_poll: nap(wait),
                problem: None,
            },
            Err(error) if error.code == ErrorCode::Cancelled => return Err(error),
            Err(error) => {
                log::warn!(
                    "private_usd: forward swap {index}: a step failed ({:?})",
                    error.code
                );
                AdvanceReport {
                    record,
                    wait: None,
                    next_poll: engine::RETRY_DELAY,
                    problem: Some(engine::problem(error.code)),
                }
            }
        })
    }

    /// One look at the chain for swap `index`: deposits, claims or refunds
    /// when due (zapp `AtomicSwapDriver.advance`).
    pub(crate) async fn advance(&self, store: &mut SwapStore, index: u32) -> Result<ForwardStep> {
        let record = load(store, self.account, index)?;
        if let Some(outcome) = &record.outcome {
            return Ok(ForwardStep::Finished(outcome.clone()));
        }
        self.check_cancelled()?;
        match self.terms(&record)? {
            None => self.not_on_chain(store, &record, false).await,
            Some(terms) => self.step(store, &record, &terms).await,
        }
    }

    async fn step(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
    ) -> Result<ForwardStep> {
        let confirmed = match self.chain.confirmed_swap(&record.swap_id.0, terms).await {
            Ok(confirmed) => confirmed,
            // A swap under this id with other terms, such as one an earlier
            // use of its index left, gets nothing.
            Err(error)
                if error.code == ErrorCode::Mismatch
                    && record.deposit_state() == DepositState::NotStarted =>
            {
                return self.finish(
                    store,
                    record,
                    ForwardOutcome::NothingSent {
                        cause: NothingSentCause::Mismatch,
                    },
                    None,
                    None,
                );
            }
            Err(error) => return Err(error),
        };
        match confirmed.swap {
            None => self.not_on_chain(store, record, true).await,
            Some(swap) => self.on_chain(store, record, terms, &swap).await,
        }
    }

    /// Not at its confirmation depth yet; or, without the maker's answer and
    /// the deadlines it carries, never to be checked nor paid into.
    async fn not_on_chain(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        answered: bool,
    ) -> Result<ForwardStep> {
        let gave_up = self.clock.now() > record.quote.expires_at + OPEN_GRACE_SECONDS;
        let cause = if !gave_up || record.deposit_state() != DepositState::NotStarted {
            None
        } else if self.chain.swap(&record.swap_id.0).await?.is_none() {
            Some(NothingSentCause::NeverOpened)
        } else if answered {
            None
        } else {
            Some(NothingSentCause::MakerUnavailable)
        };
        match cause {
            Some(cause) => self.finish(
                store,
                record,
                ForwardOutcome::NothingSent { cause },
                None,
                None,
            ),
            None => Ok(waiting(ForwardWait::Opening)),
        }
    }

    async fn on_chain(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        swap: &SwapState,
    ) -> Result<ForwardStep> {
        match swap.stage {
            SwapStage::Refunded => self.refunded(store, record, terms, swap).await,
            SwapStage::Claimed => {
                if !swap.paid_out {
                    self.set_activity(Activity::PayingOut);
                    self.pay_out(store, record, terms).await?;
                }
                self.finish_paid(store, record).await
            }
            SwapStage::Ready => {
                self.set_activity(Activity::Claiming);
                self.claim(store, record, terms, swap).await?;
                self.finish_paid(store, record).await
            }
            SwapStage::Open => self.open(store, record, terms, swap).await,
        }
    }

    async fn open(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        swap: &SwapState,
    ) -> Result<ForwardStep> {
        match self.ensure_paid(store, record, terms, swap).await? {
            Deposit::Unpayable(cause) => self.finish(
                store,
                record,
                ForwardOutcome::NothingSent { cause },
                None,
                None,
            ),
            Deposit::Syncing => Ok(waiting(ForwardWait::ZcashSyncing)),
            // Past t0 the claim needs no `ready`: a maker gone quiet holds
            // the deposit no longer.
            Deposit::Kept if self.chain.head().await?.timestamp >= terms.t0 => {
                self.set_activity(Activity::Claiming);
                self.claim(store, record, terms, swap).await?;
                self.finish_paid(store, record).await
            }
            Deposit::Kept => Ok(ForwardStep::Waiting {
                wait: ForwardWait::Confirming,
                t0: Some(terms.t0),
                t1: Some(terms.t1),
            }),
        }
    }

    // ---- the deposit ----

    /// Sends the deposit again until it is mined; pays anew only once the
    /// last is proven expired, in time for t0 and with no refund lock (§3.5
    /// item 3; zapp `ensurePaid` and `keepSending`).
    async fn ensure_paid(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        swap: &SwapState,
    ) -> Result<Deposit> {
        // From the maker share the contract confirmed, never the API's alone.
        let address = self
            .keys
            .joint(record.index, &terms.maker_share)?
            .unified_address(self.zcash_network());
        let chain_now = self.chain.head().await?.timestamp;
        let unpayable = unpayable(self.pins, terms, swap, chain_now);
        let mut current = self.with_found(store, record, &address).await?;

        let mut kept = None;
        if let Some(deposit) = current.deposit.clone() {
            let status = self.zcash.deposit_status(&deposit).await?;
            if status == SwapTxStatus::Expired {
                // Proven never to be mined: it may be paid anew.
                current.deposit = None;
                current.deposit_attempted = true;
                write(store, self.account, &current, false)?;
            } else {
                kept = Some((deposit, status));
            }
        }
        let (deposit, status) = match kept {
            Some(kept) => kept,
            None => {
                if let Some(cause) = unpayable {
                    return Ok(Deposit::Unpayable(cause));
                }
                if !self.zcash.synced().await? {
                    return Ok(Deposit::Syncing);
                }
                self.check_cancelled()?;
                let max_total = current.max_total_zat.ok_or_else(|| {
                    PrivateUsdError::new(
                        ErrorCode::DepositUnpayable,
                        "the conversion has no approved deposit total",
                    )
                })?;
                let proposal = ProposedDeposit {
                    zcash: self.zcash,
                    proposal: Some(
                        self.zcash
                            .propose_deposit(
                                current.index,
                                &address,
                                current.quote.deposit_zat,
                                max_total,
                            )
                            .await?,
                    ),
                };
                // Proposing can wait seconds on the wallet write lock; a lock or
                // background that arrived meanwhile stops here, before any key is
                // used. The guard releases the proposal.
                self.check_cancelled()?;
                self.set_activity(Activity::Depositing);
                // Started before it exists: an interruption from here on finds
                // it in the wallet rather than paying again.
                current.deposit_attempted = true;
                write(store, self.account, &current, false)?;
                let created = self.zcash.create_deposit(proposal.take()).await?;
                // Kept before it is first sent.
                current.deposit = Some(created.clone());
                write(store, self.account, &current, false)?;
                let status = self.zcash.deposit_status(&created).await?;
                (created, status)
            }
        };
        // A deposit the maker is calling off is left to be mined or expire,
        // not pushed.
        if !matches!(status, SwapTxStatus::Mined { .. }) && swap.refund_lock_until == 0 {
            self.zcash.broadcast(&deposit).await?;
        }
        Ok(Deposit::Kept)
    }

    /// `record` with the deposit an interruption cut short, found again in
    /// the wallet: a started deposit is never built before it is looked for.
    async fn with_found(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        address: &str,
    ) -> Result<ForwardRecord> {
        let mut current = record.clone();
        if current.deposit.is_some() || !current.deposit_attempted {
            return Ok(current);
        }
        if let Some(found) = self.zcash.find_deposit(address).await? {
            current.deposit = Some(found);
            write(store, self.account, &current, false)?;
        }
        Ok(current)
    }

    // ---- the forward refund (§5.8) ----

    /// A refunded swap: a mined deposit is swept home, and one that may still
    /// be mined is waited for.
    async fn refunded(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        swap: &SwapState,
    ) -> Result<ForwardStep> {
        let joint = self.keys.joint(record.index, &terms.maker_share)?;
        let address = joint.unified_address(self.zcash_network());
        let current = self.with_found(store, record, &address).await?;
        let status = match &current.deposit {
            Some(deposit) => Some(self.zcash.deposit_status(deposit).await?),
            None => None,
        };
        match status {
            Some(SwapTxStatus::Mined { .. }) => {
                self.sweep(store, &current, terms, swap, &joint).await
            }
            Some(SwapTxStatus::Unmined | SwapTxStatus::Unknown) => {
                Ok(waiting(ForwardWait::DepositUnsettled))
            }
            Some(SwapTxStatus::Expired) | None => self.finish(
                store,
                &current,
                ForwardOutcome::NothingSent {
                    cause: NothingSentCause::MakerCancelled,
                },
                None,
                None,
            ),
        }
    }

    /// Sweeps the refunded deposit home with `±(e+z)`, kept before it is
    /// first sent; the swap ends, and its joint account goes, only once the
    /// sweep has the confirmations a deposit gets.
    async fn sweep(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        swap: &SwapState,
        joint: &JointAccount,
    ) -> Result<ForwardStep> {
        let maker_secret = SecretShare::from_be_bytes(&swap.secret).map_err(|_| {
            PrivateUsdError::new(ErrorCode::Mismatch, "the refund revealed no valid share")
        })?;
        let user = self.keys.user_keys(record.index)?;
        let key = joint.spend_key(&maker_secret, &user.share).map_err(|_| {
            PrivateUsdError::new(
                ErrorCode::Mismatch,
                "the revealed share does not open the joint account",
            )
        })?;
        drop(user);
        let birthday = record.zcash_height;
        let mut current = record.clone();

        let mut kept = None;
        if let Some(sweep) = current.sweep.clone() {
            let status = self
                .zcash
                .sweep_status(record.index, joint, birthday, &sweep)
                .await?;
            if status == SwapTxStatus::Expired {
                current.sweep = None;
                write(store, self.account, &current, false)?;
            } else {
                kept = Some((sweep, status));
            }
        }
        let (sweep, status) = match kept {
            Some(kept) => kept,
            None => {
                self.check_cancelled()?;
                self.set_activity(Activity::Sweeping);
                let Some(built) = self
                    .zcash
                    .prepare_sweep(record.index, joint, &key, birthday)
                    .await?
                else {
                    return Ok(waiting(ForwardWait::Refunding));
                };
                current.sweep = Some(built.clone());
                write(store, self.account, &current, false)?;
                let status = self
                    .zcash
                    .sweep_status(record.index, joint, birthday, &built)
                    .await?;
                (built, status)
            }
        };
        let confirmations = match status {
            SwapTxStatus::Mined { confirmations, .. } => confirmations,
            _ => {
                self.zcash.broadcast(&sweep).await?;
                0
            }
        };
        if confirmations < self.pins.zcash_confirmations {
            return Ok(waiting(ForwardWait::Refunding));
        }
        let cause = self.refund_cause(terms, swap).await?;
        let step = self.finish(
            store,
            &current,
            ForwardOutcome::Refunded {
                sweep_tx_id: sweep.tx_id.clone(),
                cause,
            },
            None,
            None,
        )?;
        if let Err(error) = self.zcash.forget_joint_account(record.index).await {
            // The swap is over; account deletion and reset remove what is
            // left of its joint account.
            log::warn!(
                "private_usd: forgetting a swept joint account failed ({:?})",
                error.code
            );
        }
        Ok(step)
    }

    /// A refund lock taken before t0 is the maker calling it off; one taken
    /// later waited out the user.
    async fn refund_cause(&self, terms: &Terms, swap: &SwapState) -> Result<RefundCause> {
        let lock_duration = self.chain.lock_duration().await?;
        Ok(
            if swap.refund_lock_until.saturating_sub(lock_duration) < terms.t0 {
                RefundCause::MakerCancelled
            } else {
                RefundCause::NotClaimedInTime
            },
        )
    }

    // ---- the claim (zapp `AtomicSwapClaim`) ----

    /// Reveals `z` under a held claim lock once Railgun would take the
    /// payout, then pays out.
    async fn claim(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        swap: &SwapState,
    ) -> Result<()> {
        let payout = self.payout(store, record, terms, None).await?;
        self.require_railgun_open().await?;
        self.check_cancelled()?;
        self.hold_claim_lock(record, terms, swap).await?;
        self.send_payout(store, record, terms, payout, PayoutPost::Claim)
            .await?;
        let claimed = self
            .caught_up(record, terms, |swap| swap.stage == SwapStage::Claimed)
            .await?;
        if !claimed.paid_out {
            self.pay_out(store, record, terms).await?;
        }
        Ok(())
    }

    /// Pays out a claim that revealed without paying out.
    async fn pay_out(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
    ) -> Result<()> {
        let payout = self.payout(store, record, terms, None).await?;
        self.require_railgun_open().await?;
        self.send_payout(store, record, terms, payout, PayoutPost::Payout)
            .await?;
        self.caught_up(record, terms, |swap| {
            swap.stage == SwapStage::Claimed && swap.paid_out
        })
        .await?;
        Ok(())
    }

    /// The payout to send: the saved one while its fee is the fee to pay,
    /// else one signed now and kept before it is posted. The fee is the
    /// offer's within its window, else the relayer's now, or `repriced`; it
    /// must leave something of the amount and be within the 2 USDC cap.
    async fn payout(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        repriced: Option<Amount>,
    ) -> Result<SwapPayout> {
        let mut current = load(store, self.account, record.index)?;
        if current.finished() {
            return fail(ErrorCode::Other, "the conversion has ended");
        }
        let note = SwapNote::from(&self.keys.note(current.index)?);
        if let Some(saved) = &current.payout {
            if saved.swap_id != current.swap_id || saved.note != note {
                return fail(ErrorCode::Mismatch, "the saved payout is for another swap");
            }
        }
        let asked = self.relayer_fee().await?.fee;
        let fee = match (repriced, current.fee_expires_at) {
            (Some(fee), _) => fee,
            (None, Some(expires_at)) if self.clock.now() < expires_at => current.relayer_fee,
            (None, _) => asked,
        };
        require_payout_fee(Amount(terms.amount), fee)?;
        if let Some(saved) = &current.payout {
            if saved.fee == fee {
                return Ok(saved.clone());
            }
        }
        let digest = self
            .pins
            .domain()
            .payout(&current.swap_id.0, &self.pins.relayer, fee.0);
        let signature = self.keys.user_keys(current.index)?.auth.sign(&digest);
        let payout = SwapPayout {
            swap_id: current.swap_id,
            note,
            fee,
            signature: Hex(signature),
        };
        current.payout = Some(payout.clone());
        write(store, self.account, &current, false)?;
        Ok(payout)
    }

    /// Posts `payout`. A refusal sends nothing: one turning the fee down is
    /// signed again only at a higher fee the relayer asks now, and posted
    /// once more.
    async fn send_payout(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        payout: SwapPayout,
        post: PayoutPost,
    ) -> Result<()> {
        let refusal = match self.post_payout(record, terms, &payout, post).await {
            Ok(()) => return Ok(()),
            Err(Posted::Refused(refusal)) if refusal.code == Some(SwapErrorCode::Rejected) => {
                refusal
            }
            Err(failed) => return Err(failed.into()),
        };
        let fee = self.relayer_fee().await?.fee;
        if fee <= payout.fee {
            return Err(SwapHttpError::Refused(refusal).into());
        }
        let repriced = self.payout(store, record, terms, Some(fee)).await?;
        self.post_payout(record, terms, &repriced, post)
            .await
            .map_err(PrivateUsdError::from)
    }

    async fn post_payout(
        &self,
        record: &ForwardRecord,
        terms: &Terms,
        payout: &SwapPayout,
        post: PayoutPost,
    ) -> std::result::Result<(), Posted> {
        let ticket = record.ticket.as_ref();
        let sent = match post {
            PayoutPost::Claim => {
                let secret = Zeroizing::new(
                    self.keys
                        .user_keys(record.index)
                        .map_err(Posted::Failed)?
                        .share
                        .to_be_bytes(),
                );
                // Read the lock and the clock again after every preparatory
                // step, immediately before the reveal.
                self.require_fresh_claim_lock(record, terms)
                    .await
                    .map_err(Posted::Failed)?;
                self.relayer.claim(&secret, payout, terms, ticket).await
            }
            PayoutPost::Payout => self.relayer.payout(payout, terms, ticket).await,
        };
        match sent {
            Ok(_) => Ok(()),
            Err(SwapHttpError::Refused(refusal)) => Err(Posted::Refused(refusal)),
            Err(error) => Err(Posted::Failed(error.into())),
        }
    }

    async fn require_railgun_open(&self) -> Result<()> {
        if !self.chain.railgun_accepts().await? {
            return fail(
                ErrorCode::RailgunClosed,
                "Railgun is not taking the payout now",
            );
        }
        Ok(())
    }

    /// A reveal must land before the lock lapses, or the maker's next turn
    /// knows both halves; and no lock is asked for that the contract will
    /// not give, such as in the maker's turn after ours lapsed.
    async fn hold_claim_lock(
        &self,
        record: &ForwardRecord,
        terms: &Terms,
        swap: &SwapState,
    ) -> Result<()> {
        let now = fresh_head(self.chain.head().await?.timestamp, self.clock.now())?;
        // The margin counts from the later of the head and this device's clock:
        // the head can trail real time by up to `MAX_HEAD_LAG_SECONDS`.
        let margin_from = now.max(self.clock.now());
        if swap.claim_lock_until > margin_from
            && swap.claim_lock_until - margin_from > REVEAL_MARGIN_SECONDS
        {
            return Ok(());
        }
        let lock_duration = self.chain.lock_duration().await?;
        if !may_take_lock(
            swap.claim_lock_until,
            swap.refund_lock_until,
            now,
            lock_duration,
        ) {
            return fail(
                ErrorCode::ClaimTurn,
                "no claim lock to reveal under; claim once the next turn is ours",
            );
        }
        if SIGNATURE_TTL_SECONDS >= lock_duration {
            return fail(
                ErrorCode::WrongDeployment,
                "the contract's locks are too short to sign for",
            );
        }
        let deadline = now + SIGNATURE_TTL_SECONDS;
        let digest = self.pins.domain().lock_claim(&record.swap_id.0, deadline);
        let signature = self.keys.user_keys(record.index)?.auth.sign(&digest);
        let authorization = SwapAuthorization {
            swap_id: record.swap_id,
            deadline,
            signature: Hex(signature),
        };
        self.relayer
            .lock_claim(&authorization, terms, record.ticket.as_ref())
            .await?;
        self.caught_up(record, terms, |swap| swap.claim_lock_until > now)
            .await?;
        Ok(())
    }

    /// The claim lock re-read from a fresh confirmed head: held, with more
    /// than the margin left, on a swap still open or ready.
    async fn require_fresh_claim_lock(&self, record: &ForwardRecord, terms: &Terms) -> Result<()> {
        let fresh = self.chain.confirmed_swap(&record.swap_id.0, terms).await?;
        let Some(swap) = fresh.swap else {
            return fail(ErrorCode::ChainLagging, "the claim lock isn't confirmed");
        };
        let now = fresh_head(fresh.head.timestamp, self.clock.now())?;
        // As in `hold_claim_lock`: never count the margin from a trailing head.
        let margin_from = now.max(self.clock.now());
        let lapsing = !matches!(swap.stage, SwapStage::Open | SwapStage::Ready)
            || swap.claim_lock_until <= margin_from
            || swap.claim_lock_until - margin_from <= REVEAL_MARGIN_SECONDS;
        if lapsing {
            return fail(ErrorCode::ClaimTurn, "no safe claim lock to reveal under");
        }
        Ok(())
    }

    /// The swap once our node shows what `seen` expects: it can lag the node
    /// a transaction went through.
    async fn caught_up(
        &self,
        record: &ForwardRecord,
        terms: &Terms,
        seen: impl Fn(&SwapState) -> bool,
    ) -> Result<SwapState> {
        for _ in 0..CATCH_UP_POLLS {
            self.check_cancelled()?;
            if let Some(swap) = self
                .chain
                .confirmed_swap(&record.swap_id.0, terms)
                .await?
                .swap
                .filter(|swap| seen(swap))
            {
                return Ok(swap);
            }
            self.clock.sleep(CATCH_UP_INTERVAL).await;
        }
        fail(
            ErrorCode::ChainLagging,
            "our Ethereum node never showed the swap as expected",
        )
    }

    /// A relayer's answer is not the payout receipt: the swap ends paid only
    /// on the confirmed `PaidOut` event, with the amount it paid.
    async fn finish_paid(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
    ) -> Result<ForwardStep> {
        let Some(paid) = self
            .chain
            .confirmed_payout(&record.swap_id.0, record.accepted_at)
            .await?
        else {
            return fail(ErrorCode::ChainLagging, "the payout event isn't confirmed");
        };
        if paid.relayer != self.pins.relayer || paid.relayer == self.pins.maker {
            return fail(
                ErrorCode::WrongDeployment,
                "another deployment's relayer paid out",
            );
        }
        let fee = Amount(paid.fee);
        require_pays_out(record.quote.amount, fee)?;
        self.finish(
            store,
            record,
            ForwardOutcome::Paid,
            Some(Hex(paid.transaction)),
            Some(payout_after_fees(record.quote.amount, fee)),
        )
    }

    // ---- helpers ----

    /// Ends the swap. The end goes on the stored record, which may be newer
    /// than the caller's copy within one step.
    fn finish(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        outcome: ForwardOutcome,
        payout_tx: Option<super::models::Word>,
        receives: Option<Amount>,
    ) -> Result<ForwardStep> {
        end(
            store,
            self.account,
            record,
            outcome.clone(),
            payout_tx,
            receives,
            self.clock.now(),
        )?;
        Ok(ForwardStep::Finished(outcome))
    }

    /// The terms swap `index` opened with: its checked quote, our keys and
    /// the deadlines the maker answered; `None` before the answer.
    fn terms(&self, record: &ForwardRecord) -> Result<Option<Terms>> {
        let (Some(t0), Some(t1)) = (record.t0, record.t1) else {
            return Ok(None);
        };
        Ok(Some(terms::forward_terms(
            self.pins,
            &record.quote,
            self.keys.user_share(record.index)?,
            self.keys.auth_address(record.index)?,
            t0,
            t1,
            self.keys.note(record.index)?.commitment(),
        )?))
    }

    /// The pinned relayer's fee now: refused when another deployment's
    /// relayer, or the maker, answers.
    async fn relayer_fee(&self) -> Result<RelayerFee> {
        let terms = self.relayer.terms().await?;
        let serves = terms.chain_id == self.pins.chain_id
            && terms.contract.0 == self.pins.contract
            && terms.relayer.0 == self.pins.relayer
            && terms.relayer.0 != self.pins.maker;
        if !serves {
            return fail(ErrorCode::WrongDeployment, "another deployment's relayer");
        }
        Ok(RelayerFee {
            fee: terms.fee,
            expires_at: terms.fee_expires_at,
        })
    }

    /// The maker's `/v1/info` against the pins, once per session.
    async fn check_maker(&self) -> Result<()> {
        let network = self.keys.network();
        if self.makers.checked(network) {
            return Ok(());
        }
        let info = self.maker.info().await?;
        let serves = info.api_version == MAKER_API_VERSION
            && info.maker.0 == self.pins.maker
            && info.chain_id == self.pins.chain_id
            && info.contract.0 == self.pins.contract
            && info.token.0 == self.pins.token
            && info.zcash_network == SwapZcashNetwork::from(network);
        if !serves {
            return fail(
                ErrorCode::WrongDeployment,
                "the maker serves another deployment",
            );
        }
        // A return key shown to only some devices would mark the tokens they
        // get back.
        if info
            .token_return_key
            .as_deref()
            .is_some_and(|key| key != self.pins.maker_token_return_key)
        {
            return fail(
                ErrorCode::TokensRefused,
                "the maker returns tokens under another key",
            );
        }
        self.makers.mark(network);
        Ok(())
    }

    /// One conversion at a time per account, in either direction (§3.5 item
    /// 16).
    fn require_none_under_way(&self, store: &SwapStore) -> Result<()> {
        if store.unfinished_count(self.account)? > 0 {
            return fail(ErrorCode::Busy, "a conversion is already under way");
        }
        Ok(())
    }

    fn zcash_network(&self) -> NetworkType {
        self.keys.network().zcash()
    }

    fn set_activity(&self, activity: Activity) {
        if let Some(op) = self.op {
            op.set_activity(activity);
        }
    }

    /// Stops at a safe point once the call is cancelled.
    fn check_cancelled(&self) -> Result<()> {
        if self.op.is_some_and(OpHandle::cancelled) {
            return Err(engine::cancelled());
        }
        Ok(())
    }
}

/// Drops swap `index` before it reached the chain, such as one whose accept
/// failed or a maker never answered (§5.6 step 12). `TooLate` once a deposit
/// started or the chain shows the swap: it goes on.
pub(crate) async fn abandon<C: ChainReader, K: Clock>(
    store: &mut SwapStore,
    chain: &C,
    clock: &K,
    account: &str,
    index: u32,
) -> Result<ForwardRecord> {
    let record = load(store, account, index)?;
    if record.finished() {
        return Ok(record);
    }
    if record.deposit_state() != DepositState::NotStarted
        || chain.swap(&record.swap_id.0).await?.is_some()
    {
        return fail(
            ErrorCode::TooLate,
            "the swap is under way on chain: it goes on",
        );
    }
    // Unanswered, the maker never took it (a turn-away at the token gate
    // included); answered, it never opened.
    let cause = if record.t0.is_none() {
        NothingSentCause::MakerUnavailable
    } else {
        NothingSentCause::NeverOpened
    };
    end(
        store,
        account,
        &record,
        ForwardOutcome::NothingSent { cause },
        None,
        None,
        clock.now(),
    )?;
    load(store, account, index)
}

/// The account's forward records: the active one first, then the rest of
/// the history, newest first.
pub(crate) fn records(store: &SwapStore, account: &str) -> Result<Vec<ForwardRecord>> {
    let active = match store.active(account, Direction::Forward)? {
        Some(StoredRecord::Forward(record)) => Some(record),
        Some(StoredRecord::Reverse(_)) => {
            return fail(
                ErrorCode::StoreUnreadable,
                "a reverse record is filed as forward",
            )
        }
        None => None,
    };
    let active_index = active.as_ref().map(|record| record.index);
    let mut records: Vec<ForwardRecord> = active.into_iter().collect();
    for stored in store.history(account, Direction::Forward)? {
        if let StoredRecord::Forward(record) = stored {
            if Some(record.index) != active_index {
                records.push(record);
            }
        }
    }
    Ok(records)
}

// ---- rules ----

/// What reaches Railgun of `amount`: the relayer's fee comes off first, then
/// Railgun's shield fee (zapp `payoutAfterFees`).
pub(crate) fn payout_after_fees(amount: Amount, relayer_fee: Amount) -> Amount {
    if relayer_fee >= amount {
        return Amount(0);
    }
    let shielded = amount.0 - relayer_fee.0;
    Amount(shielded - shielded * RAILGUN_FEE_BPS / BPS_MAX)
}

/// The relayer refuses a payout `fee` would take all of, so nothing that
/// needs one starts.
fn require_pays_out(amount: Amount, fee: Amount) -> Result<()> {
    if fee >= amount {
        return fail(
            ErrorCode::RelayerFee,
            format!("a relayer fee of {} leaves nothing", fee.0),
        );
    }
    Ok(())
}

/// A fee a payout may be signed for: it leaves something of `amount`, and it
/// is within the 2 USDC cap (D11).
fn require_payout_fee(amount: Amount, fee: Amount) -> Result<()> {
    require_pays_out(amount, fee)?;
    if fee.0 > MAX_RELAYER_FEE {
        return fail(
            ErrorCode::RelayerFee,
            "the relayer's fee is above the 2 USDC cap",
        );
    }
    Ok(())
}

fn require_time_to_accept(quote: &SwapQuote, now: u64) -> Result<()> {
    if now.saturating_add(super::deployment::ACCEPT_MARGIN_SECONDS) >= quote.expires_at {
        return fail(
            ErrorCode::QuoteExpired,
            "the quote runs out too soon to accept",
        );
    }
    Ok(())
}

/// Why no deposit may be paid now, or `None` when one may. Until t0 an
/// unresponsive maker holds it.
fn unpayable(
    pins: &Deployment,
    terms: &Terms,
    swap: &SwapState,
    chain_now: u64,
) -> Option<NothingSentCause> {
    if swap.refund_lock_until != 0 {
        Some(NothingSentCause::MakerCancelled)
    } else if terms.t1 <= terms.t0 || terms.t0 > chain_now.saturating_add(MAX_SECONDS_TO_T0) {
        Some(NothingSentCause::Mismatch)
    } else if terms.t0 < chain_now.saturating_add(pins.min_seconds_to_t0) {
        Some(NothingSentCause::DepositWindowMissed)
    } else {
        None
    }
}

/// Whether the contract gives us a lock at `now`: none is held, nor is it
/// the other side's turn after ours lapsed (`ZecSwap.sol` `_locked`,
/// `_turnAfterLapse`; zapp `mayTakeLock`).
pub(crate) fn may_take_lock(own: u64, other: u64, now: u64, lock_duration: u64) -> bool {
    let held = now < own || now < other;
    let their_turn = own > other && (now < own || now - own < lock_duration);
    lock_duration > 0 && !held && !their_turn
}

/// `head`, the latest block's time, unless it trails this device's clock by
/// minutes: a lapsed lock would look held (§3.5 item 6).
pub(crate) fn fresh_head(head: u64, device_now: u64) -> Result<u64> {
    let lag = device_now.saturating_sub(head);
    if lag > MAX_HEAD_LAG_SECONDS {
        return fail(
            ErrorCode::ChainLagging,
            format!("the chain's head is {lag}s old"),
        );
    }
    Ok(head)
}

/// A maker's refusal of an accept that came before it opened anything, and
/// what ended; `None` for one that may follow an open (zapp `refusal`).
fn accept_refusal(refusal: &Refusal) -> Option<NothingSentCause> {
    match refusal.code {
        Some(
            SwapErrorCode::Rejected
            | SwapErrorCode::InvalidRequest
            | SwapErrorCode::NotFound
            | SwapErrorCode::MethodNotAllowed
            | SwapErrorCode::TokenRequired,
        ) => Some(NothingSentCause::MakerRefused),
        Some(SwapErrorCode::UnknownQuote) => Some(NothingSentCause::QuoteExpired),
        Some(SwapErrorCode::Unavailable | SwapErrorCode::WatchtowerUnavailable) => {
            Some(NothingSentCause::MakerUnavailable)
        }
        Some(SwapErrorCode::UnknownSwap | SwapErrorCode::Internal) => None,
        // A relayer's answer, which no maker gives, or a code this build
        // does not know: read by status.
        Some(SwapErrorCode::AlreadySpent) | None => match refusal.status {
            400 => Some(NothingSentCause::MakerRefused),
            404 => Some(NothingSentCause::QuoteExpired),
            503 => Some(NothingSentCause::MakerUnavailable),
            _ => None,
        },
    }
}

/// A quote's error: the maker turning the amount down is `AmountRefused`.
fn quote_error(error: SwapHttpError) -> PrivateUsdError {
    match error.code() {
        Some(SwapErrorCode::Rejected | SwapErrorCode::InvalidRequest) => {
            PrivateUsdError::new(ErrorCode::AmountRefused, error.to_string())
        }
        _ => error.into(),
    }
}

fn serves(pins: &Deployment, quote: &SwapQuote) -> bool {
    quote.chain_id == pins.chain_id
        && quote.contract.0 == pins.contract
        && quote.token.0 == pins.token
        && quote.maker.0 == pins.maker
}

// ---- the store ----

fn find(store: &SwapStore, account: &str, index: u32) -> Result<Option<ForwardRecord>> {
    match store.find(account, Direction::Forward, index)? {
        Some(StoredRecord::Forward(record)) => Ok(Some(record)),
        Some(StoredRecord::Reverse(_)) => fail(
            ErrorCode::StoreUnreadable,
            "a reverse record is filed as forward",
        ),
        None => Ok(None),
    }
}

fn load(store: &SwapStore, account: &str, index: u32) -> Result<ForwardRecord> {
    find(store, account, index)?
        .ok_or_else(|| PrivateUsdError::new(ErrorCode::Other, "no such conversion"))
}

/// One save, one SQLite transaction, under `OPERATIONS`. `activate` makes
/// it the account's active forward record.
fn write(
    store: &mut SwapStore,
    account: &str,
    record: &ForwardRecord,
    activate: bool,
) -> Result<()> {
    let _guard = OPERATIONS.lock().unwrap_or_else(|error| error.into_inner());
    let stored = StoredRecord::Forward(record.clone());
    if activate {
        store.save(account, &stored)?;
    } else {
        store.update(account, &stored)?;
    }
    Ok(())
}

fn end(
    store: &mut SwapStore,
    account: &str,
    record: &ForwardRecord,
    outcome: ForwardOutcome,
    payout_tx: Option<super::models::Word>,
    receives: Option<Amount>,
    now: u64,
) -> Result<()> {
    let mut ended = find(store, account, record.index)?.unwrap_or_else(|| record.clone());
    ended.outcome = Some(outcome);
    ended.finished_at = Some(now);
    if payout_tx.is_some() {
        ended.payout_tx = payout_tx;
    }
    if let Some(receives) = receives {
        ended.receives = receives;
    }
    write(store, account, &ended, false)
}

// ---- the wallet's Zcash side ----

/// The Zcash side over the main wallet DB and the M2 joint-account
/// operations (reference §8.1).
pub(crate) struct WalletZcash<'a> {
    pub main_db: &'a str,
    pub lightwalletd_url: &'a str,
    pub network: WalletNetwork,
    pub account_uuid: &'a str,
    pub store_dir: &'a Path,
    pub keys: &'a SwapKeyContext,
    /// The call's cancel flag: a joint scan stops on it between batches.
    pub cancel: Arc<AtomicBool>,
}

/// A deposit proposal in `PROPOSAL_STORE`, under its send flow.
pub(crate) struct DepositProposal {
    proposal_id: u64,
    send_flow_id: String,
}

impl WalletZcash<'_> {
    pub(crate) fn joint_db(&self) -> String {
        joint_db_path(self.store_dir)
    }

    async fn tip(&self) -> Result<u64> {
        sync_engine::latest_block_for_transaction(self.lightwalletd_url, self.network)
            .await
            .map(|tip| tip.height)
            .map_err(|error| {
                PrivateUsdError::new(
                    ErrorCode::ZcashWallet,
                    format!("read the Zcash chain tip: {error}"),
                )
            })
    }

    /// Imports swap `index`'s joint account at its exact birthday (§3.5 item
    /// 12), idempotently, and indexes it in `swaps.db`.
    fn import_joint(&self, index: u32, joint: &JointAccount, birthday: u64) -> Result<String> {
        let ufvk = joint.ufvk(self.network.network_type());
        let birthday = u32::try_from(birthday).map_err(|_| {
            PrivateUsdError::new(ErrorCode::Other, "the joint account's birthday is too high")
        })?;
        let joint_uuid =
            joint::register_joint_account(&self.joint_db(), self.network, &ufvk, birthday)?;
        let mut store = SwapStore::open(self.store_dir)?;
        let _guard = OPERATIONS.lock().unwrap_or_else(|error| error.into_inner());
        store.put_joint_account(&JointAccountRow {
            account_uuid: self.account_uuid.to_owned(),
            direction: Direction::Forward,
            swap_index: index,
            joint_uuid: joint_uuid.clone(),
            ufvk,
            birthday: u64::from(birthday),
        })?;
        Ok(joint_uuid)
    }

    async fn synced_joint(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
    ) -> Result<String> {
        let joint_uuid = self.import_joint(index, joint, birthday)?;
        joint::sync_joint_db(
            &self.joint_db(),
            self.lightwalletd_url,
            self.network,
            self.cancel.clone(),
        )
        .await?;
        Ok(joint_uuid)
    }
}

impl ForwardZcash for WalletZcash<'_> {
    type Proposal = DepositProposal;

    async fn chain_height(&self) -> Result<u64> {
        self.tip().await
    }

    async fn synced(&self) -> Result<bool> {
        let scanned = joint::scanned_height(self.main_db, self.network)?;
        let tip = self.tip().await?;
        Ok(scanned.is_some_and(|scanned| u64::from(scanned) >= tip))
    }

    async fn deposit_fee(&self, address: &str, zatoshi: u64) -> Option<u64> {
        match sync::estimate_swap_deposit_fee(
            self.main_db,
            self.network,
            self.account_uuid,
            address,
            zatoshi,
        ) {
            Ok(fee) => fee,
            Err(_) => {
                log::info!("private_usd: no deposit fee estimate");
                None
            }
        }
    }

    async fn propose_deposit(
        &self,
        index: u32,
        address: &str,
        zatoshi: u64,
        max_total: u64,
    ) -> Result<DepositProposal> {
        let send_flow_id = format!("private-usd-deposit:{}:{index}", self.account_uuid);
        let proposal = sync::propose_swap_deposit(
            self.main_db,
            self.network,
            self.account_uuid,
            &send_flow_id,
            address,
            zatoshi,
            max_total,
        )
        .map_err(deposit_error)?;
        let needs_sapling_params = proposal.needs_sapling_params;
        let proposal = DepositProposal {
            proposal_id: proposal.proposal_id,
            send_flow_id,
        };
        // Spending Sapling notes needs the Sapling proving parameters, which
        // Private USD does not download (the swap deposit sender refuses them
        // too).
        if needs_sapling_params {
            self.discard_deposit(proposal);
            return fail(
                ErrorCode::DepositUnpayable,
                "the deposit would spend Sapling funds, which Private USD cannot prove yet",
            );
        }
        Ok(proposal)
    }

    async fn create_deposit(&self, proposal: DepositProposal) -> Result<ZcashTransaction> {
        let created = sync::create_stored_proposal_transactions(
            self.main_db,
            self.lightwalletd_url,
            proposal.proposal_id,
            &proposal.send_flow_id,
            self.keys.seed(),
            None,
            None,
        )
        .await
        .map_err(|message| PrivateUsdError::new(ErrorCode::ZcashWallet, message))?;
        match created.as_slice() {
            [deposit] => kept_transaction(deposit),
            _ => fail(
                ErrorCode::ZcashWallet,
                "the deposit was not one transaction",
            ),
        }
    }

    fn discard_deposit(&self, proposal: DepositProposal) {
        if sync::discard_proposal(proposal.proposal_id, &proposal.send_flow_id).is_err() {
            log::warn!("private_usd: releasing a deposit proposal failed");
        }
    }

    async fn find_deposit(&self, address: &str) -> Result<Option<ZcashTransaction>> {
        joint::find_deposit(self.main_db, self.network, self.account_uuid, address)?
            .as_ref()
            .map(kept_transaction)
            .transpose()
    }

    async fn deposit_status(&self, deposit: &ZcashTransaction) -> Result<SwapTxStatus> {
        joint::swap_tx_status(
            self.main_db,
            self.network,
            &internal_txid(&deposit.tx_id)?,
            expiry(deposit),
        )
    }

    async fn broadcast(&self, transaction: &ZcashTransaction) -> Result<()> {
        let raw = hex::decode(&transaction.raw).map_err(|_| {
            PrivateUsdError::new(ErrorCode::StoreUnreadable, "a kept transaction is not hex")
        })?;
        sync::broadcast_raw(self.lightwalletd_url, &raw)
            .await
            .map_err(|message| {
                let code = if message.starts_with("Broadcast rejected:") {
                    ErrorCode::ZcashRejected
                } else {
                    ErrorCode::ZcashWallet
                };
                PrivateUsdError::new(code, message)
            })
    }

    async fn prepare_sweep(
        &self,
        index: u32,
        joint: &JointAccount,
        key: &SpendKey,
        birthday: u64,
    ) -> Result<Option<ZcashTransaction>> {
        let joint_uuid = self.synced_joint(index, joint, birthday).await?;
        let joint_db = self.joint_db();
        // An earlier sweep that may still land is kept, never built again.
        if let Some(earlier) = joint::find_sent(&joint_db, self.network, &joint_uuid, None)? {
            return kept_transaction(&earlier).map(Some);
        }
        let receipts = joint::joint_receipts(
            &joint_db,
            self.network,
            &joint_uuid,
            crate::wallet::JOINT_SWEEP_CONFIRMATIONS,
        )?;
        // The whole balance at once, so no note is left behind.
        if receipts.spendable_zatoshi == 0 || receipts.pending_zatoshi > 0 {
            return Ok(None);
        }
        let fee_limit = MAX_SWEEP_FEE_ZAT.min(receipts.spendable_zatoshi - 1);
        if fee_limit < MIN_SWEEP_FEE_ZAT {
            return fail(
                ErrorCode::ZcashWallet,
                "the refunded deposit does not cover a sweep's fee",
            );
        }
        let home = keys::get_address_from_db(self.main_db, self.network, Some(self.account_uuid))
            .map_err(|message| PrivateUsdError::new(ErrorCode::ZcashWallet, message))?;
        let send_flow_id = format!("private-usd-sweep:{}:{index}", self.account_uuid);
        let swept = joint::sweep_joint(
            &joint_db,
            self.lightwalletd_url,
            self.network,
            &joint_uuid,
            &send_flow_id,
            &home,
            fee_limit,
            key,
        )
        .await?;
        kept_transaction(&swept.transaction).map(Some)
    }

    async fn sweep_status(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
        sweep: &ZcashTransaction,
    ) -> Result<SwapTxStatus> {
        self.synced_joint(index, joint, birthday).await?;
        joint::swap_tx_status(
            &self.joint_db(),
            self.network,
            &internal_txid(&sweep.tx_id)?,
            expiry(sweep),
        )
    }

    async fn forget_joint_account(&self, index: u32) -> Result<()> {
        let rows: Vec<JointAccountRow> = SwapStore::open(self.store_dir)?
            .joint_accounts()?
            .into_iter()
            .filter(|row| {
                row.account_uuid == self.account_uuid
                    && row.direction == Direction::Forward
                    && row.swap_index == index
            })
            .collect();
        for row in rows {
            joint::forget_joint_account(&self.joint_db(), self.network, &row.joint_uuid)?;
            let mut store = SwapStore::open(self.store_dir)?;
            let _guard = OPERATIONS.lock().unwrap_or_else(|error| error.into_inner());
            store.remove_joint_account(self.account_uuid, Direction::Forward, index)?;
        }
        Ok(())
    }
}

/// A forward driver over the real seams.
pub(crate) type WalletForward<'a> = Forward<
    'a,
    EvmRpc<'a, RoutedTransport>,
    RoutedTransport,
    WalletZcash<'a>,
    SystemClock,
    NoTokens,
>;

/// One FRB call's account, paths and endpoints, which it drives its forward
/// swaps over. The caller holds the account's driver lock.
pub(crate) struct ForwardCall<'s> {
    pub main_db: &'s str,
    pub network: WalletNetwork,
    pub account: &'s str,
    pub store_dir: &'s Path,
    pub lightwalletd_url: &'s str,
    /// The keyed Ethereum RPC URL, or empty for publicnode. Never stored.
    pub eth_rpc_url: &'s str,
    pub keys: &'s SwapKeyContext,
}

impl ForwardCall<'_> {
    /// Runs `step` on a driver over routed HTTP (one transport per call),
    /// the pinned contract, the wallet DBs and `swaps.db`. With `op`, its
    /// cancel flag stops requests and joint scans.
    pub(crate) async fn run<R>(
        &self,
        op: Option<&OpHandle>,
        step: impl AsyncFnOnce(&WalletForward<'_>, &mut SwapStore) -> Result<R>,
    ) -> Result<R> {
        let cancel = op.map(OpHandle::cancel_flag).unwrap_or_default();
        let transport = RoutedTransport::cancellable(cancel.clone());
        let pins = super::deployment::deployment(self.keys.network());
        let chain = EvmRpc::new(&transport, pins.rpc_url(self.eth_rpc_url), pins);
        let zcash = WalletZcash {
            main_db: self.main_db,
            lightwalletd_url: self.lightwalletd_url,
            network: self.network,
            account_uuid: self.account,
            store_dir: self.store_dir,
            keys: self.keys,
            cancel,
        };
        let clock = SystemClock;
        let tokens = NoTokens;
        let forward = Forward::new(
            self.account,
            self.keys,
            &chain,
            &transport,
            &zcash,
            &clock,
            &tokens,
            &engine::MAKER_CHECKS,
            op,
        );
        let mut store = SwapStore::open(self.store_dir)?;
        step(&forward, &mut store).await
    }
}

/// [`abandon`] over the pinned contract; no key is needed. The caller holds
/// the account's driver lock.
pub(crate) async fn abandon_with(
    store_dir: &Path,
    network: super::PrivateUsdNetwork,
    eth_rpc_url: &str,
    account: &str,
    index: u32,
) -> Result<ForwardRecord> {
    let transport = RoutedTransport::new();
    let pins = super::deployment::deployment(network);
    let chain = EvmRpc::new(&transport, pins.rpc_url(eth_rpc_url), pins);
    let mut store = SwapStore::open(store_dir)?;
    abandon(&mut store, &chain, &SystemClock, account, index).await
}

/// `joint.db` in a wallet's Private USD directory.
pub(crate) fn joint_db_path(store_dir: &Path) -> String {
    store_dir.join(JOINT_DB_FILE).to_string_lossy().into_owned()
}

/// Why a deposit cannot be proposed: it does not fit (the problem copy says
/// so), or the wallet failed.
fn deposit_error(message: String) -> PrivateUsdError {
    let unpayable = message.starts_with("Propose failed")
        || message.starts_with("A swap transaction must be one transaction")
        || message.starts_with("The swap deposit costs");
    let code = if unpayable {
        ErrorCode::DepositUnpayable
    } else {
        ErrorCode::ZcashWallet
    };
    PrivateUsdError::new(code, message)
}

/// A created transaction as a record keeps it: its id in display order (as
/// zapp's records do), its bytes in hex.
fn kept_transaction(created: &CreatedTransaction) -> Result<ZcashTransaction> {
    let tx_id = ZcashTxId::parse(&created.txid.to_string()).ok_or_else(|| {
        PrivateUsdError::new(ErrorCode::ZcashWallet, "a created transaction has no id")
    })?;
    Ok(ZcashTransaction {
        tx_id,
        raw: hex::encode(&created.raw),
        expiry_height: u64::from(created.expiry_height),
    })
}

fn expiry(transaction: &ZcashTransaction) -> u32 {
    u32::try_from(transaction.expiry_height).unwrap_or(u32::MAX)
}

/// A record's transaction id (display order) as the wallet DB stores it:
/// internal byte order.
pub(crate) fn internal_txid(tx_id: &ZcashTxId) -> Result<TxId> {
    let mut bytes = [0u8; 32];
    hex::decode_to_slice(tx_id.as_str(), &mut bytes).map_err(|_| {
        PrivateUsdError::new(
            ErrorCode::StoreUnreadable,
            "a kept transaction id is not hex",
        )
    })?;
    bytes.reverse();
    Ok(TxId::from_bytes(bytes))
}
