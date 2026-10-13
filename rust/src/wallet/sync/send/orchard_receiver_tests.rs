//! A payment to an Orchard-only unified address after NU6.3 is carried by the
//! Ironwood bundle, and the wallet records the recipient address with it.
//!
//! Private USD's joint deposit depends on both: the joint UA has one Orchard
//! receiver, the swap's sweep is an Ironwood spend (only Ironwood allows the
//! cross-address transfer it needs), and the deposit lookup matches
//! `sent_notes.to_address` against the joint UA
//! (`docs/private-usd-android-plan.md` §5.1, §8.1.2, spike M0.2).

use std::convert::Infallible;

use zcash_client_backend::{
    data_api::{
        testing::{orchard::OrchardPoolTester, pool::ShieldedPoolTester, AddressType, TestBuilder},
        wallet::{input_selection::GreedyInputSelector, ConfirmationsPolicy},
        Account as _, WalletRead as _,
    },
    fees::{standard, DustOutputPolicy, StandardFeeRule},
    wallet::OvkPolicy,
    zip321::{Payment, TransactionRequest},
};
use zcash_client_sqlite::testing::{db::TestDbFactory, BlockCache};
use zcash_primitives::block::BlockHash;
use zcash_protocol::{
    consensus::BlockHeight, local_consensus::LocalNetwork, value::Zatoshis, ShieldedPool,
};

/// `sent_notes.output_pool` for Ironwood (`zcash_client_sqlite` `pool_code`).
const IRONWOOD_POOL_CODE: i64 = 4;
const DEPOSIT: u64 = 50_000;

fn ironwood_active_network() -> LocalNetwork {
    let activation = BlockHeight::from_u32(100_000);
    LocalNetwork {
        nu6: Some(activation),
        nu6_1: Some(activation),
        nu6_2: Some(activation),
        nu6_3: Some(activation),
        ..TestBuilder::<(), ()>::DEFAULT_NETWORK
    }
}

#[test]
fn payment_to_orchard_only_ua_lands_in_ironwood_with_its_address_recorded() {
    let mut st = TestBuilder::new()
        .with_network(ironwood_active_network())
        .with_data_store_factory(TestDbFactory::default())
        .with_block_cache(BlockCache::new())
        .with_account_from_sapling_activation(BlockHash([0; 32]))
        .build();
    let account = st.test_account().cloned().unwrap();

    let (height, _, _) = st.generate_next_block(
        &OrchardPoolTester::test_account_fvk(&st),
        AddressType::DefaultExternal,
        Zatoshis::const_from_u64(200_000),
    );
    st.scan_cached_blocks(height, 1);
    for _ in 0..5 {
        let (height, _) = st.generate_empty_block();
        st.scan_cached_blocks(height, 1);
    }

    // The joint deposit address's shape: a unified address with a lone Orchard
    // receiver, which nobody in this wallet owns.
    let recipient = OrchardPoolTester::fvk_default_address(&OrchardPoolTester::sk_to_fvk(
        &OrchardPoolTester::sk(&[0xf5; 32]),
    ))
    .to_zcash_address(st.network());
    let recipient_ua = recipient.encode();
    let request = TransactionRequest::new(vec![Payment::without_memo(
        recipient,
        Zatoshis::const_from_u64(DEPOSIT),
    )])
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
    // The deposit keeps the sender OVK (plan §8.1.3).
    let created = st
        .create_proposed_transactions::<Infallible, _, Infallible, _>(
            account.usk(),
            OvkPolicy::Sender,
            &proposal,
        )
        .unwrap();
    assert_eq!(created.len(), 1);
    let txid = created[0];

    let tx = st
        .wallet()
        .get_transaction(txid)
        .unwrap()
        .expect("the sent transaction is stored");
    let ironwood_actions = tx
        .ironwood_bundle()
        .expect("a payment to an Orchard receiver is carried by the Ironwood bundle")
        .actions()
        .len();

    let (output_pool, output_index, value): (i64, i64, i64) = st
        .wallet()
        .conn()
        .query_row(
            "SELECT sn.output_pool, sn.output_index, sn.value
             FROM sent_notes sn JOIN transactions t ON t.id_tx = sn.transaction_id
             WHERE t.txid = ?1 AND sn.to_address = ?2",
            rusqlite::params![&txid.as_ref()[..], recipient_ua],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("the deposit output is recorded under the recipient's unified address");
    assert_eq!(output_pool, IRONWOOD_POOL_CODE);
    assert!(usize::try_from(output_index).unwrap() < ironwood_actions);
    assert_eq!(value, i64::try_from(DEPOSIT).unwrap());
}
