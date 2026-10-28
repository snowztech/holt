import AppKit
import HoltBrand
import SwiftUI
import HoltCore

/// A small notice under the menu bar icon when a clip arrives from another Mac.
@MainActor
final class ArrivalToast {
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// `anchor` is the menu bar icon's frame on screen.
    func show(_ copy: IncomingCopy, under anchor: NSRect?) {
        let host = NSHostingView(rootView: ToastView(copy: copy))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let anchor {
            let size = panel.frame.size
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? .infinite
            let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 6))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [panel] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }
            panel.orderOut(nil)
        }
    }
}

private struct ToastView: View {
    let copy: IncomingCopy
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 11) {
            Skip(faceOnly: true)
                .frame(width: 30, height: 24)
                .offset(y: landed ? 0 : -6)
                .opacity(landed ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text("From \(copy.device)").font(.system(size: 12.5, weight: .semibold))
                if let image = copy.image, let thumb = Images.thumbnailImage(from: image) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 120, maxHeight: 36, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(.top, 3)
                } else {
                    Text(copy.image == nil ? oneLine(copy.text) : "Image")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(12)
        .onAppear {
            // Skip hops in with the clip.
            if reduceMotion {
                landed = true
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.1)) { landed = true }
            }
        }
    }
}
