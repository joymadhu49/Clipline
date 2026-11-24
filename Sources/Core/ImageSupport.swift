import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image formats, thumbnails and previews, shared by capture, paste, drag and the preview.
///
/// Everything here decodes through ImageIO with a pixel cap, so a 50 megapixel photo is never
/// decoded at full size just to draw a row or a preview.
enum ImageSupport {
    /// Image flavours worth keeping from the pasteboard, best first.
    ///
    /// Encoded formats come before TIFF: Safari and Preview put pictures up as uncompressed
    /// TIFF next to the original, and the original is both exact and a fraction of the size.
    /// GIF leads because an app only offers GIF when that is what the picture is, and
    /// converting it would flatten the animation.
    static let preferredPasteboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        .png,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.webP.identifier),
        .tiff,
    ]

    /// Formats that are stored byte for byte as they were copied, by file extension.
    private static let keptAsIs: [String: String] = [
        UTType.png.identifier: "png",
        UTType.jpeg.identifier: "jpg",
        UTType.gif.identifier: "gif",
        UTType.heic.identifier: "heic",
        UTType.webP.identifier: "webp",
    ]

    /// Every image format ImageIO can decode on this Mac.
    private static let decodableTypes: Set<String> = {
        let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return Set(identifiers)
    }()

    /// The image flavours on the pasteboard right now, in the order they should be tried:
    /// the well known ones first, then anything else that is an image ImageIO can read.
    static func imageTypes(in available: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        var result = preferredPasteboardTypes.filter(available.contains)
        for type in available where !result.contains(type) {
            guard decodableTypes.contains(type.rawValue),
                  let uti = UTType(type.rawValue), uti.conforms(to: .image) else { continue }
            result.append(type)
        }
        return result
    }

    /// Whether a flavour is already compressed and gets stored exactly as it came.
    static func isKeptAsIs(_ type: NSPasteboard.PasteboardType) -> Bool {
        keptAsIs[type.rawValue] != nil
    }

    /// The pasteboard flavour for a stored image, from the extension it was saved with.
    static func pasteboardType(forExtension pathExtension: String) -> NSPasteboard.PasteboardType {
        switch pathExtension.lowercased() {
        case "tiff", "tif": return .tiff
        case "png": return .png
        default:
            let uti = UTType(filenameExtension: pathExtension) ?? .png
            return NSPasteboard.PasteboardType(uti.identifier)
        }
    }

    /// What a captured image is stored as. Compressed formats stay exactly as copied, so a
    /// JPEG photo or an animated GIF pastes back the way it came. Anything else, mostly TIFF,
    /// becomes PNG, or JPEG when an opaque picture is still over the limit as PNG.
    static func storable(_ data: Data, type: NSPasteboard.PasteboardType, limit: Int) -> (data: Data, pathExtension: String)? {
        if let pathExtension = keptAsIs[type.rawValue] {
            return data.count <= limit ? (data, pathExtension) : nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            // Undecodable here, but the app it is pasted into may still read it.
            return type == .tiff && data.count <= limit ? (data, "tiff") : nil
        }
        if let png = encode(image, as: .png), png.count <= limit {
            return (png, "png")
        }
        if !hasAlpha(image), let jpeg = encode(image, as: .jpeg, quality: 0.9), jpeg.count <= limit {
            return (jpeg, "jpg")
        }
        return nil
    }

    // MARK: Files

    /// Whether a file is a picture ImageIO can draw, judged by its extension alone so the
    /// check never touches the disk.
    static func isImageFile(_ url: URL) -> Bool {
        guard let uti = UTType(filenameExtension: url.pathExtension), uti.conforms(to: .image) else { return false }
        return decodableTypes.contains(uti.identifier)
    }

    /// Files larger than this are not opened for a thumbnail. Decoding a huge TIFF or RAW
    /// file is slow, and the row would rather show an icon than make the capture wait.
    private static let largestThumbnailedFile = 200 * 1024 * 1024

    /// An image source for a file on this Mac, or nil when reading it would mean pulling it
    /// down from iCloud first or the file is too big to be worth it.
    static func localImageSource(at url: URL) -> CGImageSource? {
        guard isImageFile(url) else { return nil }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return nil }
            if let size = values.fileSize, size > largestThumbnailedFile { return nil }
        }
        return CGImageSourceCreateWithURL(url as CFURL, nil)
    }

    // MARK: Thumbnails and previews

    /// Small preview for a list row. Opaque pictures are stored as JPEG; anything with
    /// transparency as PNG, since JPEG has no alpha and a cut out logo or a window shot
    /// would otherwise come out on a black box.
    static func thumbnail(from source: CGImageSource, maxPixel: Int,
                          preferEmbedded: Bool = false) -> (data: Data, pathExtension: String)? {
        let options: [CFString: Any] = [
            // Files may carry a ready made thumbnail, which is far cheaper than decoding a
            // large photo. Clipboard data is decoded, since it is in memory already.
            preferEmbedded ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if hasAlpha(image) {
            return encode(image, as: .png).map { ($0, "png") }
        }
        return encode(image, as: .jpeg, quality: 0.72).map { ($0, "jpg") }
    }

    /// A decoded picture ready to draw at up to `maxPixel` on its longer side.
    struct Preview {
        let image: NSImage
        /// Size of the original, not of the downsampled copy.
        let pixelSize: CGSize
        let hasAlpha: Bool
    }

    static func preview(from source: CGImageSource, maxPixel: Int) -> Preview? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var pixelSize = CGSize(width: image.width, height: image.height)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            // Orientations 5 to 8 are rotated a quarter turn, so the stored width is the height.
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            pixelSize = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return Preview(image: nsImage, pixelSize: pixelSize, hasAlpha: hasAlpha(image))
    }

    /// The picture behind an entry: the stored image, or the first picture among copied files.
    static func previewSource(for item: ClipItem) -> CGImageSource? {
        switch item.kind {
        case .image:
            guard let blob = ClipStore.shared.blobData(id: item.id) else { return nil }
            return CGImageSourceCreateWithData(blob.data as CFData, nil)
        case .file:
            guard let url = ClipStore.shared.filePaths(id: item.id).first(where: isImageFile) else { return nil }
            return localImageSource(at: url)
        case .text, .link, .color:
            return nil
        }
    }

    // MARK: Encoding

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
