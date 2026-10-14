//! The three calls a reverse swap's funding makes from Railgun (reference
//! §5.7 step 4.5; zapp `of/ReverseFundingCalls.kt`): approve exactly the
//! escrow amount to the contract, open the escrow with the user's
//! `OpenReverse` signature, then pay the relayer its fee for the gas. The
//! Railgun page proves one Relay Adapt transaction that makes them; nothing
//! here signs or sends.
//!
//! The ABI has no dynamic part but the signature: `openReverse`'s terms tuple
//! is twelve static words in place, then the offset and the 65 signature
//! bytes, padded. 548 bytes in all, as zecSwap's relayer expects.

use super::evm_rpc::selector;
use super::terms::address_word;

pub(crate) const OPEN_REVERSE: &str =
    "openReverse((address,address,address,uint128,uint256[2],uint256[2],uint64,uint64,bytes32,uint64),bytes)";
pub(crate) const APPROVE: &str = "approve(address,uint256)";
pub(crate) const TRANSFER: &str = "transfer(address,uint256)";

const WORD: usize = 32;
/// `openReverse`'s terms tuple, in words: three addresses, the amount, two
/// shares of two words each, the deadlines and the refund note.
const OPEN_TERMS_WORDS: usize = 12;
const SIGNATURE_BYTES: usize = 65;

/// What `openReverse` takes, in the contract's `ReverseOpen` order: the ZEC
/// maker as `maker`, the escrowing user's swap address as `user`. Each share
/// is its affine `x ‖ y`, two big-endian words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct OpenReverseArgs {
    pub maker: [u8; 20],
    pub user: [u8; 20],
    pub token: [u8; 20],
    pub amount: u128,
    pub maker_share: [u8; 64],
    pub user_share: [u8; 64],
    /// The ready deadline.
    pub t0: u64,
    /// When a refund may follow.
    pub t1: u64,
    pub refund_note: [u8; 32],
    /// The funding deadline.
    pub deadline: u64,
}

/// One call of the funding: its target and calldata.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ContractCall {
    pub to: [u8; 20],
    pub data: Vec<u8>,
}

/// The funding's calls, in order: `token.approve(contract, amount)`,
/// `contract.openReverse(terms, signature)`, `token.transfer(relayer, fee)`.
pub(crate) fn encode(
    contract: [u8; 20],
    relayer: [u8; 20],
    open: &OpenReverseArgs,
    signature: &[u8; 65],
    fee: u128,
) -> [ContractCall; 3] {
    [
        ContractCall {
            to: open.token,
            data: approve(&contract, open.amount),
        },
        ContractCall {
            to: contract,
            data: open_reverse(open, signature),
        },
        ContractCall {
            to: open.token,
            data: transfer(&relayer, fee),
        },
    ]
}

/// ERC-20 `approve(spender, amount)`.
pub(crate) fn approve(spender: &[u8; 20], amount: u128) -> Vec<u8> {
    call(APPROVE, &[address_word(spender), uint_word(amount)])
}

/// ERC-20 `transfer(to, amount)`.
pub(crate) fn transfer(to: &[u8; 20], amount: u128) -> Vec<u8> {
    call(TRANSFER, &[address_word(to), uint_word(amount)])
}

/// `openReverse(terms, signature)`.
pub(crate) fn open_reverse(open: &OpenReverseArgs, signature: &[u8; 65]) -> Vec<u8> {
    let mut words = Vec::with_capacity(OPEN_TERMS_WORDS + 1);
    words.push(address_word(&open.maker));
    words.push(address_word(&open.user));
    words.push(address_word(&open.token));
    words.push(uint_word(open.amount));
    for share in [&open.maker_share, &open.user_share] {
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
    let mut data = call(OPEN_REVERSE, &words);
    data.extend_from_slice(signature);
    data.resize(data.len() + padding(SIGNATURE_BYTES), 0);
    data
}

fn call(signature: &str, words: &[[u8; 32]]) -> Vec<u8> {
    let mut data = selector(signature).to_vec();
    for word in words {
        data.extend_from_slice(word);
    }
    data
}

fn uint_word(value: u128) -> [u8; 32] {
    let mut word = [0u8; 32];
    word[16..].copy_from_slice(&value.to_be_bytes());
    word
}

/// The zero bytes that fill `length` bytes out to whole words.
fn padding(length: usize) -> usize {
    (WORD - length % WORD) % WORD
}
