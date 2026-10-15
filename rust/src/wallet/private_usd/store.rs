//! `swaps.db`: the swap-index counter, swap records, active pointers, the
//! joint-account index and the Railgun send log (plan §3.4).
//!
//! A plain SQLite file in app-private storage, opened per call (WAL,
//! `synchronous = FULL`, a busy timeout), migrated by `PRAGMA user_version`.
//! Every write is one transaction, so a crash cannot tear a record or move
//! the counter back. Records decode strictly: an unreadable one is an error,
//! never a reset. Hold `private_usd::OPERATIONS` around writes, never across
//! network I/O. Never log a record: it may hold a ticket.

use std::fmt;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

use super::models::{Direction, StoredRecord};
use super::{fail, ErrorCode, PrivateUsdError, Result};

const FILE_NAME: &str = "swaps.db";
const SCHEMA_VERSION: i32 = 1;
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);
/// Finished records kept per direction. Reverse `REFUNDED` ones are kept
/// beyond it: a rescue may still be possible.
const MAX_HISTORY: u32 = 100;
/// Confirmed sends kept per account; unconfirmed ones are never trimmed.
const MAX_CONFIRMED_SENDS: u32 = 100;
/// The index space zapp counts in (a Kotlin `Int`).
const MAX_INDEX: i64 = i32::MAX as i64;

const SCHEMA: &str = "
CREATE TABLE swap_counter(account_uuid TEXT PRIMARY KEY, next_index INTEGER NOT NULL);
CREATE TABLE swaps(
  account_uuid TEXT NOT NULL,
  direction    TEXT NOT NULL CHECK (direction IN ('forward','reverse')),
  swap_index   INTEGER NOT NULL,
  deployment   TEXT NOT NULL,
  swap_id      TEXT,
  phase        TEXT NOT NULL,
  finished     INTEGER NOT NULL,
  record_json  TEXT NOT NULL,
  updated_at   INTEGER NOT NULL,
  PRIMARY KEY(account_uuid, direction, swap_index));
CREATE TABLE active(account_uuid TEXT, direction TEXT, swap_index INTEGER,
  PRIMARY KEY(account_uuid, direction));
CREATE TABLE joint_accounts(account_uuid TEXT, direction TEXT, swap_index INTEGER,
  joint_uuid TEXT NOT NULL, ufvk TEXT NOT NULL, birthday INTEGER NOT NULL,
  PRIMARY KEY(account_uuid, direction, swap_index));
CREATE TABLE railgun_sends(
  account_uuid TEXT NOT NULL, send_id TEXT NOT NULL, created_at INTEGER NOT NULL,
  state TEXT NOT NULL, record_json TEXT NOT NULL,
  PRIMARY KEY(account_uuid, send_id));
";

/// A joint account a swap imported into `joint.db`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct JointAccountRow {
    pub account_uuid: String,
    pub direction: Direction,
    pub swap_index: u32,
    pub joint_uuid: String,
    pub ufvk: String,
    pub birthday: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SendState {
    /// Proved and kept; the record holds the relay request and nullifiers.
    Unconfirmed,
    Confirmed,
}

impl SendState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Unconfirmed => "unconfirmed",
            Self::Confirmed => "confirmed",
        }
    }
}

/// One proved Railgun send. A send still being proved is never written.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct SendRow {
    pub send_id: String,
    pub created_at: u64,
    pub state: SendState,
    pub record_json: String,
}

impl fmt::Debug for SendRow {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SendRow")
            .field("send_id", &self.send_id)
            .field("state", &self.state)
            .finish_non_exhaustive()
    }
}

pub(crate) struct SwapStore {
    conn: Connection,
}

fn unreadable(message: impl Into<String>) -> PrivateUsdError {
    PrivateUsdError::new(ErrorCode::StoreUnreadable, message)
}

fn sql(error: rusqlite::Error) -> PrivateUsdError {
    unreadable(format!("swap store: {error}"))
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or_default()
}

#[cfg(test)]
thread_local! {
    /// Fails the next `save` on this thread just before it commits, as a
    /// crash there would.
    static CRASH_BEFORE_COMMIT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Fails the next record write on this thread just before it commits, as a
/// crash there would.
#[cfg(test)]
pub(crate) fn crash_before_next_commit() {
    CRASH_BEFORE_COMMIT.with(|crash| crash.set(true));
}

impl SwapStore {
    /// Opens `dir/swaps.db`, creating and migrating it. A store written by a
    /// newer version is refused, never reset.
    pub(crate) fn open(dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(dir)
            .map_err(|error| unreadable(format!("swap store directory: {error}")))?;
        let mut conn = Connection::open(dir.join(FILE_NAME)).map_err(sql)?;
        conn.busy_timeout(BUSY_TIMEOUT).map_err(sql)?;
        let mode: String = conn
            .query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))
            .map_err(sql)?;
        if !mode.eq_ignore_ascii_case("wal") {
            return Err(unreadable(format!("swap store journal mode is {mode}")));
        }
        // The counter must survive power loss: an index a quote spent is
        // never handed out again.
        conn.pragma_update(None, "synchronous", "FULL")
            .map_err(sql)?;
        // Reading the send log must not wait for an unrelated writer just
        // to check a schema that is already current. WAL readers can proceed
        // while a swap record is being committed. A new store still takes
        // the write lock and rechecks below, so concurrent first opens cannot
        // both create the schema.
        let version: i32 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(sql)?;
        if version == SCHEMA_VERSION {
            return Ok(Self { conn });
        }
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql)?;
        let version: i32 = tx
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(sql)?;
        match version {
            0 => {
                tx.execute_batch(SCHEMA).map_err(sql)?;
                tx.pragma_update(None, "user_version", SCHEMA_VERSION)
                    .map_err(sql)?;
            }
            SCHEMA_VERSION => {}
            newer => {
                return Err(unreadable(format!(
                    "swap store version {newer} is newer than this app"
                )))
            }
        }
        tx.commit().map_err(sql)?;
        Ok(Self { conn })
    }

    /// Opens `dir/swaps.db` only if it exists: a query about conversions on a
    /// wallet that never made one creates nothing.
    pub(crate) fn open_existing(dir: &Path) -> Result<Option<Self>> {
        if !dir.join(FILE_NAME).exists() {
            return Ok(None);
        }
        Self::open(dir).map(Some)
    }

    /// The account's next swap index, committed as taken before it is
    /// returned: an index is spent once handed out, whatever follows. Never
    /// below an index a kept record already has.
    pub(crate) fn take_index(&mut self, account: &str) -> Result<u32> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql)?;
        let counter: Option<i64> = tx
            .query_row(
                "SELECT next_index FROM swap_counter WHERE account_uuid = ?1",
                [account],
                |row| row.get(0),
            )
            .optional()
            .map_err(sql)?;
        let highest: Option<i64> = tx
            .query_row(
                "SELECT MAX(swap_index) FROM swaps WHERE account_uuid = ?1",
                [account],
                |row| row.get(0),
            )
            .map_err(sql)?;
        let index = counter
            .unwrap_or(0)
            .max(highest.map_or(0, |highest| highest + 1));
        if !(0..MAX_INDEX).contains(&index) {
            return fail(ErrorCode::Other, "no swap index left for this account");
        }
        tx.execute(
            "INSERT INTO swap_counter(account_uuid, next_index) VALUES (?1, ?2)
             ON CONFLICT(account_uuid) DO UPDATE SET next_index = excluded.next_index",
            params![account, index + 1],
        )
        .map_err(sql)?;
        tx.commit().map_err(sql)?;
        Ok(u32::try_from(index).expect("below i32::MAX"))
    }

    /// Keeps `record` and makes it its direction's active record, in one
    /// transaction. Returns whether anything changed: an unchanged record is
    /// not written. A reverse quote replaces the account's earlier draft.
    pub(crate) fn save(&mut self, account: &str, record: &StoredRecord) -> Result<bool> {
        self.write(account, record, true)
    }

    /// Changes a kept record in place, leaving which one is active alone.
    /// Returns whether anything changed; a record not kept is an error.
    pub(crate) fn update(&mut self, account: &str, record: &StoredRecord) -> Result<bool> {
        self.write(account, record, false)
    }

    fn write(&mut self, account: &str, record: &StoredRecord, activate: bool) -> Result<bool> {
        let json = record.to_json().map_err(unreadable)?;
        let direction = record.direction().as_str();
        let index = i64::from(record.index());
        let deployment = record
            .deployment_name()
            .ok_or_else(|| unreadable("the record is for no pinned deployment"))?;
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql)?;
        let kept: Option<String> = tx
            .query_row(
                "SELECT record_json FROM swaps
                 WHERE account_uuid = ?1 AND direction = ?2 AND swap_index = ?3",
                params![account, direction, index],
                |row| row.get(0),
            )
            .optional()
            .map_err(sql)?;
        let active: Option<i64> = tx
            .query_row(
                "SELECT swap_index FROM active WHERE account_uuid = ?1 AND direction = ?2",
                params![account, direction],
                |row| row.get(0),
            )
            .optional()
            .map_err(sql)?;
        if kept.is_none() && !activate {
            return fail(ErrorCode::StoreUnreadable, "no such record to update");
        }
        if kept.as_deref() == Some(json.as_str()) && (!activate || active == Some(index)) {
            return Ok(false);
        }
        tx.execute(
            "INSERT INTO swaps(account_uuid, direction, swap_index, deployment, swap_id, phase,
                               finished, record_json, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(account_uuid, direction, swap_index) DO UPDATE SET
               deployment = excluded.deployment, swap_id = excluded.swap_id,
               phase = excluded.phase, finished = excluded.finished,
               record_json = excluded.record_json, updated_at = excluded.updated_at",
            params![
                account,
                direction,
                index,
                deployment,
                record.swap_id().to_hex(),
                record.phase(),
                record.finished(),
                json,
                now() as i64,
            ],
        )
        .map_err(sql)?;
        if activate {
            tx.execute(
                "INSERT INTO active(account_uuid, direction, swap_index) VALUES (?1, ?2, ?3)
                 ON CONFLICT(account_uuid, direction) DO UPDATE SET swap_index = excluded.swap_index",
                params![account, direction, index],
            )
            .map_err(sql)?;
        }
        // A draft that is no longer active is never history.
        tx.execute(
            "DELETE FROM swaps
             WHERE account_uuid = ?1 AND direction = 'reverse' AND phase = 'QUOTED'
               AND swap_index NOT IN (SELECT swap_index FROM active
                                      WHERE account_uuid = ?1 AND direction = 'reverse')",
            [account],
        )
        .map_err(sql)?;
        // Finished records beyond the newest MAX_HISTORY go, never the active
        // one, an unfinished one or a refunded reverse swap.
        tx.execute(
            "DELETE FROM swaps
             WHERE account_uuid = ?1 AND direction = ?2 AND finished = 1
               AND NOT (direction = 'reverse' AND phase = 'REFUNDED')
               AND swap_index NOT IN (SELECT swap_index FROM active
                                      WHERE account_uuid = ?1 AND direction = ?2)
               AND swap_index NOT IN (
                 SELECT swap_index FROM swaps
                 WHERE account_uuid = ?1 AND direction = ?2 AND finished = 1
                   AND NOT (direction = 'reverse' AND phase = 'REFUNDED')
                 ORDER BY swap_index DESC LIMIT ?3)",
            params![account, direction, MAX_HISTORY],
        )
        .map_err(sql)?;
        #[cfg(test)]
        if CRASH_BEFORE_COMMIT.with(|crash| crash.replace(false)) {
            return fail(ErrorCode::StoreUnreadable, "crashed before commit");
        }
        tx.commit().map_err(sql)?;
        Ok(true)
    }

    /// The direction's active record: under way, a reverse draft, or the
    /// last one finished.
    pub(crate) fn active(
        &self,
        account: &str,
        direction: Direction,
    ) -> Result<Option<StoredRecord>> {
        let row: Option<(i64, Option<String>)> = self
            .conn
            .query_row(
                "SELECT a.swap_index, s.record_json FROM active a
                 LEFT JOIN swaps s ON s.account_uuid = a.account_uuid
                   AND s.direction = a.direction AND s.swap_index = a.swap_index
                 WHERE a.account_uuid = ?1 AND a.direction = ?2",
                params![account, direction.as_str()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(sql)?;
        match row {
            None => Ok(None),
            Some((index, Some(json))) => decode(direction, index, &json).map(Some),
            Some((_, None)) => Err(unreadable("the active record is missing")),
        }
    }

    /// The direction's kept records, newest first; reverse drafts are not
    /// history.
    pub(crate) fn history(&self, account: &str, direction: Direction) -> Result<Vec<StoredRecord>> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT swap_index, record_json FROM swaps
                 WHERE account_uuid = ?1 AND direction = ?2 AND phase <> 'QUOTED'
                 ORDER BY swap_index DESC",
            )
            .map_err(sql)?;
        let rows = statement
            .query_map(params![account, direction.as_str()], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(sql)?;
        rows.map(|row| {
            let (index, json) = row.map_err(sql)?;
            decode(direction, index, &json)
        })
        .collect()
    }

    /// The kept record of swap `index`.
    pub(crate) fn find(
        &self,
        account: &str,
        direction: Direction,
        index: u32,
    ) -> Result<Option<StoredRecord>> {
        let json: Option<String> = self
            .conn
            .query_row(
                "SELECT record_json FROM swaps
                 WHERE account_uuid = ?1 AND direction = ?2 AND swap_index = ?3",
                params![account, direction.as_str(), index],
                |row| row.get(0),
            )
            .optional()
            .map_err(sql)?;
        json.map(|json| decode(direction, i64::from(index), &json))
            .transpose()
    }

    /// When swap `index`'s record last changed, in unix seconds on this
    /// device's clock.
    pub(crate) fn updated_at(
        &self,
        account: &str,
        direction: Direction,
        index: u32,
    ) -> Result<Option<u64>> {
        let updated: Option<i64> = self
            .conn
            .query_row(
                "SELECT updated_at FROM swaps
                 WHERE account_uuid = ?1 AND direction = ?2 AND swap_index = ?3",
                params![account, direction.as_str(), index],
                |row| row.get(0),
            )
            .optional()
            .map_err(sql)?;
        Ok(updated.map(|seconds| u64::try_from(seconds).unwrap_or_default()))
    }

    /// Conversions under way: forward unfinished, reverse unfinished and past
    /// its quote (a draft is not under way).
    pub(crate) fn unfinished_count(&self, account: &str) -> Result<u32> {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM swaps WHERE account_uuid = ?1 AND finished = 0
                   AND NOT (direction = 'reverse' AND phase = 'QUOTED')",
                [account],
                |row| row.get(0),
            )
            .map_err(sql)
    }

    /// Every account with a conversion under way.
    pub(crate) fn accounts_with_unfinished(&self) -> Result<Vec<String>> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT DISTINCT account_uuid FROM swaps WHERE finished = 0
                   AND NOT (direction = 'reverse' AND phase = 'QUOTED')
                 ORDER BY account_uuid",
            )
            .map_err(sql)?;
        let rows = statement.query_map([], |row| row.get(0)).map_err(sql)?;
        rows.map(|row| row.map_err(sql)).collect()
    }

    /// Removes every row of `account`, the counter included, in one
    /// transaction.
    pub(crate) fn delete_account(&mut self, account: &str) -> Result<()> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql)?;
        for table in [
            "swap_counter",
            "swaps",
            "active",
            "joint_accounts",
            "railgun_sends",
        ] {
            tx.execute(
                &format!("DELETE FROM {table} WHERE account_uuid = ?1"),
                [account],
            )
            .map_err(sql)?;
        }
        tx.commit().map_err(sql)
    }

    pub(crate) fn put_joint_account(&mut self, row: &JointAccountRow) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO joint_accounts(account_uuid, direction, swap_index, joint_uuid, ufvk,
                                            birthday)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(account_uuid, direction, swap_index) DO UPDATE SET
                   joint_uuid = excluded.joint_uuid, ufvk = excluded.ufvk,
                   birthday = excluded.birthday",
                params![
                    row.account_uuid,
                    row.direction.as_str(),
                    row.swap_index,
                    row.joint_uuid,
                    row.ufvk,
                    row.birthday as i64,
                ],
            )
            .map_err(sql)?;
        Ok(())
    }

    /// Every live joint account, of every account: one `joint.db` per wallet.
    pub(crate) fn joint_accounts(&self) -> Result<Vec<JointAccountRow>> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT account_uuid, direction, swap_index, joint_uuid, ufvk, birthday
                 FROM joint_accounts ORDER BY account_uuid, direction, swap_index",
            )
            .map_err(sql)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, u32>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            })
            .map_err(sql)?;
        rows.map(|row| {
            let (account_uuid, direction, swap_index, joint_uuid, ufvk, birthday) =
                row.map_err(sql)?;
            Ok(JointAccountRow {
                account_uuid,
                direction: Direction::parse(&direction)
                    .ok_or_else(|| unreadable("unknown joint account direction"))?,
                swap_index,
                joint_uuid,
                ufvk,
                birthday: u64::try_from(birthday)
                    .map_err(|_| unreadable("negative joint account birthday"))?,
            })
        })
        .collect()
    }

    pub(crate) fn remove_joint_account(
        &mut self,
        account: &str,
        direction: Direction,
        index: u32,
    ) -> Result<()> {
        self.conn
            .execute(
                "DELETE FROM joint_accounts
                 WHERE account_uuid = ?1 AND direction = ?2 AND swap_index = ?3",
                params![account, direction.as_str(), index],
            )
            .map_err(sql)?;
        Ok(())
    }

    /// Keeps or replaces a proved send, then trims confirmed sends beyond the
    /// newest `MAX_CONFIRMED_SENDS`.
    pub(crate) fn put_send(&mut self, account: &str, send: &SendRow) -> Result<()> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sql)?;
        tx.execute(
            "INSERT INTO railgun_sends(account_uuid, send_id, created_at, state, record_json)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(account_uuid, send_id) DO UPDATE SET
               created_at = excluded.created_at, state = excluded.state,
               record_json = excluded.record_json",
            params![
                account,
                send.send_id,
                send.created_at as i64,
                send.state.as_str(),
                send.record_json,
            ],
        )
        .map_err(sql)?;
        tx.execute(
            "DELETE FROM railgun_sends
             WHERE account_uuid = ?1 AND state = 'confirmed' AND send_id NOT IN (
               SELECT send_id FROM railgun_sends WHERE account_uuid = ?1 AND state = 'confirmed'
               ORDER BY created_at DESC, send_id DESC LIMIT ?2)",
            params![account, MAX_CONFIRMED_SENDS],
        )
        .map_err(sql)?;
        tx.commit().map_err(sql)
    }

    /// The account's kept sends, newest first.
    pub(crate) fn sends(&self, account: &str) -> Result<Vec<SendRow>> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT send_id, created_at, state, record_json FROM railgun_sends
                 WHERE account_uuid = ?1 ORDER BY created_at DESC, send_id DESC",
            )
            .map_err(sql)?;
        let rows = statement
            .query_map([account], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .map_err(sql)?;
        rows.map(|row| {
            let (send_id, created_at, state, record_json) = row.map_err(sql)?;
            Ok(SendRow {
                send_id,
                created_at: u64::try_from(created_at)
                    .map_err(|_| unreadable("negative send time"))?,
                state: match state.as_str() {
                    "unconfirmed" => SendState::Unconfirmed,
                    "confirmed" => SendState::Confirmed,
                    _ => return Err(unreadable("unknown send state")),
                },
                record_json,
            })
        })
        .collect()
    }

    pub(crate) fn remove_send(&mut self, account: &str, send_id: &str) -> Result<()> {
        self.conn
            .execute(
                "DELETE FROM railgun_sends WHERE account_uuid = ?1 AND send_id = ?2",
                params![account, send_id],
            )
            .map_err(sql)?;
        Ok(())
    }
}

/// A kept record, strictly: unreadable, or not the row's own swap, is an
/// error.
fn decode(direction: Direction, index: i64, json: &str) -> Result<StoredRecord> {
    let record = StoredRecord::decode(direction, json).map_err(unreadable)?;
    if i64::from(record.index()) != index {
        return Err(unreadable("a record is filed under another index"));
    }
    Ok(record)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wallet::private_usd::models::ForwardRecord;

    const ACCOUNT: &str = "550e8400-e29b-41d4-a716-446655440000";

    fn hex(bytes: usize, value: u8) -> String {
        format!("0x{}", format!("{value:02x}").repeat(bytes))
    }

    const MAKER: &str = "0x2bac02b5032e9092493814c705f156b49e288922";
    const CONTRACT: &str = "0xbd9a37f47a988aefc4d80395727f41feb698e225";
    const TOKEN: &str = "0x5764d0044bef5aa839e0ddafe2073421101b9ed8";
    const TESTNET: &str = r#"{"makerUrl":"https://zecswap-testnet.pepeman931.workers.dev/maker","relayerUrl":"https://zecswap-testnet.pepeman931.workers.dev/relayer","rpcUrl":"https://ethereum-sepolia-rpc.publicnode.com","chainId":11155111,"contract":"0xbd9a37f47a988aefc4d80395727f41feb698e225","token":"0x5764d0044bef5aa839e0ddafe2073421101b9ed8","railgun":"0xecfcf3b4ec647c4ca6d49108b311b7a7c9543fea","maker":"0x2bac02b5032e9092493814c705f156b49e288922","relayer":"0xd9633572041886fa7584a2e12f36c8c7f1126412"}"#;
    const MAINNET: &str = r#"{"makerUrl":"https://zecswap-mainnet.pepeman931.workers.dev/maker","relayerUrl":"https://zecswap-mainnet.pepeman931.workers.dev/relayer","rpcUrl":"https://ethereum-rpc.publicnode.com","chainId":1,"contract":"0x4708d7d36992b7e33ad97a1ab0a31c3ac6c4fe6d","token":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48","railgun":"0xfa7093cdd9ee6932b4eb2c9e1cde7ce00b1fa4b9","maker":"0x4370eeaa6becf1daef21deeb0379eb7f6caef7ef","relayer":"0xcbcb5f57c79c88a0e4bb450289de2088958a017f","zcashNetwork":"mainnet","zcashConfirmations":2,"tokenIssuer":{"url":"https://zecswap-mainnet.pepeman931.workers.dev/issuer","name":"zecswap-mainnet-issuer","tokenKey":"token","returnKey":"return"}}"#;

    fn ticket() -> String {
        format!("{}.{}", hex(32, 0x5c), "3f".repeat(32))
    }

    /// zapp's `SwapRecordStorageTest` forward fixtures: accepted, depositing,
    /// deposited, paid, refunded, ended unsent, and with a ticket.
    fn forward_states() -> Vec<String> {
        let head = format!(
            r#"{{"index":7,"quote":{{"quoteId":"{}","maker":"{MAKER}","makerShare":"{}","makerProof":"{}","chainId":11155111,"contract":"{CONTRACT}","token":"{TOKEN}","amount":"1000000","depositZat":202021,"expiresAt":1790000300}},"swapId":"{}","zcashHeight":4200000,"acceptedAt":1790000000,"receives":"977550","relayerFee":"20000""#,
            hex(32, 0x22),
            hex(64, 0x0a),
            hex(64, 0x06),
            hex(32, 0x5c),
        );
        let deposit = format!(
            r#""deposit":{{"txId":"{}","raw":"0400","expiryHeight":4200040}}"#,
            "ab".repeat(32)
        );
        let sweep = "cd".repeat(32);
        vec![
            format!("{head}}}"),
            format!(r#"{head},"depositAttempted":true,"maxTotalZat":212021}}"#),
            format!(r#"{head},"depositAttempted":true,"maxTotalZat":212021,{deposit}}}"#),
            format!(
                r#"{head},"depositAttempted":true,"outcome":{{"type":"paid"}},"finishedAt":1790003000,"payoutTx":"{}","maxTotalZat":212021,{deposit}}}"#,
                hex(32, 0xa1)
            ),
            format!(
                r#"{head},"depositAttempted":true,"outcome":{{"type":"refunded","sweepTxId":"{sweep}","cause":"NOT_CLAIMED_IN_TIME"}},"finishedAt":1790009000,"maxTotalZat":212021,{deposit},"sweep":{{"txId":"{sweep}","raw":"0500","expiryHeight":4200140}}}}"#
            ),
            format!(
                r#"{head},"outcome":{{"type":"nothing_sent","cause":"QUOTE_EXPIRED"}},"finishedAt":1790000001}}"#
            ),
            format!(
                r#"{head},"t0":1790002100,"t1":1790002400,"ticket":"{}"}}"#,
                ticket()
            ),
        ]
    }

    /// zapp's reverse fixtures: previewed, accepted, sending (with a ticket),
    /// settling, refunded by a mainnet build, and refunded.
    fn reverse_states() -> Vec<String> {
        let swap_id = hex(32, 0x5c);
        let head = format!(
            r#"{{"index":4,"deployment":{TESTNET},"quote":{{"terms":{{"quoteId":"{}","maker":"{MAKER}","makerShare":"{}","makerProof":"{}","chainId":11155111,"contract":"{CONTRACT}","token":"{TOKEN}","amount":"1000000","depositZat":100000,"expiresAt":1790000300}},"user":"0x4444444444444444444444444444444444444444","refundNote":"{}","fundingDeadline":1790000400,"readyDeadline":1790002000,"refundAfter":1790004000}},"swapId":"{swap_id}","userShare":"{}","acceptance":{{"userShare":"{}","userProof":"{}","viewingKeys":"{}"}},"birthday":3900000"#,
            hex(32, 1),
            hex(64, 2),
            hex(64, 7),
            hex(32, 6),
            hex(64, 1),
            hex(64, 1),
            hex(64, 3),
            hex(64, 4),
        );
        let cost = r#"{"debit":"1252506","railgunFee":"2506","broadcasterFee":"250000"}"#;
        let request = format!(
            r#"{{"swapId":"{swap_id}","chainId":11155111,"to":"{}","data":"0x12345678","value":"0"}}"#,
            hex(20, 7)
        );
        let funding = format!(
            r#"{{"txId":"{}","cost":{cost},"request":{request}}}"#,
            hex(32, 8)
        );
        let authorization = format!(
            r#"{{"swapId":"{swap_id}","deadline":1790001000,"signature":"{}"}}"#,
            hex(65, 9)
        );
        let payout = format!(
            r#"{{"swapId":"{swap_id}","note":{{"npk":"{}","encryptedBundle":["{}","{}","{}"],"shieldKey":"{}"}},"fee":"20000","signature":"{}"}}"#,
            hex(32, 0x11),
            hex(32, 0x12),
            hex(32, 0x13),
            hex(32, 0x14),
            hex(32, 0x15),
            hex(65, 0x16),
        );
        let account = "0a0b".repeat(8);
        let refunded = format!(
            r#"{head},"account":"{account}","phase":"REFUNDED","cost":{cost},"funding":{funding},"cancelRequested":true,"refundLock":{authorization},"payout":{payout},"acceptedAt":1790000100}}"#
        );
        let refunded_on_mainnet = refunded
            .replace(TESTNET, MAINNET)
            .replace(r#""chainId":11155111"#, r#""chainId":1"#)
            .replace(CONTRACT, "0x4708d7d36992b7e33ad97a1ab0a31c3ac6c4fe6d")
            .replace(TOKEN, "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
            .replace(MAKER, "0x4370eeaa6becf1daef21deeb0379eb7f6caef7ef");
        vec![
            format!(r#"{head},"phase":"QUOTED","cost":{cost}}}"#),
            format!(r#"{head},"cost":{cost},"acceptedAt":1790000100}}"#),
            format!(
                r#"{head},"account":"{account}","phase":"SENDING_USDC","cost":{cost},"funding":{{"cost":{cost},"request":{request}}},"acceptedAt":1790000100,"makerAccepted":true,"ticket":"{}"}}"#,
                ticket()
            ),
            format!(
                r#"{head},"account":"{account}","phase":"SETTLING","cost":{cost},"funding":{funding},"ready":{authorization},"receiveEstimate":{{"availableZat":100000,"feeZat":10000}},"acceptedAt":1790000100}}"#
            ),
            refunded_on_mainnet,
            refunded,
        ]
    }

    fn forward_json() -> String {
        forward_states().remove(0)
    }

    fn forward(json: &str) -> ForwardRecord {
        match StoredRecord::decode(Direction::Forward, json).unwrap() {
            StoredRecord::Forward(record) => record,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn reading_an_existing_send_log_does_not_wait_for_a_writer() {
        let dir = tempfile::tempdir().unwrap();
        let mut writer = SwapStore::open(dir.path()).unwrap();
        let transaction = writer
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .unwrap();
        // This lock stays held throughout the read. An unnecessary write
        // transaction on open would time out instead of reading the log.
        let reader = SwapStore::open_existing(dir.path()).unwrap().unwrap();
        assert!(reader.sends(ACCOUNT).unwrap().is_empty());
        transaction.rollback().unwrap();
    }

    #[test]
    fn a_crash_between_saves_leaves_the_last_whole_record() {
        let dir = tempfile::tempdir().unwrap();
        let accepted = forward(&forward_json());
        let mut depositing = accepted.clone();
        depositing.deposit_attempted = true;

        let mut store = SwapStore::open(dir.path()).unwrap();
        assert!(store
            .save(ACCOUNT, &StoredRecord::Forward(accepted.clone()))
            .unwrap());
        assert!(!store
            .save(ACCOUNT, &StoredRecord::Forward(accepted.clone()))
            .unwrap());
        CRASH_BEFORE_COMMIT.with(|crash| crash.set(true));
        assert!(store
            .save(ACCOUNT, &StoredRecord::Forward(depositing))
            .is_err());
        drop(store);

        let store = SwapStore::open(dir.path()).unwrap();
        assert_eq!(
            store.active(ACCOUNT, Direction::Forward).unwrap(),
            Some(StoredRecord::Forward(accepted.clone()))
        );
        assert_eq!(
            store.history(ACCOUNT, Direction::Forward).unwrap(),
            vec![StoredRecord::Forward(accepted)]
        );
        assert_eq!(store.unfinished_count(ACCOUNT).unwrap(), 1);
    }

    /// Records read only as this build writes them, and every zapp shape
    /// reads and writes back unchanged; anything else is an error, never a
    /// reset.
    #[test]
    fn records_decode_strictly() {
        let forward_cases = forward_states()
            .into_iter()
            .map(|json| (Direction::Forward, json));
        let reverse_cases = reverse_states()
            .into_iter()
            .map(|json| (Direction::Reverse, json));
        for (direction, json) in forward_cases.chain(reverse_cases) {
            let record = StoredRecord::decode(direction, &json)
                .unwrap_or_else(|error| panic!("{error}: {json}"));
            assert_eq!(record.to_json().unwrap(), json);
            let extra = json.replacen('{', r#"{"unknownField":1,"#, 1);
            assert!(StoredRecord::decode(direction, &extra).is_err());
            assert!(StoredRecord::decode(direction, &json[..json.len() - 1]).is_err());
        }
        let refunded = reverse_states().pop().unwrap();
        for malformed in [
            refunded.replace(&hex(64, 3), "0x01"),
            refunded.replace(&"0a0b".repeat(8), "0a0b"),
            refunded.replace(r#""phase":"REFUNDED""#, r#""phase":"LOST""#),
        ] {
            assert!(StoredRecord::decode(Direction::Reverse, &malformed).is_err());
        }
        let deposited = forward_states().remove(2);
        for malformed in [
            deposited.replace(&"ab".repeat(32), &"ab".repeat(31)),
            deposited.replace(r#""1000000""#, r#""1.5""#),
            deposited.replace(MAKER, &MAKER.to_uppercase().replacen("0X", "0x", 1)),
        ] {
            assert!(StoredRecord::decode(Direction::Forward, &malformed).is_err());
        }

        let dir = tempfile::tempdir().unwrap();
        let mut store = SwapStore::open(dir.path()).unwrap();
        store
            .save(ACCOUNT, &StoredRecord::Forward(forward(&forward_json())))
            .unwrap();
        let next = store.take_index(ACCOUNT).unwrap();
        store
            .conn
            .execute("UPDATE swaps SET record_json = '{\"index\":7}'", [])
            .unwrap();
        let error = store.active(ACCOUNT, Direction::Forward).unwrap_err();
        assert_eq!(error.code, ErrorCode::StoreUnreadable);
        assert!(store.history(ACCOUNT, Direction::Forward).is_err());
        // The unreadable record is kept, and the counter goes on.
        assert_eq!(store.take_index(ACCOUNT).unwrap(), next + 1);
    }

    #[test]
    fn the_counter_never_goes_backwards() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = SwapStore::open(dir.path()).unwrap();
        assert_eq!(store.take_index(ACCOUNT).unwrap(), 0);
        assert_eq!(store.take_index(ACCOUNT).unwrap(), 1);
        assert_eq!(store.take_index("another-account").unwrap(), 0);
        drop(store);

        let mut store = SwapStore::open(dir.path()).unwrap();
        assert_eq!(store.take_index(ACCOUNT).unwrap(), 2);
        // A record kept under a higher index than the counter moves it past.
        store
            .save(ACCOUNT, &StoredRecord::Forward(forward(&forward_json())))
            .unwrap();
        assert_eq!(store.take_index(ACCOUNT).unwrap(), 8);
        drop(store);

        // A store from a newer version is refused, never reset.
        let conn = Connection::open(dir.path().join(FILE_NAME)).unwrap();
        conn.pragma_update(None, "user_version", SCHEMA_VERSION + 1)
            .unwrap();
        drop(conn);
        assert_eq!(
            SwapStore::open(dir.path()).err().map(|error| error.code),
            Some(ErrorCode::StoreUnreadable)
        );
    }
}
