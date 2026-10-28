# Images in Holt

## Intent

Holt records only text today (`Clipboard.swift` reads `.string` and nothing else). Screenshots, images copied from a browser or Preview, and images pasted from the iPhone all vanish. The roadmap lists "Images, and search for the text inside screenshots". This design adds image clips end to end: capture, history, preview, paste back, sync between Macs, and OCR so a screenshot is found by the words in it.

## Goals

- Copy an image anywhere, find it in Holt, paste it back where you are.
- Search finds screenshots by the text inside them (Apple Vision OCR, local).
- Images sync between paired Macs like text does, including the "copied in the last 2 minutes goes straight onto the other Mac's clipboard" behaviour.
- History stays small: never store TIFF, keep a tiny thumbnail per clip, cap the size.
- Old Holt versions on the other Mac keep working (they just don't see images).

## Non-goals

- Files (Finder copies of non-image files), rich text, HTML, colors. Text wins when an item carries both text and an image; this keeps today's behaviour for Finder, Word and the like.
- Editing, annotating, or converting images.
- iPhone: the iOS app only needs to compile and not show garbage for image rows. Full iPhone support is a later change.
- Settings beyond one toggle.

## Anti-goals

- A history that grows to hundreds of megabytes (Maccy stores raw TIFF; a 1 MB PNG arrives as a 3.8 MB TIFF).
- Decoding full-size images to draw a list row (Maccy's memory problems, PRs #1458/#1550/#1575).
- Breaking sync with a Mac that runs an older Holt.

## What the user sees

- **Capture.** Press ⇧⌘4, or copy an image in Chrome, Preview, Photos, Slack. Half a second later it is in Holt.
- **List row.** A thumbnail (at most 40 pt tall, 120 pt wide), then "1920×1080 · PNG" (or the first line of the OCR text when there is one, with the dimensions moved to the right side), then app icon, device, age, as for text.
- **Preview pane.** The image fitted in the pane, then "Chrome · MacBook Pro · 3 min ago", then "1920×1080 · PNG · 412 KB", then the OCR text if any, scrollable.
- **Return** pastes the image. **⌘O** opens it in Preview. ⌘P pins, ⌘⌫ deletes, as before.
- **Search.** Every word must match the OCR text. `invoice 2026` finds the screenshot of the invoice.
- **Other Mac.** A screenshot taken on the MacBook is on the iMac's clipboard a second later, with the "From MacBook Pro" notice showing a thumbnail.
- **Menu bar "Recent"** shows "Image 1920×1080" for image clips.
- **Settings → History**: "Record images" toggle, on by default. Images over 10 MB are skipped, said in the toggle's footnote.

## How it works

### Capture (Swift, `Clipboard.swift`)

Polling stays at 0.5 s on `changeCount`. On a change, per `NSPasteboardItem` (not `pasteboard.types`, which is the union):

1. Skip if any `org.nspasteboard.*` marker or Holt's own marker is present.
2. If the item has a non-blank `.string`, it is a text clip. Done (today's path).
3. Otherwise look for an image, in this order:
   - `public.png` → keep bytes as is, format `png`.
   - `public.jpeg`, `public.heic` → keep bytes as is.
   - `public.tiff` → decode with ImageIO and re-encode as PNG, keeping the DPI so a Retina screenshot pastes at the right size.
   - `public.file-url` whose extension is png/jpg/jpeg/heic/gif/webp/tiff → read the file bytes (TIFF re-encoded). Skip Universal Clipboard temp files (`com.apple.is-remote-clipboard` with a file URL): Clipy found their sandbox extension does not survive.
4. Read the bytes on the main thread (fast); everything else on a utility queue: pixel size, thumbnail with `CGImageSourceCreateThumbnailAtIndex` (max 240×80 px, JPEG quality 0.8, PNG if it has alpha), OCR with `VNRecognizeTextRequest` (`.accurate`, automatic language detection, capped at 10 000 chars), then `store.addImage(...)`.
5. Images over 10 MB (after PNG re-encoding) are skipped.

### Paste back

`put(image:)` writes one `NSPasteboardItem` with `public.png` (always; re-encoded if the original is JPEG/HEIC so Electron apps accept it), the original bytes under their own type when not PNG, `public.tiff` (an `NSBitmapImageRep` representation, for older AppKit apps), Holt's marker type `app.holt.clip` and `org.nspasteboard.source` = the original app's bundle id. No file URL: Inkdrop/Joplin-style editors paste a file instead of the image when one is present. Then the usual ⌘V keystroke.

### Core (Rust, `lib.rs`)

- `ClipKind::Image` (stored as 2). `Clip` gains `image: Option<ImageInfo>` with `width`, `height`, `bytes`, `format`, `path` (absolute path of the stored file) and `thumb: Vec<u8>`.
- `text` of an image clip is its OCR text (may be empty). Search is unchanged: the LIKE scan over `text` already finds images by their words. Raycast and iOS keep reading `text` without crashing.
- Key = BLAKE3 of the stored bytes, so the same screenshot copied twice is one clip that moves to the top, and `apply` can verify an image row the way it verifies text.
- Bytes live on disk: `<db dir>/images/<key>.<ext>`. The DB row stores `width`, `height`, `bytes`, `format`, `thumb BLOB`. Migration v3 adds those five columns.
- `add_image(bytes, format, width, height, thumb, ocr_text, source_app) -> Option<Clip>` writes the file (skipped if it exists), then the same upsert as text.
- Tombstone and prune remove the file. `open` sweeps `images/` for files without a live row.
- `MAX_IMAGE_BYTES = 10 << 20`.

### Sync (`net.rs`, `Row`)

- `Row` gains `#[serde(default)]` fields: `image: Option<String>` (base64 of the file), `format`, `width`, `height`, `thumb: Option<String>` (base64). `rows_since` reads the file for live image rows; `apply` decodes, checks `blake3(bytes) == key`, writes the file.
- `batches` sizes a row by `text.len() + image.len() + 200`, so an image row goes alone in its message. 10 MB → 13.4 MB base64, under the 16 MB frame cap.
- Old peers: serde ignores the unknown fields, then `key_of(text) != key` so they drop the row and advance their cursor. They never see images and never break. New peers accept old rows unchanged.
- `IncomingCopy` gains `image: Option<Vec<u8>>` and `format`, so the receiving Mac puts the image on its clipboard.

### UI (`Popup.swift`, `App.swift`, `Toast.swift`, `Settings.swift`)

- `ClipRow`: thumbnail from `clip.image.thumb` (NSImage from Data, never the file). Label from OCR first line or "W×H · PNG".
- `ClipPreview`: decode the file with ImageIO at the pane's pixel size, cache the last one; metadata lines; OCR text below.
- `ActionBar`: "Open ⌘O" for images too (opens the file with `NSWorkspace`).
- Menu "Recent" and toast: "Image W×H".
- `Prefs.recordImages`, toggle in Settings → History.

### Raycast, iOS

- `raycast/src/sql.ts`: `AND kind != 2` for now, with the test updated. The extension gets images in a later change.
- iOS: switches over `ClipKind` get an `.image` case that renders "Image W×H"; nothing else.

## Decisions the builder makes

- Thumbnail exact size and JPEG vs PNG choice per alpha.
- Whether OCR runs before `addImage` (simpler, one write) or after (clip appears sooner). Start with before; a screenshot's OCR takes under 0.3 s on Apple Silicon.
- Exact wording of the settings footnote.

## Tests

- Core: `add_image` dedups by bytes, skips over the cap, stores a file and removes it on delete/prune; search finds an image by OCR text; an image syncs both ways in the in-memory `sync()` helper, including the file and the incoming copy; a row with wrong bytes for its key is rejected; `migrates` from v2.
- Raycast: `sql.test.ts` excludes `kind = 2`.
- Swift has no test target; verification is `make lint`, `make mac`, then a manual check: ⇧⌘4 a region, ⇧⌘V shows it, return pastes it into TextEdit and Slack, search by a word on screen finds it.
