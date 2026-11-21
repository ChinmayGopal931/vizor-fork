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
//! - **Paid only with time to be mined.** At least
//!   [`OPEN_FEE_MARGIN_SECONDS`] of the quote's life is left before the
//!   payment is built and again right before it is created and stored: a
//!   stored payment is one the wallet's own sync sends again until it is
//!   mined, so that is the point of no return.
//! - **One payment.** Exactly `zat`, an empty memo, marked started before it
//!   is created and kept before it is first sent, then sent again, never
//!   built again (`forward.rs`).
//! - **Accepted once mined.** Until the maker has seen it in a block it
//!   answers the accept `402 feeRequired`, and the accept is posted again as
//!   it asks ([`accept_wait`]) until the quote expires, never after.

use zcash_address::unified::{self, Container, Encoding};
use zcash_protocol::consensus::NetworkType;

use super::deployment::{
    FEE_PACE_SECONDS, FEE_WAIT_MAX_SECONDS, FEE_WAIT_MIN_SECONDS, OPEN_FEE_MARGIN_SECONDS,
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

/// Seconds of `quote`'s life left at `now`.
pub(crate) fn time_left(quote: &SwapQuote, now: u64) -> u64 {
    quote.expires_at.saturating_sub(now)
}

/// Whether `quote` leaves its open fee the time to be mined at `now`.
pub(crate) fn time_to_pay(quote: &SwapQuote, now: u64) -> bool {
    time_left(quote, now) >= OPEN_FEE_MARGIN_SECONDS
}

/// `QuoteExpired` once `quote` leaves its open fee too little time to be
/// mined first: nothing is paid for it.
pub(crate) fn require_time_to_pay(quote: &SwapQuote, now: u64) -> Result<()> {
    if !time_to_pay(quote, now) {
        return fail(
            ErrorCode::QuoteExpired,
            format!(
                "the quote expires in {}s, too soon for its open fee to be mined first",
                time_left(quote, now)
            ),
        );
    }
    Ok(())
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
