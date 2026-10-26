<p align="center">
  <img src="site/assets/icon-512.png" width="128" alt="Holt's icon: Skip the otter, holding a pebble">
</p>

<h1 align="center">Holt</h1>

<p align="center">
  <strong>Your clipboard, kept.</strong><br>
  Clipboard history for macOS, synced between your Macs. Free and open source.
</p>

<p align="center">
  <a href="https://github.com/snowztech/holt/actions/workflows/ci.yml"><img src="https://github.com/snowztech/holt/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2E9C93" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-2E9C93?logo=apple" alt="macOS 14 or later">
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="site/assets/popup-light.png">
    <img src="site/assets/popup-dark.png" width="540" alt="Holt's popup: a search field, recent clips with the app and Mac they came from, a preview of the selected link, and a notice that a clip arrived from a MacBook Pro">
  </picture>
</p>

## What it does

- **Find anything you copied.** Press ⇧⌘V and start typing. Every word has to match, so `ssh 10.0` finds that one command from last week.
- **Paste where you were.** Pick a clip and press return. Holt pastes it into the app you were typing in.
- **Pin what you reuse.** Pinned clips stay at the top and never expire.
- **On every Mac.** Pair your Macs once. Copy on one, press ⌘V on the other a second later.
- **Private.** No account and no Holt server. Copies that password managers mark as private are never recorded.

## Install

The first signed download comes with the first release. Until then, build it with one command:

```sh
git clone https://github.com/snowztech/holt
cd holt
make run
```

You need macOS 14 or later, Xcode and Rust ([rustup.rs](https://rustup.rs)).

On first launch, a short checklist walks you through setup:

- **See what you copy.** Required. Set Holt to Always Allow in System Settings → Privacy & Security → Paste from Other Apps. Without it, macOS asks on every copy.
- **Paste for you.** Optional. Accessibility access lets Holt paste into the app you're in. Without it, Holt copies the clip and you press ⌘V.
- **Open at login.** So Holt never misses a copy after a restart.

## Keys

| Key | What it does |
| --- | --- |
| ⇧⌘V | Open Holt. Change it in Settings → General. |
| ↑ ↓ | Move through clips |
| ↩ | Paste the clip |
| ⌘1 to ⌘9 | Paste one of the first nine. Hold ⌘ to see the numbers. |
| ⌘P | Pin or unpin |
| ⌘O | Open a link |
| ⌘⌫ | Delete, here and on your other Macs |
| esc | Close |

## Sync between Macs

Open **Settings → Devices** in Holt on both Macs. Each one shows a 6-digit code and lists the other under Nearby. On one Mac, pick the other and type the code it shows. That's it.

After that the Macs stay connected, and Holt never uses Bluetooth:

- **Same Wi-Fi.** They talk directly over your local network.
- **Different networks.** They connect directly over the internet.
- **A router in the way.** A relay passes the data along. Sync is end-to-end encrypted, so the relay only sees bytes it can't read.

Copies, pins and deletes all sync. A clip copied on another Mac in the last 2 minutes goes straight onto this Mac's clipboard, and a small notice says where it came from.

Under the hood, the connection is [iroh](https://iroh.computer). The pairing code is checked with SPAKE2, so someone on the same network gets one guess per try, and pairing stops after 5 wrong codes.

## Meet Skip

A holt is an otter's den, where it keeps what matters. Sea otters even carry a favorite stone tucked under their arm, everywhere they go.

Skip does the same with what you copy: keeps it safe, and skips it across to your other Mac. Skip's face is the icon in your menu bar.

## Roadmap

- [x] Clipboard history on the Mac
- [x] Sync between Macs
- [ ] Signed download and Homebrew
- [ ] iPhone app
- [ ] Images, and search for the text inside screenshots
- [ ] Windows and Linux

## Contributing

Bug reports, ideas and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains how the code fits together, how to work on the UI, and the checks CI runs.

History lives in `~/Library/Application Support/Holt/holt.db` if you want to look.

## License

MIT. Made by [snowztech](https://github.com/snowztech).
