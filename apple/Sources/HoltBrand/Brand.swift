import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// Holt's brand, shared by the Mac app and the iPhone app: the colors, Skip, and Skip's face.

public enum Brand {
    /// Text and icons on a river teal button: white in light mode, deep teal in dark, where the teal is lighter.
    public static let onRiver = Color(light: 0xFFFFFF, dark: 0x062421)
    public static let river = Color(light: 0x0F6E68, dark: 0x52C3B8)
    /// Selection fill. Stays dark in both themes so white text reads on it.
    public static let riverDeep = Color(light: 0x0F6E68, dark: 0x13756E)
    public static let fur = Color(hex: 0x7A5236)
    public static let furDark = Color(hex: 0x563824)
    public static let muzzle = Color(hex: 0xEAD6C0)
    public static let pebble = Color(hex: 0xA9B0AB)
    public static let eye = Color(hex: 0x1D1512)
}

extension Color {
    public init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    public init(light: UInt32, dark: UInt32) {
        #if os(macOS)
            self.init(
                nsColor: NSColor(name: nil) { appearance in
                    let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                    return NSColor(Color(hex: hex))
                })
        #else
            self.init(
                uiColor: UIColor { traits in
                    UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
                })
        #endif
    }
}

/// Skip's face on a 200×200 grid. The color Skip and the one-color menu bar icon both
/// draw from these shapes, so the menu bar shows the same otter as everywhere else.
/// Small ears low on a wide head, a two-lobed muzzle and whiskers keep it an otter, not a bear.
public enum SkipFace {
    /// The part of the grid the face covers.
    public static let bounds = CGRect(x: 18, y: 46, width: 164, height: 126)
    public static let ears = [oval(35, 86, 14, 14), oval(165, 86, 14, 14)]
    public static let innerEars = [oval(35, 86, 6, 6), oval(165, 86, 6, 6)]
    public static let head = oval(100, 110, 78, 58)
    public static let muzzle = [oval(100, 132, 40, 22), oval(82, 137, 23, 23), oval(118, 137, 23, 23)]
    public static let eyes = [oval(70, 101, 8.5, 9.5), oval(130, 101, 8.5, 9.5)]
    public static let highlights = [oval(73, 97.5, 2.8, 2.8), oval(133, 97.5, 2.8, 2.8)]
    public static let nose = Path { p in
        p.move(to: CGPoint(x: 87, y: 117))
        p.addQuadCurve(to: CGPoint(x: 113, y: 117), control: CGPoint(x: 100, y: 108))
        p.addQuadCurve(to: CGPoint(x: 100, y: 128), control: CGPoint(x: 113, y: 126))
        p.addQuadCurve(to: CGPoint(x: 87, y: 117), control: CGPoint(x: 87, y: 126))
    }
    public static let mouth = Path { p in
        p.move(to: CGPoint(x: 100, y: 128))
        p.addLine(to: CGPoint(x: 100, y: 134))
        p.addQuadCurve(to: CGPoint(x: 85, y: 137), control: CGPoint(x: 92, y: 142))
        p.move(to: CGPoint(x: 100, y: 134))
        p.addQuadCurve(to: CGPoint(x: 115, y: 137), control: CGPoint(x: 108, y: 142))
    }
    public static let whiskers = Path { p in
        for (from, to) in [((60, 131), (26, 124)), ((60, 139), (25, 141)), ((140, 131), (174, 124)), ((140, 139), (175, 141))] {
            p.move(to: CGPoint(x: from.0, y: from.1))
            p.addLine(to: CGPoint(x: to.0, y: to.1))
        }
    }

    private static func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }
}

/// Skip the otter, holding a pebble. `faceOnly` drops the pebble and frames just the
/// head: the logo, used in the search field and the arrival notice.
public struct Skip: View {
    public var faceOnly: Bool

    public init(faceOnly: Bool = false) {
        self.faceOnly = faceOnly
    }

    /// The part of the 200×200 grid to fit in the view.
    private var bounds: CGRect { faceOnly ? SkipFace.bounds : CGRect(x: 0, y: 0, width: 200, height: 200) }

    public var body: some View {
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
