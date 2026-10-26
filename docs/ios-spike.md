# iPhone spike

What we needed to know before building the iPhone app, and what we found. Run it with
`make ios`, and `cd core && cargo run --release --example peer` for a stand-in Mac.

## 1. Does the core build for iOS?

Yes, with one pin. `libc` 0.2.190 made the `net/route.h` constants and `in6_ifreq`
macOS-only, and iroh's `netwatch` and `netdev` use them on iOS too. `holt-core` pins
`libc = "=0.2.189"` until those crates handle it.

mDNS is now best effort in `Node::start`. On a real iPhone, raw multicast needs Apple's
multicast entitlement, so without it the Nearby list stays empty instead of the app
failing to start. The iPhone pairs by QR code, which carries the Mac's id directly.

## 2. Pairing and sync from an iPhone app (Simulator)

| What | Time |
| --- | --- |
| Starting the core | 91 ms |
| Pairing with the test Mac | 651 ms |
| A clip from iPhone to Mac | 32 ms after it was copied |
| A clip from Mac to iPhone | 17 ms after it was copied |

Pairing found the peer through iroh's internet discovery, without mDNS.

## 3. Sending from the iPhone (needs a real iPhone)

iOS never tells an app that something was copied, so "copy and it's on the Mac" isn't
possible. The closest is copy, then one press. The app ships two actions:

- **Send Clipboard to Holt** reads the clipboard itself. It installs with the app, with
  no setup: Spotlight, Siri, the Shortcuts app, and the Action Button. iOS asks "Allow
  Paste?" each time unless the user sets Settings → Holt → Paste from Other Apps → Allow.
- **Send to Holt** takes text, for a Shortcut that runs Get Clipboard first. No paste
  prompt, but the user builds the shortcut, or adds ours from a link.

Still to measure on a phone: whether each action connects and sends before iOS suspends
Holt, and whether Back Tap can pick an App Shortcut directly or only a library shortcut.

## 4. Receiving on the phone (needs a real iPhone)

iOS doesn't keep apps connected in the background. Clips arrive when Holt opens, in well
under a second. Notifications for new clips would need a small push service. To decide
after testing 3.
