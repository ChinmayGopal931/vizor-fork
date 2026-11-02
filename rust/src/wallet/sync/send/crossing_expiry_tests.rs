//! An ordinary payment the fee model builds as a canonical ZIP 318 crossing
//! carries the rolling expiry its period's migration transfers share. Before
//! NU7 the backend applies it. From NU7 the wallet pays the reduced fee, which
//! the backend does not take for a crossing's, so the wallet requests it.

use std::convert::Infallible;
use std::num::NonZeroU32;

use zcash_client_backend::{
    data_api::{
        anchor_retention::AnchorRetentionInterval,
        testing::{orchard::OrchardPoolTester, pool::ShieldedPoolTester, AddressType, TestBuilder},
        wallet::{create_proposed_transactions, ConfirmationsPolicy, SpendingKeys},
        Account as _, WalletRead as _,
    },
    proposal::Proposal,
    wallet::OvkPolicy,
    zip321::{Payment, TransactionRequest},
};
use zcash_client_sqlite::{
    testing::{
        db::{TestDb, TestDbFactory},
        BlockCache,
    },
    ReceivedNoteId,
};
use zcash_primitives::block::BlockHash;
use zcash_protocol::{
    consensus::BlockHeight,
    local_consensus::LocalNetwork,
    value::Zatoshis,
    zip318::{self, AnchorGrid, BlockSpacing, MAX_RESIDUAL_VALUE},
};

use super::{
    network_upgrade, proposal_expiry, zip317_helper, ConservativeZip317FeeRule, LiveSendExpiry,
    NoOpOutputProver, NoOpSpendProver,
};

type State = zcash_client_backend::data_api::testing::TestState<BlockCache, TestDb, LocalNetwork>;
type WalletProposal = Proposal<ConservativeZip317FeeRule, ReceivedNoteId>;

const IRONWOOD_ACTIVATION: u32 = 100_000;

fn network(nu7: Option<u32>) -> LocalNetwork {
    let activation = BlockHeight::from_u32(IRONWOOD_ACTIVATION);
    LocalNetwork {
        nu6: Some(activation),
        nu6_1: Some(activation),
        nu6_2: Some(activation),
        nu6_3: Some(activation),
        nu7: nu7.map(BlockHeight::from_u32),
        ..TestBuilder::<(), ()>::DEFAULT_NETWORK
    }
}

/// A wallet whose one Orchard note pays a canonical denomination into
/// Ironwood under the wallet's fee rule, proposed with the anchor on a grid
/// boundary. Returns the wallet, the proposal and the chain tip.
fn crossing(nu7: Option<u32>) -> (State, WalletProposal, u32) {
    // A short grid, so a boundary is a few blocks away.
    let interval = AnchorRetentionInterval::custom(NonZeroU32::new(12).unwrap());
    let mut st = TestBuilder::new()
        .with_network(network(nu7))
        .with_data_store_factory(TestDbFactory::default())
        .with_block_cache(BlockCache::new())
        .with_anchor_retention_interval(interval)
        .with_account_from_sapling_activation(BlockHash([0; 32]))
        .build();
    let account = st.test_account().cloned().unwrap();
    let fvk = OrchardPoolTester::test_account_fvk(&st);
    let (received, _, _) = st.generate_next_block(
        &fvk,
        AddressType::DefaultExternal,
        Zatoshis::const_from_u64(10_000_000),
    );
    st.scan_cached_blocks(received, 1);

    // `ConfirmationsPolicy::MIN` anchors one block below the tip, so the tip
    // is mined one past a boundary. Fillers pay a key outside the wallet.
    let boundary = AnchorGrid::new(interval, BlockSpacing::for_network(st.network()))
        .boundary_at_or_above(received + 2);
    let not_ours = OrchardPoolTester::sk_to_fvk(&OrchardPoolTester::sk(&[0xf5; 32]));
    let from = received + 1;
    let count = u32::from(boundary) + 1 - u32::from(from) + 1;
    for _ in 0..count {
        st.generate_next_block(
            &not_ours,
            AddressType::DefaultExternal,
            Zatoshis::const_from_u64(10_000),
        );
    }
    st.scan_cached_blocks(from, count as usize);
    let tip = u32::from(boundary) + 1;

    let network = *st.network();
    let fee_rule = ConservativeZip317FeeRule::for_target(&network, BlockHeight::from_u32(tip + 1));
    let (change_strategy, input_selector) = zip317_helper(fee_rule, None, true);
    let recipient = OrchardPoolTester::fvk_default_address(&fvk).to_zcash_address(&network);
    let request =
        TransactionRequest::new(vec![Payment::without_memo(recipient, MAX_RESIDUAL_VALUE)])
            .unwrap();
    let proposal = st
        .propose_transfer(
            account.id(),
            &input_selector,
            &change_strategy,
            request,
            ConfirmationsPolicy::MIN,
        )
        .unwrap();
    assert_eq!(proposal.steps().first().anchor_height(), Some(boundary));
    (st, proposal, tip)
}

fn ordinary_expiry(tip: u32) -> LiveSendExpiry {
    LiveSendExpiry {
        tip,
        expiry_height: BlockHeight::from_u32(tip + 41),
    }
}

#[test]
fn a_canonical_crossing_is_built_with_the_rolling_expiry_before_and_from_nu7() {
    for nu7 in [None, Some(IRONWOOD_ACTIVATION)] {
        let (mut st, proposal, tip) = crossing(nu7);
        let network = *st.network();
        let target = BlockHeight::from(proposal.min_target_height());
        let rolling = zip318::expiry_height(&BlockSpacing::for_network(&network), target);

        let expiry =
            proposal_expiry(&network, st.wallet(), &proposal, ordinary_expiry(tip)).unwrap();
        assert_eq!(expiry.height, rolling, "nu7 {nu7:?}");
        assert_eq!(expiry.requested, nu7.map(|_| rolling), "nu7 {nu7:?}");

        let usk = st.test_account().unwrap().usk().clone();
        let txids = create_proposed_transactions::<_, _, Infallible, _, Infallible, _>(
            st.wallet_mut(),
            &network,
            &NoOpSpendProver,
            &NoOpOutputProver,
            &SpendingKeys::from_unified_spending_key(usk),
            OvkPolicy::Sender,
            &proposal,
            expiry.requested,
        )
        .unwrap();
        let tx = st.wallet().get_transaction(txids[0]).unwrap().unwrap();
        assert_eq!(tx.expiry_height(), rolling, "nu7 {nu7:?}");
        assert_eq!(tx.ironwood_bundle().unwrap().actions().len(), 1);
    }
}

#[test]
fn a_canonical_crossing_is_held_before_an_upgrade_its_expiry_outlasts() {
    let (st, proposal, tip) = crossing(None);
    // The same chain with NU7 a few blocks past the tip: the rolling expiry
    // cannot be capped at the branch end, so the crossing waits out the hold.
    let upcoming = network(Some(tip + 5));
    assert_eq!(
        proposal_expiry(&upcoming, st.wallet(), &proposal, ordinary_expiry(tip)),
        Err(network_upgrade::SEND_HOLD_MESSAGE.to_string())
    );
}

#[test]
fn an_ordinary_payment_keeps_the_live_expiry() {
    let (mut st, _, tip) = crossing(Some(IRONWOOD_ACTIVATION));
    let network = *st.network();
    let account = st.test_account().unwrap().id();
    let recipient =
        OrchardPoolTester::fvk_default_address(&OrchardPoolTester::test_account_fvk(&st))
            .to_zcash_address(&network);
    let fee_rule = ConservativeZip317FeeRule::for_target(&network, BlockHeight::from_u32(tip + 1));
    let (change_strategy, input_selector) = zip317_helper(fee_rule, None, true);
    // One zatoshi off the denomination: padded, so nothing to share an expiry with.
    let request = TransactionRequest::new(vec![Payment::without_memo(
        recipient,
        (MAX_RESIDUAL_VALUE + Zatoshis::const_from_u64(1)).unwrap(),
    )])
    .unwrap();
    let proposal = st
        .propose_transfer(
            account,
            &input_selector,
            &change_strategy,
            request,
            ConfirmationsPolicy::MIN,
        )
        .unwrap();
    let live = ordinary_expiry(tip);
    let expiry = proposal_expiry(&network, st.wallet(), &proposal, live).unwrap();
    assert_eq!(expiry.height, live.expiry_height);
    assert_eq!(expiry.requested, Some(live.expiry_height));
}
