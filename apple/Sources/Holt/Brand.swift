import AppKit
import SwiftUI

enum Brand {
    static let river = Color(light: 0x0F6E68, dark: 0x52C3B8)
    /// Selection fill. Stays dark in both themes so white text reads on it.
    static let riverDeep = Color(light: 0x0F6E68, dark: 0x13756E)
    static let fur = Color(hex: 0x7A5236)
    static let furDark = Color(hex: 0x563824)
    static let muzzle = Color(hex: 0xEAD6C0)
    static let pebble = Color(hex: 0xA9B0AB)
    static let eye = Color(hex: 0x1D1512)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(Color(hex: hex))
            })
    }
}

/// Holt's mark: Skip's face, simple enough for the menu bar. Small ears low on a
/// wide, flat head, a two-lobed muzzle and whiskers make it an otter, not a bear.
/// Drawn on an 18×18 grid with y going down.
enum Mark {
    /// Filled: the ears and the head.
    static let silhouette = [oval(3.2, 7.4, 1.7, 1.7), oval(14.8, 7.4, 1.7, 1.7), oval(9, 10.4, 7.6, 5.6)]
    /// Cut out of the silhouette: the muzzle and the eyes.
    static let cutouts = [oval(7.35, 12.7, 2.45, 2.15), oval(10.65, 12.7, 2.45, 2.15), oval(5.9, 9.1, 1, 1.15), oval(12.1, 9.1, 1, 1.15)]
    static let nose = oval(9, 11.3, 1.45, 0.95)
    static let whiskers = [
        (CGPoint(x: 1.9, y: 12.3), CGPoint(x: -0.2, y: 11.6)),
        (CGPoint(x: 1.9, y: 13.6), CGPoint(x: -0.2, y: 14.0)),
        (CGPoint(x: 16.1, y: 12.3), CGPoint(x: 18.2, y: 11.6)),
        (CGPoint(x: 16.1, y: 13.6), CGPoint(x: 18.2, y: 14.0)),
    ]
    static let whiskerWidth: CGFloat = 0.75

    private static func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect {
        CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            silhouette.forEach { NSBezierPath(ovalIn: $0).fill() }
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            cutouts.forEach { NSBezierPath(ovalIn: $0).fill() }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: nose).fill()
            for (from, to) in whiskers {
                let path = NSBezierPath()
                path.move(to: from)
                path.line(to: to)
                path.lineWidth = whiskerWidth
                path.lineCapStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Holt"
        return image
    }
}

/// The mark as a view, in the current foreground style.
struct MarkView: View {
    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width, size.height) / 18
            ctx.translateBy(x: (size.width - 18 * scale) / 2, y: (size.height - 18 * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            Mark.silhouette.forEach { ctx.fill(Path(ellipseIn: $0), with: .foreground) }
            var cut = ctx
            cut.blendMode = .destinationOut
            Mark.cutouts.forEach { cut.fill(Path(ellipseIn: $0), with: .color(.black)) }
            ctx.fill(Path(ellipseIn: Mark.nose), with: .foreground)
            var whiskers = Path()
            for (from, to) in Mark.whiskers {
                whiskers.move(to: from)
                whiskers.addLine(to: to)
            }
            ctx.stroke(whiskers, with: .foreground, style: StrokeStyle(lineWidth: Mark.whiskerWidth, lineCap: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        // Keeps the cutouts from punching through to whatever is behind the mark.
        .compositingGroup()
    }
}

/// Skip the otter, holding a pebble. Same shapes as the logo SVG, on a 200×200 grid.
/// `faceOnly` drops the pebble and frames just the head, for small spots like the arrival notice.
struct Skip: View {
    var faceOnly = false

    /// The part of the 200×200 grid to fit in the view.
    private var bounds: CGRect { faceOnly ? CGRect(x: 18, y: 46, width: 164, height: 126) : CGRect(x: 0, y: 0, width: 200, height: 200) }

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            ctx.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)

            func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(color))
            }
            func line(_ build: (inout Path) -> Void, _ color: Color, _ width: CGFloat) {
                var path = Path()
                build(&path)
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }

            // Small ears low on the sides of a wide head, like the menu bar mark.
            oval(35, 86, 14, 14, Brand.fur)
            oval(165, 86, 14, 14, Brand.fur)
            oval(35, 86, 6, 6, Brand.furDark)
            oval(165, 86, 6, 6, Brand.furDark)
            oval(100, 110, 78, 58, Brand.fur)
            // Two-lobed muzzle.
            oval(100, 132, 40, 22, Brand.muzzle)
            oval(82, 137, 23, 23, Brand.muzzle)
            oval(118, 137, 23, 23, Brand.muzzle)
            oval(70, 101, 8.5, 9.5, Brand.eye)
            oval(130, 101, 8.5, 9.5, Brand.eye)
            oval(73, 97.5, 2.8, 2.8, .white)
            oval(133, 97.5, 2.8, 2.8, .white)

            var nose = Path()
            nose.move(to: CGPoint(x: 87, y: 117))
            nose.addQuadCurve(to: CGPoint(x: 113, y: 117), control: CGPoint(x: 100, y: 108))
            nose.addQuadCurve(to: CGPoint(x: 100, y: 128), control: CGPoint(x: 113, y: 126))
            nose.addQuadCurve(to: CGPoint(x: 87, y: 117), control: CGPoint(x: 87, y: 126))
            ctx.fill(nose, with: .color(Brand.eye))

            line(
                { p in
                    p.move(to: CGPoint(x: 100, y: 128)); p.addLine(to: CGPoint(x: 100, y: 134))
                    p.addQuadCurve(to: CGPoint(x: 85, y: 137), control: CGPoint(x: 92, y: 142))
                    p.move(to: CGPoint(x: 100, y: 134))
                    p.addQuadCurve(to: CGPoint(x: 115, y: 137), control: CGPoint(x: 108, y: 142))
                }, Brand.eye, 3)
            line(
                { p in
                    for (from, to) in [((60, 131), (26, 124)), ((60, 139), (25, 141)), ((140, 131), (174, 124)), ((140, 139), (175, 141))] {
                        p.move(to: CGPoint(x: from.0, y: from.1)); p.addLine(to: CGPoint(x: to.0, y: to.1))
                    }
                }, Brand.furDark, 2.4)

            if !faceOnly {
                oval(100, 177, 24, 15, Brand.pebble)
                oval(93, 172, 7, 3.5, .white.opacity(0.35))
                oval(77, 174, 11, 9, Brand.furDark)
                oval(123, 174, 11, 9, Brand.furDark)
            }
        }
        .aspectRatio(bounds.width / bounds.height, contentMode: .fit)
    }
}

/// The app icon on Apple's 1024 grid: an 824pt rounded square with Skip on river teal.
struct AppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1A8A82), Color(hex: 0x0B5450)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            Skip().frame(width: 780, height: 780).offset(y: -98)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// `Holt --render-icon out.png` writes the 1024px icon. Used by `make icon`.
@MainActor
func renderIcon(to path: String) {
    let renderer = ImageRenderer(content: AppIcon())
    guard let image = renderer.cgImage,
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        fputs("could not render icon\n", stderr)
        exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: path))
}
