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
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(Color(hex: hex))
        })
    }
}

/// Skip the otter, holding a pebble. Same shapes as the logo SVG, on a 200×200 grid.
struct Skip: View {
    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width, size.height) / 200
            ctx.translateBy(x: (size.width - 200 * scale) / 2, y: (size.height - 200 * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)

            func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(color))
            }
            func line(_ build: (inout Path) -> Void, _ color: Color, _ width: CGFloat) {
                var path = Path()
                build(&path)
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }

            oval(46, 60, 16, 16, Brand.fur)
            oval(154, 60, 16, 16, Brand.fur)
            oval(46, 60, 7, 7, Brand.furDark)
            oval(154, 60, 7, 7, Brand.furDark)
            oval(100, 104, 72, 63, Brand.fur)
            oval(100, 130, 48, 34, Brand.muzzle)
            oval(72, 98, 8.5, 9.5, Brand.eye)
            oval(128, 98, 8.5, 9.5, Brand.eye)
            oval(75, 94.5, 2.8, 2.8, .white)
            oval(131, 94.5, 2.8, 2.8, .white)

            var nose = Path()
            nose.move(to: CGPoint(x: 88, y: 113))
            nose.addQuadCurve(to: CGPoint(x: 112, y: 113), control: CGPoint(x: 100, y: 104))
            nose.addQuadCurve(to: CGPoint(x: 100, y: 124), control: CGPoint(x: 112, y: 122))
            nose.addQuadCurve(to: CGPoint(x: 88, y: 113), control: CGPoint(x: 88, y: 122))
            ctx.fill(nose, with: .color(Brand.eye))

            line({ p in
                p.move(to: CGPoint(x: 100, y: 124)); p.addLine(to: CGPoint(x: 100, y: 131))
                p.addQuadCurve(to: CGPoint(x: 84, y: 133), control: CGPoint(x: 92, y: 139))
                p.move(to: CGPoint(x: 100, y: 131))
                p.addQuadCurve(to: CGPoint(x: 116, y: 133), control: CGPoint(x: 108, y: 139))
            }, Brand.eye, 3)
            line({ p in
                for (from, to) in [((62, 124), (34, 118)), ((62, 131), (33, 133)), ((138, 124), (166, 118)), ((138, 131), (167, 133))] {
                    p.move(to: CGPoint(x: from.0, y: from.1)); p.addLine(to: CGPoint(x: to.0, y: to.1))
                }
            }, Brand.furDark, 2.2)

            oval(100, 174, 24, 15, Brand.pebble)
            oval(93, 169, 7, 3.5, .white.opacity(0.35))
            oval(77, 171, 11, 9, Brand.furDark)
            oval(123, 171, 11, 9, Brand.furDark)
        }
        .aspectRatio(1, contentMode: .fit)
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
            Skip().frame(width: 720, height: 720).offset(y: 12)
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
