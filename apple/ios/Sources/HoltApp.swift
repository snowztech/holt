import AppIntents
import SwiftUI

@main
struct HoltApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            HomeView(library: library)
                .tint(Brand.river)
                // The QR code in Holt on the Mac opens holt://pair?id=…&code=… here.
                .onOpenURL { url in
                    library.pendingPairing = PairingLink(url.absoluteString)
                }
                // For development: `-HoltPairLink "holt://pair?…"` pairs as if the Camera opened it.
                .task {
                    Appearance.apply()
                    if let link = UserDefaults.standard.string(forKey: "HoltPairLink") {
                        library.pendingPairing = PairingLink(link)
                    }
                }
        }
    }
}

/// "system", "light" or "dark". Set on the window rather than with preferredColorScheme,
/// which doesn't reach a sheet that's already open.
enum Appearance {
    static let key = "appearance"

    @MainActor
    static func apply() {
        let style: UIUserInterfaceStyle =
            switch UserDefaults.standard.string(forKey: key) {
            case "light": .light
            case "dark": .dark
            default: .unspecified
            }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
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
