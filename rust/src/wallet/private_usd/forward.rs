//! A forward conversion, ZEC → private USD, and its refund.
//!
//! Every step reads the chain first, so any of them can run again after an
//! interruption. Only a confirmed read authorizes a deposit or the end. The
//! record is saved before the user's share leaves the device, a deposit is
//! marked started before it is created and kept before it is first sent, and
//! a payout is kept before it is posted. `z` is revealed only in the claim's
//! window: once the swap is ready, `READY_DEPTH_BLOCKS` deep before `t0`, or
//! from `t0`, with more than `REVEAL_MARGIN_SECONDS` left before `t1`; or for
//! good from `t1 + LATE`. It is judged on one consistent read of a fresh
//! head, again immediately before the claim is posted, and the claim is
//! marked posted before it goes. Between `t1` and `t1 + LATE` the swap is the
//! maker's to refund, and the deposit comes home.
//!
//! The driver runs over seams: [`ChainReader`], [`HttpTransport`],
//! [`ForwardZcash`] (the wallet's side, [`WalletZcash`]) and [`Clock`]. The
//! engine tests fake all but the keys and the store.

use std::path::Path;
use std::time::Duration;

use zecswap_core::{JointAccount, NetworkType, SpendKey, Terms};
use zeroize::Zeroizing;

use super::deployment::{
    self, Deployment, ACCEPT_MARGIN_SECONDS, MAX_SECONDS_TO_T0, MAX_T0_TO_T1_SECONDS,
    READY_DEPTH_BLOCKS, REVEAL_MARGIN_SECONDS,
};
use super::engine::{self, Activity, Clock, MakerChecks, Offer, OpHandle, SystemClock};
use super::evm_rpc::{ChainReader, EvmRpc, SwapStage, SwapState};
use super::joint::{SwapTxStatus, WalletZcash};
use super::keys::SwapKeyContext;
use super::maker_client::MakerClient;
use super::models::{
    Amount, DepositProgress, Direction, ForwardOutcome, ForwardRecord, Hex, NothingSentCause,
    RefundCause, RelayerTerms, SwapAcceptance, SwapNote, SwapPayout, SwapQuote, Word,
    ZcashTransaction,
};
use super::relayer_client::RelayerClient;
use super::store::SwapStore;
use super::swap::{
    self, find, load, payout_after_fees, pinned_relayer_terms, quote_error, require_payout_fee,
    require_pays_out, save, serves, update, ClaimWindow, PostError, SwapCall, WindowView,
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
    /// Too late to claim before `t1`, and from it the swap is the maker's to
    /// refund for its late window: the deposit comes back with the refund,
    /// or from `t1 + LATE` the claim goes out after all.
    Unwinding,
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
        ForwardWait::DepositUnsettled | ForwardWait::Refunding | ForwardWait::Unwinding => {
            Duration::from_secs(30)
        }
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
    /// `/v1/claim`: reveals `z` in the claim's window, then pays out.
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
        self.pins.swap_contract()?;
        swap::require_none_under_way(store, self.account, self.pins)?;
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
        swap::require_none_under_way(store, self.account, self.pins)?;
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
            claim_posted: false,
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
        require_served(self.pins, &record)?;
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
        // A maker that names another late window settles on another
        // contract than ours: nothing is paid into it.
        let late_window = self.pins.swap_contract()?.late_window;
        if accepted.swap_id != opened.swap_id
            || accepted
                .late_window
                .is_some_and(|window| window != late_window)
        {
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
        require_served(self.pins, &record)?;
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
            SwapStage::Ready => self.claim(store, record, terms).await,
            SwapStage::Open => self.open(store, record, terms).await,
        }
    }

    async fn open(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
    ) -> Result<ForwardStep> {
        match self.ensure_paid(store, record, terms).await? {
            Deposit::Unpayable(cause) => self.finish(
                store,
                record,
                ForwardOutcome::NothingSent { cause },
                None,
                None,
            ),
            Deposit::Syncing => Ok(waiting(ForwardWait::ZcashSyncing)),
            // From t0 the claim needs no `ready`: a maker gone quiet holds
            // the deposit no longer.
            Deposit::Kept => self.claim(store, record, terms).await,
        }
    }

    // ---- the deposit ----

    /// Sends the deposit again until it is mined; pays anew only once the
    /// last is proven expired, and in time for t0. A deposit is never paid
    /// twice.
    async fn ensure_paid(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
    ) -> Result<Deposit> {
        // From the maker share the contract confirmed, never the API's alone.
        let address = self
            .keys
            .joint(record.index, &terms.maker_share)?
            .unified_address(self.zcash_network());
        let chain_now = self.chain.head().await?.timestamp;
        let unpayable = unpayable(self.pins, terms, chain_now)?;
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
        if !matches!(status, SwapTxStatus::Mined { .. }) {
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
        let cause = self.refund_cause(record, terms).await?;
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

    /// A refund mined before t0 is the maker calling the swap off; one from
    /// t1, the only other time a forward swap refunds, waited out the claim.
    /// Without the refund's event, the chain's time now says the same.
    async fn refund_cause(&self, record: &ForwardRecord, terms: &Terms) -> Result<RefundCause> {
        let refunded_at = match self
            .chain
            .confirmed_refund_time(&record.swap_id.0, record.accepted_at)
            .await?
        {
            Some(at) => at,
            None => self.chain.head().await?.timestamp,
        };
        Ok(if refunded_at < terms.t1 {
            RefundCause::MakerCancelled
        } else {
            RefundCause::NotClaimedInTime
        })
    }

    // ---- the claim ----

    /// Reveals `z` once the claim's window is open, then pays out; while the
    /// windows hold the claim, waits. The window is judged again immediately
    /// before the claim is posted, after every preparatory step.
    async fn claim(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
    ) -> Result<ForwardStep> {
        if let Some(wait) = self.claim_window(record, terms).await? {
            return Ok(holding(wait, terms));
        }
        engine::set_activity(self.op, Activity::Claiming);
        let payout = self.signed_payout(store, record, terms, None).await?;
        engine::check_cancelled(self.op)?;
        if let Some(wait) = self
            .send_payout(store, record, terms, payout, PayoutPost::Claim)
            .await?
        {
            return Ok(holding(wait, terms));
        }
        let claimed = self
            .caught_up(record, terms, |swap| swap.stage == SwapStage::Claimed)
            .await?;
        if !claimed.paid_out {
            self.pay_out(store, record, terms).await?;
        }
        self.finish_paid(store, record).await
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
            .domain()?
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

    /// Posts `payout`; with a claim, `Some(wait)` while the windows hold it,
    /// and nothing is revealed. A refusal sends nothing: one turning the fee
    /// down is signed again only at a higher fee the relayer asks now, and
    /// posted once more.
    async fn send_payout(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        payout: SwapPayout,
        post: PayoutPost,
    ) -> Result<Option<ForwardWait>> {
        let refusal = match self.post_payout(store, record, terms, &payout, post).await {
            Ok(held) => return Ok(held),
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
        self.post_payout(store, record, terms, &repriced, post)
            .await
            .map_err(PrivateUsdError::from)
    }

    /// Posts `payout`. A claim goes only once its window is judged open again
    /// on a read immediately before it (`Ok(Some(wait))` while held, nothing
    /// sent), and is kept as posted before it goes.
    async fn post_payout(
        &self,
        store: &mut SwapStore,
        record: &ForwardRecord,
        terms: &Terms,
        payout: &SwapPayout,
        post: PayoutPost,
    ) -> std::result::Result<Option<ForwardWait>, PostError> {
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
                if let Some(wait) = self
                    .claim_window(record, terms)
                    .await
                    .map_err(PostError::Failed)?
                {
                    return Ok(Some(wait));
                }
                self.mark_claim_posted(store, record)
                    .map_err(PostError::Failed)?;
                self.relayer.claim(&secret, payout, terms, ticket).await
            }
            PayoutPost::Payout => self.relayer.payout(payout, terms, ticket).await,
        };
        match sent {
            Ok(_) => Ok(None),
            Err(SwapHttpError::Refused(refusal)) => Err(PostError::Refused(refusal)),
            Err(error) => Err(PostError::Failed(error.into())),
        }
    }

    /// Keeps the claim as posted on the record as stored, before it goes.
    fn mark_claim_posted(&self, store: &mut SwapStore, record: &ForwardRecord) -> Result<()> {
        let mut current: ForwardRecord = load(store, self.account, record.index)?;
        if !current.claim_posted {
            current.claim_posted = true;
            update(store, self.account, &current)?;
        }
        Ok(())
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

    /// The claim's window on one consistent read of a fresh head: `None` to
    /// claim now, else what the windows wait for. Before `t0`, a ready counts
    /// once the block `READY_DEPTH_BLOCKS` below the head shows it. Railgun
    /// is asked only once the windows would let the claim go.
    async fn claim_window(
        &self,
        record: &ForwardRecord,
        terms: &Terms,
    ) -> Result<Option<ForwardWait>> {
        let read = self.chain.read_swap(&record.swap_id.0, terms).await?;
        let device_now = self.clock.now();
        let view = WindowView {
            stage: read.swap.as_ref().map(|swap| swap.stage),
            head: swap::fresh_head(read.head.timestamp, device_now)?,
            head_number: read.head.number,
            device_now,
            t0: terms.t0,
            t1: terms.t1,
            late_window: self.pins.swap_contract()?.late_window,
        };
        let ready_block = if view.stage == Some(SwapStage::Ready) && view.head < view.t0 {
            let deep = read.head.number.saturating_sub(READY_DEPTH_BLOCKS);
            self.chain
                .swap_at(&record.swap_id.0, terms, deep)
                .await?
                .is_some_and(|then| then.stage == SwapStage::Ready)
                .then_some(deep)
        } else {
            None
        };
        let window = match swap::claim_window(&view, ready_block, true) {
            ClaimWindow::Open => {
                swap::claim_window(&view, ready_block, self.chain.railgun_accepts().await?)
            }
            held => held,
        };
        match window {
            ClaimWindow::Open => Ok(None),
            ClaimWindow::NotYet | ClaimWindow::Shut => Ok(Some(ForwardWait::Confirming)),
            ClaimWindow::Unwinding => Ok(Some(ForwardWait::Unwinding)),
            ClaimWindow::RailgunClosed => fail(
                ErrorCode::RailgunClosed,
                "Railgun is not taking the payout now",
            ),
        }
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
    pins: &Deployment,
    chain: &C,
    clock: &K,
    account: &str,
    index: u32,
) -> Result<ForwardRecord> {
    let record: ForwardRecord = load(store, account, index)?;
    if record.finished() {
        return Ok(record);
    }
    require_served(pins, &record)?;
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
/// unresponsive maker holds it, and until the maker refunds from t1 a
/// deposit it never readied: `t1` must leave the claim from `t0` the
/// contract's least window and twice the margin, and be no further off than
/// `MAX_T0_TO_T1_SECONDS`.
fn unpayable(pins: &Deployment, terms: &Terms, chain_now: u64) -> Result<Option<NothingSentCause>> {
    let least_claim = pins
        .swap_contract()?
        .min_window
        .max(2 * REVEAL_MARGIN_SECONDS);
    let claim = terms.t1.checked_sub(terms.t0);
    Ok(
        if claim.is_none_or(|claim| !(least_claim..=MAX_T0_TO_T1_SECONDS).contains(&claim))
            || terms.t0 > chain_now.saturating_add(MAX_SECONDS_TO_T0)
        {
            Some(NothingSentCause::Mismatch)
        } else if terms.t0 < chain_now.saturating_add(pins.min_seconds_to_t0) {
            Some(NothingSentCause::DepositWindowMissed)
        } else {
            None
        },
    )
}

/// The record is pinned to this build's deployment: its quote names the
/// pinned chain, windows contract, token and maker. One of another, such as
/// the lock contract's, is never followed.
fn require_served(pins: &Deployment, record: &ForwardRecord) -> Result<()> {
    if !serves(pins, &record.quote) {
        return fail(
            ErrorCode::WrongDeployment,
            "the conversion belongs to another deployment",
        );
    }
    Ok(())
}

/// Waiting on the windows, with the deadlines they run on.
fn holding(wait: ForwardWait, terms: &Terms) -> ForwardStep {
    ForwardStep::Waiting {
        wait,
        t0: Some(terms.t0),
        t1: Some(terms.t1),
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
    let pins = deployment::deployment(network);
    let transport = RoutedHttp::new();
    let chain = EvmRpc::new(&transport, pins, eth_rpc_url);
    let mut store = SwapStore::open(store_dir)?;
    abandon(&mut store, pins, &chain, &SystemClock, account, index).await
}
