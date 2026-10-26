import AppKit
import Carbon
import HoltCore

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var watcher: ClipboardWatcher!
    private var popup: PopupController!
    private var hotKey: HotKey!
    private var statusItem: NSStatusItem!
    private var askedForAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store.open(path: Self.databasePath())
        } catch {
            let alert = NSAlert()
            alert.messageText = "Holt can't open its history"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        _ = try? store.prune(maxAgeDays: 30, maxUnpinned: 5000)

        watcher = ClipboardWatcher { [weak self] text, app in
            _ = try? self?.store.add(text: text, sourceApp: app)
        }
        watcher.start()

        popup = PopupController(store: store) { [weak self] clip in self?.paste(clip) }
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.popup.toggle()
        }
        setUpStatusItem()
        if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior != .alwaysAllow {
            askForClipboardAccess()
        }
    }

    /// Since macOS 15.4 the system prompts on every programmatic clipboard read
    /// unless the user sets the app to Always Allow, which a clipboard manager needs.
    @objc private func askForClipboardAccess() {
        let alert = NSAlert()
        alert.messageText = "Let Holt see what you copy"
        alert.informativeText = """
            macOS asks before an app reads the clipboard. To keep your history, \
            set Holt to Always Allow in Privacy & Security → Paste from Other Apps.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Holt only shows up in that list after its first access prompt.
        if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior == .default {
            _ = NSPasteboard.general.string(forType: .string)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Holt")

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Holt", action: #selector(openPopup), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Clipboard Access…", action: #selector(askForClipboardAccess), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Enable Auto-Paste…", action: #selector(askForAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Holt", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func openPopup() { popup.show() }

    @objc private func askForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned clips are kept."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            try? store.clear()
        }
    }

    private func paste(_ clip: Clip) {
        popup.close()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clip.text, forType: .string)
        // Record it ourselves so it moves to the top with its original source app,
        // instead of the watcher crediting whichever app is in front.
        watcher.ignoreCurrentChange()
        _ = try? store.add(text: clip.text, sourceApp: clip.sourceApp)

        // Without Accessibility access the clip is still on the clipboard,
        // the user just presses ⌘V themselves.
        guard AXIsProcessTrusted() else {
            if !askedForAccessibility {
                askedForAccessibility = true
                askForAccessibility()
            }
            return
        }
        // The popup never activates Holt, so the app the user was in is still
        // frontmost and receives the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { sendPasteKeystroke() }
    }

    private static func databasePath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("holt.db").path
    }
}
