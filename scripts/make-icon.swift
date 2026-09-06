// Renders the app icon. Cream ground, coral mark, squircle silhouette — the
// same palette as the UI.
//
// Draws into an explicit NSBitmapImageRep context rather than NSImage's
// lockFocus, which is unreliable outside a running GUI app, and emits exactly
// the sizes iconutil accepts.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(pixels)
    let inset = side * 0.055
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect,
                                xRadius: side * 0.225, yRadius: side * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0.984, green: 0.976, blue: 0.961, alpha: 1),
               ending: NSColor(srgbRed: 0.941, green: 0.929, blue: 0.902, alpha: 1))?
        .draw(in: squircle, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: side * 0.44, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let markRect = NSRect(x: (side - symbol.size.width) / 2,
                              y: (side - symbol.size.height) / 2,
                              width: symbol.size.width, height: symbol.size.height)
        NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1).set()
        symbol.draw(in: markRect)
        markRect.fill(using: .sourceAtop)
    }

    NSGraphicsContext.current?.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

// iconutil accepts only these names; anything else makes it refuse the set.
for base in [16, 32, 128, 256, 512] {
    if let png = render(pixels: base) {
        try png.write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    }
    if let png = render(pixels: base * 2) {
        try png.write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
}
print("icons written")
