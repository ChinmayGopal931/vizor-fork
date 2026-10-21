//! Swap index allocation.
//!
//! An index is spent once its share has gone to a maker: claiming reveals
//! `z`, so another swap that shares it becomes spendable by its maker. The
//! store commits each index as taken before it is used, and an index the chain
//! already shows in use, on the pinned contract or one retired before it, is
//! skipped (and stays spent), so a reinstall, or the same seed in another
//! wallet, never reuses one.

use super::evm_rpc::ChainReader;
use super::keys::SwapKeyContext;
use super::store::SwapStore;
use super::terms::{maker_key_used_key, swap_id};
use super::{fail, with_operations, ErrorCode, Result};

/// How many indices in a row may be in use before allocation gives up; the
/// next attempt goes on from there.
pub(crate) const MAX_SKIPPED: u32 = 16;

/// Takes the account's next swap index that no pinned contract shows in use.
/// `contracts` pairs each contract's reader with its forward maker.
pub(crate) async fn take_index<C: ChainReader>(
    store: &mut SwapStore,
    contracts: &[(&C, [u8; 20])],
    keys: &SwapKeyContext,
    account: &str,
) -> Result<u32> {
    for _ in 0..MAX_SKIPPED {
        let index = with_operations(|| store.take_index(account))?;
        if !used_on_chain(contracts, keys, index).await? {
            return Ok(index);
        }
    }
    fail(
        ErrorCode::IndicesInUse,
        format!("{MAX_SKIPPED} swap indices in a row are in use"),
    )
}

/// A forward swap's id binds its maker and our share; a reverse swap spends
/// our share as its own (`makerKeyUsed`).
async fn used_on_chain<C: ChainReader>(
    contracts: &[(&C, [u8; 20])],
    keys: &SwapKeyContext,
    index: u32,
) -> Result<bool> {
    let share = keys.user_share(index)?;
    let auth = keys.auth_address(index)?;
    let key = maker_key_used_key(&auth, &share);
    for (chain, maker) in contracts {
        let id = swap_id(maker, &share);
        if chain.swap(&id).await?.is_some()
            || chain.maker_key_used(&key).await?
            || chain.used_before(&id, &key).await?
        {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use serde_json::{json, Value};

    use super::*;
    use crate::wallet::private_usd::{
        abi::hex0x,
        deployment,
        evm_rpc::EvmRpc,
        transport::test_support::{rpc_error, rpc_result, ScriptedTransport},
        PrivateUsdNetwork,
    };
    use crate::wallet::routed_http::{RoutedError, RoutedRequest, RoutedResponse};

    const ACCOUNT: &str = "550e8400-e29b-41d4-a716-446655440000";

    /// A node on the pinned windows contract, on which the forward swaps of
    /// indices `used` exist, and those of `retired` on the lock contract
    /// before it.
    fn node(
        used: HashSet<String>,
        retired: HashSet<String>,
    ) -> ScriptedTransport<
        impl Fn(&RoutedRequest) -> std::result::Result<RoutedResponse, RoutedError>,
    > {
        let pins = deployment::deployment(PrivateUsdNetwork::Testnet);
        let windows = pins.swap_contract().unwrap();
        let lock_contract = hex0x(&pins.retired_contracts[0]);
        ScriptedTransport::new(move |request: &RoutedRequest| {
            let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
            let data = body["params"][0]["data"].as_str().unwrap().to_owned();
            let on_lock_contract = body["params"][0]["to"] == json!(lock_contract);
            let (selector, id) = data.split_at(10);
            let mut answer = vec![0u8; 32];
            match selector {
                // getSwap: an open swap for a used id, else stage 0; the
                // lock contract's records are six words.
                "0x3da0e66e" if on_lock_contract => {
                    answer = vec![0u8; 192];
                    if retired.contains(id) {
                        answer[63] = 1;
                    }
                }
                "0x3da0e66e" => {
                    answer = vec![0u8; 128];
                    if used.contains(id) {
                        answer[63] = 1;
                    }
                }
                "0x52b65c4b" => answer[24..].copy_from_slice(&windows.min_window.to_be_bytes()),
                "0x4d9fef3e" => answer[24..].copy_from_slice(&windows.late_window.to_be_bytes()),
                "0x485d3834" => return Ok(rpc_error(3, "execution reverted")),
                _ => {}
            }
            Ok(rpc_result(json!(hex0x(&answer))))
        })
    }

    #[tokio::test]
    async fn skips_used_indices_and_gives_up_after_sixteen() {
        let pins = deployment::deployment(PrivateUsdNetwork::Testnet);
        let keys = SwapKeyContext::for_tests(&[7; 64], PrivateUsdNetwork::Testnet, 0);
        let id_of = |index| hex::encode(swap_id(&pins.maker, &keys.user_share(index).unwrap()));
        let dir = tempfile::tempdir().unwrap();
        let mut store = SwapStore::open(dir.path()).unwrap();

        // Indices 0 to 2 are in use on chain: 3 is taken, 0 to 2 stay spent.
        let first_three = node((0..3).map(id_of).collect(), HashSet::new());
        let chain = EvmRpc::new(&first_three, pins, "https://rpc.invalid");
        let contracts = [(&chain, pins.maker)];
        assert_eq!(
            take_index(&mut store, &contracts, &keys, ACCOUNT)
                .await
                .unwrap(),
            3
        );

        // Sixteen in a row in use: refused, and all sixteen stay spent.
        let all = node((4..40).map(id_of).collect(), HashSet::new());
        let chain = EvmRpc::new(&all, pins, "https://rpc.invalid");
        let contracts = [(&chain, pins.maker)];
        let error = take_index(&mut store, &contracts, &keys, ACCOUNT)
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::IndicesInUse);
        assert_eq!(store.take_index(ACCOUNT).unwrap(), 4 + MAX_SKIPPED);

        // An index the retired lock contract shows in use is skipped too,
        // in a store that lost its counter.
        let dir = tempfile::tempdir().unwrap();
        let mut store = SwapStore::open(dir.path()).unwrap();
        let retired = node(HashSet::new(), (0..2).map(id_of).collect());
        let chain = EvmRpc::new(&retired, pins, "https://rpc.invalid");
        let contracts = [(&chain, pins.maker)];
        assert_eq!(
            take_index(&mut store, &contracts, &keys, ACCOUNT)
                .await
                .unwrap(),
            2
        );
    }
}
