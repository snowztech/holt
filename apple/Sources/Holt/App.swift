import AppKit
import Carbon
import HoltCore
import SystemConfiguration
import os

private let log = Logger(subsystem: "app.holtclip.Holt", category: "app")

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--render-icon" || args[1] == "--render-phone-icon" {
            MainActor.assumeIsolated { renderIcon(to: args[2], phone: args[1] == "--render-phone-icon") }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: Store!
    /// Nil if networking failed to start. History still works without it.
    private var node: Node?
    private var watcher: ClipboardWatcher!
    private var popup: PopupController!
    private var hotKey: HotKey!
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindow!
    private var welcome: WelcomeWindow?
    private let toast = ArrivalToast()
    /// Shows the highlighted image of the menu's Recent list full size, on space.
    private let menuPreview = Lightbox()
    private var highlighted: Clip?
    private var menuKeyTap: CFMachPort?
    private let updates = Updates()
    private var pruneTimer: Timer?
    private var askedForAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        Prefs.applyAppearance()
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
        do {
            node = try Node.start(store: store, deviceName: Self.computerName())
        } catch {
            log.error("sync is off: \(error, privacy: .public)")
        }
        prune()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }

        watcher = ClipboardWatcher(
            onText: { [weak self] text, app in
                if let app, Prefs.ignoredApps.contains(app) { return }
                _ = try? self?.store.add(text: text, sourceApp: app)
            },
            onImage: { [weak self] raw, app in
                if let app, Prefs.ignoredApps.contains(app) { return }
                // Decoding and reading the text take a moment; the clip shows up
                // once both are done.
                Task.detached(priority: .utility) {
                    guard let image = Images.prepare(raw) else { return }
                    let text = Images.recognizeText(in: image.bytes)
                    await MainActor.run { self?.record(image, text: text, sourceApp: app) }
                }
            },
            incoming: { [weak self] in
                guard let self, let copy = store.takeIncomingCopy() else { return nil }
                received(copy)
                if let image = copy.image {
                    return .image(image, format: copy.imageFormat ?? "png", sourceApp: nil)
                }
                return .text(copy.text)
            }
        )
        watcher.start()

        popup = PopupController(store: store, syncStatus: { [weak self] in self?.syncStatus() }) { [weak self] clip in
            self?.paste(clip)
        }
        hotKey = HotKey(Prefs.shortcut) { [weak self] in self?.popup.toggle() }

        settings = SettingsWindow(
            model: SettingsModel(
                node: node,
                onShortcutChange: { [weak self] in self?.hotKey.register($0) },
                onHistoryChange: { [weak self] in self?.prune() },
                onClear: { [weak self] in try? self?.store.clear() }
            ))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Mark.menuBarImage()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // For development: `open build/Holt.app --args -HoltOpen settings`
        // opens a window right away. Also devices and welcome.
        switch UserDefaults.standard.string(forKey: "HoltOpen") {
        case "settings": settings.show()
        case "devices": settings.show(.devices)
        case "welcome": showWelcome()
        default:
            if !Prefs.onboarded || !Permissions.clipboard {
                showWelcome()
            }
        }
    }

    // MARK: Menu

    /// Rebuilt each time it opens, so sync status and recent clips are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let version = updates.available {
            let item = NSMenuItem(title: "Update to Holt \(version)…", action: #selector(checkForUpdates), keyEquivalent: "")
            item.image = symbol("arrow.down.circle.fill")
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if let sync = syncStatus() {
            let item = NSMenuItem(title: sync.label, action: sync.connected ? nil : #selector(openDevices), keyEquivalent: "")
            item.image = dot(sync.connected ? .systemGreen : .tertiaryLabelColor)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let recent = (try? store.search(query: "", limit: 5)) ?? []
        if !recent.isEmpty {
            menu.addItem(.sectionHeader(title: "Recent"))
            for clip in recent {
                let title = clip.image.map(imageLabel) ?? oneLine(clip.text)
                let item = NSMenuItem(
                    title: title.count > 44 ? String(title.prefix(43)) + "…" : title, action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.representedObject = clip
                item.image =
                    clip.image.flatMap { menuThumbnail($0) } ?? AppInfo.icon(clip.sourceApp).map(resized) ?? symbol("doc.on.clipboard")
                // Images get the preview instead of a tooltip.
                item.toolTip = clip.image == nil && clip.text.count > 44 ? String(clip.text.prefix(400)) : nil
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let open = NSMenuItem(title: "Open Holt", action: #selector(openPopup), keyEquivalent: Prefs.shortcut.key.lowercased())
        open.keyEquivalentModifierMask = Prefs.shortcut.eventModifiers
        open.image = symbol("magnifyingglass")
        menu.addItem(open)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = symbol("gearshape")
        menu.addItem(settingsItem)
        if updates.canCheck, updates.available == nil {
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            check.image = symbol("arrow.down.circle")
            menu.addItem(check)
        }
        if !Permissions.clipboard {
            let warning = NSMenuItem(title: "Allow Clipboard Access…", action: #selector(showWelcome), keyEquivalent: "")
            warning.image = symbol("exclamationmark.triangle")
            menu.addItem(warning)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Holt", action: #selector(quit), keyEquivalent: "q")
        quit.image = symbol("power")
        menu.addItem(quit)

        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    // MARK: Menu preview

    // Space shows the highlighted image full size. A menu takes every key
    // itself (space picks the row), so while the menu is open an event tap
    // catches space first, which needs the Accessibility access Holt already
    // uses to paste. Without it the menu behaves as usual.

    func menuWillOpen(_ menu: NSMenu) {
        startMenuKeyTap()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopMenuKeyTap()
        menuPreview.hide()
        highlighted = nil
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlighted = item?.representedObject as? Clip
        // An open preview follows the highlight, and goes away on a text row.
        if menuPreview.isVisible, !showMenuPreview() {
            menuPreview.hide()
        }
    }

    /// Returns false when nothing was done, so the key goes to the menu.
    fileprivate func toggleMenuPreview() -> Bool {
        if menuPreview.isVisible {
            menuPreview.hide()
            return true
        }
        return showMenuPreview()
    }

    private func showMenuPreview() -> Bool {
        guard let image = highlighted?.image, let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return false }
        menuPreview.show(image, on: screen, fraction: 0.6)
        return true
    }

    private func startMenuKeyTap() {
        guard menuKeyTap == nil, Permissions.autoPaste else { return }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { delegate.menuKeyTap.map { CGEvent.tapEnable(tap: $0, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == kVK_Space else {
                return Unmanaged.passUnretained(event)
            }
            return MainActor.assumeIsolated { delegate.toggleMenuPreview() } ? nil : Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        menuKeyTap = tap
    }

    private func stopMenuKeyTap() {
        guard let tap = menuKeyTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        menuKeyTap = nil
    }

    @objc private func openPopup() { popup.show() }
    @objc private func openSettings() { settings.show() }
    @objc private func openDevices() { settings.show(.devices) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { updates.check() }

    @objc private func showWelcome() {
        if welcome == nil {
            welcome = WelcomeWindow(settings: settings.model) { [weak self] in self?.openDevices() }
        }
        welcome?.show()
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let clip = sender.representedObject as? Clip else { return }
        copy(clip)
    }

    // MARK: Sync

    private func syncStatus() -> SyncStatus? {
        guard let node else { return SyncStatus(label: "Sync is off", connected: false) }
        let devices = (try? node.devices()) ?? []
        guard !devices.isEmpty else { return nil }
        let online = devices.filter(\.online)
        switch online.count {
        case 0: return SyncStatus(label: "Not connected to \(devices.count == 1 ? devices[0].name : "your Macs")", connected: false)
        case 1: return SyncStatus(label: "Synced with \(online[0].name)", connected: true)
        default: return SyncStatus(label: "Synced with \(online.count) Macs", connected: true)
        }
    }

    private func received(_ copy: IncomingCopy) {
        popup.refresh()
        if Prefs.showArrivals, !popup.isVisible {
            let anchor = statusItem.button.flatMap { button in button.window?.convertToScreen(button.convert(button.bounds, to: nil)) }
            toast.show(copy, under: anchor)
        }
    }

    // MARK: Paste

    /// Puts a clip back on the clipboard and records the copy ourselves, so it
    /// moves to the top with its original source app instead of the watcher
    /// crediting whichever app is in front.
    private func copy(_ clip: Clip) {
        if let image = clip.image {
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: image.path)) else { return }
            watcher.put(.image(bytes, format: image.format, sourceApp: clip.sourceApp))
            _ = try? store.addImage(
                bytes: bytes, format: image.format, width: image.width, height: image.height,
                thumb: image.thumb, text: clip.text, sourceApp: clip.sourceApp)
        } else {
            watcher.put(.text(clip.text))
            _ = try? store.add(text: clip.text, sourceApp: clip.sourceApp)
        }
    }

    private func record(_ image: CopiedImage, text: String, sourceApp: String?) {
        _ = try? store.addImage(
            bytes: image.bytes, format: image.format, width: image.width, height: image.height,
            thumb: image.thumb, text: text, sourceApp: sourceApp)
        popup.refresh()
    }

    private func paste(_ clip: Clip) {
        popup.close()
        copy(clip)

        // Without Accessibility access the clip is still on the clipboard,
        // the user just presses ⌘V themselves.
        guard Permissions.autoPaste else {
            if !askedForAccessibility {
                askedForAccessibility = true
                Permissions.requestAutoPaste()
            }
            return
        }
        // The popup never activates Holt, so the app the user was in is still
        // frontmost and receives the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { sendPasteKeystroke() }
    }

    private func prune() {
        _ = try? store.prune(maxAgeDays: UInt32(max(Prefs.historyDays, 1)), maxUnpinned: 5000)
    }

    // MARK: Helpers

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func dot(_ color: NSColor) -> NSImage? {
        symbol("circle.fill")?.withSymbolConfiguration(.init(pointSize: 8, weight: .regular).applying(.init(paletteColors: [color])))
    }

    private func resized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    /// The clip's thumbnail at menu size: 32 pt tall at most, 56 pt wide at most.
    private func menuThumbnail(_ image: ImageInfo) -> NSImage? {
        guard let thumb = NSImage(data: image.thumb), image.width > 0, image.height > 0 else { return nil }
        let scale = min(32 / CGFloat(image.height), 56 / CGFloat(image.width))
        thumb.size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return thumb
    }

    /// The name set in System Settings → General → Sharing, like "Lucas's MacBook Pro".
    private static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    private static func databasePath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("holt.db").path
    }
}
