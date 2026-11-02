//! The deltas a balance history is folded from: one per mined transaction,
//! where Activity can list one transaction as two rows that each carry its
//! whole delta.

use std::convert::Infallible;

use transparent::keys::IncomingViewingKey as _;

use zcash_client_backend::{
    data_api::{
        testing::{orchard::OrchardPoolTester, pool::ShieldedPoolTester, AddressType, TestBuilder},
        wallet::{input_selection::GreedyInputSelector, ConfirmationsPolicy},
        Account as _,
    },
    fees::{standard, DustOutputPolicy, StandardFeeRule},
    wallet::OvkPolicy,
    zip321::{Payment, TransactionRequest},
};
use zcash_client_sqlite::testing::{db::TestDbFactory, BlockCache};
use zcash_keys::address::Address;
use zcash_primitives::block::BlockHash;
use zcash_protocol::{value::Zatoshis, ShieldedPool};

use super::private_shielding_tests::{regtest, NETWORK};
use super::{get_balance_deltas, get_transaction_history};

const RECEIVED: u64 = 200_000;
const PAID: u64 = 50_000;

#[test]
fn a_transaction_activity_lists_twice_is_one_delta() {
    let mut st = TestBuilder::new()
        .with_network(regtest())
        .with_data_store_factory(TestDbFactory::default())
        .with_block_cache(BlockCache::new())
        .with_account_from_sapling_activation(BlockHash([0; 32]))
        .build();
    let account = st.test_account().cloned().unwrap();
    let fvk = OrchardPoolTester::test_account_fvk(&st);
    let (height, _, _) = st.generate_next_block(
        &fvk,
        AddressType::DefaultExternal,
        Zatoshis::const_from_u64(RECEIVED),
    );
    st.scan_cached_blocks(height, 1);
    for _ in 0..5 {
        let (height, _) = st.generate_empty_block();
        st.scan_cached_blocks(height, 1);
    }

    // One payment out, and one to the account's own transparent address,
    // which Activity shows as a receipt of its own.
    let (own_transparent, _) = account
        .usk()
        .to_unified_full_viewing_key()
        .transparent()
        .unwrap()
        .derive_external_ivk()
        .unwrap()
        .default_address();
    let own = Address::Transparent(own_transparent).to_zcash_address(st.network());
    let other = OrchardPoolTester::fvk_default_address(&OrchardPoolTester::sk_to_fvk(
        &OrchardPoolTester::sk(&[0xf5; 32]),
    ))
    .to_zcash_address(st.network());
    let request = TransactionRequest::new(vec![
        Payment::without_memo(other, Zatoshis::const_from_u64(PAID)),
        Payment::without_memo(own, Zatoshis::const_from_u64(100_000)),
    ])
    .unwrap();
    let change_strategy = standard::SingleOutputChangeStrategy::new(
        StandardFeeRule::Zip317,
        None,
        ShieldedPool::Orchard,
        DustOutputPolicy::default(),
    );
    let proposal = st
        .propose_transfer(
            account.id(),
            &GreedyInputSelector::new(),
            &change_strategy,
            request,
            ConfirmationsPolicy::MIN,
        )
        .unwrap();
    let fee = u64::from(proposal.steps().first().balance().fee_required());
    let txids = st
        .create_proposed_transactions::<Infallible, _, Infallible, _>(
            account.usk(),
            OvkPolicy::Sender,
            &proposal,
        )
        .unwrap();
    let (mined, _) = st.generate_next_block_including(txids[0]);
    st.scan_cached_blocks(mined, 1);

    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("wallet.db").to_str().unwrap().to_owned();
    st.wallet()
        .conn()
        .execute("VACUUM INTO ?1", [&path])
        .unwrap();
    let account_uuid = account.id().expose_uuid().to_string();

    let txid_hex = hex::encode(txids[0].as_ref());
    let rows = get_transaction_history(&path, NETWORK, None, &account_uuid).unwrap();
    let listed = rows
        .iter()
        .filter(|row| row.txid_hex == txid_hex)
        .map(|row| (row.tx_kind.as_str(), row.account_balance_delta))
        .collect::<Vec<_>>();
    assert_eq!(listed.len(), 2, "{listed:?}");
    assert!(listed.iter().all(|(_, delta)| *delta == listed[0].1));

    let deltas = get_balance_deltas(&path, NETWORK, &account_uuid).unwrap();
    assert_eq!(deltas.len(), 2);
    assert_eq!(
        deltas.iter().map(|delta| delta.zatoshi).sum::<i64>(),
        i64::try_from(RECEIVED - PAID - fee).unwrap()
    );
    assert!(deltas
        .iter()
        .any(|delta| delta.mined_height == u32::from(mined)));
}
