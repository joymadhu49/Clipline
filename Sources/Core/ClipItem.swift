import AppKit

/// The kind of payload a clipboard entry holds. Drives icon, preview and paste behaviour.
enum ClipKind: String, Codable, CaseIterable {
    case text
    case link
    case color
    case image
    case file

    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    var title: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .color: return "Color"
        case .image: return "Image"
        case .file: return "File"
        }
    }
}

/// Filters offered in the panel header.
enum ClipFilter: String, CaseIterable, Identifiable {
    case all
    case pinned
    case text
    case link
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .pinned: return "Pinned"
        case .text: return "Text"
        case .link: return "Links"
        case .image: return "Images"
        case .file: return "Files"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "square.stack"
        case .pinned: return "pin.fill"
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// SQL fragment applied to the item query, empty when the filter matches everything.
    var sqlCondition: String {
        switch self {
        case .all: return ""
        case .pinned: return "pinned = 1"
        case .text: return "kind IN ('text','color')"
        case .link: return "kind = 'link'"
        case .image: return "kind = 'image'"
        case .file: return "kind = 'file'"
        }
    }
}

/// A lightweight row loaded from the database.
///
/// Deliberately holds only metadata plus a short preview. Full bodies and images are
/// fetched on demand so a long history never sits in memory.
struct ClipItem: Identifiable, Equatable {
    let id: Int64
    var kind: ClipKind
    var preview: String
    var pinned: Bool
    var pinOrder: Int
    var copiedAt: Date
    var createdAt: Date
    var useCount: Int
    var byteSize: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var fileCount: Int
    var sourceName: String
    var sourceBundle: String
    var thumbPath: String?
    var hasBody: Bool
    /// Masked entries paste as normal but the list shows their name or dots instead of the
    /// content, so they stay safe on a shared or recorded screen.
    var masked: Bool = false
    /// Optional name that stands in for the content in the list.
    var label: String = ""

    var isTruncated: Bool { byteSize > preview.utf8.count + 8 }

    /// Human readable size such as "12 KB".
    var sizeText: String {
        let bytes = Double(byteSize)
        if bytes < 1024 { return "\(byteSize) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", bytes / 1024) }
        return String(format: "%.1f MB", bytes / (1024 * 1024))
    }

    /// Compact relative time such as "just now" or "3 h ago".
    var timeText: String {
        let seconds = Date().timeIntervalSince(copiedAt)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if seconds < 86_400 * 7 { return "\(Int(seconds / 86_400)) d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: copiedAt)
    }

    var detailText: String {
        switch kind {
        case .image:
            return pixelWidth > 0 ? "\(pixelWidth) by \(pixelHeight) px" : sizeText
        case .file:
            return fileCount > 1 ? "\(fileCount) files" : "1 file"
        default:
            let count = byteSize
            if count < 1024 { return "\(count) characters" }
            return sizeText
        }
    }

    /// Colour parsed out of the preview for colour swatch entries.
    var swatchColor: NSColor? {
        guard kind == .color else { return nil }
        return NSColor.fromClipboardString(preview)
    }
}
