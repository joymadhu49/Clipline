import AppKit
import SwiftUI

/// Drags entries out of the panel through AppKit rather than SwiftUI's `onDrag`.
///
/// `onDrag` hands the drop an `NSItemProvider`, which reaches the other app as promised data.
/// Finder and most native apps resolve the promise, but Chromium based apps (Claude, Slack,
/// Chrome, VS Code and other Electron apps) do not, and a dropped image or file landed as its
/// address typed out as text. An AppKit dragging session carries exactly what a drag out of
/// Finder carries instead: a real file on disk behind `public.file-url`, which every app
/// takes as a file, with the image data alongside for apps that would rather have the
/// picture itself.
final class RowDragController: NSObject, NSDraggingSource {
    static let shared = RowDragController()

    /// Starts a drag for `item` from the mouse event that moved far enough to mean one.
    /// Returns false when there is nothing to drag, such as an image whose file is gone.
    @MainActor
    @discardableResult
    func beginDrag(_ item: ClipItem, event: NSEvent) -> Bool {
        guard let view = event.window?.contentView else { return false }
        let writers = pasteboardItems(for: item)
        guard !writers.isEmpty else { return false }

        let image = dragImage(for: item, scale: event.window?.backingScaleFactor ?? 2)
        let location = view.convert(event.locationInWindow, from: nil)
        let draggingItems = writers.enumerated().map { index, writer -> NSDraggingItem in
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            // Several files stack up under the pointer, offset a little so they read as more
            // than one; only the top one carries the picture.
            let offset = CGFloat(min(index, 3)) * 4
            let frame = NSRect(x: location.x - image.size.width / 2 + offset,
                               y: location.y - image.size.height / 2 - offset,
                               width: image.size.width, height: image.size.height)
            dragging.setDraggingFrame(frame, contents: index == 0 ? image : nil)
            return dragging
        }
        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    // MARK: NSDraggingSource

    /// Copy only. A move would let Finder carry a copied file away from where it lives.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    // MARK: Payload

    /// What a drag of `item` puts on the drag pasteboard. Internal rather than private so the
    /// self test can write it to a pasteboard of its own and read it back.
    func pasteboardItems(for item: ClipItem) -> [NSPasteboardWriting] {
        switch item.kind {
        case .image:
            guard let blob = ClipStore.shared.blobData(id: item.id) else { return [] }
            // The stored file is sealed, so the drop gets a decrypted copy, under a name worth
            // reading in whatever app it lands in.
            let name = Self.dragFileName(for: item, pathExtension: blob.pathExtension)
            guard let url = ClipStore.shared.writeDragCopy(blob.data, named: name) else { return [] }
            let type = ImageSupport.pasteboardType(forExtension: blob.pathExtension)
            return [PasteEngine.imagePasteboardItem(blob.data, type: type, fileURL: url, includeTIFF: false)]

        case .file:
            // One item per file, carrying the file and nothing else, the way Finder does it.
            // A plain text flavour would let an app paste the path in place of the file.
            return ClipStore.shared.filePaths(id: item.id).map { url in
                let entry = NSPasteboardItem()
                entry.setString(url.absoluteString, forType: .fileURL)
                return entry
            }

        case .text, .link, .color:
            let text = ClipStore.shared.body(id: item.id) ?? item.preview
            let entry = NSPasteboardItem()
            entry.setString(text, forType: .string)
            if item.kind == .link,
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                entry.setString(url.absoluteString, forType: .URL)
            }
            return [entry]
        }
    }

    /// "Image 2026-11-24 at 10.32.15.png", in the style of a macOS screenshot, or the name the
    /// entry was given.
    static func dragFileName(for item: ClipItem, pathExtension: String) -> String {
        let named = item.label
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the file, and a masked entry's name is all it shows.
        if !named.isEmpty, !named.hasPrefix(".") {
            return String(named.prefix(80)) + "." + pathExtension
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Image \(formatter.string(from: item.copiedAt)).\(pathExtension)"
    }

    // MARK: Drag image

    /// What follows the pointer: the picture for images, a small label for everything else.
    @MainActor
    private func dragImage(for item: ClipItem, scale: CGFloat) -> NSImage {
        if item.showsImage, !item.masked,
           let url = ClipStore.shared.thumbnailURL(for: item),
           let thumbnail = ThumbnailCache.shared.image(at: url) {
            let longest: CGFloat = 112
            let size = thumbnail.size
            let ratio = min(longest / max(size.width, 1), longest / max(size.height, 1), 1)
            let fitted = NSSize(width: max(size.width * ratio, 24), height: max(size.height * ratio, 24))
            let image = NSImage(size: fitted, flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
                thumbnail.draw(in: rect)
                return true
            }
            return image
        }
        let renderer = ImageRenderer(content: DragLabel(item: item))
        renderer.scale = scale
        // Short labels stay short; long ones truncate at this width.
        renderer.proposedSize = ProposedViewSize(width: 260, height: nil)
        return renderer.nsImage ?? NSImage(size: NSSize(width: 32, height: 32))
    }
}

/// The label that follows the pointer while text, a link or a file is dragged.
private struct DragLabel: View {
    let item: ClipItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.masked ? "eye.slash" : item.kind.symbolName)
                .font(.system(size: 10, weight: .medium))
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var title: String {
        if item.masked { return item.label.isEmpty ? "••••••••••" : item.label }
        if !item.label.isEmpty { return item.label }
        let text = item.preview.isEmpty ? item.kind.title : item.preview
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}
