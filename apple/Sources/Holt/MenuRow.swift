import AppKit
import HoltCore

/// A row of the menu bar menu's Recent list that can be dragged into another
/// app. A plain menu item can't start a drag, so the row draws itself: icon or
/// thumbnail, title, and the highlight the menu would have drawn.
final class MenuRow: NSView, NSDraggingSource {
    private let clip: Clip
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var mouseDown: NSEvent?
    private var dragging = false

    init(clip: Clip, title: String, icon image: NSImage?) {
        self.clip = clip
        let iconSize = image?.size ?? NSSize(width: 16, height: 16)
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: max(22, iconSize.height + 8)))
        icon.image = image
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: 14, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
        label.stringValue = title
        label.font = NSFont.menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: icon.frame.maxX + 8, y: (bounds.height - 17) / 2, width: bounds.width - icon.frame.maxX - 22, height: 17)
        addSubview(icon)
        addSubview(label)
        autoresizingMask = [.width]
        label.autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if highlighted {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        label.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDown = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDown, !dragging,
            hypot(event.locationInWindow.x - mouseDown.locationInWindow.x, event.locationInWindow.y - mouseDown.locationInWindow.y) > 4,
            let writer = dragWriter(for: clip)
        else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = dragImage(for: clip)
        let origin = convert(mouseDown.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(
                x: origin.x - image.size.width / 2, y: origin.y - image.size.height / 2, width: image.size.width, height: image.size.height),
            contents: image)
        beginDraggingSession(with: [item], event: mouseDown, source: self)
    }

    /// A click does what picking the item would: the menu closes and the item's action runs.
    override func mouseUp(with event: NSEvent) {
        defer { mouseDown = nil }
        guard !dragging, let item = enclosingMenuItem, let action = item.action else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
