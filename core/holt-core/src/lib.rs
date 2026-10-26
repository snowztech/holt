use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;

mod net;
pub use net::{Device, Node};

uniffi::setup_scaffolding!();

/// Clips bigger than this are skipped. Nobody pastes a 2 MB blob from history,
/// and it keeps the database small.
const MAX_CLIP_BYTES: usize = 1 << 20;

/// A clip that arrives from another device goes on this Mac's clipboard only if
/// it was copied this recently, the same window Apple uses for Universal Clipboard.
const LIVE_COPY_WINDOW_MS: i64 = 120_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ClipKind {
    Text,
    Link,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Clip {
    pub id: i64,
    pub kind: ClipKind,
    pub text: String,
    pub source_app: Option<String>,
    /// Unix time in milliseconds of the last copy.
    pub created_at: i64,
    pub pinned: bool,
}

#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum HoltError {
    Db(String),
    Net(String),
    /// Pairing failed for a reason the user can act on. The message is shown as is.
    Pairing(String),
}

impl std::fmt::Display for HoltError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HoltError::Db(msg) => write!(f, "database error: {msg}"),
            HoltError::Net(msg) => write!(f, "network error: {msg}"),
            HoltError::Pairing(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for HoltError {}

impl From<rusqlite::Error> for HoltError {
    fn from(e: rusqlite::Error) -> Self {
        HoltError::Db(e.to_string())
    }
}

type Result<T> = std::result::Result<T, HoltError>;

/// One clip as it travels between devices. Every local change gives the clip a
/// new `seq` from this device's counter and sets `origin` to this device, so a
/// peer can ask for "everything from origin X after seq N".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct Row {
    /// BLAKE3 of the text, hex. The same text copied on two devices is one clip.
    pub key: String,
    /// None once the clip is deleted. Tombstones keep the key so deletes sync.
    pub text: Option<String>,
    pub kind: i64,
    pub source_app: Option<String>,
    pub created_at: i64,
    /// Time of the last change of any kind. On conflict the newest wins.
    pub updated_at: i64,
    pub pinned: bool,
    pub deleted: bool,
    pub origin: String,
    pub seq: i64,
}

#[derive(uniffi::Object)]
pub struct Store {
    conn: Mutex<Connection>,
    secret_key: [u8; 32],
    device_id: String,
    changes: watch::Sender<u64>,
    incoming_copy: Mutex<Option<String>>,
}

#[uniffi::export]
impl Store {
    /// Opens (or creates) the history database. Pass ":memory:" for tests.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>> {
        let mut conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA journal_mode = WAL;")?;
        let secret_key = migrate(&mut conn)?;
        let device_id = iroh::SecretKey::from_bytes(&secret_key).public().to_string();
        Ok(Arc::new(Store {
            conn: Mutex::new(conn),
            secret_key,
            device_id,
            changes: watch::channel(0).0,
            incoming_copy: Mutex::new(None),
        }))
    }

    /// This device's public key, which other devices know it by.
    pub fn device_id(&self) -> String {
        self.device_id.clone()
    }

    /// Records a copy. Copying something already in history moves it to the top
    /// instead of adding a duplicate. Returns None for empty or oversized text.
    pub fn add(&self, text: String, source_app: Option<String>) -> Result<Option<Clip>> {
        if text.trim().is_empty() || text.len() > MAX_CLIP_BYTES {
            return Ok(None);
        }
        let clip = self.write(|tx, now, seq| {
            Ok(tx.query_row(
                "INSERT INTO clips (key, text, kind, source_app, created_at, updated_at, origin, seq)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7)
                 ON CONFLICT(key) DO UPDATE SET
                     text = excluded.text,
                     source_app = excluded.source_app,
                     created_at = excluded.created_at,
                     updated_at = max(excluded.updated_at, clips.updated_at + 1),
                     deleted = 0,
                     origin = excluded.origin,
                     seq = excluded.seq
                 RETURNING id, kind, text, source_app, created_at, pinned",
                params![key_of(&text), text, kind_of(&text) as i64, source_app, now, self.device_id, seq],
                clip_from_row,
            )?)
        })?;
        Ok(Some(clip))
    }

    /// Pinned clips first, then newest first. Every whitespace-separated word in
    /// the query must appear somewhere in the clip, case-insensitively. An empty
    /// query lists recent clips.
    pub fn search(&self, query: String, limit: u32) -> Result<Vec<Clip>> {
        // A LIKE scan is fine for a few thousand rows. Switch to an FTS5 trigram
        // index if history limits go up and search starts to lag.
        let words: Vec<String> = query
            .split_whitespace()
            .map(|w| format!("%{}%", escape_like(w)))
            .collect();
        let mut sql = String::from(
            "SELECT id, kind, text, source_app, created_at, pinned FROM clips WHERE deleted = 0",
        );
        for _ in &words {
            sql.push_str(" AND text LIKE ? ESCAPE '\\'");
        }
        sql.push_str(&format!(" ORDER BY pinned DESC, created_at DESC LIMIT {limit}"));

        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(words.iter()), clip_from_row)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn set_pinned(&self, id: i64, pinned: bool) -> Result<()> {
        self.write(|tx, now, seq| {
            tx.execute(
                "UPDATE clips SET pinned = ?1, updated_at = max(?2, updated_at + 1), origin = ?3, seq = ?4
                 WHERE id = ?5 AND deleted = 0",
                params![pinned, now, self.device_id, seq, id],
            )?;
            Ok(())
        })
    }

    /// Deletes the clip here and on every paired device.
    pub fn delete(&self, id: i64) -> Result<()> {
        self.write(|tx, now, seq| tombstone(tx, id, now, seq, &self.device_id))
    }

    /// Deletes every unpinned clip, here and on every paired device.
    pub fn clear(&self) -> Result<()> {
        let ids: Vec<i64> = {
            let conn = self.conn.lock().unwrap();
            let mut stmt = conn.prepare("SELECT id FROM clips WHERE pinned = 0 AND deleted = 0")?;
            let ids = stmt.query_map([], |r| r.get(0))?.collect::<std::result::Result<_, _>>()?;
            ids
        };
        for id in ids {
            self.write(|tx, now, seq| tombstone(tx, id, now, seq, &self.device_id))?;
        }
        Ok(())
    }

    /// Drops unpinned clips older than `max_age_days`, then keeps only the newest
    /// `max_unpinned` of the rest. Pinned clips are never pruned. This only
    /// affects this device: each device prunes its own history. Returns how many
    /// clips were removed.
    pub fn prune(&self, max_age_days: u32, max_unpinned: u32) -> Result<u32> {
        let cutoff = now_ms() - i64::from(max_age_days) * 86_400_000;
        let conn = self.conn.lock().unwrap();
        let old = conn.execute(
            "DELETE FROM clips WHERE pinned = 0 AND created_at < ?1",
            params![cutoff],
        )?;
        let extra = conn.execute(
            "DELETE FROM clips WHERE pinned = 0 AND deleted = 0 AND id NOT IN (
                 SELECT id FROM clips WHERE pinned = 0 AND deleted = 0 ORDER BY created_at DESC LIMIT ?1
             )",
            params![max_unpinned],
        )?;
        Ok((old + extra) as u32)
    }

    /// The newest clip that just arrived from another device, if there is one
    /// the app hasn't taken yet. The app puts it on the clipboard.
    pub fn take_incoming_copy(&self) -> Option<String> {
        self.incoming_copy.lock().unwrap().take()
    }
}

/// Sync and pairing support, used by `net`.
impl Store {
    pub(crate) fn secret_key(&self) -> [u8; 32] {
        self.secret_key
    }

    pub(crate) fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    /// Highest seq received from each other device.
    pub(crate) fn cursors(&self) -> Result<HashMap<String, i64>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT origin, seq FROM cursors")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub(crate) fn origins(&self) -> Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT DISTINCT origin FROM clips")?;
        let rows = stmt.query_map([], |r| r.get(0))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub(crate) fn rows_since(&self, origin: &str, after: i64, limit: u32) -> Result<Vec<Row>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT key, text, kind, source_app, created_at, updated_at, pinned, deleted, origin, seq
             FROM clips WHERE origin = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![origin, after, limit], |r| {
            Ok(Row {
                key: r.get(0)?,
                text: r.get(1)?,
                kind: r.get(2)?,
                source_app: r.get(3)?,
                created_at: r.get(4)?,
                updated_at: r.get(5)?,
                pinned: r.get(6)?,
                deleted: r.get(7)?,
                origin: r.get(8)?,
                seq: r.get(9)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Merges rows from a peer. For each clip the version with the newest
    /// `updated_at` wins, with the origin id breaking ties so every device
    /// picks the same one.
    pub(crate) fn apply(&self, rows: Vec<Row>) -> Result<()> {
        let now = now_ms();
        let mut changed = false;
        let mut live_copy: Option<(i64, String)> = None;
        {
            let mut conn = self.conn.lock().unwrap();
            let tx = conn.transaction()?;
            let newest_before: i64 = tx.query_row(
                "SELECT coalesce(max(created_at), 0) FROM clips WHERE deleted = 0",
                [],
                |r| r.get(0),
            )?;
            for row in rows {
                if row.origin == self.device_id {
                    continue;
                }
                tx.execute(
                    "INSERT INTO cursors (origin, seq) VALUES (?1, ?2)
                     ON CONFLICT(origin) DO UPDATE SET seq = max(seq, excluded.seq)",
                    params![row.origin, row.seq],
                )?;
                // A live clip's key must match its text, or dedupe breaks.
                if !row.deleted && row.text.as_deref().map(key_of).as_deref() != Some(row.key.as_str()) {
                    continue;
                }
                let current: Option<(i64, String)> = tx
                    .query_row(
                        "SELECT updated_at, origin FROM clips WHERE key = ?1",
                        params![row.key],
                        |r| Ok((r.get(0)?, r.get(1)?)),
                    )
                    .optional()?;
                if let Some((updated_at, origin)) = current {
                    if (updated_at, origin.as_str()) >= (row.updated_at, row.origin.as_str()) {
                        continue;
                    }
                }
                tx.execute(
                    "INSERT INTO clips (key, text, kind, source_app, created_at, updated_at, pinned, deleted, origin, seq)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                     ON CONFLICT(key) DO UPDATE SET
                         text = excluded.text, kind = excluded.kind, source_app = excluded.source_app,
                         created_at = excluded.created_at, updated_at = excluded.updated_at,
                         pinned = excluded.pinned, deleted = excluded.deleted,
                         origin = excluded.origin, seq = excluded.seq",
                    params![
                        row.key, row.text, row.kind, row.source_app, row.created_at,
                        row.updated_at, row.pinned, row.deleted, row.origin, row.seq
                    ],
                )?;
                changed = true;
                let is_new_copy = !row.deleted
                    && row.created_at > newest_before
                    && row.created_at > now - LIVE_COPY_WINDOW_MS
                    && live_copy.as_ref().is_none_or(|(at, _)| row.created_at > *at);
                if is_new_copy {
                    live_copy = Some((row.created_at, row.text.clone().unwrap_or_default()));
                }
            }
            tx.commit()?;
        }
        if let Some((_, text)) = live_copy {
            *self.incoming_copy.lock().unwrap() = Some(text);
        }
        if changed {
            self.changes.send_modify(|v| *v += 1);
        }
        Ok(())
    }

    pub(crate) fn add_peer(&self, id: &str, name: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO peers (id, name) VALUES (?1, ?2) ON CONFLICT(id) DO UPDATE SET name = excluded.name",
            params![id, name],
        )?;
        Ok(())
    }

    pub(crate) fn remove_peer(&self, id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM peers WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub(crate) fn peers(&self) -> Result<Vec<(String, String)>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT id, name FROM peers ORDER BY name")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub(crate) fn is_peer(&self, id: &str) -> Result<bool> {
        let conn = self.conn.lock().unwrap();
        Ok(conn
            .query_row("SELECT 1 FROM peers WHERE id = ?1", params![id], |_| Ok(()))
            .optional()?
            .is_some())
    }

    /// Runs a local change in a transaction with a fresh timestamp and seq,
    /// then wakes the sync sessions.
    fn write<T>(&self, f: impl FnOnce(&Transaction, i64, i64) -> Result<T>) -> Result<T> {
        let result = {
            let mut conn = self.conn.lock().unwrap();
            let tx = conn.transaction()?;
            let seq: i64 = tx.query_row(
                "UPDATE meta SET value = value + 1 WHERE key = 'seq' RETURNING value",
                [],
                |r| r.get(0),
            )?;
            let result = f(&tx, now_ms(), seq)?;
            tx.commit()?;
            result
        };
        self.changes.send_modify(|v| *v += 1);
        Ok(result)
    }
}

fn tombstone(tx: &Transaction, id: i64, now: i64, seq: i64, origin: &str) -> Result<()> {
    tx.execute(
        "UPDATE clips SET text = NULL, source_app = NULL, pinned = 0, deleted = 1,
             updated_at = max(?1, updated_at + 1), origin = ?2, seq = ?3
         WHERE id = ?4 AND deleted = 0",
        params![now, origin, seq, id],
    )?;
    Ok(())
}

/// Creates or upgrades the schema and returns this device's secret key.
fn migrate(conn: &mut Connection) -> Result<[u8; 32]> {
    let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    let tx = conn.transaction()?;
    if version < 1 {
        let had_v0: bool = tx
            .query_row("SELECT 1 FROM sqlite_master WHERE name = 'clips'", [], |_| Ok(()))
            .optional()?
            .is_some();
        if had_v0 {
            // The old index moves with the renamed table and would clash with the new one.
            tx.execute_batch("ALTER TABLE clips RENAME TO clips_v0; DROP INDEX IF EXISTS clips_created;")?;
        }
        tx.execute_batch(
            "CREATE TABLE clips (
                 id         INTEGER PRIMARY KEY,
                 key        TEXT    NOT NULL UNIQUE,
                 text       TEXT,
                 kind       INTEGER NOT NULL,
                 source_app TEXT,
                 created_at INTEGER NOT NULL,
                 updated_at INTEGER NOT NULL,
                 pinned     INTEGER NOT NULL DEFAULT 0,
                 deleted    INTEGER NOT NULL DEFAULT 0,
                 origin     TEXT    NOT NULL,
                 seq        INTEGER NOT NULL
             );
             CREATE INDEX clips_created ON clips(created_at);
             CREATE INDEX clips_origin ON clips(origin, seq);
             CREATE TABLE cursors (origin TEXT PRIMARY KEY, seq INTEGER NOT NULL);
             CREATE TABLE peers (id TEXT PRIMARY KEY, name TEXT NOT NULL);
             CREATE TABLE meta (key TEXT PRIMARY KEY, value NOT NULL);
             INSERT INTO meta (key, value) VALUES ('seq', 0);",
        )?;
        let secret = iroh::SecretKey::generate().to_bytes();
        tx.execute(
            "INSERT INTO meta (key, value) VALUES ('secret_key', ?1)",
            params![to_hex(&secret)],
        )?;
        if had_v0 {
            let origin = iroh::SecretKey::from_bytes(&secret).public().to_string();
            let old: Vec<(String, i64, Option<String>, i64, bool)> = {
                let mut stmt = tx.prepare(
                    "SELECT text, kind, source_app, created_at, pinned FROM clips_v0 ORDER BY created_at",
                )?;
                let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?;
                rows.collect::<std::result::Result<_, _>>()?
            };
            for (seq, (text, kind, source_app, created_at, pinned)) in (1i64..).zip(old) {
                tx.execute(
                    "INSERT INTO clips (key, text, kind, source_app, created_at, updated_at, pinned, origin, seq)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, ?8)",
                    params![key_of(&text), text, kind, source_app, created_at, pinned, origin, seq],
                )?;
                tx.execute("UPDATE meta SET value = ?1 WHERE key = 'seq'", params![seq])?;
            }
            tx.execute_batch("DROP TABLE clips_v0;")?;
        }
        tx.execute_batch("PRAGMA user_version = 1;")?;
    }
    let hex: String = tx.query_row("SELECT value FROM meta WHERE key = 'secret_key'", [], |r| r.get(0))?;
    tx.commit()?;
    from_hex(&hex).ok_or_else(|| HoltError::Db("corrupt device key".into()))
}

fn key_of(text: &str) -> String {
    blake3::hash(text.as_bytes()).to_hex().to_string()
}

fn kind_of(text: &str) -> ClipKind {
    let t = text.trim();
    let is_url = (t.starts_with("https://") || t.starts_with("http://"))
        && !t.contains(char::is_whitespace);
    if is_url {
        ClipKind::Link
    } else {
        ClipKind::Text
    }
}

fn escape_like(s: &str) -> String {
    s.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

fn clip_from_row(row: &rusqlite::Row) -> rusqlite::Result<Clip> {
    Ok(Clip {
        id: row.get(0)?,
        kind: if row.get::<_, i64>(1)? == ClipKind::Link as i64 {
            ClipKind::Link
        } else {
            ClipKind::Text
        },
        text: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
        source_app: row.get(3)?,
        created_at: row.get(4)?,
        pinned: row.get(5)?,
    })
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex(hex: &str) -> Option<[u8; 32]> {
    let mut out = [0u8; 32];
    if hex.len() != 64 {
        return None;
    }
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

pub(crate) fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> Arc<Store> {
        Store::open(":memory:".into()).unwrap()
    }

    fn texts(clips: &[Clip]) -> Vec<&str> {
        clips.iter().map(|c| c.text.as_str()).collect()
    }

    fn all(s: &Store) -> Vec<String> {
        s.search("".into(), 100).unwrap().into_iter().map(|c| c.text).collect()
    }

    /// Copies everything `from` has that `to` lacks, the way a sync session does.
    fn sync(from: &Store, to: &Store) {
        let cursors = to.cursors().unwrap();
        for origin in from.origins().unwrap() {
            let after = cursors.get(&origin).copied().unwrap_or(0);
            to.apply(from.rows_since(&origin, after, 1000).unwrap()).unwrap();
        }
    }

    fn tick() {
        std::thread::sleep(std::time::Duration::from_millis(2));
    }

    #[test]
    fn recopy_moves_to_top_without_duplicating() {
        let s = store();
        let first = s.add("one".into(), None).unwrap().unwrap();
        tick();
        s.add("two".into(), None).unwrap();
        tick();
        let again = s.add("one".into(), Some("com.apple.Safari".into())).unwrap().unwrap();

        assert_eq!(again.id, first.id);
        assert_eq!(again.source_app.as_deref(), Some("com.apple.Safari"));
        assert_eq!(texts(&s.search("".into(), 10).unwrap()), ["one", "two"]);
    }

    #[test]
    fn skips_blank_and_huge_text() {
        let s = store();
        assert!(s.add("  \n".into(), None).unwrap().is_none());
        assert!(s.add("x".repeat(MAX_CLIP_BYTES + 1), None).unwrap().is_none());
        assert!(s.search("".into(), 10).unwrap().is_empty());
    }

    #[test]
    fn detects_links() {
        let s = store();
        let link = s.add(" https://github.com/holt-app ".into(), None).unwrap().unwrap();
        let text = s.add("see https://github.com".into(), None).unwrap().unwrap();
        assert_eq!(link.kind, ClipKind::Link);
        assert_eq!(text.kind, ClipKind::Text);
    }

    #[test]
    fn search_matches_every_word_anywhere() {
        let s = store();
        s.add("ssh deploy@10.0.0.4 -p 2222".into(), None).unwrap();
        s.add("Invoice #2031".into(), None).unwrap();
        s.add("100% done_now".into(), None).unwrap();

        assert_eq!(texts(&s.search("0.0 SSH".into(), 10).unwrap()), ["ssh deploy@10.0.0.4 -p 2222"]);
        assert_eq!(texts(&s.search("invoice".into(), 10).unwrap()), ["Invoice #2031"]);
        // % and _ are literal, not wildcards.
        assert_eq!(texts(&s.search("0%".into(), 10).unwrap()), ["100% done_now"]);
        assert!(s.search("e_p".into(), 10).unwrap().is_empty());
    }

    #[test]
    fn prune_keeps_pinned_and_newest() {
        let s = store();
        let keep = s.add("pinned".into(), None).unwrap().unwrap();
        s.set_pinned(keep.id, true).unwrap();
        for i in 0..5 {
            s.add(format!("clip {i}"), None).unwrap();
            tick();
        }

        assert_eq!(s.prune(30, 2).unwrap(), 3);
        assert_eq!(texts(&s.search("".into(), 10).unwrap()), ["pinned", "clip 4", "clip 3"]);

        s.clear().unwrap();
        assert_eq!(texts(&s.search("".into(), 10).unwrap()), ["pinned"]);
    }

    #[test]
    fn copies_pins_and_deletes_sync_both_ways() {
        let (a, b) = (store(), store());
        a.add("hello".into(), None).unwrap();
        sync(&a, &b);
        assert_eq!(all(&b), ["hello"]);
        assert_eq!(b.take_incoming_copy().as_deref(), Some("hello"));
        assert_eq!(b.take_incoming_copy(), None);

        let on_b = b.search("hello".into(), 1).unwrap().remove(0);
        b.set_pinned(on_b.id, true).unwrap();
        b.add("from b".into(), None).unwrap();
        sync(&b, &a);
        assert_eq!(all(&a), ["hello", "from b"]);
        assert!(a.search("hello".into(), 1).unwrap()[0].pinned);

        let on_a = a.search("from b".into(), 1).unwrap().remove(0);
        a.delete(on_a.id).unwrap();
        sync(&a, &b);
        assert_eq!(all(&b), ["hello"]);

        // Syncing again changes nothing.
        sync(&a, &b);
        sync(&b, &a);
        assert_eq!(all(&a), all(&b));
    }

    #[test]
    fn same_text_on_two_devices_is_one_clip() {
        let (a, b) = (store(), store());
        a.add("same".into(), None).unwrap();
        tick();
        b.add("same".into(), Some("com.apple.Notes".into())).unwrap();
        sync(&a, &b);
        sync(&b, &a);
        assert_eq!(all(&a), ["same"]);
        assert_eq!(all(&b), ["same"]);
        // b's copy is newer, so both keep it.
        assert_eq!(a.search("".into(), 1).unwrap()[0].source_app.as_deref(), Some("com.apple.Notes"));
    }

    #[test]
    fn clips_reach_a_device_through_another() {
        let (a, b, c) = (store(), store(), store());
        a.add("from a".into(), None).unwrap();
        sync(&a, &b);
        sync(&b, &c);
        assert_eq!(all(&c), ["from a"]);
    }

    #[test]
    fn rejects_rows_whose_key_does_not_match() {
        let (a, b) = (store(), store());
        a.add("real".into(), None).unwrap();
        let mut rows = a.rows_since(&a.device_id(), 0, 10).unwrap();
        rows[0].text = Some("forged".into());
        b.apply(rows).unwrap();
        assert!(all(&b).is_empty());
    }

    #[test]
    fn migrates_m0_history() {
        let dir = std::env::temp_dir().join(format!("holt-migrate-{}", now_ms()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("holt.db");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE clips (id INTEGER PRIMARY KEY, kind INTEGER NOT NULL, text TEXT NOT NULL UNIQUE,
                     source_app TEXT, created_at INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0);
                 CREATE INDEX clips_created ON clips(created_at);
                 INSERT INTO clips (kind, text, created_at, pinned) VALUES (0, 'old', 1, 1), (1, 'https://x.dev', 2, 0);",
            )
            .unwrap();
        }
        let s = Store::open(path.to_string_lossy().into()).unwrap();
        let clips = s.search("".into(), 10).unwrap();
        assert_eq!(texts(&clips), ["old", "https://x.dev"]);
        assert!(clips[0].pinned);
        // The device key survives reopening.
        let id = s.device_id();
        drop(s);
        assert_eq!(Store::open(path.to_string_lossy().into()).unwrap().device_id(), id);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
