//! Swap records and wire shapes, in the swap services' JSON.
//!
//! The shapes are camelCase, with nulls and defaults not written and fields
//! in declaration order. Ids, shares and addresses read in either case and
//! are written lowercase; token amounts are decimal strings. Wire answers
//! ignore unknown fields. Stored records decode strictly ([`decode_strict`]):
//! one this build would not write back unchanged is an error, never a reset.

use std::fmt;

use serde::{de, de::DeserializeOwned, Deserialize, Deserializer, Serialize, Serializer};

use super::abi::hex0x;
use super::deployment::{self, MAX_READY_WAIT_SECONDS};
use super::PrivateUsdNetwork;

/// The most zatoshi there will ever be.
pub(crate) const MAX_ZATOSHI: u64 = 2_100_000_000_000_000;
/// Token amounts fit the contract's `uint120`.
const SWAP_AMOUNT_BITS: u32 = 120;

/// `0x` and `N` bytes of hex, either case; written lowercase.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct Hex<const N: usize>(pub [u8; N]);

pub(crate) type Address = Hex<20>;
/// A swap id, note commitment, Ethereum transaction hash or other 32-byte word.
pub(crate) type Word = Hex<32>;
/// A Pallas point `x ‖ y`, a share proof or viewing keys.
pub(crate) type Bytes64 = Hex<64>;
/// `r ‖ s ‖ v`.
pub(crate) type Signature = Hex<65>;

impl<const N: usize> Hex<N> {
    pub(crate) fn parse(text: &str) -> Option<Self> {
        let digits = text.strip_prefix("0x")?;
        if digits.len() != 2 * N {
            return None;
        }
        let mut bytes = [0u8; N];
        hex::decode_to_slice(digits, &mut bytes).ok()?;
        Some(Self(bytes))
    }

    pub(crate) fn to_hex(self) -> String {
        hex0x(&self.0)
    }
}

impl<const N: usize> fmt::Debug for Hex<N> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_hex())
    }
}

impl<const N: usize> Serialize for Hex<N> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_hex())
    }
}

impl<'de, const N: usize> Deserialize<'de> for Hex<N> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        // The value is never echoed: it may be a secret.
        Self::parse(&text)
            .ok_or_else(|| de::Error::custom(format!("expected 0x and {N} bytes of hex")))
    }
}

/// A token amount in base units, a decimal string on the wire (`Usdc6`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct Amount(pub u128);

impl Amount {
    /// Fits the contract's `uint120` amounts, and is positive where it moves
    /// something.
    pub(crate) fn is_swap_amount(self, positive: bool) -> bool {
        (!positive || self.0 > 0) && self.0 < 1u128 << SWAP_AMOUNT_BITS
    }
}

impl Serialize for Amount {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0.to_string())
    }
}

impl<'de> Deserialize<'de> for Amount {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
            return Err(de::Error::custom("expected a decimal amount"));
        }
        text.parse()
            .map(Amount)
            .map_err(|_| de::Error::custom("amount out of range"))
    }
}

/// A Zcash transaction id as wallets show it: the 32 bytes reversed, in
/// lowercase hex, no prefix.
#[derive(Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub(crate) struct ZcashTxId(String);

impl ZcashTxId {
    pub(crate) fn parse(text: &str) -> Option<Self> {
        (text.len() == 64 && text.bytes().all(|b| b.is_ascii_hexdigit()))
            .then(|| Self(text.to_ascii_lowercase()))
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ZcashTxId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for ZcashTxId {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Self::parse(&text).ok_or_else(|| de::Error::custom("expected a Zcash transaction id"))
    }
}

/// A joint account's UUID, as a record keeps it: its 16 bytes in hex.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct JointAccountId(pub [u8; 16]);

impl fmt::Debug for JointAccountId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&hex::encode(self.0))
    }
}

impl Serialize for JointAccountId {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&hex::encode(self.0))
    }
}

impl<'de> Deserialize<'de> for JointAccountId {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        let mut bytes = [0u8; 16];
        hex::decode_to_slice(&text, &mut bytes)
            .map(|()| Self(bytes))
            .map_err(|_| de::Error::custom("expected an account id"))
    }
}

/// A value kept out of `Debug`; it serializes as itself.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub(crate) struct Redacted<T>(pub T);

impl<T> fmt::Debug for Redacted<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

/// The maker's ticket for a swap: an allowance at the relayer's gateway for
/// whoever holds it. Never logged.
pub(crate) type Ticket = Redacted<String>;

pub(crate) fn is_false(value: &bool) -> bool {
    !*value
}

pub(crate) fn is_zero(value: &u64) -> bool {
    *value == 0
}

/// `value` is `0x` and exactly `bytes` bytes of hex.
pub(crate) fn is_fixed_hex(value: &str, bytes: usize) -> bool {
    value.len() == 2 + 2 * bytes
        && value.starts_with("0x")
        && value[2..].bytes().all(|b| b.is_ascii_hexdigit())
}

// ---- wire ----

/// A maker's quote, and a reverse quote's terms. The id and proof are sent
/// back as they came.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SwapQuote {
    pub quote_id: String,
    pub maker: Address,
    pub maker_share: Bytes64,
    pub maker_proof: String,
    pub chain_id: u64,
    pub contract: Address,
    pub token: Address,
    pub amount: Amount,
    pub deposit_zat: u64,
    pub expires_at: u64,
    /// The maker's own gas and Zcash fee this quote charges.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_cost: Option<Amount>,
}

impl SwapQuote {
    pub(crate) fn check_well_formed(&self) -> Result<(), String> {
        if !is_fixed_hex(&self.quote_id, 32) || !is_fixed_hex(&self.maker_proof, 64) {
            return Err("the quote's id or proof is malformed".into());
        }
        if !self.amount.is_swap_amount(true)
            || !self
                .network_cost
                .is_none_or(|cost| cost.is_swap_amount(false))
        {
            return Err("the quote's amount is invalid".into());
        }
        if !(1..=MAX_ZATOSHI).contains(&self.deposit_zat) || self.expires_at == 0 {
            return Err("the quote's terms are empty".into());
        }
        Ok(())
    }

    pub(crate) fn quote_id_bytes(&self) -> Option<[u8; 32]> {
        Hex::<32>::parse(&self.quote_id).map(|id| id.0)
    }

    pub(crate) fn maker_proof_bytes(&self) -> Option<[u8; 64]> {
        Hex::<64>::parse(&self.maker_proof).map(|proof| proof.0)
    }
}

/// `POST /v1/reverse/quote`'s answer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReverseQuote {
    pub terms: SwapQuote,
    pub user: Address,
    pub refund_note: Word,
    pub funding_deadline: u64,
    pub ready_deadline: u64,
    pub refund_after: u64,
}

impl ReverseQuote {
    pub(crate) fn check_well_formed(&self) -> Result<(), String> {
        self.terms.check_well_formed()?;
        if !(0 < self.funding_deadline
            && self.funding_deadline < self.ready_deadline
            && self.ready_deadline < self.refund_after)
        {
            return Err("the quote's deadlines are out of order".into());
        }
        if self.refund_after - self.funding_deadline > MAX_READY_WAIT_SECONDS {
            return Err("the quote's deadlines are too far apart".into());
        }
        Ok(())
    }
}

/// A quote accepted: our share, its proof, and the viewing keys the maker
/// watches the deposit with.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SwapAcceptance {
    pub user_share: Bytes64,
    pub user_proof: Bytes64,
    pub viewing_keys: Redacted<Bytes64>,
    /// On an accept a token pays for: the blinded request for it back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_request: Option<Redacted<String>>,
}

/// A `ready` the swap's own key signed, for a relayer to send.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SwapAuthorization {
    pub swap_id: Word,
    pub deadline: u64,
    pub signature: Signature,
}

/// The Railgun note a payout shields to.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SwapNote {
    pub npk: Word,
    pub encrypted_bundle: [Word; 3],
    pub shield_key: Word,
}

impl From<&zecswap_railgun::ShieldNote> for SwapNote {
    fn from(note: &zecswap_railgun::ShieldNote) -> Self {
        Self {
            npk: Hex(note.npk),
            encrypted_bundle: note.ciphertext.encrypted_bundle.map(Hex),
            shield_key: Hex(note.ciphertext.shield_key),
        }
    }
}

/// A payout into Railgun, paying the relayer at most `fee`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SwapPayout {
    pub swap_id: Word,
    pub note: SwapNote,
    pub fee: Amount,
    pub signature: Signature,
}

/// One approval to rescue returned funds, bounded in time.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SwapRescue {
    pub swap_id: Word,
    pub note: SwapNote,
    pub fee: Amount,
    pub nonce: u64,
    pub deadline: u64,
    pub signature: Signature,
}

/// The Zcash network a maker takes deposits on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum SwapZcashNetwork {
    Mainnet,
    Testnet,
}

impl From<PrivateUsdNetwork> for SwapZcashNetwork {
    fn from(network: PrivateUsdNetwork) -> Self {
        match network {
            PrivateUsdNetwork::Mainnet => Self::Mainnet,
            PrivateUsdNetwork::Testnet => Self::Testnet,
        }
    }
}

/// `GET /v1/info`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MakerInfo {
    pub api_version: u32,
    pub maker: Address,
    pub chain_id: u64,
    pub contract: Address,
    pub token: Address,
    pub zcash_network: SwapZcashNetwork,
    pub reverse_enabled: bool,
    /// The key accepts' tokens come back under, base64url SPKI.
    pub token_return_key: Option<String>,
}

/// The swap a maker opened for an accepted quote, with the deadlines it
/// picked.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SwapAccepted {
    pub swap_id: Word,
    pub t0: u64,
    pub t1: u64,
    pub ticket: Option<Ticket>,
    /// The contract's `LATE_WINDOW`, where the maker names it.
    pub late_window: Option<u64>,
}

impl SwapAccepted {
    /// The ticket, if it is `swap_id`'s (it starts with the id and a dot) and
    /// a header can carry it as it came.
    pub(crate) fn ticket_for(&self, swap_id: &Word) -> Option<Ticket> {
        let ticket = &self.ticket.as_ref()?.0;
        (ticket.starts_with(&format!("{}.", swap_id.to_hex()))
            && ticket.bytes().all(|b| (b'!'..=b'~').contains(&b)))
        .then(|| Redacted(ticket.clone()))
    }
}

/// `GET /v1/terms`.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RelayerTerms {
    pub relayer: Address,
    pub chain_id: u64,
    pub contract: Address,
    /// The contract's `MIN_WINDOW`, `LATE_WINDOW` and kind, where the relayer
    /// names them.
    pub min_window: Option<u64>,
    pub late_window: Option<u64>,
    pub contract_kind: Option<String>,
    pub fee: Amount,
    pub reverse_funding: Option<ReverseFundingTerms>,
    pub railgun_sends: Option<RailgunSendsTerms>,
    pub fee_expires_at: Option<u64>,
    /// Absent when the relayer takes no deposits. Kept unparsed here, so a
    /// deposits part this build cannot read never fails the terms the swaps
    /// and sends need; `deposits::pinned_terms` reads and checks it.
    #[serde(default)]
    pub deposits: Option<serde_json::Value>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReverseFundingTerms {
    pub relay_adapt: Address,
    pub token: Address,
    pub maker: Address,
    pub max_gas_limit: u64,
    pub max_gas_price_wei: String,
    pub max_calldata_bytes: u32,
    pub fee: Option<Amount>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RailgunSendsTerms {
    pub railgun_address: String,
    pub railgun_proxy: Address,
    pub token: Address,
    pub fee: Amount,
    pub fee_per_unit_gas: Option<String>,
    pub fee_expires_at: Option<u64>,
    pub max_gas_limit: u64,
    pub max_gas_price_wei: String,
    pub max_calldata_bytes: u32,
}

/// A proved Railgun transaction for the relayer to send as it is
/// (`POST /v1/railgun/transact`): exactly these four fields, `data` in
/// lowercase hex.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RailgunTransactRequest {
    pub chain_id: u64,
    pub to: Address,
    pub data: String,
    pub value: String,
}

/// Redacted: `data` is the proof.
impl fmt::Debug for RailgunTransactRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RailgunTransactRequest")
            .field("chain_id", &self.chain_id)
            .field("to", &self.to)
            .field("data_chars", &self.data.len())
            .finish_non_exhaustive()
    }
}

/// The transactions a relayer request sent, in order.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(crate) struct Sent {
    pub transactions: Vec<Word>,
}

/// A swap's terms as relayer requests carry them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WireTerms {
    pub maker: Address,
    pub token: Address,
    pub amount: Amount,
    pub maker_key: Bytes64,
    pub user_key: Bytes64,
    pub user: Address,
    pub t0: u64,
    pub t1: u64,
    pub payout_note: Word,
}

impl From<&zecswap_core::Terms> for WireTerms {
    fn from(terms: &zecswap_core::Terms) -> Self {
        Self {
            maker: Hex(terms.maker),
            token: Hex(terms.token),
            amount: Amount(terms.amount),
            maker_key: Hex(terms.maker_share.to_affine_bytes()),
            user_key: Hex(terms.user_share.to_affine_bytes()),
            user: Hex(terms.user),
            t0: terms.t0,
            t1: terms.t1,
            payout_note: Hex(terms.payout_note),
        }
    }
}

// ---- forward record ----

/// A transaction the wallet created for a swap, kept so it can be sent again
/// until it is mined.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ZcashTransaction {
    pub tx_id: ZcashTxId,
    /// The transaction's bytes, in hex.
    pub raw: String,
    pub expiry_height: u64,
}

impl fmt::Debug for ZcashTransaction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ZcashTransaction({:?})", self.tx_id)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub(crate) enum RefundCause {
    MakerCancelled,
    NotClaimedInTime,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub(crate) enum NothingSentCause {
    QuoteExpired,
    MakerRefused,
    MakerUnavailable,
    NeverOpened,
    Mismatch,
    DepositWindowMissed,
    MakerCancelled,
}

/// How a forward swap ended.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub(crate) enum ForwardOutcome {
    #[serde(rename = "paid")]
    Paid,
    /// The deposit came home in `sweep_tx_id`.
    #[serde(rename = "refunded", rename_all = "camelCase")]
    Refunded {
        sweep_tx_id: ZcashTxId,
        cause: RefundCause,
    },
    /// Over before any ZEC left the wallet.
    #[serde(rename = "nothing_sent")]
    NothingSent { cause: NothingSentCause },
}

/// How far a forward swap's deposit got. It is marked started before it is
/// created, so an interrupted one is never paid twice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DepositProgress<'a> {
    NotStarted,
    /// Started, with no transaction known: an interruption may have cut it
    /// short.
    Started,
    Kept(&'a ZcashTransaction),
}

/// What the app keeps about a forward swap it accepted. Its keys derive from
/// the seed and `index` again.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ForwardRecord {
    pub index: u32,
    pub quote: SwapQuote,
    pub swap_id: Word,
    /// The Zcash height read before accepting: the joint account's birthday.
    pub zcash_height: u64,
    /// Unix seconds on this device's clock.
    pub accepted_at: u64,
    /// Expected net payout; replaced by the confirmed event's at the end.
    pub receives: Amount,
    pub relayer_fee: Amount,
    #[serde(default, skip_serializing_if = "is_false")]
    pub deposit_attempted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<ForwardOutcome>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<u64>,
    /// The Ethereum transaction that shielded the payout.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payout_tx: Option<Word>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_total_zat: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deposit: Option<ZcashTransaction>,
    /// A refund's sweep home, kept before it is first sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sweep: Option<ZcashTransaction>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payout: Option<SwapPayout>,
    /// A claim was posted, `z` with it: kept before it goes.
    #[serde(default, skip_serializing_if = "is_false")]
    pub claim_posted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub t0: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub t1: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fee_expires_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ticket: Option<Ticket>,
}

/// Where a forward swap stands, by what its record keeps: the stage while
/// under way, the outcome once it ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ForwardPhase {
    Opening,
    Depositing,
    Confirming,
    Claiming,
    Refunding,
    Paid,
    Refunded,
    NothingSent,
}

impl ForwardPhase {
    /// The store's `phase` column.
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Opening => "OPENING",
            Self::Depositing => "DEPOSITING",
            Self::Confirming => "CONFIRMING",
            Self::Claiming => "CLAIMING",
            Self::Refunding => "REFUNDING",
            Self::Paid => "PAID",
            Self::Refunded => "REFUNDED",
            Self::NothingSent => "NOTHING_SENT",
        }
    }
}

impl ForwardRecord {
    pub(crate) fn deposit_progress(&self) -> DepositProgress<'_> {
        match (&self.deposit, self.deposit_attempted) {
            (Some(transaction), _) => DepositProgress::Kept(transaction),
            (None, true) => DepositProgress::Started,
            (None, false) => DepositProgress::NotStarted,
        }
    }

    pub(crate) fn finished(&self) -> bool {
        self.outcome.is_some()
    }

    pub(crate) fn phase(&self) -> ForwardPhase {
        match (&self.outcome, self.deposit_progress()) {
            (Some(ForwardOutcome::Paid), _) => ForwardPhase::Paid,
            (Some(ForwardOutcome::Refunded { .. }), _) => ForwardPhase::Refunded,
            (Some(ForwardOutcome::NothingSent { .. }), _) => ForwardPhase::NothingSent,
            (None, _) if self.sweep.is_some() => ForwardPhase::Refunding,
            (None, _) if self.payout.is_some() => ForwardPhase::Claiming,
            (None, DepositProgress::Kept(_)) => ForwardPhase::Confirming,
            (None, DepositProgress::Started) => ForwardPhase::Depositing,
            (None, DepositProgress::NotStarted) => ForwardPhase::Opening,
        }
    }

    fn check(&self) -> Result<(), String> {
        // An outcome reads only with the time it ended.
        if self.outcome.is_some() && self.finished_at.is_none() {
            return Err("an ended swap has no end time".into());
        }
        Ok(())
    }
}

// ---- reverse record ----

/// Where a deployment's maker takes Privacy Pass tokens from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TokenIssuer {
    pub url: String,
    pub name: String,
    pub token_key: String,
    pub return_key: String,
}

const DEFAULT_ESCROW_CONFIRMATIONS: u64 = 3;
const DEFAULT_ZCASH_CONFIRMATIONS: u32 = 3;

fn default_escrow_confirmations() -> u64 {
    DEFAULT_ESCROW_CONFIRMATIONS
}

fn is_default_escrow_confirmations(value: &u64) -> bool {
    *value == DEFAULT_ESCROW_CONFIRMATIONS
}

fn default_zcash_confirmations() -> u32 {
    DEFAULT_ZCASH_CONFIRMATIONS
}

fn is_default_zcash_confirmations(value: &u32) -> bool {
    *value == DEFAULT_ZCASH_CONFIRMATIONS
}

fn default_zcash_network() -> SwapZcashNetwork {
    SwapZcashNetwork::Testnet
}

fn is_default_zcash_network(value: &SwapZcashNetwork) -> bool {
    *value == SwapZcashNetwork::Testnet
}

/// The deployment a reverse record is pinned to. `rpc_url` is always the
/// keyless URL: a keyed one is never stored.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RecordDeployment {
    pub maker_url: String,
    pub relayer_url: String,
    pub rpc_url: String,
    pub chain_id: u64,
    pub contract: Address,
    pub token: Address,
    #[serde(rename = "railgun")]
    pub railgun_proxy: Address,
    pub maker: Address,
    pub relayer: Address,
    #[serde(
        rename = "confirmations",
        default = "default_escrow_confirmations",
        skip_serializing_if = "is_default_escrow_confirmations"
    )]
    pub escrow_confirmations: u64,
    #[serde(
        default = "default_zcash_network",
        skip_serializing_if = "is_default_zcash_network"
    )]
    pub zcash_network: SwapZcashNetwork,
    #[serde(
        default = "default_zcash_confirmations",
        skip_serializing_if = "is_default_zcash_confirmations"
    )]
    pub zcash_confirmations: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_issuer: Option<TokenIssuer>,
}

impl RecordDeployment {
    /// `network`'s pins, as a new reverse record keeps them; `Unavailable`
    /// where bridging is off.
    pub(crate) fn pinned(network: PrivateUsdNetwork) -> super::Result<Self> {
        let pins = deployment::deployment(network);
        Ok(Self {
            maker_url: pins.maker_url.into(),
            relayer_url: pins.relayer_url.into(),
            rpc_url: pins.keyless_rpc_url.into(),
            chain_id: pins.chain_id,
            contract: Hex(pins.swap_contract()?.address),
            token: Hex(pins.token),
            railgun_proxy: Hex(pins.railgun_proxy),
            maker: Hex(pins.maker),
            relayer: Hex(pins.relayer),
            escrow_confirmations: pins.escrow_confirmations.into(),
            zcash_network: network.into(),
            zcash_confirmations: pins.zcash_confirmations,
            token_issuer: Some(TokenIssuer {
                url: pins.issuer_url.into(),
                name: pins.issuer_name.into(),
                token_key: pins.issuer_token_key.into(),
                return_key: pins.maker_token_return_key.into(),
            }),
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub(crate) enum ReversePhase {
    Quoted,
    Accepting,
    AwaitingFunding,
    SendingUsdc,
    ConfirmingEscrow,
    ReceivingZec,
    AwaitingReady,
    Settling,
    Receiving,
    RefundWait,
    Refunding,
    RefundPayout,
    Complete,
    Refunded,
    Cancelled,
}

impl ReversePhase {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Quoted => "QUOTED",
            Self::Accepting => "ACCEPTING",
            Self::AwaitingFunding => "AWAITING_FUNDING",
            Self::SendingUsdc => "SENDING_USDC",
            Self::ConfirmingEscrow => "CONFIRMING_ESCROW",
            Self::ReceivingZec => "RECEIVING_ZEC",
            Self::AwaitingReady => "AWAITING_READY",
            Self::Settling => "SETTLING",
            Self::Receiving => "RECEIVING",
            Self::RefundWait => "REFUND_WAIT",
            Self::Refunding => "REFUNDING",
            Self::RefundPayout => "REFUND_PAYOUT",
            Self::Complete => "COMPLETE",
            Self::Refunded => "REFUNDED",
            Self::Cancelled => "CANCELLED",
        }
    }

    pub(crate) fn is_finished(self) -> bool {
        matches!(self, Self::Complete | Self::Refunded | Self::Cancelled)
    }
}

fn default_phase() -> ReversePhase {
    ReversePhase::Accepting
}

fn is_default_phase(phase: &ReversePhase) -> bool {
    *phase == ReversePhase::Accepting
}

/// What funding a reverse swap takes from the private balance.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReverseFundingCost {
    pub debit: Amount,
    pub railgun_fee: Amount,
    pub broadcaster_fee: Amount,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fee_expires_at: Option<u64>,
}

/// Exact proved calldata, kept before submission.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReverseFundingRequest {
    pub swap_id: Word,
    pub chain_id: u64,
    pub to: Address,
    pub data: String,
    pub value: String,
}

/// Redacted: `data` is the proof.
impl fmt::Debug for ReverseFundingRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReverseFundingRequest")
            .field("swap_id", &self.swap_id)
            .field("chain_id", &self.chain_id)
            .field("to", &self.to)
            .field("data_chars", &self.data.len())
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReverseFundingTransaction {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tx_id: Option<Word>,
    pub cost: ReverseFundingCost,
    pub request: ReverseFundingRequest,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReverseReceiveEstimate {
    pub available_zat: u64,
    pub fee_zat: u64,
}

impl ReverseReceiveEstimate {
    /// What the sweep home brings after its fee.
    pub(crate) fn received_zat(&self) -> u64 {
        self.available_zat.saturating_sub(self.fee_zat)
    }

    /// A sweep that pays a fee and still brings something home.
    pub(crate) fn is_usable(&self) -> bool {
        self.fee_zat > 0 && self.available_zat > self.fee_zat
    }
}

/// The joint account's sweep home, kept before it is first sent.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReverseReceiveTransaction {
    pub tx_id: ZcashTxId,
    pub raw: String,
    pub expiry_height: u64,
    pub received_zat: u64,
    pub fee_zat: u64,
}

impl fmt::Debug for ReverseReceiveTransaction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ReverseReceiveTransaction({:?})", self.tx_id)
    }
}

impl ReverseReceiveTransaction {
    /// The transaction alone, as it is sent again and followed.
    pub(crate) fn transaction(&self) -> ZcashTransaction {
        ZcashTransaction {
            tx_id: self.tx_id.clone(),
            raw: self.raw.clone(),
            expiry_height: self.expiry_height,
        }
    }
}

/// A reverse swap.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReverseRecord {
    pub index: u32,
    pub deployment: RecordDeployment,
    pub quote: ReverseQuote,
    pub swap_id: Word,
    pub user_share: Bytes64,
    pub acceptance: SwapAcceptance,
    pub birthday: u64,
    /// Set once the joint account was imported for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<JointAccountId>,
    #[serde(default = "default_phase", skip_serializing_if = "is_default_phase")]
    pub phase: ReversePhase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<ReverseFundingCost>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub funding: Option<ReverseFundingTransaction>,
    /// The one `ready` the user signs, kept before it is handed out. It is
    /// never signed again, so its deadline is every ready deadline the
    /// conversion has: a refund waits for the chain to pass it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ready: Option<SwapAuthorization>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub cancel_requested: bool,
    /// A refund was posted, `z` with it: kept before it goes, and no `ready`
    /// is signed or sent after it.
    #[serde(default, skip_serializing_if = "is_false")]
    pub refund_posted: bool,
    /// The lock contract's refund lock, in a record from before the windows
    /// contract: still read, never written.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refund_lock: Option<SwapAuthorization>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payout: Option<SwapPayout>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rescue: Option<SwapRescue>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receive: Option<ReverseReceiveTransaction>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receive_estimate: Option<ReverseReceiveEstimate>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub receive_confirmations: u64,
    /// Unix seconds when the user went ahead; none while only a preview.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accepted_at: Option<u64>,
    /// The maker took the quote; a token paid for it, never asked again.
    #[serde(default, skip_serializing_if = "is_false")]
    pub maker_accepted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ticket: Option<Ticket>,
}

impl ReverseRecord {
    pub(crate) fn finished(&self) -> bool {
        self.phase.is_finished()
    }

    /// The deadline of every `ready` the user signed.
    pub(crate) fn ready_deadlines(&self) -> Vec<u64> {
        self.ready.iter().map(|ready| ready.deadline).collect()
    }

    /// A quote only previewed: never written to history.
    pub(crate) fn is_draft(&self) -> bool {
        self.phase == ReversePhase::Quoted
    }

    pub(crate) fn under_way(&self) -> bool {
        !self.is_draft() && !self.finished()
    }

    /// Settlement was seen on Ethereum, even if the sweep home is not built
    /// yet: no refund can follow.
    pub(crate) fn is_settled(&self) -> bool {
        matches!(self.phase, ReversePhase::Receiving | ReversePhase::Complete)
            || self.receive.is_some()
    }

    /// Whether the user may still call it off: under way, not called off
    /// already, not settled, and no refund being paid.
    pub(crate) fn cancellable(&self) -> bool {
        self.under_way()
            && !self.cancel_requested
            && !self.is_settled()
            && !matches!(
                self.phase,
                ReversePhase::Refunding | ReversePhase::RefundPayout
            )
    }

    /// Gone ahead with, and neither accepted nor funded nor called off yet.
    pub(crate) fn is_accepting(&self) -> bool {
        self.under_way()
            && self.account.is_none()
            && self.funding.is_none()
            && !self.cancel_requested
    }

    /// Waiting on one of the user's two approvals: the funding payment or
    /// the settlement.
    pub(crate) fn awaiting_user(&self) -> bool {
        self.under_way()
            && !self.cancel_requested
            && matches!(
                self.phase,
                ReversePhase::AwaitingFunding | ReversePhase::AwaitingReady
            )
    }
}

// ---- stored records ----

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Direction {
    Forward,
    Reverse,
}

impl Direction {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Forward => "forward",
            Self::Reverse => "reverse",
        }
    }

    pub(crate) fn parse(text: &str) -> Option<Self> {
        match text {
            "forward" => Some(Self::Forward),
            "reverse" => Some(Self::Reverse),
            _ => None,
        }
    }
}

/// A record as `swaps.db` keeps it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum StoredRecord {
    Forward(Box<ForwardRecord>),
    Reverse(Box<ReverseRecord>),
}

impl StoredRecord {
    pub(crate) fn direction(&self) -> Direction {
        match self {
            Self::Forward(_) => Direction::Forward,
            Self::Reverse(_) => Direction::Reverse,
        }
    }

    pub(crate) fn index(&self) -> u32 {
        match self {
            Self::Forward(record) => record.index,
            Self::Reverse(record) => record.index,
        }
    }

    pub(crate) fn swap_id(&self) -> Word {
        match self {
            Self::Forward(record) => record.swap_id,
            Self::Reverse(record) => record.swap_id,
        }
    }

    pub(crate) fn phase(&self) -> &'static str {
        match self {
            Self::Forward(record) => record.phase().name(),
            Self::Reverse(record) => record.phase.name(),
        }
    }

    pub(crate) fn finished(&self) -> bool {
        match self {
            Self::Forward(record) => record.finished(),
            Self::Reverse(record) => record.finished(),
        }
    }

    /// The deployment's record name, from the pinned chain of the quote or
    /// the record's own deployment.
    pub(crate) fn deployment_name(&self) -> Option<&'static str> {
        let chain_id = match self {
            Self::Forward(record) => record.quote.chain_id,
            Self::Reverse(record) => record.deployment.chain_id,
        };
        deployment::for_chain_id(chain_id).map(|pins| pins.network.record_name())
    }

    pub(crate) fn to_json(&self) -> Result<String, String> {
        match self {
            Self::Forward(record) => serde_json::to_string(record),
            Self::Reverse(record) => serde_json::to_string(record),
        }
        .map_err(|error| format!("could not write the record: {error}"))
    }

    /// Strict: see [`decode_strict`].
    pub(crate) fn decode(direction: Direction, json: &str) -> Result<Self, String> {
        match direction {
            Direction::Forward => {
                let record: ForwardRecord = decode_strict(json)?;
                record.check()?;
                Ok(Self::Forward(Box::new(record)))
            }
            Direction::Reverse => decode_strict(json).map(Self::Reverse),
        }
    }
}

/// Reads a stored record only if this build would write it back unchanged:
/// an unknown field, a value of the wrong form or a default written out makes
/// it unreadable, never silently dropped. Errors carry no record content.
pub(crate) fn decode_strict<T: DeserializeOwned + Serialize>(json: &str) -> Result<T, String> {
    let value: serde_json::Value = serde_json::from_str(json).map_err(describe)?;
    let record = T::deserialize(&value).map_err(describe)?;
    let written = serde_json::to_value(&record).map_err(describe)?;
    if written != value {
        return Err("the record holds fields this version does not write".into());
    }
    Ok(record)
}

/// A serde error without the text of the value it tripped on.
fn describe(error: serde_json::Error) -> String {
    format!(
        "unreadable record ({:?} error at line {} column {})",
        error.classify(),
        error.line(),
        error.column()
    )
}
