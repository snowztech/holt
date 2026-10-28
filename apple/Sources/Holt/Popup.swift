import AppKit
import HoltBrand
import SwiftUI
import HoltCore

/// How sync looks right now, for the popup footer and the menu.
struct SyncStatus: Equatable {
    var label: String
    var connected: Bool
}

@MainActor
final class PopupModel: ObservableObject {
    @Published var query = "" { didSet { selection = 0; refresh() } }
    @Published private(set) var clips: [Clip] = []
    @Published var selection = 0
    /// The app that will receive the paste, shown in the action bar.
    @Published private(set) var targetApp: String?
    @Published private(set) var sync: SyncStatus?
    /// ⌘1 to ⌘9 hints show only while ⌘ is held.
    @Published var commandHeld = false
    /// Bumped on every show so the view can refocus the search field.
    @Published private(set) var shown = 0

    private let store: Store
    private let syncStatus: () -> SyncStatus?

    init(store: Store, syncStatus: @escaping () -> SyncStatus?) {
        self.store = store
        self.syncStatus = syncStatus
    }

    var selected: Clip? { clips.indices.contains(selection) ? clips[selection] : nil }

    func reset() {
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        sync = syncStatus()
        commandHeld = false
        query = ""
        shown += 1
    }

    func refresh() {
        let selectedID = selected?.id
        clips = (try? store.search(query: query, limit: 200)) ?? []
        if let selectedID, let index = clips.firstIndex(where: { $0.id == selectedID }) {
            selection = index
        }
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
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    private var pressedRow: DragSource.DragView?

    /// SwiftUI's scroll view keeps every click for itself, so AppKit views in
    /// the rows never see one. Mouse events are handed to the row under the
    /// cursor here instead.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let row = row(at: event.locationInWindow) {
                pressedRow = row
                row.mouseDown(with: event)
                return
            }
        case .leftMouseDragged:
            if let pressedRow {
                pressedRow.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if let pressedRow {
                self.pressedRow = nil
                pressedRow.mouseUp(with: event)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    private func row(at point: NSPoint) -> DragSource.DragView? {
        guard let contentView else { return nil }
        return rows(in: contentView).first { row in
            row.bounds.intersection(row.visibleRect).contains(row.convert(point, from: nil))
        }
    }

    private func rows(in view: NSView) -> [DragSource.DragView] {
        view.subviews.flatMap { ($0 as? DragSource.DragView).map { [$0] } ?? rows(in: $0) }
    }
}

@MainActor
final class PopupController {
    private let panel: PopupPanel
    private let model: PopupModel
    private let onPick: (Clip) -> Void
    private let lightbox = Lightbox()
    private var keyMonitor: Any?

    init(store: Store, syncStatus: @escaping () -> SyncStatus?, onPick: @escaping (Clip) -> Void) {
        self.onPick = onPick
        model = PopupModel(store: store, syncStatus: syncStatus)
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
        panel.contentView = NSHostingView(
            rootView: PopupView(
                model: model,
                onPick: { [weak self] in self?.onPick($0) },
                canPreview: { [weak self] in self?.canPreview ?? false }))
        lightbox.onDismiss = { [weak self] in self?.lightbox.hide() }

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    var isVisible: Bool { panel.isVisible }

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
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
    }

    func close() {
        lightbox.hide()
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Space shows the selected image full size, as in Finder. Only while the
    /// search field is empty, so a space in a query stays a space.
    private var canPreview: Bool { model.query.isEmpty && model.selected?.image != nil }

    private func togglePreview() {
        if lightbox.isVisible {
            lightbox.hide()
        } else if let image = model.selected?.image {
            lightbox.show(image, over: panel)
        }
    }

    /// Keeps the full-size view on the selected clip as ↑↓ move through the list.
    private func followSelection() {
        guard lightbox.isVisible else { return }
        if canPreview, let image = model.selected?.image {
            lightbox.show(image, over: panel)
        } else {
            lightbox.hide()
        }
    }

    /// Picks up clips that arrive from another device while the popup is open.
    func refresh() {
        if panel.isVisible { model.refresh() }
    }

    /// Returns nil for keys the popup handles, so the search field never sees them.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let command = event.modifierFlags.contains(.command)
        if event.type == .flagsChanged {
            model.commandHeld = command
            return event
        }
        switch Int(event.keyCode) {
        case 125: model.move(1); followSelection()  // ↓
        case 126: model.move(-1); followSelection()  // ↑
        case 36, 76: if let clip = model.selected { onPick(clip) }  // return, enter
        case 53: lightbox.isVisible ? lightbox.hide() : close()  // esc
        case 49 where canPreview: togglePreview()  // space
        case 51 where command: model.deleteSelected()  // ⌘⌫
        default:
            guard command, let key = event.charactersIgnoringModifiers else { return event }
            if key == "p" {
                model.togglePin()
            } else if key == "o", let clip = model.selected, let url = openURL(clip) {
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

/// The selected image full size, over the popup. Not Quick Look: that panel
/// only shows for the active app, and Holt stays inactive so the app the user
/// was in keeps the paste.
@MainActor
final class Lightbox {
    private let panel: NSPanel
    var onDismiss: (() -> Void)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
    }

    var isVisible: Bool { panel.isVisible }

    /// Sized to the image at 1:1 on this screen, or to fit the screen, whichever is smaller.
    func show(_ image: ImageInfo, over popup: NSWindow) {
        guard let screen = popup.screen ?? NSScreen.main else { return }
        show(image, on: screen, fraction: 1, above: popup)
    }

    /// `fraction` is how much of the screen the view may take.
    func show(_ image: ImageInfo, on screen: NSScreen, fraction: CGFloat, above window: NSWindow? = nil) {
        let visible = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        let room = visible.insetBy(dx: visible.width * (1 - fraction) / 2, dy: visible.height * (1 - fraction) / 2)
        let natural = NSSize(
            width: CGFloat(image.width) / screen.backingScaleFactor, height: CGFloat(image.height) / screen.backingScaleFactor)
        let fit = min(room.width / max(natural.width, 1), room.height / max(natural.height, 1), 1)
        let size = NSSize(width: max(natural.width * fit, 160), height: max(natural.height * fit, 100))
        panel.contentView = NSHostingView(rootView: LightboxView(image: image, onTap: { [weak self] in self?.onDismiss?() }))
        panel.setFrame(
            NSRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2, width: size.width, height: size.height), display: true)
        // Ordered, never made key: the popup keeps the keyboard.
        if let window {
            panel.order(.above, relativeTo: window.windowNumber)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

private struct LightboxView: View {
    let image: ImageInfo
    let onTap: () -> Void
    @State private var loaded: NSImage?

    var body: some View {
        ZStack {
            if let picture = loaded ?? NSImage(data: image.thumb) {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: image.path) {
            let path = image.path
            let picture = await Task.detached(priority: .userInitiated) { Images.preview(path: path, maxPixels: 5000) }.value
            if !Task.isCancelled { loaded = picture }
        }
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    let onPick: (Clip) -> Void
    let canPreview: () -> Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Skip(faceOnly: true)
                    .frame(width: 28, height: 22)
                TextField("Search your clips", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .tint(Brand.river)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            Divider()

            if model.clips.isEmpty {
                EmptyState(query: model.query)
            } else {
                HStack(spacing: 0) {
                    list
                    Divider()
                    if let clip = model.selected {
                        ClipPreview(clip: clip, query: model.query).frame(width: 300)
                    }
                }
            }

            Divider()
            ActionBar(clip: model.selected, targetApp: model.targetApp, sync: model.sync, canPreview: canPreview())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 4 : 12)
                                .padding(.bottom, 4)
                        }
                        ClipRow(
                            clip: clip,
                            number: model.commandHeld && index < 9 ? index + 1 : nil,
                            query: model.query,
                            selected: index == model.selection
                        )
                        .id(clip.id)
                        .overlay(
                            DragSource(
                                clip: clip,
                                onClick: { model.selection = index },
                                onDoubleClick: { onPick(clip) }))
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
    let number: Int?
    let query: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            SourceIcon(clip: clip).frame(width: 18, height: 18)
            if let image = clip.image {
                Thumbnail(data: image.thumb, maxWidth: 40, maxHeight: 24)
            }
            // An image's recognized text is for search and the preview. As a title it's
            // mostly noise, especially on photos.
            Text(highlight(clip.image.map(imageLabel) ?? oneLine(clip.text), query))
                .font(.system(size: 13.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if clip.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(Brand.river)
            }
            if let device = clip.device {
                Text(device)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let number {
                Text("⌘\(number)")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Brand.river)
                    .frame(width: 28, alignment: .trailing)
            } else {
                Text(shortAge(clip))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.river.opacity(0.2))
            }
        }
    }
}

private struct ClipPreview: View {
    let clip: Clip
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                SourceIcon(clip: clip).frame(width: 15, height: 15)
                Text(meta).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }

            if let image = clip.image {
                // Takes the room the text below doesn't need.
                ImagePreview(image: image).layoutPriority(1)
                Text("\(dimensions(image)) · \(image.format.uppercased()) · \(fileSize(image.bytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                // The recognized text shows why a search matched. Browsing, the picture says enough.
                if let excerpt = recognizedExcerpt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Text in image").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                        // A few lines, not selectable: laying out a screenshot's worth of
                        // recognized text costs hundreds of milliseconds per keypress.
                        Text(highlight(excerpt, query))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            } else if clip.kind == .link {
                linkCard
                Spacer(minLength: 0)
            } else if isShort {
                Text(clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 21, weight: .medium))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    Text(clip.text)
                        .font(lineCount > 1 ? .system(size: 12, design: .monospaced) : .system(size: 14))
                        .lineSpacing(lineCount > 1 ? 2 : 3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(size).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var lineCount: Int { clip.text.split(whereSeparator: \.isNewline).count }

    /// While searching, the lines that match first.
    private var recognizedExcerpt: String? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, !clip.text.isEmpty else { return nil }
        let lines = clip.text.split(whereSeparator: \.isNewline)
        let matching = lines.filter { line in words.contains { line.lowercased().contains($0) } }
        let shown = (matching.isEmpty ? lines : matching).prefix(6)
        return shown.map { String($0.prefix(120)) }.joined(separator: "\n")
    }
    private var isShort: Bool { lineCount <= 1 && clip.text.count <= 90 }

    private var meta: String {
        [AppInfo.name(clip.sourceApp), clip.device, longAge(clip)].compactMap { $0 }.joined(separator: " · ")
    }

    private var size: String {
        let chars = "\(clip.text.count.formatted()) characters"
        return lineCount > 1 ? "\(lineCount.formatted()) lines · \(chars)" : chars
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(linkURL(clip)?.host() ?? clip.text)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .lineLimit(2)
            Text(clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.river.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ActionBar: View {
    let clip: Clip?
    let targetApp: String?
    let sync: SyncStatus?
    let canPreview: Bool

    var body: some View {
        HStack(spacing: 18) {
            if let sync {
                HStack(spacing: 6) {
                    Circle()
                        .fill(sync.connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(sync.label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let clip {
                if canPreview { action("Full size", "␣") }
                if openURL(clip) != nil { action("Open", "⌘O") }
                action(clip.pinned ? "Unpin" : "Pin", "⌘P")
                action("Delete", "⌘⌫")
                action(targetApp.map { "Paste in \($0)" } ?? "Paste", "↩", primary: true)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func action(_ label: String, _ key: String, primary: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: primary ? .semibold : .regular))
                .foregroundStyle(primary ? .primary : .secondary)
            Text(key)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

private struct EmptyState: View {
    let query: String

    var body: some View {
        VStack(spacing: 12) {
            Skip().frame(width: 112, height: 112)
            Text(query.isEmpty ? "Skip has nothing yet" : "No clips match “\(query)”")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(query.isEmpty ? "Copy something and it shows up here." : "Try fewer words, or part of a word.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SourceIcon: View {
    let clip: Clip

    var body: some View {
        if let icon = AppInfo.icon(clip.sourceApp) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: fallback)
                .foregroundStyle(.secondary)
        }
    }

    private var fallback: String {
        switch clip.kind {
        case .link: "link"
        case .image: "photo"
        case .text: "text.alignleft"
        }
    }
}

/// A clip's stored thumbnail, a few kilobytes, so the list never opens the file.
private struct Thumbnail: View {
    let data: Data
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        if let image = NSImage(data: data) {
            // A fixed box, filled: a tall screenshot would otherwise be a sliver.
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: maxWidth, height: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }
}

/// The image decoded for the preview pane, off the main thread and cached, with
/// the thumbnail standing in while it loads.
private struct ImagePreview: View {
    let image: ImageInfo
    @State private var loaded: NSImage?

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 12
        return cache
    }()

    var body: some View {
        Group {
            if let picture = loaded ?? NSImage(data: image.thumb) {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: image.path) {
            let key = image.path as NSString
            if let cached = Self.cache.object(forKey: key) {
                loaded = cached
                return
            }
            let path = image.path
            let picture = await Task.detached(priority: .userInitiated) { Images.preview(path: path, maxPixels: 1200) }.value
            guard !Task.isCancelled, let picture else { return }
            Self.cache.setObject(picture, forKey: key)
            loaded = picture
        }
    }
}

@MainActor
enum AppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if bundleID == ClipboardWatcher.universalClipboard { return "Universal Clipboard" }
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

func linkURL(_ clip: Clip) -> URL? {
    URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// What ⌘O opens: the link, or the image file in Preview.
func openURL(_ clip: Clip) -> URL? {
    switch clip.kind {
    case .link: linkURL(clip)
    case .image: clip.image.map { URL(fileURLWithPath: $0.path) }
    case .text: nil
    }
}

/// Lets a row be dragged into another app, and still clicked. SwiftUI's own
/// drag writes types only SwiftUI reads; AppKit's writes what the Finder, Mail
/// and browsers expect.
struct DragSource: NSViewRepresentable {
    let clip: Clip
    let onClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.clip = clip
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView, NSDraggingSource {
        var clip: Clip?
        var onClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        private var mouseDown: NSEvent?
        private var dragging = false

        // Otherwise a drag on a row moves the popup, which is movable by its background.
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            mouseDown = event
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDown, !dragging, let clip,
                hypot(event.locationInWindow.x - mouseDown.locationInWindow.x, event.locationInWindow.y - mouseDown.locationInWindow.y) > 4,
                let writer = dragWriter(for: clip)
            else { return }
            dragging = true
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image = dragImage(for: clip)
            let origin = convert(mouseDown.locationInWindow, from: nil)
            item.setDraggingFrame(
                NSRect(
                    x: origin.x - image.size.width / 2, y: origin.y - image.size.height / 2, width: image.size.width,
                    height: image.size.height),
                contents: image)
            beginDraggingSession(with: [item], event: mouseDown, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDown = nil }
            guard !dragging else { return }
            event.clickCount == 2 ? onDoubleClick?() : onClick?()
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

    }
}

/// What a dragged clip carries: the text as text; an image as its file, plus PNG and TIFF for apps
/// that take a picture rather than a file.
func dragWriter(for clip: Clip) -> NSPasteboardWriting? {
    guard let image = clip.image else { return clip.text as NSString }
    let url = URL(fileURLWithPath: image.path)
    guard let bytes = try? Data(contentsOf: url) else { return nil }
    let item = Images.pasteboardItem(bytes: bytes, format: image.format, sourceApp: clip.sourceApp)
    item.setString(url.absoluteString, forType: .fileURL)
    return item
}

func dragImage(for clip: Clip) -> NSImage {
    if let image = clip.image, let thumb = NSImage(data: image.thumb) {
        let scale = min(1, 160 / max(thumb.size.width, 1), 100 / max(thumb.size.height, 1))
        thumb.size = NSSize(width: thumb.size.width * scale, height: thumb.size.height * scale)
        return thumb
    }
    let text = oneLine(clip.text).prefix(60) as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
    let size = text.size(withAttributes: attributes)
    return NSImage(size: NSSize(width: size.width + 16, height: size.height + 8), flipped: false) { rect in
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: 8, y: 4), withAttributes: attributes)
        return true
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

func oneLine(_ text: String) -> String {
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
            let range = result[start...].range(of: word, options: .caseInsensitive)
        {
            result[range].inlinePresentationIntent = .stronglyEmphasized
            start = range.upperBound
        }
    }
    return result
}
