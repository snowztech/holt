# Changelog

Notable changes to Holt. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- An Alfred workflow. Type `holt` in Alfred to search your history and paste from it. It needs Alfred's Powerpack.

## [0.1.3] - 2026-10-27

Clips you save from Raycast now sync too.

### Changed

- The update window shows what's new in the release, instead of opening the GitHub page.

### Fixed

- Clips that the Raycast extension adds reach your other devices right away. Before, they waited until you copied something on the Mac.

## [0.1.2] - 2026-10-27

Holt for Mac is ready for the iPhone app, which is in testing now.

### Added

- Choose Light, Dark or System in Settings → General.
- Settings → Devices has a Copy button for the pairing code, and a QR code an iPhone can scan.

### Changed

- Settings → Devices covers every device you pair, and shows an iPhone icon for iPhones.

### Fixed

- A device that restarts reconnects to the others right away, instead of waiting up to half a minute.

## [0.1.1] - 2026-10-26

Holt now keeps itself up to date.

### Added

- Holt updates itself. It checks once a day, and when a new version is out, the menu bar menu offers it. Check for Updates in the same menu looks right away.
- Coming from 0.1.0, install this one update yourself: download it again, or run `brew upgrade --cask holt`. From here on, Holt does it for you.

## [0.1.0] - 2026-10-26

The first release. Holt keeps everything you copy on your Mac, and pairs your Macs so a copy on one is a paste on the other.

### Added

- Press ⇧⌘V to open Holt, type to search everything you copied, and press return to paste it into the app you were in. Every word you type has to match.
- Pin clips you reuse. Pinned clips stay at the top and never expire.
- ⌘1 to ⌘9 paste one of the first nine clips. Hold ⌘ to see the numbers.
- Pair your Macs in Settings → Devices with a 6-digit code. Copies, pins and deletes sync between them, over the same Wi-Fi or across the internet, end-to-end encrypted.
- A clip copied on another Mac in the last 2 minutes goes straight onto this Mac's clipboard, with a small notice saying where it came from.
- Copies that password managers mark as private are never recorded, and you can tell Holt to ignore any app.
- A first-launch checklist for the permissions Holt needs, and a setting to open Holt at login.
- Settings to change the shortcut and choose how long to keep history.

[Unreleased]: https://github.com/snowztech/holt/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/snowztech/holt/releases/tag/v0.1.3
[0.1.2]: https://github.com/snowztech/holt/releases/tag/v0.1.2
[0.1.1]: https://github.com/snowztech/holt/releases/tag/v0.1.1
[0.1.0]: https://github.com/snowztech/holt/releases/tag/v0.1.0
