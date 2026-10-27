import Foundation
import UIKit
import os

/// The app group the app and its extensions share, so the share sheet and the
/// Control Center button see the same history and pairing as the app.
let appGroup = "group.app.holtclip.Holt"

private let logger = Logger(subsystem: "app.holtclip.Holt", category: "spike")

/// The core, opened once per process. The app, the share extension and the controls
/// extension each run their own process, so each gets its own `Core.shared`.
@MainActor
final class Core {
    static let shared = Core()

    let store: Store
    private(set) var node: Node?

    private init() {
        let start = Date()
        store = try! Store.open(path: Self.container.appendingPathComponent("holt.db").path)
        do {
            node = try Node.start(store: store, deviceName: UIDevice.current.name)
            Core.log("core started in \(ms(since: start)) ms in the \(Core.process)")
        } catch {
            Core.log("core failed to start in the \(Core.process): \(error)")
        }
    }

    /// Records the clip, then waits for a paired Mac to connect so it leaves before iOS
    /// suspends us. Returns whether a Mac was connected.
    func send(_ text: String) async -> Bool {
        _ = try? store.add(text: text, sourceApp: nil)
        for _ in 0..<100 {
            if (try? node?.devices())?.contains(where: \.online) == true {
                // The core has no delivery receipt yet, so give the sync session a moment to write.
                try? await Task.sleep(for: .milliseconds(400))
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// The shared container. Unsigned Simulator builds have no app group, so they fall
    /// back to the process's own Application Support.
    /// The clipboard change Holt last sent or put there itself, shared with the
    /// extensions so the app doesn't offer a copy one of them already sent.
    static func markCopySeen() {
        UserDefaults(suiteName: appGroup)?.set(UIPasteboard.general.changeCount, forKey: seenCopyKey)
    }

    /// Text is on the clipboard that Holt hasn't sent. Asking doesn't show the paste prompt.
    static var hasNewCopy: Bool {
        let defaults = UserDefaults(suiteName: appGroup)
        // On first launch, whatever is on the clipboard is old news.
        guard defaults?.object(forKey: seenCopyKey) != nil else {
            markCopySeen()
            return false
        }
        let board = UIPasteboard.general
        return board.hasStrings && board.changeCount != defaults?.integer(forKey: seenCopyKey)
    }

    private static let seenCopyKey = "seenClipboardChange"

    static var container: URL {
        let url =
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holt", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "app", "share extension" or "controls extension", for the spike log.
    static var process: String {
        guard Bundle.main.bundlePath.hasSuffix(".appex") else { return "app" }
        return Bundle.main.bundleIdentifier?.hasSuffix(".share") == true ? "share extension" : "controls extension"
    }

    static var logFile: URL { container.appendingPathComponent("spike.log") }

    /// Logs to the unified log and to a file the app shows, so extension runs show up too.
    nonisolated static func log(_ line: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(2)))
        let entry = "\(stamp)  \(line)"
        logger.info("\(entry, privacy: .public)")
        guard let data = (entry + "\n").data(using: .utf8) else { return }
        let file = MainActor.assumeIsolated { logFile }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}

func ms(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1000)
}
