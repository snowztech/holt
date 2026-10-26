import AppKit
import Carbon
import ServiceManagement

/// User settings, kept in UserDefaults. Views bind to the same keys with @AppStorage.
enum Prefs {
    static let historyDaysKey = "historyDays"
    static let ignoredAppsKey = "ignoredApps"
    static let showArrivalsKey = "showArrivals"
    static let onboardedKey = "onboarded"

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [historyDaysKey: 30, showArrivalsKey: true])
    }

    static var historyDays: Int { defaults.integer(forKey: historyDaysKey) }
    static var showArrivals: Bool { defaults.bool(forKey: showArrivalsKey) }

    static var onboarded: Bool {
        get { defaults.bool(forKey: onboardedKey) }
        set { defaults.set(newValue, forKey: onboardedKey) }
    }

    /// Bundle ids whose copies are never recorded.
    static var ignoredApps: [String] {
        get { defaults.stringArray(forKey: ignoredAppsKey) ?? [] }
        set { defaults.set(newValue, forKey: ignoredAppsKey) }
    }

    static var shortcut: Shortcut {
        get {
            guard defaults.object(forKey: "shortcut.keyCode") != nil else { return .default }
            return Shortcut(
                keyCode: UInt32(defaults.integer(forKey: "shortcut.keyCode")),
                modifiers: UInt32(defaults.integer(forKey: "shortcut.modifiers")),
                key: defaults.string(forKey: "shortcut.key") ?? "V"
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: "shortcut.keyCode")
            defaults.set(Int(newValue.modifiers), forKey: "shortcut.modifiers")
            defaults.set(newValue.key, forKey: "shortcut.key")
        }
    }
}

/// A global shortcut: a key position plus Carbon modifier flags.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key's character, for display.
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), key: "V")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Nil when the event has no ⌘, ⌥ or ⌃, since a plain key can't be a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isDisjoint(with: [.command, .option, .control]),
              let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty
        else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, key: key)
    }
}

/// The macOS permissions Holt depends on.
@MainActor
enum Permissions {
    /// Since macOS 15.4 the system prompts on every programmatic clipboard read
    /// unless the user sets the app to Always Allow, which a clipboard manager needs.
    static var clipboard: Bool {
        if #available(macOS 15.4, *) {
            return NSPasteboard.general.accessBehavior == .alwaysAllow
        }
        return true
    }

    static func openClipboardSettings() {
        // Holt only shows up in that list after its first access prompt.
        if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior == .default {
            _ = NSPasteboard.general.string(forType: .string)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
    }

    static var autoPaste: Bool { AXIsProcessTrusted() }

    static func requestAutoPaste() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }
}
