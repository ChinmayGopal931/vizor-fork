//! The swap keys of one software account.
//!
//! `SwapKeyContext::open` reads the account's ZIP-32 index from the main
//! wallet DB and refuses a seed whose fingerprint is not the account's, so no
//! key is ever derived from the wrong seed. Each swap's keys then derive from
//! the seed, the account's ZIP-32 index and the swap index.

use std::fmt;

use rand_0_10::{rand_core::UnwrapErr, rngs::SysRng};
use secrecy::{ExposeSecret, SecretVec};
use zcash_client_backend::data_api::{Account as _, WalletRead};
use zecswap_core::{
    derive_deposit_keys, derive_user_keys, DepositKeys, JointAccount, Payout, PublicShare,
    ShareProof, SwapContext, UserSwapKeys,
};
use zeroize::Zeroizing;
use zip32::fingerprint::SeedFingerprint;

use super::models::{Hex, Redacted, SwapAcceptance};
use super::{fail, railgun_keys, ErrorCode, PrivateUsdError, PrivateUsdNetwork, Result};
use crate::wallet::{keys, network::WalletNetwork};

/// An account's ZIP-32 derivation, as the main wallet DB records it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct AccountDerivation {
    pub zip32_index: u32,
    pub seed_fingerprint: [u8; 32],
}

/// The derivation of `account_uuid`, or `None` when Private USD cannot run
/// for it: a hardware account (no seed on the phone) or one without ZIP-32
/// metadata.
pub(crate) fn account_derivation(
    main_db: &str,
    network: WalletNetwork,
    account_uuid: &str,
) -> Result<Option<AccountDerivation>> {
    let account_id = keys::parse_account_uuid(account_uuid)
        .map_err(|error| PrivateUsdError::new(ErrorCode::Other, error))?;
    let db = crate::wallet::sync::open_wallet_db_for_read(main_db, network)
        .map_err(|error| PrivateUsdError::new(ErrorCode::ZcashWallet, error))?;
    let account = db
        .get_account(account_id)
        .map_err(|error| PrivateUsdError::new(ErrorCode::ZcashWallet, error.to_string()))?
        .ok_or_else(|| PrivateUsdError::new(ErrorCode::Unavailable, "account not found"))?;
    let source = account.source();
    if keys::hardware_signer_kind(source).is_some() {
        return Ok(None);
    }
    Ok(source.key_derivation().map(|derivation| AccountDerivation {
        zip32_index: u32::from(derivation.account_index()),
        seed_fingerprint: derivation.seed_fingerprint().to_bytes(),
    }))
}

/// One account's seed, checked against the account, with its ZIP-32 index.
pub(crate) struct SwapKeyContext {
    network: PrivateUsdNetwork,
    zip32_index: u32,
    seed: SecretVec<u8>,
}

impl fmt::Debug for SwapKeyContext {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SwapKeyContext")
            .field("network", &self.network)
            .field("zip32_index", &self.zip32_index)
            .finish_non_exhaustive()
    }
}

impl SwapKeyContext {
    /// Parses the stored secret (a phrase or the `{version, mnemonic,
    /// bip39Passphrase}` envelope) into the 64-byte seed, passphrase included,
    /// and requires its fingerprint to be the account's.
    ///
    /// `Unavailable` on regtest, for a hardware account or one without
    /// derivation metadata; `Mismatch` for another seed.
    pub(crate) fn open(
        main_db: &str,
        network: WalletNetwork,
        account_uuid: &str,
        mnemonic_bytes: &[u8],
    ) -> Result<Self> {
        let Some(swap_network) = PrivateUsdNetwork::from_wallet(network) else {
            return fail(
                ErrorCode::Unavailable,
                "no Private USD deployment on this network",
            );
        };
        let Some(derivation) = account_derivation(main_db, network, account_uuid)? else {
            return fail(
                ErrorCode::Unavailable,
                "Private USD needs a software account with ZIP-32 derivation",
            );
        };
        let seed = keys::mnemonic_bytes_to_seed(mnemonic_bytes)
            .map_err(|_| PrivateUsdError::new(ErrorCode::Mismatch, "the secret does not parse"))?;
        let fingerprint = SeedFingerprint::from_seed(seed.expose_secret())
            .ok_or_else(|| PrivateUsdError::new(ErrorCode::Mismatch, "invalid seed length"))?;
        if fingerprint.to_bytes() != derivation.seed_fingerprint {
            return fail(ErrorCode::Mismatch, "the seed is not this account's");
        }
        Ok(Self {
            network: swap_network,
            zip32_index: derivation.zip32_index,
            seed,
        })
    }

    #[cfg(test)]
    pub(crate) fn for_tests(seed: &[u8], network: PrivateUsdNetwork, zip32_index: u32) -> Self {
        Self {
            network,
            zip32_index,
            seed: SecretVec::new(seed.to_vec()),
        }
    }

    pub(crate) fn network(&self) -> PrivateUsdNetwork {
        self.network
    }

    #[cfg(test)]
    pub(crate) fn zip32_index(&self) -> u32 {
        self.zip32_index
    }

    /// Swap `index`'s share `z`, viewing keys, auth key and note entropy.
    pub(crate) fn user_keys(&self, index: u32) -> Result<UserSwapKeys> {
        derive_user_keys(
            self.seed.expose_secret(),
            self.network.zcash(),
            self.zip32_index,
            index,
        )
        .map_err(|error| PrivateUsdError::new(ErrorCode::Other, format!("swap keys: {error}")))
    }

    /// Swap `index`'s public share `Z`.
    pub(crate) fn user_share(&self, index: u32) -> Result<PublicShare> {
        Ok(self.user_keys(index)?.share.public())
    }

    /// Swap `index`'s `user`: the never-funded key that signs its EIP-712
    /// messages.
    pub(crate) fn auth_address(&self, index: u32) -> Result<[u8; 20]> {
        Ok(self.user_keys(index)?.auth.address())
    }

    /// The Railgun note swap `index` pays out into (forward) or refunds into
    /// (reverse), in the account's own Railgun wallet. Built here, so a
    /// forward swap never needs the Railgun page.
    pub(crate) fn note(&self, index: u32) -> Result<zecswap_railgun::ShieldNote> {
        let keys = self.user_keys(index)?;
        self.railgun_keys()?
            .note(&keys.note_entropy)
            .map_err(|error| {
                PrivateUsdError::new(ErrorCode::Other, format!("payout note: {error}"))
            })
    }

    /// Accepts a quote for swap `index`: checks the maker's proof of `E` in
    /// `context`, then proves our `Z` bound to both shares and to the payout
    /// into this account's Railgun note. `Mismatch` when the maker's proof
    /// does not verify.
    pub(crate) fn acceptance(
        &self,
        index: u32,
        context: SwapContext,
        maker: &PublicShare,
        maker_proof: &[u8; 64],
    ) -> Result<SwapAcceptance> {
        context
            .verify_maker(maker, &ShareProof::from_bytes(*maker_proof))
            .map_err(|_| {
                PrivateUsdError::new(
                    ErrorCode::Mismatch,
                    "the maker's share proof does not verify",
                )
            })?;
        let keys = self.user_keys(index)?;
        let payout = Payout {
            user: keys.auth.address(),
            note: Some(self.note(index)?.commitment()),
        };
        let proof = context.prove_user(maker, &keys.share, &payout, UnwrapErr(SysRng));
        Ok(SwapAcceptance {
            user_share: Hex(keys.share.public().to_affine_bytes()),
            user_proof: Hex(proof.to_bytes()),
            viewing_keys: Redacted(Hex(keys.viewing.to_bytes())),
            token_request: None,
        })
    }

    /// The account's seed, for creating a deposit from the main wallet. It
    /// zeroizes on drop.
    pub(crate) fn seed(&self) -> SecretVec<u8> {
        SecretVec::new(self.seed.expose_secret().clone())
    }

    /// The joint account of swap `index` with the maker's share `E`, taken
    /// from the confirmed on-chain terms, never from the quote API alone.
    pub(crate) fn joint(&self, index: u32, maker: &PublicShare) -> Result<JointAccount> {
        let keys = self.user_keys(index)?;
        JointAccount::derive(maker, &keys.share.public(), &keys.viewing).map_err(|error| {
            PrivateUsdError::new(ErrorCode::Mismatch, format!("joint account: {error}"))
        })
    }

    /// The account's Railgun mnemonic, for the Railgun page.
    pub(crate) fn railgun_mnemonic(&self) -> Result<Zeroizing<String>> {
        railgun_keys::railgun_mnemonic(self.seed.expose_secret(), self.zip32_index)
            .map_err(|error| PrivateUsdError::new(ErrorCode::Other, error))
    }

    /// The account's Railgun wallet keys.
    pub(crate) fn railgun_keys(&self) -> Result<zecswap_railgun::Keys> {
        railgun_keys::railgun_keys(self.seed.expose_secret(), self.zip32_index)
            .map_err(|error| PrivateUsdError::new(ErrorCode::Other, error))
    }

    /// The account's `0zk` address. A Railgun session whose engine address
    /// differs is refused.
    pub(crate) fn railgun_address(&self) -> Result<String> {
        Ok(self.railgun_keys()?.address())
    }

    /// Deposit address `index` of the account: its Ethereum key at
    /// `m/44'/60'/(1000 + zip32)'/0/index` on mainnet, coin type `1'` on
    /// testnet, and what the notes its deposits pay are built from. The key
    /// signs only a deposit's EIP-3009 authorization and a rescue: never
    /// delegate the address (EIP-7702) or use it otherwise.
    pub(crate) fn deposit_keys(&self, index: u32) -> Result<DepositKeys> {
        derive_deposit_keys(
            self.seed.expose_secret(),
            self.network.zcash(),
            self.zip32_index,
            index,
        )
        .map_err(|error| PrivateUsdError::new(ErrorCode::Other, format!("deposit keys: {error}")))
    }
}
