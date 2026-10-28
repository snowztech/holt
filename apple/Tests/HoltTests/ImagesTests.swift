import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Holt

final class ImagesTests: XCTestCase {
    func testKeepsPNGBytesAndMeasuresThem() throws {
        let png = try XCTUnwrap(encode(picture(width: 20, height: 10), as: .png))
        let image = try XCTUnwrap(Images.prepare(RawImage(data: png, type: .png)))

        XCTAssertEqual(image.format, "png")
        XCTAssertEqual(image.bytes, png)
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 10)
        XCTAssertNotNil(NSImage(data: image.thumb))
    }

    func testConvertsTIFFToPNG() throws {
        let tiff = try XCTUnwrap(NSBitmapImageRep(cgImage: picture(width: 30, height: 30)).tiffRepresentation)
        let image = try XCTUnwrap(Images.prepare(RawImage(data: tiff, type: .tiff)))

        XCTAssertEqual(image.format, "png")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(image.bytes as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source).map { $0 as String }, UTType.png.identifier)
        XCTAssertEqual(image.width, 30)
    }

    func testTrustsContentOverPasteboardLabel() throws {
        // Some apps label JPEG bytes as PNG. Holt keeps them as what they are.
        let jpeg = try XCTUnwrap(encode(picture(width: 12, height: 12), as: .jpeg))
        let image = try XCTUnwrap(Images.prepare(RawImage(data: jpeg, type: .png)))
        XCTAssertEqual(image.format, "jpeg")
        XCTAssertEqual(image.bytes, jpeg)
    }

    func testThumbnailFitsTheRow() throws {
        let png = try XCTUnwrap(encode(picture(width: 2000, height: 1000), as: .png))
        let image = try XCTUnwrap(Images.prepare(RawImage(data: png, type: .png)))
        let thumb = try XCTUnwrap(CGImageSourceCreateWithData(image.thumb as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(thumb, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, Images.thumbMaxPixels)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, Images.thumbMaxPixels / 2)
        XCTAssertLessThan(image.thumb.count, 20_000)
    }

    func testRejectsBytesThatAreNotAnImage() {
        XCTAssertNil(Images.prepare(RawImage(data: Data("hello".utf8), type: .png)))
    }

    func testReadsTheTextInAScreenshot() throws {
        let png = try XCTUnwrap(encode(picture(width: 600, height: 160, text: "Invoice 2031"), as: .png))
        let text = Images.recognizeText(in: png)
        XCTAssertTrue(text.contains("Invoice"), "got: \(text)")
        XCTAssertTrue(text.contains("2031"), "got: \(text)")
    }

    func testPrefersPNGOverTIFFOnTheClipboard() throws {
        let item = NSPasteboardItem()
        let png = try XCTUnwrap(encode(picture(width: 8, height: 8), as: .png))
        item.setData(try XCTUnwrap(NSBitmapImageRep(cgImage: picture(width: 8, height: 8)).tiffRepresentation), forType: .tiff)
        item.setData(png, forType: .png)

        let raw = try XCTUnwrap(Images.raw(in: item))
        XCTAssertEqual(raw.type, .png)
        XCTAssertEqual(raw.data, png)
        XCTAssertNil(Images.raw(in: NSPasteboardItem()))
    }

    func testReadsAnImageFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holt-test-\(UUID()).png")
        let png = try XCTUnwrap(encode(picture(width: 8, height: 8), as: .png))
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)

        let raw = try XCTUnwrap(Images.raw(in: item))
        XCTAssertEqual(raw.type, .fileURL)
        XCTAssertEqual(raw.data, png)
    }

    func testPastesPNGAndTIFFForEveryApp() throws {
        let jpeg = try XCTUnwrap(encode(picture(width: 8, height: 8), as: .jpeg))
        let item = Images.pasteboardItem(bytes: jpeg, format: "jpeg", sourceApp: "com.apple.Safari")

        XCTAssertNotNil(item.data(forType: .png))
        XCTAssertNotNil(item.data(forType: .tiff))
        XCTAssertEqual(item.data(forType: Images.jpeg), jpeg)
        XCTAssertEqual(item.string(forType: Images.source), "com.apple.Safari")
        XCTAssertNil(item.string(forType: .fileURL))
    }

    // MARK: Helpers

    /// Drawn in pixels, not points, so sizes don't double on a Retina screen.
    private func picture(width: Int, height: Int, text: String? = nil) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSColor.white.setFill()
        rect.fill()
        if let text {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black,
            ]
            (text as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: attributes)
        } else {
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: width / 2, height: height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
