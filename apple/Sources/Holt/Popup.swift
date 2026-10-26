import AppKit
import SwiftUI
import HoltCore

@MainActor
final class PopupModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0; refresh() } }
    @Published private(set) var clips: [Clip] = []
    @Published var selection = 0
    /// The app that will receive the paste, shown in the action bar.
    @Published private(set) var targetApp: String?
    /// Bumped on every show so the view can refocus the search field.
    @Published private(set) var shown = 0

    private let store: Store

    init(store: Store) { self.store = store }

    var selected: Clip? { clips.indices.contains(selection) ? clips[selection] : nil }

    func reset() {
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
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
        // Pinning moves the clip, so keep it selected.
        if let index = clips.firstIndex(where: { $0.id == clip.id }) { selection = index }
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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
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
        panel.contentView = NSHostingView(rootView: PopupView(model: model, onPick: { [weak self] in self?.onPick($0) }))

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

    /// Returns nil for keys the popup handles, so the search field never sees them.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case 125: model.move(1)                                    // ↓
        case 126: model.move(-1)                                   // ↑
        case 36, 76: if let clip = model.selected { onPick(clip) } // return, enter
        case 53: close()                                           // esc
        case 51 where command: model.deleteSelected()              // ⌘⌫
        default:
            guard command, let key = event.charactersIgnoringModifiers else { return event }
            if key == "p" {
                model.togglePin()
            } else if key == "o", let clip = model.selected, clip.kind == .link,
                      let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                close()
                NSWorkspace.shared.open(url)
            } else if let n = Int(key), (1...9).contains(n), model.clips.indices.contains(n - 1) {
                onPick(model.clips[n - 1])
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
            HStack(spacing: 12) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Brand.river)
                TextField("Search your clips", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            Divider()

            if model.clips.isEmpty {
                EmptyState(query: model.query)
            } else {
                HStack(spacing: 0) {
                    list
                    Divider()
                    if let clip = model.selected {
                        ClipPreview(clip: clip).frame(width: 300)
                    }
                }
            }

            Divider()
            ActionBar(clip: model.selected, targetApp: model.targetApp)
        }
        .frame(width: 760, height: 460)
        .background(.regularMaterial)
        // Draw under the panel's hidden title bar instead of leaving a gap.
        .ignoresSafeArea()
        .onChange(of: model.shown, initial: true) { searchFocused = true }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                        let section = sectionTitle(clip)
                        if index == 0 || sectionTitle(model.clips[index - 1]) != section {
                            Text(section)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 4 : 12)
                                .padding(.bottom, 4)
                        }
                        ClipRow(clip: clip, index: index, query: model.query, selected: index == model.selection)
                            .id(clip.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onPick(clip) }
                            .onTapGesture { model.selection = index }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selection) {
                if let clip = model.selected { proxy.scrollTo(clip.id) }
            }
        }
    }
}

private struct ClipRow: View {
    let clip: Clip
    let index: Int
    let query: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            SourceIcon(clip: clip).frame(width: 20, height: 20)
            Text(highlight(oneLine(clip.text), query))
                .font(.system(size: 13.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if clip.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).opacity(0.7)
            }
            Text(shortAge(clip))
                .font(.system(size: 11.5).monospacedDigit())
                .opacity(0.55)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, design: .rounded))
                    .opacity(selected ? 0.8 : 0.35)
                    .frame(width: 24, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.riverDeep)
            }
        }
    }
}

private struct ClipPreview: View {
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SourceIcon(clip: clip).frame(width: 18, height: 18)
                Text(AppInfo.name(clip.sourceApp) ?? "Unknown app")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(longAge(clip)).font(.system(size: 12)).foregroundStyle(.secondary)
            }

            if clip.kind == .link {
                linkCard
            } else {
                ScrollView {
                    Text(clip.text)
                        .font(isCode ? .system(size: 12, design: .monospaced) : .system(size: 14))
                        .lineSpacing(isCode ? 2 : 3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                info("Type", clip.kind == .link ? "Link" : "Text")
                info("Characters", clip.text.count.formatted())
                if lineCount > 1 { info("Lines", lineCount.formatted()) }
            }
            .font(.system(size: 12))
        }
        .padding(16)
    }

    private var lineCount: Int { clip.text.split(whereSeparator: \.isNewline).count }
    private var isCode: Bool { lineCount > 1 }

    private var linkCard: some View {
        let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
        return VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "link").foregroundStyle(Brand.river)
            Text(url?.host() ?? clip.text)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(2)
            Text(clip.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.river.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

private struct ActionBar: View {
    let clip: Clip?
    let targetApp: String?

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Image(systemName: "pawprint.fill").foregroundStyle(Brand.river)
                Text("Holt").font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            Spacer()
            if let clip {
                if clip.kind == .link { action("Open", "⌘O") }
                action(clip.pinned ? "Unpin" : "Pin", "⌘P")
                action("Delete", "⌘⌫")
                action(targetApp.map { "Paste in \($0)" } ?? "Paste", "⏎", primary: true)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func action(_ label: String, _ key: String, primary: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: primary ? .semibold : .regular))
                .foregroundStyle(primary ? .primary : .secondary)
            Text(key)
                .font(.system(size: 11, design: .rounded))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

private struct EmptyState: View {
    let query: String

    var body: some View {
        VStack(spacing: 12) {
            Skip().frame(width: 96, height: 96)
            Text(query.isEmpty ? "Skip has nothing yet" : "No clips match “\(query)”")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(query.isEmpty ? "Copy something and it shows up here." : "Try fewer words, or part of a word.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SourceIcon: View {
    let clip: Clip

    var body: some View {
        if let icon = AppInfo.icon(clip.sourceApp) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: clip.kind == .link ? "link" : "text.alignleft")
                .foregroundStyle(.secondary)
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

private func date(_ clip: Clip) -> Date {
    Date(timeIntervalSince1970: TimeInterval(clip.createdAt) / 1000)
}

private func sectionTitle(_ clip: Clip) -> String {
    if clip.pinned { return "PINNED" }
    let calendar = Calendar.current
    if calendar.isDateInToday(date(clip)) { return "TODAY" }
    if calendar.isDateInYesterday(date(clip)) { return "YESTERDAY" }
    return "EARLIER"
}

/// "now", "42s", "5m", "3h", "12d".
private func shortAge(_ clip: Clip) -> String {
    let seconds = Int(Date().timeIntervalSince(date(clip)))
    switch seconds {
    case ..<5: return "now"
    case ..<60: return "\(seconds)s"
    case ..<3600: return "\(seconds / 60)m"
    case ..<86_400: return "\(seconds / 3600)h"
    default: return "\(seconds / 86_400)d"
    }
}

private let relative: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
}()

private func longAge(_ clip: Clip) -> String {
    relative.localizedString(for: date(clip), relativeTo: Date())
}

private func oneLine(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: \.isNewline)
        .joined(separator: " ⏎ ")
}

/// Bolds every place a query word appears, matching how search works.
private func highlight(_ text: String, _ query: String) -> AttributedString {
    var result = AttributedString(text)
    for word in query.split(whereSeparator: \.isWhitespace) {
        var start = result.startIndex
        while start < result.endIndex,
              let range = result[start...].range(of: word, options: .caseInsensitive) {
            result[range].inlinePresentationIntent = .stronglyEmphasized
            start = range.upperBound
        }
    }
    return result
}
