import AppKit
import SwiftUI

/// Design tokens for the whole app. Every colour adapts to the active appearance so the
/// panel looks intentional in both light and dark.
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let accent = dynamic(
        light: NSColor(srgbRed: 0.29, green: 0.34, blue: 0.86, alpha: 1),
        dark: NSColor(srgbRed: 0.47, green: 0.52, blue: 1.0, alpha: 1))

    static let accentSoft = dynamic(
        light: NSColor(srgbRed: 0.29, green: 0.34, blue: 0.86, alpha: 0.12),
        dark: NSColor(srgbRed: 0.47, green: 0.52, blue: 1.0, alpha: 0.18))

    static let primaryText = dynamic(
        light: NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1),
        dark: NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1))

    static let secondaryText = dynamic(
        light: NSColor(srgbRed: 0.36, green: 0.38, blue: 0.42, alpha: 1),
        dark: NSColor(srgbRed: 0.62, green: 0.65, blue: 0.70, alpha: 1))

    static let tertiaryText = dynamic(
        light: NSColor(srgbRed: 0.52, green: 0.54, blue: 0.58, alpha: 1),
        dark: NSColor(srgbRed: 0.45, green: 0.48, blue: 0.53, alpha: 1))

    static let hairline = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.09),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09))

    /// Top edge of the panel, a touch brighter than the rest of the border.
    static let edgeHighlight = dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20))

    static let surface = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.035),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05))

    static let surfaceStrong = dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))

    static let hover = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06))

    static let panelBackground = dynamic(
        light: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.72),
        dark: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.80))

    /// Settings cards. Enough lift off the page to read as a group on its own, so the rows
    /// inside need no rules between them.
    static let card = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.04),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.045))

    /// Settings sidebar. Carries its own tone rather than a rule to divide it from the page.
    static let sidebarBackground = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.038),
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22))

    /// The selected row in the sidebar. A quiet slab reads as more settled than a coloured
    /// pill, and leaves the accent to mean one thing.
    static let selection = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.075),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.085))

    static let danger = dynamic(
        light: NSColor(srgbRed: 0.80, green: 0.20, blue: 0.20, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1))

    static let cornerRadius: CGFloat = 14
    static let rowRadius: CGFloat = 8
}

// MARK: Button styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.vertical, 4.5)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Rectangle())
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.secondaryText

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.vertical, 4.5)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.selection.opacity(configuration.isPressed ? 1.6 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// Small bounded cache for row thumbnails. Images are tiny JPEGs on disk, so the cache
/// stays capped by count and cost and never pins a large history in memory.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    /// Thumbnails whose file is gone. Remembering the misses keeps a broken row from
    /// hitting the disk on every redraw.
    private var missing = Set<String>()

    private init() {
        // The cost limit bounds this to a few megabytes, so it is left warm between panel
        // opens rather than dropped every time Clipline loses focus.
        cache.countLimit = 120
        cache.totalCostLimit = 6 * 1024 * 1024
    }

    func image(at url: URL) -> NSImage? {
        let name = url.lastPathComponent
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if missing.contains(name) { return nil }
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            missing.insert(name)
            return nil
        }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    func clear() {
        cache.removeAllObjects()
        missing.removeAll()
    }
}
