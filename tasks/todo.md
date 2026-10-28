# Images in Holt

Design: docs/superpowers/specs/2026-10-28-images-design.md

## Core (Rust)
- [x] Migration v3: columns width, height, bytes, format, thumb
- [x] ClipKind::Image, ImageInfo on Clip, clip_from_row
- [x] images/ dir next to the db, file write/delete helpers, sweep on open
- [x] add_image (key = blake3(bytes), cap 10 MB)
- [x] tombstone / prune / clear remove files
- [x] Row: image, format, width, height, thumb (serde default); rows_since loads file; apply verifies and writes it
- [x] batches sizes by image length
- [x] IncomingCopy carries image bytes + format
- [x] Tests: dedup, cap, file lifecycle, search by OCR, sync both ways + incoming, bad key rejected, sweep on open

## Mac app (Swift)
- [x] Clipboard.swift: read image per item (png, jpeg, heic, tiff→png, file url), background pipeline (size, thumbnail, OCR), addImage
- [x] put(image:) with png + tiff + original + source marker; incoming copy with image
- [x] Popup: row thumbnail + label, preview pane, ⌘O opens in Preview, action bar
- [x] Menu "Recent" and toast labels for images
- [x] Settings → History: "Record images" toggle
- [x] Raycast sql.ts excludes kind 2 + test; iOS compiles (nothing builds Clip by hand)
- [x] Swift test target (apple/Tests/HoltTests): prepare, TIFF→PNG, thumbnail, OCR, pasteboard read/write

## Verify
- [x] make lint, make test (cargo 22 tests + swift 9 tests), make mac
- [ ] Manual by Mathias: screenshot → ⇧⌘V → return pastes in TextEdit and a browser; search by OCR word; ⌘O
- [x] README: What it does, ⌘O, Privacy, roadmap

## Review
- Core: image rows reuse the text path (text = OCR text), so search, pins, deletes and Raycast's SQL need no new logic.
- Sync: an image row carries its bytes base64 in the JSON row (10 MB cap → 13.4 MB, under the 16 MB frame). Old peers drop image rows silently and keep syncing text.
- Not done, on purpose: file URL on paste back (Electron editors paste a file instead), iPhone display of images, Raycast images.
