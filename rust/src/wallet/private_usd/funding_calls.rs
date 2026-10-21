//! The three calls a reverse swap's funding makes from Railgun: approve exactly
//! the escrow amount to the contract, open the escrow with the user's
//! `OpenReverse` signature, then pay the relayer its fee for the gas. The
//! Railgun page proves one Relay Adapt transaction that makes them; nothing
//! here signs or sends.
//!
//! The ABI has no dynamic part but the signature: `openReverse`'s terms tuple
//! is twelve static words in place, then the offset and the 65 signature
//! bytes, padded. 548 bytes in all, as the relayer expects.

use zecswap_core::ReverseOpen;

use super::abi::{address_word, call_data, uint_word, Call, WORD};

pub(crate) const OPEN_REVERSE: &str =
    "openReverse((address,address,address,uint128,uint256[2],uint256[2],uint64,uint64,bytes32,uint64),bytes)";
pub(crate) const APPROVE: &str = "approve(address,uint256)";
pub(crate) const TRANSFER: &str = "transfer(address,uint256)";

/// `openReverse`'s terms tuple, in words: three addresses, the amount, two
/// shares of two words each, the deadlines and the refund note.
const OPEN_TERMS_WORDS: usize = 12;
const SIGNATURE_BYTES: usize = 65;

/// The funding's calls, in order: `token.approve(contract, amount)`,
/// `contract.openReverse(terms, signature)`, `token.transfer(relayer, fee)`.
pub(crate) fn encode(
    contract: [u8; 20],
    relayer: [u8; 20],
    open: &ReverseOpen,
    signature: &[u8; 65],
    fee: u128,
) -> [Call; 3] {
    [
        Call {
            to: open.token,
            data: call_data(APPROVE, &[address_word(&contract), uint_word(open.amount)]),
        },
        Call {
            to: contract,
            data: open_reverse(open, signature),
        },
        Call {
            to: open.token,
            data: call_data(TRANSFER, &[address_word(&relayer), uint_word(fee)]),
        },
    ]
}

/// `openReverse(terms, signature)`, in the contract's `ReverseOpen` order:
/// the ZEC maker as `maker`, the escrowing user's swap address as `user`, and
/// each share as its affine `x ‖ y`.
fn open_reverse(open: &ReverseOpen, signature: &[u8; 65]) -> Vec<u8> {
    let mut words = Vec::with_capacity(OPEN_TERMS_WORDS + 2);
    words.push(address_word(&open.maker));
    words.push(address_word(&open.user));
    words.push(address_word(&open.token));
    words.push(uint_word(open.amount));
    for share in [&open.maker_share, &open.user_share] {
        let share = share.to_affine_bytes();
        words.push(share[..WORD].try_into().expect("32 bytes"));
        words.push(share[WORD..].try_into().expect("32 bytes"));
    }
    words.push(uint_word(open.t0.into()));
    words.push(uint_word(open.t1.into()));
    words.push(open.refund_note);
    words.push(uint_word(open.deadline.into()));
    // The signature's bytes follow the head: the tuple in place and this
    // offset.
    words.push(uint_word(((OPEN_TERMS_WORDS + 1) * WORD) as u128));
    words.push(uint_word(SIGNATURE_BYTES as u128));
    let mut data = call_data(OPEN_REVERSE, &words);
    data.extend_from_slice(signature);
    data.resize(data.len() + (WORD - SIGNATURE_BYTES % WORD) % WORD, 0);
    data
}
