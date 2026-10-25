// Generates the MacBack application icon as an iconset of PNGs (one size per
// Finder scale): the same "arrow.uturn.backward.circle" symbol that the menu
// bar uses, in black on a transparent background. Convert the iconset to an
// .icns afterwards:
//
//   xcrun swift Scripts/AppIcon.swift build/AppIcon.iconset
//   iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

import AppKit

let symbolName = "arrow.uturn.backward.circle"
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/AppIcon.iconset"

try? FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true)

/// The symbol rendered into its own canvas at a given square size.
func symbolImage(_ side: CGFloat) -> NSImage {
    let symbol = NSImage(
        systemSymbolName: symbolName, accessibilityDescription: nil)!
    let scaled = symbol.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: side, weight: .bold))!
    scaled.size = NSSize(width: side, height: side)

    let canvas = NSImage(size: scaled.size)
    canvas.lockFocus()
    scaled.draw(
        in: NSRect(origin: .zero, size: canvas.size),
        from: .zero, operation: .sourceOver, fraction: 1)
    canvas.unlockFocus()
    return canvas
}

/// Recolors a canvas to pure black, keeping only its alpha shape.
func blackSilhouette(of source: NSImage) -> NSImage {
    let canvas = NSImage(size: source.size)
    canvas.lockFocus()
    NSColor.black.setFill()
    NSRect(origin: .zero, size: canvas.size).fill()
    source.draw(
        in: NSRect(origin: .zero, size: canvas.size),
        from: .zero, operation: .destinationIn, fraction: 1)
    canvas.unlockFocus()
    return canvas
}

func appIcon(_ pixels: Int) -> NSImage {
    let size = CGFloat(pixels)
    // The glyph box includes the symbol's internal padding, so the visible
    // arrow lands around 3/4 of the canvas edge.
    let glyphSide = size * 0.55
    let glyph = blackSilhouette(of: symbolImage(glyphSide))

    let canvas = NSImage(size: NSSize(width: size, height: size))
    canvas.lockFocus()
    let inset = (size - glyph.size.width) / 2
    glyph.draw(
        in: NSRect(x: inset, y: inset, width: glyph.size.width,
                   height: glyph.size.height),
        from: .zero, operation: .sourceOver, fraction: 1)
    canvas.unlockFocus()
    return canvas
}

func pngData(of image: NSImage) -> Data {
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for (scale, pixels) in [(1, base), (2, base * 2)] {
        let name = scale == 1
            ? "icon_\(base)x\(base).png"
            : "icon_\(base)x\(base)@2x.png"
        let data = pngData(of: appIcon(pixels))
        try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
        print("wrote \(name) (\(pixels)px)")
    }
}
