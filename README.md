# Holt

[![CI](https://github.com/snowztech/holt/actions/workflows/ci.yml/badge.svg)](https://github.com/snowztech/holt/actions/workflows/ci.yml)

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
| ⇧⌘V | Open or close Holt (change it in Settings) |
| ↑ ↓ | Move |
| ⏎ | Paste |
| ⌘1 to ⌘9 | Paste that row (hold ⌘ to see the numbers) |
| ⌘O | Open a link |
| ⌘P | Pin or unpin |
| ⌘⌫ | Delete |
| esc | Close |

History lives in `~/Library/Application Support/Holt/holt.db`. Unpinned clips are kept for a month by default (change it in Settings → History), up to 5,000. Copies that password managers mark as private are never recorded, and you can add apps to ignore.

## Sync

Open **Settings → Devices** in Holt on both Macs. Each shows a 6-digit code and lists the other under Nearby. On one Mac, pick the other and type the code it shows.

After that the Macs stay connected:

- On the same Wi-Fi they talk directly over the local network.
- On different networks they connect over the internet, through a relay if a router blocks the direct path. Everything is end-to-end encrypted, so the relay only forwards bytes it can't read.

Copies, pins and deletes all sync. A clip copied in the last 2 minutes on another Mac goes straight onto this Mac's clipboard, so ⌘V just works. Clips also reach a Mac through any other paired device, so three Macs don't need to all be paired with each other.

The networking is [iroh](https://iroh.computer). The code is checked with SPAKE2, so someone on the same network gets one guess per attempt, and pairing stops after 5 wrong codes.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how the code fits together, how to work on the UI, and the checks CI runs (`make test`, `make lint`).

## Roadmap

- **M0** Mac history app
- **M1** Mac ↔ Mac sync over iroh (this)
- **M2** iPhone app
- **M3** Public release: notarized DMG, Homebrew cask
- **M4** Images, text search in screenshots, paste stack, transforms
- **M5** Windows and Linux

## License

MIT
