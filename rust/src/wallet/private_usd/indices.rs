//! Swap index allocation (plan §3.3, zapp `of/SwapIndices.kt`).
//!
//! An index is spent once its share has gone to a maker: claiming reveals
//! `z`, so another swap that shares it becomes spendable by its maker. The
//! store commits each index as taken before it is used, and an index the chain
//! already shows in use is skipped (and stays spent), so a reinstall, or the
//! same seed in zapp and vizor, never reuses one.

use super::evm_rpc::ChainReader;
use super::keys::SwapKeyContext;
use super::store::SwapStore;
use super::terms::{maker_key_used_key, swap_id};
use super::{fail, ErrorCode, Result, OPERATIONS};

/// How many indices in a row may be in use before allocation gives up; the
/// next attempt goes on from there.
pub(crate) const MAX_SKIPPED: u32 = 16;

/// Takes the account's next swap index that no pinned contract shows in use.
/// `contracts` pairs each contract's reader with its forward maker.
pub(crate) async fn take_index<C: ChainReader>(
    store: &mut SwapStore,
    contracts: &[(C, [u8; 20])],
    keys: &SwapKeyContext,
    account: &str,
) -> Result<u32> {
    for _ in 0..MAX_SKIPPED {
        let index = {
            let _guard = OPERATIONS.lock().unwrap_or_else(|error| error.into_inner());
            store.take_index(account)?
        };
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
    contracts: &[(C, [u8; 20])],
    keys: &SwapKeyContext,
    index: u32,
) -> Result<bool> {
    let share = keys.user_share(index)?;
    let auth = keys.auth_address(index)?;
    for (chain, maker) in contracts {
        if chain.swap(&swap_id(maker, &share)).await?.is_some()
            || chain
                .maker_key_used(&maker_key_used_key(&auth, &share))
                .await?
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
        deployment,
        evm_rpc::EvmRpc,
        transport::test_support::{rpc_result, ScriptedTransport},
        PrivateUsdNetwork,
    };
    use crate::wallet::routed_http::{RoutedError, RoutedRequest, RoutedResponse};

    const ACCOUNT: &str = "550e8400-e29b-41d4-a716-446655440000";

    /// A node on which the forward swaps of indices `used` exist.
    fn node(
        used: HashSet<String>,
    ) -> ScriptedTransport<
        impl Fn(&RoutedRequest) -> std::result::Result<RoutedResponse, RoutedError>,
    > {
        ScriptedTransport::new(move |request: &RoutedRequest| {
            let body: Value = serde_json::from_slice(request.body.as_ref().unwrap()).unwrap();
            let data = body["params"][0]["data"].as_str().unwrap().to_owned();
            let (selector, id) = data.split_at(10);
            let mut answer = vec![0u8; 32];
            if selector == "0x3da0e66e" {
                // getSwap: an open swap for a used id, else stage 0.
                answer = vec![0u8; 192];
                if used.contains(id) {
                    answer[63] = 1;
                }
            }
            Ok(rpc_result(json!(format!("0x{}", hex::encode(answer)))))
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
        let first_three = node((0..3).map(id_of).collect());
        let chain = EvmRpc::new(&first_three, "https://rpc.invalid", pins);
        let contracts = [(chain, pins.maker)];
        assert_eq!(
            take_index(&mut store, &contracts, &keys, ACCOUNT)
                .await
                .unwrap(),
            3
        );

        // Sixteen in a row in use: refused, and all sixteen stay spent.
        let all = node((4..40).map(id_of).collect());
        let chain = EvmRpc::new(&all, "https://rpc.invalid", pins);
        let contracts = [(chain, pins.maker)];
        let error = take_index(&mut store, &contracts, &keys, ACCOUNT)
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::IndicesInUse);
        assert_eq!(store.take_index(ACCOUNT).unwrap(), 4 + MAX_SKIPPED);
    }
}
