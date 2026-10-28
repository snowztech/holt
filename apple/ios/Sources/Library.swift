import SwiftUI
import UIKit

/// What the app's screens show: the synced history, the paired Macs, and a short notice.
@MainActor
@Observable
final class Library {
    var query = "" {
        didSet { refresh() }
    }
    private(set) var clips: [Clip] = []
    private(set) var devices: [Device] = []
    /// A pairing link opened from the Camera, waiting for the pairing sheet.
    var pendingPairing: PairingLink?
    private(set) var notice: String?
    /// Text is on the clipboard that Holt hasn't sent yet. iOS says the clipboard changed
    /// without the paste prompt, so Holt can offer it without reading it.
    private(set) var newCopy = false
    private var arrived = Set<Int64>()

    init() {
        _ = Core.shared
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var paired: Bool { !devices.isEmpty }

    /// "Lucas's MacBook Pro", or "your 2 Macs". Sending reaches every paired device.
    var macs: String {
        devices.count == 1 ? devices[0].name : "your \(devices.count) Macs"
    }

    /// "Synced with MacBook Pro", like the Mac's popup footer.
    var syncStatus: (label: String, connected: Bool)? {
        guard paired else { return nil }
        let online = devices.filter(\.online)
        switch online.count {
        case 0: return ("Not connected to \(devices.count == 1 ? devices[0].name : "your Macs")", false)
        case 1: return ("Synced with \(online[0].name)", true)
        default: return ("Synced with \(online.count) Macs", true)
        }
    }

    func refresh() {
        // Assigning, even the same value, redraws every view that reads it. This runs every second.
        let clips = (try? Core.shared.store.search(query: query, limit: 300)) ?? []
        if clips != self.clips { self.clips = clips }
        let devices = (try? Core.shared.node?.devices()) ?? []
        if devices != self.devices { self.devices = devices }
        for clip in clips where clip.device != nil && arrived.insert(clip.id).inserted {
            let delay = Int64(Date().timeIntervalSince1970 * 1000) - clip.createdAt
            if delay < 10_000 { Core.log("received a clip from \(clip.device!), \(delay) ms after it was copied") }
        }
    }

    func copy(_ clip: Clip) {
        if let image = clip.image {
            // An image clip's text is only what was read in it.
            guard let bytes = FileManager.default.contents(atPath: image.path) else { return }
            UIPasteboard.general.setData(bytes, forPasteboardType: "public.\(image.format)")
        } else {
            UIPasteboard.general.string = clip.text
        }
        markCopySeen()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        show("Copied")
    }

    func togglePin(_ clip: Clip) {
        try? Core.shared.store.setPinned(id: clip.id, pinned: !clip.pinned)
        refresh()
    }

    func delete(_ clip: Clip) {
        try? Core.shared.store.delete(id: clip.id)
        refresh()
    }

    func send(_ text: String) async {
        markCopySeen()
        guard !text.isEmpty else { return }
        let start = Date()
        let connected = await Core.shared.send(text)
        Core.log("send from the app: done in \(ms(since: start)) ms, connected: \(connected)")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        show(connected ? "Sent to \(macs)" : "Saved. It goes once \(macs) connects.")
        refresh()
    }

    /// Returns an error to show, or nil when paired.
    func pair(_ link: PairingLink) async -> String? {
        guard let node = Core.shared.node else { return "Holt couldn't start its connection. Try again in a moment." }
        let start = Date()
        let result = await Task.detached { Result { try node.pair(deviceId: link.id, code: link.code) } }.value
        refresh()
        switch result {
        case .success(let device):
            Core.log("paired with \(device.name) in \(ms(since: start)) ms")
            return nil
        case .failure(let error):
            Core.log("pairing failed: \(error)")
            if case HoltError.Pairing(let message) = error { return message }
            return "Pairing failed. Check that your Mac still shows its code."
        }
    }

    func removeDevice(_ device: Device) {
        try? Core.shared.node?.removeDevice(deviceId: device.id)
        refresh()
    }

    func checkForNewCopy() {
        newCopy = Core.hasNewCopy
    }

    func markCopySeen() {
        Core.markCopySeen()
        newCopy = false
    }

    private func show(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if notice == message { notice = nil }
        }
    }
}

/// `holt://pair?id=…&code=…` from the QR code on the Mac, or the test peer's `pair: <id> <code>`.
struct PairingLink: Identifiable, Equatable {
    let id: String
    let code: String

    init(id: String, code: String) {
        self.id = id
        self.code = code
    }

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme == "holt",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let id = items.first(where: { $0.name == "id" })?.value,
            let code = items.first(where: { $0.name == "code" })?.value
        {
            self.id = id
            self.code = code
            return
        }
        let parts = trimmed.replacingOccurrences(of: "pair:", with: "").split(separator: " ")
        guard parts.count == 2 else { return nil }
        id = String(parts[0])
        code = String(parts[1])
    }
}

extension Device: Identifiable {}
