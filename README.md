# Holt

An open-source clipboard history for macOS. Press ⇧⌘V, find anything you copied, paste it.

Sync between Macs, iPhone and Windows/Linux is next. See the roadmap below.

## Run it

You need Xcode and Rust (`rustup`).

```sh
make run
```

That builds the Rust core, generates the Swift bindings, builds `build/Holt.app`, signs it and opens it.

On first launch macOS needs two permissions:

- **Paste from Other Apps** (macOS 15.4+): set Holt to Always Allow in System Settings → Privacy & Security. Without it, macOS asks on every copy and Holt records nothing.
- **Accessibility** (optional): lets Holt paste into the app you're in. Without it, picking a clip puts it on the clipboard and you press ⌘V.

The Makefile signs with your Apple Development certificate when you have one, so macOS remembers these permissions across rebuilds. With ad-hoc signing you have to grant them again after every build.

## Keys

| Key | Action |
| --- | --- |
| ⇧⌘V | Open or close Holt |
| ↑ ↓ | Move |
| ⏎ | Paste |
| ⌘1 to ⌘9 | Paste that row |
| ⌘P | Pin or unpin |
| ⌘⌫ | Delete |
| esc | Close |

History lives in `~/Library/Application Support/Holt/holt.db`. Unpinned clips are pruned after 30 days or past 5,000 clips. Copies marked concealed by password managers are never recorded.

## Layout

```
core/holt-core/   Rust: storage and search, exposed to Swift with UniFFI
apple/            SwiftPM package: the menu bar app
Makefile          core, mac, run, test, clean
```

`make test` runs the core tests.

## Roadmap

- **M0** Mac history app (this)
- **M1** Mac ↔ Mac sync over iroh, QR pairing, `holt` CLI
- **M2** iPhone app
- **M3** Public release: notarized DMG, Homebrew cask
- **M4** Images, text search in screenshots, paste stack, transforms
- **M5** Windows and Linux

## License

MIT
