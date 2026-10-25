//! The contracts' ABI as the engine reads and writes it, and `0x` hex: words,
//! call data, Multicall3's `aggregate3`, a `string` answer and Railgun's
//! `Shield` event.
//!
//! Every decoder is strict: an offset or a length that points outside the
//! data, or that is not where the ABI puts it, is `ChainUnreadable`, never a
//! guess.

use sha3::{Digest, Keccak256};
use zecswap_railgun::{ShieldCiphertext, ShieldNote};

use super::{fail, ErrorCode, PrivateUsdError, Result};

pub(crate) const WORD: usize = 32;

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

/// One contract call: its target and calldata.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Call {
    pub to: [u8; 20],
    pub data: Vec<u8>,
}

/// Keccak-256 (Ethereum's, not SHA3-256).
pub(crate) fn keccak(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Keccak256::new();
    for part in parts {
        hasher.update(part);
    }
    hasher.finalize().into()
}

/// The first four bytes of `keccak256(signature)`.
pub(crate) fn selector(signature: &str) -> [u8; 4] {
    let hash = keccak(&[signature.as_bytes()]);
    [hash[0], hash[1], hash[2], hash[3]]
}

/// `selector ‖ word…`: a call whose arguments are all static.
pub(crate) fn call_data(signature: &str, words: &[[u8; WORD]]) -> Vec<u8> {
    let mut data = selector(signature).to_vec();
    for word in words {
        data.extend_from_slice(word);
    }
    data
}

/// A big-endian `uint256` word holding `value`.
pub(crate) fn uint_word(value: u128) -> [u8; WORD] {
    let mut word = [0u8; WORD];
    word[WORD - 16..].copy_from_slice(&value.to_be_bytes());
    word
}

/// An address as an ABI word: left-padded to 32 bytes.
pub(crate) fn address_word(address: &[u8; 20]) -> [u8; WORD] {
    let mut word = [0u8; WORD];
    word[12..].copy_from_slice(address);
    word
}

/// `0x` and lowercase hex, as the wire and records write bytes.
pub(crate) fn hex0x(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

/// `aggregate3(calls)`'s calldata, selector included. None may fail
/// (`allowFailure` false), so one failing reverts the whole read.
pub(crate) fn encode_aggregate3(calls: &[Call]) -> Vec<u8> {
    encode_aggregate3_allowing(calls, false)
}

/// [`encode_aggregate3`] with every call allowed to fail (`allowFailure`
/// true): the read answers each call's success rather than reverting.
pub(crate) fn encode_try_aggregate3(calls: &[Call]) -> Vec<u8> {
    encode_aggregate3_allowing(calls, true)
}

fn encode_aggregate3_allowing(calls: &[Call], allow_failure: bool) -> Vec<u8> {
    let mut out = selector(AGGREGATE3).to_vec();
    // The one argument is a dynamic array: its offset, then the array.
    out.extend_from_slice(&uint_word(WORD as u128));
    out.extend_from_slice(&uint_word(calls.len() as u128));
    // Each element is a dynamic tuple: offsets from the start of the
    // element area, then the tuples.
    let tuples: Vec<Vec<u8>> = calls
        .iter()
        .map(|call| encode_call3(call, allow_failure))
        .collect();
    let mut offset = calls.len() * WORD;
    for tuple in &tuples {
        out.extend_from_slice(&uint_word(offset as u128));
        offset += tuple.len();
    }
    for tuple in tuples {
        out.extend_from_slice(&tuple);
    }
    out
}

/// `(address target, bool allowFailure, bytes callData)`.
fn encode_call3(call: &Call, allow_failure: bool) -> Vec<u8> {
    let mut tuple = Vec::with_capacity(5 * WORD + call.data.len());
    tuple.extend_from_slice(&address_word(&call.to));
    tuple.extend_from_slice(&uint_word(u128::from(allow_failure)));
    // `callData` follows the tuple's three head words.
    tuple.extend_from_slice(&uint_word(3 * WORD as u128));
    tuple.extend_from_slice(&uint_word(call.data.len() as u128));
    tuple.extend_from_slice(&call.data);
    let padding = (WORD - call.data.len() % WORD) % WORD;
    tuple.extend(std::iter::repeat_n(0u8, padding));
    tuple
}

/// `aggregate3`'s answer, `(bool success, bytes returnData)[]`: each call's
/// return data, in order. The count must be `expected`, and every call must
/// have succeeded.
pub(crate) fn decode_aggregate3(data: &[u8], expected: usize) -> Result<Vec<Vec<u8>>> {
    decode_try_aggregate3(data, expected)?
        .into_iter()
        .map(|answer| {
            answer.ok_or_else(|| {
                PrivateUsdError::new(ErrorCode::ChainUnreadable, "a Multicall3 call failed")
            })
        })
        .collect()
}

/// `aggregate3`'s answer: each call's return data in order, `None` for one
/// that failed. The count must be `expected`.
pub(crate) fn decode_try_aggregate3(data: &[u8], expected: usize) -> Result<Vec<Option<Vec<u8>>>> {
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
        let success = bool_word(&word_at(data, element)?)?;
        let bytes = offset_at(data, element + WORD, element)?;
        results.push(
            success
                .then(|| bytes_at(data, bytes).map(<[u8]>::to_vec))
                .transpose()?,
        );
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

/// At least `count` words of `data`; a shorter answer does not read.
pub(crate) fn words(data: &[u8], count: usize) -> Result<Vec<[u8; WORD]>> {
    if data.len() < count * WORD {
        return fail(
            ErrorCode::ChainUnreadable,
            format!("the node answered {} bytes", data.len()),
        );
    }
    Ok(data
        .as_chunks::<WORD>()
        .0
        .iter()
        .take(count)
        .copied()
        .collect())
}

/// Exactly one word: a static answer of another length is not this ABI's.
pub(crate) fn exact_word(data: &[u8]) -> Result<[u8; WORD]> {
    if data.len() != WORD {
        return fail(
            ErrorCode::ChainUnreadable,
            format!("expected one word, the node answered {} bytes", data.len()),
        );
    }
    Ok(data.try_into().expect("32 bytes"))
}

/// An ABI `bool`: zero or one, nothing else.
pub(crate) fn bool_word(word: &[u8; WORD]) -> Result<bool> {
    if word[..WORD - 1].iter().any(|byte| *byte != 0) || word[WORD - 1] > 1 {
        return unreadable("a bool that is neither 0 nor 1");
    }
    Ok(word[WORD - 1] == 1)
}

/// An ABI `address`: twelve zero bytes, then the address.
pub(crate) fn address_of_word(word: &[u8; WORD]) -> Result<[u8; 20]> {
    if word[..12].iter().any(|byte| *byte != 0) {
        return unreadable("an address word with high bytes");
    }
    Ok(word[12..].try_into().expect("20 bytes"))
}

/// A word that must fit `u64`; anything else is not this contract's.
pub(crate) fn u64_word(word: &[u8; WORD]) -> Result<u64> {
    if word[..WORD - 8].iter().any(|byte| *byte != 0) {
        return fail(ErrorCode::WrongDeployment, "a time or count beyond u64");
    }
    Ok(u64::from_be_bytes(
        word[WORD - 8..].try_into().expect("8 bytes"),
    ))
}

/// A word that must fit `u128`.
pub(crate) fn u128_word(word: &[u8; WORD]) -> Result<u128> {
    if word[..WORD - 16].iter().any(|byte| *byte != 0) {
        return unreadable("an amount beyond u128");
    }
    Ok(u128::from_be_bytes(
        word[WORD - 16..].try_into().expect("16 bytes"),
    ))
}

fn unreadable<T>(message: &str) -> Result<T> {
    fail(ErrorCode::ChainUnreadable, message)
}

fn word_at(data: &[u8], at: usize) -> Result<[u8; WORD]> {
    data.get(at..at.saturating_add(WORD))
        .map(|word| word.try_into().expect("32 bytes"))
        .ok_or_else(|| PrivateUsdError::new(ErrorCode::ChainUnreadable, "the answer ends too soon"))
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
            PrivateUsdError::new(
                ErrorCode::ChainUnreadable,
                "an offset points outside the answer",
            )
        })?;
    Ok(position)
}

/// `bytes` at `at`: its length word, then that many bytes.
fn bytes_at(data: &[u8], at: usize) -> Result<&[u8]> {
    let length = usize_at(data, at)?;
    let start = at + WORD;
    data.get(start..start.saturating_add(length))
        .ok_or_else(|| {
            PrivateUsdError::new(
                ErrorCode::ChainUnreadable,
                "a byte string ends past the answer",
            )
        })
}

/// Multicall3 from the node's side, for test nodes that answer the reads a
/// batch carries.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;

    /// The calls an `aggregate3` calldata carries, each with its
    /// `allowFailure`.
    pub(crate) fn decode_aggregate3_calls(calldata: &[u8]) -> Vec<(Call, bool)> {
        assert_eq!(calldata[..4], selector(AGGREGATE3), "not aggregate3");
        let data = &calldata[4..];
        let array = offset_at(data, 0, 0).unwrap();
        let count = usize_at(data, array).unwrap();
        let elements = array + WORD;
        (0..count)
            .map(|i| {
                let element = offset_at(data, elements + i * WORD, elements).unwrap();
                let to = address_of_word(&word_at(data, element).unwrap()).unwrap();
                let allow_failure = bool_word(&word_at(data, element + WORD).unwrap()).unwrap();
                let bytes = offset_at(data, element + 2 * WORD, element).unwrap();
                let data = bytes_at(data, bytes).unwrap().to_vec();
                (Call { to, data }, allow_failure)
            })
            .collect()
    }

    /// `aggregate3`'s answer to calls answering `answers`, in order: `None`
    /// for a call that failed.
    pub(crate) fn encode_aggregate3_answers(answers: &[Option<Vec<u8>>]) -> Vec<u8> {
        let mut out = uint_word(WORD as u128).to_vec();
        out.extend_from_slice(&uint_word(answers.len() as u128));
        let tuples: Vec<Vec<u8>> = answers
            .iter()
            .map(|answer| {
                let data = answer.as_deref().unwrap_or_default();
                let mut tuple = uint_word(u128::from(answer.is_some())).to_vec();
                tuple.extend_from_slice(&uint_word(2 * WORD as u128));
                tuple.extend_from_slice(&uint_word(data.len() as u128));
                tuple.extend_from_slice(data);
                let padding = (WORD - data.len() % WORD) % WORD;
                tuple.extend(std::iter::repeat_n(0u8, padding));
                tuple
            })
            .collect();
        let mut offset = answers.len() * WORD;
        for tuple in &tuples {
            out.extend_from_slice(&uint_word(offset as u128));
            offset += tuple.len();
        }
        for tuple in tuples {
            out.extend_from_slice(&tuple);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{decode_aggregate3_calls, encode_aggregate3_answers};
    use super::*;

    fn calls() -> Vec<Call> {
        vec![
            Call {
                to: [1; 20],
                data: call_data("MIN_WINDOW()", &[]),
            },
            Call {
                to: [2; 20],
                data: call_data("getSwap(bytes32)", &[[7; WORD]]),
            },
        ]
    }

    /// A batch carries its calls as given, none allowed to fail, or every
    /// one in a batch that may fail.
    #[test]
    fn a_batch_carries_its_calls_and_whether_they_may_fail() {
        for (calldata, allowed) in [
            (encode_aggregate3(&calls()), false),
            (encode_try_aggregate3(&calls()), true),
        ] {
            let carried = decode_aggregate3_calls(&calldata);
            assert_eq!(carried.len(), 2);
            for ((call, allow_failure), sent) in carried.iter().zip(calls()) {
                assert_eq!((call.to, &call.data), (sent.to, &sent.data));
                assert_eq!(*allow_failure, allowed);
            }
        }
    }

    /// The answers read back in order, a failed call as `None`; a batch that
    /// must not fail refuses one, and a count that differs is refused.
    #[test]
    fn a_batchs_answers_read_back_in_order() {
        let answers = vec![Some(vec![5; WORD]), None, Some(vec![9; 3])];
        let encoded = encode_aggregate3_answers(&answers);
        assert_eq!(decode_try_aggregate3(&encoded, 3).unwrap(), answers);
        assert_eq!(
            decode_aggregate3(&encoded, 3).unwrap_err().code,
            ErrorCode::ChainUnreadable
        );
        assert_eq!(
            decode_try_aggregate3(&encoded, 2).unwrap_err().code,
            ErrorCode::ChainUnreadable
        );
        let all = encode_aggregate3_answers(&[Some(vec![1; WORD]), Some(Vec::new())]);
        assert_eq!(
            decode_aggregate3(&all, 2).unwrap(),
            vec![vec![1; WORD], Vec::new()]
        );
    }
}
