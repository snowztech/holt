import AppKit
import SwiftUI
import HoltCore

private let river = Color(red: 0.06, green: 0.43, blue: 0.41)

@MainActor
final class PopupModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0; refresh() } }
    @Published private(set) var clips: [Clip] = []
    @Published var selection = 0
    /// Bumped on every show so the view can refocus the search field.
    @Published private(set) var shown = 0

    private let store: Store

    init(store: Store) { self.store = store }

    var selected: Clip? { clips.indices.contains(selection) ? clips[selection] : nil }

    func reset() {
        query = ""
        shown += 1
    }

    func refresh() {
        clips = (try? store.search(query: query, limit: 200)) ?? []
        selection = min(selection, max(clips.count - 1, 0))
    }

    func move(_ delta: Int) {
        guard !clips.isEmpty else { return }
        selection = min(max(selection + delta, 0), clips.count - 1)
    }

    func togglePin() {
        guard let clip = selected else { return }
        try? store.setPinned(id: clip.id, pinned: !clip.pinned)
        refresh()
    }

    func deleteSelected() {
        guard let clip = selected else { return }
        try? store.delete(id: clip.id)
        refresh()
    }
}

/// Floating panel that takes the keyboard without activating Holt, so the app
/// the user was typing in stays frontmost and gets the paste.
private final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PopupController {
    private let panel: PopupPanel
    private let model: PopupModel
    private let onPick: (Clip) -> Void
    private var keyMonitor: Any?

    init(store: Store, onPick: @escaping (Clip) -> Void) {
        self.onPick = onPick
        model = PopupModel(store: store)
        panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = NSHostingView(rootView: PopupView(model: model, onPick: { [weak self] in self?.pick($0) }))

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        model.reset()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
    }

    func close() {
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func pick(_ clip: Clip) {
        onPick(clip)
    }

    /// Returns nil for keys the popup handles, so the search field never sees them.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case 125: model.move(1)                              // ↓
        case 126: model.move(-1)                             // ↑
        case 36, 76: if let clip = model.selected { pick(clip) } // return, enter
        case 53: close()                                     // esc
        case 51 where command: model.deleteSelected()        // ⌘⌫
        default:
            guard command, let key = event.charactersIgnoringModifiers else { return event }
            if key == "p" {
                model.togglePin()
            } else if let n = Int(key), (1...9).contains(n), model.clips.indices.contains(n - 1) {
                pick(model.clips[n - 1])
            } else {
                return event
            }
        }
        return nil
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    let onPick: (Clip) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pawprint.fill").foregroundStyle(river)
                TextField("Search clips", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($searchFocused)
                Text("⇧⌘V").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()

            if model.clips.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    list
                    Divider()
                    if let clip = model.selected {
                        ClipPreview(clip: clip).frame(width: 280)
                    }
                }
            }

            Divider()
            HStack(spacing: 16) {
                hint("↑↓", "Move")
                hint("⏎", "Paste")
                hint("⌘P", "Pin")
                hint("⌘⌫", "Delete")
                hint("esc", "Close")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .frame(width: 720, height: 440)
        .background(.regularMaterial)
        // Draw under the panel's hidden title bar instead of leaving a gap.
        .ignoresSafeArea()
        .onChange(of: model.shown, initial: true) { searchFocused = true }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                        ClipRow(clip: clip, index: index, selected: index == model.selection)
                            .id(clip.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onPick(clip) }
                            .onTapGesture { model.selection = index }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) {
                if let clip = model.selected { proxy.scrollTo(clip.id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "pawprint").font(.system(size: 32)).foregroundStyle(river)
            Text(model.query.isEmpty ? "Skip has nothing yet. Copy something." : "No clips match “\(model.query)”.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.caption.monospaced())
            Text(label).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

private struct ClipRow: View {
    let clip: Clip
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            SourceIcon(bundleID: clip.sourceApp).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(oneLine(clip.text)).lineLimit(1).truncationMode(.tail)
                Text(meta(clip)).font(.caption).opacity(selected ? 0.8 : 0.6)
            }
            Spacer(minLength: 8)
            if clip.pinned { Image(systemName: "pin.fill").font(.caption) }
            if index < 9 { Text("⌘\(index + 1)").font(.caption.monospaced()).opacity(0.6) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? river : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ClipPreview: View {
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(meta(clip)).font(.caption).foregroundStyle(river)
            ScrollView {
                Text(clip.text)
                    .font(clip.text.contains("\n") ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("\(clip.kind == .link ? "Link" : "Text") · \(clip.text.count) characters")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

private struct SourceIcon: View {
    let bundleID: String?

    var body: some View {
        if let icon = AppInfo.icon(bundleID) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
        }
    }
}

@MainActor
private enum AppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let cached = names[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        names[bundleID] = name ?? bundleID
        return names[bundleID]
    }

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

private let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

@MainActor
private func meta(_ clip: Clip) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(clip.createdAt) / 1000)
    let when = relative.localizedString(for: date, relativeTo: Date())
    return [AppInfo.name(clip.sourceApp), when].compactMap { $0 }.joined(separator: " · ")
}

private func oneLine(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: \.isNewline)
        .joined(separator: " ⏎ ")
}
