//! The wallets: Vizor's, driven only through its API and sync engine, and a payer
//! standing in for NEAR's treasury, which builds zero-OVK payments with the wallet library.

use std::convert::Infallible;

use rust_lib_zcash_wallet::{
    api::{
        one_time_ivk::{self as swap_api, ReceiveDeposit, SwapProviderStatus},
        sync as sync_api, wallet as wallet_api,
    },
    wallet::{
        keys::{mnemonic_bytes_to_seed, parse_account_uuid},
        network::WalletNetwork,
    },
};
use secrecy::ExposeSecret as _;
use tempfile::TempDir;
// The store's RNG, as Vizor opens it (see `wallet::db`).
use voting_crypto_deps::rand::rngs::OsRng;
#[allow(deprecated)]
use zcash_client_backend::zip321::{Payment, TransactionRequest};
use zcash_client_backend::{
    data_api::{
        transparent_ledger::TransparentLedgerMode,
        wallet::{
            create_proposed_transactions,
            input_selection::{GreedyInputSelector, SpendPolicy},
            propose_transfer, ConfirmationsPolicy, SpendingKeys,
        },
        WalletCommitmentTrees, WalletRead as _,
    },
    fees::{standard::SingleOutputChangeStrategy, DustOutputPolicy, StandardFeeRule},
    wallet::OvkPolicy,
};
use zcash_client_sqlite::{util::SystemClock, WalletDb};
use zcash_keys::{
    address::{Address, UnifiedAddress},
    keys::UnifiedSpendingKey,
};
use zcash_primitives::transaction::{Transaction, TxId};
use zcash_proofs::prover::LocalTxProver;
use zcash_protocol::{value::Zatoshis, ShieldedPool};

use super::{
    chain::{Stack, NETWORK},
    near::{Near, Role},
};

/// A Vizor wallet with one software account.
pub struct Wallet {
    pub name: String,
    _dir: TempDir,
    pub db: String,
    pub account: String,
    pub address: String,
    pub mnemonic: String,
}

/// An incoming swap whose deposit instructions the app showed.
pub struct IncomingSwap {
    pub address: String,
    pub receiver: [u8; 43],
    pub deposit: String,
    pub memo: Option<String>,
}

/// A ZEC-to-X swap quoted with a refund address.
pub struct RefundSwap {
    pub index: u64,
    pub address: String,
    pub deposit: String,
}

impl Wallet {
    /// Imports `mnemonic` into a new Vizor wallet whose birthday is `birthday`.
    pub fn import(name: &str, mnemonic: &str, birthday: u32) -> Self {
        let dir = tempfile::tempdir().expect("a wallet directory");
        let db = dir
            .path()
            .join("zcash_wallet.db")
            .to_str()
            .expect("a UTF-8 path")
            .to_owned();
        let imported = wallet_api::import_wallet(
            mnemonic.to_owned(),
            String::new(),
            Some(u64::from(birthday)),
            NETWORK.into(),
            db.clone(),
            Some(name.to_owned()),
        )
        .unwrap_or_else(|e| panic!("import {name}: {e}"));
        Self {
            name: name.to_owned(),
            _dir: dir,
            db,
            account: imported.account_uuid,
            address: imported.unified_address,
            mnemonic: mnemonic.to_owned(),
        }
    }

    /// One foreground sync, as the app runs it: scanning, the follow-ups, then the one
    /// restore sweep run the receiver directory gets per sync.
    pub fn sync(&self, stack: &Stack) {
        sync_api::run_full_sync_blocking(
            self.db.clone(),
            stack.lightwalletd_url(),
            NETWORK.into(),
            1,
        )
        .unwrap_or_else(|e| panic!("{} syncs: {e}", self.name));
    }

    /// Every zatoshi the wallet holds, spendable or not.
    pub fn total(&self) -> u64 {
        sync_api::get_balance(self.db.clone(), NETWORK.into(), self.account.clone())
            .unwrap_or_else(|e| panic!("{} balance: {e}", self.name))
            .total
    }

    /// Quotes an incoming swap as the app does: reserves an address, records the request,
    /// NEAR accepts it with a deadline `deadline_in` seconds away, and the app shows the
    /// deposit instructions. Fails only if the address cannot be reserved yet.
    pub fn quote_incoming(
        &self,
        stack: &Stack,
        near: &mut Near,
        deadline_in: i64,
    ) -> Result<IncomingSwap, String> {
        let reserved = swap_api::reserve_swap_address(
            self.db.clone(),
            NETWORK.into(),
            self.account.clone(),
            true,
            u64::from(stack.tip()),
        )
        .map_err(|e| e.message)?;
        let index = reserved.reservation_index.expect("an incoming reservation");
        let now = stack.now();
        let deadline = now + deadline_in;
        let request = swap_api::begin_receive_quote(
            self.db.clone(),
            NETWORK.into(),
            self.account.clone(),
            index,
            deadline,
        )
        .unwrap_or_else(|e| panic!("{} begins a quote: {e}", self.name));
        let receiver = receiver_of(&reserved.address);
        near.give(receiver, now, Role::Payout);
        let deposit = ReceiveDeposit {
            address: near.deposit_address(),
            memo: None,
            deadline_seconds: deadline,
        };
        swap_api::finish_receive_quote(
            self.db.clone(),
            NETWORK.into(),
            self.account.clone(),
            request.clone(),
            Some(deposit),
        )
        .unwrap_or_else(|e| panic!("{} records the accepted quote: {e}", self.name));
        let shown = swap_api::start_receive_quote(
            self.db.clone(),
            NETWORK.into(),
            self.account.clone(),
            request,
        )
        .unwrap_or_else(|e| panic!("{} shows the quote: {e}", self.name));
        Ok(IncomingSwap {
            address: reserved.address,
            receiver,
            deposit: shown.address,
            memo: shown.memo,
        })
    }

    /// Records NEAR's `status` for an incoming swap, as the app's status poll does.
    pub fn observe_incoming(
        &self,
        stack: &Stack,
        swap: &IncomingSwap,
        status: &str,
        amount_out: u64,
    ) {
        swap_api::observe_swap_status(
            self.db.clone(),
            NETWORK.into(),
            self.account.clone(),
            true,
            swap.deposit.clone(),
            swap.memo.clone(),
            SwapProviderStatus {
                status: status.into(),
                swap_type: Some("EXACT_INPUT".into()),
                refunded_amount: None,
                amount_out: Some(amount_out.to_string()),
            },
            false,
            stack.now(),
        )
        .unwrap_or_else(|e| panic!("{} records {status}: {e}", self.name));
    }

    /// Quotes a ZEC-to-X swap with a refund address, as the app does: reserves the refund
    /// key, then records NEAR's ZEC deposit address for it. Fails only if the key cannot
    /// be reserved yet.
    pub fn quote_refund(
        &self,
        stack: &Stack,
        near: &mut Near,
        deadline_in: i64,
    ) -> Result<RefundSwap, String> {
        let reserved = swap_api::reserve_swap_address(
            self.db.clone(),
            NETWORK.into(),
            self.account.clone(),
            false,
            u64::from(stack.tip()),
        )
        .map_err(|e| e.message)?;
        let index = reserved.refund_index.expect("a refund index");
        let deposit = zec_deposit_address(index);
        swap_api::record_swap_refund_quote(
            self.db.clone(),
            NETWORK.into(),
            self.account.clone(),
            index,
            deposit.clone(),
            stack.now() + deadline_in,
        )
        .unwrap_or_else(|e| panic!("{} records the refund quote: {e}", self.name));
        near.give(receiver_of(&reserved.address), stack.now(), Role::Refund);
        Ok(RefundSwap {
            index,
            address: reserved.address,
            deposit,
        })
    }

    /// Funds a ZEC-to-X swap through Vizor's send flow, which puts the refund memo on its
    /// Ironwood change, and broadcasts it.
    pub fn fund_swap(&self, stack: &Stack, swap: &RefundSwap, amount: u64) {
        let flow = format!("fund-swap-{}", swap.index);
        let proposal = sync_api::propose_swap_funding(
            self.db.clone(),
            NETWORK.into(),
            self.account.clone(),
            flow.clone(),
            swap.deposit.clone(),
            amount,
            swap.index,
        )
        .unwrap_or_else(|e| panic!("{} proposes the swap deposit: {e}", self.name));
        let result = sync_api::execute_proposal(
            self.db.clone(),
            stack.lightwalletd_url(),
            proposal.proposal_id,
            flow,
            self.mnemonic.as_bytes().to_vec(),
            None,
            None,
        )
        .unwrap_or_else(|e| panic!("{} sends the swap deposit: {e}", self.name));
        assert_eq!(result.status, "broadcasted", "{:?}", result.message);
    }

    /// Records NEAR's `status` for a ZEC-to-X swap's refund side.
    pub fn observe_refund(&self, stack: &Stack, swap: &RefundSwap, status: &str, refunded: u64) {
        swap_api::observe_swap_status(
            self.db.clone(),
            NETWORK.into(),
            self.account.clone(),
            false,
            swap.deposit.clone(),
            None,
            SwapProviderStatus {
                status: status.into(),
                swap_type: Some("EXACT_INPUT".into()),
                refunded_amount: Some(refunded.to_string()),
                amount_out: None,
            },
            true,
            stack.now(),
        )
        .unwrap_or_else(|e| panic!("{} records {status}: {e}", self.name));
    }

    /// Queues Check swap history for the next sync.
    pub fn check_swap_history(&self) {
        swap_api::recheck_swap_history(self.db.clone(), NETWORK.into())
            .unwrap_or_else(|e| panic!("{} checks swap history: {e}", self.name));
    }
}

/// The payer standing in for NEAR: a Vizor-synced wallet whose payments the test builds
/// with the wallet library, with the zero OVK for payouts and refunds as NEAR's are.
pub struct Payer {
    pub wallet: Wallet,
    usk: UnifiedSpendingKey,
}

impl Payer {
    /// The payer for `wallet`, with the spending key of its first account.
    pub fn new(wallet: Wallet) -> Self {
        let seed = mnemonic_bytes_to_seed(wallet.mnemonic.as_bytes()).expect("a seed");
        let usk = UnifiedSpendingKey::from_seed(
            &WalletNetwork::Regtest,
            seed.expose_secret(),
            zip32::AccountId::ZERO,
        )
        .expect("a spending key");
        Self { wallet, usk }
    }

    /// `count` of the payer's own addresses, at diversifier indices from 1.
    pub fn own_addresses(&self, count: u32) -> Vec<String> {
        let ufvk = self.usk.to_unified_full_viewing_key();
        let fvk = ufvk.orchard().expect("an Orchard key");
        (1..=count)
            .map(|i| encode(fvk.address_at(i, orchard::keys::Scope::External)))
            .collect()
    }

    /// Builds one transaction paying `outputs` with `ovk`, from shielded notes with one
    /// confirmation, after a sync. The wallet stores it as sent; nothing broadcasts it
    /// until the payer's next sync resubmits it.
    pub fn build(&self, stack: &Stack, outputs: &[(&str, u64)], ovk: OvkPolicy) -> Transaction {
        self.wallet.sync(stack);
        self.build_unsynced(outputs, ovk)
    }

    /// [`Self::build`] without the sync, so a transaction built earlier stays unsent.
    pub fn build_unsynced(&self, outputs: &[(&str, u64)], ovk: OvkPolicy) -> Transaction {
        self.build_in(&self.wallet.db, outputs, ovk)
    }

    /// Builds in a copy of the payer's wallet, which never learns of the transaction until
    /// a sync finds it mined, so one not broadcast leaves nothing behind to resubmit.
    pub fn build_detached(
        &self,
        stack: &Stack,
        outputs: &[(&str, u64)],
        ovk: OvkPolicy,
    ) -> Transaction {
        self.wallet.sync(stack);
        let dir = tempfile::tempdir().expect("a directory for the copy");
        let copy = dir.path().join("detached.db");
        rusqlite::Connection::open(&self.wallet.db)
            .expect("the payer's wallet opens")
            .execute("VACUUM INTO ?1", [copy.to_str().expect("a UTF-8 path")])
            .expect("the wallet copies");
        self.build_in(copy.to_str().expect("a UTF-8 path"), outputs, ovk)
    }

    /// Builds one transaction paying `outputs` with `ovk` in the wallet at `db_path`.
    fn build_in(&self, db_path: &str, outputs: &[(&str, u64)], ovk: OvkPolicy) -> Transaction {
        let conn = rusqlite::Connection::open(db_path).expect("the payer's wallet opens");
        // As Vizor configures its connections (see `wallet::db`).
        conn.busy_timeout(std::time::Duration::from_secs(30))
            .expect("a busy timeout");
        rusqlite::vtab::array::load_module(&conn).expect("the rarray module");
        let mut db = WalletDb::from_connection(conn, WalletNetwork::Regtest, SystemClock, OsRng)
            .with_transparent_ledger_mode(TransparentLedgerMode::Public);
        let account = parse_account_uuid(&self.wallet.account).expect("an account UUID");
        #[allow(deprecated)]
        let request = TransactionRequest::new(
            outputs
                .iter()
                .map(|(address, value)| {
                    Payment::without_memo(
                        address.parse().expect("an address"),
                        Zatoshis::from_u64(*value).expect("a value"),
                    )
                })
                .collect(),
        )
        .expect("a payment request");
        type Db = WalletDb<rusqlite::Connection, WalletNetwork, SystemClock, OsRng>;
        let strategy = SingleOutputChangeStrategy::<Db>::new(
            StandardFeeRule::Zip317,
            None,
            ShieldedPool::Ironwood,
            DustOutputPolicy::default(),
        );
        let policy =
            SpendPolicy::shielded_pools(vec![ShieldedPool::Orchard, ShieldedPool::Ironwood]);
        let proposal = propose_transfer::<_, _, _, _, <Db as WalletCommitmentTrees>::Error>(
            &mut db,
            &WalletNetwork::Regtest,
            account,
            &GreedyInputSelector::new(),
            &strategy,
            request,
            ConfirmationsPolicy::MIN,
            &policy,
            None,
            None,
        )
        .unwrap_or_else(|e| panic!("the payer proposes: {e}"));
        let prover = LocalTxProver::bundled();
        let txids = create_proposed_transactions::<_, _, Infallible, _, Infallible, _>(
            &mut db,
            &WalletNetwork::Regtest,
            &prover,
            &prover,
            &SpendingKeys::from_unified_spending_key(self.usk.clone()),
            ovk,
            &proposal,
            None,
        )
        .unwrap_or_else(|e| panic!("the payer builds: {e}"));
        db.get_transaction(*txids.first())
            .expect("the stored transaction reads")
            .expect("the payer stored its transaction")
    }

    /// Builds and broadcasts one transaction paying `outputs` with `ovk`.
    pub fn pay(&self, stack: &Stack, outputs: &[(&str, u64)], ovk: OvkPolicy) -> TxId {
        let tx = self.build(stack, outputs, ovk);
        broadcast(stack, &tx);
        tx.txid()
    }
}

/// The zero OVK NEAR pays with, which lets the receiver directory list its payments.
pub fn zero_ovk() -> OvkPolicy {
    OvkPolicy::custom_from_common_bytes(&[0; 32])
}

/// Broadcasts `tx` through the node.
pub fn broadcast(stack: &Stack, tx: &Transaction) {
    let mut bytes = Vec::new();
    tx.write(&mut bytes).expect("the transaction encodes");
    stack.send_raw(&bytes);
}

/// The raw receiver of a swap address, which carries only an Ironwood receiver.
pub fn receiver_of(address: &str) -> [u8; 43] {
    match Address::decode(&WalletNetwork::Regtest, address).expect("a regtest address") {
        Address::Unified(ua) => ua
            .orchard()
            .expect("an Ironwood receiver")
            .to_raw_address_bytes(),
        other => panic!("not a unified address: {other:?}"),
    }
}

/// `address` as a unified address with no other receiver.
fn encode(address: orchard::Address) -> String {
    Address::Unified(UnifiedAddress::from_receivers(Some(address), None, None).expect("an address"))
        .encode(&WalletNetwork::Regtest)
}

/// A P2PKH address on regtest for NEAR's ZEC deposit, as 1Click deposits are.
fn zec_deposit_address(index: u64) -> String {
    let hash = [u8::try_from(index % 251).expect("fits") + 1; 20];
    Address::Transparent(transparent::address::TransparentAddress::PublicKeyHash(
        hash,
    ))
    .encode(&WalletNetwork::Regtest)
}
