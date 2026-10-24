//! A reverse conversion, private USD → ZEC, with its refund and rescue.
//!
//! Roles are swapped on chain: the user escrows the dollars, the maker
//! deposits ZEC into the joint account, the user signs `ready`, the maker
//! claims the dollars by revealing `e`, and the wallet sweeps the ZEC home
//! with `±(e+z)`. Every step reads the chain first, so any can run again
//! after an interruption.
//!
//! - Every signature (`OpenReverse` excepted, which only the funding proof
//!   carries), the funding itself and the sweep home are kept in `swaps.db`
//!   before they are first sent. The driver lock spans the post; the store's
//!   writer lock never does.
//! - A funding is never proved again because an answer was lost: the kept
//!   bytes go again only while the node does not know them, before the
//!   funding deadline and while the user has not called the conversion off.
//!   A proof made before a lock, or for a record that changed, is never
//!   submitted.
//! - `ready` is signed only when the user authorizes it, never after a
//!   restart, and only before `t0` with its deadline kept before it is handed
//!   out; a kept one is only sent again while it holds, and never once a
//!   refund was posted.
//! - `z` is revealed to refund an open escrow only once no `ready` of ours
//!   can land (the chain past its deadline, or at `t0`), and a ready one only
//!   from `t1`. It is judged on one consistent read of a fresh head, again
//!   immediately before sending, and the refund is kept as posted before it
//!   goes.
//!
//! The driver runs over seams: [`ChainReader`], [`HttpTransport`],
//! [`ReverseZcash`] (the wallet's side, `WalletZcash`) and [`Clock`]. The
//! steps that need no key (pricing, going ahead, submitting a proof, a rescue
//! check) live on [`ReverseView`].

use std::path::Path;
use std::time::Duration;

use zecswap_core::{JointAccount, PublicShare, RescueAuthorization, ReverseOpen, SpendKey, Terms};
use zeroize::Zeroizing;

use super::abi::Call;
use super::deployment::{
    self, Deployment, BPS_MAX, DEFAULT_MIN_SECONDS_TO_T0, MAX_READY_WAIT_SECONDS,
    SIGNATURE_TTL_SECONDS,
};
use super::engine::{self, Activity, Clock, FundingSession, MakerChecks, OpHandle, SystemClock};
use super::evm_rpc::{
    ChainReader, EvmRpc, ReverseChainState, SwapStage, SwapState, TransactionStatus,
};
use super::funding_calls;
use super::joint::{SwapTxStatus, WalletZcash};
use super::keys::SwapKeyContext;
use super::maker_client::MakerClient;
use super::models::{
    Amount, Direction, Hex, JointAccountId, NothingSentCause, RecordDeployment, RelayerTerms,
    ReverseFundingCost, ReverseFundingRequest, ReverseFundingTerms, ReverseFundingTransaction,
    ReversePhase, ReverseQuote, ReverseReceiveEstimate, ReverseReceiveTransaction, ReverseRecord,
    StoredRecord, SwapAuthorization, SwapNote, SwapPayout, SwapRescue, ZcashTransaction,
};
use super::relayer_client::RelayerClient;
use super::store::SwapStore;
use super::swap::{
    self, find, load, pinned_relayer_terms, quote_error, require_payout_fee, save, serves, update,
    PostError, SwapCall, WindowView,
};
use super::transport::{HttpTransport, Refusal, SwapErrorCode, SwapHttpError};
use super::{fail, indices, terms, ErrorCode, PrivateUsdError, PrivateUsdNetwork, Result};
use crate::wallet::routed_http::RoutedHttp;

/// The phases that wait on the maker's ZEC, so each look syncs the joint
/// account first.
const AWAITING_DEPOSIT: [ReversePhase; 2] =
    [ReversePhase::ReceivingZec, ReversePhase::AwaitingReady];
/// `openReverse` reverts past the funding deadline: this far past it, no
/// escrow is coming.
const FUNDING_SETTLED_AFTER_SECONDS: u64 = 10 * 60;
/// The relayer must still take the reviewed fee when the proof reaches it.
const PROVING_SECONDS: u64 = 2 * 60;
/// The most calldata any funding may carry.
const MAX_FUNDING_CALLDATA_BYTES: u32 = 65_536;
/// A conversion to ZEC names whole cents: 10^(6 − 2) token base units.
pub(crate) const CENT_UNITS: u32 = 10_000;
/// How long the engine loop naps between looks at a reverse conversion.
pub(crate) const NAP: Duration = Duration::from_secs(15);

/// What the Railgun page's `reverseCost` prices a funding at: the escrow
/// `amount` and the relayer's funding `fee` on Railgun's `railgun_proxy`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FundingPrice {
    pub index: u32,
    pub amount: Amount,
    pub railgun_proxy: [u8; 20],
    pub fee: Amount,
    pub fee_expires_at: Option<u64>,
}

/// A reverse quote, kept as a draft, and what its funding is priced at.
#[derive(Clone, Debug)]
pub(crate) struct ReverseQuoted {
    pub record: ReverseRecord,
    pub price: FundingPrice,
}

/// What the Railgun page's `prepareReverse` takes, or that the funding is
/// kept already (send nothing to the page; advance instead).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FundingRequest {
    pub amount: Amount,
    pub railgun_proxy: [u8; 20],
    pub token: [u8; 20],
    /// `approve`, `openReverse`, `transfer`; none once funded.
    pub calls: Vec<Call>,
    pub relay_adapt: [u8; 20],
    pub fee: Amount,
    pub already_funded: bool,
}

/// The page's proved funding transaction and what it costs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ProvedFunding {
    pub to: String,
    pub data: String,
    pub value: String,
    pub debit: Amount,
    pub railgun_fee: Amount,
}

/// How an accept went.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ReverseAccept {
    /// The maker took the quote and the joint account is imported.
    Accepted,
    /// The maker wants a Privacy Pass token, which this build cannot pay:
    /// nothing opened, and the conversion waits, unanswered.
    TokensNeeded,
    /// The maker's last word ended the conversion before anything was paid.
    Ended(Option<NothingSentCause>),
}

/// A step's result as the engine loop takes it: a failure is a problem to
/// show after a minute, not an error.
#[derive(Clone, Debug)]
pub(crate) struct ReverseReport {
    pub record: ReverseRecord,
    pub next_poll: Duration,
    pub problem: Option<ErrorCode>,
}

/// The relayer's funding sponsorship, once it is the pinned one's.
struct Sponsored {
    terms: ReverseFundingTerms,
    fee: Amount,
    fee_expires_at: Option<u64>,
}

/// The wallet's Zcash side of a reverse conversion: the joint account the
/// maker pays, and the sweep home.
pub(crate) trait ReverseZcash {
    /// The chain's height now: a new conversion's joint account is born there.
    async fn chain_height(&self) -> Result<u64>;
    /// Imports swap `index`'s joint account at `birthday`, unless the wallet
    /// holds it already.
    async fn import_account(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
    ) -> Result<JointAccountId>;
    /// The joint account synced to the tip: what it received in transactions
    /// `confirmations` deep or more, and the most a sweep of those notes
    /// pays.
    async fn estimate_receive(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
        confirmations: u32,
    ) -> Result<ReverseReceiveEstimate>;
    /// The sweep home with the combined `key`, paying at most
    /// `max_fee_zatoshi`: an earlier one that may still land, else a new one
    /// once every note is spendable; `None` until then. Never sent.
    async fn prepare_receive(
        &self,
        index: u32,
        joint: &JointAccount,
        key: &SpendKey,
        birthday: u64,
        max_fee_zatoshi: Option<u64>,
    ) -> Result<Option<ReverseReceiveTransaction>>;
    async fn receive_status(
        &self,
        index: u32,
        joint: &JointAccount,
        birthday: u64,
        receive: &ZcashTransaction,
    ) -> Result<SwapTxStatus>;
    /// Sends a kept transaction once more.
    async fn broadcast(&self, transaction: &ZcashTransaction) -> Result<()>;
    /// Stops watching swap `index`'s joint account: nothing more comes from
    /// it.
    async fn forget(&self, index: u32) -> Result<()>;
}

// ---- the keyless view ----

/// One account's reverse conversions where no key is needed: the funding's
/// price and terms, going ahead, a proved funding's submission, and whether a
/// refund can be rescued (a chain read only).
pub(crate) struct ReverseView<'a, C, T, K>
where
    T: HttpTransport,
{
    pins: &'static Deployment,
    account: &'a str,
    chain: &'a C,
    relayer: RelayerClient<'a, T>,
    clock: &'a K,
    op: Option<&'a OpHandle>,
}

impl<'a, C, T, K> ReverseView<'a, C, T, K>
where
    C: ChainReader,
    T: HttpTransport,
    K: Clock,
{
    pub(crate) fn new(
        network: PrivateUsdNetwork,
        account: &'a str,
        chain: &'a C,
        transport: &'a T,
        clock: &'a K,
        op: Option<&'a OpHandle>,
    ) -> Self {
        let pins = deployment::deployment(network);
        Self {
            pins,
            account,
            chain,
            relayer: RelayerClient::new(transport, pins.relayer_url),
            clock,
            op,
        }
    }

    /// What the page's `reverseCost` prices swap `index`'s funding at now.
    pub(crate) async fn price(&self, store: &SwapStore, index: u32) -> Result<FundingPrice> {
        let record: ReverseRecord = load(store, self.account, index)?;
        let sponsored = self.sponsored().await?;
        Ok(FundingPrice {
            index,
            amount: record.quote.terms.amount,
            railgun_proxy: self.pins.railgun_proxy,
            fee: sponsored.fee,
            fee_expires_at: sponsored.fee_expires_at,
        })
    }

    /// Keeps the cost the page priced for the user to review: the escrow,
    /// the relayer's funding fee and Railgun's unshield fee on top
    /// (`debit = amount + fee + railgun_fee`). Only a draft, or one waiting
    /// to be paid, is priced. `FundingCostChanged` when the relayer's fee
    /// moved meanwhile: price it again.
    pub(crate) async fn set_cost(
        &self,
        store: &mut SwapStore,
        index: u32,
        debit: Amount,
        railgun_fee: Amount,
    ) -> Result<ReverseRecord> {
        let record: ReverseRecord = load(store, self.account, index)?;
        let priceable = record.phase == ReversePhase::Quoted
            || (record.phase == ReversePhase::AwaitingFunding
                && record.funding.is_none()
                && !record.cancel_requested);
        if !priceable {
            return fail(
                ErrorCode::TooLate,
                "the conversion is past paying for its funding",
            );
        }
        let sponsored = self.sponsored().await?;
        let fee = funding_fee_of(&record, debit, railgun_fee)?;
        if fee != sponsored.fee {
            return fail(
                ErrorCode::FundingCostChanged,
                "the relayer's fee changed while the cost was priced: price it again",
            );
        }
        let mut priced: ReverseRecord = load(store, self.account, index)?;
        priced.cost = Some(ReverseFundingCost {
            debit,
            railgun_fee,
            broadcaster_fee: sponsored.fee,
            fee_expires_at: sponsored.fee_expires_at,
        });
        update(store, self.account, &priced)?;
        Ok(priced)
    }

    /// The user went ahead with the reviewed draft: under way from here,
    /// though nothing is paid yet. One conversion at a time per account, in
    /// either direction.
    pub(crate) async fn go_ahead(
        &self,
        store: &mut SwapStore,
        index: u32,
    ) -> Result<ReverseRecord> {
        let record = active(store, self.account, index)?;
        if record.phase != ReversePhase::Quoted {
            return Ok(record);
        }
        if record.cost.is_none() {
            return fail(
                ErrorCode::FundingCostChanged,
                "price the conversion's funding before going ahead",
            );
        }
        swap::require_none_under_way(store, self.account)?;
        let now = self.state(&record).await?.head.timestamp;
        require_quote_holds(&record.quote, now)?;
        let mut going = record;
        going.phase = ReversePhase::Accepting;
        going.accepted_at = Some(self.clock.now());
        update(store, self.account, &going)?;
        Ok(going)
    }

    /// Checks the page's proof of the funding Rust handed it, then keeps it
    /// (`SENDING_USDC`) and posts it. Refused, with nothing kept or sent, once
    /// the user called the conversion off, the wallet locked, or the record
    /// changed while the page proved.
    pub(crate) async fn submit_funding(
        &self,
        store: &mut SwapStore,
        index: u32,
        proved: ProvedFunding,
    ) -> Result<ReverseRecord> {
        let Some(session) = engine::take_funding(self.account, index, self.pins.network) else {
            return fail(
                ErrorCode::Cancelled,
                "the funding was not prepared in this session: prove it again",
            );
        };
        let record = active(store, self.account, index)?;
        if record.cancel_requested {
            return fail(
                ErrorCode::Cancelled,
                "the conversion was called off: nothing was paid",
            );
        }
        if record != session.record {
            return fail(
                ErrorCode::TooLate,
                "the conversion changed while its payment was proved: nothing was paid",
            );
        }
        let to = Hex::<20>::parse(&proved.to).filter(|to| to.0 == session.relay_adapt);
        let Some(to) = to.filter(|_| proved.value == "0") else {
            return fail(
                ErrorCode::Mismatch,
                "unexpected funding destination or value",
            );
        };
        let data = proved.data.to_ascii_lowercase();
        let Some(length) = calldata_length(&data) else {
            return fail(ErrorCode::Mismatch, "the funding calldata is malformed");
        };
        if length > session.max_calldata_bytes {
            return fail(
                ErrorCode::Mismatch,
                "the funding exceeds the relayer's calldata limit",
            );
        }
        if funding_fee_of(&record, proved.debit, proved.railgun_fee)? != session.fee {
            return fail(ErrorCode::Mismatch, "the proof pays another relayer fee");
        }
        let cost = ReverseFundingCost {
            debit: proved.debit,
            railgun_fee: proved.railgun_fee,
            broadcaster_fee: session.fee,
            fee_expires_at: session.fee_expires_at,
        };
        if record.cost.as_ref() != Some(&cost) {
            // Nothing is paid; the new cost shows, for the user to pay or
            // cancel.
            let mut repriced = record;
            repriced.cost = Some(cost);
            update(store, self.account, &repriced)?;
            return fail(
                ErrorCode::FundingCostChanged,
                "the funding costs other than reviewed: nothing was paid",
            );
        }
        let transaction = ReverseFundingTransaction {
            tx_id: None,
            cost,
            request: ReverseFundingRequest {
                swap_id: record.swap_id,
                chain_id: self.pins.chain_id,
                to,
                data,
                value: "0".into(),
            },
        };
        // Kept before it is posted: an answer lost from here on never proves
        // a second funding.
        let mut sending = record;
        sending.funding = Some(transaction.clone());
        sending.phase = ReversePhase::SendingUsdc;
        update(store, self.account, &sending)?;
        match self.submit(store, &sending, &transaction).await {
            Ok(()) => load(store, self.account, index),
            Err(PostError::Refused(refusal)) => {
                self.reprice(store, index, &transaction, refusal).await
            }
            Err(PostError::Failed(error)) => Err(error),
        }
    }

    /// Whether swap `index`'s refund, sent back to its vault by Railgun,
    /// holds more than a rescue's relayer fee. A chain read only.
    pub(crate) async fn can_rescue(&self, store: &SwapStore, index: u32) -> Result<bool> {
        let record: ReverseRecord = load(store, self.account, index)?;
        Ok(record.phase == ReversePhase::Refunded && self.rescue_fee(&record).await?.is_some())
    }

    /// Posts a kept funding: never anything but the bytes kept, with the
    /// swap's ticket. Its hash is merged into the record as it is now, so a
    /// cancel that came meanwhile stays.
    async fn submit(
        &self,
        store: &mut SwapStore,
        record: &ReverseRecord,
        transaction: &ReverseFundingTransaction,
    ) -> std::result::Result<(), PostError> {
        let request = &transaction.request;
        if request.swap_id != record.swap_id || request.chain_id != self.pins.chain_id {
            return Err(PostError::Failed(PrivateUsdError::new(
                ErrorCode::Mismatch,
                "the kept funding is for another swap",
            )));
        }
        let terms = self.funding_terms().await.map_err(PostError::Failed)?;
        if request.to != terms.terms.relay_adapt {
            return Err(PostError::Failed(PrivateUsdError::new(
                ErrorCode::WrongDeployment,
                "the relayer funds through another adapter now",
            )));
        }
        if calldata_length(&request.data)
            .is_none_or(|length| length > terms.terms.max_calldata_bytes)
        {
            return Err(PostError::Failed(PrivateUsdError::new(
                ErrorCode::Mismatch,
                "the funding exceeds the relayer's calldata limit",
            )));
        }
        engine::set_activity(self.op, Activity::Funding);
        let sent = match self
            .relayer
            .fund_reverse(request, record.ticket.as_ref())
            .await
        {
            Ok(sent) => sent,
            Err(SwapHttpError::Refused(refusal)) => {
                // A funding the relayer refused was never sent: it waits for
                // the user to pay again.
                if refusal.code == Some(SwapErrorCode::Rejected) && transaction.tx_id.is_none() {
                    self.drop_funding(store, record.index, transaction)
                        .map_err(PostError::Failed)?;
                }
                return Err(PostError::Refused(refusal));
            }
            Err(error) => return Err(PostError::Failed(error.into())),
        };
        let current: Option<ReverseRecord> =
            find(store, self.account, record.index).map_err(PostError::Failed)?;
        if let Some(mut current) =
            current.filter(|current| current.funding.as_ref() == Some(transaction))
        {
            if current.phase == ReversePhase::SendingUsdc {
                current.phase = ReversePhase::ConfirmingEscrow;
            }
            current.funding = Some(ReverseFundingTransaction {
                tx_id: sent.transactions.first().copied().or(transaction.tx_id),
                ..transaction.clone()
            });
            update(store, self.account, &current).map_err(PostError::Failed)?;
        }
        Ok(())
    }

    fn drop_funding(
        &self,
        store: &mut SwapStore,
        index: u32,
        transaction: &ReverseFundingTransaction,
    ) -> Result<()> {
        let current: Option<ReverseRecord> = find(store, self.account, index)?;
        if let Some(mut current) =
            current.filter(|current| current.funding.as_ref() == Some(transaction))
        {
            current.funding = None;
            if !current.cancel_requested {
                current.phase = ReversePhase::AwaitingFunding;
            }
            update(store, self.account, &current)?;
        }
        Ok(())
    }

    /// After the relayer refused a funding: if it asks a higher fee now, the
    /// cost is priced again by the page before the user pays again
    /// (`FundingCostChanged`); else the refusal stands.
    async fn reprice(
        &self,
        store: &mut SwapStore,
        index: u32,
        transaction: &ReverseFundingTransaction,
        refusal: Refusal,
    ) -> Result<ReverseRecord> {
        let dropped = find::<ReverseRecord>(store, self.account, index)?
            .filter(|current| current.funding.is_none() && !current.cancel_requested);
        let Some(mut dropped) = dropped else {
            return Err(SwapHttpError::Refused(refusal).into());
        };
        let fee = self.funding_terms().await?.fee;
        if fee <= transaction.cost.broadcaster_fee {
            return Err(SwapHttpError::Refused(refusal).into());
        }
        dropped.cost = None;
        update(store, self.account, &dropped)?;
        fail(
            ErrorCode::FundingCostChanged,
            "the relayer asks a higher funding fee: nothing was paid",
        )
    }

    /// The chain as far as `record` is concerned, once the record is this
    /// deployment's and its id its quote's. An escrow must be the one this
    /// conversion funded, at its confirmation depth.
    async fn state(&self, record: &ReverseRecord) -> Result<ReverseChainState> {
        let maker_share = terms::quote_maker_share(&record.quote.terms)?;
        if record.swap_id.0 != terms::reverse_swap_id(&record.quote.user.0, &maker_share) {
            return fail(ErrorCode::Mismatch, "the conversion's id isn't its quote's");
        }
        let state = self
            .chain
            .reverse_state(&record.swap_id.0, &reverse_terms(record)?)
            .await?;
        if state.swap.is_some() {
            let funded = state.refund_note == record.quote.refund_note.0
                && (1..=state.head.number).contains(&state.funding_block);
            if !funded {
                return fail(
                    ErrorCode::Mismatch,
                    "the escrow isn't the one this conversion opened",
                );
            }
            let depth = state.head.number - state.funding_block + 1;
            if depth < u64::from(self.pins.escrow_confirmations) {
                return fail(ErrorCode::ChainLagging, "the escrow isn't confirmed");
            }
        }
        Ok(state)
    }

    /// The pinned relayer's funding sponsorship now.
    async fn funding_terms(&self) -> Result<Sponsored> {
        sponsorship(
            self.pins,
            pinned_relayer_terms(&self.relayer, self.pins).await?,
        )
    }

    /// [`Self::funding_terms`], at a fee within the cap: what a funding is
    /// priced and signed at.
    async fn sponsored(&self) -> Result<Sponsored> {
        within_cap(self.funding_terms().await?)
    }

    /// The fee a refund payout or a rescue of `amount` pays the pinned
    /// relayer now: it leaves something of the amount and is within the cap.
    async fn payout_fee(&self, amount: Amount) -> Result<Amount> {
        let fee = pinned_relayer_terms(&self.relayer, self.pins).await?.fee;
        require_payout_fee(amount, fee)?;
        Ok(fee)
    }

    /// The rescue fee, when the escrow refunded and paid out and its vault
    /// holds more than the fee.
    async fn rescue_fee(&self, record: &ReverseRecord) -> Result<Option<Amount>> {
        let refunded = self
            .state(record)
            .await?
            .swap
            .is_some_and(|swap| swap.stage == SwapStage::Refunded && swap.paid_out);
        if !refunded {
            return Ok(None);
        }
        let fee = self.payout_fee(record.quote.terms.amount).await?;
        let vault = self.chain.vault_balance(&record.swap_id.0).await?;
        Ok((vault > fee.0).then_some(fee))
    }
}

// ---- the keyed driver ----

/// One account's reverse conversions, over the seams.
pub(crate) struct Reverse<'a, C, T, Z, K>
where
    T: HttpTransport,
{
    view: ReverseView<'a, C, T, K>,
    pins: &'static Deployment,
    account: &'a str,
    keys: &'a SwapKeyContext,
    chain: &'a C,
    maker: MakerClient<'a, T>,
    zcash: &'a Z,
    clock: &'a K,
    makers: &'a MakerChecks,
    op: Option<&'a OpHandle>,
}

impl<'a, C, T, Z, K> Reverse<'a, C, T, Z, K>
where
    C: ChainReader,
    T: HttpTransport,
    Z: ReverseZcash,
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
        let network = keys.network();
        let pins = deployment::deployment(network);
        Self {
            view: ReverseView::new(network, account, chain, transport, clock, op),
            pins,
            account,
            keys,
            chain,
            maker: MakerClient::new(transport, pins.maker_url),
            zcash,
            clock,
            makers,
            op,
        }
    }

    /// The keyless steps over the same seams.
    #[cfg(test)]
    pub(crate) fn view(&self) -> &ReverseView<'a, C, T, K> {
        &self.view
    }

    // ---- quote, accept and funding ----

    /// Quotes the most that `total` private dollars (whole cents) fund, once
    /// Railgun's unshield fee (`unshield_basis_points`, as the page loads
    /// it) and the relayer's funding fee come off it, for a fresh index,
    /// which counts as spent from here on, and keeps the verified quote as a
    /// `QUOTED` draft, replacing any earlier draft. Nothing is accepted or
    /// paid; the draft is not under way.
    pub(crate) async fn quote(
        &self,
        store: &mut SwapStore,
        total: u32,
        unshield_basis_points: u32,
    ) -> Result<ReverseQuoted> {
        if total == 0 || !total.is_multiple_of(CENT_UNITS) {
            return fail(
                ErrorCode::AmountUnquotable,
                "a conversion to ZEC names a whole number of cents",
            );
        }
        if u128::from(unshield_basis_points) >= BPS_MAX {
            return fail(ErrorCode::Other, "an unshield fee of the whole amount");
        }
        self.pins.swap_contract()?;
        swap::require_none_under_way(store, self.account)?;
        swap::check_maker(&self.maker, self.pins, self.makers, true).await?;
        let contracts = [(self.chain, self.pins.maker)];
        // The relayer's terms, the index and the joint account's birthday (any
        // height before the maker's deposit) don't wait on each other: all
        // three are asked at once.
        let (relayer, index, birthday) = tokio::join!(
            pinned_relayer_terms(&self.view.relayer, self.pins),
            indices::take_index(store, &contracts, self.keys, self.account),
            self.zcash.chain_height(),
        );
        let relayer = relayer?;
        let payout_fee = relayer.fee;
        let sponsored = within_cap(sponsorship(self.pins, relayer)?)?;
        let requested = escrow_for(
            u128::from(total),
            u128::from(unshield_basis_points),
            sponsored.fee.0,
        )?;
        // A refund pays out less the relayer's fee: one it would take all of
        // could never come back.
        require_payout_fee(requested, payout_fee)?;
        let (index, birthday) = (index?, birthday?);
        let user = self.keys.auth_address(index)?;
        let note = self.keys.note(index)?.commitment();
        let quote = self
            .maker
            .quote_reverse(escrow_units(requested)?, user, note)
            .await
            .map_err(quote_error)?;
        verify_quote(self.pins, &quote, &user, &note)?;
        if quote.terms.amount != requested {
            return fail(ErrorCode::Mismatch, "the quote is for another amount");
        }
        // Building the acceptance now checks the maker's share proof.
        let acceptance = swap::acceptance(self.keys, self.pins, index, &quote.terms)?;
        let maker_share = terms::quote_maker_share(&quote.terms)?;
        let record = ReverseRecord {
            index,
            deployment: RecordDeployment::pinned(self.pins.network)?,
            swap_id: Hex(terms::reverse_swap_id(&user, &maker_share)),
            user_share: acceptance.user_share,
            acceptance,
            birthday,
            quote,
            account: None,
            phase: ReversePhase::Quoted,
            cost: None,
            funding: None,
            ready: None,
            cancel_requested: false,
            refund_posted: false,
            payout: None,
            rescue: None,
            receive: None,
            receive_estimate: None,
            receive_confirmations: 0,
            accepted_at: None,
            maker_accepted: false,
            ticket: None,
        };
        let now = self.view.state(&record).await?.head.timestamp;
        require_time_to_go_ahead(&record.quote, now)?;
        swap::require_none_under_way(store, self.account)?;
        save(store, self.account, &record)?;
        Ok(ReverseQuoted {
            price: FundingPrice {
                index,
                amount: requested,
                railgun_proxy: self.pins.railgun_proxy,
                fee: sponsored.fee,
                fee_expires_at: sponsored.fee_expires_at,
            },
            record,
        })
    }

    /// The maker's acceptance of swap `index`, once, and its joint account
    /// imported, which holds if done twice. The account is imported before
    /// anything is funded.
    pub(crate) async fn accept(&self, store: &mut SwapStore, index: u32) -> Result<ReverseAccept> {
        let record = active(store, self.account, index)?;
        if record.finished() {
            return Ok(ReverseAccept::Ended(None));
        }
        require_going_ahead(&record)?;
        self.ensure_accepted(store, &record, false).await
    }

    /// The calls the Railgun page proves for swap `index`'s funding, with
    /// the user's `OpenReverse` signed. The page must hold this account's own
    /// Railgun wallet (`page_address`), and the funding is priced: the
    /// reviewed relayer fee while the relayer still takes it, else its fee
    /// now, within the cap. Nothing is kept; the proof comes back through
    /// [`ReverseView::submit_funding`].
    pub(crate) async fn funding_request(
        &self,
        store: &mut SwapStore,
        index: u32,
        page_address: &str,
    ) -> Result<FundingRequest> {
        let session = engine::session();
        let record = active(store, self.account, index)?;
        require_going_ahead(&record)?;
        if record.funding.is_some() {
            return Ok(FundingRequest {
                amount: record.quote.terms.amount,
                railgun_proxy: self.pins.railgun_proxy,
                token: self.pins.token,
                calls: Vec::new(),
                relay_adapt: self.pins.relay_adapt,
                fee: record
                    .funding
                    .as_ref()
                    .map_or_else(Amount::default, |funding| funding.cost.broadcaster_fee),
                already_funded: true,
            });
        }
        if record.account.is_none() {
            return fail(ErrorCode::Other, "accept the conversion before funding it");
        }
        if page_address != self.keys.railgun_address()? {
            return fail(
                ErrorCode::Mismatch,
                "the Railgun page holds another wallet than this account's",
            );
        }
        let Some(reviewed) = record.cost.clone() else {
            return fail(
                ErrorCode::FundingCostChanged,
                "price the funding before paying for it",
            );
        };
        let observed = self.state(&record).await?;
        if observed.swap.is_some() {
            return fail(ErrorCode::TooLate, "its escrow is open already");
        }
        require_time_to_fund(&record.quote, observed.head.timestamp)?;
        let sponsored = self.view.sponsored().await?;
        let honored = reviewed.fee_expires_at.is_some_and(|expires_at| {
            self.clock.now().saturating_add(PROVING_SECONDS) < expires_at
        });
        let (fee, fee_expires_at) = if honored {
            (reviewed.broadcaster_fee, reviewed.fee_expires_at)
        } else {
            (sponsored.fee, sponsored.fee_expires_at)
        };
        deployment::require_within_fee_cap(fee.0)?;
        let open = reverse_open(&record)?;
        let digest = self.pins.domain()?.open_reverse(&open);
        let signature = self.keys.user_keys(index)?.auth.sign(&digest);
        let calls = funding_calls::encode(
            record.quote.terms.contract.0,
            self.pins.relayer,
            &open,
            &signature,
            fee.0,
        );
        engine::put_funding(
            self.account,
            index,
            FundingSession {
                network: self.pins.network,
                record: record.clone(),
                fee,
                fee_expires_at,
                relay_adapt: sponsored.terms.relay_adapt.0,
                max_calldata_bytes: sponsored.terms.max_calldata_bytes,
            },
            session,
        );
        Ok(FundingRequest {
            amount: record.quote.terms.amount,
            railgun_proxy: self.pins.railgun_proxy,
            token: self.pins.token,
            calls: calls.into(),
            relay_adapt: sponsored.terms.relay_adapt.0,
            fee,
            already_funded: false,
        })
    }

    // ---- advance ----

    /// One look at the chain for swap `index`, then what is due: following
    /// the funding to its escrow, the deposit, a kept `ready`, the sweep
    /// home or the refund. Never signs `ready`. The engine loop's view: a
    /// failed step is a problem, and a cancelled one an error.
    pub(crate) async fn advance_report(
        &self,
        store: &mut SwapStore,
        index: u32,
    ) -> Result<ReverseReport> {
        load::<ReverseRecord>(store, self.account, index)?;
        let step = self.advance(store, index).await;
        let step = swap::loop_outcome(self.op, Direction::Reverse, index, step)?;
        let record: ReverseRecord = load(store, self.account, index)?;
        Ok(match step {
            Ok(_) => ReverseReport {
                next_poll: if record.under_way() {
                    NAP
                } else {
                    Duration::ZERO
                },
                record,
                problem: None,
            },
            Err(problem) => ReverseReport {
                record,
                next_poll: engine::RETRY_DELAY,
                problem: Some(problem),
            },
        })
    }

    /// One look at the chain for swap `index`: whatever is due.
    pub(crate) async fn advance(&self, store: &mut SwapStore, index: u32) -> Result<ReverseRecord> {
        let snapshot: ReverseRecord = load(store, self.account, index)?;
        if !snapshot.under_way() {
            return Ok(snapshot);
        }
        engine::check_cancelled(self.op)?;
        let estimate = if AWAITING_DEPOSIT.contains(&snapshot.phase) {
            Some(self.look_at_deposit(&snapshot).await?)
        } else {
            None
        };
        let current: ReverseRecord = load(store, self.account, index)?;
        if current.under_way() {
            engine::check_cancelled(self.op)?;
            self.stage(store, &current, estimate).await?;
        }
        let current: ReverseRecord = load(store, self.account, index)?;
        if current.is_accepting() {
            engine::check_cancelled(self.op)?;
            self.ensure_accepted(store, &current, true).await?;
        }
        load(store, self.account, index)
    }

    /// The user's second approval: once the maker's whole deposit has its
    /// confirmations and the escrow is open with its signature's deadline
    /// before `t0` (judged on one consistent read of a fresh head), and no
    /// refund was posted, signs `ready` and keeps it, its deadline and the
    /// sweep's reviewed fee before posting it. A kept one is only sent again;
    /// a restart never signs one.
    pub(crate) async fn authorize_ready(
        &self,
        store: &mut SwapStore,
        index: u32,
    ) -> Result<ReverseRecord> {
        let snapshot = active(store, self.account, index)?;
        require_going_ahead(&snapshot)?;
        if snapshot.ready.is_some() {
            self.advance(store, index).await?;
            return load(store, self.account, index);
        }
        let estimate = self.look_at_deposit(&snapshot).await?.ok_or_else(|| {
            PrivateUsdError::new(
                ErrorCode::DepositUnconfirmed,
                "the maker's ZEC isn't all confirmed yet",
            )
        })?;
        let record = active(store, self.account, index)?;
        require_going_ahead(&record)?;
        if self.state(&record).await?.swap.is_none() {
            return fail(ErrorCode::DepositUnconfirmed, "the escrow isn't confirmed");
        }
        let view = self.windows(&record).await?;
        if !swap::may_sign_ready(&view, record.refund_posted, true) {
            return fail(ErrorCode::TooLate, "too late to authorize settlement");
        }
        let deadline = view.head + SIGNATURE_TTL_SECONDS;
        let digest = self.pins.domain()?.ready(&record.swap_id.0, deadline);
        let ready = SwapAuthorization {
            swap_id: record.swap_id,
            deadline,
            signature: Hex(self.keys.user_keys(index)?.auth.sign(&digest)),
        };
        let terms = reverse_terms(&record)?;
        let mut settling = record;
        settling.ready = Some(ready.clone());
        settling.phase = ReversePhase::Settling;
        settling.receive_estimate = Some(estimate);
        update(store, self.account, &settling)?;
        self.view
            .relayer
            .ready(&ready, &terms, settling.ticket.as_ref())
            .await?;
        load(store, self.account, index)
    }

    /// Calls swap `index` off: kept first, then an advance follows at once.
    /// With no escrow and no funding kept it ends `CANCELLED`; with an escrow,
    /// its refund starts. `TooLate` once settled: a settled conversion is
    /// never refunded, also if it settled during this call. An error after
    /// the flag was kept leaves it kept.
    pub(crate) async fn cancel(&self, store: &mut SwapStore, index: u32) -> Result<ReverseRecord> {
        let record = active(store, self.account, index)?;
        require_refund_possible(&record)?;
        if record.finished() {
            return Ok(record);
        }
        if !record.cancel_requested {
            let mut called_off = record;
            called_off.cancel_requested = true;
            if !matches!(
                called_off.phase,
                ReversePhase::Refunding | ReversePhase::RefundPayout
            ) {
                called_off.phase = ReversePhase::RefundWait;
            }
            update(store, self.account, &called_off)?;
        }
        let advanced = self.advance(store, index).await;
        require_refund_possible(&load(store, self.account, index)?)?;
        advanced
    }

    /// Asks the relayer to shield swap `index`'s refund, which Railgun sent
    /// back to its vault, again into this account's note: a fresh nonce and
    /// deadline signed, kept, then sent. The conversion stays finished, so it
    /// never holds up another. Nothing happens when the vault holds no more
    /// than the fee.
    pub(crate) async fn rescue(&self, store: &mut SwapStore, index: u32) -> Result<ReverseRecord> {
        let record: ReverseRecord = load(store, self.account, index)?;
        if record.phase != ReversePhase::Refunded {
            return fail(ErrorCode::Other, "only a refunded conversion is rescued");
        }
        self.check_keys(&record)?;
        let nonce = self.chain.rescue_nonce(&record.swap_id.0).await?;
        let Some(fee) = self.view.rescue_fee(&record).await? else {
            return Ok(record);
        };
        let now = swap::fresh_head(self.state(&record).await?.head.timestamp, self.clock.now())?;
        let deadline = now + SIGNATURE_TTL_SECONDS;
        let note = self.keys.note(index)?;
        let digest = self.pins.domain()?.rescue(
            &record.swap_id.0,
            &note.commitment(),
            &self.pins.relayer,
            fee.0,
            RescueAuthorization { nonce, deadline },
        );
        let rescue = SwapRescue {
            swap_id: record.swap_id,
            note: SwapNote::from(&note),
            fee,
            nonce,
            deadline,
            signature: Hex(self.keys.user_keys(index)?.auth.sign(&digest)),
        };
        let terms = reverse_terms(&record)?;
        let mut rescued = record;
        rescued.rescue = Some(rescue.clone());
        // In place: the active conversion may be a newer one.
        update(store, self.account, &rescued)?;
        self.view
            .relayer
            .rescue(&rescue, &terms, rescued.ticket.as_ref())
            .await?;
        load(store, self.account, index)
    }

    // ---- the steps of an advance ----

    /// The maker's acceptance, posted once, then the joint account imported
    /// and kept with the record. `resuming` is the loop's call, which ends a
    /// conversion the maker turns away at the token gate: this build cannot
    /// pay a token.
    async fn ensure_accepted(
        &self,
        store: &mut SwapStore,
        record: &ReverseRecord,
        resuming: bool,
    ) -> Result<ReverseAccept> {
        if record.account.is_some() {
            return Ok(ReverseAccept::Accepted);
        }
        if !record.maker_accepted {
            match self.post_accept(store, record, resuming).await? {
                ReverseAccept::Accepted => {}
                other => return Ok(other),
            }
        }
        let current: ReverseRecord = load(store, self.account, record.index)?;
        let joint = self.joint(&current)?;
        let account = self
            .zcash
            .import_account(current.index, &joint, current.birthday)
            .await?;
        let mut accepted: ReverseRecord = load(store, self.account, record.index)?;
        if accepted.account.is_none() {
            if accepted.phase == ReversePhase::Accepting {
                accepted.phase = ReversePhase::AwaitingFunding;
            }
            accepted.account = Some(account);
            update(store, self.account, &accepted)?;
        }
        Ok(ReverseAccept::Accepted)
    }

    /// Posts the kept acceptance. A refusal no other try would change ends
    /// the conversion before anything is paid; an answer that may follow an
    /// acceptance is an error, and the loop posts the same acceptance again.
    async fn post_accept(
        &self,
        store: &mut SwapStore,
        record: &ReverseRecord,
        resuming: bool,
    ) -> Result<ReverseAccept> {
        let accepted = match self
            .maker
            .accept_reverse(&record.quote.terms.quote_id, &record.acceptance)
            .await
        {
            Ok(accepted) => accepted,
            // Turned away at the token gate: a refusal sends nothing.
            Err(SwapHttpError::Refused(refusal))
                if refusal.code == Some(SwapErrorCode::TokenRequired) =>
            {
                if !resuming {
                    return Ok(ReverseAccept::TokensNeeded);
                }
                self.finish(store, record.clone(), ReversePhase::Cancelled)
                    .await?;
                return Ok(ReverseAccept::Ended(Some(
                    NothingSentCause::MakerUnavailable,
                )));
            }
            Err(SwapHttpError::Refused(refusal)) => match last_word(&refusal) {
                Some(cause) => {
                    self.finish(store, record.clone(), ReversePhase::Cancelled)
                        .await?;
                    return Ok(ReverseAccept::Ended(Some(cause)));
                }
                None => return Err(SwapHttpError::Refused(refusal).into()),
            },
            // No answer, or one that does not read: maybe accepted.
            Err(error) => return Err(error.into()),
        };
        // The maker takes the same keys again, on the quote's deadlines and
        // the contract's late window.
        let quote = &record.quote;
        let late_window = self.pins.swap_contract()?.late_window;
        let opened = accepted.swap_id == record.swap_id
            && accepted.t0 == quote.ready_deadline
            && accepted.t1 == quote.refund_after
            && accepted
                .late_window
                .is_none_or(|window| window == late_window);
        if !opened {
            self.finish(store, record.clone(), ReversePhase::Cancelled)
                .await?;
            return Ok(ReverseAccept::Ended(Some(NothingSentCause::Mismatch)));
        }
        // Its ticket goes with each relayer request for the swap, the first
        // of which, the funding, waits for this.
        let mut current: ReverseRecord = load(store, self.account, record.index)?;
        current.maker_accepted = true;
        current.ticket = accepted.ticket_for(&current.swap_id);
        update(store, self.account, &current)?;
        Ok(ReverseAccept::Accepted)
    }

    /// One step of a conversion under way, by what the chain shows of its
    /// escrow. `estimate` is the deposit as this look already found it.
    async fn stage(
        &self,
        store: &mut SwapStore,
        record: &ReverseRecord,
        estimate: Option<Option<ReverseReceiveEstimate>>,
    ) -> Result<()> {
        let observed = self.state(record).await?;
        let Some(escrow) = observed.swap.clone() else {
            return self.await_funding(store, record, &observed).await;
        };
        if escrow.stage == SwapStage::Claimed {
            // The maker revealed `e`: settled, and swept home.
            let mut settled = record.clone();
            settled.phase = ReversePhase::Receiving;
            update(store, self.account, &settled)?;
            return self.receive(store, settled, &escrow.secret).await;
        }
        if refund_due(record, &observed, &escrow) {
            return self.refund(store, record, &observed, &escrow).await;
        }
        if escrow.stage == SwapStage::Ready {
            let mut settling = record.clone();
            settling.phase = ReversePhase::Settling;
            return update(store, self.account, &settling);
        }
        if let Some(ready) = record.ready.clone() {
            // A `ready` the user signed is sent again while it holds, never
            // once a refund was posted, and never signed again after.
            let lapsed = observed.head.timestamp > ready.deadline;
            let mut current = record.clone();
            current.phase = if lapsed {
                ReversePhase::RefundWait
            } else {
                ReversePhase::Settling
            };
            update(store, self.account, &current)?;
            if !lapsed && !record.refund_posted {
                engine::check_cancelled(self.op)?;
                engine::set_activity(self.op, Activity::Readying);
                self.view
                    .relayer
                    .ready(&ready, &reverse_terms(record)?, record.ticket.as_ref())
                    .await?;
            }
            return Ok(());
        }
        let estimate = match estimate {
            Some(estimate) => estimate,
            None => self.look_at_deposit(record).await?,
        };
        self.set_deposit_phase(store, record, &observed, &escrow, estimate)
    }

    /// No escrow on the chain yet: a kept funding is followed to it, and a
    /// conversion past its funding deadline, or called off, with none ends.
    async fn await_funding(
        &self,
        store: &mut SwapStore,
        record: &ReverseRecord,
        observed: &ReverseChainState,
    ) -> Result<()> {
        let now = observed.head.timestamp;
        match record.funding.clone() {
            Some(funding) => self.await_escrow(store, record, &funding, now).await,
            None if record.cancel_requested || now >= record.quote.funding_deadline => {
                self.finish(store, record.clone(), ReversePhase::Cancelled)
                    .await
            }
            None => Ok(()),
        }
    }

    /// A kept funding with no escrow yet: called off once it reverted or is
    /// long past its deadline; followed once the node knows it; else sent
    /// again, the same bytes, only before its deadline and while the user has
    /// not called the conversion off.
    async fn await_escrow(
        &self,
        store: &mut SwapStore,
        record: &ReverseRecord,
        funding: &ReverseFundingTransaction,
        now: u64,
    ) -> Result<()> {
        let status = match &funding.tx_id {
            Some(transaction) => {
                self.chain
                    .transaction_status(&transaction.0, self.pins.escrow_confirmations)
                    .await?
            }
            None => TransactionStatus::Unknown,
        };
        let settled_after = record
            .quote
            .funding_deadline
            .saturating_add(FUNDING_SETTLED_AFTER_SECONDS);
        if status == TransactionStatus::Reverted || now > settled_after {
            return self
                .finish(store, record.clone(), ReversePhase::Cancelled)
                .await;
        }
        if status != TransactionStatus::Unknown {
            let mut confirming = record.clone();
            confirming.phase = ReversePhase::ConfirmingEscrow;
            return update(store, self.account, &confirming);
        }
        if !record.cancel_requested && now < record.quote.funding_deadline {
            engine::check_cancelled(self.op)?;
            self.view.submit(store, record, funding).await?;
        }
        Ok(())
    }

    /// The joint account synced, with the sweep's estimate once the whole
    /// deposit has the deployment's confirmations (`None` before); an
    /// estimate that leaves nothing is `Mismatch`.
    async fn look_at_deposit(
        &self,
        record: &ReverseRecord,
    ) -> Result<Option<ReverseReceiveEstimate>> {
        let joint = self.joint(record)?;
        let estimate = self
            .zcash
            .estimate_receive(
                record.index,
                &joint,
                record.birthday,
                self.pins.zcash_confirmations,
            )
            .await?;
        if estimate.available_zat < record.quote.terms.deposit_zat {
            return Ok(None);
        }
        if !estimate.is_usable() {
            return fail(ErrorCode::Mismatch, "a sweep home would bring nothing");
        }
        Ok(Some(estimate))
    }

    /// The phase of an open escrow waiting on the maker's ZEC or the user's
    /// `ready`, by the chain's view of the deposit. The maker's status API is
    /// never evidence.
    fn set_deposit_phase(
        &self,
        store: &mut SwapStore,
        record: &ReverseRecord,
        observed: &ReverseChainState,
        escrow: &SwapState,
        estimate: Option<ReverseReceiveEstimate>,
    ) -> Result<()> {
        let now = observed.head.timestamp;
        let phase = if escrow.stage != SwapStage::Open {
            ReversePhase::Settling
        } else if record.refund_posted
            || now.saturating_add(SIGNATURE_TTL_SECONDS) >= record.quote.ready_deadline
        {
            ReversePhase::RefundWait
        } else if estimate.is_some() {
            ReversePhase::AwaitingReady
        } else {
            ReversePhase::ReceivingZec
        };
        let mut current = record.clone();
        current.phase = phase;
        if phase == ReversePhase::AwaitingReady {
            current.receive_estimate = estimate;
        }
        update(store, self.account, &current)
    }

    /// The sweep home with `e + z`, capped at the reviewed fee, kept before
    /// it is first sent and sent again until it has its confirmations; then
    /// the conversion is complete and its joint account goes.
    async fn receive(
        &self,
        store: &mut SwapStore,
        record: ReverseRecord,
        secret: &[u8; 32],
    ) -> Result<()> {
        let joint = self.joint(&record)?;
        let key = swap::joint_spend_key(self.keys, record.index, &joint, secret)?;
        let (index, birthday) = (record.index, record.birthday);
        let mut current = record;

        let receive = current.receive.clone();
        let kept = swap::unexpired(
            store,
            self.account,
            &mut current,
            receive,
            async |receive| {
                self.zcash
                    .receive_status(index, &joint, birthday, &receive.transaction())
                    .await
            },
            |current| {
                // Proven never to be mined: built again.
                current.receive = None;
                current.receive_confirmations = 0;
            },
        )
        .await?;
        let (receive, status) = match kept {
            Some(kept) => kept,
            None => {
                engine::check_cancelled(self.op)?;
                engine::set_activity(self.op, Activity::Sweeping);
                let max_fee_zatoshi = current
                    .receive_estimate
                    .as_ref()
                    .map(|estimate| estimate.fee_zat);
                let Some(built) = self
                    .zcash
                    .prepare_receive(index, &joint, &key, birthday, max_fee_zatoshi)
                    .await?
                else {
                    // Not every note is spendable yet.
                    return Ok(());
                };
                // Kept before it is first sent.
                current.receive = Some(built.clone());
                current.receive_confirmations = 0;
                update(store, self.account, &current)?;
                let status = self
                    .zcash
                    .receive_status(index, &joint, birthday, &built.transaction())
                    .await?;
                (built, status)
            }
        };
        let (mined, confirmations) = match status {
            SwapTxStatus::Mined { confirmations, .. } => (true, confirmations),
            _ => (false, 0),
        };
        current.receive_confirmations = u64::from(confirmations);
        if confirmations >= self.pins.zcash_confirmations {
            return self.finish(store, current, ReversePhase::Complete).await;
        }
        update(store, self.account, &current)?;
        // Sent again until it is mined.
        if !mined {
            self.zcash.broadcast(&receive.transaction()).await?;
        }
        Ok(())
    }

    /// Getting the dollars back: paid out once refunded, else the reveal once
    /// the windows let it land.
    async fn refund(
        &self,
        store: &mut SwapStore,
        record: &ReverseRecord,
        observed: &ReverseChainState,
        escrow: &SwapState,
    ) -> Result<()> {
        let now = observed.head.timestamp;
        engine::set_activity(self.op, Activity::Refunding);
        if escrow.stage == SwapStage::Refunded && escrow.paid_out {
            return self
                .finish(store, record.clone(), ReversePhase::Refunded)
                .await;
        }
        if escrow.stage == SwapStage::Refunded {
            let payout = self
                .refund_payout(store, record.index, ReversePhase::RefundPayout)
                .await?;
            engine::check_cancelled(self.op)?;
            self.view
                .relayer
                .refund_payout(&payout, &reverse_terms(record)?, record.ticket.as_ref())
                .await?;
            return Ok(());
        }
        if escrow.stage == SwapStage::Ready && now < record.quote.refund_after {
            return self.wait_to_refund(store, record.index);
        }
        self.reveal(store, record).await
    }

    /// Reveals `z` once the windows let the refund land, never on a relayer's
    /// answer, an old observation or a lagging head: judged on one consistent
    /// read, and again on one taken immediately before the reveal. While a
    /// `ready` of ours may still land, it waits. The refund is kept as posted
    /// before it goes, and no `ready` is signed or sent after it.
    async fn reveal(&self, store: &mut SwapStore, record: &ReverseRecord) -> Result<()> {
        if !self.refund_lands(store, record.index).await? {
            return self.wait_to_refund(store, record.index);
        }
        // Signed when it goes out, and kept first.
        let payout = self
            .refund_payout(store, record.index, ReversePhase::Refunding)
            .await?;
        engine::check_cancelled(self.op)?;
        let secret = Zeroizing::new(self.keys.user_keys(record.index)?.share.to_be_bytes());
        if !self.refund_lands(store, record.index).await? {
            return self.wait_to_refund(store, record.index);
        }
        let mut posting: ReverseRecord = load(store, self.account, record.index)?;
        posting.refund_posted = true;
        update(store, self.account, &posting)?;
        self.view
            .relayer
            .refund(
                &secret,
                &payout,
                &reverse_terms(record)?,
                record.ticket.as_ref(),
            )
            .await?;
        Ok(())
    }

    /// Whether swap `index`'s refund lands now, past every `ready` its record
    /// signed.
    async fn refund_lands(&self, store: &SwapStore, index: u32) -> Result<bool> {
        let record: ReverseRecord = load(store, self.account, index)?;
        let view = self.windows(&record).await?;
        Ok(swap::may_refund(&view, &record.ready_deadlines()))
    }

    fn wait_to_refund(&self, store: &mut SwapStore, index: u32) -> Result<()> {
        let mut waiting: ReverseRecord = load(store, self.account, index)?;
        waiting.phase = ReversePhase::RefundWait;
        update(store, self.account, &waiting)
    }

    /// `record`'s escrow on one consistent read of a fresh head, as its
    /// windows judge it.
    async fn windows(&self, record: &ReverseRecord) -> Result<WindowView> {
        let read = self
            .chain
            .read_swap(&record.swap_id.0, &reverse_terms(record)?)
            .await?;
        let device_now = self.clock.now();
        Ok(WindowView {
            stage: read.swap.as_ref().map(|swap| swap.stage),
            head: swap::fresh_head(read.head.timestamp, device_now)?,
            head_number: read.head.number,
            device_now,
            t0: record.quote.ready_deadline,
            t1: record.quote.refund_after,
            late_window: self.pins.swap_contract()?.late_window,
        })
    }

    /// The refund's payout at the relayer's fee now: the kept one while its
    /// fee is that fee, else one signed now; kept, with `phase`, before it is
    /// sent.
    async fn refund_payout(
        &self,
        store: &mut SwapStore,
        index: u32,
        phase: ReversePhase,
    ) -> Result<SwapPayout> {
        let record: ReverseRecord = load(store, self.account, index)?;
        let fee = self.view.payout_fee(record.quote.terms.amount).await?;
        let note = SwapNote::from(&self.keys.note(index)?);
        let payout = match &record.payout {
            Some(saved) if saved.fee == fee => saved.clone(),
            _ => {
                let digest =
                    self.pins
                        .domain()?
                        .refund_payout(&record.swap_id.0, &self.pins.relayer, fee.0);
                SwapPayout {
                    swap_id: record.swap_id,
                    note: note.clone(),
                    fee,
                    signature: Hex(self.keys.user_keys(index)?.auth.sign(&digest)),
                }
            }
        };
        if payout.swap_id != record.swap_id || payout.note != note {
            return fail(
                ErrorCode::Mismatch,
                "the kept refund payout is for another swap",
            );
        }
        let mut paying = record;
        paying.payout = Some(payout.clone());
        paying.phase = phase;
        update(store, self.account, &paying)?;
        Ok(payout)
    }

    // ---- helpers ----

    /// Ends the conversion with `phase`, then stops watching its joint
    /// account (best effort: deleting the account or a reset removes what is
    /// left).
    async fn finish(
        &self,
        store: &mut SwapStore,
        record: ReverseRecord,
        phase: ReversePhase,
    ) -> Result<()> {
        let index = record.index;
        let mut ended = record;
        ended.phase = phase;
        update(store, self.account, &ended)?;
        if let Err(error) = self.zcash.forget(index).await {
            log::warn!(
                "private usd: forgetting a reverse joint account failed ({:?})",
                error.code
            );
        }
        Ok(())
    }

    /// The chain as far as `record` is concerned, once its quote, ids and
    /// share are this account's keys'.
    async fn state(&self, record: &ReverseRecord) -> Result<ReverseChainState> {
        self.check_keys(record)?;
        self.view.state(record).await
    }

    fn check_keys(&self, record: &ReverseRecord) -> Result<()> {
        let user = self.keys.auth_address(record.index)?;
        let note = self.keys.note(record.index)?.commitment();
        verify_quote(self.pins, &record.quote, &user, &note)?;
        if record.user_share.0 != self.keys.user_share(record.index)?.to_affine_bytes() {
            return fail(
                ErrorCode::Mismatch,
                "the conversion's share isn't its keys'",
            );
        }
        Ok(())
    }

    /// Swap `index`'s joint account, from the quote's maker share (its proof
    /// verified at quote; the escrow's terms, which the chain checks, carry
    /// the same share).
    fn joint(&self, record: &ReverseRecord) -> Result<JointAccount> {
        self.keys.joint(
            record.index,
            &terms::quote_maker_share(&record.quote.terms)?,
        )
    }
}

// ---- rules ----

/// A reverse quote this deployment's maker gave for `user`, refunding into
/// our own `note`.
fn verify_quote(
    pins: &Deployment,
    quote: &ReverseQuote,
    user: &[u8; 20],
    note: &[u8; 32],
) -> Result<()> {
    quote
        .check_well_formed()
        .map_err(|message| PrivateUsdError::new(ErrorCode::Mismatch, message))?;
    if !serves(pins, &quote.terms) {
        return fail(
            ErrorCode::WrongDeployment,
            "the quote is for another deployment",
        );
    }
    if quote.user.0 != *user || quote.refund_note.0 != *note || *note == [0; 32] {
        return fail(ErrorCode::Mismatch, "the quote refunds someone else");
    }
    // An escrow funded at its deadline must still leave the contract's least
    // window before `t0`, and `t1` that window after `t0`, or `openReverse`
    // refuses it.
    let min_window = pins.swap_contract()?.min_window;
    if quote.ready_deadline - quote.funding_deadline < min_window
        || quote.refund_after - quote.ready_deadline < min_window
    {
        return fail(
            ErrorCode::Mismatch,
            "the quote's deadlines leave less than the contract's window",
        );
    }
    Ok(())
}

/// The pinned relayer's funding sponsorship in `terms`: through the pinned
/// Relay Adapt, for the pinned token and maker, at a fee.
fn sponsorship(pins: &Deployment, terms: RelayerTerms) -> Result<Sponsored> {
    // Terms without a fee predate paid sponsorship, which the relayer would
    // refuse.
    let Some(funding) = terms
        .reverse_funding
        .filter(|funding| funding.fee.is_some())
    else {
        return fail(
            ErrorCode::Unavailable,
            "the relayer sponsors no funding of conversions to ZEC now",
        );
    };
    let pinned = funding.relay_adapt.0 == pins.relay_adapt
        && funding.token.0 == pins.token
        && funding.maker.0 == pins.maker;
    if !pinned {
        return fail(
            ErrorCode::WrongDeployment,
            "the funding terms name another deployment",
        );
    }
    let limits = funding.max_gas_limit > 0
        && (1..=MAX_FUNDING_CALLDATA_BYTES).contains(&funding.max_calldata_bytes)
        && is_gas_price(&funding.max_gas_price_wei);
    if !limits {
        return fail(ErrorCode::WrongDeployment, "unreadable funding limits");
    }
    Ok(Sponsored {
        fee: funding.fee.expect("checked above"),
        terms: funding,
        fee_expires_at: terms.fee_expires_at,
    })
}

fn within_cap(sponsored: Sponsored) -> Result<Sponsored> {
    deployment::require_within_fee_cap(sponsored.fee.0)?;
    Ok(sponsored)
}

/// The most whole cents a debit of at most `total` puts in escrow: Railgun's
/// unshield fee comes off the debit, as the page's `fundingAmounts` takes it
/// (the escrow and the relayer's `funding_fee` get `total × (10000 − bps) /
/// 10000` at most), then the funding fee. `AmountUnquotable` when the fees
/// take it all.
pub(crate) fn escrow_for(
    total: u128,
    unshield_basis_points: u128,
    funding_fee: u128,
) -> Result<Amount> {
    let cent = u128::from(CENT_UNITS);
    let funded = total * (BPS_MAX - unshield_basis_points) / BPS_MAX;
    match funded
        .checked_sub(funding_fee)
        .map(|escrow| escrow / cent * cent)
    {
        Some(escrow) if escrow > 0 => Ok(Amount(escrow)),
        _ => fail(
            ErrorCode::AmountUnquotable,
            "the fees take all of this amount",
        ),
    }
}

/// [`escrow_for`]'s amount as the maker's quote names it.
fn escrow_units(escrow: Amount) -> Result<u32> {
    u32::try_from(escrow.0)
        .map_err(|_| PrivateUsdError::new(ErrorCode::AmountUnquotable, "more than one quote names"))
}

/// The conversion is under way and waiting on the user, not called off.
fn require_going_ahead(record: &ReverseRecord) -> Result<()> {
    if record.is_draft() {
        return fail(ErrorCode::Other, "go ahead with the quote first");
    }
    if !record.under_way() || record.cancel_requested {
        return fail(
            ErrorCode::TooLate,
            "the conversion was called off or has ended",
        );
    }
    Ok(())
}

/// A settled conversion is never refunded.
fn require_refund_possible(record: &ReverseRecord) -> Result<()> {
    if record.is_settled() {
        return fail(
            ErrorCode::TooLate,
            "the conversion has already settled and can no longer be refunded",
        );
    }
    Ok(())
}

fn require_quote_holds(quote: &ReverseQuote, now: u64) -> Result<()> {
    if now >= quote.terms.expires_at || now >= quote.funding_deadline {
        return fail(ErrorCode::QuoteExpired, "the quote ran out");
    }
    Ok(())
}

/// The quote holds, and its deadlines leave time to fund and authorize
/// settlement, and no more than a day of escrow.
fn require_time_to_go_ahead(quote: &ReverseQuote, now: u64) -> Result<()> {
    require_quote_holds(quote, now)?;
    if quote.ready_deadline <= now.saturating_add(DEFAULT_MIN_SECONDS_TO_T0) {
        return fail(
            ErrorCode::TooLate,
            "the maker's deadlines leave too little time",
        );
    }
    if quote.refund_after > now.saturating_add(MAX_READY_WAIT_SECONDS) {
        return fail(ErrorCode::Mismatch, "the maker's deadlines are too far off");
    }
    Ok(())
}

fn require_time_to_fund(quote: &ReverseQuote, now: u64) -> Result<()> {
    if now >= quote.funding_deadline
        || quote.ready_deadline <= now.saturating_add(DEFAULT_MIN_SECONDS_TO_T0)
    {
        return fail(ErrorCode::QuoteExpired, "too late to fund it");
    }
    Ok(())
}

/// Called off, refunded, or past the deadline of the stage its escrow is in.
fn refund_due(record: &ReverseRecord, observed: &ReverseChainState, escrow: &SwapState) -> bool {
    let now = observed.head.timestamp;
    record.cancel_requested
        || match escrow.stage {
            SwapStage::Refunded => true,
            SwapStage::Ready => now >= record.quote.refund_after,
            SwapStage::Open => now >= record.quote.ready_deadline,
            SwapStage::Claimed => false,
        }
}

/// The relayer fee a priced or proved funding of `record` pays: the page
/// unshields the escrow and the fee, and Railgun's own fee on top
/// (`debit = amount + fee + railgun_fee`).
fn funding_fee_of(record: &ReverseRecord, debit: Amount, railgun_fee: Amount) -> Result<Amount> {
    debit
        .0
        .checked_sub(railgun_fee.0)
        .and_then(|escrow| escrow.checked_sub(record.quote.terms.amount.0))
        .map(Amount)
        .ok_or_else(|| {
            PrivateUsdError::new(
                ErrorCode::Mismatch,
                "the funding's cost does not cover its escrow",
            )
        })
}

/// A maker's refusal no other accept would change, and how it ended the
/// conversion; `None` for one that may follow an acceptance.
fn last_word(refusal: &Refusal) -> Option<NothingSentCause> {
    match refusal.code? {
        SwapErrorCode::Unavailable | SwapErrorCode::WatchtowerUnavailable => {
            Some(NothingSentCause::MakerUnavailable)
        }
        SwapErrorCode::UnknownQuote => Some(NothingSentCause::QuoteExpired),
        SwapErrorCode::TokenRequired => Some(NothingSentCause::MakerUnavailable),
        SwapErrorCode::Rejected
        | SwapErrorCode::InvalidRequest
        | SwapErrorCode::UnknownSwap
        | SwapErrorCode::NotFound
        | SwapErrorCode::MethodNotAllowed => Some(NothingSentCause::MakerRefused),
        SwapErrorCode::Internal | SwapErrorCode::AlreadySpent | SwapErrorCode::Conflict => None,
    }
}

/// What `openReverse` opens the escrow with, and what the user signs, in the
/// contract's order.
fn reverse_open(record: &ReverseRecord) -> Result<ReverseOpen> {
    let quote = &record.quote;
    Ok(ReverseOpen {
        maker: quote.terms.maker.0,
        user: quote.user.0,
        token: quote.terms.token.0,
        amount: quote.terms.amount.0,
        maker_share: terms::quote_maker_share(&quote.terms)?,
        user_share: PublicShare::from_affine_bytes(&record.user_share.0).map_err(|_| {
            PrivateUsdError::new(ErrorCode::Mismatch, "the kept share is not a valid point")
        })?,
        t0: quote.ready_deadline,
        t1: quote.refund_after,
        refund_note: quote.refund_note.0,
        deadline: quote.funding_deadline,
    })
}

/// What the escrow's contract keeps: the swapped-role terms `openReverse`
/// stores, the escrowing user as their `maker` and the ZEC maker as their
/// `user`.
pub(crate) fn reverse_terms(record: &ReverseRecord) -> Result<Terms> {
    Ok(reverse_open(record)?.terms())
}

/// Calldata's length in bytes, when it is `0x` and whole bytes of hex,
/// between a selector and the most any funding carries.
fn calldata_length(data: &str) -> Option<u32> {
    let digits = data.strip_prefix("0x")?;
    let length = u32::try_from(digits.len() / 2).ok()?;
    (digits.len() % 2 == 0
        && (4..=MAX_FUNDING_CALLDATA_BYTES).contains(&length)
        && digits.bytes().all(|b| b.is_ascii_hexdigit()))
    .then_some(length)
}

/// A positive decimal gas price that fits `uint128`.
fn is_gas_price(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= 39
        && text.bytes().all(|b| b.is_ascii_digit())
        && text.parse::<u128>().is_ok_and(|price| price > 0)
}

// ---- the store ----

/// Swap `index`, when it is the account's active reverse conversion.
fn active(store: &SwapStore, account: &str, index: u32) -> Result<ReverseRecord> {
    match store.active(account, Direction::Reverse)? {
        Some(StoredRecord::Reverse(record)) if record.index == index => Ok(*record),
        _ => fail(ErrorCode::Other, "the conversion isn't the active one"),
    }
}

// ---- over the real seams ----

/// A reverse driver over the real seams.
pub(crate) type WalletReverse<'a> =
    Reverse<'a, EvmRpc<'a, RoutedHttp>, RoutedHttp, WalletZcash<'a>, SystemClock>;

/// The keyless steps over the real seams.
pub(crate) type WalletReverseView<'a> =
    ReverseView<'a, EvmRpc<'a, RoutedHttp>, RoutedHttp, SystemClock>;

impl SwapCall<'_> {
    /// Runs `step` on a reverse driver over routed HTTP (one transport per
    /// call), the pinned contract, the wallet DBs and `swaps.db`. With `op`,
    /// its cancel flag stops requests and joint scans.
    pub(crate) async fn reverse<R>(
        &self,
        op: Option<&OpHandle>,
        step: impl AsyncFnOnce(&WalletReverse<'_>, &mut SwapStore) -> Result<R>,
    ) -> Result<R> {
        let transport = swap::transport(op);
        let chain = EvmRpc::new(&transport, self.pins(), self.eth_rpc_url);
        let zcash = self.zcash(op);
        let reverse = Reverse::new(
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
        step(&reverse, &mut store).await
    }
}

/// Runs a keyless `step` over the pinned contract and relayer and
/// `swaps.db`; no key is needed. `None` when the wallet never converted
/// (nothing is created by asking).
pub(crate) async fn run_view<R>(
    store_dir: &Path,
    network: PrivateUsdNetwork,
    eth_rpc_url: &str,
    account: &str,
    step: impl AsyncFnOnce(&WalletReverseView<'_>, &mut SwapStore) -> Result<R>,
) -> Result<Option<R>> {
    let Some(mut store) = SwapStore::open_existing(store_dir)? else {
        return Ok(None);
    };
    let transport = RoutedHttp::new();
    let chain = EvmRpc::new(&transport, deployment::deployment(network), eth_rpc_url);
    let view = ReverseView::new(network, account, &chain, &transport, &SystemClock, None);
    step(&view, &mut store).await.map(Some)
}
