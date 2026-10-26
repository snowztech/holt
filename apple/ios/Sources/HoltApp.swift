import AppIntents
import SwiftUI
import UIKit
import os

private let log = Logger(subsystem: "app.holtclip.Holt", category: "spike")

/// Spike: how the core behaves on iPhone. It logs timings for starting, pairing
/// and clips in both directions, to the screen and to Documents/spike.log.
@main
struct HoltApp: App {
    @State private var spike = Spike.shared

    var body: some Scene {
        WindowGroup {
            SpikeView(spike: spike)
        }
    }
}

@MainActor
@Observable
final class Spike {
    static let shared = Spike()

    private(set) var lines: [String] = []
    private(set) var clips: [Clip] = []
    let store: Store
    private(set) var node: Node?
    private let started = Date()
    private var seen = Set<Int64>()

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try! Store.open(path: dir.appendingPathComponent("holt.db").path)
        do {
            node = try Node.start(store: store, deviceName: UIDevice.current.name)
            note("node started in \(ms(since: started)) ms, id \(node!.deviceId().prefix(12))…")
        } catch {
            note("node failed to start: \(error)")
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { Spike.shared.tick() }
        }
        // Stand-in for scanning a QR code: `-HoltPair <device id> -HoltCode <code>`.
        if let id = UserDefaults.standard.string(forKey: "HoltPair"),
            let code = UserDefaults.standard.string(forKey: "HoltCode")
        {
            pair(id, code)
        }
    }

    func pair(_ id: String, _ code: String) {
        guard let node else { return }
        let start = Date()
        note("pairing with \(id.prefix(12))…")
        Task.detached {
            let result = Result { try node.pair(deviceId: id, code: code) }
            await MainActor.run {
                switch result {
                case .success(let device):
                    self.note("paired with \(device.name) in \(ms(since: start)) ms")
                    _ = try? self.store.add(text: "from iPhone \(Int64(Date().timeIntervalSince1970 * 1000))", sourceApp: nil)
                    self.note("sent a clip")
                case .failure(let error):
                    self.note("pairing failed: \(error)")
                }
            }
        }
    }

    /// Records the clip, then waits for a paired Mac to connect so it leaves before iOS
    /// suspends Holt. Returns whether a Mac was connected.
    func send(_ text: String) async throws -> Bool {
        _ = try store.add(text: text, sourceApp: nil)
        for _ in 0..<100 {
            if (try? node?.devices())?.contains(where: \.online) == true {
                // The core has no delivery receipt yet, so give the sync session a moment to write.
                try await Task.sleep(for: .milliseconds(400))
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func tick() {
        clips = (try? store.search(query: "", limit: 50)) ?? []
        for clip in clips where clip.device != nil && seen.insert(clip.id).inserted {
            note(
                "received \"\(clip.text)\" from \(clip.device!), \(Int64(Date().timeIntervalSince1970 * 1000) - clip.createdAt) ms after it was copied"
            )
        }
    }

    func note(_ line: String) {
        let stamped = String(format: "%7.2fs  ", Date().timeIntervalSince(started)) + line
        lines.append(stamped)
        log.info("\(stamped, privacy: .public)")
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("spike.log")
        if let data = (stamped + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
    }
}

private func ms(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1000)
}

struct SpikeView: View {
    let spike: Spike
    @State private var pairing = ""

    var body: some View {
        NavigationStack {
            List {
                // Stand-in for scanning a QR code: paste the "pair:" line the test peer prints.
                Section("Pair") {
                    TextField("pair: <device id> <code>", text: $pairing)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Pair") {
                        let parts = pairing.replacingOccurrences(of: "pair:", with: "").split(separator: " ")
                        if parts.count == 2 { spike.pair(String(parts[0]), String(parts[1])) }
                    }
                }
                Section("Log") {
                    ForEach(Array(spike.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
                Section("Clips") {
                    ForEach(spike.clips, id: \.id) { clip in
                        VStack(alignment: .leading) {
                            Text(clip.text).lineLimit(2)
                            Text(clip.device ?? "this iPhone").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Holt spike")
        }
    }
}

/// The Back Tap question: a Shortcut does Get Clipboard, then this. Holt never reads
/// the clipboard itself, so iOS shows no paste prompt.
struct SendToHolt: AppIntent {
    static let title: LocalizedStringResource = "Send to Holt"
    static let description = IntentDescription("Sends text to your paired Macs.")
    static let openAppWhenRun = false

    @Parameter(title: "Text") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let spike = Spike.shared
        let start = Date()
        spike.note("intent: started")
        let connected = try await spike.send(text)
        spike.note("intent: done in \(ms(since: start)) ms, connected: \(connected)")
        return .result(dialog: connected ? "Sent to your Mac" : "Saved. It goes to your Mac when it's reachable.")
    }
}

/// The zero-setup way: installed with the app, in Spotlight, Siri, Shortcuts and the
/// Action Button. It reads the clipboard itself, so iOS asks "Allow Paste?" unless the
/// user sets Settings → Holt → Paste from Other Apps → Allow.
struct SendClipboardToHolt: AppIntent {
    static let title: LocalizedStringResource = "Send Clipboard to Holt"
    static let description = IntentDescription("Sends what you copied to your paired Macs.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let spike = Spike.shared
        let start = Date()
        spike.note("clipboard intent: started")
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            spike.note("clipboard intent: nothing to send, or paste not allowed (\(ms(since: start)) ms)")
            return .result(dialog: "There's no text on the clipboard.")
        }
        spike.note("clipboard intent: read the clipboard in \(ms(since: start)) ms")
        let connected = try await spike.send(text)
        spike.note("clipboard intent: done in \(ms(since: start)) ms, connected: \(connected)")
        return .result(dialog: connected ? "Sent to your Mac" : "Saved. It goes to your Mac when it's reachable.")
    }
}

struct HoltShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendClipboardToHolt(), phrases: ["Send clipboard to \(.applicationName)"],
            shortTitle: "Send Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(
            intent: SendToHolt(), phrases: ["Send to \(.applicationName)"], shortTitle: "Send to Holt", systemImageName: "paperplane")
    }
}
