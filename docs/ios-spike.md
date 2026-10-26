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

## 3. Sending from Back Tap (needs a real iPhone)

A Shortcut runs Get Clipboard, then the app's "Send to Holt" action with that text. Holt
never reads the clipboard itself, so iOS shows no paste prompt. Still to measure on a
phone: whether the action connects and sends before iOS suspends the app.

## 4. Receiving on the phone (needs a real iPhone)

iOS doesn't keep apps connected in the background. Clips arrive when Holt opens, in well
under a second. Notifications for new clips would need a small push service. To decide
after testing 3.
