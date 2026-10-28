import AppKit
import ImageIO
import UniformTypeIdentifiers
import HoltCore
import SwiftUI
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
        // What Finder puts on the clipboard: the URL, the name as text, the icon as TIFF.
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.lastPathComponent, forType: .string)
        item.setData(try XCTUnwrap(NSBitmapImageRep(cgImage: picture(width: 4, height: 4)).tiffRepresentation), forType: .tiff)

        let raw = try XCTUnwrap(Images.file(in: item))
        XCTAssertEqual(raw.type, .fileURL)
        XCTAssertEqual(raw.data, png)
    }

    func testSkipsFilesThatAreNotImagesOrTooBig() throws {
        let dir = FileManager.default.temporaryDirectory
        let text = dir.appendingPathComponent("holt-test-\(UUID()).txt")
        let huge = dir.appendingPathComponent("holt-test-\(UUID()).png")
        try Data("notes".utf8).write(to: text)
        try Data(count: Images.maxBytes + 1).write(to: huge)
        defer {
            try? FileManager.default.removeItem(at: text)
            try? FileManager.default.removeItem(at: huge)
        }
        for url in [text, huge] {
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            XCTAssertNil(Images.file(in: item), url.lastPathComponent)
        }
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

final class DragTests: XCTestCase {
    func testImageDragOffersFileAndPictureTypes() throws {
        let png = try XCTUnwrap(encodePNG())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("holt-drag-\(UUID()).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = Images.pasteboardItem(bytes: png, format: "png", sourceApp: nil)
        item.setString(url.absoluteString, forType: .fileURL)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("holt-test-\(UUID())"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        XCTAssertTrue(types.contains("public.file-url"), "\(types)")
        XCTAssertTrue(types.contains("public.png"), "\(types)")
        XCTAssertTrue(types.contains("public.tiff"), "\(types)")
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL, url)
        pasteboard.releaseGlobally()
    }

    private func encodePNG() -> Data? {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

final class DragRoutingTests: XCTestCase {
    /// A click on a row must land on the drag view, not on SwiftUI underneath.
    @MainActor
    func testRowHitTestReachesTheDragView() {
        let clip = Clip(id: 1, kind: .text, text: "hello", sourceApp: nil, createdAt: 0, pinned: false, device: nil, image: nil)
        let view = Text("hello").frame(width: 200, height: 32)
            .overlay(DragSource(clip: clip, onClick: {}, onDoubleClick: {}))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let hit = host.hitTest(NSPoint(x: 100, y: 16))
        XCTAssertTrue(hit is DragSource.DragView, "hit: \(String(describing: hit))")
    }
}

final class PopupDragRoutingTests: XCTestCase {
    /// Same view tree as the real popup: scroll view, lazy stack, rows.
    @MainActor
    func testDoubleClickOnARowInTheRealPopupPicksIt() throws {
        let store = try Store.open(path: ":memory:")
        _ = try store.add(text: "first", sourceApp: nil)
        _ = try store.add(text: "second", sourceApp: nil)
        let model = PopupModel(store: store, syncStatus: { nil })
        var picked: Clip?
        let host = NSHostingView(rootView: PopupView(model: model, onPick: { picked = $0 }, canPreview: { false }))
        let panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.contentView = host
        model.reset()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()

        let dragViews = descendants(of: host).compactMap { $0 as? DragSource.DragView }
        XCTAssertEqual(dragViews.count, 2, "rows: \(dragViews.count)")
        let row = try XCTUnwrap(dragViews.last)
        let center = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        // SwiftUI's scroll view answers hit tests itself; the panel routes around it.
        XCTAssertFalse(host.hitTest(host.convert(center, from: nil)) is DragSource.DragView)

        for (type, count) in [(NSEvent.EventType.leftMouseDown, 2), (.leftMouseUp, 2)] {
            let event = NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: count, pressure: 1)!
            panel.sendEvent(event)
        }
        let frames = dragViews.map { "\($0.clip?.text ?? "-")@\($0.convert($0.bounds, to: nil)) visible=\($0.visibleRect)" }
        XCTAssertEqual(picked?.text, row.clip?.text, "double-click should pick the row; center=\(center) rows=\(frames)")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
