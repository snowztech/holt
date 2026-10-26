use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, params_from_iter, Connection, Row};

uniffi::setup_scaffolding!();

/// Clips bigger than this are skipped. Nobody pastes a 2 MB blob from history,
/// and it keeps the database small.
const MAX_CLIP_BYTES: usize = 1 << 20;

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
    /// Unix time in milliseconds.
    pub created_at: i64,
    pub pinned: bool,
}

#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum HoltError {
    Db(String),
}

impl std::fmt::Display for HoltError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HoltError::Db(msg) => write!(f, "database error: {msg}"),
        }
    }
}

impl From<rusqlite::Error> for HoltError {
    fn from(e: rusqlite::Error) -> Self {
        HoltError::Db(e.to_string())
    }
}

type Result<T> = std::result::Result<T, HoltError>;

#[derive(uniffi::Object)]
pub struct Store {
    conn: Mutex<Connection>,
}

#[uniffi::export]
impl Store {
    /// Opens (or creates) the history database. Pass ":memory:" for tests.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS clips (
                 id         INTEGER PRIMARY KEY,
                 kind       INTEGER NOT NULL,
                 text       TEXT    NOT NULL UNIQUE,
                 source_app TEXT,
                 created_at INTEGER NOT NULL,
                 pinned     INTEGER NOT NULL DEFAULT 0
             );
             CREATE INDEX IF NOT EXISTS clips_created ON clips(created_at);",
        )?;
        Ok(Arc::new(Store { conn: Mutex::new(conn) }))
    }

    /// Records a copy. Copying something already in history moves it to the top
    /// instead of adding a duplicate. Returns None for empty or oversized text.
    pub fn add(&self, text: String, source_app: Option<String>) -> Result<Option<Clip>> {
        if text.trim().is_empty() || text.len() > MAX_CLIP_BYTES {
            return Ok(None);
        }
        let kind = kind_of(&text) as i64;
        let conn = self.conn.lock().unwrap();
        let clip = conn.query_row(
            "INSERT INTO clips (kind, text, source_app, created_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(text) DO UPDATE SET
                 source_app = excluded.source_app,
                 created_at = excluded.created_at
             RETURNING id, kind, text, source_app, created_at, pinned",
            params![kind, text, source_app, now_ms()],
            clip_from_row,
        )?;
        Ok(Some(clip))
    }

    /// Pinned clips first, then newest first. Every whitespace-separated word in the query must appear
    /// somewhere in the clip, case-insensitively. An empty query lists recent clips.
    pub fn search(&self, query: String, limit: u32) -> Result<Vec<Clip>> {
        // A LIKE scan is fine for a few thousand rows. Switch to an FTS5 trigram
        // index if history limits go up and search starts to lag.
        let words: Vec<String> = query
            .split_whitespace()
            .map(|w| format!("%{}%", escape_like(w)))
            .collect();
        let mut sql = String::from(
            "SELECT id, kind, text, source_app, created_at, pinned FROM clips WHERE 1",
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
        let conn = self.conn.lock().unwrap();
        conn.execute("UPDATE clips SET pinned = ?1 WHERE id = ?2", params![pinned, id])?;
        Ok(())
    }

    pub fn delete(&self, id: i64) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM clips WHERE id = ?1", params![id])?;
        Ok(())
    }

    /// Deletes every unpinned clip.
    pub fn clear(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM clips WHERE pinned = 0", [])?;
        Ok(())
    }

    /// Drops unpinned clips older than `max_age_days`, then keeps only the newest
    /// `max_unpinned` of the rest. Pinned clips are never pruned. Returns how many
    /// clips were deleted.
    pub fn prune(&self, max_age_days: u32, max_unpinned: u32) -> Result<u32> {
        let cutoff = now_ms() - i64::from(max_age_days) * 86_400_000;
        let conn = self.conn.lock().unwrap();
        let old = conn.execute(
            "DELETE FROM clips WHERE pinned = 0 AND created_at < ?1",
            params![cutoff],
        )?;
        let extra = conn.execute(
            "DELETE FROM clips WHERE pinned = 0 AND id NOT IN (
                 SELECT id FROM clips WHERE pinned = 0 ORDER BY created_at DESC LIMIT ?1
             )",
            params![max_unpinned],
        )?;
        Ok((old + extra) as u32)
    }
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

fn clip_from_row(row: &Row) -> rusqlite::Result<Clip> {
    Ok(Clip {
        id: row.get(0)?,
        kind: if row.get::<_, i64>(1)? == ClipKind::Link as i64 {
            ClipKind::Link
        } else {
            ClipKind::Text
        },
        text: row.get(2)?,
        source_app: row.get(3)?,
        created_at: row.get(4)?,
        pinned: row.get(5)?,
    })
}

fn now_ms() -> i64 {
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

    #[test]
    fn recopy_moves_to_top_without_duplicating() {
        let s = store();
        let first = s.add("one".into(), None).unwrap().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
        s.add("two".into(), None).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
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
            std::thread::sleep(std::time::Duration::from_millis(2));
        }

        assert_eq!(s.prune(30, 2).unwrap(), 3);
        assert_eq!(texts(&s.search("".into(), 10).unwrap()), ["pinned", "clip 4", "clip 3"]);

        s.clear().unwrap();
        assert_eq!(texts(&s.search("".into(), 10).unwrap()), ["pinned"]);
    }
}
