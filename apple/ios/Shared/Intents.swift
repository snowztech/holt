import AppIntents
import UIKit

/// The zero-setup way: installed with the app, in Spotlight, Siri, Shortcuts, the Action
/// Button and the Control Center button. It reads the clipboard itself, so iOS asks
/// "Allow Paste?" unless the user sets Settings → Holt → Paste from Other Apps → Allow.
struct SendClipboardToHolt: AppIntent {
    static let title: LocalizedStringResource = "Send Clipboard to Holt"
    static let description = IntentDescription("Sends what you copied to your paired Macs.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let start = Date()
        Core.log("send clipboard: started in the \(Core.process)")
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            Core.log("send clipboard: nothing to send, or paste not allowed (\(ms(since: start)) ms)")
            return .result(dialog: "There's no text on the clipboard.")
        }
        Core.log("send clipboard: read the clipboard in \(ms(since: start)) ms")
        let connected = await Core.shared.send(text)
        Core.log("send clipboard: done in \(ms(since: start)) ms, connected: \(connected)")
        return .result(dialog: connected ? "Sent to your Mac" : "Saved. It goes to your Mac when it's reachable.")
    }
}

/// Takes text, for a Shortcut that runs Get Clipboard first. No paste prompt.
struct SendToHolt: AppIntent {
    static let title: LocalizedStringResource = "Send to Holt"
    static let description = IntentDescription("Sends text to your paired Macs.")
    static let openAppWhenRun = false

    @Parameter(title: "Text") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let start = Date()
        Core.log("send text: started in the \(Core.process)")
        let connected = await Core.shared.send(text)
        Core.log("send text: done in \(ms(since: start)) ms, connected: \(connected)")
        return .result(dialog: connected ? "Sent to your Mac" : "Saved. It goes to your Mac when it's reachable.")
    }
}
