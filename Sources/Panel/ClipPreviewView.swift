import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A larger look at one entry, laid over the list. Opened by holding a row down, by Space,
/// or by Command Y.
///
/// Pictures get the whole card, which is the point of it: a row thumbnail is too small to
/// tell two screenshots apart. Text, links and colours show everything a row can only begin,
/// and copied files list where they live. A masked entry stays masked here too.
struct ClipPreviewView: View {
    let item: ClipItem
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var loaded: Loaded?

    /// Longest side a picture is decoded at: sharp at the largest the panel can be on a
    /// Retina screen, without ever decoding a 48 megapixel photo in full.
    private static let maxPixel = 2400
    /// Longest text shown. SwiftUI lays out the whole string, and a few megabytes of it would
    /// stall the panel; the full text still pastes.
    private static let textLimit = 40_000

    private struct Loaded {
        var id: Int64
        var picture: ImageSupport.Preview?
        var text: String?
        var truncated = false
        var files: [URL] = []
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Theme.hairline)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surfaceStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: item.id) { await load() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if item.masked {
            notice("eye.slash", "Content hidden", "Press Command H to show it.")
        } else if let loaded, loaded.id == item.id {
            if let picture = loaded.picture {
                pictureView(picture)
            } else if item.kind == .color, let text = loaded.text, let color = item.swatchColor {
                colorView(color, value: text)
            } else if let text = loaded.text {
                textView(text, truncated: loaded.truncated)
            } else if !loaded.files.isEmpty {
                fileList(loaded.files)
            } else {
                notice("exclamationmark.triangle", "Nothing to show",
                       item.kind == .image ? "The stored image could not be read." : "The stored content could not be read.")
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func pictureView(_ picture: ImageSupport.Preview) -> some View {
        GeometryReader { geometry in
            let size = fittedSize(for: picture, in: geometry.size)
            Image(nsImage: picture.image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .background(picture.hasAlpha ? Checkerboard() : nil)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding(12)
    }

    /// Fits the picture in the card at no more than its natural size, so a small icon is not
    /// blown up into a blur. Points, not pixels: a Retina screenshot shows at the size it was
    /// on screen. Tiny images may double so there is something to look at.
    private func fittedSize(for picture: ImageSupport.Preview, in available: CGSize) -> CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let natural = CGSize(width: max(picture.pixelSize.width / scale, 1),
                             height: max(picture.pixelSize.height / scale, 1))
        let largestNatural: CGFloat = max(natural.width, natural.height) < 96 ? 2 : 1
        let fit = min(available.width / natural.width, available.height / natural.height, largestNatural)
        return CGSize(width: max(natural.width * fit, 1), height: max(natural.height * fit, 1))
    }

    private func textView(_ text: String, truncated: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(item.kind == .link ? Theme.accent : Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if truncated {
                    Text("Showing the first \(Self.textLimit.formatted()) characters. All of it pastes.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(12)
        }
    }

    private func colorView(_ color: NSColor, value: String) -> some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: color))
                .frame(width: 120, height: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
            Text(value.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
        }
    }

    private func fileList(_ files: [URL]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, url in
                    HStack(spacing: 8) {
                        // By type, not by file, so listing files never reads the disk.
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data))
                            .resizable()
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func notice(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .padding(16)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text(caption)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button("Copy", action: onCopy)
                .buttonStyle(GhostButtonStyle())
                .help("Copy without pasting, or press Command Return")
            Button("Paste", action: onPaste)
                .buttonStyle(PrimaryButtonStyle())
                .help("Paste, or press Return")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the preview, or press Space")
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .frame(height: 36)
    }

    /// Size and age, short enough to sit beside the buttons in the narrowest panel. The row
    /// underneath already names the source app. Nothing about a masked entry beyond its age.
    private var caption: String {
        if item.masked { return "••••••  ·  " + item.timeText }
        var parts: [String] = []
        switch item.kind {
        case .image:
            if item.pixelWidth > 0 { parts.append("\(item.pixelWidth) × \(item.pixelHeight)") }
            parts.append(item.sizeText)
        case .file:
            if item.fileCount > 1 {
                parts.append("\(item.fileCount) files")
            } else if let size = loaded?.picture?.pixelSize, loaded?.id == item.id {
                parts.append("\(Int(size.width)) × \(Int(size.height))")
            } else {
                parts.append("1 file")
            }
        case .text, .link, .color:
            parts.append(item.detailText)
        }
        parts.append(item.timeText)
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Loading

    private func load() async {
        let item = self.item
        guard !item.masked else { return }
        let maxPixel = Self.maxPixel
        let textLimit = Self.textLimit
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded in
            var loaded = Loaded(id: item.id)
            switch item.kind {
            case .image:
                loaded.picture = ImageSupport.previewSource(for: item)
                    .flatMap { ImageSupport.preview(from: $0, maxPixel: maxPixel) }
            case .file:
                loaded.files = ClipStore.shared.filePaths(id: item.id)
                // Asking for a preview is asking to look at the file, so this also works for
                // pictures copied before rows had thumbnails.
                loaded.picture = ImageSupport.previewSource(for: item)
                    .flatMap { ImageSupport.preview(from: $0, maxPixel: maxPixel) }
            case .text, .link, .color:
                if let body = ClipStore.shared.body(id: item.id) {
                    loaded.truncated = body.count > textLimit
                    loaded.text = loaded.truncated ? String(body.prefix(textLimit)) : body
                }
            }
            return loaded
        }.value
        guard !Task.isCancelled else { return }
        loaded = result
    }
}

/// The grey and white squares that show where a picture is transparent.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 7
            let columns = Int((size.width / cell).rounded(.up))
            let rows = Int((size.height / cell).rounded(.up))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    let square = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(square), with: .color(Color(white: 0.86)))
                }
            }
        }
    }
}
