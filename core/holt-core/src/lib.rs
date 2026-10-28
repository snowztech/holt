use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;

mod net;
pub use net::{Device, Node};

uniffi::setup_scaffolding!();

/// Clips bigger than this are skipped. Nobody pastes a 2 MB blob from history,
/// and it keeps the database small.
const MAX_CLIP_BYTES: usize = 1 << 20;

/// Images bigger than this are skipped. A sync message holds one image at most,
/// base64-encoded, and must stay under the 16 MB frame cap in `net`.
pub const MAX_IMAGE_BYTES: usize = 10 << 20;

/// A clip that arrives from another device goes on this Mac's clipboard only if
/// it was copied this recently, the same window Apple uses for Universal Clipboard.
const LIVE_COPY_WINDOW_MS: i64 = 120_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ClipKind {
    Text,
    Link,
    Image,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Clip {
    pub id: i64,
    pub kind: ClipKind,
    /// The text, or for an image the text recognized in it (may be empty).
    pub text: String,
    pub source_app: Option<String>,
    /// Unix time in milliseconds of the last copy.
    pub created_at: i64,
    pub pinned: bool,
    /// Name of the device it was copied on, if that's not this one.
    pub device: Option<String>,
    /// Set for image clips.
    pub image: Option<ImageInfo>,
}

/// Where an image clip's bytes are and what they hold. The bytes stay on disk;
/// only the thumbnail travels with the clip, so listing history never decodes
/// a full-size image.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImageInfo {
    /// Absolute path of the stored file.
    pub path: String,
    /// "png", "jpeg" or "heic": the bytes as the app copied them, except TIFF
    /// which the app converts to PNG before storing.
    pub format: String,
    pub width: u32,
    pub height: u32,
    pub bytes: u64,
    /// A small encoded preview, a few kilobytes.
    pub thumb: Vec<u8>,
}

/// A clip that just arrived from another device.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct IncomingCopy {
    pub text: String,
    pub device: String,
    /// The image bytes and their format, for an image clip.
    pub image: Option<Vec<u8>>,
    pub image_format: Option<String>,
}

/// The network path a synced clip took to reach this device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ArrivalPath {
    /// Straight from the other device, without leaving this network.
    SameNetwork,
    /// Straight from the other device, across the internet.
    Internet,
    /// Forwarded by a relay server, because the devices couldn't reach each other.
    Relay,
}

impl ArrivalPath {
    fn as_str(self) -> &'static str {
        match self {
            ArrivalPath::SameNetwork => "same-network",
            ArrivalPath::Internet => "internet",
            ArrivalPath::Relay => "relay",
        }
    }

    fn parse(stored: &str) -> Option<Self> {
        // 0.1.6 stored "direct" without telling the two apart, so those have no path.
        [Self::SameNetwork, Self::Internet, Self::Relay]
            .into_iter()
            .find(|p| p.as_str() == stored)
    }
}

/// One delivery of a clip from a paired device. Kept on this device only, to
/// show how a clip got here.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Arrival {
    /// The device that sent it. It may be passing on another device's copy.
    pub from: String,
    pub path: Option<ArrivalPath>,
    /// The relay server's host, or the other device's IP address on a direct path.
    pub address: Option<String>,
    /// Unix time in milliseconds it was copied, on the copying device's clock.
    pub copied_at: i64,
    /// Unix time in milliseconds it got here.
    pub arrived_at: i64,
}

/// Who a batch of rows came from, and over which path.
#[derive(Debug, Clone)]
pub(crate) struct Delivery {
    pub peer: String,
    pub path: Option<ArrivalPath>,
    pub address: Option<String>,
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
    /// Id and name of the device the clip was last copied on.
    #[serde(default)]
    pub copied_by: Option<String>,
    #[serde(default)]
    pub copied_on: Option<String>,
    /// Image clips carry their bytes and thumbnail base64-encoded. Older
    /// versions ignore these fields and drop the row, since its key doesn't
    /// match its text.
    #[serde(default)]
    pub image: Option<String>,
    #[serde(default)]
    pub format: Option<String>,
    #[serde(default)]
    pub width: Option<i64>,
    #[serde(default)]
    pub height: Option<i64>,
    #[serde(default)]
    pub thumb: Option<String>,
}

#[derive(uniffi::Object)]
pub struct Store {
    conn: Mutex<Connection>,
    secret_key: [u8; 32],
    device_id: String,
    device_name: Mutex<Option<String>>,
    changes: watch::Sender<u64>,
    incoming_copy: Mutex<Option<IncomingCopy>>,
    /// Where image bytes live: `images/` next to the database.
    images_dir: PathBuf,
    /// An in-memory store gets a temporary folder, removed when it's dropped.
    temp_images: bool,
}

static MEMORY_STORES: AtomicU64 = AtomicU64::new(0);

#[uniffi::export]
impl Store {
    /// Opens (or creates) the history database. Pass ":memory:" for tests.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>> {
        let temp_images = path == ":memory:";
        let images_dir = if temp_images {
            std::env::temp_dir().join(format!(
                "holt-images-{}-{}",
                std::process::id(),
                MEMORY_STORES.fetch_add(1, Ordering::Relaxed)
            ))
        } else {
            Path::new(&path)
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_default()
                .join("images")
        };
        let mut conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA journal_mode = WAL;")?;
        let secret_key = migrate(&mut conn)?;
        let device_id = iroh::SecretKey::from_bytes(&secret_key)
            .public()
            .to_string();
        std::fs::create_dir_all(&images_dir).map_err(|e| HoltError::Db(e.to_string()))?;
        let store = Store {
            conn: Mutex::new(conn),
            secret_key,
            device_id,
            device_name: Mutex::new(None),
            changes: watch::channel(0).0,
            incoming_copy: Mutex::new(None),
            images_dir,
            temp_images,
        };
        store.sweep_images()?;
        Ok(Arc::new(store))
    }

    /// Records an image copy. `text` is the text recognized in the image, which
    /// is what search matches. The same bytes copied again move the existing
    /// clip to the top. Returns None for empty or oversized images.
    #[allow(clippy::too_many_arguments)]
    pub fn add_image(
        &self,
        bytes: Vec<u8>,
        format: String,
        width: u32,
        height: u32,
        thumb: Vec<u8>,
        text: String,
        source_app: Option<String>,
    ) -> Result<Option<Clip>> {
        if bytes.is_empty() || bytes.len() > MAX_IMAGE_BYTES || text.len() > MAX_CLIP_BYTES {
            return Ok(None);
        }
        let key = blake3::hash(&bytes).to_hex().to_string();
        let name = self.device_name.lock().unwrap().clone();
        let clip = self.write(|tx, now, seq| {
            self.write_image_file(&key, &format, &bytes)?;
            Ok(tx.query_row(
                &format!(
                    "INSERT INTO clips (key, text, kind, source_app, created_at, updated_at, origin, seq, copied_by, copied_on,
                                        format, width, height, bytes, thumb)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, ?6, ?8, ?9, ?10, ?11, ?12, ?13)
                     ON CONFLICT(key) DO UPDATE SET
                         text = excluded.text,
                         source_app = excluded.source_app,
                         created_at = excluded.created_at,
                         updated_at = max(excluded.updated_at, clips.updated_at + 1),
                         deleted = 0,
                         origin = excluded.origin,
                         seq = excluded.seq,
                         copied_by = excluded.copied_by,
                         copied_on = excluded.copied_on,
                         format = excluded.format,
                         width = excluded.width,
                         height = excluded.height,
                         bytes = excluded.bytes,
                         thumb = excluded.thumb
                     RETURNING {CLIP_COLUMNS}"
                ),
                params![
                    key, text, ClipKind::Image as i64, source_app, now, self.device_id, seq, name,
                    format, width, height, bytes.len() as i64, thumb
                ],
                |r| self.clip_from_row(r),
            )?)
        })?;
        Ok(Some(clip))
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
        let name = self.device_name.lock().unwrap().clone();
        let clip = self.write(|tx, now, seq| {
            Ok(tx.query_row(
                &format!(
                    "INSERT INTO clips (key, text, kind, source_app, created_at, updated_at, origin, seq, copied_by, copied_on)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, ?6, ?8)
                     ON CONFLICT(key) DO UPDATE SET
                         text = excluded.text,
                         source_app = excluded.source_app,
                         created_at = excluded.created_at,
                         updated_at = max(excluded.updated_at, clips.updated_at + 1),
                         deleted = 0,
                         origin = excluded.origin,
                         seq = excluded.seq,
                         copied_by = excluded.copied_by,
                         copied_on = excluded.copied_on
                     RETURNING {CLIP_COLUMNS}"
                ),
                params![key_of(&text), text, kind_of(&text) as i64, source_app, now, self.device_id, seq, name],
                |r| self.clip_from_row(r),
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
        let mut sql = format!("SELECT {CLIP_COLUMNS} FROM clips WHERE deleted = 0");
        for _ in &words {
            sql.push_str(" AND text LIKE ? ESCAPE '\\'");
        }
        sql.push_str(&format!(
            " ORDER BY pinned DESC, created_at DESC LIMIT {limit}"
        ));

        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(words.iter()), |r| self.clip_from_row(r))?;
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
        self.write(|tx, now, seq| self.tombstone(tx, id, now, seq))
    }

    /// Deletes every unpinned clip, here and on every paired device.
    pub fn clear(&self) -> Result<()> {
        let ids: Vec<i64> = {
            let conn = self.conn.lock().unwrap();
            let mut stmt = conn.prepare("SELECT id FROM clips WHERE pinned = 0 AND deleted = 0")?;
            let ids = stmt
                .query_map([], |r| r.get(0))?
                .collect::<std::result::Result<_, _>>()?;
            ids
        };
        for id in ids {
            self.write(|tx, now, seq| self.tombstone(tx, id, now, seq))?;
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
        conn.execute(
            "DELETE FROM arrivals WHERE key NOT IN (SELECT key FROM clips WHERE deleted = 0)",
            [],
        )?;
        drop(conn);
        self.sweep_images()?;
        Ok((old + extra) as u32)
    }

    /// How a clip reached this device from paired devices, the last five in the
    /// order they came. Empty for a clip copied here.
    pub fn arrivals(&self, id: i64) -> Result<Vec<Arrival>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT coalesce(p.name, a.peer), a.path, a.address, a.copied_at, a.at
             FROM arrivals a JOIN clips c ON c.key = a.key LEFT JOIN peers p ON p.id = a.peer
             WHERE c.id = ?1 ORDER BY a.at DESC LIMIT 5",
        )?;
        let rows = stmt.query_map(params![id], |r| {
            Ok(Arrival {
                from: r.get(0)?,
                path: r
                    .get::<_, Option<String>>(1)?
                    .as_deref()
                    .and_then(ArrivalPath::parse),
                address: r.get(2)?,
                copied_at: r.get(3)?,
                arrived_at: r.get(4)?,
            })
        })?;
        let mut arrivals: Vec<Arrival> = rows.collect::<std::result::Result<_, _>>()?;
        arrivals.reverse();
        Ok(arrivals)
    }

    /// The newest clip that just arrived from another device, if there is one
    /// the app hasn't taken yet. The app puts it on the clipboard.
    pub fn take_incoming_copy(&self) -> Option<IncomingCopy> {
        self.incoming_copy.lock().unwrap().take()
    }
}

/// Sync and pairing support, used by `net`.
impl Store {
    pub(crate) fn secret_key(&self) -> [u8; 32] {
        self.secret_key
    }

    pub(crate) fn set_device_name(&self, name: &str) {
        *self.device_name.lock().unwrap() = Some(name.to_string());
    }

    fn clip_from_row(&self, row: &rusqlite::Row) -> rusqlite::Result<Clip> {
        let copied_by: Option<String> = row.get(6)?;
        let device = if copied_by.as_deref().is_some_and(|id| id != self.device_id) {
            row.get(7)?
        } else {
            None
        };
        let kind = kind_from(row.get(1)?);
        let image = if kind == ClipKind::Image {
            let key: String = row.get(8)?;
            let format: String = row.get::<_, Option<String>>(9)?.unwrap_or_default();
            Some(ImageInfo {
                path: self
                    .image_path(&key, &format)
                    .to_string_lossy()
                    .into_owned(),
                format,
                width: row.get::<_, Option<u32>>(10)?.unwrap_or_default(),
                height: row.get::<_, Option<u32>>(11)?.unwrap_or_default(),
                bytes: row.get::<_, Option<i64>>(12)?.unwrap_or_default().max(0) as u64,
                thumb: row.get::<_, Option<Vec<u8>>>(13)?.unwrap_or_default(),
            })
        } else {
            None
        };
        Ok(Clip {
            id: row.get(0)?,
            kind,
            text: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
            source_app: row.get(3)?,
            created_at: row.get(4)?,
            pinned: row.get(5)?,
            device,
            image,
        })
    }

    fn image_path(&self, key: &str, format: &str) -> PathBuf {
        let ext = match format {
            "jpeg" => "jpg",
            "heic" => "heic",
            _ => "png",
        };
        self.images_dir.join(format!("{key}.{ext}"))
    }

    /// Writes the bytes unless the file is already there: the same image copied
    /// again has the same key, so the same file. Read-only, because ⌘O opens it
    /// in Preview, and an edit saved in place would no longer match its key.
    fn write_image_file(&self, key: &str, format: &str, bytes: &[u8]) -> Result<()> {
        let path = self.image_path(key, format);
        if path.exists() {
            return Ok(());
        }
        let err = |e: std::io::Error| HoltError::Db(format!("{}: {e}", path.display()));
        std::fs::write(&path, bytes).map_err(err)?;
        let mut perms = std::fs::metadata(&path).map_err(err)?.permissions();
        perms.set_readonly(true);
        std::fs::set_permissions(&path, perms).map_err(err)
    }

    /// Removes any file in `images/` that no live image clip points to: leftovers
    /// of a crash between writing the file and the row, or of a prune.
    fn sweep_images(&self) -> Result<()> {
        // Held to the end: an image written meanwhile would look like a leftover.
        let conn = self.conn.lock().unwrap();
        let live: std::collections::HashSet<String> = {
            let mut stmt = conn.prepare("SELECT key FROM clips WHERE kind = ?1 AND deleted = 0")?;
            let keys = stmt.query_map(params![ClipKind::Image as i64], |r| r.get(0))?;
            keys.collect::<std::result::Result<_, _>>()?
        };
        let entries =
            std::fs::read_dir(&self.images_dir).map_err(|e| HoltError::Db(e.to_string()))?;
        for entry in entries.flatten() {
            let path = entry.path();
            let key = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or_default();
            if !live.contains(key) {
                let _ = std::fs::remove_file(&path);
            }
        }
        Ok(())
    }

    /// Marks a clip deleted so the delete syncs, and drops its image file.
    fn tombstone(&self, tx: &Transaction, id: i64, now: i64, seq: i64) -> Result<()> {
        let image: Option<(String, Option<String>)> = tx
            .query_row(
                "SELECT key, format FROM clips WHERE id = ?1 AND deleted = 0 AND kind = ?2",
                params![id, ClipKind::Image as i64],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        tx.execute(
            "UPDATE clips SET text = NULL, source_app = NULL, pinned = 0, deleted = 1, thumb = NULL,
                 updated_at = max(?1, updated_at + 1), origin = ?2, seq = ?3
             WHERE id = ?4 AND deleted = 0",
            params![now, self.device_id, seq, id],
        )?;
        if let Some((key, format)) = image {
            let _ = std::fs::remove_file(self.image_path(&key, &format.unwrap_or_default()));
        }
        Ok(())
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
            "SELECT key, text, kind, source_app, created_at, updated_at, pinned, deleted, origin, seq, copied_by, copied_on,
                    format, width, height, thumb
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
                copied_by: r.get(10)?,
                copied_on: r.get(11)?,
                image: None,
                format: r.get(12)?,
                width: r.get(13)?,
                height: r.get(14)?,
                thumb: r.get::<_, Option<Vec<u8>>>(15)?.map(|t| BASE64.encode(t)),
            })
        })?;
        let mut rows: Vec<Row> = rows.collect::<std::result::Result<_, _>>()?;
        // Live images travel with their bytes. A missing file leaves `image` empty
        // and the peer drops the row, as it would a forged one. Past one image's
        // worth of bytes the rows stop, so a long history of screenshots isn't all
        // in memory at once; the caller asks again from the last seq.
        let mut loaded = 0;
        let mut keep = rows.len();
        for (i, row) in rows.iter_mut().enumerate() {
            if row.kind != ClipKind::Image as i64 || row.deleted {
                continue;
            }
            if loaded >= MAX_IMAGE_BYTES {
                keep = i;
                break;
            }
            let path = self.image_path(&row.key, row.format.as_deref().unwrap_or_default());
            row.image = std::fs::read(path).ok().map(|bytes| {
                loaded += bytes.len();
                BASE64.encode(bytes)
            });
        }
        rows.truncate(keep);
        Ok(rows)
    }

    /// Merges rows from a peer. For each clip the version with the newest
    /// `updated_at` wins, with the origin id breaking ties so every device
    /// picks the same one.
    pub(crate) fn apply(&self, rows: Vec<Row>, delivery: Option<&Delivery>) -> Result<()> {
        let now = now_ms();
        let mut changed = false;
        let mut live_copy: Option<(i64, IncomingCopy)> = None;
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
                // A live clip's key must match its text, or its bytes for an
                // image, or dedupe breaks.
                let is_image = row.kind == ClipKind::Image as i64;
                // An image's key names its file, so a deleted one must still be a hash.
                if is_image
                    && (row.key.len() != 64 || !row.key.bytes().all(|b| b.is_ascii_hexdigit()))
                {
                    continue;
                }
                let image = if is_image && !row.deleted {
                    let Some(bytes) = row.image.as_deref().and_then(|b| BASE64.decode(b).ok())
                    else {
                        continue;
                    };
                    if bytes.is_empty()
                        || bytes.len() > MAX_IMAGE_BYTES
                        || blake3::hash(&bytes).to_hex().as_str() != row.key
                    {
                        continue;
                    }
                    Some(bytes)
                } else {
                    if !row.deleted
                        && row.text.as_deref().map(key_of).as_deref() != Some(row.key.as_str())
                    {
                        continue;
                    }
                    None
                };
                // Noted even when this device's own version wins below: a copy that
                // came through Universal Clipboard first still shows it arrived here too.
                if let (Some(d), false) = (delivery, row.deleted) {
                    tx.execute(
                        "INSERT OR IGNORE INTO arrivals (key, copied_at, peer, path, address, at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                        params![
                            row.key,
                            row.created_at,
                            d.peer,
                            d.path.map(ArrivalPath::as_str),
                            d.address,
                            now
                        ],
                    )?;
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
                let format = row.format.clone().unwrap_or_default();
                let thumb = row.thumb.as_deref().and_then(|t| BASE64.decode(t).ok());
                tx.execute(
                    "INSERT INTO clips (key, text, kind, source_app, created_at, updated_at, pinned, deleted, origin, seq, copied_by, copied_on,
                                        format, width, height, bytes, thumb)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
                     ON CONFLICT(key) DO UPDATE SET
                         text = excluded.text, kind = excluded.kind, source_app = excluded.source_app,
                         created_at = excluded.created_at, updated_at = excluded.updated_at,
                         pinned = excluded.pinned, deleted = excluded.deleted,
                         origin = excluded.origin, seq = excluded.seq,
                         copied_by = excluded.copied_by, copied_on = excluded.copied_on,
                         format = excluded.format, width = excluded.width, height = excluded.height,
                         bytes = excluded.bytes, thumb = excluded.thumb",
                    params![
                        row.key, row.text, row.kind, row.source_app, row.created_at, row.updated_at,
                        row.pinned, row.deleted, row.origin, row.seq, row.copied_by, row.copied_on,
                        row.format, row.width, row.height, image.as_ref().map(|b| b.len() as i64), thumb
                    ],
                )?;
                match &image {
                    Some(bytes) => self.write_image_file(&row.key, &format, bytes)?,
                    None if is_image => {
                        let _ = std::fs::remove_file(self.image_path(&row.key, &format));
                    }
                    None => {}
                }
                changed = true;
                let is_new_copy = !row.deleted
                    && row.created_at > newest_before
                    && row.created_at > now - LIVE_COPY_WINDOW_MS
                    && live_copy
                        .as_ref()
                        .is_none_or(|(at, _)| row.created_at > *at);
                if is_new_copy {
                    let copy = IncomingCopy {
                        text: row.text.clone().unwrap_or_default(),
                        device: row
                            .copied_on
                            .clone()
                            .unwrap_or_else(|| "another device".into()),
                        image_format: image.is_some().then_some(format),
                        image,
                    };
                    live_copy = Some((row.created_at, copy));
                }
            }
            tx.commit()?;
        }
        if let Some((_, copy)) = live_copy {
            *self.incoming_copy.lock().unwrap() = Some(copy);
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

impl Drop for Store {
    fn drop(&mut self) {
        if self.temp_images {
            let _ = std::fs::remove_dir_all(&self.images_dir);
        }
    }
}

/// Creates or upgrades the schema and returns this device's secret key.
fn migrate(conn: &mut Connection) -> Result<[u8; 32]> {
    let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    let tx = conn.transaction()?;
    if version < 1 {
        let had_v0: bool = tx
            .query_row(
                "SELECT 1 FROM sqlite_master WHERE name = 'clips'",
                [],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if had_v0 {
            // The old index moves with the renamed table and would clash with the new one.
            tx.execute_batch(
                "ALTER TABLE clips RENAME TO clips_v0; DROP INDEX IF EXISTS clips_created;",
            )?;
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
                let rows = stmt.query_map([], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                })?;
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
    if version < 2 {
        tx.execute_batch(
            "ALTER TABLE clips ADD COLUMN copied_by TEXT;
             ALTER TABLE clips ADD COLUMN copied_on TEXT;
             PRAGMA user_version = 2;",
        )?;
    }
    if version < 3 {
        // Image clips: the bytes are in images/<key>.<ext>, the row keeps what
        // the list and preview need without opening the file.
        tx.execute_batch(
            "ALTER TABLE clips ADD COLUMN format TEXT;
             ALTER TABLE clips ADD COLUMN width INTEGER;
             ALTER TABLE clips ADD COLUMN height INTEGER;
             ALTER TABLE clips ADD COLUMN bytes INTEGER;
             ALTER TABLE clips ADD COLUMN thumb BLOB;
             PRAGMA user_version = 3;",
        )?;
    }
    if version < 4 {
        // How synced clips got here. Never synced itself: each device keeps its own.
        // One row per copy and sender, so a pin or a second batch doesn't add another.
        tx.execute_batch(
            "CREATE TABLE arrivals (
                 key TEXT NOT NULL,
                 copied_at INTEGER NOT NULL,
                 peer TEXT NOT NULL,
                 path TEXT,
                 address TEXT,
                 at INTEGER NOT NULL,
                 PRIMARY KEY (key, copied_at, peer)
             ) WITHOUT ROWID;
             PRAGMA user_version = 4;",
        )?;
    }
    let hex: String = tx.query_row("SELECT value FROM meta WHERE key = 'secret_key'", [], |r| {
        r.get(0)
    })?;
    tx.commit()?;
    from_hex(&hex).ok_or_else(|| HoltError::Db("corrupt device key".into()))
}

fn key_of(text: &str) -> String {
    blake3::hash(text.as_bytes()).to_hex().to_string()
}

fn kind_of(text: &str) -> ClipKind {
    let t = text.trim();
    let is_url =
        (t.starts_with("https://") || t.starts_with("http://")) && !t.contains(char::is_whitespace);
    if is_url {
        ClipKind::Link
    } else {
        ClipKind::Text
    }
}

fn escape_like(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

fn kind_from(stored: i64) -> ClipKind {
    match stored {
        1 => ClipKind::Link,
        2 => ClipKind::Image,
        _ => ClipKind::Text,
    }
}

const CLIP_COLUMNS: &str =
    "id, kind, text, source_app, created_at, pinned, copied_by, copied_on, key, format, width, height, bytes, thumb";

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
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
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
        s.search("".into(), 100)
            .unwrap()
            .into_iter()
            .map(|c| c.text)
            .collect()
    }

    /// Copies everything `from` has that `to` lacks, the way a sync session does.
    fn sync(from: &Store, to: &Store) {
        let cursors = to.cursors().unwrap();
        for origin in from.origins().unwrap() {
            let after = cursors.get(&origin).copied().unwrap_or(0);
            to.apply(from.rows_since(&origin, after, 1000).unwrap(), None)
                .unwrap();
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
        let again = s
            .add("one".into(), Some("com.apple.Safari".into()))
            .unwrap()
            .unwrap();

        assert_eq!(again.id, first.id);
        assert_eq!(again.source_app.as_deref(), Some("com.apple.Safari"));
        assert_eq!(texts(&s.search("".into(), 10).unwrap()), ["one", "two"]);
    }

    #[test]
    fn skips_blank_and_huge_text() {
        let s = store();
        assert!(s.add("  \n".into(), None).unwrap().is_none());
        assert!(s
            .add("x".repeat(MAX_CLIP_BYTES + 1), None)
            .unwrap()
            .is_none());
        assert!(s.search("".into(), 10).unwrap().is_empty());
    }

    #[test]
    fn detects_links() {
        let s = store();
        let link = s
            .add(" https://github.com/holt-app ".into(), None)
            .unwrap()
            .unwrap();
        let text = s
            .add("see https://github.com".into(), None)
            .unwrap()
            .unwrap();
        assert_eq!(link.kind, ClipKind::Link);
        assert_eq!(text.kind, ClipKind::Text);
    }

    #[test]
    fn search_matches_every_word_anywhere() {
        let s = store();
        s.add("ssh deploy@10.0.0.4 -p 2222".into(), None).unwrap();
        s.add("Invoice #2031".into(), None).unwrap();
        s.add("100% done_now".into(), None).unwrap();

        assert_eq!(
            texts(&s.search("0.0 SSH".into(), 10).unwrap()),
            ["ssh deploy@10.0.0.4 -p 2222"]
        );
        assert_eq!(
            texts(&s.search("invoice".into(), 10).unwrap()),
            ["Invoice #2031"]
        );
        // % and _ are literal, not wildcards.
        assert_eq!(
            texts(&s.search("0%".into(), 10).unwrap()),
            ["100% done_now"]
        );
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
        assert_eq!(
            texts(&s.search("".into(), 10).unwrap()),
            ["pinned", "clip 4", "clip 3"]
        );

        s.clear().unwrap();
        assert_eq!(texts(&s.search("".into(), 10).unwrap()), ["pinned"]);
    }

    #[test]
    fn copies_pins_and_deletes_sync_both_ways() {
        let (a, b) = (store(), store());
        a.add("hello".into(), None).unwrap();
        sync(&a, &b);
        assert_eq!(all(&b), ["hello"]);
        assert_eq!(
            b.take_incoming_copy().map(|c| c.text).as_deref(),
            Some("hello")
        );
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
    fn clips_say_which_device_they_came_from() {
        let (a, b) = (store(), store());
        a.set_device_name("MacBook Pro");
        b.set_device_name("Mac mini");
        a.add("hi".into(), None).unwrap();
        assert_eq!(a.search("".into(), 1).unwrap()[0].device, None);
        sync(&a, &b);
        assert_eq!(
            b.search("".into(), 1).unwrap()[0].device.as_deref(),
            Some("MacBook Pro")
        );
        assert_eq!(
            b.take_incoming_copy().map(|c| c.device).as_deref(),
            Some("MacBook Pro")
        );
        // Pinning on b doesn't change where it was copied.
        let id = b.search("".into(), 1).unwrap()[0].id;
        b.set_pinned(id, true).unwrap();
        sync(&b, &a);
        assert_eq!(a.search("".into(), 1).unwrap()[0].device, None);
    }

    #[test]
    fn same_text_on_two_devices_is_one_clip() {
        let (a, b) = (store(), store());
        a.add("same".into(), None).unwrap();
        tick();
        b.add("same".into(), Some("com.apple.Notes".into()))
            .unwrap();
        sync(&a, &b);
        sync(&b, &a);
        assert_eq!(all(&a), ["same"]);
        assert_eq!(all(&b), ["same"]);
        // b's copy is newer, so both keep it.
        assert_eq!(
            a.search("".into(), 1).unwrap()[0].source_app.as_deref(),
            Some("com.apple.Notes")
        );
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
        b.apply(rows, None).unwrap();
        assert!(all(&b).is_empty());
    }

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n fake screenshot bytes";

    fn add_png(s: &Store, text: &str) -> Clip {
        s.add_image(
            PNG.to_vec(),
            "png".into(),
            640,
            480,
            vec![1, 2, 3],
            text.into(),
            Some("com.apple.screencaptureui".into()),
        )
        .unwrap()
        .unwrap()
    }

    /// Like `sync`, as if `from` sent the rows over `path`.
    fn sync_via(from: &Store, to: &Store, path: ArrivalPath) {
        let delivery = Delivery {
            peer: from.device_id(),
            path: Some(path),
            address: (path == ArrivalPath::Relay).then(|| "euw1-1.relay.n0.iroh.link".into()),
        };
        let cursors = to.cursors().unwrap();
        for origin in from.origins().unwrap() {
            let after = cursors.get(&origin).copied().unwrap_or(0);
            to.apply(
                from.rows_since(&origin, after, 1000).unwrap(),
                Some(&delivery),
            )
            .unwrap();
        }
    }

    #[test]
    fn arrivals_say_who_sent_a_copy_and_how() {
        let (a, b) = (store(), store());
        b.add_peer(&a.device_id(), "MacBook Pro").unwrap();
        let on_a = a.add("hello".into(), None).unwrap().unwrap();
        sync_via(&a, &b, ArrivalPath::Relay);

        let on_b = b.search("".into(), 10).unwrap().remove(0);
        let arrivals = b.arrivals(on_b.id).unwrap();
        assert_eq!(arrivals.len(), 1);
        assert_eq!(arrivals[0].from, "MacBook Pro");
        assert_eq!(arrivals[0].path, Some(ArrivalPath::Relay));
        assert_eq!(
            arrivals[0].address.as_deref(),
            Some("euw1-1.relay.n0.iroh.link")
        );
        assert_eq!(arrivals[0].copied_at, on_a.created_at);
        assert!(arrivals[0].arrived_at >= on_a.created_at);
        assert!(a.arrivals(on_a.id).unwrap().is_empty());

        // A pin is the same copy, so it adds nothing. Copying it again does.
        a.set_pinned(on_a.id, true).unwrap();
        sync_via(&a, &b, ArrivalPath::Relay);
        assert_eq!(b.arrivals(on_b.id).unwrap().len(), 1);
        tick();
        a.add("hello".into(), None).unwrap();
        sync_via(&a, &b, ArrivalPath::Internet);
        let arrivals = b.arrivals(on_b.id).unwrap();
        assert_eq!(arrivals.len(), 2);
        assert_eq!(arrivals[1].path, Some(ArrivalPath::Internet));

        // 0.1.6 stored plain "direct", which can't say which network.
        assert_eq!(ArrivalPath::parse("direct"), None);
        assert_eq!(ArrivalPath::parse("internet"), Some(ArrivalPath::Internet));
    }

    #[test]
    fn a_copy_already_here_still_notes_that_it_arrived() {
        // Universal Clipboard can put a copy on this Mac before Holt sync brings it.
        let (a, b) = (store(), store());
        a.add("from the phone".into(), None).unwrap();
        tick();
        let here = b
            .add(
                "from the phone".into(),
                Some("com.apple.is-remote-clipboard".into()),
            )
            .unwrap()
            .unwrap();
        sync_via(&a, &b, ArrivalPath::Relay);

        let clips = b.search("".into(), 10).unwrap();
        assert_eq!(clips.len(), 1);
        assert_eq!(clips[0].source_app, here.source_app);
        let arrivals = b.arrivals(here.id).unwrap();
        assert_eq!(arrivals.len(), 1);
        assert_eq!(arrivals[0].from, a.device_id());
    }

    #[test]
    fn pruning_forgets_arrivals_of_deleted_clips() {
        let (a, b) = (store(), store());
        a.add("gone soon".into(), None).unwrap();
        sync_via(&a, &b, ArrivalPath::SameNetwork);
        let id = b.search("".into(), 10).unwrap()[0].id;
        b.delete(id).unwrap();
        b.prune(30, 5000).unwrap();
        let left: i64 = b
            .conn
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM arrivals", [], |r| r.get(0))
            .unwrap();
        assert_eq!(left, 0);
    }

    #[test]
    fn same_image_copied_twice_is_one_clip_with_one_file() {
        let s = store();
        let first = add_png(&s, "");
        tick();
        s.add("in between".into(), None).unwrap();
        tick();
        let again = add_png(&s, "Invoice 2026");

        assert_eq!(again.id, first.id);
        assert_eq!(again.kind, ClipKind::Image);
        assert_eq!(again.text, "Invoice 2026");
        let image = again.image.unwrap();
        assert_eq!(
            (image.width, image.height, image.bytes),
            (640, 480, PNG.len() as u64)
        );
        assert_eq!(image.format, "png");
        assert_eq!(image.thumb, vec![1, 2, 3]);
        assert_eq!(std::fs::read(&image.path).unwrap(), PNG);
        assert!(std::fs::metadata(&image.path)
            .unwrap()
            .permissions()
            .readonly());
        assert!(image
            .path
            .ends_with(&format!("{}.png", blake3::hash(PNG).to_hex())));
        let clips = s.search("".into(), 10).unwrap();
        assert_eq!(clips.len(), 2);
        assert_eq!(clips[0].id, first.id);
        assert_eq!(clips[1].text, "in between");
        assert!(clips[1].image.is_none());
    }

    #[test]
    fn skips_empty_and_huge_images() {
        let s = store();
        assert!(s
            .add_image(vec![], "png".into(), 1, 1, vec![], "".into(), None)
            .unwrap()
            .is_none());
        assert!(s
            .add_image(
                vec![0; MAX_IMAGE_BYTES + 1],
                "png".into(),
                1,
                1,
                vec![],
                "".into(),
                None
            )
            .unwrap()
            .is_none());
        assert!(s.search("".into(), 10).unwrap().is_empty());
    }

    #[test]
    fn search_finds_images_by_the_text_in_them() {
        let s = store();
        add_png(&s, "Invoice #2031\nTotal 120 €");
        s.add("invoice email".into(), None).unwrap();

        let hits = s.search("invoice total".into(), 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].kind, ClipKind::Image);
        assert_eq!(s.search("invoice".into(), 10).unwrap().len(), 2);
    }

    #[test]
    fn deleting_or_pruning_an_image_removes_its_file() {
        let s = store();
        let clip = add_png(&s, "");
        let path = clip.image.unwrap().path;
        assert!(std::path::Path::new(&path).exists());
        s.delete(clip.id).unwrap();
        assert!(!std::path::Path::new(&path).exists());
        assert!(all(&s).is_empty());

        let clip = add_png(&s, "");
        let path = clip.image.unwrap().path;
        s.clear().unwrap();
        assert!(!std::path::Path::new(&path).exists());

        let clip = add_png(&s, "");
        let path = clip.image.unwrap().path;
        tick();
        s.add("newer".into(), None).unwrap();
        assert_eq!(s.prune(30, 1).unwrap(), 1);
        assert!(!std::path::Path::new(&path).exists());
    }

    #[test]
    fn images_sync_with_their_bytes() {
        let (a, b) = (store(), store());
        a.set_device_name("MacBook Pro");
        let on_a = add_png(&a, "Invoice 2026");
        sync(&a, &b);

        let clips = b.search("".into(), 10).unwrap();
        assert_eq!(clips.len(), 1);
        assert_eq!(clips[0].kind, ClipKind::Image);
        assert_eq!(clips[0].text, "Invoice 2026");
        assert_eq!(clips[0].device.as_deref(), Some("MacBook Pro"));
        let image = clips[0].image.clone().unwrap();
        assert_ne!(image.path, on_a.image.unwrap().path);
        assert_eq!(std::fs::read(&image.path).unwrap(), PNG);
        assert_eq!(
            (image.width, image.height, image.thumb.clone()),
            (640, 480, vec![1, 2, 3])
        );

        let copy = b.take_incoming_copy().unwrap();
        assert_eq!(copy.image.as_deref(), Some(PNG));
        assert_eq!(copy.image_format.as_deref(), Some("png"));

        a.delete(on_a.id).unwrap();
        sync(&a, &b);
        assert!(all(&b).is_empty());
        assert!(!std::path::Path::new(&image.path).exists());
    }

    #[test]
    fn rejects_images_whose_bytes_do_not_match_key() {
        let (a, b) = (store(), store());
        add_png(&a, "");
        let mut rows = a.rows_since(&a.device_id(), 0, 10).unwrap();
        rows[0].image = Some(base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            b"forged",
        ));
        b.apply(rows, None).unwrap();
        assert!(all(&b).is_empty());
    }

    #[test]
    fn rows_since_stops_after_an_image_worth_of_bytes() {
        let s = store();
        for n in 1..=3u8 {
            s.add_image(
                vec![n; 6 << 20],
                "png".into(),
                1,
                1,
                vec![],
                "".into(),
                None,
            )
            .unwrap();
        }
        let id = s.device_id();
        let first = s.rows_since(&id, 0, 10).unwrap();
        assert_eq!(first.len(), 2);
        let rest = s.rows_since(&id, first[1].seq, 10).unwrap();
        assert_eq!(rest.len(), 1);
        assert!(rest[0].image.is_some());
    }

    #[test]
    fn deleted_images_from_a_peer_stay_inside_images() {
        let (a, b) = (store(), store());
        let clip = add_png(&a, "");
        a.delete(clip.id).unwrap();
        let outside = b
            .images_dir
            .with_file_name(format!("holt-outside-{}.png", now_ms()));
        std::fs::write(&outside, b"x").unwrap();
        let mut rows = a.rows_since(&a.device_id(), 0, 10).unwrap();
        rows[0].key = format!("../{}", outside.file_stem().unwrap().to_str().unwrap());
        b.apply(rows, None).unwrap();
        assert!(outside.exists());
        std::fs::remove_file(outside).unwrap();
    }

    #[test]
    fn opening_removes_image_files_without_a_clip() {
        let dir = std::env::temp_dir().join(format!("holt-sweep-{}", now_ms()));
        std::fs::create_dir_all(dir.join("images")).unwrap();
        let path = dir.join("holt.db");
        let stray = dir.join("images").join("stray.png");
        std::fs::write(&stray, b"x").unwrap();
        let kept = {
            let s = Store::open(path.to_string_lossy().into()).unwrap();
            add_png(&s, "").image.unwrap().path
        };
        let _s = Store::open(path.to_string_lossy().into()).unwrap();
        assert!(!stray.exists());
        assert!(std::path::Path::new(&kept).exists());
        assert!(kept.starts_with(dir.join("images").to_str().unwrap()));
        std::fs::remove_dir_all(dir).unwrap();
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
        assert_eq!(
            Store::open(path.to_string_lossy().into())
                .unwrap()
                .device_id(),
            id
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
