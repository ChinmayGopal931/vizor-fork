//! Known-answer vectors (plan §3.3, reference §5.4 and §5.5), pinned in
//! `vectors.json`. Signatures are deterministic (RFC 6979), so they compare
//! byte for byte. `joint` holds the joint-account and deposit tests (M2),
//! `ironwood_regtest` the ignored test against the regtest stack, `forward`
//! the forward conversion's fund-safety tests on the `fakes` (M5), and
//! `lifecycle` the account deletion and drain guards (M5).

use serde_json::Value;
use zecswap_core::{
    derive_maker_share, Domain, NetworkType, RescueAuthorization, ReverseOpen, SecretShare, Terms,
};
use zecswap_railgun::Keys;

use super::{evm_rpc, keys::SwapKeyContext, railgun_keys, terms, ErrorCode, PrivateUsdNetwork};
use crate::wallet::{keys, network::WalletNetwork};
use secrecy::ExposeSecret;

mod fakes;
mod forward;
mod ironwood_regtest;
mod joint;
mod lifecycle;

fn vectors() -> Value {
    serde_json::from_str(include_str!("vectors.json")).unwrap()
}

fn text(value: &Value) -> &str {
    value.as_str().unwrap()
}

fn bytes<const N: usize>(value: &Value) -> [u8; N] {
    hex::decode(text(value).trim_start_matches("0x"))
        .unwrap()
        .try_into()
        .unwrap()
}

fn hex0x(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

/// Base58Check, for the BIP-85 specification's `xprv`.
fn base58check(text: &str) -> Vec<u8> {
    const ALPHABET: &[u8] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    let mut number: Vec<u8> = Vec::new();
    for c in text.bytes() {
        let mut carry = ALPHABET.iter().position(|a| *a == c).unwrap() as u32;
        for byte in number.iter_mut().rev() {
            carry += u32::from(*byte) * 58;
            *byte = carry as u8;
            carry >>= 8;
        }
        while carry > 0 {
            number.insert(0, carry as u8);
            carry >>= 8;
        }
    }
    let zeros = text.bytes().take_while(|c| *c == b'1').count();
    let decoded = [vec![0; zeros], number].concat();
    let (payload, checksum) = decoded.split_at(decoded.len() - 4);
    use sha2::{Digest, Sha256};
    assert_eq!(&Sha256::digest(Sha256::digest(payload))[..4], checksum);
    payload.to_vec()
}

#[test]
fn bip85_matches_the_specification() {
    let vector = &vectors()["bip85"];
    let xprv = base58check(text(&vector["xprv"]));
    assert_eq!(xprv.len(), 78);
    let chain_code: [u8; 32] = xprv[13..45].try_into().unwrap();
    assert_eq!(xprv[45], 0);
    let key: [u8; 32] = xprv[46..78].try_into().unwrap();

    let entropy = railgun_keys::tests::entropy_from_xprv_parts(key, chain_code, 0);
    assert_eq!(hex::encode(*entropy), text(&vector["entropy"]));
    assert_eq!(
        keys::mnemonic_from_entropy(entropy.to_vec()).unwrap(),
        text(&vector["mnemonic"])
    );
}

/// zapp's vector, and vizor's: a BIP-39 passphrase (D7) and ZIP-32 index 1
/// (D8) give their own Railgun wallet.
#[test]
fn railgun_wallets_match_zapp_and_pin_d7_and_d8() {
    for case in vectors()["railgun"].as_array().unwrap() {
        let seed = keys::mnemonic_to_seed_with_passphrase(
            text(&case["mnemonic"]),
            text(&case["passphrase"]),
        )
        .unwrap();
        let seed = seed.expose_secret();
        let index = case["zip32Index"].as_u64().unwrap() as u32;
        let name = text(&case["name"]);

        let entropy = railgun_keys::bip85_entropy(seed, index).unwrap();
        assert_eq!(hex::encode(*entropy), text(&case["entropy"]), "{name}");
        let words = railgun_keys::railgun_mnemonic(seed, index).unwrap();
        assert_eq!(words.as_str(), text(&case["railgunMnemonic"]), "{name}");
        let railgun_seed = railgun_keys::railgun_seed(seed, index).unwrap();
        assert_eq!(
            hex::encode(railgun_seed.expose_secret()),
            text(&case["railgunSeed"]),
            "{name}"
        );
        let address = railgun_keys::railgun_keys(seed, index).unwrap().address();
        assert_eq!(address, text(&case["address"]), "{name}");
        assert!(railgun_keys::is_valid_railgun_address(&address));
    }
}

/// The vizor vector through an account: the stored passphrase envelope
/// (D7) and the ZIP-32 index the wallet DB records (D8). Any other seed,
/// here the same words without the passphrase, is refused.
#[test]
fn the_vizor_vector_through_an_account() {
    let case = vectors()["railgun"][1].clone();
    let mnemonic = text(&case["mnemonic"]);
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("wallet.db");
    let db = db.to_str().unwrap();
    let seed = keys::mnemonic_to_seed_with_passphrase(mnemonic, "vizor").unwrap();
    keys::init_db_and_create_account(db, WalletNetwork::Test, &seed, None, "zero").unwrap();
    let (uuid, _) =
        keys::import_derived_account_at_index(db, WalletNetwork::Test, &seed, None, "one", 1)
            .unwrap();

    let envelope = serde_json::json!({
        "version": 1,
        "mnemonic": mnemonic,
        "bip39Passphrase": "vizor",
    })
    .to_string();
    let context =
        SwapKeyContext::open(db, WalletNetwork::Test, &uuid, envelope.as_bytes()).unwrap();
    assert_eq!(context.zip32_index(), 1);
    assert_eq!(
        context.railgun_mnemonic().unwrap().as_str(),
        text(&case["railgunMnemonic"])
    );
    assert_eq!(context.railgun_address().unwrap(), text(&case["address"]));

    let refused =
        SwapKeyContext::open(db, WalletNetwork::Test, &uuid, mnemonic.as_bytes()).unwrap_err();
    assert_eq!(refused.code, ErrorCode::Mismatch);
}

#[test]
fn railgun_keys_match_the_engine() {
    for wallet in vectors()["engine"].as_array().unwrap() {
        let seed = hex::decode(text(&wallet["seed"]).trim_start_matches("0x")).unwrap();
        let index = wallet["index"].as_u64().unwrap() as u32;
        assert_eq!(
            Keys::from_seed(&seed, index).address(),
            text(&wallet["address"])
        );
    }
}

#[test]
fn swap_keys_notes_ids_and_eip712_match_zecswap() {
    let vector = &vectors()["swap"];
    let inputs = &vector["inputs"];
    let maker_address: [u8; 20] = bytes(&inputs["maker"]);
    let relayer: [u8; 20] = bytes(&inputs["relayer"]);
    let deadline = inputs["deadline"].as_u64().unwrap();
    let fee = u128::from(inputs["fee"].as_u64().unwrap());

    // The Testnet mapping gives coin type 1, as the vectors were made.
    let context = SwapKeyContext::for_tests(&[7; 64], PrivateUsdNetwork::Testnet, 0);
    assert_eq!(context.network().zcash(), NetworkType::Test);
    let keys = context.user_keys(0).unwrap();
    let user_share = keys.share.public();
    assert_eq!(
        hex0x(&user_share.to_affine_bytes()),
        text(&vector["userShare"])
    );
    assert_eq!(
        hex0x(&keys.share.to_be_bytes()),
        text(&vector["userSecret"])
    );
    assert_eq!(
        hex0x(&keys.viewing.to_bytes()),
        text(&vector["viewingKeys"])
    );
    let auth = context.auth_address(0).unwrap();
    assert_eq!(hex0x(&auth), text(&vector["authAddress"]));

    let maker_secret = derive_maker_share(&[9; 32], 0).unwrap();
    let maker_share = maker_secret.public();
    assert_eq!(
        hex0x(&maker_share.to_affine_bytes()),
        text(&vector["makerShare"])
    );
    let id = terms::swap_id(&maker_address, &user_share);
    assert_eq!(hex0x(&id), text(&vector["swapId"]));

    // The joint account from the shares, and its combined key.
    let joint = context.joint(0, &maker_share).unwrap();
    assert_eq!(
        joint.unified_address(NetworkType::Test),
        text(&vector["jointUaTest"])
    );
    assert_eq!(
        joint.ufvk(NetworkType::Test),
        text(&vector["jointUfvkTest"])
    );
    assert_eq!(
        joint.unified_address(NetworkType::Main),
        text(&vector["jointUaMain"])
    );
    assert!(joint.spend_key(&maker_secret, &keys.share).is_ok());
    let revealed = SecretShare::from_be_bytes(&keys.share.to_be_bytes()).unwrap();
    assert_eq!(revealed.public(), user_share);

    // Payout notes into Railgun wallet 0 of a seed, from the swap's entropy.
    let notes = vector["notes"].as_array().unwrap();
    let mut commitments = Vec::new();
    for case in notes {
        let fill = case["byte"].as_u64().unwrap() as u8;
        let wallet = Keys::from_seed(&[fill; 64], 0);
        assert_eq!(wallet.address(), text(&case["address"]));
        let note = wallet.note(&keys.note_entropy).unwrap();
        assert_eq!(hex0x(&note.npk), text(&case["npk"]));
        for (word, expected) in note
            .ciphertext
            .encrypted_bundle
            .iter()
            .zip(case["bundle"].as_array().unwrap())
        {
            assert_eq!(hex0x(word), text(expected));
        }
        assert_eq!(hex0x(&note.ciphertext.shield_key), text(&case["shieldKey"]));
        assert_eq!(hex0x(&note.commitment()), text(&case["payoutNote"]));
        commitments.push(note.commitment());
    }
    let (own_note, railgun_note) = (commitments[0], commitments[1]);

    // EIP-712, signed by the swap's auth key.
    let domain = Domain {
        chain_id: inputs["chainId"].as_u64().unwrap(),
        contract: bytes(&inputs["contract"]),
    };
    let lock = domain.lock_claim(&id, deadline);
    assert_eq!(hex0x(&lock), text(&vector["lockClaimDigest"]));
    assert_eq!(
        hex0x(&keys.auth.sign(&lock)),
        text(&vector["lockClaimSignature"])
    );
    let payout = domain.payout(&id, &relayer, fee);
    assert_eq!(hex0x(&payout), text(&vector["payoutDigest"]));
    assert_eq!(
        hex0x(&keys.auth.sign(&payout)),
        text(&vector["payoutSignature"])
    );

    let reverse_id = terms::reverse_swap_id(&auth, &maker_share);
    assert_eq!(hex0x(&reverse_id), text(&vector["reverseSwapId"]));
    let open = ReverseOpen {
        maker: maker_address,
        user: auth,
        token: bytes(&inputs["token"]),
        amount: u128::from(vector["reverseOpen"]["amount"].as_u64().unwrap()),
        maker_share,
        user_share,
        t0: vector["reverseOpen"]["t0"].as_u64().unwrap(),
        t1: vector["reverseOpen"]["t1"].as_u64().unwrap(),
        refund_note: own_note,
        deadline,
    };
    for (digest, signature) in [
        (domain.open_reverse(&open), "openReverseSignature"),
        (domain.ready(&reverse_id, deadline), "readySignature"),
        (
            domain.lock_refund(&reverse_id, deadline),
            "lockRefundSignature",
        ),
        (
            domain.refund_payout(&reverse_id, &relayer, fee),
            "refundPayoutSignature",
        ),
        (
            domain.open_reverse(&ReverseOpen {
                refund_note: railgun_note,
                ..open.clone()
            }),
            "openReverseToRailgunSeedSignature",
        ),
        (
            domain.rescue(
                &reverse_id,
                &railgun_note,
                &relayer,
                fee,
                RescueAuthorization { nonce: 0, deadline },
            ),
            "rescueSignature",
        ),
    ] {
        assert_eq!(
            hex0x(&keys.auth.sign(&digest)),
            text(&vector[signature]),
            "{signature}"
        );
    }

    // Terms hashes: paid to an account, into Railgun, and a reverse escrow.
    let hashes = &vector["termsHashes"];
    let pays_account = Terms {
        maker: maker_address,
        token: bytes(&inputs["token"]),
        amount: u128::from(hashes["amount"].as_u64().unwrap()),
        maker_share,
        user_share,
        user: bytes(&inputs["payee"]),
        t0: hashes["t0"].as_u64().unwrap(),
        t1: hashes["t1"].as_u64().unwrap(),
        payout_note: [0; 32],
    };
    let pays_railgun = Terms {
        user: auth,
        payout_note: railgun_note,
        ..pays_account.clone()
    };
    assert_eq!(
        hex0x(&terms::terms_hash(&pays_account)),
        text(&hashes["paysAccount"])
    );
    assert_eq!(
        hex0x(&terms::terms_hash(&pays_railgun)),
        text(&hashes["paysRailgun"])
    );
    assert_eq!(
        hex0x(&terms::terms_hash(&terms::reverse_terms(&open))),
        text(&hashes["reverse"])
    );
}

/// The contract reads' selectors, and Keccak (not SHA3) under them.
#[test]
fn selectors_match_the_contract() {
    for (signature, expected) in vectors()["selectors"].as_object().unwrap() {
        let expected = text(expected);
        if expected.len() == 2 + 8 {
            assert_eq!(
                hex0x(&evm_rpc::selector(signature)),
                expected,
                "{signature}"
            );
        } else {
            assert_eq!(
                hex0x(&terms::keccak(&[signature.as_bytes()])),
                expected,
                "{signature}"
            );
        }
    }
    for signature in [
        evm_rpc::GET_SWAP,
        evm_rpc::LOCK_DURATION,
        evm_rpc::MAKER_KEY_USED,
        evm_rpc::REVERSE_FUNDING,
        evm_rpc::VAULT_OF,
        evm_rpc::RESCUE_NONCES,
        evm_rpc::TOKEN_BLOCKLIST,
        evm_rpc::BALANCE_OF,
        evm_rpc::PAID_OUT_EVENT,
    ] {
        assert!(
            vectors()["selectors"].get(signature).is_some(),
            "{signature}"
        );
    }
}
