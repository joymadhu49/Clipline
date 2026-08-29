import AppKit

extension NSView {
    /// Draws the view into a PNG at `scale`x and writes it to `url`.
    ///
    /// `bitmapImageRepForCachingDisplay` hands back a rep at the window's backing scale, which
    /// comes out 1x for a window that has not been composited onto a Retina screen yet — fine
    /// for reading the interface back during QA, too soft to show anyone. Building the rep by
    /// hand pins the scale regardless of where the window is.
    func writeSnapshot(to url: URL, scale: CGFloat = 2) -> Bool {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return false }
        // Point size against a larger pixel buffer is what makes this a `scale`x rep, and it
        // is what sets the drawing transform on the context below.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        displayIgnoringOpacity(bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }
}
