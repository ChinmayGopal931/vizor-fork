//! The send log and its settlement (plan M7 "Done when"): keep before post,
//! the spend guard across restarts, and the settlement's `when` (zapp
//! `RelayedPrivateUsdSenderTest` 63, 104, 132, 180, 209 and 230,
//! `PrivateUsdSendLogTest` 52 and 98), on a scripted relayer and a fake
//! chain. The relayer's answer mapping is `relayer_client`'s test.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

use serde_json::{json, Value};

use crate::wallet::private_usd::{
    deployment::{self, hex_address, Deployment},
    engine::Clock,
    evm_rpc::{SendChain, TransactionStatus},
    models::{Amount, Hex},
    relayer_client::RailgunBroadcast,
    sends::{self, ProvedSend, SendRecord, Sends},
    store::{SendRow, SendState, SwapStore},
    transport::test_support::ScriptedTransport,
    ErrorCode, PrivateUsdNetwork, Result,
};
use crate::wallet::routed_http::{RoutedError, RoutedPhase, RoutedRequest, RoutedResponse};

const NOW: u64 = 1_790_000_000;
const RELAYER: &str = "https://relayer.invalid/relayer";
/// The proof's calldata as the page might give it, in capitals.
const DATA: &str = "0xD8AE136A00010203";

fn pins() -> &'static Deployment {
    deployment::deployment(PrivateUsdNetwork::Testnet)
}

fn word(byte: u8) -> [u8; 32] {
    [byte; 32]
}

fn hex0x(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

struct TestClock(Cell<u64>);

impl TestClock {
    fn set(&self, now: u64) {
        self.0.set(now);
    }
}

impl Clock for TestClock {
    fn now(&self) -> u64 {
        self.0.get()
    }

    async fn sleep(&self, _duration: Duration) {}
}

/// Receipts and spent nullifiers, as each test sets them.
#[derive(Default)]
struct FakeSendChain {
    statuses: RefCell<HashMap<[u8; 32], TransactionStatus>>,
    spent: RefCell<HashSet<[u8; 32]>>,
}

impl FakeSendChain {
    fn status(&self, transaction: [u8; 32], status: TransactionStatus) {
        self.statuses.borrow_mut().insert(transaction, status);
    }

    fn spend(&self, nullifier: [u8; 32]) {
        self.spent.borrow_mut().insert(nullifier);
    }
}

impl SendChain for FakeSendChain {
    async fn send_status(&self, transaction: &[u8; 32]) -> Result<TransactionStatus> {
        Ok(self
            .statuses
            .borrow()
            .get(transaction)
            .copied()
            .unwrap_or(TransactionStatus::Unknown))
    }

    async fn nullifier_spent(&self, _tree: u32, nullifier: &[u8; 32]) -> Result<bool> {
        Ok(self.spent.borrow().contains(nullifier))
    }
}

/// The relayer's answer to every `/v1/railgun/transact` until changed:
/// status, body and `Retry-After`; status 0 drops the connection.
struct Answer(RefCell<(u16, String, Option<&'static str>)>);

impl Answer {
    fn new() -> Self {
        Self(RefCell::new((0, String::new(), None)))
    }

    fn set(&self, status: u16, body: &str, retry_after: Option<&'static str>) {
        *self.0.borrow_mut() = (status, body.to_owned(), retry_after);
    }

    fn sent(&self, transaction: [u8; 32]) {
        self.set(
            200,
            &json!({ "transactions": [hex0x(&transaction)] }).to_string(),
            None,
        );
    }

    fn spent(&self, transactions: &[[u8; 32]]) {
        let named: Vec<String> = transactions.iter().map(|t| hex0x(t)).collect();
        self.set(
            409,
            &json!({ "code": "alreadySpent", "error": "spent", "transactions": named }).to_string(),
            None,
        );
    }

    fn respond(&self) -> std::result::Result<RoutedResponse, RoutedError> {
        let (status, body, retry_after) = self.0.borrow().clone();
        if status == 0 {
            return Err(RoutedError {
                phase: RoutedPhase::AfterDispatch,
                message: "connection reset".into(),
            });
        }
        Ok(RoutedResponse {
            status,
            headers: retry_after
                .map(|value| vec![("retry-after".to_owned(), value.to_owned())])
                .unwrap_or_default(),
            body: body.into_bytes(),
        })
    }
}

/// The bodies the relayer received, in order.
fn bodies<F>(transport: &ScriptedTransport<F>) -> Vec<String> {
    transport
        .sent
        .borrow()
        .iter()
        .map(|request| String::from_utf8(request.body.clone().unwrap()).unwrap())
        .collect()
}

/// The page's `transfer` result spending `nullifiers`: its proxy in mixed
/// case, its calldata in capitals, with the fields the relayer never sees.
fn page_proof(nullifiers: &[[u8; 32]]) -> Value {
    let nullifiers: Vec<String> = nullifiers.iter().map(|n| hex0x(n)).collect();
    json!({
        "chainId": pins().chain_id,
        "to": hex_address(&pins().railgun_proxy).to_uppercase().replace("0X", "0x"),
        "data": DATA,
        "value": "0",
        "spends": [{ "tree": 1, "nullifiers": nullifiers }],
        "proofMs": 4200,
    })
}

/// What the relayer receives for any `page_proof`: the four fields, as kept.
fn kept_body() -> String {
    format!(
        r#"{{"chainId":{},"to":"{}","data":"{}","value":"0"}}"#,
        pins().chain_id,
        hex_address(&pins().railgun_proxy),
        DATA.to_lowercase()
    )
}

fn proved<'a>(id: &'a str, proof: &'a str) -> ProvedSend<'a> {
    ProvedSend {
        id,
        token: Hex(pins().token),
        amount: Amount(1_000_000),
        fee: Amount(500_000),
        to: deployment::deployment(PrivateUsdNetwork::Mainnet).relayer_railgun_address,
        proof_json: proof,
    }
}

fn keep(store: &mut SwapStore, account: &str, id: &str, proof: &Value) -> Result<SendRecord> {
    let proof = proof.to_string();
    sends::keep(store, pins(), account, &proved(id, &proof), NOW)
}

#[tokio::test]
async fn a_send_is_kept_before_it_is_posted_and_posted_from_the_store() {
    let account = "sends-keep-before-post";
    let dir = tempfile::tempdir().unwrap();
    let mut store = SwapStore::open(dir.path()).unwrap();
    let answer = Answer::new();
    answer.sent(word(0xab));
    let transport = ScriptedTransport::new(|_: &RoutedRequest| answer.respond());
    let clock = TestClock(Cell::new(NOW));
    let relay = Sends::new(&transport, RELAYER, &clock, account);

    // Nothing kept, nothing posted.
    let error = relay.transact(&mut store, "send-1").await.unwrap_err();
    assert_eq!(error.code, ErrorCode::Other);
    assert!(transport.sent.borrow().is_empty());

    // A proof that is not this deployment's, or a fee above the cap, is
    // never kept, so it can never go out.
    let proof = page_proof(&[word(1), word(2)]);
    let edited = |field: &str, value: Value| {
        let mut edited = proof.clone();
        edited[field] = value;
        edited
    };
    for bad in [
        edited("chainId", json!(1)),
        edited("to", json!(hex_address(&pins().relay_adapt))),
        edited("value", json!("1")),
        edited("data", json!("0x12")),
        edited("spends", json!([])),
        edited("spends", json!([{ "tree": 1, "nullifiers": [] }])),
        edited("spends", json!([{ "tree": 1, "nullifiers": ["0x12"] }])),
    ] {
        let error = keep(&mut store, account, "send-1", &bad).unwrap_err();
        assert_eq!(error.code, ErrorCode::Mismatch, "{bad}");
    }
    let text = proof.to_string();
    let over_cap = ProvedSend {
        fee: Amount(2_000_001),
        ..proved("send-1", &text)
    };
    let error = sends::keep(&mut store, pins(), account, &over_cap, NOW).unwrap_err();
    assert_eq!(error.code, ErrorCode::RelayerFee);
    let burned = ProvedSend {
        to: "0x0000000000000000000000000000000000000000",
        ..proved("send-1", &text)
    };
    let error = sends::keep(&mut store, pins(), account, &burned, NOW).unwrap_err();
    assert_eq!(error.code, ErrorCode::Mismatch);
    assert!(sends::records(&store, account).unwrap().is_empty());

    // Kept, then posted as kept: exactly the four fields, from the store.
    let kept = keep(&mut store, account, "send-1", &proof).unwrap();
    assert!(!kept.confirmed());
    // Keeping it again is the same send; another proof under its id (a
    // second proving) is never kept.
    assert_eq!(keep(&mut store, account, "send-1", &proof).unwrap(), kept);
    let error = keep(&mut store, account, "send-1", &page_proof(&[word(3)])).unwrap_err();
    assert_eq!(error.code, ErrorCode::Mismatch);

    let answered = relay.transact(&mut store, "send-1").await.unwrap();
    assert_eq!(answered, RailgunBroadcast::Sent(word(0xab)));
    assert_eq!(
        transport.sent.borrow()[0].url,
        format!("{RELAYER}/v1/railgun/transact")
    );
    assert_eq!(bodies(&transport), vec![kept_body()]);
    let records = sends::records(&store, account).unwrap();
    assert_eq!(records[0].tx_hash, Some(Hex(word(0xab))));
    assert!(!records[0].confirmed(), "sent is not landed");
}

#[tokio::test]
async fn an_unsettled_send_blocks_the_next_payment_across_restarts() {
    let account = "sends-guard";
    let dir = tempfile::tempdir().unwrap();
    {
        let mut store = SwapStore::open(dir.path()).unwrap();
        keep(&mut store, account, "send-a", &page_proof(&[word(1)])).unwrap();
    }
    // A restart: nothing in memory survives, the kept send does.
    let mut store = SwapStore::open(dir.path()).unwrap();
    let kept = sends::records(&store, account).unwrap();
    assert_eq!(kept.len(), 1);
    assert!(!kept[0].confirmed());
    let error = keep(&mut store, account, "send-b", &page_proof(&[word(2)])).unwrap_err();
    assert_eq!(error.code, ErrorCode::Busy);
    // Another account's payments are its own.
    keep(
        &mut store,
        "sends-guard-other",
        "send-c",
        &page_proof(&[word(2)]),
    )
    .unwrap();

    // Once the chain shows it landed, the next payment may go.
    let answer = Answer::new();
    answer.spent(&[]);
    let transport = ScriptedTransport::new(|_: &RoutedRequest| answer.respond());
    let clock = TestClock(Cell::new(NOW));
    let chain = FakeSendChain::default();
    let relay = Sends::new(&transport, RELAYER, &clock, account);
    let posted = relay.settle_all(&mut store, &chain).await.unwrap();
    assert!(!posted[0].confirmed());
    chain.spend(word(1));
    let settled = relay.settle_all(&mut store, &chain).await.unwrap();
    assert!(settled[0].confirmed());
    assert_eq!(bodies(&transport), vec![kept_body()]);

    // A log that does not read keeps every payment blocked.
    let garbled = SendRow {
        send_id: "garbled".into(),
        created_at: NOW + 1,
        state: SendState::Unconfirmed,
        record_json: r#"{"id":"garbled"}"#.into(),
    };
    store.put_send(account, &garbled).unwrap();
    let error = sends::records(&store, account).unwrap_err();
    assert_eq!(error.code, ErrorCode::StoreUnreadable);
    let error = keep(&mut store, account, "send-b", &page_proof(&[word(2)])).unwrap_err();
    assert_eq!(error.code, ErrorCode::StoreUnreadable);
    store.remove_send(account, "garbled").unwrap();
    keep(&mut store, account, "send-b", &page_proof(&[word(2)])).unwrap();
}

#[tokio::test]
async fn a_kept_send_goes_again_as_the_same_bytes_no_sooner_than_asked() {
    let account = "sends-post-again";
    let dir = tempfile::tempdir().unwrap();
    let mut store = SwapStore::open(dir.path()).unwrap();
    // Killed between keeping and posting: the next pass posts what was kept.
    keep(&mut store, account, "send-1", &page_proof(&[word(1)])).unwrap();
    let answer = Answer::new();
    answer.set(
        503,
        r#"{"code":"unavailable","error":"a send of these notes reverted lately"}"#,
        Some("600"),
    );
    let transport = ScriptedTransport::new(|_: &RoutedRequest| answer.respond());
    let clock = TestClock(Cell::new(NOW));
    let chain = FakeSendChain::default();
    let relay = Sends::new(&transport, RELAYER, &clock, account);

    let held = relay.settle_all(&mut store, &chain).await.unwrap();
    let relay_state = |records: &[SendRecord]| {
        let held = records[0].relay.as_ref().unwrap();
        (held.posted_at, held.retry_at)
    };
    assert_eq!(relay_state(&held), (Some(NOW), Some(NOW + 600)));
    clock.set(NOW + 599);
    relay.settle_all(&mut store, &chain).await.unwrap();
    assert_eq!(bodies(&transport).len(), 1, "no sooner than it asked");

    // A lost answer, here a dropped connection, goes again on the next pass.
    answer.set(0, "", None);
    clock.set(NOW + 600);
    let lost = relay.settle_all(&mut store, &chain).await.unwrap();
    assert_eq!(relay_state(&lost), (Some(NOW + 600), None));
    answer.sent(word(0xcd));
    clock.set(NOW + 601);
    let sent = relay.settle_all(&mut store, &chain).await.unwrap();
    assert_eq!(sent[0].tx_hash, Some(Hex(word(0xcd))));
    assert!(!sent[0].confirmed());
    // Never proved again: every post is the kept bytes.
    assert_eq!(bodies(&transport), vec![kept_body(); 3]);

    // A refusal: nothing went, so the send is forgotten.
    let refused = "sends-post-again-refused";
    keep(&mut store, refused, "send-2", &page_proof(&[word(2)])).unwrap();
    answer.set(422, r#"{"code":"rejected","error":"noncanonical"}"#, None);
    let relay = Sends::new(&transport, RELAYER, &clock, refused);
    assert!(relay
        .settle_all(&mut store, &chain)
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn a_named_transaction_settles_from_its_receipt() {
    let account = "sends-receipt";
    let dir = tempfile::tempdir().unwrap();
    let mut store = SwapStore::open(dir.path()).unwrap();
    keep(&mut store, account, "send-1", &page_proof(&[word(1)])).unwrap();
    let answer = Answer::new();
    answer.sent(word(0x11));
    let transport = ScriptedTransport::new(|_: &RoutedRequest| answer.respond());
    let clock = TestClock(Cell::new(NOW));
    let chain = FakeSendChain::default();
    let relay = Sends::new(&transport, RELAYER, &clock, account);
    relay.transact(&mut store, "send-1").await.unwrap();

    // Still out: asked about again only after a while, as the same bytes.
    chain.status(word(0x11), TransactionStatus::Pending);
    clock.set(NOW + 179);
    relay.settle_all(&mut store, &chain).await.unwrap();
    assert_eq!(bodies(&transport).len(), 1);
    clock.set(NOW + 180);
    relay.settle_all(&mut store, &chain).await.unwrap();
    assert_eq!(bodies(&transport), vec![kept_body(); 2]);

    // In a block (one confirmation): landed in it.
    chain.status(word(0x11), TransactionStatus::Confirmed);
    let landed = relay.settle_all(&mut store, &chain).await.unwrap();
    assert!(landed[0].confirmed());
    assert_eq!(landed[0].tx_hash, Some(Hex(word(0x11))));
    assert_eq!(bodies(&transport).len(), 2);

    // Reverted: it moved nothing, and is forgotten.
    let reverted = "sends-receipt-reverted";
    keep(&mut store, reverted, "send-2", &page_proof(&[word(2)])).unwrap();
    answer.sent(word(0x22));
    let relay = Sends::new(&transport, RELAYER, &clock, reverted);
    relay.transact(&mut store, "send-2").await.unwrap();
    chain.status(word(0x22), TransactionStatus::Reverted);
    assert!(relay
        .settle_all(&mut store, &chain)
        .await
        .unwrap()
        .is_empty());
    assert_eq!(bodies(&transport).len(), 3);
}

#[tokio::test]
async fn notes_the_relayer_calls_spent_settle_from_the_chain() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = SwapStore::open(dir.path()).unwrap();
    let answer = Answer::new();
    let transport = ScriptedTransport::new(|_: &RoutedRequest| answer.respond());
    let clock = TestClock(Cell::new(NOW));
    let chain = FakeSendChain::default();

    // The relayer named its own transaction, and it succeeded: landed in it.
    let named = "sends-spent-named";
    keep(
        &mut store,
        named,
        "send-1",
        &page_proof(&[word(1), word(2)]),
    )
    .unwrap();
    answer.spent(&[word(0x31)]);
    let relay = Sends::new(&transport, RELAYER, &clock, named);
    assert_eq!(
        relay.transact(&mut store, "send-1").await.unwrap(),
        RailgunBroadcast::Spent(vec![word(0x31)])
    );
    chain.status(word(0x31), TransactionStatus::Confirmed);
    let landed = relay.settle_all(&mut store, &chain).await.unwrap();
    assert!(landed[0].confirmed());
    assert_eq!(landed[0].tx_hash, Some(Hex(word(0x31))));

    // None of its nullifiers spent: asked again only after a while; all of
    // them spent: landed, in a transaction nobody named.
    let unnamed = "sends-spent-unnamed";
    keep(
        &mut store,
        unnamed,
        "send-2",
        &page_proof(&[word(3), word(4)]),
    )
    .unwrap();
    answer.spent(&[]);
    let relay = Sends::new(&transport, RELAYER, &clock, unnamed);
    relay.transact(&mut store, "send-2").await.unwrap();
    clock.set(NOW + 899);
    relay.settle_all(&mut store, &chain).await.unwrap();
    assert_eq!(bodies(&transport).len(), 2);
    clock.set(NOW + 900);
    let asked = relay.settle_all(&mut store, &chain).await.unwrap();
    assert_eq!(bodies(&transport).len(), 3);
    assert_eq!(asked[0].relay.as_ref().unwrap().spent_at, Some(NOW + 900));
    chain.spend(word(3));
    chain.spend(word(4));
    let landed = relay.settle_all(&mut store, &chain).await.unwrap();
    assert!(landed[0].confirmed());
    assert_eq!(landed[0].tx_hash, None);

    // Some spent: another proof took part of its notes, so it never can
    // land, and is forgotten.
    let taken = "sends-spent-taken";
    keep(
        &mut store,
        taken,
        "send-3",
        &page_proof(&[word(5), word(6)]),
    )
    .unwrap();
    let relay = Sends::new(&transport, RELAYER, &clock, taken);
    relay.transact(&mut store, "send-3").await.unwrap();
    chain.spend(word(5));
    assert!(relay
        .settle_all(&mut store, &chain)
        .await
        .unwrap()
        .is_empty());
    assert_eq!(
        bodies(&transport),
        vec![kept_body(); 4],
        "every post was a kept proof"
    );
}
