//! The few dynamic ABI shapes deposits need (plan M9), beside `evm_rpc`'s
//! word-only calls: Multicall3's `aggregate3` call and its answer, a
//! `string` answer (`name()`, `version()`), and Railgun's `Shield` event.
//!
//! Every decoder is strict: an offset or a length that points outside the
//! data, or that is not where the ABI puts it, is `ChainUnreadable`, never a
//! guess.

use zecswap_railgun::{ShieldCiphertext, ShieldNote};

use super::terms::address_word;
use super::{fail, ErrorCode, PrivateUsdError, Result};

const WORD: usize = 32;

/// `aggregate3((address,bool,bytes)[])`.
pub(crate) const AGGREGATE3: &str = "aggregate3((address,bool,bytes)[])";
/// Railgun's `Shield(uint256 treeNumber, uint256 startPosition,
/// CommitmentPreimage[] commitments, ShieldCiphertext[] shieldCiphertext,
/// uint256[] fees)`.
pub(crate) const RAILGUN_SHIELD_EVENT: &str =
    "Shield(uint256,uint256,(bytes32,(uint8,address,uint256),uint120)[],(bytes32[3],bytes32)[],uint256[])";
/// A `CommitmentPreimage`: `npk`, the token's type, address and sub-id,
/// and the value.
const PREIMAGE_WORDS: usize = 5;
/// A `ShieldCiphertext`: three bundle words and the shield key.
const CIPHERTEXT_WORDS: usize = 4;

/// One call of an `aggregate3`: its target and calldata. None may fail
/// (`allowFailure` false), so one failing reverts the whole read.
pub(crate) struct Call3 {
    pub target: [u8; 20],
    pub data: Vec<u8>,
}

/// `aggregate3(calls)`'s calldata, selector included.
pub(crate) fn encode_aggregate3(selector: [u8; 4], calls: &[Call3]) -> Vec<u8> {
    let mut out = selector.to_vec();
    // The one argument is a dynamic array: its offset, then the array.
    out.extend_from_slice(&uint_word(WORD as u64));
    out.extend_from_slice(&uint_word(calls.len() as u64));
    // Each element is a dynamic tuple: offsets from the start of the
    // element area, then the tuples.
    let tuples: Vec<Vec<u8>> = calls.iter().map(encode_call3).collect();
    let mut offset = calls.len() * WORD;
    for tuple in &tuples {
        out.extend_from_slice(&uint_word(offset as u64));
        offset += tuple.len();
    }
    for tuple in tuples {
        out.extend_from_slice(&tuple);
    }
    out
}

/// `(address target, bool allowFailure, bytes callData)`, with
/// `allowFailure` false.
fn encode_call3(call: &Call3) -> Vec<u8> {
    let mut tuple = Vec::with_capacity(5 * WORD + call.data.len());
    tuple.extend_from_slice(&address_word(&call.target));
    tuple.extend_from_slice(&[0u8; WORD]);
    // `callData` follows the tuple's three head words.
    tuple.extend_from_slice(&uint_word(3 * WORD as u64));
    tuple.extend_from_slice(&uint_word(call.data.len() as u64));
    tuple.extend_from_slice(&call.data);
    let padding = (WORD - call.data.len() % WORD) % WORD;
    tuple.extend(std::iter::repeat_n(0u8, padding));
    tuple
}

/// `aggregate3`'s answer, `(bool success, bytes returnData)[]`: each call's
/// return data, in order. The count must be `expected`, and every call must
/// have succeeded.
pub(crate) fn decode_aggregate3(data: &[u8], expected: usize) -> Result<Vec<Vec<u8>>> {
    let array = offset_at(data, 0, 0)?;
    let count = usize_at(data, array)?;
    if count != expected {
        return fail(
            ErrorCode::ChainUnreadable,
            format!("Multicall3 answered {count} results for {expected} calls"),
        );
    }
    let elements = array + WORD;
    let mut results = Vec::with_capacity(count);
    for i in 0..count {
        let element = offset_at(data, elements + i * WORD, elements)?;
        let success = word_at(data, element)?;
        if !is_bool(&success) {
            return unreadable("a Multicall3 result's success is not a bool");
        }
        if success[WORD - 1] != 1 {
            return fail(ErrorCode::ChainUnreadable, "a Multicall3 call failed");
        }
        let bytes = offset_at(data, element + WORD, element)?;
        results.push(bytes_at(data, bytes)?.to_vec());
    }
    Ok(results)
}

/// A function's single `string` answer, as UTF-8.
pub(crate) fn decode_string(data: &[u8]) -> Result<String> {
    let start = offset_at(data, 0, 0)?;
    let bytes = bytes_at(data, start)?;
    String::from_utf8(bytes.to_vec())
        .map_err(|_| PrivateUsdError::new(ErrorCode::ChainUnreadable, "a string is not UTF-8"))
}

/// The notes a Railgun `Shield` event's data records: each commitment's
/// `npk` with the ciphertext at the same position.
pub(crate) fn decode_railgun_shield(data: &[u8]) -> Result<Vec<ShieldNote>> {
    let commitments = offset_at(data, 2 * WORD, 0)?;
    let ciphertexts = offset_at(data, 3 * WORD, 0)?;
    let count = usize_at(data, commitments)?;
    if usize_at(data, ciphertexts)? != count {
        return unreadable("a Shield event's arrays differ in length");
    }
    let mut notes = Vec::with_capacity(count);
    for i in 0..count {
        let preimage = commitments + WORD + i * PREIMAGE_WORDS * WORD;
        let ciphertext = ciphertexts + WORD + i * CIPHERTEXT_WORDS * WORD;
        notes.push(ShieldNote {
            npk: word_at(data, preimage)?,
            ciphertext: ShieldCiphertext {
                encrypted_bundle: [
                    word_at(data, ciphertext)?,
                    word_at(data, ciphertext + WORD)?,
                    word_at(data, ciphertext + 2 * WORD)?,
                ],
                shield_key: word_at(data, ciphertext + 3 * WORD)?,
            },
        });
    }
    Ok(notes)
}

/// A big-endian `uint256` word holding `value`.
pub(crate) fn uint_word(value: u64) -> [u8; WORD] {
    let mut word = [0u8; WORD];
    word[WORD - 8..].copy_from_slice(&value.to_be_bytes());
    word
}

fn unreadable<T>(message: &str) -> Result<T> {
    fail(ErrorCode::ChainUnreadable, message)
}

fn word_at(data: &[u8], at: usize) -> Result<[u8; WORD]> {
    data.get(at..at.checked_add(WORD).unwrap_or(usize::MAX))
        .map(|word| word.try_into().expect("32 bytes"))
        .ok_or_else(|| {
            PrivateUsdError::new(ErrorCode::ChainUnreadable, "the answer ends too soon")
        })
}

/// A word that must be a small unsigned integer (a length or an offset).
fn usize_at(data: &[u8], at: usize) -> Result<usize> {
    let word = word_at(data, at)?;
    if word[..WORD - 4].iter().any(|byte| *byte != 0) {
        return unreadable("a length or offset is out of range");
    }
    Ok(u32::from_be_bytes(word[WORD - 4..].try_into().expect("4 bytes")) as usize)
}

/// The offset word at `at`, relative to `base`, as an absolute position
/// that is word-aligned and inside `data`.
fn offset_at(data: &[u8], at: usize, base: usize) -> Result<usize> {
    let offset = usize_at(data, at)?;
    let position = base
        .checked_add(offset)
        .filter(|position| position % WORD == 0 && *position < data.len())
        .ok_or_else(|| {
            PrivateUsdError::new(ErrorCode::ChainUnreadable, "an offset points outside the answer")
        })?;
    Ok(position)
}

/// `bytes` at `at`: its length word, then that many bytes.
fn bytes_at(data: &[u8], at: usize) -> Result<&[u8]> {
    let length = usize_at(data, at)?;
    let start = at + WORD;
    data.get(start..start.checked_add(length).unwrap_or(usize::MAX))
        .ok_or_else(|| {
            PrivateUsdError::new(ErrorCode::ChainUnreadable, "a byte string ends past the answer")
        })
}

fn is_bool(word: &[u8; WORD]) -> bool {
    word[..WORD - 1].iter().all(|byte| *byte == 0) && word[WORD - 1] <= 1
}
