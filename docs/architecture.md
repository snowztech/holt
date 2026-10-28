# How Holt works

Holt keeps what you copy and shares it between your own devices. There's no Holt server and no account. Your devices talk to each other directly.

![How a clip travels between your devices](flow.png)

## On each device

Every device runs the same small core, written in Rust. It does two jobs:

- **Keeping history.** Your clips live in one file on the device, `holt.db`, a SQLite database. Search, pins and deletes all happen there.
- **Talking to your other devices.** Pairing them, then keeping them up to date.

The Mac app and the iPhone app are the parts you see. They put copies into the history and show what's in it.

## Capturing a copy

**On a Mac**, Holt checks the clipboard twice a second. Anything new goes into the history. It skips copies that password managers mark as private, apps you told it to ignore, and anything over 1 MB.

**On an iPhone**, iOS doesn't let apps read the clipboard in the background. So Holt can't notice your copies. You send one yourself: tap Paste in Holt, or use the Control Center button, Back Tap, the Action Button or the share sheet.

## Pairing

Pairing is how a device learns which other devices it can trust. You do it once per device.

1. On the Mac, Settings → Devices shows a 6-digit code and a QR code.
2. The other device scans the QR code, or finds the Mac nearby and you type the code.
3. Both sides check the code without ever sending it, using a method called SPAKE2. Someone listening on the network learns nothing, and 5 wrong codes stop the attempt.

After that, each device remembers the other by its ID, a cryptographic key it made for itself. Only paired devices can connect.

## Syncing

When two paired devices connect, they compare notes and send each other only what's missing.

- Every change, a new clip, a pin or a delete, is numbered by the device that made it.
- On connect, each side says how far it has got with every device. The other sends the rest.
- Devices pass along changes from every device, not just their own. If your iPhone only reaches one Mac, that Mac hands its clips to your other Macs.
- If the same clip was changed in two places, the newest change wins.

A clip that arrives from another device within 2 minutes of being copied also goes straight onto the Mac's clipboard, so ⌘V pastes it.

## Reaching your other devices

The connection is handled by [iroh](https://iroh.computer), an open-source library. You give it a device ID and it finds the way:

1. **Same Wi-Fi:** the devices talk directly over your network.
2. **Different networks:** they find each other through iroh's discovery service and connect directly across the internet.
3. **Something in the way**, like a strict router or office firewall: the traffic goes through an iroh relay.

Every connection is end-to-end encrypted. The discovery service and relays are run by n0, the team behind iroh. They see your devices' network addresses, never your clips.

## Limits worth knowing

- The iPhone syncs while Holt is open, or for a moment when you send from Control Center or the share sheet. iOS stops it in the background.
- A clip reaches a device once some device that has it connects to it. Two devices that are never online at the same time, and have no third device in common, wait for each other.
- Holt keeps text only for now. Images are on the roadmap.

## Where it is in the code

![The pieces in each app](architecture.png)

| What | Where |
|---|---|
| History, search, merge rules | `core/holt-core/src/lib.rs` |
| Pairing and sync | `core/holt-core/src/net.rs` |
| Mac clipboard watcher | `apple/Sources/Holt/Clipboard.swift` |
| Mac pairing screen and Bonjour | `apple/Sources/Holt/Devices.swift` |
| iPhone app | `apple/ios/Sources/` |
| iPhone extensions and shared core | `apple/ios/Shared/`, `apple/ios/Share/`, `apple/ios/Controls/` |

Both diagrams come from [Archify](https://github.com/tt-a1i/archify) specs, `flow.json` and `architecture.json`, in this folder.
