import AppIntents
import SwiftUI

/// Spike: how the core behaves on iPhone. Timings for starting, pairing, clips in both
/// directions, and runs of the actions and extensions all go to the shared spike log.
@main
struct HoltApp: App {
    @State private var spike = Spike()

    var body: some Scene {
        WindowGroup {
            SpikeView(spike: spike)
        }
    }
}

@MainActor
@Observable
final class Spike {
    private(set) var lines: [String] = []
    private(set) var clips: [Clip] = []
    private var seen = Set<Int64>()

    init() {
        _ = Core.shared
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Stand-in for scanning a QR code: `-HoltPair <device id> -HoltCode <code>`.
        if let id = UserDefaults.standard.string(forKey: "HoltPair"),
            let code = UserDefaults.standard.string(forKey: "HoltCode")
        {
            pair(id, code)
        }
    }

    func pair(_ id: String, _ code: String) {
        guard let node = Core.shared.node else { return }
        let start = Date()
        Core.log("pairing with \(id.prefix(12))…")
        Task.detached {
            let result = Result { try node.pair(deviceId: id, code: code) }
            await MainActor.run {
                switch result {
                case .success(let device):
                    Core.log("paired with \(device.name) in \(ms(since: start)) ms")
                    _ = try? Core.shared.store.add(
                        text: "from iPhone \(Int64(Date().timeIntervalSince1970 * 1000))", sourceApp: nil)
                    Core.log("sent a clip")
                case .failure(let error):
                    Core.log("pairing failed: \(error)")
                }
            }
        }
    }

    func tick() {
        clips = (try? Core.shared.store.search(query: "", limit: 50)) ?? []
        for clip in clips where clip.device != nil && seen.insert(clip.id).inserted {
            let delay = Int64(Date().timeIntervalSince1970 * 1000) - clip.createdAt
            Core.log("received \"\(clip.text)\" from \(clip.device!), \(delay) ms after it was copied")
        }
        let log = (try? String(contentsOf: Core.logFile, encoding: .utf8)) ?? ""
        lines = log.split(separator: "\n").map(String.init)
    }
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

struct HoltShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendClipboardToHolt(), phrases: ["Send clipboard to \(.applicationName)"],
            shortTitle: "Send Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(
            intent: SendToHolt(), phrases: ["Send to \(.applicationName)"], shortTitle: "Send to Holt",
            systemImageName: "paperplane")
    }
}
