//! The joint-account and deposit operations, against real wallet DBs that
//! scan synthetic compact blocks after NU6.3. A local fake lightwalletd
//! answers the chain tip; nothing is broadcast.

use std::num::NonZeroU32;

use incrementalmerkletree::frontier::Frontier;
use orchard::{
    keys::{OutgoingViewingKey, Scope},
    note::{ExtractedNoteCommitment, NoteVersion, RandomSeed, Rho},
    note_encryption::{IronwoodDomain, OrchardDomain},
    tree::MerkleHashOrchard,
    value::NoteValue,
};
use pczt::roles::verifier::{OrchardError, Verifier};
use secrecy::SecretVec;
use zcash_address::unified::{self, Encoding};
use zcash_client_backend::data_api::{
    anchor_retention::AnchorRetentionInterval,
    chain::{error::Error as ChainError, scan_cached_blocks, BlockSource, ChainState},
    TransactionStatus, WalletWrite,
};
use zcash_client_backend::proto::compact_formats::{
    ChainMetadata, CompactBlock, CompactOrchardAction, CompactTx,
};
use zcash_keys::{address::Address, keys::UnifiedSpendingKey};
use zcash_note_encryption::{
    try_output_recovery_with_ovk, Domain, NoteEncryption, ShieldedOutput, ENC_CIPHERTEXT_SIZE,
};
use zcash_primitives::{block::BlockHash, transaction::TxId};
use zcash_protocol::consensus::{BlockHeight, NetworkUpgrade, Parameters};
use zecswap_core::{derive_maker_share, JointAccount};

use super::super::{
    joint::{self, SwapTxStatus},
    keys::SwapKeyContext,
    PrivateUsdNetwork,
};
use crate::network_privacy::test_route_policy::lock_route_policy;
use crate::wallet::sync_engine::test_lwd::CapturingLwd;
use crate::wallet::{db, keys, network::WalletNetwork, sync};

const NETWORK: WalletNetwork = WalletNetwork::Main;
const SEED: [u8; 32] = [7; 32];
const FUNDS: u64 = 1_000_000;

type IronwoodFrontier = Frontier<MerkleHashOrchard, 32>;

/// A chain from just after NU6.3 whose blocks carry one Ironwood note or
/// nothing.
struct Chain {
    start: u32,
    blocks: Vec<CompactBlock>,
    /// The Ironwood tree's frontier after each block.
    frontiers: Vec<IronwoodFrontier>,
}

struct Blocks(Vec<CompactBlock>);

impl BlockSource for Blocks {
    type Error = std::convert::Infallible;

    fn with_blocks<F, E>(
        &self,
        from: Option<BlockHeight>,
        limit: Option<usize>,
        mut f: F,
    ) -> Result<(), ChainError<E, Self::Error>>
    where
        F: FnMut(CompactBlock) -> Result<(), ChainError<E, Self::Error>>,
    {
        for block in self
            .0
            .iter()
            .filter(|block| from.is_none_or(|from| block.height >= u64::from(u32::from(from))))
            .take(limit.unwrap_or(usize::MAX))
        {
            f(block.clone())?;
        }
        Ok(())
    }
}

impl Chain {
    fn new() -> Self {
        let activation = NETWORK.activation_height(NetworkUpgrade::Nu6_3).unwrap();
        Self {
            start: u32::from(activation) + 100,
            blocks: vec![],
            frontiers: vec![],
        }
    }

    fn tip(&self) -> u32 {
        self.start + self.blocks.len() as u32 - 1
    }

    fn hash(height: u32) -> [u8; 32] {
        let mut hash = [0x5a; 32];
        hash[..4].copy_from_slice(&height.to_le_bytes());
        hash
    }

    fn frontier_after(&self, height: u32) -> IronwoodFrontier {
        if height < self.start {
            Frontier::empty()
        } else {
            self.frontiers[(height - self.start) as usize].clone()
        }
    }

    fn push(&mut self, vtx: Vec<CompactTx>, frontier: IronwoodFrontier) {
        let height = self.start + self.blocks.len() as u32;
        self.blocks.push(CompactBlock {
            height: u64::from(height),
            hash: Self::hash(height).to_vec(),
            prev_hash: Self::hash(height - 1).to_vec(),
            time: 1_800_000_000 + height,
            chain_metadata: Some(ChainMetadata {
                ironwood_commitment_tree_size: frontier.tree_size() as u32,
                ..Default::default()
            }),
            vtx,
            ..Default::default()
        });
        self.frontiers.push(frontier);
    }

    fn empty(&mut self) {
        let frontier = self.frontier_after(self.start + self.blocks.len() as u32 - 1);
        self.push(vec![], frontier);
    }

    /// A block paying `value` to `recipient` in an Ironwood note.
    fn pay(&mut self, recipient: orchard::Address, value: u64) {
        let height = self.start + self.blocks.len() as u32;
        let mut rho_bytes = [0; 32];
        rho_bytes[..4].copy_from_slice(&height.to_le_bytes());
        let rho = Rho::from_bytes(&rho_bytes).unwrap();
        let rseed = RandomSeed::from_bytes([3; 32], &rho).unwrap();
        let note = orchard::Note::from_parts(
            recipient,
            NoteValue::from_raw(value),
            rho,
            rseed,
            NoteVersion::V3,
        )
        .unwrap();
        let encryption = NoteEncryption::<IronwoodDomain>::new(None, note, [0; 512]);
        let cmx = ExtractedNoteCommitment::from(note.commitment());
        let mut frontier = self.frontier_after(height - 1);
        frontier.append(MerkleHashOrchard::from_cmx(&cmx));
        let tx = CompactTx {
            txid: Self::hash(height).iter().map(|byte| !byte).collect(),
            ironwood_actions: vec![CompactOrchardAction {
                nullifier: rho_bytes.to_vec(),
                cmx: cmx.to_bytes().to_vec(),
                ephemeral_key: IronwoodDomain::epk_bytes(encryption.epk()).0.to_vec(),
                ciphertext: encryption.encrypt_note_plaintext()[..52].to_vec(),
            }],
            ..Default::default()
        };
        self.push(vec![tx], frontier);
    }

    /// `blocks` more empty blocks.
    fn grow(&mut self, blocks: u32) {
        for _ in 0..blocks {
            self.empty();
        }
    }

    /// Tells the wallet at `path` the tip is the chain's last block, then
    /// scans `from` through `to` into it.
    fn scan(&self, path: &str, from: u32, to: u32) {
        let mut db = open(path);
        // Keep an anchor checkpoint at every block, so any confirmation depth
        // finds one.
        db.set_anchor_retention_interval(AnchorRetentionInterval::custom(
            NonZeroU32::new(1).unwrap(),
        ));
        db.update_chain_tip(BlockHeight::from(self.tip())).unwrap();
        let blocks =
            self.blocks[(from - self.start) as usize..=(to - self.start) as usize].to_vec();
        let state = ChainState::new(
            BlockHeight::from(from - 1),
            BlockHash(Self::hash(from - 1)),
            Frontier::empty(),
            Frontier::empty(),
            self.frontier_after(from - 1),
        );
        let count = blocks.len();
        scan_cached_blocks(
            &NETWORK,
            &Blocks(blocks),
            &mut db,
            BlockHeight::from(from),
            &state,
            count,
        )
        .unwrap();
    }

    /// Ten blocks after the start: a note paid at the start is ten deep,
    /// enough for an ordinary send's six confirmations.
    fn fund(&mut self, path: &str, recipient: orchard::Address) {
        self.pay(recipient, FUNDS);
        self.grow(9);
        self.scan(path, self.start, self.tip());
    }
}

fn open(path: &str) -> db::WalletDatabase {
    db::open_wallet_db_with_timeout(path, NETWORK, db::WALLET_DB_BUSY_TIMEOUT).unwrap()
}

struct Wallet {
    _dir: tempfile::TempDir,
    path: String,
    account: String,
}

fn temp_db(name: &str) -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(name).to_str().unwrap().to_string();
    (dir, path)
}

/// A software account born at the chain's start.
fn main_wallet(chain: &Chain) -> Wallet {
    let (dir, path) = temp_db("zcash_wallet.db");
    let (account, _) = keys::init_db_and_create_account(
        &path,
        NETWORK,
        &SecretVec::new(SEED.to_vec()),
        Some(u64::from(chain.start)),
        "Main",
    )
    .unwrap();
    Wallet {
        _dir: dir,
        path,
        account,
    }
}

fn main_address() -> orchard::Address {
    UnifiedSpendingKey::from_seed(&NETWORK, &SEED, zip32::AccountId::ZERO)
        .unwrap()
        .to_unified_full_viewing_key()
        .orchard()
        .unwrap()
        .address_at(0u32, Scope::External)
}

/// An Orchard-only unified address, the shape of a home address.
fn home_ua() -> String {
    unified::Address::try_from_items(vec![unified::Receiver::Orchard(
        main_address().to_raw_address_bytes(),
    )])
    .unwrap()
    .encode(&NETWORK.network_type())
}

/// Swap `index`'s joint account with the vectors' maker share.
fn joint_account(index: u32) -> JointAccount {
    let maker = derive_maker_share(&[9; 32], u64::from(index)).unwrap();
    SwapKeyContext::for_tests(&[7; 64], PrivateUsdNetwork::Mainnet, 0)
        .joint(index, &maker.public())
        .unwrap()
}

/// `joint.db` holding `joint`, born at the chain's start.
fn joint_wallet(chain: &Chain, joint: &JointAccount) -> Wallet {
    let (dir, path) = temp_db("joint.db");
    let account = joint::register_joint_account(
        &path,
        NETWORK,
        &joint.ufvk(NETWORK.network_type()),
        chain.start,
    )
    .unwrap();
    Wallet {
        _dir: dir,
        path,
        account,
    }
}

/// The send-proposal input locks the wallet at `path` records for recovery.
fn proposal_locks(path: &str) -> i64 {
    let conn = rusqlite::Connection::open(path).unwrap();
    let exists: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'vizor_send_proposal_locks')",
            [],
            |row| row.get(0),
        )
        .unwrap();
    if !exists {
        return 0;
    }
    conn.query_row(
        "SELECT COUNT(*) FROM vizor_send_proposal_locks",
        [],
        |row| row.get(0),
    )
    .unwrap()
}

/// The PCZT's non-zero outputs, and how many of them any of `ovks` recovers.
fn ovk_recovery(pczt: &[u8], ovks: &[OutgoingViewingKey]) -> (usize, usize) {
    fn tally<D>(
        bundle: &orchard::pczt::Bundle,
        domain: impl Fn(&orchard::pczt::Action) -> D,
        ovks: &[OutgoingViewingKey],
        counts: &mut (usize, usize),
    ) where
        D: Domain<
            OutgoingViewingKey = OutgoingViewingKey,
            ValueCommitment = orchard::value::ValueCommitment,
        >,
        orchard::pczt::Action: ShieldedOutput<D, ENC_CIPHERTEXT_SIZE>,
    {
        for action in bundle.actions() {
            if action
                .output()
                .value()
                .is_none_or(|value| value.inner() == 0)
            {
                continue;
            }
            counts.0 += 1;
            let domain = domain(action);
            let out_ciphertext = &action.output().encrypted_note().out_ciphertext;
            if ovks.iter().any(|ovk| {
                try_output_recovery_with_ovk(&domain, ovk, action, action.cv_net(), out_ciphertext)
                    .is_some()
            }) {
                counts.1 += 1;
            }
        }
    }

    let pczt = pczt::Pczt::parse(pczt).unwrap();
    let (has_orchard, has_ironwood) = (
        !pczt.orchard().actions().is_empty(),
        !pczt.ironwood().actions().is_empty(),
    );
    let mut counts = (0, 0);
    let mut verifier = Verifier::new(pczt);
    if has_orchard {
        verifier = verifier
            .with_orchard(|bundle| {
                tally(bundle, OrchardDomain::for_pczt_action, ovks, &mut counts);
                Ok::<_, OrchardError<std::convert::Infallible>>(())
            })
            .unwrap();
    }
    if has_ironwood {
        verifier
            .with_ironwood(|bundle| {
                tally(bundle, IronwoodDomain::for_pczt_action, ovks, &mut counts);
                Ok::<_, OrchardError<std::convert::Infallible>>(())
            })
            .unwrap();
    }
    counts
}

/// A deposit is one transaction whose amount plus fee stays within the
/// approved total. A refused deposit locks nothing. The joint sweep shares
/// the one-transaction check.
#[test]
fn a_swap_deposit_is_one_transaction_within_its_approved_total() {
    let mut chain = Chain::new();
    let wallet = main_wallet(&chain);
    chain.fund(&wallet.path, main_address());
    let joint_ua = joint_account(0).unified_address(NETWORK.network_type());
    let propose = |to: &str, amount: u64, max_total: u64| {
        sync::propose_swap_deposit(
            &wallet.path,
            NETWORK,
            &wallet.account,
            "deposit",
            to,
            amount,
            max_total,
        )
    };

    let over = propose(&joint_ua, 500_000, 500_000)
        .err()
        .unwrap()
        .to_string();
    assert!(over.contains("more than the approved 500000"), "{over}");
    // A TEX recipient takes two transactions (ZIP 320).
    let tex = Address::Tex([2; 20]).to_zcash_address(&NETWORK).encode();
    let split = propose(&tex, 500_000, FUNDS).err().unwrap().to_string();
    assert!(split.contains("must be one transaction"), "{split}");
    assert_eq!(proposal_locks(&wallet.path), 0);

    // Neither refusal held the note: a deposit within its total takes it.
    let deposit = propose(&joint_ua, 500_000, 600_000).unwrap();
    assert_eq!(deposit.amount_zatoshi, 500_000);
    assert!(deposit.fee_zatoshi > 0 && 500_000 + deposit.fee_zatoshi <= 600_000);
    assert!(proposal_locks(&wallet.path) > 0);
    sync::discard_proposal(deposit.proposal_id, "deposit").unwrap();
    assert_eq!(proposal_locks(&wallet.path), 0);
}

/// The create half stores the deposit without sending it; `find_deposit`
/// finds it; `swap_tx_status` follows it until it is mined or provably
/// expired.
#[tokio::test]
async fn a_stored_deposit_is_found_and_followed_until_it_expires() {
    let _route = lock_route_policy();
    let mut chain = Chain::new();
    let wallet = main_wallet(&chain);
    chain.fund(&wallet.path, main_address());
    let joint_ua = joint_account(0).unified_address(NETWORK.network_type());
    let lwd = CapturingLwd::start_with(vec![], u64::from(chain.tip()), |_| {}).await;

    let deposit = sync::propose_swap_deposit(
        &wallet.path,
        NETWORK,
        &wallet.account,
        "deposit",
        &joint_ua,
        500_000,
        600_000,
    )
    .unwrap();
    let created = sync::create_stored_proposal_transactions(
        &wallet.path,
        &lwd.url,
        deposit.proposal_id,
        "deposit",
        SecretVec::new(SEED.to_vec()),
        None,
        None,
    )
    .await
    .unwrap();
    assert_eq!(created.len(), 1);
    let created = &created[0];
    assert_eq!(
        lwd.count("/SendTransaction"),
        0,
        "the create half sends nothing"
    );

    let find = |to: &str| joint::find_deposit(&wallet.path, NETWORK, &wallet.account, to).unwrap();
    let found = find(&joint_ua).expect("the stored, unsent deposit is found");
    assert_eq!(found.txid, created.txid);
    assert_eq!(found.raw, created.raw);
    assert_eq!(found.expiry_height, created.expiry_height);
    assert!(find(&joint_account(1).unified_address(NETWORK.network_type())).is_none());

    let expiry = created.expiry_height;
    let absent = TxId::from_bytes([0xab; 32]);
    let status = |txid: &TxId, expiry: u32| {
        joint::swap_tx_status(&wallet.path, NETWORK, txid, expiry).unwrap()
    };
    assert_eq!(status(&created.txid, expiry), SwapTxStatus::Unmined);
    assert_eq!(status(&absent, expiry), SwapTxStatus::Unknown);

    // A tip past the expiry proves nothing while its blocks are unscanned.
    let scanned = chain.tip();
    chain.grow(expiry + 1 - scanned);
    open(&wallet.path)
        .update_chain_tip(BlockHeight::from(chain.tip()))
        .unwrap();
    assert_eq!(status(&created.txid, expiry), SwapTxStatus::Unmined);

    // Scanned through the expiry height: it may still be mined in that block.
    chain.scan(&wallet.path, scanned + 1, expiry);
    assert_eq!(status(&created.txid, expiry), SwapTxStatus::Unmined);
    assert_eq!(status(&absent, expiry), SwapTxStatus::Unknown);

    // Scanned past it: expired, held or not. No expiry never expires.
    chain.scan(&wallet.path, expiry + 1, expiry + 1);
    assert_eq!(status(&created.txid, expiry), SwapTxStatus::Expired);
    assert_eq!(status(&absent, expiry), SwapTxStatus::Expired);
    assert_eq!(status(&created.txid, 0), SwapTxStatus::Unmined);
    assert_eq!(status(&absent, 0), SwapTxStatus::Unknown);
    assert!(find(&joint_ua).is_none(), "an expired deposit is not found");

    // Mined in its last valid block: never expired, and found again.
    open(&wallet.path)
        .set_transaction_status(
            created.txid,
            TransactionStatus::Mined(BlockHeight::from(expiry)),
        )
        .unwrap();
    assert_eq!(
        status(&created.txid, expiry),
        SwapTxStatus::Mined {
            height: expiry,
            confirmations: 2
        }
    );
    assert_eq!(find(&joint_ua).map(|found| found.txid), Some(created.txid));
}

/// A joint sweep's PCZT discards the joint OVK, which the maker holds. An
/// ordinary send from the same account keeps it, which shows the check can
/// recover an output.
#[tokio::test]
async fn a_joint_sweep_pczt_discards_the_joint_ovk() {
    let _route = lock_route_policy();
    let mut chain = Chain::new();
    let joint = joint_account(0);
    let wallet = joint_wallet(&chain, &joint);
    chain.fund(&wallet.path, joint.deposit_address());
    let lwd = CapturingLwd::start_with(vec![], u64::from(chain.tip()), |_| {}).await;
    let ovks = [
        joint.fvk().to_ovk(Scope::External),
        joint.fvk().to_ovk(Scope::Internal),
    ];

    let ordinary = sync::propose_send_for_purpose(
        &wallet.path,
        NETWORK,
        &wallet.account,
        "ordinary",
        &home_ua(),
        100_000,
        None,
        sync::SendPurpose::Ordinary,
    )
    .unwrap();
    let pczt = sync::create_pczt_from_proposal(
        &wallet.path,
        &lwd.url,
        NETWORK,
        ordinary.proposal_id,
        "ordinary",
    )
    .await
    .unwrap();
    // librustzcash encrypts change without an OVK; the payment is what the
    // sender OVK recovers.
    let (outputs, recovered) = ovk_recovery(&pczt, &ovks);
    assert_eq!(
        (outputs, recovered),
        (2, 1),
        "a recoverable payment and its change"
    );
    sync::discard_proposal(ordinary.proposal_id, "ordinary").unwrap();

    let sweep = sync::propose_joint_sweep(
        &wallet.path,
        NETWORK,
        &wallet.account,
        "sweep",
        &home_ua(),
        50_000,
    )
    .unwrap();
    assert_eq!(
        sweep.amount_zatoshi + sweep.fee_zatoshi,
        FUNDS,
        "all of it, no change"
    );
    let pczt = sync::create_pczt_from_proposal(
        &wallet.path,
        &lwd.url,
        NETWORK,
        sweep.proposal_id,
        "sweep",
    )
    .await
    .unwrap();
    assert_eq!(
        ovk_recovery(&pczt, &ovks),
        (1, 0),
        "one output, home, which the joint OVK cannot recover"
    );
    sync::discard_proposal(sweep.proposal_id, "sweep").unwrap();
    assert_eq!(proposal_locks(&wallet.path), 0);
}

/// A sweep whose fee exceeds its limit is refused before anything is locked,
/// so the note stays free for a sweep within it. (A sweep of more than one
/// transaction fails the same one-transaction check as the deposit.)
#[test]
fn a_joint_sweep_over_its_fee_limit_is_refused_and_locks_nothing() {
    let mut chain = Chain::new();
    let joint = joint_account(0);
    let wallet = joint_wallet(&chain, &joint);
    chain.fund(&wallet.path, joint.deposit_address());
    let propose = |max_fee: u64| {
        sync::propose_joint_sweep(
            &wallet.path,
            NETWORK,
            &wallet.account,
            "sweep",
            &home_ua(),
            max_fee,
        )
    };

    let refused = propose(1).err().unwrap();
    assert!(refused.contains("exceeds its limit of 1"), "{refused}");
    assert_eq!(proposal_locks(&wallet.path), 0);

    let sweep = propose(50_000).unwrap();
    assert_eq!(sweep.amount_zatoshi + sweep.fee_zatoshi, FUNDS);
    sync::discard_proposal(sweep.proposal_id, "sweep").unwrap();
    assert_eq!(proposal_locks(&wallet.path), 0);
}
