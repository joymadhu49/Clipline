// Renders AppIcon.icns for Clipline. Run from the project root: swift Scripts/make_icon.swift
//
// The mark is a clipboard seen as a stack: two sheets of history peeking out behind a
// white board, with an accent clip across the top. Drawn rather than exported so every
// size is rendered from the same geometry.
import AppKit

let backgroundTop = NSColor(calibratedRed: 0.106, green: 0.110, blue: 0.129, alpha: 1)
let backgroundBottom = NSColor(calibratedRed: 0.035, green: 0.037, blue: 0.051, alpha: 1)
let accentTop = NSColor(calibratedRed: 0.494, green: 0.541, blue: 1.0, alpha: 1)
let accentBottom = NSColor(calibratedRed: 0.318, green: 0.361, blue: 0.918, alpha: 1)
let boardColor = NSColor(calibratedRed: 0.965, green: 0.969, blue: 0.980, alpha: 1)
let lineColor = NSColor(calibratedRed: 0.106, green: 0.114, blue: 0.145, alpha: 1)

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size / 1024.0

    // Background squircle.
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let background = rounded(bounds, 185.4 * s)
    NSGradient(starting: backgroundTop, ending: backgroundBottom)!.draw(in: background, angle: -90)

    // Light catching the top edge, the same touch the panel has.
    let edge = rounded(bounds.insetBy(dx: 5 * s, dy: 5 * s), 180 * s)
    edge.lineWidth = 7 * s
    NSGradient(starting: NSColor.white.withAlphaComponent(0.20),
               ending: NSColor.white.withAlphaComponent(0.02))!.draw(in: edge, angle: -90)
    NSColor.white.withAlphaComponent(0.10).setStroke()
    edge.stroke()

    // Geometry, laid out so the whole mark keeps a clear margin inside the squircle.
    let boardWidth: CGFloat = 496
    let boardBottom: CGFloat = 176
    let boardTop: CGFloat = 726

    // A soft accent glow so the mark sits in light rather than on a flat field.
    if let glow = NSGradient(colors: [NSColor(calibratedRed: 0.42, green: 0.46, blue: 1.0, alpha: 0.22),
                                      NSColor(calibratedRed: 0.42, green: 0.46, blue: 1.0, alpha: 0.0)]) {
        NSGraphicsContext.current?.saveGraphicsState()
        background.setClip()
        glow.draw(fromCenter: NSPoint(x: size / 2, y: 720 * s), radius: 0,
                  toCenter: NSPoint(x: size / 2, y: 720 * s), radius: 430 * s, options: [])
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // The sheet behind, offset on the diagonal so its corner shows. A sheet tucked directly
    // behind the board just reads as a grey smudge.
    let backRect = NSRect(x: (size - boardWidth * s) / 2 + 30 * s,
                          y: boardBottom * s + 30 * s,
                          width: boardWidth * s,
                          height: (boardTop - boardBottom) * s)
    NSColor.white.withAlphaComponent(0.22).setFill()
    rounded(backRect, 58 * s).fill()

    // The board itself.
    let boardRect = NSRect(x: (size - boardWidth * s) / 2,
                           y: boardBottom * s,
                           width: boardWidth * s,
                           height: (boardTop - boardBottom) * s)
    let board = rounded(boardRect, 58 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 46 * s
    shadow.shadowOffset = NSSize(width: 0, height: -14 * s)
    shadow.set()
    boardColor.setFill()
    board.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Content lines. The top one carries the accent: the entry you just picked.
    let lineWidths: [CGFloat] = [340, 268, 190]
    for (index, width) in lineWidths.enumerated() {
        let height = 44 * s
        let y = (536 - CGFloat(index) * 98) * s
        let rect = NSRect(x: 322 * s, y: y, width: width * s, height: height)
        if index == 0 {
            NSGradient(starting: accentTop, ending: accentBottom)!
                .draw(in: rounded(rect, height / 2), angle: -90)
        } else {
            lineColor.withAlphaComponent(0.74 - Double(index - 1) * 0.22).setFill()
            rounded(rect, height / 2).fill()
        }
    }

    // The clip across the top, the one piece of colour. Wide enough to read as a clip
    // holding the board rather than a badge floating on it.
    let clipWidth: CGFloat = 268
    let clipRect = NSRect(x: (size - clipWidth * s) / 2, y: 700 * s,
                          width: clipWidth * s, height: 104 * s)
    let clip = rounded(clipRect, 42 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let clipShadow = NSShadow()
    clipShadow.shadowColor = NSColor(calibratedRed: 0.36, green: 0.40, blue: 1.0, alpha: 0.5)
    clipShadow.shadowBlurRadius = 48 * s
    clipShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    clipShadow.set()
    NSGradient(starting: accentTop, ending: accentBottom)!.draw(in: clip, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Slot in the clip so it reads as a clip and not a plain bar.
    let slotWidth: CGFloat = 104
    let slotRect = NSRect(x: (size - slotWidth * s) / 2, y: 734 * s,
                          width: slotWidth * s, height: 36 * s)
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.16, alpha: 0.55).setFill()
    rounded(slotRect, 20 * s).fill()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconsetURL = URL(fileURLWithPath: "AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
let master = drawIcon(size: 1024)
for (name, pixels) in sizes {
    writePNG(master, to: iconsetURL.appendingPathComponent("\(name).png"), pixels: pixels)
}

// A couple of loose previews for eyeballing the result at real sizes.
writePNG(master, to: URL(fileURLWithPath: "icon-preview-512.png"), pixels: 512)
writePNG(master, to: URL(fileURLWithPath: "icon-preview-64.png"), pixels: 64)
print("iconset written")
