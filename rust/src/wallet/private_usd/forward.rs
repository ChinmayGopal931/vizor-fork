//! A forward conversion, ZEC → private USD, and its refund.
//!
//! Every step reads the chain first, so any of them can run again after an
//! interruption. Only a confirmed read authorizes a deposit, a reveal or the
//! end. The record is saved before the user's share leaves the device, a
//! deposit is marked started before it is created and kept before it is first
//! sent, and a payout is kept before it is posted. `z` is revealed only under
//! a claim lock with more than `REVEAL_MARGIN_SECONDS` left, read again from a
//! fresh head immediately before sending.
//!
//! The driver runs over seams: [`ChainReader`], [`HttpTransport`],
//! [`ForwardZcash`] (the wallet's side, [`WalletZcash`]) and [`Clock`]. The
//! engine tests fake all but the keys and the store.

use std::path::Path;
use std::time::Duration;

use zecswap_core::{JointAccount, NetworkType, SpendKey, Terms};
use zeroize::Zeroizing;

use super::deployment::{self, Deployment, ACCEPT_MARGIN_SECONDS, MAX_SECONDS_TO_T0};
use super::engine::{self, Activity, Clock, MakerChecks, Offer, OpHandle, SystemClock};
use super::evm_rpc::{ChainReader, EvmRpc, SwapStage, SwapState};
use super::joint::{SwapTxStatus, WalletZcash};
use super::keys::SwapKeyContext;
use super::maker_client::MakerClient;
use super::models::{
    Amount, DepositProgress, Direction, ForwardOutcome, ForwardRecord, Hex, NothingSentCause,
    RefundCause, RelayerTerms, SwapAcceptance, SwapAuthorization, SwapNote, SwapPayout, SwapQuote,
    Word, ZcashTransaction,
};
use super::relayer_client::RelayerClient;
use super::store::SwapStore;
use super::swap::{
    self, find, load, lock_deadline, payout_after_fees, pinned_relayer_terms, quote_error,
    require_payout_fee, require_pays_out, reveal_margin_holds, save, serves, update, PostError,
    SwapCall,
};
use super::transport::{HttpTransport, Refusal, SwapErrorCode, SwapHttpError};
use super::{fail, indices, terms, ErrorCode, PrivateUsdError, Result};
use crate::wallet::routed_http::RoutedHttp;

/// A maker's open can queue behind others; past this after the quote's
/// expiry it is not coming, or too late to deposit into.
const OPEN_GRACE_SECONDS: u64 = 5 * 60;
/// `caught_up` polls a confirmed read this often, this many times.
const CATCH_UP_POLLS: u32 = 30;
const CATCH_UP_INTERVAL: Duration = Duration::from_secs(2);

/// Why a forward swap waits, with nothing for the user to do.
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

/// How long the engine loop naps after a wait.
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
    /// The maker wants a Privacy Pass token, which this build cannot pay.
    /// Nothing opened; the record waits, unanswered, to be abandoned.
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
/// show after a minute, not an error.
#[derive(Clone, Debug)]
pub(crate) struct AdvanceReport {
    pub record: ForwardRecord,
    pub wait: Option<ForwardWait>,
    pub next_poll: Duration,
    pub problem: Option<ErrorCode>,
}

/// The wallet's Zcash side of a forward swap.
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
    async fn deposit_fee(&self, address: &str, zatoshi: u64) -> Result<Option<u64>>;
    /// Proposes paying `zatoshi` to `address` in one transaction costing at
    /// most `max_total_zatoshi` in all, and locks its inputs.
    async fn propose_deposit(
        &self,
        index: u32,
        address: &str,
        zatoshi: u64,
        max_total_zatoshi: u64,
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

/// A stored deposit proposal, released unless it was created:
/// `PROPOSAL_STORE` is consume-on-entry.
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

/// One account's forward swaps, over the seams.
pub(crate) struct Forward<'a, C, T, Z, K>
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
    makers: &'a MakerChecks,
    op: Option<&'a OpHandle>,
}

impl<'a, C, T, Z, K> Forward<'a, C, T, Z, K>
where
    C: ChainReader,
    T: HttpTransport,
    Z: ForwardZcash,
    K: Clock,
{
    pub(crate) fn new(
        account: &'a str,
        keys: &'a SwapKeyContext,
        chain: &'a C,
        transport: &'a T,
        zcash: &'a Z,
        clock: &'a K,
        makers: &'a MakerChecks,
        op: Option<&'a OpHandle>,
    ) -> Self {
        let pins = deployment::deployment(keys.network());
        Self {
            pins,
            account,
            keys,
            chain,
            maker: MakerClient::new(transport, pins.maker_url),
            relayer: RelayerClient::new(transport, pins.relayer_url),
            zcash,
            clock,
            makers,
            op,
        }
    }

    // ---- quote and accept ----

    /// Quotes `units` of the token for a fresh index, which counts as spent
    /// from here on: a shared `z` would hand that swap to its maker. The
    /// offer stays in memory until accepted or expired; it is never
    /// persisted.
    pub(crate) async fn quote(&self, store: &mut SwapStore, units: u32) -> Result<Quoted> {
        let session = engine::session();
        swap::require_none_under_way(store, self.account)?;
        swap::check_maker(&self.maker, self.pins, self.makers, false).await?;
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
        let relayer = self.relayer_terms().await?;
        // A fee above the cap is refused before anything is accepted.
        deployment::require_within_fee_cap(relayer.fee.0)?;
        let receives = payout_after_fees(quote.amount, relayer.fee);
        // The preview pays the quote's share; the deposit itself goes to the
        // joint address of the confirmed on-chain terms.
        let address = self
            .keys
            .joint(index, &terms::quote_maker_share(&quote)?)?
            .unified_address(self.zcash_network());
        let deposit_fee_zatoshi = self.zcash.deposit_fee(&address, quote.deposit_zat).await?;
        let offer = Offer {
            network: self.keys.network(),
            quote,
            relayer_fee: relayer.fee,
            fee_expires_at: relayer.fee_expires_at,
            receives,
            deposit_fee_zatoshi,
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
    /// maker sees our share, so an accept cut short is still known. Again for
    /// an index already saved, unfinished and unanswered, it posts the saved
    /// quote once more and never takes another index.
    pub(crate) async fn accept(
        &self,
        store: &mut SwapStore,
        index: u32,
        max_total_zatoshi: u64,
    ) -> Result<AcceptOutcome> {
        if let Some(record) = find(store, self.account, index)? {
            return self.accept_again(store, record).await;
        }
        swap::require_none_under_way(store, self.account)?;
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
        if offer.deposit_fee_zatoshi.is_none() {
            return fail(
                ErrorCode::DepositUnpayable,
                "the deposit does not fit one transaction from this wallet",
            );
        }
        if max_total_zatoshi < quote.deposit_zat {
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
            max_total_zat: Some(max_total_zatoshi),
            deposit: None,
            sweep: None,
            payout: None,
            t0: None,
            t1: None,
            fee_expires_at: offer.fee_expires_at,
            ticket: None,
        };
        save(store, self.account, &record)?;
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
        let accepted = match self.maker.accept(&record.quote.quote_id, acceptance).await {
            Ok(accepted) => accepted,
            // Turned away at the token gate. A refusal sends nothing, so
            // nothing opened.
            Err(SwapHttpError::Refused(refusal))
                if refusal.code == Some(SwapErrorCode::TokenRequired) =>
            {
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
        update(store, self.account, &opened)?;
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
        swap::acceptance(self.keys, self.pins, index, quote)
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
        load::<ForwardRecord>(store, self.account, index)?;
        let step = self.advance(store, index).await;
        let step = swap::loop_outcome(self.op, Direction::Forward, index, step)?;
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
            Err(problem) => AdvanceReport {
                record,
                wait: None,
                next_poll: engine::RETRY_DELAY,
                problem: Some(problem),
            },
        })
    }

    /// One look at the chain for swap `index`: deposits, claims or refunds
    /// when due.
    pub(crate) async fn advance(&self, store: &mut SwapStore, index: u32) -> Result<ForwardStep> {
        let record: ForwardRecord = load(store, self.account, index)?;
        if let Some(outcome) = &record.outcome {
            return Ok(ForwardStep::Finished(outcome.clone()));
        }
        engine::check_cancelled(self.op)?;
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
                    && record.deposit_progress() == DepositProgress::NotStarted =>
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
        let cause = if !gave_up || record.deposit_progress() != DepositProgress::NotStarted {
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
                    engine::set_activity(self.op, Activity::PayingOut);
                    self.pay_out(store, record, terms).await?;
                }
                self.finish_paid(store, record).await
            }
            SwapStage::Ready => {
                engine::set_activity(self.op, Activity::Claiming);
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
                engine::set_activity(self.op, Activity::Claiming);
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
    /// last is proven expired, in time for t0 and with no refund lock. A
    /// deposit is never paid twice.
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

        let deposit = current.deposit.clone();
        let kept = swap::unexpired(
            store,
            self.account,
            &mut current,
            deposit,
            async |deposit| self.zcash.deposit_status(deposit).await,
            |current| {
                // Proven never to be mined: it may be paid anew.
                current.deposit = None;
                current.deposit_attempted = true;
            },
        )
        .await?;
        let (deposit, status) = match kept {
            Some(kept) => kept,
            None => {
                if let Some(cause) = unpayable {
                    return Ok(Deposit::Unpayable(cause));
                }
                if !self.zcash.synced().await? {
                    return Ok(Deposit::Syncing);
                }
                engine::check_cancelled(self.op)?;
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
                engine::check_cancelled(self.op)?;
                engine::set_activity(self.op, Activity::Depositing);
                // Started before it exists: an interruption from here on finds
                // it in the wallet rather than paying again.
                current.deposit_attempted = true;
                update(store, self.account, &current)?;
                let created = self.zcash.create_deposit(proposal.take()).await?;
                // Kept before it is first sent.
                current.deposit = Some(created.clone());
                update(store, self.account, &current)?;
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
            update(store, self.account, &current)?;
        }
        Ok(current)
    }

    // ---- the refund ----

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
        let key = swap::joint_spend_key(self.keys, record.index, joint, &swap.secret)?;
        let birthday = record.zcash_height;
        let mut current = record.clone();

        let sweep = current.sweep.clone();
        let kept = swap::unexpired(
            store,
            self.account,
            &mut current,
            sweep,
            async |sweep| {
                self.zcash
                    .sweep_status(record.index, joint, birthday, sweep)
                    .await
            },
            |current| current.sweep = None,
        )
        .await?;
        let (sweep, status) = match kept {
            Some(kept) => kept,
            None => {
                engine::check_cancelled(self.op)?;
                engine::set_activity(self.op, Activity::Sweeping);
                let Some(built) = self
                    .zcash
                    .prepare_sweep(record.index, joint, &key, birthday)
                    .await?
                else {
                    return Ok(waiting(ForwardWait::Refunding));
                };
                current.sweep = Some(built.clone());
                update(store, self.account, &current)?;
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
                "private usd: forgetting a swept joint account failed ({:?})",
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

    // ---- the claim ----

    /// Reveals `z` under a held claim lock once Railgun would take the
    /// payout, then pays out.
    async fn claim(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        swap: &SwapState,
    ) -> Result<()> {
        let payout = self.signed_payout(store, record, terms, None).await?;
        self.require_railgun_open().await?;
        engine::check_cancelled(self.op)?;
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
        let payout = self.signed_payout(store, record, terms, None).await?;
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
    /// must leave something of the amount and be within the cap.
    async fn signed_payout(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        repriced: Option<Amount>,
    ) -> Result<SwapPayout> {
        let mut current: ForwardRecord = load(store, self.account, record.index)?;
        if current.finished() {
            return fail(ErrorCode::Other, "the conversion has ended");
        }
        let note = SwapNote::from(&self.keys.note(current.index)?);
        if let Some(saved) = &current.payout {
            if saved.swap_id != current.swap_id || saved.note != note {
                return fail(ErrorCode::Mismatch, "the saved payout is for another swap");
            }
        }
        let asked = self.relayer_terms().await?.fee;
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
        update(store, self.account, &current)?;
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
            Err(PostError::Refused(refusal)) if refusal.code == Some(SwapErrorCode::Rejected) => {
                refusal
            }
            Err(failed) => return Err(failed.into()),
        };
        let fee = self.relayer_terms().await?.fee;
        if fee <= payout.fee {
            return Err(SwapHttpError::Refused(refusal).into());
        }
        let repriced = self.signed_payout(store, record, terms, Some(fee)).await?;
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
    ) -> std::result::Result<(), PostError> {
        let ticket = record.ticket.as_ref();
        let sent = match post {
            PayoutPost::Claim => {
                let secret = Zeroizing::new(
                    self.keys
                        .user_keys(record.index)
                        .map_err(PostError::Failed)?
                        .share
                        .to_be_bytes(),
                );
                // Read the lock and the clock again after every preparatory
                // step, immediately before the reveal.
                self.require_fresh_claim_lock(record, terms)
                    .await
                    .map_err(PostError::Failed)?;
                self.relayer.claim(&secret, payout, terms, ticket).await
            }
            PayoutPost::Payout => self.relayer.payout(payout, terms, ticket).await,
        };
        match sent {
            Ok(_) => Ok(()),
            Err(SwapHttpError::Refused(refusal)) => Err(PostError::Refused(refusal)),
            Err(error) => Err(PostError::Failed(error.into())),
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
        let now = swap::fresh_head(self.chain.head().await?.timestamp, self.clock.now())?;
        if reveal_margin_holds(swap.claim_lock_until, now, self.clock.now()) {
            return Ok(());
        }
        let lock_duration = self.chain.lock_duration().await?;
        let Some(deadline) = lock_deadline(
            swap.claim_lock_until,
            swap.refund_lock_until,
            now,
            lock_duration,
        )?
        else {
            return fail(
                ErrorCode::ClaimTurn,
                "no claim lock to reveal under; claim once the next turn is ours",
            );
        };
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

    /// The claim lock read again from a fresh confirmed head: held, with
    /// more than the margin left, on a swap still open or ready.
    async fn require_fresh_claim_lock(&self, record: &ForwardRecord, terms: &Terms) -> Result<()> {
        let fresh = self.chain.confirmed_swap(&record.swap_id.0, terms).await?;
        let Some(swap) = fresh.swap else {
            return fail(ErrorCode::ChainLagging, "the claim lock isn't confirmed");
        };
        let now = swap::fresh_head(fresh.head.timestamp, self.clock.now())?;
        let safe = matches!(swap.stage, SwapStage::Open | SwapStage::Ready)
            && reveal_margin_holds(swap.claim_lock_until, now, self.clock.now());
        if !safe {
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
            engine::check_cancelled(self.op)?;
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
        payout_tx: Option<Word>,
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

    async fn relayer_terms(&self) -> Result<RelayerTerms> {
        pinned_relayer_terms(&self.relayer, self.pins).await
    }

    fn zcash_network(&self) -> NetworkType {
        self.keys.network().zcash()
    }
}

/// Drops swap `index` before it reached the chain, such as one whose accept
/// failed or a maker never answered. `TooLate` once a deposit started or the
/// chain shows the swap: it goes on.
pub(crate) async fn abandon<C: ChainReader, K: Clock>(
    store: &mut SwapStore,
    chain: &C,
    clock: &K,
    account: &str,
    index: u32,
) -> Result<ForwardRecord> {
    let record: ForwardRecord = load(store, account, index)?;
    if record.finished() {
        return Ok(record);
    }
    if record.deposit_progress() != DepositProgress::NotStarted
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

// ---- rules ----

fn require_time_to_accept(quote: &SwapQuote, now: u64) -> Result<()> {
    if now.saturating_add(ACCEPT_MARGIN_SECONDS) >= quote.expires_at {
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

/// A maker's refusal of an accept that came before it opened anything, and
/// what ended; `None` for one that may follow an open.
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
        Some(SwapErrorCode::AlreadySpent | SwapErrorCode::Conflict) | None => {
            match refusal.status {
                400 => Some(NothingSentCause::MakerRefused),
                404 => Some(NothingSentCause::QuoteExpired),
                503 => Some(NothingSentCause::MakerUnavailable),
                _ => None,
            }
        }
    }
}

// ---- the store ----

fn end(
    store: &mut SwapStore,
    account: &str,
    record: &ForwardRecord,
    outcome: ForwardOutcome,
    payout_tx: Option<Word>,
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
    update(store, account, &ended)
}

// ---- over the real seams ----

/// A forward driver over the real seams.
pub(crate) type WalletForward<'a> =
    Forward<'a, EvmRpc<'a, RoutedHttp>, RoutedHttp, WalletZcash<'a>, SystemClock>;

impl SwapCall<'_> {
    /// Runs `step` on a forward driver over routed HTTP (one transport per
    /// call), the pinned contract, the wallet DBs and `swaps.db`. With `op`,
    /// its cancel flag stops requests and joint scans.
    pub(crate) async fn forward<R>(
        &self,
        op: Option<&OpHandle>,
        step: impl AsyncFnOnce(&WalletForward<'_>, &mut SwapStore) -> Result<R>,
    ) -> Result<R> {
        let transport = swap::transport(op);
        let chain = EvmRpc::new(&transport, self.pins(), self.eth_rpc_url);
        let zcash = self.zcash(op);
        let forward = Forward::new(
            self.account,
            self.keys,
            &chain,
            &transport,
            &zcash,
            &SystemClock,
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
    let transport = RoutedHttp::new();
    let chain = EvmRpc::new(&transport, deployment::deployment(network), eth_rpc_url);
    let mut store = SwapStore::open(store_dir)?;
    abandon(&mut store, &chain, &SystemClock, account, index).await
}
