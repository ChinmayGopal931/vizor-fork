//! One-time IVK swaps on the Dockerized Ironwood regtest stack
//! (`scripts/ironwood-regtest`), driven through Vizor's API and sync engine.
//!
//! Real: the node, lightwalletd, signed Ironwood transactions, Vizor's wallet, sync and
//! swap API, and the receiver directory's routes and PIR, reached over HTTP. Simulated:
//! NEAR, whose payouts and refunds a payer wallet sends with the zero OVK; the directory's
//! indexer, which reads the node's raw blocks as the live one does; and time, which a mock
//! clock moves for the node and Vizor together. Debug builds of Vizor read the seams
//! these tests set (see `one_time_ivk` and `swap_private`).
//!
//! Each test resets the chain. Run them one at a time:
//! `cargo test --test ironwood_regtest_one_time_ivk -- --ignored --test-threads=1`.

mod chain;
mod directory;
mod near;
mod wallets;

use std::sync::{Mutex, MutexGuard};

use rust_lib_zcash_wallet::api::{sync as sync_api, wallet as wallet_api};
use zcash_client_backend::wallet::OvkPolicy;

use chain::{internal_hash, Stack, DAY, HOUR, MINUTE, ZEC};
use directory::{zero_ovk_receivers, DirectoryServer, Indexer};
use near::Near;
use wallets::{broadcast, zero_ovk, IncomingSwap, Payer, RefundSwap, Wallet};

static STACK: Mutex<()> = Mutex::new(());

const PAYOUT: u64 = ZEC / 4;

/// The chain, the directory serving it, NEAR, and NEAR's payer, for one test.
struct World {
    stack: Stack,
    indexer: Indexer,
    directory: DirectoryServer,
    near: Near,
    payer: Payer,
    genesis: [u8; 32],
}

impl World {
    /// A fresh chain past Ironwood activation, a payer holding Ironwood notes, and a
    /// directory that Vizor is pointed at.
    fn start() -> Self {
        let stack = Stack::start();
        let directory = DirectoryServer::start();
        let genesis = stack.genesis_displayed();
        std::env::set_var("VIZOR_REGTEST_ONE_TIME_IVKS", "1");
        std::env::set_var("VIZOR_RECEIVER_PIR_URL", directory.origin());
        std::env::set_var("VIZOR_RECEIVER_PIR_GENESIS", &genesis);
        sync_api::set_near_swap_privacy_enabled(true);

        let payer = Payer::new(Wallet::import("NEAR", &wallet_api::generate_mnemonic(), 1));
        stack.fund_orchard(&[&payer.wallet.address], 10);
        stack.activate_ironwood();
        stack.mine(3);
        let mut world = Self {
            indexer: Indexer::new(stack.activation()),
            directory,
            near: Near::new(stack.now()),
            payer,
            genesis: internal_hash(&genesis),
            stack,
        };
        world.publish();
        // Several Ironwood notes, so payments need not wait for change.
        let own = world.payer.own_addresses(8);
        let split: Vec<(&str, u64)> = own.iter().map(|a| (a.as_str(), ZEC)).collect();
        world.payer.pay(&world.stack, &split, OvkPolicy::Sender);
        world.stack.mine(1);
        world
    }

    /// A new wallet whose birthday is the tip, synced.
    fn wallet(&mut self, name: &str) -> Wallet {
        let wallet = Wallet::import(name, &wallet_api::generate_mnemonic(), self.stack.tip());
        self.sync(&wallet);
        wallet
    }

    /// Republishes the directory two blocks below the tip, as the live indexer does.
    fn publish(&mut self) {
        let end = self.stack.tip().saturating_sub(2);
        if end < self.stack.activation() {
            return;
        }
        let sets = self.near.sets(self.stack.now());
        let publication = self
            .indexer
            .publication(&self.stack, end, &sets, self.genesis);
        self.directory.publish(publication);
    }

    /// Republishes the directory, then syncs `wallet` once, as the app's poll would.
    fn sync(&mut self, wallet: &Wallet) {
        self.publish();
        wallet.sync(&self.stack);
    }

    /// Syncs `wallet`, mining a block between syncs, until it holds `expected` or
    /// `rounds` syncs have run. Returns whether it holds `expected`.
    fn sync_until(&mut self, wallet: &Wallet, expected: u64, rounds: u32) -> bool {
        for round in 0..rounds {
            if round > 0 {
                self.stack.mine(1);
            }
            self.sync(wallet);
            if wallet.total() == expected {
                return true;
            }
        }
        false
    }

    /// Quotes an incoming swap on `wallet`, syncing while restored addresses are still
    /// being checked, as a user would retry.
    fn quote_incoming(&mut self, wallet: &Wallet, deadline_in: i64) -> IncomingSwap {
        for _ in 0..4 {
            match wallet.quote_incoming(&self.stack, &mut self.near, deadline_in) {
                Ok(swap) => return swap,
                Err(e) => {
                    eprintln!("{} cannot quote yet: {e}", wallet.name);
                    self.stack.mine(1);
                    self.sync(wallet);
                }
            }
        }
        panic!("{} never quotes", wallet.name);
    }

    /// Quotes a ZEC-to-X swap on `wallet`, retrying like [`Self::quote_incoming`].
    fn quote_refund(&mut self, wallet: &Wallet, deadline_in: i64) -> RefundSwap {
        for _ in 0..4 {
            match wallet.quote_refund(&self.stack, &mut self.near, deadline_in) {
                Ok(swap) => return swap,
                Err(e) => {
                    eprintln!("{} cannot quote yet: {e}", wallet.name);
                    self.stack.mine(1);
                    self.sync(wallet);
                }
            }
        }
        panic!("{} never quotes", wallet.name);
    }

    /// NEAR pays `value` to `address` with the zero OVK, in a block of its own.
    fn pay(&mut self, address: &str, value: u64) {
        self.payer.pay(&self.stack, &[(address, value)], zero_ovk());
        self.stack.mine(1);
    }

    /// NEAR pays `value` to `address` with the zero OVK, in a block of its own, with the
    /// payment's sibling leaf in the note commitment tree where `sibling` says. Applying a
    /// late find inserts the payment with its sibling's hash. Returns the position.
    fn pay_late(&mut self, address: &str, receiver: [u8; 43], value: u64, sibling: Sibling) -> u64 {
        // A payout has two actions, the payment and its change, in a shuffled order.
        let (base_odd, index) = match sibling {
            Sibling::OwnChangeAfter => (false, 0),
            Sibling::OwnChangeBefore => (false, 1),
            Sibling::EarlierBlock => (true, 0),
        };
        for _ in 0..12 {
            let base = self.indexer.tree_size(&self.stack, self.stack.tip());
            if (base % 2 == 1) != base_odd {
                // A three-action transaction moves the next block's tree size to the other
                // parity.
                let own = self.payer.own_addresses(2);
                let padding: Vec<(&str, u64)> =
                    own.iter().map(|a| (a.as_str(), ZEC / 100)).collect();
                self.payer.pay(&self.stack, &padding, OvkPolicy::Sender);
                self.stack.mine(1);
                continue;
            }
            // Built in a copy of the payer's wallet, so a draw in the wrong order leaves
            // nothing behind to resubmit.
            let tx = self
                .payer
                .build_detached(&self.stack, &[(address, value)], zero_ovk());
            let actions = zero_ovk_receivers(&tx);
            let at = actions
                .iter()
                .position(|r| r.as_ref() == Some(&receiver))
                .expect("the payment's action");
            if actions.len() != 2 || at != index {
                continue;
            }
            broadcast(&self.stack, &tx);
            self.stack.mine(1);
            self.indexer.tree_size(&self.stack, self.stack.tip());
            let position = *self
                .indexer
                .positions(&receiver)
                .last()
                .expect("the indexer saw the payment");
            assert_eq!(
                position,
                base + at as u64,
                "the payment is alone in its block"
            );
            eprintln!("late payment at position {position}, sibling {sibling:?}");
            return position;
        }
        panic!("no payout drew the {sibling:?} layout");
    }
}

/// Where a late payment's sibling leaf sits in the note commitment tree. Applying a late
/// find inserts the payment with that sibling's hash.
#[derive(Clone, Copy, Debug)]
enum Sibling {
    /// The payment's own change, to its right: the payment is at an even position.
    OwnChangeAfter,
    /// The payment's own change, to its left: the payment is at an odd position.
    OwnChangeBefore,
    /// The last output of an earlier block, to its left: an odd position.
    EarlierBlock,
}

/// Serializes the tests, which share one regtest stack, and prints Vizor's warnings,
/// such as a deferred restore sweep, to standard error (`E2E_LOG=info` for more).
fn lock() -> MutexGuard<'static, ()> {
    static LOGGER: StderrLogger = StderrLogger;
    let level = match std::env::var("E2E_LOG").as_deref() {
        Ok("info") => log::LevelFilter::Info,
        _ => log::LevelFilter::Warn,
    };
    if log::set_logger(&LOGGER).is_ok() {
        log::set_max_level(level);
    }
    STACK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Vizor's `log` records on standard error.
struct StderrLogger;

impl log::Log for StderrLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            eprintln!("[{} {}] {}", record.level(), record.target(), record.args());
        }
    }

    fn flush(&self) {}
}

/// An incoming swap's payout is found while the wallet scans, and a restore of the seed
/// two days later finds it again through the receiver directory.
#[test]
#[ignore = "requires the Dockerized Ironwood zcashd/lightwalletd regtest stack"]
fn incoming_payout_is_found_live_and_by_a_later_restore() {
    let _guard = lock();
    let mut world = World::start();
    let a = world.wallet("A");
    let birthday = world.stack.tip();
    let swap = world.quote_incoming(&a, HOUR);
    world.stack.advance(20 * MINUTE);
    world.pay(&swap.address, PAYOUT);
    assert!(
        world.sync_until(&a, PAYOUT, 3),
        "A finds the payout while scanning"
    );
    a.observe_incoming(&world.stack, &swap, "SUCCESS", PAYOUT);
    world.stack.mine(12);
    world.sync(&a);

    world.stack.advance(2 * DAY);
    world.stack.mine(1);
    let b = Wallet::import("B", &a.mnemonic, birthday);
    let lookups = world.directory.lookups();
    assert!(
        world.sync_until(&b, PAYOUT, 10),
        "B, restored from A's seed, finds the payout (holds {})",
        b.total()
    );
    assert!(
        world.directory.lookups() > lookups,
        "B looked the payout up in the directory"
    );
}

/// One address paid twice in a row is credited twice while it scans. A third payment
/// three weeks later, after the key closed, is found only by Check swap history; here its
/// sibling leaf is its own change, to its right.
#[test]
#[ignore = "requires the Dockerized Ironwood zcashd/lightwalletd regtest stack"]
fn address_paid_twice_then_late_beside_its_own_change_after() {
    late_payment(true, Sibling::OwnChangeAfter);
}

/// A late payment found by Check swap history, its sibling leaf its own change, to its left.
#[test]
#[ignore = "requires the Dockerized Ironwood zcashd/lightwalletd regtest stack"]
fn late_payment_beside_its_own_change_before() {
    late_payment(false, Sibling::OwnChangeBefore);
}

/// A late payment found by Check swap history, its sibling leaf an earlier block's output.
#[test]
#[ignore = "requires the Dockerized Ironwood zcashd/lightwalletd regtest stack"]
fn late_payment_beside_an_earlier_block() {
    late_payment(false, Sibling::EarlierBlock);
}

/// Pays an incoming swap's address (twice in a row when `twice`), lets its key close,
/// then pays it again three weeks later with the payment's sibling where `sibling` says,
/// and checks that only Check swap history finds that payment.
fn late_payment(twice: bool, sibling: Sibling) {
    let _guard = lock();
    let (mut world, a, held) = paid_late(twice, sibling);
    // The directory publishes two blocks below the tip, and a recheck before then misses
    // the payment.
    assert!(
        !world.sync_until(&a, held, 3),
        "the key closed, so only Check swap history finds a later payment"
    );
    a.check_swap_history();
    assert!(
        world.sync_until(&a, held, 10),
        "Check swap history finds the late payment (A holds {})",
        a.total()
    );
}

/// Check swap history runs once. Run before the directory has published a late payment, it
/// finishes without the payment, and only running it again finds it.
#[test]
#[ignore = "requires the Dockerized Ironwood zcashd/lightwalletd regtest stack"]
fn check_swap_history_before_the_directory_publishes_needs_another_run() {
    let _guard = lock();
    let (mut world, a, held) = paid_late(false, Sibling::EarlierBlock);
    a.check_swap_history();
    assert!(
        !world.sync_until(&a, held, 4),
        "a check against a publication without the payment finishes without it"
    );
    a.check_swap_history();
    assert!(
        world.sync_until(&a, held, 10),
        "checking swap history again finds the late payment (A holds {})",
        a.total()
    );
}

/// A wallet whose swap address was paid (twice in a row when `twice`) and found, whose key
/// then closed, and which NEAR paid again three weeks later with the payment's sibling
/// where `sibling` says, just mined. Returns what the wallet holds once it finds that
/// payment too.
fn paid_late(twice: bool, sibling: Sibling) -> (World, Wallet, u64) {
    let mut world = World::start();
    let a = world.wallet("A");
    let swap = world.quote_incoming(&a, HOUR);
    world.stack.advance(20 * MINUTE);
    world.pay(&swap.address, PAYOUT);
    let mut paid = PAYOUT;
    if twice {
        world.pay(&swap.address, PAYOUT / 2);
        paid += PAYOUT / 2;
    }
    assert!(
        world.sync_until(&a, paid, 3),
        "A finds every payout while scanning"
    );
    a.observe_incoming(&world.stack, &swap, "SUCCESS", paid);
    world.stack.mine(12);
    world.sync(&a);

    world.stack.advance(21 * DAY);
    world.stack.mine(1);
    world.pay_late(&swap.address, swap.receiver, PAYOUT / 5, sibling);
    (world, a, paid + PAYOUT / 5)
}

/// A ZEC-to-X swap's refund is found while the refund key scans, and a restore two days
/// later recovers the key from the funding transaction's memo and finds the refund
/// through the receiver directory.
#[test]
#[ignore = "requires the Dockerized Ironwood zcashd/lightwalletd regtest stack"]
fn refund_is_found_live_and_by_a_later_restore() {
    let _guard = lock();
    let mut world = World::start();
    let a = world.wallet("A");
    let birthday = world.stack.tip();
    world
        .payer
        .pay(&world.stack, &[(&a.address, 2 * ZEC)], OvkPolicy::Sender);
    world.stack.mine(10);
    world.sync(&a);
    assert_eq!(a.total(), 2 * ZEC, "A holds its funding");

    let swap = world.quote_refund(&a, HOUR);
    a.fund_swap(&world.stack, &swap, ZEC / 2);
    world.stack.mine(1);
    world.sync(&a);
    let funded = a.total();
    assert!(funded < 2 * ZEC - ZEC / 2 + 1, "A paid the deposit");

    world.stack.advance(30 * MINUTE);
    world.pay(&swap.address, ZEC / 2);
    assert!(
        world.sync_until(&a, funded + ZEC / 2, 3),
        "A finds the refund while the refund key scans (holds {})",
        a.total()
    );
    a.observe_refund(&world.stack, &swap, "REFUNDED", ZEC / 2);
    world.stack.mine(12);
    world.sync(&a);

    world.stack.advance(2 * DAY);
    world.stack.mine(1);
    let b = Wallet::import("B", &a.mnemonic, birthday);
    assert!(
        world.sync_until(&b, a.total(), 15),
        "B, restored from A's seed, finds the refund (holds {}, A holds {})",
        b.total(),
        a.total()
    );
}
