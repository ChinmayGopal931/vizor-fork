//! The reveal decisions against zecSwap's port oracle: every vector of the
//! app's three reveals (`windows_vectors.json`) goes through
//! `swap::claim_window`, `swap::may_sign_ready` and `swap::may_refund`, which
//! must give the oracle's `send`. And the windows contract's reads, as its
//! ABI and the deployed testnet contract name them.

use serde_json::Value;

use super::super::abi;
use super::super::deployment::{
    self, READY_DEPTH_BLOCKS, REVEAL_MARGIN_SECONDS, SIGNATURE_TTL_SECONDS,
};
use super::super::evm_rpc::{self, SwapStage};
use super::super::swap::{self, ClaimWindow, WindowView};
use super::super::PrivateUsdNetwork;
use super::{hex0x, text};

fn vectors() -> Vec<Value> {
    let fixture: Value = serde_json::from_str(include_str!("windows_vectors.json")).unwrap();
    fixture["vectors"].as_array().unwrap().clone()
}

fn number(value: &Value) -> u64 {
    value.as_u64().unwrap()
}

fn flag(value: &Value) -> bool {
    value.as_bool().unwrap()
}

fn stage(name: &str) -> Option<SwapStage> {
    match name {
        "open" => Some(SwapStage::Open),
        "ready" => Some(SwapStage::Ready),
        "claimed" => Some(SwapStage::Claimed),
        "refunded" => Some(SwapStage::Refunded),
        "none" => None,
        other => panic!("unknown stage {other}"),
    }
}

/// The app's decision on `vector`: a forward claim, a reverse `ready` or a
/// reverse refund, on the one consistent read and the durable facts it names.
fn decide(vector: &Value) -> bool {
    let view = &vector["view"];
    let own = &vector["own"];
    let window = WindowView {
        stage: stage(text(&view["stage"])),
        head: number(&view["head_ts"]),
        head_number: number(&view["head_number"]),
        device_now: number(&view["wall_now"]),
        t0: number(&view["t0"]),
        t1: number(&view["t1"]),
        late_window: number(&view["late_window"]),
    };
    let forward = text(&view["direction"]) == "forward";
    match text(&vector["reveal"]) {
        "user_claim" => {
            forward
                && swap::claim_window(
                    &window,
                    view["ready_block"].as_u64(),
                    flag(&view["railgun_accepts"]),
                ) == ClaimWindow::Open
        }
        "user_ready" => {
            !forward
                && swap::may_sign_ready(
                    &window,
                    flag(&own["refund_sent"]),
                    flag(&view["deposit_confirmed"]),
                )
        }
        "user_refund" => {
            let deadlines: Vec<u64> = own["ready_sig_deadlines"]
                .as_array()
                .unwrap()
                .iter()
                .map(number)
                .collect();
            !forward && swap::may_refund(&window, &deadlines)
        }
        other => panic!("not one of the app's reveals: {other}"),
    }
}

/// Every vector of the app's reveals, with the oracle's margins, which are
/// the app's, gives the oracle's answer.
#[test]
fn the_reveals_give_the_oracles_answer_on_every_vector() {
    let vectors = vectors();
    let count = |reveal: &str| {
        vectors
            .iter()
            .filter(|vector| text(&vector["reveal"]) == reveal)
            .count()
    };
    assert_eq!(
        (
            count("user_claim"),
            count("user_ready"),
            count("user_refund")
        ),
        (25, 7, 12)
    );
    let mut sends = 0;
    for (i, vector) in vectors.iter().enumerate() {
        let margins = &vector["margins"];
        assert_eq!(number(&margins["claim_app"]), REVEAL_MARGIN_SECONDS);
        assert_eq!(number(&margins["ready_sig_ttl"]), SIGNATURE_TTL_SECONDS);
        assert_eq!(number(&margins["ready_depth"]), READY_DEPTH_BLOCKS);
        let expected = flag(&vector["expect"]["send"]);
        assert_eq!(
            decide(vector),
            expected,
            "vector {i}: {} ({})",
            text(&vector["reveal"]),
            text(&vector["expect"]["reason"])
        );
        sends += usize::from(expected);
    }
    assert_eq!((vectors.len(), sends), (44, 17));
}

/// The windows contract's reads and its refund event: the selectors its ABI
/// gives, at which the testnet contract answers its windows and reverts
/// `LOCK_DURATION()`.
#[test]
fn the_windows_contracts_reads() {
    for (signature, selector) in [
        (evm_rpc::MIN_WINDOW, "0x52b65c4b"),
        (evm_rpc::LATE_WINDOW, "0x4d9fef3e"),
        (evm_rpc::LOCK_DURATION, "0x485d3834"),
        (evm_rpc::GET_SWAP, "0x3da0e66e"),
    ] {
        assert_eq!(hex0x(&abi::selector(signature)), selector, "{signature}");
    }
    assert_eq!(
        hex0x(&abi::keccak(&[evm_rpc::REFUNDED_EVENT.as_bytes()])),
        "0x1535ab411323bb41ad642ccf14068bbd78818ed38dd9b4421c927cc6eeb07e2d"
    );

    // Each network pins the windows contract zecSwap deployed there:
    // testnet's at block 11958709, mainnet's at block 26250774.
    for (network, address, windows) in [
        (
            PrivateUsdNetwork::Testnet,
            "0x459b0a69e0f736666b66a3ffe0fc17c11f05980d",
            (1_800, 3_600),
        ),
        (
            PrivateUsdNetwork::Mainnet,
            "0xeb3a00bcb6c9ff626fe57a5dbbdcf01730e7898f",
            (3_600, 86_400),
        ),
    ] {
        let swaps = deployment::deployment(network).swap_contract().unwrap();
        assert_eq!(hex0x(&swaps.address), address, "{network:?}");
        assert_eq!(
            (swaps.min_window, swaps.late_window),
            windows,
            "{network:?}"
        );
    }
}
