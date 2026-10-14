//! The account's Railgun wallet, derived as zapp derives it with D7 and D8
//! applied (plan §3.3):
//!
//! 1. `seed`: the account's 64-byte BIP-39 seed, passphrase included (D7).
//! 2. BIP-32 secp256k1 to `m/83696968'/39'/0'/24'/{zip32 index}'` (BIP-85,
//!    English, 24 words; the index is the account's ZIP-32 index, D8).
//! 3. `entropy = HMAC-SHA512("bip-entropy-from-k", key)[..32]`.
//! 4. The Railgun mnemonic: the 24 English words of `entropy`.
//! 5. `railgunSeed`: that mnemonic's BIP-39 seed, empty passphrase.
//! 6. Railgun wallet 0 of `railgunSeed` (`zecswap_railgun::Keys`), and its
//!    `0zk` address.
//!
//! None of these is stored: each use derives them again and drops them.

use bech32::{primitives::decode::CheckedHrpstring, Bech32m};
use hmac::{Hmac, Mac};
use secp256k1::{Scalar, SecretKey};
use secrecy::{ExposeSecret, SecretVec};
use sha2::Sha512;
use zeroize::Zeroizing;

use crate::wallet::keys;

const BIP32_MASTER_KEY: &[u8] = b"Bitcoin seed";
const BIP85_ENTROPY_KEY: &[u8] = b"bip-entropy-from-k";
/// `m/83696968'/39'/0'/24'`: BIP-85, BIP-39, English, 24 words.
const BIP85_BIP39_PATH: [u32; 4] = [83_696_968, 39, 0, 24];
const HARDENED: u32 = 0x8000_0000;
/// Railgun's wallets open the first wallet of a seed, and swaps pay into it.
const RAILGUN_WALLET: u32 = 0;

/// `0zk` addresses: bech32m over version 1, the master public key, the
/// network id and the viewing public key (73 bytes), at most 127 characters.
const RAILGUN_HRP: &str = "0zk";
const RAILGUN_ADDRESS_BYTES: usize = 73;
const RAILGUN_ADDRESS_VERSION: u8 = 1;
const RAILGUN_ADDRESS_MAX_LENGTH: usize = 127;

type Node = (Zeroizing<[u8; 32]>, Zeroizing<[u8; 32]>);

/// BIP-85 entropy for a 24-word BIP-39 mnemonic at `index` of `seed64`.
pub(crate) fn bip85_entropy(seed64: &[u8], index: u32) -> Result<Zeroizing<[u8; 32]>, String> {
    if seed64.len() != 64 {
        return Err(format!("the seed must be 64 bytes, not {}", seed64.len()));
    }
    let master = split(hmac(BIP32_MASTER_KEY, &[seed64]));
    // A master key of zero or past the curve order is unusable (BIP-32).
    SecretKey::from_slice(&*master.0).map_err(|_| "unusable BIP-32 master key".to_string())?;
    entropy_from_master(master, index)
}

/// Steps 2 and 3 from a BIP-32 master `(key, chain code)`.
fn entropy_from_master(master: Node, index: u32) -> Result<Zeroizing<[u8; 32]>, String> {
    if index >= HARDENED {
        return Err(format!("BIP-85 index {index} is out of range"));
    }
    let mut node = master;
    for segment in BIP85_BIP39_PATH.iter().chain([&index]) {
        node = hardened_child(&node, *segment)?;
    }
    let mut entropy = Zeroizing::new([0u8; 32]);
    entropy.copy_from_slice(&hmac(BIP85_ENTROPY_KEY, &[&*node.0])[..32]);
    Ok(entropy)
}

/// Hardened BIP-32 CKD needs no point math:
/// `I = HMAC-SHA512(chain, 0x00 ‖ k ‖ i')`, `k' = (I_L + k) mod n`,
/// `chain' = I_R`.
fn hardened_child((key, chain_code): &Node, index: u32) -> Result<Node, String> {
    let hardened = (index | HARDENED).to_be_bytes();
    let (tweak, child_chain_code) = split(hmac(&**chain_code, &[&[0], &**key, &hardened]));
    // `I_L >= n`, or a zero child key, makes this child invalid (BIP-32;
    // probability about 2^-127).
    let tweak = Scalar::from_be_bytes(*tweak).map_err(|_| "invalid BIP-32 child".to_string())?;
    let child = SecretKey::from_slice(&**key)
        .and_then(|parent| parent.add_tweak(&tweak))
        .map_err(|_| "invalid BIP-32 child".to_string())?;
    Ok((Zeroizing::new(child.secret_bytes()), child_chain_code))
}

fn split(output: Zeroizing<[u8; 64]>) -> Node {
    let (mut left, mut right) = (Zeroizing::new([0u8; 32]), Zeroizing::new([0u8; 32]));
    left.copy_from_slice(&output[..32]);
    right.copy_from_slice(&output[32..]);
    (left, right)
}

fn hmac(key: &[u8], parts: &[&[u8]]) -> Zeroizing<[u8; 64]> {
    let mut mac = Hmac::<Sha512>::new_from_slice(key).expect("HMAC takes keys of any length");
    for part in parts {
        mac.update(part);
    }
    let mut output = Zeroizing::new([0u8; 64]);
    output.copy_from_slice(&mac.finalize().into_bytes());
    output
}

/// The account's Railgun mnemonic (step 4).
pub(crate) fn railgun_mnemonic(
    seed64: &[u8],
    zip32_index: u32,
) -> Result<Zeroizing<String>, String> {
    let entropy = bip85_entropy(seed64, zip32_index)?;
    keys::mnemonic_from_entropy(entropy.to_vec())
        .map(Zeroizing::new)
        .map_err(|_| "could not encode the Railgun mnemonic".to_string())
}

/// The Railgun wallet's own 64-byte seed (step 5).
pub(crate) fn railgun_seed(seed64: &[u8], zip32_index: u32) -> Result<SecretVec<u8>, String> {
    let words = railgun_mnemonic(seed64, zip32_index)?;
    keys::mnemonic_to_seed(&words)
}

/// The account's Railgun wallet keys (step 6).
pub(crate) fn railgun_keys(
    seed64: &[u8],
    zip32_index: u32,
) -> Result<zecswap_railgun::Keys, String> {
    let railgun_seed = railgun_seed(seed64, zip32_index)?;
    Ok(zecswap_railgun::Keys::from_seed(
        railgun_seed.expose_secret(),
        RAILGUN_WALLET,
    ))
}

/// Whether `address` is a Railgun `0zk` address: lowercase bech32m (not
/// bech32), hrp `0zk`, 73 bytes, version 1, at most 127 characters. A QR code
/// may carry it in capitals; lowercase it before asking (zapp's
/// `RailgunAddress.parseOrNull`).
pub(crate) fn is_valid_railgun_address(address: &str) -> bool {
    if address.len() > RAILGUN_ADDRESS_MAX_LENGTH || address.bytes().any(|b| b.is_ascii_uppercase())
    {
        return false;
    }
    let Ok(checked) = CheckedHrpstring::new::<Bech32m>(address) else {
        return false;
    };
    if checked.hrp().as_str() != RAILGUN_HRP {
        return false;
    }
    let data: Vec<u8> = checked.byte_iter().collect();
    data.len() == RAILGUN_ADDRESS_BYTES && data[0] == RAILGUN_ADDRESS_VERSION
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Steps 2 and 3 from a BIP-32 master given as its key and chain code,
    /// for the BIP-85 specification's vector (an `xprv`).
    pub(crate) fn entropy_from_xprv_parts(
        key: [u8; 32],
        chain_code: [u8; 32],
        index: u32,
    ) -> Zeroizing<[u8; 32]> {
        entropy_from_master((Zeroizing::new(key), Zeroizing::new(chain_code)), index).unwrap()
    }

    #[test]
    fn railgun_addresses_validate_only_as_bech32m_0zk() {
        let valid = [
            // The pinned relayers', and the plan's known-answer addresses.
            "0zk1qy860uut20m8gd6fnhzvr0zqeyhs0ya5247x7h2eyedxsazx43w5nrv7j6fe3z53l78hn78kmslky2206lm75mclrv7dawd756m2suy7l4zud2m4yhg6kcsn7ed",
            "0zk1qy25r4x4qjhtlfe0k9z22jy9psfm83j4k4fgvqs3pmv4he4ytefm8rv7j6fe3z53lltumh8amd66g2axaej92dmjk6mvnuveqtmmwccdm593pft827p4xpwljug",
            "0zk1qy4jkxxr9zsw46luz7hvp2j6rtqmjws6ttnrrr6uf485mg9xwpwu0rv7j6fe3z53llrc73lffkv84nudklsglyryy0703mu97e8sgn6sk8anxxypf8jjz382jz9",
            "0zk1qy9fp87z33daqyvxaqveyjgrpx243jupm2sprzzply0qtp948rafnrv7j6fe3z53la94m9hv6a8k9t6g6lslxsmyua7rcaclem6j2ekcjxpvg5w0v68dzd7477k",
            "0zk1qyt5x0c632363rrmd8psxws6n9tscm8gps277gzc0w3s5cg4mdpe9rv7j6fe3z53luahk4ksjwagt68fl2vguye054rxjyqzvhs9usq4rwrk09al6n0677pdrgn",
            "0zk1qyrs4qyrd08p6uep0fc2y8njktgcpezts3rpaq6q0ln948ecjkw8prv7j6fe3z53llz8ursderja0juwv5pgnv8x5klmmwkv8q38h9n704h4d4qjyw7n5qk68nx",
        ];
        for address in valid {
            assert!(is_valid_railgun_address(address), "{address}");
            // One character changed breaks the checksum.
            let mut changed = address.to_string();
            let last = changed.pop().unwrap();
            changed.push(if last == 'q' { 'p' } else { 'q' });
            assert!(!is_valid_railgun_address(&changed), "{changed}");
        }
        assert!(!is_valid_railgun_address(
            "0x4370eEaa6bEcf1dAeF21Deeb0379Eb7f6CaEf7eF"
        ));
        assert!(!is_valid_railgun_address(""));

        // The same 73 bytes under a bech32 (not bech32m) checksum.
        let payload: Vec<u8> = CheckedHrpstring::new::<Bech32m>(valid[0])
            .unwrap()
            .byte_iter()
            .collect();
        let bech32 =
            bech32::encode::<bech32::Bech32>(bech32::Hrp::parse("0zk").unwrap(), &payload).unwrap();
        assert!(!is_valid_railgun_address(&bech32), "{bech32}");
    }
}
