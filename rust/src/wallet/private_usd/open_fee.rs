//! The open fee a maker may ask before it opens a forward swap (zecSwap's
//! `docs/open-fee.md`): its gas for the open and, if no deposit follows, for
//! the cancel. It is the one amount in a swap that rests on trust in the
//! maker, so it is small and capped, and it is never refunded.
//!
//! - **Checked before anything is paid.** Above zero and at most the
//!   deployment's cap, and paid to a unified address of the wallet's own
//!   network with an Orchard receiver and no other ([`orchard_only`]), so no
//!   choice of pool can send it in the clear. A quote that fails is dropped;
//!   its index is spent all the same.
//! - **Quoted to live long enough, and no longer.** A fee quote must live
//!   the deployment's `open_fee_min_quote_life_seconds` (180 s: a 75-second
//!   block more than 90% likely in time) and at most its
//!   `open_fee_max_quote_life_seconds` (30 minutes) when it comes
//!   ([`check_quote_life`]).
//! - **From a wallet at the tip.** Nothing is paid while the main wallet's
//!   scan trails the Zcash tip by more than [`OPEN_FEE_MAX_SCAN_LAG_BLOCKS`]
//!   ([`require_scanned`]): it would deposit late, if at all.
//! - **Paid only with time to be mined.** At least that least life is left
//!   before the payment is built and again right before it is created and
//!   stored ([`require_time_to_start`]): a stored payment is one the
//!   wallet's own sync sends again, so that is the point of no return. It
//!   expires a few blocks after the quote (`create_open_fee`), and the sync
//!   sends it no more once its bridge ended or its quote expired
//!   ([`withheld_fee_txids`]). It is sent again only with
//!   [`OPEN_FEE_MARGIN_SECONDS`] of the quote left.
//! - **One payment.** Exactly `zat`, an empty memo, marked started before it
//!   is created and kept before it is first sent, then sent again, never
//!   built again (`forward.rs`).
//! - **Accepted once mined.** Until the maker has seen it in a block it
//!   answers the accept `402 feeRequired`, and the accept is posted again as
//!   it asks ([`accept_wait`]) until the quote expires, never after.

use std::collections::HashSet;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use zcash_address::unified::{self, Container, Encoding};
use zcash_protocol::consensus::NetworkType;

use super::deployment::{
    FEE_PACE_SECONDS, FEE_WAIT_MAX_SECONDS, FEE_WAIT_MIN_SECONDS, OPEN_FEE_MARGIN_SECONDS,
    OPEN_FEE_MAX_SCAN_LAG_BLOCKS,
};
use super::models::{OpenFee, SwapQuote};
use super::{fail, ErrorCode, Result};

/// That `address` is a unified address of `network` with an Orchard receiver
/// and no other receiver, nor anything unknown beside it; else what is wrong
/// with it. zecSwap's `orchard_only`, which the pinned zecswap-core predates.
pub(crate) fn orchard_only(
    address: &str,
    network: NetworkType,
) -> std::result::Result<(), &'static str> {
    let (actual_network, address) =
        unified::Address::decode(address).map_err(|_| "must be a unified address")?;
    if actual_network != network {
        return Err("is on another network");
    }
    // Metadata, or a receiver of a kind this build does not know, would
    // parse as one more item: either is refused, never ignored.
    let receivers = address.items();
    if receivers.len() != 1 {
        return Err("must have an Orchard receiver and no other");
    }
    match receivers.first() {
        Some(unified::Receiver::Orchard(bytes))
            if orchard::Address::from_raw_address_bytes(bytes)
                .into_option()
                .is_some() =>
        {
            Ok(())
        }
        _ => Err("needs an Orchard receiver"),
    }
}

/// That a wallet may pay `fee`: more than nothing, at most `max` zatoshis,
/// to an Orchard-only address of `network`. `OpenFeeRefused` otherwise,
/// with nothing paid.
pub(crate) fn check_open_fee(fee: &OpenFee, network: NetworkType, max: u64) -> Result<()> {
    if fee.zat == 0 {
        return fail(
            ErrorCode::OpenFeeRefused,
            "the maker asks an open fee of nothing",
        );
    }
    if fee.zat > max {
        return fail(
            ErrorCode::OpenFeeRefused,
            format!(
                "the maker asks an open fee of {} zat, over the {max} allowed",
                fee.zat
            ),
        );
    }
    orchard_only(&fee.address, network).map_err(|wrong| {
        super::PrivateUsdError::new(
            ErrorCode::OpenFeeRefused,
            format!("the open fee's address {wrong}"),
        )
    })?;
    // The wallet keeps a payment under its recipient as it encodes it, and an
    // interrupted payment is looked for by that: another spelling of the
    // same address would hide it and pay twice.
    if !canonical(&fee.address) {
        return fail(
            ErrorCode::OpenFeeRefused,
            "the open fee's address is not written as wallets write it",
        );
    }
    Ok(())
}

/// Whether `address` reads back as written: lowercase, as encoded.
fn canonical(address: &str) -> bool {
    unified::Address::decode(address)
        .is_ok_and(|(network, decoded)| decoded.encode(&network) == address)
}

/// That a quote asking an open fee, quoted at `now`, lives long enough for
/// its fee to be paid and mined in time, `min_life` seconds, and not past
/// `max_life`. `OpenFeeRefused` otherwise, with nothing paid.
pub(crate) fn check_quote_life(
    quote: &SwapQuote,
    now: u64,
    min_life: u64,
    max_life: u64,
) -> Result<()> {
    let life = time_left(quote, now);
    if life < min_life {
        return fail(
            ErrorCode::OpenFeeRefused,
            format!("the fee quote lives {life}s, too short for its fee to be mined first"),
        );
    }
    if quote.expires_at.saturating_sub(now) > max_life {
        return fail(
            ErrorCode::OpenFeeRefused,
            format!("the fee quote lives {life}s, over the {max_life}s allowed"),
        );
    }
    Ok(())
}

/// `WalletSyncing` while the main wallet's fully scanned height `scanned`
/// trails the Zcash tip `tip` by more than [`OPEN_FEE_MAX_SCAN_LAG_BLOCKS`]:
/// the fee is not paid yet. A wallet catching up would see the fee mined
/// late, so post the accept late if at all, and deposit late, perhaps after
/// the deposit window.
pub(crate) fn require_scanned(scanned: Option<u64>, tip: u64) -> Result<()> {
    let behind = scanned.map_or(tip, |scanned| tip.saturating_sub(scanned));
    if behind > OPEN_FEE_MAX_SCAN_LAG_BLOCKS {
        return fail(
            ErrorCode::WalletSyncing,
            format!("the wallet is {behind} blocks behind the Zcash tip"),
        );
    }
    Ok(())
}

/// `QuoteExpired` once `quote` has less than `min_life` seconds left at
/// `now`: too little to start paying its open fee, which the user's bridge
/// and a payment the engine resumes need. A fresh quote is the way on.
pub(crate) fn require_time_to_start(quote: &SwapQuote, now: u64, min_life: u64) -> Result<()> {
    let left = time_left(quote, now);
    if left < min_life {
        return fail(
            ErrorCode::QuoteExpired,
            format!("the quote expires in {left}s, too soon to start paying its open fee"),
        );
    }
    Ok(())
}

/// Seconds of `quote`'s life left at `now`.
pub(crate) fn time_left(quote: &SwapQuote, now: u64) -> u64 {
    quote.expires_at.saturating_sub(now)
}

/// Whether `quote` leaves a kept open fee the time to be mined at `now`, so
/// that sending it again is worth it.
pub(crate) fn time_to_pay(quote: &SwapQuote, now: u64) -> bool {
    time_left(quote, now) >= OPEN_FEE_MARGIN_SECONDS
}

/// The networks a wallet's Private USD directory is named for, as Dart
/// names them (`getPrivateUsdDirPath`).
const STORE_NETWORKS: [&str; 2] = ["main", "test"];

/// The open fee payments the wallet DB at `db_path` must not send again:
/// those of bridges that ended, and of quotes with less than
/// [`OPEN_FEE_MARGIN_SECONDS`] left, the time a fee needs to be mined first.
/// Mined later, a fee pays for nothing. The wallet's resubmission leaves
/// these out, read from the swap store beside the wallet DB
/// (`<support>/private_usd_<db>_<net>`) on each pass, so a restart withholds
/// them before the engine runs. Best effort: a store that does not read
/// withholds nothing, and the payment's own expiry still ends it a few
/// blocks after its quote.
pub(crate) fn withheld_fee_txids(db_path: &str) -> HashSet<Vec<u8>> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or_default();
    let path = Path::new(db_path);
    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
        return HashSet::new();
    };
    let mut withheld = HashSet::new();
    for network in STORE_NETWORKS {
        let store = dir.join(format!("private_usd_{}_{network}", name.to_string_lossy()));
        let rows = match super::store::open_fee_payments(&store) {
            Ok(Some(rows)) => rows,
            Ok(None) => continue,
            Err(error) => {
                log::warn!(
                    "private usd: reading open fees to withhold failed ({:?})",
                    error.code
                );
                continue;
            }
        };
        for row in rows {
            if !row.ended && now.saturating_add(OPEN_FEE_MARGIN_SECONDS) < row.expires_at {
                continue;
            }
            let Some(tx_id) = super::models::ZcashTxId::parse(&row.tx_id) else {
                continue;
            };
            if let Ok(txid) = super::joint::internal_txid(&tx_id) {
                withheld.insert(txid.as_ref().to_vec());
            }
        }
    }
    withheld
}

/// How long to wait before an accept is posted again: what the maker asked
/// (`asked`, from `Retry-After`), else `default`, at least a second the first
/// time and [`FEE_PACE_SECONDS`] from the second wait on (`waits` waits came
/// before), at most [`FEE_WAIT_MAX_SECONDS`], and never past the quote's end,
/// `left` seconds away.
pub(crate) fn accept_wait(asked: Option<u64>, default: u64, waits: u32, left: u64) -> u64 {
    let pace = if waits == 0 {
        FEE_WAIT_MIN_SECONDS
    } else {
        FEE_PACE_SECONDS
    };
    asked
        .unwrap_or(default)
        .clamp(pace, FEE_WAIT_MAX_SECONDS)
        .min(left)
}

#[cfg(test)]
mod tests {
    use zcash_address::unified::{Encoding, Receiver};
    use zecswap_core::{derive_maker_share, derive_user_keys, JointAccount};

    use super::super::deployment::{FEE_WAIT_SECONDS, UNANSWERED_ACCEPT_WAIT_SECONDS};
    use super::*;

    /// An Orchard-only unified address on `network`, as a maker's fee
    /// address is (any joint account's is one).
    pub(crate) fn fee_address(network: NetworkType) -> String {
        let keys = derive_user_keys(&[1; 64], network, 0, 0).unwrap();
        let maker = derive_maker_share(&[9; 32], 1).unwrap().public();
        JointAccount::derive(&maker, &keys.share.public(), &keys.viewing)
            .unwrap()
            .unified_address(network)
    }

    /// `address`'s receivers with `extra` beside them, encoded again.
    fn with_receiver(address: &str, extra: Receiver) -> String {
        let (network, ua) = unified::Address::decode(address).unwrap();
        let mut receivers = ua.items();
        receivers.push(extra);
        unified::Address::try_from_items(receivers)
            .unwrap()
            .encode(&network)
    }

    /// Done-when 1, the address half: only a unified address of the
    /// wallet's network whose one receiver is Orchard is paid.
    #[test]
    fn an_open_fee_is_paid_only_to_an_orchard_only_address_on_our_network() {
        let alone = fee_address(NetworkType::Test);
        assert_eq!(orchard_only(&alone, NetworkType::Test), Ok(()));
        assert_eq!(
            orchard_only(&alone, NetworkType::Main),
            Err("is on another network")
        );
        let beside_transparent = with_receiver(&alone, Receiver::P2pkh([7; 20]));
        assert_eq!(
            orchard_only(&beside_transparent, NetworkType::Test),
            Err("must have an Orchard receiver and no other")
        );
        let beside_unknown = with_receiver(
            &alone,
            Receiver::Unknown {
                typecode: 0x05,
                data: vec![1; 32],
            },
        );
        assert_eq!(
            orchard_only(&beside_unknown, NetworkType::Test),
            Err("must have an Orchard receiver and no other")
        );
        let sapling = unified::Address::try_from_items(vec![Receiver::Sapling([9; 43])])
            .unwrap()
            .encode(&NetworkType::Test);
        assert_eq!(
            orchard_only(&sapling, NetworkType::Test),
            Err("needs an Orchard receiver")
        );
        assert_eq!(
            orchard_only("tmEZhbWHTpdKMw5it8YDspUXSMGQyFwovpU", NetworkType::Test),
            Err("must be a unified address")
        );
    }

    /// Done-when 1, the amount half: a fee of nothing, or above the cap, is
    /// refused, and the cap itself is paid.
    #[test]
    fn an_open_fee_above_the_cap_or_of_nothing_is_refused() {
        let at = |zat: u64, address: String| OpenFee { zat, address };
        let address = fee_address(NetworkType::Test);
        assert!(check_open_fee(&at(40_000, address.clone()), NetworkType::Test, 40_000).is_ok());
        for (fee, network) in [
            (at(40_001, address.clone()), NetworkType::Test),
            (at(0, address.clone()), NetworkType::Test),
            (at(20_000, address.clone()), NetworkType::Main),
            (
                at(20_000, with_receiver(&address, Receiver::P2pkh([7; 20]))),
                NetworkType::Test,
            ),
            (at(20_000, address.to_uppercase()), NetworkType::Test),
        ] {
            let refused = check_open_fee(&fee, network, 40_000).unwrap_err();
            assert_eq!(refused.code, ErrorCode::OpenFeeRefused, "{refused:?}");
        }
    }

    /// A forward record of `index` asking an open fee, its payment `paid` kept,
    /// its quote expiring at `expires_at`, ended or not.
    fn fee_record(index: u32, paid: &str, expires_at: u64, ended: bool) -> String {
        let hex = |bytes: usize, value: u8| format!("0x{}", format!("{value:02x}").repeat(bytes));
        let end = if ended {
            r#","outcome":{"type":"nothing_sent","cause":"FEE_NOT_HONOURED"},"finishedAt":1790000400"#
        } else {
            ""
        };
        format!(
            r#"{{"index":{index},"quote":{{"quoteId":"{}","maker":"0x2bac02b5032e9092493814c705f156b49e288922","makerShare":"{}","makerProof":"{}","chainId":11155111,"contract":"0x459b0a69e0f736666b66a3ffe0fc17c11f05980d","token":"0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c","amount":"1000000","depositZat":202021,"expiresAt":{expires_at},"openFee":{{"zat":20000,"address":"utest1fee"}}}},"swapId":"{}","zcashHeight":4200000,"acceptedAt":1790000000,"receives":"977550","relayerFee":"20000"{end},"openFeeMaxTotalZat":30000,"openFeeAttempted":true,"openFeePayment":{{"txId":"{}","raw":"0600","expiryHeight":4200005,"networkFeeZat":10000}}}}"#,
            hex(32, 0x22),
            hex(64, 0x0a),
            hex(64, 0x06),
            hex(32, index as u8),
            paid.repeat(32),
        )
    }

    /// Dart offers Bridge on a fee quote only within the scan lag Rust takes
    /// (`kPrivateUsdOpenFeeScanLagBlocks`): held to Rust's.
    #[test]
    fn darts_scan_lag_is_rusts() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../lib/src/features/private_usd/providers/private_usd_convert_provider.dart");
        let dart = std::fs::read_to_string(path).expect("the Dart convert provider");
        let assignment = "kPrivateUsdOpenFeeScanLagBlocks = ";
        let start = dart.find(assignment).expect("the Dart lag") + assignment.len();
        let end = start + dart[start..].find(';').expect("an assignment");
        assert_eq!(
            dart[start..end].trim(),
            OPEN_FEE_MAX_SCAN_LAG_BLOCKS.to_string()
        );
    }

    /// The wallet's resubmission withholds the open fee of a bridge that
    /// ended and of a quote that expired or has less than a minute left,
    /// read from the swap store beside the wallet DB; a fee with its quote's
    /// time ahead goes on.
    #[test]
    fn the_sync_never_sends_again_a_fee_whose_bridge_ended_or_quote_expired() {
        use super::super::models::{Direction, StoredRecord, ZcashTxId};
        use super::super::store::SwapStore;

        let support = tempfile::tempdir().unwrap();
        let db_path = support.path().join("zcash_wallet_test.db");
        let db_path = db_path.to_str().unwrap();
        assert!(
            withheld_fee_txids(db_path).is_empty(),
            "no store, nothing withheld"
        );

        let store_dir = support.path().join("private_usd_zcash_wallet_test.db_test");
        let mut store = SwapStore::open(&store_dir).unwrap();
        let later = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3_600;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        for (index, paid, expires_at, ended) in [
            (7, "aa", 1_790_000_300, true),
            (8, "bb", later, false),
            (9, "cc", 1_790_000_300, false),
            // In its quote's last minute: too late to be mined first.
            (10, "dd", now + 30, false),
        ] {
            let record = StoredRecord::decode(
                Direction::Forward,
                &fee_record(index, paid, expires_at, ended),
            )
            .unwrap();
            store.save("account", &record).unwrap();
        }
        let internal = |paid: &str| {
            super::super::joint::internal_txid(&ZcashTxId::parse(&paid.repeat(32)).unwrap())
                .unwrap()
                .as_ref()
                .to_vec()
        };
        assert_eq!(
            withheld_fee_txids(db_path),
            HashSet::from([internal("aa"), internal("cc"), internal("dd")])
        );
    }

    /// Waits follow `Retry-After`, five seconds where a `402` names none and
    /// twelve after no answer, at least a second the first time and twelve
    /// after, at most thirty, and never past the quote's end.
    #[test]
    fn an_accept_waits_as_the_maker_asks_paced_after_the_first_wait() {
        assert_eq!(accept_wait(Some(1), FEE_WAIT_SECONDS, 0, 300), 1);
        assert_eq!(accept_wait(None, FEE_WAIT_SECONDS, 0, 300), 5);
        assert_eq!(accept_wait(Some(0), FEE_WAIT_SECONDS, 0, 300), 1);
        assert_eq!(accept_wait(Some(1), FEE_WAIT_SECONDS, 1, 300), 12);
        assert_eq!(
            accept_wait(None, UNANSWERED_ACCEPT_WAIT_SECONDS, 0, 300),
            12
        );
        assert_eq!(accept_wait(Some(600), FEE_WAIT_SECONDS, 3, 300), 30);
        assert_eq!(accept_wait(Some(20), FEE_WAIT_SECONDS, 3, 7), 7);
    }
}
