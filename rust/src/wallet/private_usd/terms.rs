//! Swap ids and terms (plan reference §5.4, §5.5).
//!
//! The terms hash and the EIP-712 digests are `zecswap-core`'s
//! (`Terms::hash`, `Domain::{lock_claim, payout, open_reverse, ready,
//! lock_refund, refund_payout, rescue}`). The ids live in `zecswap-chain`,
//! which vizor does not depend on (D3), so they are written here.

use sha3::{Digest, Keccak256};
use zecswap_core::{PublicShare, ReverseOpen, Terms};

use super::deployment::Deployment;
use super::models::SwapQuote;
use super::{fail, ErrorCode, Result};

/// Keccak-256 (Ethereum's, not SHA3-256).
pub(crate) fn keccak(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Keccak256::new();
    for part in parts {
        hasher.update(part);
    }
    hasher.finalize().into()
}

/// An address as an ABI word: left-padded to 32 bytes.
pub(crate) fn address_word(address: &[u8; 20]) -> [u8; 32] {
    let mut word = [0u8; 32];
    word[12..].copy_from_slice(address);
    word
}

/// A forward swap's id, `keccak256(abi.encode(owner, share))`: the maker's
/// swap with the user's share `Z`. With the swap's auth address as owner, it
/// is also the contract's `makerKeyUsed` key for `Z`.
pub(crate) fn swap_id(owner: &[u8; 20], share: &PublicShare) -> [u8; 32] {
    keccak(&[&address_word(owner), &share.to_affine_bytes()])
}

/// A reverse escrow's id, `keccak256(abi.encode(user, makerShare, true))`:
/// never a forward swap's.
pub(crate) fn reverse_swap_id(user: &[u8; 20], maker_share: &PublicShare) -> [u8; 32] {
    let mut flag = [0u8; 32];
    flag[31] = 1;
    keccak(&[&address_word(user), &maker_share.to_affine_bytes(), &flag])
}

/// The contract's `makerKeyUsed` key for `share` spent by `auth_address` (a
/// reverse swap's own share): owner and share hashed as a swap id is.
pub(crate) fn maker_key_used_key(auth_address: &[u8; 20], share: &PublicShare) -> [u8; 32] {
    swap_id(auth_address, share)
}

/// The maker's share `E` a quote names.
pub(crate) fn quote_maker_share(quote: &SwapQuote) -> Result<PublicShare> {
    PublicShare::from_affine_bytes(&quote.maker_share.0).or_else(|_| {
        fail(
            ErrorCode::Mismatch,
            "the quote's maker share is not a valid point",
        )
    })
}

/// The terms a forward swap opens with: the pinned maker's swap of the
/// pinned token, paying this swap's auth key `user` into the Railgun note
/// `payout_note`.
pub(crate) fn forward_terms(
    pins: &Deployment,
    quote: &SwapQuote,
    user_share: PublicShare,
    user: [u8; 20],
    t0: u64,
    t1: u64,
    payout_note: [u8; 32],
) -> Result<Terms> {
    Ok(Terms {
        maker: pins.maker,
        token: pins.token,
        amount: quote.amount.0,
        maker_share: quote_maker_share(quote)?,
        user_share,
        user,
        t0,
        t1,
        payout_note,
    })
}

/// The terms a reverse escrow opens with, roles swapped: the escrowing user
/// is their `maker` and the ZEC maker their `user`, each with the other's
/// share, paying the ZEC side's balance (`zecswap_core::ReverseOpen::terms`).
pub(crate) fn reverse_terms(open: &ReverseOpen) -> Terms {
    open.terms()
}

/// The contract's `hashTerms`.
pub(crate) fn terms_hash(terms: &Terms) -> [u8; 32] {
    terms.hash()
}
