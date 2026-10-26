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

/// Skip's face on a 200×200 grid. The color Skip and the one-color menu bar icon both
/// draw from these shapes, so the menu bar shows the same otter as everywhere else.
/// Small ears low on a wide head, a two-lobed muzzle and whiskers keep it an otter, not a bear.
enum SkipFace {
    /// The part of the grid the face covers.
    static let bounds = CGRect(x: 18, y: 46, width: 164, height: 126)
    static let ears = [oval(35, 86, 14, 14), oval(165, 86, 14, 14)]
    static let innerEars = [oval(35, 86, 6, 6), oval(165, 86, 6, 6)]
    static let head = oval(100, 110, 78, 58)
    static let muzzle = [oval(100, 132, 40, 22), oval(82, 137, 23, 23), oval(118, 137, 23, 23)]
    static let eyes = [oval(70, 101, 8.5, 9.5), oval(130, 101, 8.5, 9.5)]
    static let highlights = [oval(73, 97.5, 2.8, 2.8), oval(133, 97.5, 2.8, 2.8)]
    static let nose = Path { p in
        p.move(to: CGPoint(x: 87, y: 117))
        p.addQuadCurve(to: CGPoint(x: 113, y: 117), control: CGPoint(x: 100, y: 108))
        p.addQuadCurve(to: CGPoint(x: 100, y: 128), control: CGPoint(x: 113, y: 126))
        p.addQuadCurve(to: CGPoint(x: 87, y: 117), control: CGPoint(x: 87, y: 126))
    }
    static let mouth = Path { p in
        p.move(to: CGPoint(x: 100, y: 128))
        p.addLine(to: CGPoint(x: 100, y: 134))
        p.addQuadCurve(to: CGPoint(x: 85, y: 137), control: CGPoint(x: 92, y: 142))
        p.move(to: CGPoint(x: 100, y: 134))
        p.addQuadCurve(to: CGPoint(x: 115, y: 137), control: CGPoint(x: 108, y: 142))
    }
    static let whiskers = Path { p in
        for (from, to) in [((60, 131), (26, 124)), ((60, 139), (25, 141)), ((140, 131), (174, 124)), ((140, 139), (175, 141))] {
            p.move(to: CGPoint(x: from.0, y: from.1))
            p.addLine(to: CGPoint(x: to.0, y: to.1))
        }
    }

    private static func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }
}

/// Skip's face in one color, for the menu bar, where macOS wants a template image.
enum Mark {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let bounds = SkipFace.bounds
            let scale = rect.width / bounds.width
            cg.translateBy(x: 0, y: (rect.height - bounds.height * scale) / 2)
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -bounds.minX, y: -bounds.minY)
            cg.setFillColor(.black)
            cg.setStrokeColor(.black)

            (SkipFace.ears + [SkipFace.head]).forEach { cg.addPath($0.cgPath) }
            cg.fillPath()
            // The muzzle and eyes become holes, the way they read as lighter shapes in color.
            cg.setBlendMode(.destinationOut)
            (SkipFace.muzzle + SkipFace.eyes).forEach { cg.addPath($0.cgPath) }
            cg.fillPath()
            cg.setBlendMode(.normal)
            cg.addPath(SkipFace.nose.cgPath)
            cg.fillPath()
            // Thicker than in color, or the whiskers vanish at menu bar size.
            cg.setLineWidth(6)
            cg.setLineCap(.round)
            cg.addPath(SkipFace.whiskers.cgPath)
            cg.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Holt"
        return image
    }
}

/// Skip the otter, holding a pebble. `faceOnly` drops the pebble and frames just the
/// head: the logo, used in the search field and the arrival notice.
struct Skip: View {
    var faceOnly = false

    /// The part of the 200×200 grid to fit in the view.
    private var bounds: CGRect { faceOnly ? SkipFace.bounds : CGRect(x: 0, y: 0, width: 200, height: 200) }

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            ctx.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)

            func fill(_ paths: [Path], _ color: Color) {
                paths.forEach { ctx.fill($0, with: .color(color)) }
            }
            fill(SkipFace.ears, Brand.fur)
            fill(SkipFace.innerEars, Brand.furDark)
            fill([SkipFace.head], Brand.fur)
            fill(SkipFace.muzzle, Brand.muzzle)
            fill(SkipFace.eyes, Brand.eye)
            fill(SkipFace.highlights, .white)
            fill([SkipFace.nose], Brand.eye)
            ctx.stroke(SkipFace.mouth, with: .color(Brand.eye), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ctx.stroke(SkipFace.whiskers, with: .color(Brand.furDark), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

            if !faceOnly {
                func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: Color) {
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(color))
                }
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
