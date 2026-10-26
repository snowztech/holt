import AppKit
import SwiftUI
import HoltCore

enum SettingsTab {
    case general, history, devices, about
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var shortcut = Prefs.shortcut {
        didSet {
            Prefs.shortcut = shortcut
            onShortcutChange(shortcut)
        }
    }
    @Published var launchAtLogin = Permissions.launchAtLogin {
        didSet { Permissions.launchAtLogin = launchAtLogin }
    }
    @Published var ignoredApps = Prefs.ignoredApps {
        didSet { Prefs.ignoredApps = ignoredApps }
    }
    /// Polled while the window is open, since macOS sends no change events.
    @Published private(set) var clipboardAllowed = Permissions.clipboard
    @Published private(set) var autoPasteAllowed = Permissions.autoPaste

    let devices: DevicesModel?
    let onShortcutChange: (Shortcut) -> Void
    let onHistoryChange: () -> Void
    let onClear: () -> Void

    init(node: Node?, onShortcutChange: @escaping (Shortcut) -> Void, onHistoryChange: @escaping () -> Void, onClear: @escaping () -> Void)
    {
        devices = node.map(DevicesModel.init)
        self.onShortcutChange = onShortcutChange
        self.onHistoryChange = onHistoryChange
        self.onClear = onClear
    }

    func refreshPermissions() {
        clipboardAllowed = Permissions.clipboard
        autoPasteAllowed = Permissions.autoPaste
        launchAtLogin = Permissions.launchAtLogin
    }

    func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !ignoredApps.contains(id) {
                ignoredApps.append(id)
            }
        }
    }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private var timer: Timer?
    private static let order: [SettingsTab] = [.general, .history, .devices, .about]

    init(model: SettingsModel) {
        self.model = model
    }

    func show(_ tab: SettingsTab? = nil) {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = [.crossfade, .allowUserInteraction]
            tabs.addTabViewItem(item("General", "gearshape", GeneralTab(model: model)))
            tabs.addTabViewItem(item("History", "clock", HistoryTab(model: model)))
            tabs.addTabViewItem(item("Devices", "laptopcomputer", DevicesTab(model: model)))
            tabs.addTabViewItem(item("About", "info.circle", AboutTab()))
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.tabs = tabs
            self.window = window
        }
        if let tab, let index = Self.order.firstIndex(of: tab) {
            tabs?.selectedTabViewItemIndex = index
        }
        model.refreshPermissions()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshPermissions() }
        }
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func item<V: View>(_ label: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view.frame(width: 560).tint(Brand.river))
        controller.sizingOptions = .preferredContentSize
        // The toolbar tab style shows the selected tab's title as the window title.
        controller.title = label
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

private struct DevicesTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let devices = model.devices {
            // Pairable only while this tab is showing.
            DevicesView(model: devices)
                .onAppear { devices.open() }
                .onDisappear { devices.close() }
        } else {
            Text("Sync couldn't start on this Mac. Your history still works.")
                .foregroundStyle(.secondary)
                .padding(40)
        }
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(Prefs.showArrivalsKey) private var showArrivals = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Open Holt with") {
                    ShortcutRecorder(shortcut: $model.shortcut)
                }
                Toggle("Open Holt at login", isOn: $model.launchAtLogin)
                Toggle("Show a notice when a clip arrives from another Mac", isOn: $showArrivals)
            }
            Section("Permissions") {
                PermissionRow(
                    title: "See what you copy",
                    detail: "Required. Set Holt to Always Allow in Paste from Other Apps.",
                    granted: model.clipboardAllowed,
                    button: "Open Settings",
                    action: Permissions.openClipboardSettings
                )
                PermissionRow(
                    title: "Paste for you",
                    detail: "Optional. Without it, Holt copies the clip and you press ⌘V.",
                    granted: model.autoPasteAllowed,
                    button: "Allow",
                    action: Permissions.requestAutoPaste
                )
            }
        }
        .formStyle(.grouped)
        .frame(height: 330)
    }
}

private struct HistoryTab: View {
    @ObservedObject var model: SettingsModel
    @AppStorage(Prefs.historyDaysKey) private var historyDays = 30
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                Picker("Keep clips for", selection: $historyDays) {
                    Text("1 week").tag(7)
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                    Text("1 year").tag(365)
                }
                .onChange(of: historyDays) { model.onHistoryChange() }
            } footer: {
                Text("Pinned clips are kept forever. Copies that password managers mark as private are never recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Never record copies from") {
                if model.ignoredApps.isEmpty {
                    Text("No apps").foregroundStyle(.secondary)
                }
                ForEach(model.ignoredApps, id: \.self) { id in
                    HStack(spacing: 8) {
                        if let icon = AppInfo.icon(id) {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(AppInfo.name(id) ?? id)
                        Spacer()
                        Button {
                            model.ignoredApps.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Record copies from this app again")
                    }
                }
                Button("Add App…") { model.addIgnoredApp() }
            }
            Section {
                Button("Clear History…", role: .destructive) { confirmingClear = true }
                    .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
                        Button("Clear History", role: .destructive) { model.onClear() }
                    } message: {
                        Text("This removes every unpinned clip here and on your paired devices.")
                    }
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Skip().frame(width: 120, height: 120)
            Text("Holt").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Your clipboard, kept.").foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.callout)
                .foregroundStyle(.tertiary)
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/snowztech/holt")!)
                Link("Report an issue", destination: URL(string: "https://github.com/snowztech/holt/issues/new/choose")!)
            }
            .padding(.top, 6)
            Text("Free and open source, made by snowztech.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

/// Click, then type a shortcut. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Type a shortcut…" : shortcut.display) {
                recording ? stop() : start()
            }
            .font(.system(.body, design: .rounded))
            if shortcut != .default && !recording {
                Button {
                    shortcut = .default
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to \(Shortcut.default.display)")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
            } else if let new = Shortcut(event: event) {
                shortcut = new
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// A permission with its status, and a button to fix it when it's missing.
struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(granted ? Brand.river : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button(button, action: action)
            }
        }
    }
}
