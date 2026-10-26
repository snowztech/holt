import AppKit
import HoltBrand
import SwiftUI

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

/// The iPhone icon: full bleed, because iOS rounds the corners itself.
struct PhoneAppIcon: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1A8A82), Color(hex: 0x0B5450)], startPoint: .top, endPoint: .bottom)
            Skip().frame(width: 900, height: 900).offset(y: -112)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// `Holt --render-icon out.png` writes the 1024px Mac icon, and `--render-phone-icon` the
/// iPhone one. Used by `make icon`.
@MainActor
func renderIcon(to path: String, phone: Bool = false) {
    let renderer = ImageRenderer(content: phone ? AnyView(PhoneAppIcon()) : AnyView(AppIcon()))
    guard let image = renderer.cgImage,
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        fputs("could not render icon\n", stderr)
        exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: path))
}
