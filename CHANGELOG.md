# Changelog

Notable changes to Holt. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.7] - 2026-10-28

The ⌘I panel in plain words.

### Changed

- The ⌘I panel says whether a clip came over the same network, over the internet or through a relay, in one line per arrival. Hover over a line for the exact time and address.

### Fixed

- ⌘, opens Settings while the popup is open.

## [0.1.6] - 2026-10-28

See how a clip got to your Mac.

### Added

- Press ⌘I in the popup to see when and where a clip was copied, and how it reached this Mac: through Universal Clipboard, or from a paired device directly or through a relay, and how long that took.

## [0.1.5] - 2026-10-28

Images work the way you'd expect: from Finder, from your iPhone, and the right way up.

### Added

- Copy an image file in Finder and Holt keeps the picture, not the file name.
- The preview shows images larger. While you search, it shows the text found in the image, with your words in bold.
- Copies that arrive through Universal Clipboard say so, instead of naming the app that was in front.

### Fixed

- Photos from an iPhone are measured and pasted the right way up. Before, most apps got them sideways.
- Image rows are titled by their size, instead of the text read in them.
- A clip copied seconds ago says "just now", not "in 0 seconds".

## [0.1.4] - 2026-10-28

Holt keeps the images you copy now, and works from Alfred.

### Added

- Screenshots and images you copy are kept in your history, and search finds them by the text in them. Turn it off in Settings → History.
- Press Space on an image in the popup or the menu bar menu to see it full size. ⌘O opens it in Preview.
- Drag a clip out of the popup or the menu bar menu into any app.
- Images sync to your other devices once they run this version too.
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

[Unreleased]: https://github.com/snowztech/holt/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/snowztech/holt/releases/tag/v0.1.7
[0.1.6]: https://github.com/snowztech/holt/releases/tag/v0.1.6
[0.1.5]: https://github.com/snowztech/holt/releases/tag/v0.1.5
[0.1.4]: https://github.com/snowztech/holt/releases/tag/v0.1.4
[0.1.3]: https://github.com/snowztech/holt/releases/tag/v0.1.3
[0.1.2]: https://github.com/snowztech/holt/releases/tag/v0.1.2
[0.1.1]: https://github.com/snowztech/holt/releases/tag/v0.1.1
[0.1.0]: https://github.com/snowztech/holt/releases/tag/v0.1.0
