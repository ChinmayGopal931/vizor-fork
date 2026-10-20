//! Swap ids and terms.
//!
//! The terms hash and the EIP-712 digests are `zecswap-core`'s (`Terms::hash`,
//! `Domain`). The ids live in `zecswap-chain`, which this crate does not
//! depend on, so they are written here.

use zecswap_core::{PublicShare, Terms};

use super::abi::{address_word, keccak};
use super::deployment::Deployment;
use super::models::SwapQuote;
use super::{fail, ErrorCode, Result};

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
