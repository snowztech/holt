# Holt

An open-source clipboard history for macOS. Press ⇧⌘V, find anything you copied, paste it.

Pair your Macs and what you copy on one is on the other's clipboard a moment later. iPhone and Windows/Linux are next. See the roadmap below.

## Run it

You need Xcode and Rust (`rustup`).

```sh
make run
```

That builds the Rust core, generates the Swift bindings, builds `build/Holt.app`, signs it and opens it.

On first launch macOS needs two permissions:

- **Paste from Other Apps** (macOS 15.4+): set Holt to Always Allow in System Settings → Privacy & Security. Without it, macOS asks on every copy and Holt records nothing.
- **Accessibility** (optional): lets Holt paste into the app you're in. Without it, picking a clip puts it on the clipboard and you press ⌘V.
- **Local Network**: lets Holt find your other Macs to pair with them.

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

## Sync

Open **Devices…** from the menu bar on both Macs. Each shows a 6-digit code and lists the other under Nearby. On one Mac, pick the other and type the code it shows.

After that the Macs stay connected:

- On the same Wi-Fi they talk directly over the local network.
- On different networks they connect over the internet, through a relay if a router blocks the direct path. Everything is end-to-end encrypted, so the relay only forwards bytes it can't read.

Copies, pins and deletes all sync. A clip copied in the last 2 minutes on another Mac goes straight onto this Mac's clipboard, so ⌘V just works. Clips also reach a Mac through any other paired device, so three Macs don't need to all be paired with each other.

The networking is [iroh](https://iroh.computer). The code is checked with SPAKE2, so someone on the same network gets one guess per attempt, and pairing stops after 5 wrong codes.

## Layout

```
core/holt-core/   Rust: storage, search, pairing and sync, exposed to Swift with UniFFI
apple/            SwiftPM package: the menu bar app
Makefile          core, mac, run, test, clean
```

`make test` runs the core tests. `cargo test -- --ignored real_network` in `core/` also pairs and syncs two nodes over your real network. `make icon` redraws `apple/AppIcon.icns` from the Skip drawing in `Brand.swift`.

## Roadmap

- **M0** Mac history app
- **M1** Mac ↔ Mac sync over iroh (this)
- **M2** iPhone app
- **M3** Public release: notarized DMG, Homebrew cask
- **M4** Images, text search in screenshots, paste stack, transforms
- **M5** Windows and Linux

## License

MIT
