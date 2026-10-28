import AppKit
import HoltCore
import ImageIO
import UniformTypeIdentifiers
import Vision

/// An image as it was on the clipboard, before any work on it.
struct RawImage: @unchecked Sendable {
    let data: Data
    /// The pasteboard type it was read from.
    let type: NSPasteboard.PasteboardType
}

/// An image ready for the store: bytes in a format Holt keeps, its size in
/// pixels and a thumbnail of a few kilobytes.
struct CopiedImage: @unchecked Sendable {
    var bytes: Data
    /// "png", "jpeg" or "heic".
    var format: String
    var width: UInt32
    var height: UInt32
    var thumb: Data
}

/// Reading images from the clipboard, getting them ready for history, and
/// putting them back. Everything but `raw` is slow enough to run off the main
/// thread.
enum Images {
    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    static let heic = NSPasteboard.PasteboardType("public.heic")
    /// Other clipboard managers read this to credit the right app. See nspasteboard.org.
    static let source = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// Same cap as the core. Bigger images are skipped.
    static let maxBytes = 10 << 20
    /// A thumbnail's longer side in pixels: a 40 pt row on a Retina screen, with room.
    static let thumbMaxPixels = 240
    /// Text recognized in an image is cut here so search stays fast.
    static let maxTextLength = 10_000

    private static let fileExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]

    /// The image in a pasteboard item, best representation first: PNG as is,
    /// JPEG and HEIC as is, then TIFF, then an image file. The bytes are read
    /// now, because a file from Universal Clipboard is gone a moment later.
    static func raw(in item: NSPasteboardItem) -> RawImage? {
        for type in [NSPasteboard.PasteboardType.png, jpeg, heic, .tiff] {
            if let data = item.data(forType: type), !data.isEmpty {
                return RawImage(data: data, type: type)
            }
        }
        return nil
    }

    /// An image file copied in Finder. The item also carries the file's name as
    /// text and its icon as TIFF, so this is asked first.
    static func file(in item: NSPasteboardItem) -> RawImage? {
        guard let string = item.string(forType: .fileURL), let url = URL(string: string),
            fileExtensions.contains(url.pathExtension.lowercased()),
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= maxBytes,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return RawImage(data: data, type: .fileURL)
    }

    /// Decodes the image, keeps PNG, JPEG and HEIC bytes as they are and
    /// converts anything else (TIFF above all, which is uncompressed) to PNG,
    /// then measures it and draws the thumbnail. Nil for images Holt can't
    /// decode or over the cap.
    static func prepare(_ raw: RawImage) -> CopiedImage? {
        guard let source = CGImageSourceCreateWithData(raw.data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }

        let bytes: Data
        let format: String
        // The type by content, not by the pasteboard's label.
        switch CGImageSourceGetType(source).map({ $0 as String }) {
        case UTType.png.identifier:
            (bytes, format) = (raw.data, "png")
        case UTType.jpeg.identifier:
            (bytes, format) = (raw.data, "jpeg")
        case UTType.heic.identifier:
            (bytes, format) = (raw.data, "heic")
        default:
            guard let png = encode(source, as: .png, keepingDPIOf: properties) else { return nil }
            (bytes, format) = (png, "png")
        }
        guard bytes.count <= maxBytes, let thumb = thumbnail(source) else { return nil }
        return CopiedImage(bytes: bytes, format: format, width: UInt32(width), height: UInt32(height), thumb: thumb)
    }

    /// The text in the image, line by line, so search finds screenshots by
    /// what they show. Apple's recognizer runs on this Mac.
    static func recognizeText(in bytes: Data) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(data: bytes)
        guard (try? handler.perform([request])) != nil, let results = request.results else { return "" }
        let text = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return String(text.prefix(maxTextLength))
    }

    /// What goes on the clipboard when an image clip is pasted. PNG for
    /// browsers and Electron apps, which take nothing else, TIFF for older
    /// AppKit apps, and the original bytes when they're JPEG or HEIC. No file
    /// URL: editors that see one paste a file instead of the picture.
    static func pasteboardItem(bytes: Data, format: String, sourceApp: String?) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let png: Data?
        switch format {
        case "png":
            png = bytes
        case "jpeg", "heic":
            item.setData(bytes, forType: format == "jpeg" ? jpeg : heic)
            png = CGImageSourceCreateWithData(bytes as CFData, nil).flatMap { encode($0, as: .png, keepingDPIOf: [:]) }
        default:
            png = nil
        }
        if let png {
            item.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        if let sourceApp {
            item.setString(sourceApp, forType: source)
        }
        return item
    }

    /// A small preview from the clipboard bytes, for the arrival toast.
    static func thumbnailImage(from bytes: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let image = thumbnail(source, maxPixels: 96)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    /// The stored image decoded at the size the preview pane shows it, never
    /// bigger: a Retina screenshot would otherwise cost tens of megabytes.
    static func preview(path: String, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = thumbnail(source, maxPixels: maxPixels)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private static func thumbnail(_ source: CGImageSource, maxPixels: Int = thumbMaxPixels) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The thumbnail bytes: JPEG unless the image has transparency.
    private static func thumbnail(_ source: CGImageSource) -> Data? {
        guard let image = thumbnail(source, maxPixels: thumbMaxPixels) else { return nil }
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        return opaque
            ? encode(image, as: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.8])
            : encode(image, as: .png, properties: [:])
    }

    /// Re-encodes the first image of `source`, keeping its DPI so a Retina
    /// screenshot pastes at the size it was taken.
    private static func encode(_ source: CGImageSource, as type: UTType, keepingDPIOf properties: [CFString: Any]) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var dpi: [CFString: Any] = [:]
        if let width = properties[kCGImagePropertyDPIWidth], let height = properties[kCGImagePropertyDPIHeight] {
            dpi = [kCGImagePropertyDPIWidth: width, kCGImagePropertyDPIHeight: height]
        }
        return encode(image, as: type, properties: dpi)
    }

    private static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// "1920×1080".
func dimensions(_ image: ImageInfo) -> String {
    "\(image.width)×\(image.height)"
}

/// "Image 1920×1080", for places that show one line of text per clip.
func imageLabel(_ image: ImageInfo) -> String {
    "Image \(dimensions(image))"
}

/// "412 KB".
func fileSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
