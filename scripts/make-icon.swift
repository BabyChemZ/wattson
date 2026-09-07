// The app icon: a steady baseline with one bar breaking out of it.
//
// That is the whole product in one shape — a program's normal, and the moment
// it stops being normal. An SF Symbol pasted onto a square reads as a
// placeholder; this at least says what the thing does.
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
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let side = CGFloat(pixels)
    let inset = side * 0.055
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect,
                                xRadius: side * 0.225, yRadius: side * 0.225)

    // Near-black ground with a slight lift toward the top, so the icon has
    // depth at large sizes without looking glossy at small ones.
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
                        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1)])?
        .draw(in: squircle, angle: -90)

    squircle.setClip()

    // Bars sit on a shared floor, like the load charts inside the app.
    let plotWidth = rect.width * 0.68
    let plotLeft = rect.midX - plotWidth / 2
    let floor = rect.minY + rect.height * 0.26
    let ceiling = rect.maxY - rect.height * 0.18

    // Fewer, thicker bars. At 16 points a hairline spike disappears entirely,
    // and the icon has to survive being a Dock thumbnail before it has to look
    // good at 512.
    let heights: [CGFloat] = [0.30, 0.40, 0.95, 0.34, 0.27]
    let spikeIndex = 2
    let slot = plotWidth / CGFloat(heights.count)
    let barWidth = slot * 0.60
    let radius = barWidth / 2

    for (index, fraction) in heights.enumerated() {
        let height = (ceiling - floor) * fraction
        let x = plotLeft + CGFloat(index) * slot + (slot - barWidth) / 2
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: floor,
                                                   width: barWidth, height: height),
                               xRadius: radius, yRadius: radius)
        if index == spikeIndex {
            // The outlier, in the accent the app uses for anomalies.
            NSGradient(colors: [NSColor(srgbRed: 1.00, green: 0.58, blue: 0.24, alpha: 1),
                                NSColor(srgbRed: 0.91, green: 0.35, blue: 0.20, alpha: 1)])?
                .draw(in: bar, angle: -90)
        } else {
            NSColor(white: 1, alpha: 0.48).setFill()
            bar.fill()
        }
    }

    // A faint rule at the level the quiet bars sit at: the baseline itself.
    // Just above the quiet bars, so it reads as the level they sit at rather
    // than a line drawn through them.
    let baseline = (ceiling - floor) * 0.44 + floor
    let rule = NSBezierPath()
    rule.move(to: NSPoint(x: plotLeft - slot * 0.35, y: baseline))
    rule.line(to: NSPoint(x: plotLeft + plotWidth + slot * 0.35, y: baseline))
    rule.lineWidth = max(1, side * 0.010)
    NSColor(white: 1, alpha: 0.26).setStroke()
    rule.setLineDash([side * 0.026, side * 0.020], count: 2, phase: 0)
    rule.stroke()

    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    if let png = render(pixels: base) {
        try png.write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    }
    if let png = render(pixels: base * 2) {
        try png.write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
}
print("icons written")
