//! The swap and Deposits contracts and Railgun's proxy over Ethereum
//! JSON-RPC.
//!
//! One JSON-RPC 2.0 request per call (publicnode limits batches), through the
//! engine's [`HttpTransport`]. Calls and answers are encoded by [`abi`].
//!
//! Only [`ChainReader::confirmed_swap`] (and the reverse equivalent) reads a
//! confirmed block, `head − confirmations + 1`, after checking the node's
//! chain id; it is the only read that may authorize a deposit, a reveal or a
//! completion. `swap` reads `latest` and serves index skipping and "did it
//! ever open".
//!
//! The RPC URL may carry an API key: it is never logged or stored.

use std::sync::{
    atomic::{AtomicU64, Ordering},
    OnceLock,
};

use serde::Deserialize;
use serde_json::{json, Value};
use zecswap_core::Terms;

use super::abi::{
    self, address_of_word, address_word, bool_word, call_data, exact_word, hex0x, keccak,
    u128_word, u64_word, uint_word, words, Call, WORD,
};
use super::deployment::{Deployment, DepositsPin, MAX_LOGS_BODY, MAX_SERVICE_BODY, QUICK_TIMEOUT};
use super::transport::HttpTransport;
use super::{fail, ErrorCode, PrivateUsdError, Result};
use crate::wallet::routed_http::RoutedRequest;

/// `getSwap`'s static struct: termsHash, stage, paidOut, claimLockUntil,
/// refundLockUntil, secret.
const GET_SWAP_WORDS: usize = 6;
/// Public nodes cap a log query's range.
const LOG_WINDOW_BLOCKS: u64 = 5_000;
const SECONDS_PER_BLOCK: u64 = 12;

pub(crate) const GET_SWAP: &str = "getSwap(bytes32)";
pub(crate) const LOCK_DURATION: &str = "LOCK_DURATION()";
pub(crate) const MAKER_KEY_USED: &str = "makerKeyUsed(bytes32)";
pub(crate) const REVERSE_FUNDING: &str = "reverseFunding(bytes32)";
pub(crate) const VAULT_OF: &str = "vaultOf(bytes32)";
pub(crate) const RESCUE_NONCES: &str = "rescueNonces(bytes32)";
pub(crate) const TOKEN_BLOCKLIST: &str = "tokenBlocklist(address)";
pub(crate) const BALANCE_OF: &str = "balanceOf(address)";
pub(crate) const PAID_OUT_EVENT: &str = "PaidOut(bytes32,address,uint256)";
/// Railgun's proxy: whether a note's nullifier in a tree is spent.
pub(crate) const NULLIFIERS: &str = "nullifiers(uint256,bytes32)";
/// A relayed send counts as landed once its receipt has this many blocks.
pub(crate) const SEND_CONFIRMATIONS: u32 = 1;
/// The Deposits contract. Unlike the swap contract's `bytes32` versions,
/// these take an address.
pub(crate) const DEPOSITED: &str = "deposited(address)";
pub(crate) const DEPOSITS_VAULT_OF: &str = "vaultOf(address)";
pub(crate) const DEPOSITS_RESCUE_NONCES: &str = "rescueNonces(address)";
pub(crate) const DEPOSITS_TOKEN: &str = "TOKEN()";
/// The token's own EIP-712 domain (EIP-3009).
pub(crate) const TOKEN_NAME: &str = "name()";
pub(crate) const TOKEN_VERSION: &str = "version()";
pub(crate) const TOKEN_DOMAIN_SEPARATOR: &str = "DOMAIN_SEPARATOR()";
pub(crate) const AUTHORIZATION_STATE: &str = "authorizationState(address,bytes32)";
/// A deposit, or a rescue, counts as landed once its receipt has this many
/// blocks, as a relayed send does.
pub(crate) const DEPOSIT_CONFIRMATIONS: u32 = SEND_CONFIRMATIONS;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Head {
    pub number: u64,
    pub timestamp: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SwapStage {
    Open,
    Ready,
    Claimed,
    Refunded,
}

/// `getSwap(id)`: what the contract keeps of a swap besides its terms, which
/// it holds only as `terms_hash`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SwapState {
    pub terms_hash: [u8; 32],
    pub stage: SwapStage,
    /// A payout into Railgun has left the contract.
    pub paid_out: bool,
    pub claim_lock_until: u64,
    pub refund_lock_until: u64,
    /// The share a claim or refund revealed, big-endian, once there was one
    /// (what `SecretShare::from_be_bytes` takes).
    pub secret: [u8; 32],
}

/// A confirmed read: the head it was taken against, and the swap whose terms
/// hash to what the contract stored (`None`: no swap).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ConfirmedSwap {
    pub head: Head,
    pub swap: Option<SwapState>,
}

/// A reverse escrow at one confirmed block: its swap, and the refund note
/// and funding block the contract keeps apart (`refund_note` zero: none).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ReverseChainState {
    pub head: Head,
    pub swap: Option<SwapState>,
    pub refund_note: [u8; 32],
    pub funding_block: u64,
    pub lock_duration: u64,
}

/// A confirmed `PaidOut(id, relayer, fee)` event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PaidOut {
    pub transaction: [u8; 32],
    pub relayer: [u8; 20],
    pub fee: u128,
}

/// Where a transaction stands with the node.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TransactionStatus {
    /// Neither in a block nor waiting for one.
    Unknown,
    /// Waiting for a block, or in one with too few on top yet.
    Pending,
    Confirmed,
    Reverted,
}

/// Every contract read the swap driver makes. Implemented over JSON-RPC by
/// [`EvmRpc`]; engine tests fake it.
pub(crate) trait ChainReader {
    async fn chain_id(&self) -> Result<u64>;
    async fn head(&self) -> Result<Head>;
    /// `latest`, unconfirmed: never authorizes anything.
    async fn swap(&self, id: &[u8; 32]) -> Result<Option<SwapState>>;
    /// The only read that authorizes a deposit, a reveal or completion.
    async fn confirmed_swap(&self, id: &[u8; 32], terms: &Terms) -> Result<ConfirmedSwap>;
    /// Immutable, so read once.
    async fn lock_duration(&self) -> Result<u64>;
    async fn maker_key_used(&self, key: &[u8; 32]) -> Result<bool>;
    async fn reverse_state(&self, id: &[u8; 32], terms: &Terms) -> Result<ReverseChainState>;
    async fn vault_balance(&self, id: &[u8; 32]) -> Result<u128>;
    async fn rescue_nonce(&self, id: &[u8; 32]) -> Result<u64>;
    /// Whether Railgun's proxy takes the swap token. Any revert means paused,
    /// so closed.
    async fn railgun_accepts(&self) -> Result<bool>;
    /// The confirmed payout of `id`, looking back to `since` (unix seconds).
    async fn confirmed_payout(&self, id: &[u8; 32], since: u64) -> Result<Option<PaidOut>>;
    async fn transaction_status(
        &self,
        transaction: &[u8; 32],
        confirmations: u32,
    ) -> Result<TransactionStatus>;
}

/// What settles a relayed Railgun send: its transaction's receipt, or the
/// nullifiers it spends. Implemented over JSON-RPC by [`EvmRpc`]; the send
/// tests fake it.
pub(crate) trait SendChain {
    /// The transaction's receipt with [`SEND_CONFIRMATIONS`].
    async fn send_status(&self, transaction: &[u8; 32]) -> Result<TransactionStatus>;
    /// `nullifiers(tree, nullifier)` on Railgun's proxy at `latest`.
    async fn nullifier_spent(&self, tree: u32, nullifier: &[u8; 32]) -> Result<bool>;
}

/// A deposit address as a scan reads it: what it holds of the token, and
/// whether it has deposited (its vault is there).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct AddressUse {
    pub balance: u128,
    pub deposited: bool,
}

impl AddressUse {
    /// Given out: it holds tokens or has deposited.
    pub(crate) fn used(&self) -> bool {
        self.balance > 0 || self.deposited
    }
}

/// One log of a mined transaction's receipt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ReceiptLog {
    pub address: [u8; 20],
    pub topics: Vec<[u8; 32]>,
    pub data: Vec<u8>,
}

/// What deposits read from Ethereum. Implemented over JSON-RPC by [`EvmRpc`],
/// one request per call.
pub(crate) trait DepositChain {
    /// The node's chain id (named apart from `ChainReader::chain_id`, which
    /// `EvmRpc` also has).
    async fn node_chain_id(&self) -> Result<u64>;
    /// Each owner's token balance and whether it has deposited, in one
    /// Multicall3 `aggregate3` at `latest`.
    async fn deposit_addresses(
        &self,
        pin: &DepositsPin,
        owners: &[[u8; 20]],
    ) -> Result<Vec<AddressUse>>;
    /// The Deposits contract's `TOKEN()`.
    async fn deposits_token(&self, pin: &DepositsPin) -> Result<[u8; 20]>;
    /// The token's own `name()`, `version()` and `DOMAIN_SEPARATOR()`.
    async fn token_domain(&self, token: &[u8; 20]) -> Result<(String, String, [u8; 32])>;
    /// What each owner's vault (`vaultOf`) holds of the token: Railgun sends
    /// a note its screening refused back there.
    async fn vault_balances(&self, pin: &DepositsPin, owners: &[[u8; 20]]) -> Result<Vec<u128>>;
    /// The nonce `from`'s next rescue signs (`rescueNonces(from)`).
    async fn deposit_rescue_nonce(&self, pin: &DepositsPin, from: &[u8; 20]) -> Result<u64>;
    /// Whether `from` used authorization `nonce` on the token: an EIP-3009
    /// nonce of a deposit is used only by its landing (the wallet never
    /// cancels one).
    async fn authorization_used(
        &self,
        token: &[u8; 20],
        from: &[u8; 20],
        nonce: &[u8; 32],
    ) -> Result<bool>;
    /// A deposit's transaction, with [`DEPOSIT_CONFIRMATIONS`].
    async fn deposit_status(&self, transaction: &[u8; 32]) -> Result<TransactionStatus>;
    /// The logs of `transaction`'s receipt; `None` while it is not mined.
    async fn receipt_logs(&self, transaction: &[u8; 32]) -> Result<Option<Vec<ReceiptLog>>>;
}

enum RpcError {
    /// `execution reverted` (code 3, or the message).
    Reverted,
    Failed(PrivateUsdError),
}

impl From<RpcError> for PrivateUsdError {
    fn from(error: RpcError) -> Self {
        match error {
            RpcError::Reverted => {
                PrivateUsdError::new(ErrorCode::ChainUnreadable, "the call reverted")
            }
            RpcError::Failed(error) => error,
        }
    }
}

#[derive(Deserialize)]
struct RpcAnswer {
    result: Option<Value>,
    error: Option<RpcFault>,
}

#[derive(Deserialize)]
struct RpcFault {
    code: Option<i64>,
    message: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LogEntry {
    address: String,
    topics: Vec<String>,
    data: String,
    block_number: String,
    transaction_hash: String,
    #[serde(default)]
    removed: bool,
}

/// One deployment's contract over JSON-RPC at `url`.
pub(crate) struct EvmRpc<'a, T: HttpTransport> {
    transport: &'a T,
    url: String,
    pins: &'static Deployment,
    lock_duration: OnceLock<u64>,
    next_id: AtomicU64,
}

impl<'a, T: HttpTransport> EvmRpc<'a, T> {
    /// Over the build's keyed RPC URL, or publicnode when `keyed_rpc_url` is
    /// empty.
    pub(crate) fn new(transport: &'a T, pins: &'static Deployment, keyed_rpc_url: &str) -> Self {
        Self {
            transport,
            url: pins.rpc_url(keyed_rpc_url).to_owned(),
            pins,
            lock_duration: OnceLock::new(),
            next_id: AtomicU64::new(1),
        }
    }

    async fn rpc(&self, method: &str, params: Value) -> std::result::Result<Value, RpcError> {
        let body = json!({
            "jsonrpc": "2.0",
            "id": self.next_id.fetch_add(1, Ordering::Relaxed),
            "method": method,
            "params": params,
        });
        let limit = if method == "eth_getLogs" {
            MAX_LOGS_BODY
        } else {
            MAX_SERVICE_BODY
        };
        let request = RoutedRequest::post(
            self.url.clone(),
            serde_json::to_vec(&body).expect("JSON-RPC requests encode"),
            QUICK_TIMEOUT,
            limit,
        )
        .header("content-type", "application/json");
        let offline = |message: String| {
            RpcError::Failed(PrivateUsdError::new(
                ErrorCode::EthereumUnreachable,
                message,
            ))
        };
        let response = self.transport.send(request).await.map_err(|error| {
            let code = if error.route_blocked {
                ErrorCode::RouteBlocked
            } else {
                ErrorCode::EthereumUnreachable
            };
            RpcError::Failed(PrivateUsdError::new(
                code,
                format!("Ethereum node unreachable ({method}): {error}"),
            ))
        })?;
        if !response.is_success() {
            return Err(offline(format!(
                "Ethereum node answered HTTP {} ({method})",
                response.status
            )));
        }
        let answer: RpcAnswer = serde_json::from_slice(&response.body).map_err(|_| {
            RpcError::Failed(PrivateUsdError::new(
                ErrorCode::ChainUnreadable,
                format!("unreadable JSON-RPC answer ({method})"),
            ))
        })?;
        if let Some(fault) = answer.error {
            let message = fault.message.unwrap_or_default();
            // geth uses code 3; some providers -32000 with the message.
            if fault.code == Some(3) || message.to_ascii_lowercase().contains("execution reverted")
            {
                return Err(RpcError::Reverted);
            }
            return Err(offline(format!(
                "Ethereum node error {} ({method}): {message}",
                fault.code.unwrap_or_default()
            )));
        }
        answer.result.ok_or_else(|| {
            RpcError::Failed(PrivateUsdError::new(
                ErrorCode::ChainUnreadable,
                format!("JSON-RPC answer without a result ({method})"),
            ))
        })
    }

    async fn eth_call(
        &self,
        to: &[u8; 20],
        data: Vec<u8>,
        block: &str,
    ) -> std::result::Result<Vec<u8>, RpcError> {
        let result = self
            .rpc(
                "eth_call",
                json!([
                    { "to": hex0x(to), "data": hex0x(&data) },
                    block
                ]),
            )
            .await?;
        hex_bytes(&result).map_err(RpcError::Failed)
    }

    /// `signature(word)` on the swap contract at `block`.
    async fn contract_call(
        &self,
        signature: &str,
        word: &[u8; 32],
        block: &str,
    ) -> Result<Vec<u8>> {
        Ok(self
            .eth_call(&self.pins.contract, call_data(signature, &[*word]), block)
            .await?)
    }

    async fn require_chain(&self) -> Result<()> {
        if self.chain_id().await? != self.pins.chain_id {
            return fail(ErrorCode::WrongDeployment, "the node serves another chain");
        }
        Ok(())
    }

    /// `head − confirmations + 1`, the block a confirmed read uses.
    fn confirmed_number(&self, head: Head) -> u64 {
        (head.number + 1).saturating_sub(u64::from(self.pins.escrow_confirmations.max(1)))
    }

    async fn lookup(&self, transaction: &[u8; 32], method: &str) -> Result<Option<Value>> {
        let result = self.rpc(method, json!([hex0x(transaction)])).await?;
        Ok((!result.is_null()).then_some(result))
    }
}

impl<T: HttpTransport> ChainReader for EvmRpc<'_, T> {
    async fn chain_id(&self) -> Result<u64> {
        quantity(&self.rpc("eth_chainId", json!([])).await?)
    }

    async fn head(&self) -> Result<Head> {
        let block = self
            .rpc("eth_getBlockByNumber", json!(["latest", false]))
            .await?;
        if block.is_null() {
            return fail(ErrorCode::ChainUnreadable, "the node has no latest block");
        }
        Ok(Head {
            number: quantity(&block["number"])?,
            timestamp: quantity(&block["timestamp"])?,
        })
    }

    async fn swap(&self, id: &[u8; 32]) -> Result<Option<SwapState>> {
        decode_swap_state(&self.contract_call(GET_SWAP, id, "latest").await?)
    }

    async fn confirmed_swap(&self, id: &[u8; 32], terms: &Terms) -> Result<ConfirmedSwap> {
        self.require_chain().await?;
        let head = self.head().await?;
        let block = block_tag(self.confirmed_number(head));
        let swap = decode_swap_state(&self.contract_call(GET_SWAP, id, &block).await?)?
            .map(|state| state.verified(terms))
            .transpose()?;
        Ok(ConfirmedSwap { head, swap })
    }

    async fn lock_duration(&self) -> Result<u64> {
        if let Some(duration) = self.lock_duration.get() {
            return Ok(*duration);
        }
        let data = self
            .eth_call(&self.pins.contract, call_data(LOCK_DURATION, &[]), "latest")
            .await?;
        let duration = u64_word(&words(&data, 1)?[0])?;
        Ok(*self.lock_duration.get_or_init(|| duration))
    }

    async fn maker_key_used(&self, key: &[u8; 32]) -> Result<bool> {
        let data = self.contract_call(MAKER_KEY_USED, key, "latest").await?;
        Ok(words(&data, 1)?[0][WORD - 1] != 0)
    }

    async fn reverse_state(&self, id: &[u8; 32], terms: &Terms) -> Result<ReverseChainState> {
        self.require_chain().await?;
        let head = self.head().await?;
        let block = block_tag(self.confirmed_number(head));
        let funding_data = self.contract_call(REVERSE_FUNDING, id, &block).await?;
        let funding = words(&funding_data, 2)?;
        let swap = decode_swap_state(&self.contract_call(GET_SWAP, id, &block).await?)?
            .map(|state| state.verified(terms))
            .transpose()?;
        Ok(ReverseChainState {
            head,
            swap,
            refund_note: funding[0],
            funding_block: u64_word(&funding[1])?,
            lock_duration: self.lock_duration().await?,
        })
    }

    async fn vault_balance(&self, id: &[u8; 32]) -> Result<u128> {
        let vault_data = self.contract_call(VAULT_OF, id, "latest").await?;
        let vault: [u8; 20] = words(&vault_data, 1)?[0][12..]
            .try_into()
            .expect("20 bytes");
        let balance = self
            .eth_call(
                &self.pins.token,
                call_data(BALANCE_OF, &[address_word(&vault)]),
                "latest",
            )
            .await?;
        u128_word(&words(&balance, 1)?[0])
    }

    async fn rescue_nonce(&self, id: &[u8; 32]) -> Result<u64> {
        self.require_chain().await?;
        let data = self.contract_call(RESCUE_NONCES, id, "latest").await?;
        u64_word(&words(&data, 1)?[0])
    }

    async fn railgun_accepts(&self) -> Result<bool> {
        let call = call_data(TOKEN_BLOCKLIST, &[address_word(&self.pins.token)]);
        match self
            .eth_call(&self.pins.railgun_proxy, call, "latest")
            .await
        {
            Ok(data) => Ok(words(&data, 1)?[0][WORD - 1] == 0),
            // Railgun's proxy reverts every call while it is paused.
            Err(RpcError::Reverted) => Ok(false),
            Err(RpcError::Failed(error)) => Err(error),
        }
    }

    async fn confirmed_payout(&self, id: &[u8; 32], since: u64) -> Result<Option<PaidOut>> {
        self.require_chain().await?;
        let head = self.head().await?;
        let confirmed = self.confirmed_number(head);
        // Walk back in bounded pages to before the swap was accepted,
        // including payouts delayed past `since`.
        let elapsed = head.timestamp - since.min(head.timestamp);
        let around = head.number.saturating_sub(elapsed / SECONDS_PER_BLOCK);
        let earliest = around.saturating_sub(LOG_WINDOW_BLOCKS).min(confirmed);
        let topic = hex0x(&keccak(&[PAID_OUT_EVENT.as_bytes()]));
        let id_topic = hex0x(id);
        let contract = hex0x(&self.pins.contract);
        let mut to = confirmed;
        loop {
            let from = (to + 1).saturating_sub(LOG_WINDOW_BLOCKS).max(earliest);
            let logs = self
                .rpc(
                    "eth_getLogs",
                    json!([{
                        "address": contract,
                        "topics": [topic, id_topic],
                        "fromBlock": block_tag(from),
                        "toBlock": block_tag(to),
                    }]),
                )
                .await?;
            let logs: Vec<LogEntry> = serde_json::from_value(logs).map_err(|_| {
                PrivateUsdError::new(ErrorCode::ChainUnreadable, "unreadable payout logs")
            })?;
            for log in logs {
                let block = quantity(&Value::String(log.block_number.clone()))?;
                if log.removed
                    || !log.address.eq_ignore_ascii_case(&contract)
                    || log.topics.len() != 2
                    || !log.topics[0].eq_ignore_ascii_case(&topic)
                    || !log.topics[1].eq_ignore_ascii_case(&id_topic)
                    || !(from..=to).contains(&block)
                {
                    continue;
                }
                let data = hex_bytes(&Value::String(log.data))?;
                let fields = words(&data, 2)?;
                let transaction = super::models::Word::parse(&log.transaction_hash)
                    .ok_or_else(|| {
                        PrivateUsdError::new(ErrorCode::ChainUnreadable, "unreadable payout hash")
                    })?
                    .0;
                return Ok(Some(PaidOut {
                    transaction,
                    relayer: fields[0][12..].try_into().expect("20 bytes"),
                    fee: u128_word(&fields[1])?,
                }));
            }
            if from <= earliest {
                return Ok(None);
            }
            to = from - 1;
        }
    }

    async fn transaction_status(
        &self,
        transaction: &[u8; 32],
        confirmations: u32,
    ) -> Result<TransactionStatus> {
        let Some(receipt) = self
            .lookup(transaction, "eth_getTransactionReceipt")
            .await?
        else {
            let known = self.lookup(transaction, "eth_getTransactionByHash").await?;
            return Ok(if known.is_some() {
                TransactionStatus::Pending
            } else {
                TransactionStatus::Unknown
            });
        };
        let head = self.head().await?;
        let included = quantity(&receipt["blockNumber"])?;
        if included > head.number || head.number - included + 1 < u64::from(confirmations.max(1)) {
            return Ok(TransactionStatus::Pending);
        }
        Ok(if quantity(&receipt["status"])? == 0 {
            TransactionStatus::Reverted
        } else {
            TransactionStatus::Confirmed
        })
    }
}

impl<T: HttpTransport> SendChain for EvmRpc<'_, T> {
    async fn send_status(&self, transaction: &[u8; 32]) -> Result<TransactionStatus> {
        self.transaction_status(transaction, SEND_CONFIRMATIONS)
            .await
    }

    async fn nullifier_spent(&self, tree: u32, nullifier: &[u8; 32]) -> Result<bool> {
        let data = self
            .eth_call(
                &self.pins.railgun_proxy,
                call_data(NULLIFIERS, &[uint_word(tree.into()), *nullifier]),
                "latest",
            )
            .await?;
        Ok(words(&data, 1)?[0].iter().any(|byte| *byte != 0))
    }
}

impl<T: HttpTransport> EvmRpc<'_, T> {
    /// Each call's return data, from one `aggregate3` on Multicall3 at
    /// `latest`; any call failing fails the read.
    async fn aggregate(&self, multicall: &[u8; 20], calls: &[Call]) -> Result<Vec<Vec<u8>>> {
        let data = abi::encode_aggregate3(calls);
        let answer = self.eth_call(multicall, data, "latest").await?;
        abi::decode_aggregate3(&answer, calls.len())
    }

    /// `signature()` on `to` at `latest`.
    async fn bare_call(&self, to: &[u8; 20], signature: &str) -> Result<Vec<u8>> {
        Ok(self
            .eth_call(to, call_data(signature, &[]), "latest")
            .await?)
    }
}

impl<T: HttpTransport> DepositChain for EvmRpc<'_, T> {
    async fn node_chain_id(&self) -> Result<u64> {
        ChainReader::chain_id(self).await
    }

    async fn deposit_addresses(
        &self,
        pin: &DepositsPin,
        owners: &[[u8; 20]],
    ) -> Result<Vec<AddressUse>> {
        let calls: Vec<Call> = owners
            .iter()
            .flat_map(|owner| {
                let word = address_word(owner);
                [
                    Call {
                        to: pin.token,
                        data: call_data(BALANCE_OF, &[word]),
                    },
                    Call {
                        to: pin.contract,
                        data: call_data(DEPOSITED, &[word]),
                    },
                ]
            })
            .collect();
        let answers = self.aggregate(&pin.multicall, &calls).await?;
        answers
            .as_chunks::<2>()
            .0
            .iter()
            .map(|[balance, deposited]| {
                Ok(AddressUse {
                    balance: u128_word(&exact_word(balance)?)?,
                    deposited: bool_word(&exact_word(deposited)?)?,
                })
            })
            .collect()
    }

    async fn deposits_token(&self, pin: &DepositsPin) -> Result<[u8; 20]> {
        address_of_word(&exact_word(
            &self.bare_call(&pin.contract, DEPOSITS_TOKEN).await?,
        )?)
    }

    async fn token_domain(&self, token: &[u8; 20]) -> Result<(String, String, [u8; 32])> {
        let name = abi::decode_string(&self.bare_call(token, TOKEN_NAME).await?)?;
        let version = abi::decode_string(&self.bare_call(token, TOKEN_VERSION).await?)?;
        let separator = exact_word(&self.bare_call(token, TOKEN_DOMAIN_SEPARATOR).await?)?;
        Ok((name, version, separator))
    }

    async fn vault_balances(&self, pin: &DepositsPin, owners: &[[u8; 20]]) -> Result<Vec<u128>> {
        if owners.is_empty() {
            return Ok(Vec::new());
        }
        let vault_calls: Vec<Call> = owners
            .iter()
            .map(|owner| Call {
                to: pin.contract,
                data: call_data(DEPOSITS_VAULT_OF, &[address_word(owner)]),
            })
            .collect();
        let vaults = self
            .aggregate(&pin.multicall, &vault_calls)
            .await?
            .iter()
            .map(|answer| address_of_word(&exact_word(answer)?))
            .collect::<Result<Vec<_>>>()?;
        let balance_calls: Vec<Call> = vaults
            .iter()
            .map(|vault| Call {
                to: pin.token,
                data: call_data(BALANCE_OF, &[address_word(vault)]),
            })
            .collect();
        self.aggregate(&pin.multicall, &balance_calls)
            .await?
            .iter()
            .map(|answer| u128_word(&exact_word(answer)?))
            .collect()
    }

    async fn deposit_rescue_nonce(&self, pin: &DepositsPin, from: &[u8; 20]) -> Result<u64> {
        let data = self
            .eth_call(
                &pin.contract,
                call_data(DEPOSITS_RESCUE_NONCES, &[address_word(from)]),
                "latest",
            )
            .await?;
        u64_word(&exact_word(&data)?)
    }

    async fn authorization_used(
        &self,
        token: &[u8; 20],
        from: &[u8; 20],
        nonce: &[u8; 32],
    ) -> Result<bool> {
        let data = self
            .eth_call(
                token,
                call_data(AUTHORIZATION_STATE, &[address_word(from), *nonce]),
                "latest",
            )
            .await?;
        bool_word(&exact_word(&data)?)
    }

    async fn deposit_status(&self, transaction: &[u8; 32]) -> Result<TransactionStatus> {
        self.transaction_status(transaction, DEPOSIT_CONFIRMATIONS)
            .await
    }

    async fn receipt_logs(&self, transaction: &[u8; 32]) -> Result<Option<Vec<ReceiptLog>>> {
        let Some(receipt) = self
            .lookup(transaction, "eth_getTransactionReceipt")
            .await?
        else {
            return Ok(None);
        };
        let logs: Vec<LogEntry> =
            serde_json::from_value(receipt["logs"].clone()).map_err(|_| {
                PrivateUsdError::new(ErrorCode::ChainUnreadable, "unreadable receipt logs")
            })?;
        let mut read = Vec::with_capacity(logs.len());
        for log in logs {
            if log.removed {
                continue;
            }
            let address = super::models::Address::parse(&log.address.to_ascii_lowercase())
                .ok_or_else(|| {
                    PrivateUsdError::new(ErrorCode::ChainUnreadable, "unreadable log address")
                })?;
            let topics = log
                .topics
                .iter()
                .map(|topic| super::models::Word::parse(&topic.to_ascii_lowercase()).map(|t| t.0))
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| {
                    PrivateUsdError::new(ErrorCode::ChainUnreadable, "unreadable log topic")
                })?;
            read.push(ReceiptLog {
                address: address.0,
                topics,
                data: hex_bytes(&Value::String(log.data))?,
            });
        }
        Ok(Some(read))
    }
}

impl SwapState {
    /// This state, once its terms hash is `terms`' (`MISMATCH` otherwise):
    /// the chain shows nothing else of them.
    fn verified(self, terms: &Terms) -> Result<Self> {
        if self.terms_hash != terms.hash() {
            return fail(
                ErrorCode::Mismatch,
                "the swap on chain opened with other terms",
            );
        }
        Ok(self)
    }
}

/// `getSwap`'s answer: exactly six words, or another contract's ABI
/// (`WRONG_DEPLOYMENT`). Stage 0 is no swap.
pub(crate) fn decode_swap_state(data: &[u8]) -> Result<Option<SwapState>> {
    if data.len() != GET_SWAP_WORDS * WORD {
        return fail(
            ErrorCode::WrongDeployment,
            format!("getSwap gave {} bytes", data.len()),
        );
    }
    let words = words(data, GET_SWAP_WORDS)?;
    let stage = match words[1][WORD - 1] {
        0 => return Ok(None),
        1 => SwapStage::Open,
        2 => SwapStage::Ready,
        3 => SwapStage::Claimed,
        4 => SwapStage::Refunded,
        other => {
            return fail(
                ErrorCode::ChainUnreadable,
                format!("unknown swap stage {other}"),
            )
        }
    };
    Ok(Some(SwapState {
        terms_hash: words[0],
        stage,
        paid_out: words[2][WORD - 1] != 0,
        claim_lock_until: u64_word(&words[3])?,
        refund_lock_until: u64_word(&words[4])?,
        secret: words[5],
    }))
}

fn block_tag(number: u64) -> String {
    format!("0x{number:x}")
}

/// A JSON-RPC quantity: `0x` and up to 16 hex digits.
fn quantity(value: &Value) -> Result<u64> {
    value
        .as_str()
        .and_then(|text| text.strip_prefix("0x"))
        .filter(|digits| !digits.is_empty())
        .and_then(|digits| u64::from_str_radix(digits, 16).ok())
        .ok_or_else(|| PrivateUsdError::new(ErrorCode::ChainUnreadable, "unreadable quantity"))
}

/// JSON-RPC data: `0x` and an even number of hex digits.
fn hex_bytes(value: &Value) -> Result<Vec<u8>> {
    value
        .as_str()
        .and_then(|text| text.strip_prefix("0x"))
        .and_then(|digits| hex::decode(digits).ok())
        .ok_or_else(|| PrivateUsdError::new(ErrorCode::ChainUnreadable, "unreadable data"))
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    use super::*;
    use crate::wallet::private_usd::{
        deployment,
        transport::test_support::{rpc_error, rpc_result, ScriptedTransport},
        PrivateUsdNetwork,
    };
    use crate::wallet::routed_http::{RoutedError, RoutedRequest, RoutedResponse};

    fn word(last: u8) -> [u8; 32] {
        let mut word = [0u8; 32];
        word[31] = last;
        word
    }

    fn get_swap_answer(stage: u8) -> Vec<u8> {
        [word(0xaa), word(stage), word(0), word(5), word(0), word(0)].concat()
    }

    fn method(request: &RoutedRequest) -> (String, Value) {
        let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
        (
            body["method"].as_str().unwrap().to_owned(),
            body["params"].clone(),
        )
    }

    #[test]
    fn get_swap_reads_exactly_six_words() {
        assert_eq!(decode_swap_state(&get_swap_answer(0)).unwrap(), None);
        let open = decode_swap_state(&get_swap_answer(1)).unwrap().unwrap();
        assert_eq!(open.stage, SwapStage::Open);
        assert_eq!(open.claim_lock_until, 5);
        assert_eq!(open.terms_hash, word(0xaa));
        for data in [
            get_swap_answer(1)[..191].to_vec(),
            [get_swap_answer(1), vec![0]].concat(),
            Vec::new(),
        ] {
            assert_eq!(
                decode_swap_state(&data).unwrap_err().code,
                ErrorCode::WrongDeployment,
                "{} bytes",
                data.len()
            );
        }
        // A lock time beyond u64 is not this contract's.
        let mut wide = get_swap_answer(1);
        wide[3 * 32] = 1;
        assert_eq!(
            decode_swap_state(&wide).unwrap_err().code,
            ErrorCode::WrongDeployment
        );
    }

    #[tokio::test]
    async fn a_revert_reads_as_railgun_closed() {
        let pins = deployment::deployment(PrivateUsdNetwork::Testnet);
        let reverting = ScriptedTransport::new(|request: &RoutedRequest| {
            let (method, params) = method(request);
            assert_eq!(method, "eth_call");
            assert_eq!(params[0]["to"], hex0x(&pins.railgun_proxy));
            Ok::<RoutedResponse, RoutedError>(rpc_error(3, "execution reverted"))
        });
        let rpc = EvmRpc::new(&reverting, pins, "https://rpc.invalid");
        assert!(!rpc.railgun_accepts().await.unwrap());

        let open = ScriptedTransport::new(|_: &RoutedRequest| {
            Ok::<RoutedResponse, RoutedError>(rpc_result(json!(hex0x(&word(0)))))
        });
        assert!(EvmRpc::new(&open, pins, "https://rpc.invalid")
            .railgun_accepts()
            .await
            .unwrap());
    }

    #[tokio::test]
    async fn another_chain_is_a_wrong_deployment() {
        let pins = deployment::deployment(PrivateUsdNetwork::Testnet);
        let mainnet_node = ScriptedTransport::new(|request: &RoutedRequest| {
            let (method, _) = method(request);
            assert_eq!(
                method, "eth_chainId",
                "nothing is read before the chain check"
            );
            Ok::<RoutedResponse, RoutedError>(rpc_result(json!("0x1")))
        });
        let rpc = EvmRpc::new(&mainnet_node, pins, "https://rpc.invalid");
        let terms = zecswap_core::Terms {
            maker: pins.maker,
            token: pins.token,
            amount: 1,
            maker_share: zecswap_core::derive_maker_share(&[9; 32], 0)
                .unwrap()
                .public(),
            user_share: zecswap_core::derive_maker_share(&[8; 32], 0)
                .unwrap()
                .public(),
            user: [4; 20],
            t0: 1,
            t1: 2,
            payout_note: [0; 32],
        };
        let error = rpc.confirmed_swap(&[1; 32], &terms).await.unwrap_err();
        assert_eq!(error.code, ErrorCode::WrongDeployment);
        assert_eq!(mainnet_node.sent.borrow().len(), 1);
    }
}
